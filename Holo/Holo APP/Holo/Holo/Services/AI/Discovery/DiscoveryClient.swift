//
//  DiscoveryClient.swift
//  Holo
//
//  「一个发现」八端点网络层（实施包 03 §3.1，契约对齐
//  HoloBackend/src/discovery/discoveryController.js）。
//  职责仅限传输与反序列化；控制代数/预算/撤权复核在 Coordinator 六检查位（02 §9.2、03 §5）。
//

import Foundation

nonisolated final class DiscoveryClient {

    private let apiClient: APIClient
    private let baseURL: String
    private let deviceIdProvider: () -> String

    init(
        apiClient: APIClient = .shared,
        baseURL: String = HoloBackendEnvironment.baseURL,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId }
    ) {
        self.apiClient = apiClient
        self.baseURL = baseURL
        self.deviceIdProvider = deviceIdProvider
    }

    // MARK: - 响应模型

    struct CapabilitiesResponse: Decodable, Sendable {
        let protocolVersion: Int
        let enabled: Bool
        let policyVersion: Int
        let allowedDomains: [String]
        struct Budget: Decodable, Sendable {
            let runsPerDay: Int
            let candidateMaxTokens: Int?
            let verifyMaxTokens: Int?
            let inputBudgetTokens: Int
        }
        let budget: Budget
    }

    struct ControlResponse: Decodable, Sendable {
        let enabled: Bool
        let revision: Int
        let ownerDeviceId: String?
        let scopeRevision: Int
        let allowedDomains: [String]
        let consentDocVersion: String?
    }

    struct EnableResponse: Decodable, Sendable {
        let enabled: Bool
        let revision: Int
        let scopeRevision: Int
        let allowedDomains: [String]
        let ownerDeviceId: String?
        let grant: String?
        let replayed: Bool?
    }

    struct DisableResponse: Decodable, Sendable {
        let enabled: Bool
        let revision: Int
        let scopeRevision: Int
        let replayed: Bool?
    }

    struct ScopeResponse: Decodable, Sendable {
        let enabled: Bool
        let revision: Int
        let scopeRevision: Int
        let allowedDomains: [String]
        let replayed: Bool?
    }

    struct CreateRunResponse: Decodable, Sendable {
        let runID: String
        let runToken: String
        let status: String
        let controlRevision: Int
        let scopeRevision: Int
        let dayKey: String
        let leaseExpiresAt: Int
        let leaseSeconds: Int
        struct StageBudget: Decodable, Sendable {
            let candidates: Int
            let verify: Int
        }
        let stageBudget: StageBudget
        let replayed: Bool?
    }

    struct StageUsage: Decodable, Sendable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
    }

    struct StageModelRoute: Decodable, Sendable {
        let provider: String?
        let model: String?
    }

    /// 阶段响应。envelope 保留无类型 JSON：candidates 需原样回显给 verify（hash 对齐），
    /// 语义校验由调用方用 DiscoveryAIPacket.decodeValidated* 二次把关（不信服务端校验为唯一防线）。
    struct StageResponse: Decodable, Sendable {
        let runID: String
        let stage: String
        let envelope: DiscoveryJSONValue
        let promptType: String?
        let promptVersion: Int?
        let model: StageModelRoute?
        let usage: StageUsage?
        let replayed: Bool?
        let candidatesHash: String?

        enum CodingKeys: String, CodingKey {
            case runID, stage, envelope, promptType, promptVersion, model, usage, replayed, candidatesHash
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            runID = try container.decode(String.self, forKey: .runID)
            stage = try container.decode(String.self, forKey: .stage)
            envelope = try container.decode(DiscoveryJSONValue.self, forKey: .envelope)
            promptType = try container.decodeIfPresent(String.self, forKey: .promptType)
            promptVersion = try container.decodeIfPresent(Int.self, forKey: .promptVersion)
            model = try container.decodeIfPresent(StageModelRoute.self, forKey: .model)
            usage = try container.decodeIfPresent(StageUsage.self, forKey: .usage)
            replayed = try container.decodeIfPresent(Bool.self, forKey: .replayed)
            candidatesHash = try container.decodeIfPresent(String.self, forKey: .candidatesHash)
        }
    }

    struct CancelResponse: Decodable, Sendable {
        let runID: String
        let status: String
        let alreadyClosed: Bool
    }

    // MARK: - 错误

    enum DiscoveryClientError: Error, LocalizedError {
        case stageResultLost(runID: String)
        case controlConflict(detail: String)
        case hashMismatch
        case unexpectedStageEnvelope(runID: String)

        var errorDescription: String? {
            switch self {
            case .stageResultLost: return "发现批次结果已失效（服务端重启或缓存淘汰），本批终止，不重试模型"
            case .controlConflict(let detail): return "发现控制版本冲突，需刷新控制状态：\(detail)"
            case .hashMismatch: return "候选包与服务端响应不一致"
            case .unexpectedStageEnvelope: return "阶段响应格式不符"
            }
        }
    }

    // MARK: - 端点

    func capabilities() async throws -> CapabilitiesResponse {
        try await apiClient.send(request(path: "/v1/discovery/capabilities"))
    }

    func control() async throws -> ControlResponse {
        try await apiClient.send(request(path: "/v1/discovery/control"))
    }

    func enable(
        expectedRevision: Int,
        allowedDomains: [String],
        consentDocVersion: String?,
        confirmTakeover: Bool,
        requestID: String
    ) async throws -> EnableResponse {
        struct Body: Encodable {
            let expectedRevision: Int
            let allowedDomains: [String]
            let consentDocVersion: String?
            let confirmTakeover: Bool
            let requestID: String
        }
        return try await apiClient.send(request(
            path: "/v1/discovery/control/enable",
            body: Body(
                expectedRevision: expectedRevision,
                allowedDomains: allowedDomains,
                consentDocVersion: consentDocVersion,
                confirmTakeover: confirmTakeover,
                requestID: requestID
            )
        ))
    }

    func disable(requestID: String, reason: String?) async throws -> DisableResponse {
        struct Body: Encodable {
            let requestID: String
            let reason: String?
        }
        return try await apiClient.send(request(
            path: "/v1/discovery/control/disable",
            body: Body(requestID: requestID, reason: reason)
        ))
    }

    func updateScope(
        expectedRevision: Int,
        allowedDomains: [String],
        consentDocVersion: String?,
        requestID: String
    ) async throws -> ScopeResponse {
        struct Body: Encodable {
            let expectedRevision: Int
            let allowedDomains: [String]
            let consentDocVersion: String?
            let requestID: String
        }
        return try await apiClient.send(request(
            path: "/v1/discovery/control/scope",
            body: Body(
                expectedRevision: expectedRevision,
                allowedDomains: allowedDomains,
                consentDocVersion: consentDocVersion,
                requestID: requestID
            )
        ))
    }

    func createRun(
        runID: String,
        sourceManifestDigest: String?,
        requestID: String?
    ) async throws -> CreateRunResponse {
        struct Body: Encodable {
            let runID: String
            let sourceManifestDigest: String?
            let requestID: String?
        }
        return try await apiClient.send(request(
            path: "/v1/discovery/runs",
            body: Body(runID: runID, sourceManifestDigest: sourceManifestDigest, requestID: requestID)
        ))
    }

    /// 阶段一：候选生成。data 为结构化输入（evidence/coverage/computedFacts…，05 §2.1 形态）。
    /// 返回值附带解码后的严格信封；校验失败按本批终止处理，不宽松解析。
    func candidates(runID: String, runToken: String, requestID: String?, data: DiscoveryJSONValue) async throws -> (response: StageResponse, envelope: DiscoveryCandidateEnvelope) {
        let body = StageBody(runToken: runToken, requestID: requestID, candidates: nil, candidatesHash: nil, data: data)
        let response: StageResponse = try await apiClient.send(request(
            path: "/v1/discovery/runs/\(runID)/candidates",
            body: body,
            timeout: 180
        ))
        let envelope: DiscoveryCandidateEnvelope
        do {
            envelope = try DiscoveryAIPacket.decodeValidatedCandidateEnvelope(from: DiscoveryCanonicalJSON.data(from: response.envelope))
        } catch {
            throw DiscoveryClientError.unexpectedStageEnvelope(runID: runID)
        }
        return (response, envelope)
    }

    /// 阶段二：独立核验。candidates 必须是阶段一响应 envelope.candidates 的**原样无类型值**
    /// （字节级回显，hash 双端一致，T34）。data 为核验输入（冻结候选+支持/反例+覆盖）。
    func verify(
        runID: String,
        runToken: String,
        requestID: String?,
        candidates: DiscoveryJSONValue,
        data: DiscoveryJSONValue
    ) async throws -> (response: StageResponse, envelope: DiscoveryVerificationEnvelope) {
        guard case .array(let items) = candidates else {
            throw DiscoveryClientError.hashMismatch
        }
        let hash = DiscoveryCanonicalJSON.canonicalSha256(.array(items))
        let body = StageBody(
            runToken: runToken,
            requestID: requestID,
            candidates: candidates,
            candidatesHash: hash,
            data: data
        )
        let response: StageResponse = try await apiClient.send(request(
            path: "/v1/discovery/runs/\(runID)/verify",
            body: body,
            timeout: 180
        ))
        let envelope: DiscoveryVerificationEnvelope
        do {
            envelope = try DiscoveryAIPacket.decodeValidatedVerificationEnvelope(from: DiscoveryCanonicalJSON.data(from: response.envelope))
        } catch {
            throw DiscoveryClientError.unexpectedStageEnvelope(runID: runID)
        }
        return (response, envelope)
    }

    func cancel(runID: String, requestID: String) async throws -> CancelResponse {
        struct Body: Encodable {
            let requestID: String
        }
        return try await apiClient.send(request(
            path: "/v1/discovery/runs/\(runID)/cancel",
            body: Body(requestID: requestID)
        ))
    }

    // MARK: - 组装

    private struct StageBody: Encodable {
        let runToken: String
        let requestID: String?
        let candidates: DiscoveryJSONValue?
        let candidatesHash: String?
        let data: DiscoveryJSONValue
    }

    private func request(
        path: String,
        body: (any Encodable)? = nil,
        timeout: TimeInterval? = nil
    ) -> APIRequest {
        var headers = ["X-Holo-Device-Id": deviceIdProvider()]
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        return APIRequest(
            baseURL: baseURL,
            path: path,
            method: body == nil ? .get : .post,
            headers: headers,
            body: body,
            timeoutInterval: timeout
        )
    }
}

// MARK: - DiscoveryJSONValue 传输支持

extension DiscoveryJSONValue: Encodable, Decodable {
    private struct CodingKeys: CodingKey {
        let stringValue: String
        let intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let pairs):
            var keyed = encoder.container(keyedBy: CodingKeys.self)
            for (key, value) in pairs {
                try keyed.encode(value, forKey: CodingKeys(stringValue: key))
            }
        default:
            var container = encoder.singleValueContainer()
            switch self {
            case .null:
                try container.encodeNil()
            case .bool(let bool):
                try container.encode(bool)
            case .number(let number):
                switch number {
                case .int(let value): try container.encode(value)
                case .double(let value): try container.encode(value)
                }
            case .string(let string):
                try container.encode(string)
            case .array(let items):
                try container.encode(items)
            case .object:
                fatalError("unreachable：object 已在上层分支处理")
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int64.self) {
            self = .number(.int(int))
        } else if let double = try? container.decode(Double.self) {
            self = .number(.double(double))
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let items = try? container.decode([DiscoveryJSONValue].self) {
            self = .array(items)
        } else {
            let pairs = try container.decode([String: DiscoveryJSONValue].self)
            self = .object(pairs.map { ($0.key, $0.value) })
        }
    }
}

extension DiscoveryCanonicalJSON {
    /// 无类型值 → JSON Data（编码用，键序不重要——服务端按 canonical 规则重新解析）。
    static func data(from value: DiscoveryJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(value)
    }
}
