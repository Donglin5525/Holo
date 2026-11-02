//
//  DiscoveryClient.swift
//  Holo
//
//  「一个发现」八端点网络层（实施包 03 §3.1，契约对齐
//  HoloBackend/src/discovery/discoveryController.js）。
//  职责仅限传输与反序列化；控制代数/预算/撤权复核在 Coordinator 六检查位（02 §9.2、03 §5）。
//

import Foundation
import OSLog

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

    /// 个人档案通道：档案原文（带缓存，@MainActor 隔离读取）。
    /// 「一个发现」两阶段都携带——发现的措辞与建议取舍同受档案约束。
    private static func profileBrief() async -> String? {
        let raw = await MainActor.run { HoloProfileService.shared.loadProfile() }
        return raw.isEmpty ? nil : raw
    }

    // MARK: - 响应模型
    //
    // ⚠️ 契约纪律：以下每个模型必须与后端 controller 的 context.json 返回体逐字段一致
    // （真源=HoloBackend/src/discovery/discoveryController.js）；改任一端必须同步另一端
    // 与 DiscoveryContractTests（后端真实形状字面量对拍）。规范：docs/standards/跨端接口契约规范.md
    // （2026-10-28 事故：grant 被声明为 String 而后端返回对象，服务端开启成功、客户端误报失败。）

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

        enum CodingKeys: String, CodingKey {
            case protocolVersion, enabled, policyVersion, allowedDomains, budget
        }

        init(protocolVersion: Int, enabled: Bool, policyVersion: Int, allowedDomains: [String], budget: Budget) {
            self.protocolVersion = protocolVersion
            self.enabled = enabled
            self.policyVersion = policyVersion
            self.allowedDomains = allowedDomains
            self.budget = budget
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
            enabled = try values.decode(Bool.self, forKey: .enabled)
            // 服务端使用 v1/v2；保留数字版本的兼容，冻结与失效仍比较同一个版本号。
            if let number = try? values.decode(Int.self, forKey: .policyVersion), number > 0 {
                policyVersion = number
            } else {
                let raw = try values.decode(String.self, forKey: .policyVersion)
                let digits = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
                guard let number = Int(digits), number > 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .policyVersion, in: values,
                        debugDescription: "不支持的发现策略版本：\(raw)")
                }
                policyVersion = number
            }
            allowedDomains = try values.decode([String].self, forKey: .allowedDomains)
            budget = try values.decode(Budget.self, forKey: .budget)
        }
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
        /// 开启租约。形状真源 = 后端 discoveryControlStore.js enable() 的 grant
        /// （嵌套对象，2026-10-28 曾因声明为 String 解码必挂、开启被误报失败）。
        struct Grant: Decodable, Sendable {
            let deviceId: String
            let revision: Int
            let scopeRevision: Int
            let dayKey: String
            let leaseExpiresAt: Int
        }
        let grant: Grant?
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

    /// 1.1.5 候选异步作业状态（`candidates/async` 与 `candidates/result` 同一形状；
    /// 字面量逐字抄 HoloBackend/src/discovery/discoveryController.js `jobStatusResponse`）。
    /// 字段恒齐全，不适用为 null：running 带 pollAfterSeconds；completed 带 result（与同步
    /// `/candidates` 200 响应同形）；failed 带 error 与 retryAvailable（当天还有尝试次数）。
    struct CandidateJobStatus: Decodable, Sendable {
        enum JobState: String, Decodable, Sendable {
            case running
            case completed
            case failed
        }

        struct JobError: Decodable, Sendable {
            let code: String?
            let reason: String?
        }

        let runID: String
        let stage: String
        let jobStatus: JobState
        let pollAfterSeconds: Int?
        /// run 租约到期（毫秒时间戳）；过期后客户端放弃取件
        let leaseExpiresAt: Int64?
        let result: StageResponse?
        let error: JobError?
        let retryAvailable: Bool
        let replayed: Bool?
    }

    /// 一次取件的结果：completed 时附带经严格解码的候选信封（与同步 candidates() 同一道防线）。
    struct CandidateJobPoll: Sendable {
        let status: CandidateJobStatus
        let completed: (response: StageResponse, envelope: DiscoveryCandidateEnvelope)?
    }

    // MARK: - 错误

    enum DiscoveryClientError: Error, LocalizedError {
        case stageResultLost(runID: String)
        case controlConflict(detail: String)
        case hashMismatch
        case unexpectedStageEnvelope(runID: String)
        /// 服务端（或测试替身）不支持候选异步作业：调用方回落同步端点
        case asyncCandidatesUnsupported
        /// 候选作业在服务端失败；retryAvailable=服务端判定当天还有尝试次数（失败不烧名额）
        case candidateJobFailed(code: String?, retryAvailable: Bool)

        var errorDescription: String? {
            switch self {
            case .stageResultLost: return "发现批次结果已失效（服务端重启或缓存淘汰），本批终止，不重试模型"
            case .controlConflict(let detail): return "发现控制版本冲突，需刷新控制状态：\(detail)"
            case .hashMismatch: return "候选包与服务端响应不一致"
            case .unexpectedStageEnvelope: return "阶段响应格式不符"
            case .asyncCandidatesUnsupported: return "服务端未开放候选异步作业"
            case .candidateJobFailed(let code, _): return "候选作业失败：\(code ?? "unknown")"
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
        let body = StageBody(runToken: runToken, requestID: requestID, candidates: nil, candidatesHash: nil, data: data, profileBrief: await Self.profileBrief())
        let response: StageResponse = try await apiClient.send(request(
            path: "/v1/discovery/runs/\(runID)/candidates",
            body: body,
            timeout: 180
        ))
        return (response, try await Self.validatedCandidateEnvelope(response, runID: runID))
    }

    /// 1.1.5 阶段一（异步）：交材料即返回 running，服务端后台生成。请求体与同步 candidates() 逐字段相同
    /// （阶段 hash 只锚 data；profileBrief 平级不进 hash）。requestID 由调用方持久化复用，重交同 body 幂等。
    func startCandidatesAsync(runID: String, runToken: String, requestID: String?, data: DiscoveryJSONValue) async throws -> CandidateJobPoll {
        let body = StageBody(runToken: runToken, requestID: requestID, candidates: nil, candidatesHash: nil, data: data, profileBrief: await Self.profileBrief())
        let status: CandidateJobStatus = try await apiClient.send(request(
            path: "/v1/discovery/runs/\(runID)/candidates/async",
            body: body,
            timeout: 30
        ))
        return try await Self.poll(from: status, runID: runID)
    }

    /// 1.1.5 取件：POST 携带 runToken（不进 URL/访问日志）。作业不存在 → 404 DISCOVERY_JOB_NOT_FOUND。
    func candidatesResult(runID: String, runToken: String) async throws -> CandidateJobPoll {
        struct Body: Encodable {
            let runToken: String
        }
        let status: CandidateJobStatus = try await apiClient.send(request(
            path: "/v1/discovery/runs/\(runID)/candidates/result",
            body: Body(runToken: runToken),
            timeout: 30
        ))
        return try await Self.poll(from: status, runID: runID)
    }

    @MainActor
    private static func poll(from status: CandidateJobStatus, runID: String) throws -> CandidateJobPoll {
        guard status.runID == runID else {
            throw DiscoveryClientError.unexpectedStageEnvelope(runID: runID)
        }
        guard status.jobStatus == .completed else {
            return CandidateJobPoll(status: status, completed: nil)
        }
        guard let response = status.result else {
            throw DiscoveryClientError.unexpectedStageEnvelope(runID: runID)
        }
        return CandidateJobPoll(status: status, completed: (response, try validatedCandidateEnvelope(response, runID: runID)))
    }

    /// 候选信封严格解码（同步与异步取件共用同一道防线，不宽松解析）。
    @MainActor
    private static func validatedCandidateEnvelope(_ response: StageResponse, runID: String) throws -> DiscoveryCandidateEnvelope {
        do {
            return try DiscoveryAIPacket.decodeValidatedCandidateEnvelope(from: DiscoveryCanonicalJSON.data(from: response.envelope))
        } catch {
            // 2026-11-01 诊断保留（独立诊断报告问题1）：具体字段级错误不得吞掉——
            // notice 级进系统日志（配合 Coordinator 的 disp-diag.log 排查契约缝隙）
            Logger(subsystem: "com.holo.app", category: "Discovery")
                .notice("disp envelope rejected: stage=candidates run=\(runID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw DiscoveryClientError.unexpectedStageEnvelope(runID: runID)
        }
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
            data: data,
            profileBrief: await Self.profileBrief()
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
            // 2026-11-01 诊断保留（独立诊断报告问题1）：具体字段级错误不得吞掉——
            // notice 级进系统日志（配合 Coordinator 的 disp-diag.log 排查契约缝隙）
            Logger(subsystem: "com.holo.app", category: "Discovery")
                .notice("disp envelope rejected: stage=verify run=\(runID, privacy: .public) error=\(String(describing: error), privacy: .public)")
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
        /// 个人档案通道（2026-11-01）：档案原文与 data 平级上行（不进 data——发现幂等键
        /// 锚定环境数据，档案更新不应触发阶段 409）；后端注入指令级 system 消息。
        /// nil 时不编码该键。
        let profileBrief: String?
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
