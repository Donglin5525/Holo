//
//  AppleSignInAuthService.swift
//  Holo
//
//  使用 Sign in with Apple 管理 Holo 本地登录态。
//

import AuthenticationServices
import Combine
import Foundation
import OSLog

private let authLogger = Logger(subsystem: "com.holo.app", category: "AppleSignInAuthService")

enum HoloAuthStatus: Equatable {
    case signedOut
    case signedIn
    case credentialRevoked
}

@MainActor
protocol HoloAuthSessionStoring {
    func save(_ session: HoloAuthSession) throws
    func load() throws -> HoloAuthSession?
    func delete() throws
}

@MainActor
struct KeychainHoloAuthSessionStore: HoloAuthSessionStoring {
    func save(_ session: HoloAuthSession) throws {
        try KeychainService.shared.saveAppleAuthSession(session)
    }

    func load() throws -> HoloAuthSession? {
        try KeychainService.shared.loadAppleAuthSession()
    }

    func delete() throws {
        try KeychainService.shared.deleteAppleAuthSession()
    }
}

@MainActor
final class AppleSignInAuthService: ObservableObject {
    static let shared = AppleSignInAuthService()

    @Published private(set) var status: HoloAuthStatus = .signedOut
    @Published private(set) var session: HoloAuthSession?
    @Published private(set) var isSigningIn = false
    @Published var errorMessage: String?

    private let sessionStore: HoloAuthSessionStoring
    private let credentialProvider: ASAuthorizationAppleIDProvider
    private let internalAccessService: HoloInternalAccessService

    init(
        sessionStore: HoloAuthSessionStoring? = nil,
        credentialProvider: ASAuthorizationAppleIDProvider = ASAuthorizationAppleIDProvider(),
        internalAccessService: HoloInternalAccessService? = nil
    ) {
        self.sessionStore = sessionStore ?? KeychainHoloAuthSessionStore()
        self.credentialProvider = credentialProvider
        self.internalAccessService = internalAccessService ?? .shared
        loadStoredSession()
        observeCredentialRevocation()
    }

    private func observeCredentialRevocation() {
        NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                authLogger.warning("Apple ID 凭证已被用户撤销")
                try? sessionStore.delete()
                internalAccessService.clear()
                session = nil
                status = .credentialRevoked
                errorMessage = "Apple 登录已失效，请重新登录"
            }
        }
    }

    var isSignedIn: Bool {
        status == .signedIn && session != nil
    }

    var statusText: String {
        switch status {
        case .signedOut:
            return "本机模式"
        case .signedIn:
            return "已通过 Apple 登录"
        case .credentialRevoked:
            return "Apple 登录已失效，请重新登录"
        }
    }

    func configureSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    func handleSignInCompletion(_ result: Result<ASAuthorization, Error>) {
        isSigningIn = true
        defer { isSigningIn = false }

        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Apple 登录返回了无法识别的凭证"
                return
            }

            let authSession = HoloAuthSession(
                userIdentifier: credential.user,
                fullName: Self.fullNameString(from: credential.fullName),
                email: credential.email,
                signedInAt: Date()
            )

            do {
                try sessionStore.save(authSession)
                session = authSession
                status = .signedIn
                errorMessage = nil
                Task {
                    await internalAccessService.establishSession(
                        identityToken: credential.identityToken,
                        authorizationCode: credential.authorizationCode
                    )
                }
            } catch {
                errorMessage = "保存登录状态失败：\(error.localizedDescription)"
                authLogger.error("保存 Apple 登录态失败：\(error.localizedDescription)")
            }

        case .failure(let error):
            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                errorMessage = nil
            } else {
                errorMessage = "Apple 登录失败：\(error.localizedDescription)"
                authLogger.error("Apple 登录失败：\(error.localizedDescription)")
            }
        }
    }

    func refreshCredentialState() async {
        guard let session else {
            status = .signedOut
            return
        }

        do {
            let state = try await credentialState(forUserID: session.userIdentifier)
            switch state {
            case .authorized, .transferred:
                status = .signedIn
                errorMessage = nil
            case .revoked, .notFound:
                try? sessionStore.delete()
                internalAccessService.clear()
                self.session = nil
                status = .credentialRevoked
                errorMessage = "Apple 登录已失效，请重新登录"
            @unknown default:
                status = .signedIn
            }
        } catch {
            authLogger.warning("Apple 凭证状态检查失败：\(error.localizedDescription)")
        }
    }

    func signOut() {
        do {
            try sessionStore.delete()
        } catch {
            errorMessage = "退出登录失败：\(error.localizedDescription)"
            authLogger.error("删除 Apple 登录态失败：\(error.localizedDescription)")
            return
        }

        session = nil
        internalAccessService.clear()
        status = .signedOut
        errorMessage = nil
    }

    /// 标记账号删除完成，将状态设为已注销
    /// Sign in with Apple 凭证撤销需通过服务端 REST API（Apple /auth/revoke 端点），
    /// 客户端负责清除所有本地数据并退出登录态
    func markAccountDeleted() {
        if let error = tryDeleteSession() {
            authLogger.warning("删除登录态失败（不阻断删除）：\(error.localizedDescription)")
        }

        session = nil
        internalAccessService.clear()
        status = .signedOut
        errorMessage = nil
    }

    private func tryDeleteSession() -> Error? {
        do {
            try sessionStore.delete()
            return nil
        } catch {
            return error
        }
    }

    private func loadStoredSession() {
        do {
            session = try sessionStore.load()
            status = session == nil ? .signedOut : .signedIn
        } catch {
            session = nil
            status = .signedOut
            errorMessage = "读取登录状态失败：\(error.localizedDescription)"
            authLogger.error("读取 Apple 登录态失败：\(error.localizedDescription)")
        }
    }

    private func credentialState(forUserID userID: String) async throws -> ASAuthorizationAppleIDProvider.CredentialState {
        try await withCheckedThrowingContinuation { continuation in
            credentialProvider.getCredentialState(forUserID: userID) { state, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: state)
                }
            }
        }
    }

    private static func fullNameString(from components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let name = formatter.string(from: components).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
