//
//  HoloAppAttestSessionManager.swift
//  Holo
//
//  用 App Attest 建立短期后端实例会话；key 由系统管理，token 仅存本机 Keychain。
//

import CryptoKit
import DeviceCheck
import Foundation
import Security

actor HoloAppAttestSessionManager {

    static let shared = HoloAppAttestSessionManager()

    private let service = DCAppAttestService.shared
    private let session: URLSession
    private let baseURL: String
    private var cachedState: StoredState?
    private var refreshTask: Task<StoredState, Error>?

    init(
        baseURL: String = HoloBackendEnvironment.baseURL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func authorized(_ request: APIRequest) async throws -> APIRequest {
        guard service.isSupported else {
            // 模拟器和不支持设备继续走后端的受限兼容通道；生产强制模式会明确拒绝。
            return request
        }
        let state = try await validState()
        var headers = request.headers
        headers["Authorization"] = "Bearer \(state.token)"
        return APIRequest(
            baseURL: request.baseURL,
            path: request.path,
            method: request.method,
            headers: headers,
            body: request.body
        )
    }

    func authorizationValue() async throws -> String? {
        guard service.isSupported else { return nil }
        return "Bearer \(try await validState().token)"
    }

    private func validState(now: Date = Date()) async throws -> StoredState {
        if let state = try currentState(), state.expiresAt.timeIntervalSince(now) > 60 {
            return state
        }
        if let refreshTask { return try await refreshTask.value }

        let task = Task { try await refreshState() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refreshState() async throws -> StoredState {
        if let existing = try currentState(), !existing.keyId.isEmpty {
            do {
                return try await assertExistingKey(existing.keyId)
            } catch {
                if Self.isInvalidKey(error) {
                    try Self.deleteStoredState()
                    cachedState = nil
                } else {
                    throw error
                }
            }
        }
        return try await attestNewKey()
    }

    private func attestNewKey() async throws -> StoredState {
        let keyId = try await service.generateKey()
        let challenge = try await fetchChallenge(keyId: keyId)
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.challenge.utf8)))
        let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
        let response: SessionResponse = try await postJSON(
            path: "/v1/app-attest/attest",
            body: AttestationRequest(
                keyId: keyId,
                challengeId: challenge.challengeId,
                challenge: challenge.challenge,
                attestationObject: attestation.base64EncodedString()
            )
        )
        return try save(response: response, keyId: keyId)
    }

    private func assertExistingKey(_ keyId: String) async throws -> StoredState {
        let challenge = try await fetchChallenge(keyId: keyId)
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.challenge.utf8)))
        let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
        let response: SessionResponse = try await postJSON(
            path: "/v1/app-attest/assert",
            body: AssertionRequest(
                keyId: keyId,
                challengeId: challenge.challengeId,
                challenge: challenge.challenge,
                assertionObject: assertion.base64EncodedString()
            )
        )
        return try save(response: response, keyId: keyId)
    }

    private func fetchChallenge(keyId: String) async throws -> ChallengeResponse {
        try await postJSON(
            path: "/v1/app-attest/challenge",
            body: ChallengeRequest(keyId: keyId)
        )
    }

    private func postJSON<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request
    ) async throws -> Response {
        guard let url = URL(string: baseURL + path) else { throw SessionError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SessionError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            throw SessionError.server(payload?.error.message ?? "实例身份验证失败")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func currentState() throws -> StoredState? {
        if let cachedState { return cachedState }
        let state = try Self.loadStoredState()
        cachedState = state
        return state
    }

    private func save(response: SessionResponse, keyId: String) throws -> StoredState {
        let state = StoredState(
            keyId: keyId,
            token: response.token,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(response.expiresAt))
        )
        try Self.saveStoredState(state)
        cachedState = state
        return state
    }

    private static func isInvalidKey(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == DCError.errorDomain
            && nsError.code == DCError.Code.invalidKey.rawValue
    }

    private static let keychainAccount = "com.holo.backend.app-attest-session"

    nonisolated private static func loadStoredState() throws -> StoredState? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SessionError.keychain(status)
        }
        return try JSONDecoder().decode(StoredState.self, from: data)
    }

    nonisolated private static func saveStoredState(_ state: StoredState) throws {
        try deleteStoredState()
        let data = try JSONEncoder().encode(state)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SessionError.keychain(status) }
    }

    nonisolated private static func deleteStoredState() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionError.keychain(status)
        }
    }
}

private extension HoloAppAttestSessionManager {
    struct StoredState: Codable {
        let keyId: String
        let token: String
        let expiresAt: Date
    }

    struct ChallengeRequest: Encodable { let keyId: String }
    struct ChallengeResponse: Decodable {
        let challengeId: String
        let challenge: String
    }
    struct AttestationRequest: Encodable {
        let keyId: String
        let challengeId: String
        let challenge: String
        let attestationObject: String
    }
    struct AssertionRequest: Encodable {
        let keyId: String
        let challengeId: String
        let challenge: String
        let assertionObject: String
    }
    struct SessionResponse: Decodable {
        let token: String
        let expiresAt: Int
    }
    struct ErrorEnvelope: Decodable {
        struct Payload: Decodable { let message: String }
        let error: Payload
    }

    enum SessionError: LocalizedError {
        case invalidURL
        case invalidResponse
        case server(String)
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "实例身份服务地址无效"
            case .invalidResponse: "实例身份服务响应无效"
            case .server(let message): message
            case .keychain(let status): "实例身份安全存储失败（\(status)）"
            }
        }
    }
}
