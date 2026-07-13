import Combine
import Foundation
import OSLog

private let internalAccessLogger = Logger(subsystem: "com.holo.app", category: "HoloInternalAccess")

@MainActor
protocol HoloBackendSessionStoring {
    func save(_ session: HoloBackendSession) throws
    func load() throws -> HoloBackendSession?
    func delete() throws
}

@MainActor
struct KeychainHoloBackendSessionStore: HoloBackendSessionStoring {
    func save(_ session: HoloBackendSession) throws {
        try KeychainService.shared.saveHoloBackendSession(session)
    }

    func load() throws -> HoloBackendSession? {
        try KeychainService.shared.loadHoloBackendSession()
    }

    func delete() throws {
        try KeychainService.shared.deleteHoloBackendSession()
    }
}

protocol HoloSessionExchanging: Sendable {
    func exchange(identityToken: String, authorizationCode: String?) async throws -> HoloBackendSession
}

struct HoloBackendSessionExchangeClient: HoloSessionExchanging {
    let baseURL: String
    let session: URLSession

    init(baseURL: String = HoloBackendEnvironment.baseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func exchange(identityToken: String, authorizationCode: String?) async throws -> HoloBackendSession {
        guard let url = URL(string: "\(baseURL)/v1/auth/apple/session") else {
            throw HoloInternalAccessError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = try JSONEncoder().encode(ExchangeRequest(
            identityToken: identityToken,
            authorizationCode: authorizationCode
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw HoloInternalAccessError.exchangeRejected
        }
        return try JSONDecoder().decode(HoloBackendSession.self, from: data)
    }

    private struct ExchangeRequest: Encodable {
        let identityToken: String
        let authorizationCode: String?
    }
}

@MainActor
final class HoloInternalAccessService: ObservableObject {
    static let shared = HoloInternalAccessService()

    @Published private(set) var session: HoloBackendSession?

    private let store: HoloBackendSessionStoring
    private let exchanger: any HoloSessionExchanging

    init(
        store: HoloBackendSessionStoring? = nil,
        exchanger: (any HoloSessionExchanging)? = nil
    ) {
        self.store = store ?? KeychainHoloBackendSessionStore()
        self.exchanger = exchanger ?? HoloBackendSessionExchangeClient()
        self.session = try? self.store.load()
        if let session, session.expirationDate <= Date() {
            clear()
        }
    }

    var canViewAILogs: Bool {
        HoloInternalAccessPolicy.canViewAILogs(
            appleSignedIn: AppleSignInAuthService.shared.isSignedIn,
            session: session
        )
    }

    func establishSession(identityToken: Data?, authorizationCode: Data?) async {
        guard let identityToken,
              let identityTokenString = String(data: identityToken, encoding: .utf8),
              !identityTokenString.isEmpty else {
            clear()
            return
        }
        let authorizationCodeString = authorizationCode.flatMap { String(data: $0, encoding: .utf8) }

        do {
            let newSession = try await exchanger.exchange(
                identityToken: identityTokenString,
                authorizationCode: authorizationCodeString
            )
            guard newSession.expirationDate > Date() else {
                clear()
                return
            }
            try store.save(newSession)
            session = newSession
        } catch {
            clear()
            internalAccessLogger.warning("内部诊断会话建立失败")
        }
    }

    func clear() {
        try? store.delete()
        session = nil
        HoloInternalLogService.shared.clear()
    }
}

enum HoloInternalAccessError: Error {
    case invalidEndpoint
    case exchangeRejected
}
