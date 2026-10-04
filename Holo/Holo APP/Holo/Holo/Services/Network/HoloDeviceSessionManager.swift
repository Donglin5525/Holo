//
//  HoloDeviceSessionManager.swift
//  Holo
//
//  设备会话（2026-10-04 体检 S01）：把设备编号从「自报身份」升级为「持钥证明」。
//
//  首装生成 Ed25519 密钥对（私钥存 Keychain 不出设备），向後端出示
//  「设备号 + 公钥 + 对一次性挑战的签名」换短效设备会话 JWT；请求头由
//  APIClient 统一注入，服务端 enforceDeviceSession 开启后设备路由凭此放行。
//  后端未部署会话端点（旧版本）或网络失败时静默降级——只带设备号头，
//  并进入冷却期避免每个请求都空跑两次往返。
//

import CryptoKit
import Foundation
import os.log

nonisolated final class HoloDeviceSessionManager {

    static let shared = HoloDeviceSessionManager()

    private let logger = Logger(subsystem: "com.holo.app", category: "DeviceSession")

    private static let keychainAccount = "com.holo.device.session.ed25519"
    private static let bindingPrefix = "holo-device-bind:v1:"
    /// 会话到期提前量：到期前 5 分钟即视为过期，避免边界上发出将失效的会话
    private static let expiryLead: TimeInterval = 300
    /// 获取失败冷却期（旧后端 404 / 网络不可达时，避免每请求空跑）
    private static let failureCooldown: TimeInterval = 1800

    private struct CachedSession {
        let deviceId: String
        let token: String
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var cachedSession: CachedSession?
    private var cooldownUntil: Date?
    /// 并发去重：同时多个请求冷启动时只发一次会话获取
    private var inflight: Task<(token: String, expiresAt: Date), Error>?

    private let baseURL: String
    private let urlSession: URLSession

    init(baseURL: String = HoloBackendEnvironment.baseURL,
         urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    // MARK: - 对外接口

    /// 后端请求统一注入设备会话头（S01，APIClient 与各直连 URLSession 服务共用）。
    /// 已有 Authorization 的请求（内部诊断用户会话等）不覆盖；非后端域名的请求不动；
    /// 会话不可用时静默跳过——强制开关关闭期请求照常工作，开启期由 401 刷新重试兜底。
    func attachAuthorization(to request: inout URLRequest) async {
        guard request.value(forHTTPHeaderField: "Authorization") == nil,
              request.url?.host == URL(string: baseURL)?.host else { return }
        let deviceId = HoloBackendDeviceIdentity.shared.deviceId
        if let header = await authorizationHeader(deviceId: deviceId) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
    }

    /// 设备会话请求头（Bearer …）。无可用会话时返回 nil——请求照常发出（仅设备号头），
    /// 服务端强制开关开启且拿到 401 时由 APIClient 触发刷新重试。
    func authorizationHeader(deviceId: String) async -> String? {
        if let header = cachedHeader(deviceId: deviceId) { return header }
        guard let token = try? await ensureSession(deviceId: deviceId) else { return nil }
        return "Bearer \(token)"
    }

    /// 服务端拒绝会话（401 设备会话类错误码）后调用：清缓存清冷却，下次立即重取
    func invalidate() {
        lock.lock()
        cachedSession = nil
        cooldownUntil = nil
        inflight = nil
        lock.unlock()
    }

    /// 启动预热：提前把会话拿到手，首个业务请求不必等待两次往返
    func warmUp() {
        let deviceId = HoloBackendDeviceIdentity.shared.deviceId
        Task {
            _ = await authorizationHeader(deviceId: deviceId)
        }
    }

    // MARK: - 会话获取

    private func cachedHeader(deviceId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = cachedSession,
              session.deviceId == deviceId,
              session.expiresAt.timeIntervalSinceNow > Self.expiryLead else { return nil }
        return "Bearer \(session.token)"
    }

    private func ensureSession(deviceId: String) async throws -> String {
        lock.lock()
        if let until = cooldownUntil, until > Date() {
            lock.unlock()
            throw APIError.networkUnavailable
        }
        if let inflight {
            lock.unlock()
            return try await inflight.value.token
        }
        let task = Task { [baseURL, urlSession] in
            try await Self.fetchSession(baseURL: baseURL, urlSession: urlSession, deviceId: deviceId)
        }
        inflight = task
        lock.unlock()

        defer {
            lock.lock()
            inflight = nil
            lock.unlock()
        }

        do {
            let (token, expiresAt) = try await task.value
            lock.lock()
            cachedSession = CachedSession(deviceId: deviceId, token: token, expiresAt: expiresAt)
            cooldownUntil = nil
            lock.unlock()
            return token
        } catch {
            lock.lock()
            cooldownUntil = Date().addingTimeInterval(Self.failureCooldown)
            lock.unlock()
            logger.warning("设备会话获取失败，进入冷却：\(error.localizedDescription)")
            throw error
        }
    }    /// 挑战 → 签名 → 会话，两段往返；任何一段失败即抛错（调用方进冷却）。
    /// 主体一致性由服务端在使用时强制（getDeviceId 比对会话主体与设备号头），
    /// 客户端不重复解码校验 JWT。
    private static func fetchSession(baseURL: String, urlSession: URLSession, deviceId: String) async throws -> (token: String, expiresAt: Date) {
        guard let sessionURL = URL(string: baseURL)?.appendingPathComponent("v1/auth/device/session") else {
            throw APIError.invalidURL
        }

        let privateKey = try devicePrivateKey()
        let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()

        // 1) 一次性挑战
        var challengeRequest = URLRequest(url: sessionURL.deletingLastPathComponent().appendingPathComponent("challenge"))
        challengeRequest.httpMethod = "POST"
        challengeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        challengeRequest.httpBody = Data("{}".utf8)
        let (challengeData, challengeResponse) = try await urlSession.data(for: challengeRequest)
        guard let challengeHTTP = challengeResponse as? HTTPURLResponse, challengeHTTP.statusCode == 200 else {
            throw APIError.httpError(statusCode: (challengeResponse as? HTTPURLResponse)?.statusCode ?? 0,
                                     message: "设备会话挑战不可用")
        }
        struct ChallengeResponse: Decodable { let challenge: String }
        let challenge = try JSONDecoder().decode(ChallengeResponse.self, from: challengeData).challenge

        // 2) 绑定签名换会话
        let payload = Data("\(bindingPrefix)\(deviceId):\(challenge)".utf8)
        let signature = try privateKey.signature(for: payload).base64EncodedString()

        var sessionRequest = URLRequest(url: sessionURL)
        sessionRequest.httpMethod = "POST"
        sessionRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sessionRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "deviceId": deviceId,
            "publicKey": publicKeyBase64,
            "signature": signature,
            "challenge": challenge,
        ])
        let (sessionData, sessionResponse) = try await urlSession.data(for: sessionRequest)
        guard let sessionHTTP = sessionResponse as? HTTPURLResponse, sessionHTTP.statusCode == 200 else {
            throw APIError.httpError(statusCode: (sessionResponse as? HTTPURLResponse)?.statusCode ?? 0,
                                     message: "设备会话签发失败")
        }
        struct TokenResponse: Decodable {
            let token: String
            let expiresAt: Double
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: sessionData)
        return (decoded.token, Date(timeIntervalSince1970: decoded.expiresAt))
    }

    // MARK: - 密钥管理（Keychain 持久，卸载重装存活）

    private static func devicePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        if let existing = loadPrivateKeyFromKeychain() { return existing }
        let created = Curve25519.Signing.PrivateKey()
        savePrivateKeyToKeychain(created)
        return created
    }

    private static func loadPrivateKeyFromKeychain() -> Curve25519.Signing.PrivateKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { return nil }
        return key
    }

    private static func savePrivateKeyToKeychain(_ key: Curve25519.Signing.PrivateKey) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
    }
}
