//
//  HoloMemoryDecisionPolicy.swift
//  Holo
//
//  记忆低确认成本方案（2026-09-16）五路决策契约与元数据。
//
//  P0 仅冻结数据契约：枚举取值、decision metadata v2 与容错解码。
//  五路裁决逻辑在 P2 落地到本文件；落地前全库不得出现第二个最终裁决者。
//  方案：docs/_common/plans/2026-09-16-Holo记忆萃取低确认成本产品设计方案.md §5/§6/§10
//

import Foundation

// MARK: - 容错枚举基建

/// 所有 decision metadata 枚举的统一纪律：未知原始值原样保留为 `.unrecognized`，
/// 不丢数据、不猜语义；消费端必须按保守策略处理（方案 §10.2 约束）。
/// 「属性 optional」不等于枚举前向兼容，因此这里统一走显式容错解码。
private protocol HoloMemoryTolerantEnumValue: Equatable, Sendable {
    var rawValue: String { get }
    static var knownCases: [Self] { get }
    static func unrecognized(_ raw: String) -> Self
}

private enum HoloMemoryTolerantEnumCodec {
    static func decode<T: HoloMemoryTolerantEnumValue>(
        _ type: T.Type,
        from decoder: Decoder
    ) throws -> T {
        let raw = try decoder.singleValueContainer().decode(String.self)
        return type.knownCases.first { $0.rawValue == raw } ?? type.unrecognized(raw)
    }
}

// MARK: - 来源权威性（§6.1）

/// 由程序从来源与证据类型计算，不由模型自行声称。
nonisolated enum HoloMemorySourceAuthority: Equatable, Sendable {
    case explicitMemoryRequest
    case explicitUserStatement
    case structuredObservation
    case repeatedIndependentEvidence
    case modelInference
    case unknownSource
    case unrecognized(String)

    var rawValue: String {
        switch self {
        case .explicitMemoryRequest: return "explicitMemoryRequest"
        case .explicitUserStatement: return "explicitUserStatement"
        case .structuredObservation: return "structuredObservation"
        case .repeatedIndependentEvidence: return "repeatedIndependentEvidence"
        case .modelInference: return "modelInference"
        case .unknownSource: return "unknownSource"
        case .unrecognized(let raw): return raw
        }
    }

    static let knownCases: [HoloMemorySourceAuthority] = [
        .explicitMemoryRequest,
        .explicitUserStatement,
        .structuredObservation,
        .repeatedIndependentEvidence,
        .modelInference,
        .unknownSource,
    ]
}

extension HoloMemorySourceAuthority: Codable, HoloMemoryTolerantEnumValue {
    init(from decoder: Decoder) throws {
        self = try HoloMemoryTolerantEnumCodec.decode(Self.self, from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 证据核验（§6.2）

/// 沿用个人情境 verification 已有离散结果，不引入模型数值置信度。
/// 与 HoloContextVerificationVerdict.Verdict 的映射由 P2 决策器负责。
nonisolated enum HoloMemoryEvidenceVerdict: Equatable, Sendable {
    case supported
    case qualified
    case insufficient
    case contradicted
    case unsupported
    case unreviewed
    case unrecognized(String)

    var rawValue: String {
        switch self {
        case .supported: return "supported"
        case .qualified: return "qualified"
        case .insufficient: return "insufficient"
        case .contradicted: return "contradicted"
        case .unsupported: return "unsupported"
        case .unreviewed: return "unreviewed"
        case .unrecognized(let raw): return raw
        }
    }

    static let knownCases: [HoloMemoryEvidenceVerdict] = [
        .supported, .qualified, .insufficient, .contradicted, .unsupported, .unreviewed,
    ]
}

extension HoloMemoryEvidenceVerdict: Codable, HoloMemoryTolerantEnumValue {
    init(from decoder: Decoder) throws {
        self = try HoloMemoryTolerantEnumCodec.decode(Self.self, from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 错误影响（§6.3）

nonisolated enum HoloMemoryDecisionImpactLevel: Equatable, Sendable {
    case low
    case medium
    case high
    case unrecognized(String)

    var rawValue: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .unrecognized(let raw): return raw
        }
    }

    static let knownCases: [HoloMemoryDecisionImpactLevel] = [.low, .medium, .high]
}

extension HoloMemoryDecisionImpactLevel: Codable, HoloMemoryTolerantEnumValue {
    init(from decoder: Decoder) throws {
        self = try HoloMemoryTolerantEnumCodec.decode(Self.self, from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 持久化权限（§5.1 / ADR-5）

/// 只表达「派生长期记忆」的保存权，不替代原始业务数据自身的权限。
nonisolated enum HoloMemoryPersistencePermission: Equatable, Sendable {
    case durable
    case sourceScoped
    case sessionOnly
    case blocked
    case unrecognized(String)

    var rawValue: String {
        switch self {
        case .durable: return "durable"
        case .sourceScoped: return "sourceScoped"
        case .sessionOnly: return "sessionOnly"
        case .blocked: return "blocked"
        case .unrecognized(let raw): return raw
        }
    }

    static let knownCases: [HoloMemoryPersistencePermission] = [
        .durable, .sourceScoped, .sessionOnly, .blocked,
    ]
}

extension HoloMemoryPersistencePermission: Codable, HoloMemoryTolerantEnumValue {
    init(from decoder: Decoder) throws {
        self = try HoloMemoryTolerantEnumCodec.decode(Self.self, from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 使用权限（§5.1 / §11.2）

nonisolated enum HoloMemoryUseLevel: Equatable, Sendable {
    case factEligible
    case qualifiedAdvice
    case observeOnly
    case blocked
    case unrecognized(String)

    var rawValue: String {
        switch self {
        case .factEligible: return "factEligible"
        case .qualifiedAdvice: return "qualifiedAdvice"
        case .observeOnly: return "observeOnly"
        case .blocked: return "blocked"
        case .unrecognized(let raw): return raw
        }
    }

    static let knownCases: [HoloMemoryUseLevel] = [
        .factEligible, .qualifiedAdvice, .observeOnly, .blocked,
    ]
}

extension HoloMemoryUseLevel: Codable, HoloMemoryTolerantEnumValue {
    init(from decoder: Decoder) throws {
        self = try HoloMemoryTolerantEnumCodec.decode(Self.self, from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 打扰策略（§5.1 / §11.3）

/// 所有 UI 判断「是否需要用户处理」的唯一入口输入；禁止再用 `state == candidate` 单独判断。
nonisolated enum HoloMemoryAttentionPolicyKind: Equatable, Sendable {
    case silent
    case askWhenRelevant
    case neverAsk
    case unrecognized(String)

    var rawValue: String {
        switch self {
        case .silent: return "silent"
        case .askWhenRelevant: return "askWhenRelevant"
        case .neverAsk: return "neverAsk"
        case .unrecognized(let raw): return raw
        }
    }

    static let knownCases: [HoloMemoryAttentionPolicyKind] = [.silent, .askWhenRelevant, .neverAsk]
}

extension HoloMemoryAttentionPolicyKind: Codable, HoloMemoryTolerantEnumValue {
    init(from decoder: Decoder) throws {
        self = try HoloMemoryTolerantEnumCodec.decode(Self.self, from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 决策理由（§7.3 / §15.3）

/// 仅枚举与 metadata，不记录用户原文。
nonisolated enum HoloMemoryDecisionReason: Equatable, Sendable {
    case structureInvalid
    case evidenceUntraceable
    case prohibitedInference
    case userRejectedOrForgotten
    case explicitlyRequestedMemory
    case unsupportedClaim
    case awaitingEvidence
    case unresolvedConflict
    case derivedPersistenceNotAuthorized
    case declaredStatementAccepted
    case boundedStructuredFact
    case qualifiedInferenceOnly
    case repeatedEvidencePromoted
    case highImpactBlockedPendingClarification
    case conservativeDowngrade
    case legacyRecordWithoutMetadata
    case staleOrExpired
    case temporaryScopeNarrowed
    case unrecognized(String)

    var rawValue: String {
        switch self {
        case .structureInvalid: return "structureInvalid"
        case .evidenceUntraceable: return "evidenceUntraceable"
        case .prohibitedInference: return "prohibitedInference"
        case .userRejectedOrForgotten: return "userRejectedOrForgotten"
        case .explicitlyRequestedMemory: return "explicitlyRequestedMemory"
        case .unsupportedClaim: return "unsupportedClaim"
        case .awaitingEvidence: return "awaitingEvidence"
        case .unresolvedConflict: return "unresolvedConflict"
        case .derivedPersistenceNotAuthorized: return "derivedPersistenceNotAuthorized"
        case .declaredStatementAccepted: return "declaredStatementAccepted"
        case .boundedStructuredFact: return "boundedStructuredFact"
        case .qualifiedInferenceOnly: return "qualifiedInferenceOnly"
        case .repeatedEvidencePromoted: return "repeatedEvidencePromoted"
        case .highImpactBlockedPendingClarification: return "highImpactBlockedPendingClarification"
        case .conservativeDowngrade: return "conservativeDowngrade"
        case .legacyRecordWithoutMetadata: return "legacyRecordWithoutMetadata"
        case .staleOrExpired: return "staleOrExpired"
        case .temporaryScopeNarrowed: return "temporaryScopeNarrowed"
        case .unrecognized(let raw): return raw
        }
    }

    static let knownCases: [HoloMemoryDecisionReason] = [
        .structureInvalid,
        .evidenceUntraceable,
        .prohibitedInference,
        .userRejectedOrForgotten,
        .explicitlyRequestedMemory,
        .unsupportedClaim,
        .awaitingEvidence,
        .unresolvedConflict,
        .derivedPersistenceNotAuthorized,
        .declaredStatementAccepted,
        .boundedStructuredFact,
        .qualifiedInferenceOnly,
        .repeatedEvidencePromoted,
        .highImpactBlockedPendingClarification,
        .conservativeDowngrade,
        .legacyRecordWithoutMetadata,
        .staleOrExpired,
        .temporaryScopeNarrowed,
    ]
}

extension HoloMemoryDecisionReason: Codable, HoloMemoryTolerantEnumValue {
    init(from decoder: Decoder) throws {
        self = try HoloMemoryTolerantEnumCodec.decode(Self.self, from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 五路决策结果（§5）

nonisolated enum HoloMemoryFiveWayRoute: Equatable, Sendable {
    case factEligible
    case qualifiedAdvice
    case observeOnly
    case askWhenRelevant
    case discard

    /// 是否允许进入任何使用通道（事实召回或限定建议）。
    var usable: Bool {
        switch self {
        case .factEligible, .qualifiedAdvice: return true
        case .observeOnly, .askWhenRelevant, .discard: return false
        }
    }

    /// 是否允许打扰用户（askWhenRelevant 仅在相关场景问一次）。
    var mayDisturb: Bool {
        self == .askWhenRelevant
    }
}

// MARK: - 按需澄清元数据（§8.4 / §10.2）

nonisolated struct HoloMemoryClarificationMetadata: Codable, Equatable, Sendable {
    /// 由主体、关系、适用范围、缺失变量的规范化签名生成，不能使用显示文案。
    var logicalQuestionKey: String
    var missingVariable: String
    var impactSummary: String
    var options: [String]
    var lastPromptedAt: Date?
    var cooldownUntil: Date?
    var promptCount: Int
    var materialEvidenceRevisionAtLastPrompt: String?

    init(
        logicalQuestionKey: String,
        missingVariable: String,
        impactSummary: String,
        options: [String] = [],
        lastPromptedAt: Date? = nil,
        cooldownUntil: Date? = nil,
        promptCount: Int = 0,
        materialEvidenceRevisionAtLastPrompt: String? = nil
    ) {
        self.logicalQuestionKey = logicalQuestionKey
        self.missingVariable = missingVariable
        self.impactSummary = impactSummary
        self.options = options
        self.lastPromptedAt = lastPromptedAt
        self.cooldownUntil = cooldownUntil
        self.promptCount = promptCount
        self.materialEvidenceRevisionAtLastPrompt = materialEvidenceRevisionAtLastPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case logicalQuestionKey, missingVariable, impactSummary, options
        case lastPromptedAt, cooldownUntil, promptCount
        case materialEvidenceRevisionAtLastPrompt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logicalQuestionKey = try c.decodeIfPresent(String.self, forKey: .logicalQuestionKey) ?? ""
        missingVariable = try c.decodeIfPresent(String.self, forKey: .missingVariable) ?? ""
        impactSummary = try c.decodeIfPresent(String.self, forKey: .impactSummary) ?? ""
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        lastPromptedAt = try c.decodeIfPresent(Date.self, forKey: .lastPromptedAt)
        cooldownUntil = try c.decodeIfPresent(Date.self, forKey: .cooldownUntil)
        promptCount = try c.decodeIfPresent(Int.self, forKey: .promptCount) ?? 0
        materialEvidenceRevisionAtLastPrompt = try c.decodeIfPresent(
            String.self,
            forKey: .materialEvidenceRevisionAtLastPrompt
        )
    }
}

// MARK: - 决策元数据 v2（§10.2）

nonisolated struct HoloMemoryDecisionMetadataV2: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 2

    var schemaVersion: Int
    /// 首版五路决策策略版本（方案 §14：memory decision policy v4）。
    var policyVersion: Int
    var sourceAuthority: HoloMemorySourceAuthority
    var evidenceVerdict: HoloMemoryEvidenceVerdict
    var impactLevel: HoloMemoryDecisionImpactLevel
    var persistencePermission: HoloMemoryPersistencePermission
    var useLevel: HoloMemoryUseLevel
    var attentionPolicy: HoloMemoryAttentionPolicyKind
    var reasonCodes: [HoloMemoryDecisionReason]
    var evaluatedAt: Date
    var evidenceRevision: String
    var clarification: HoloMemoryClarificationMetadata?

    init(
        schemaVersion: Int = HoloMemoryDecisionMetadataV2.supportedSchemaVersion,
        policyVersion: Int,
        sourceAuthority: HoloMemorySourceAuthority,
        evidenceVerdict: HoloMemoryEvidenceVerdict,
        impactLevel: HoloMemoryDecisionImpactLevel,
        persistencePermission: HoloMemoryPersistencePermission,
        useLevel: HoloMemoryUseLevel,
        attentionPolicy: HoloMemoryAttentionPolicyKind,
        reasonCodes: [HoloMemoryDecisionReason] = [],
        evaluatedAt: Date,
        evidenceRevision: String,
        clarification: HoloMemoryClarificationMetadata? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
        self.sourceAuthority = sourceAuthority
        self.evidenceVerdict = evidenceVerdict
        self.impactLevel = impactLevel
        self.persistencePermission = persistencePermission
        self.useLevel = useLevel
        self.attentionPolicy = attentionPolicy
        self.reasonCodes = reasonCodes
        self.evaluatedAt = evaluatedAt
        self.evidenceRevision = evidenceRevision
        self.clarification = clarification
    }

    /// 任一字段是未知值即视为不可靠；消费端必须整体降级为 blocked/observeOnly（方案 §10.2）。
    var isReliablyDecoded: Bool {
        sourceAuthoritySourceKnown && verdictKnown && impactKnown
            && persistenceKnown && useLevelKnown && attentionKnown
            && reasonCodes.allSatisfy { reasonKnown($0) }
    }

    private var sourceAuthoritySourceKnown: Bool {
        if case .unrecognized = sourceAuthority { return false }
        return true
    }

    private var verdictKnown: Bool {
        if case .unrecognized = evidenceVerdict { return false }
        return true
    }

    private var impactKnown: Bool {
        if case .unrecognized = impactLevel { return false }
        return true
    }

    private var persistenceKnown: Bool {
        if case .unrecognized = persistencePermission { return false }
        return true
    }

    private var useLevelKnown: Bool {
        if case .unrecognized = useLevel { return false }
        return true
    }

    private var attentionKnown: Bool {
        if case .unrecognized = attentionPolicy { return false }
        return true
    }

    private func reasonKnown(_ reason: HoloMemoryDecisionReason) -> Bool {
        if case .unrecognized = reason { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, policyVersion, sourceAuthority, evidenceVerdict, impactLevel
        case persistencePermission, useLevel, attentionPolicy, reasonCodes
        case evaluatedAt, evidenceRevision, clarification
    }

    /// 缺 key 一律落到保守值：字段缺失必须导致更保守，而不是更开放（方案 §10.3）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.supportedSchemaVersion
        policyVersion = try c.decodeIfPresent(Int.self, forKey: .policyVersion) ?? 0
        sourceAuthority = try c.decodeIfPresent(
            HoloMemorySourceAuthority.self,
            forKey: .sourceAuthority
        ) ?? .unknownSource
        evidenceVerdict = try c.decodeIfPresent(
            HoloMemoryEvidenceVerdict.self,
            forKey: .evidenceVerdict
        ) ?? .unreviewed
        impactLevel = try c.decodeIfPresent(
            HoloMemoryDecisionImpactLevel.self,
            forKey: .impactLevel
        ) ?? .medium
        persistencePermission = try c.decodeIfPresent(
            HoloMemoryPersistencePermission.self,
            forKey: .persistencePermission
        ) ?? .blocked
        useLevel = try c.decodeIfPresent(HoloMemoryUseLevel.self, forKey: .useLevel) ?? .blocked
        attentionPolicy = try c.decodeIfPresent(
            HoloMemoryAttentionPolicyKind.self,
            forKey: .attentionPolicy
        ) ?? .silent
        reasonCodes = try c.decodeIfPresent(
            [HoloMemoryDecisionReason].self,
            forKey: .reasonCodes
        ) ?? [.conservativeDowngrade]
        evaluatedAt = try c.decodeIfPresent(Date.self, forKey: .evaluatedAt)
            ?? Date(timeIntervalSince1970: 0)
        evidenceRevision = try c.decodeIfPresent(String.self, forKey: .evidenceRevision) ?? ""
        clarification = try c.decodeIfPresent(
            HoloMemoryClarificationMetadata.self,
            forKey: .clarification
        )
    }
}

/// 任意 JSON 的无损捕获（仅用于未知版本载荷原样保留），本文件私有，避免 MemoryCore 反向依赖个人情境模型。
private enum HoloMemoryOpaqueJSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HoloMemoryOpaqueJSONValue])
    case object([String: HoloMemoryOpaqueJSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([HoloMemoryOpaqueJSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: HoloMemoryOpaqueJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// decision metadata 的容错信封：未知 schemaVersion 原样保留、不降为 nil 覆盖。
/// 与 HoloPersonalContextPayloadEnvelope 同型；recordData 中的挂载字段在 P2 接入。
nonisolated struct HoloMemoryDecisionMetadataEnvelope: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = HoloMemoryDecisionMetadataV2.supportedSchemaVersion
    static let opaquePayloadKey = "holoOpaqueDecision"

    var schemaVersion: Int
    /// 已支持版本的解析结果；未知/无法解析时为 nil。
    var v2: HoloMemoryDecisionMetadataV2?
    private var opaquePayloadJSON: String?

    init(v2: HoloMemoryDecisionMetadataV2) {
        schemaVersion = v2.schemaVersion
        self.v2 = v2
        opaquePayloadJSON = nil
    }

    init(unknownVersion: Int, rawJSON: String) {
        schemaVersion = unknownVersion
        v2 = nil
        opaquePayloadJSON = rawJSON
    }

    /// 新端是否可把它当结构化决策结果使用。
    var isReadable: Bool { v2 != nil }

    /// 未知版本载荷的原始 JSON（诊断与无损迁移用）。
    var unknownPayloadJSON: String? { opaquePayloadJSON }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case opaquePayload = "holoOpaqueDecision"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        let preservedOpaque = try? c.decodeIfPresent(String.self, forKey: .opaquePayload)
        if version == Self.supportedSchemaVersion,
           let payload = try? HoloMemoryDecisionMetadataV2(from: decoder),
           preservedOpaque == nil {
            schemaVersion = version
            v2 = payload
            opaquePayloadJSON = nil
            return
        }
        schemaVersion = version
        v2 = nil
        if let preserved = try c.decodeIfPresent(String.self, forKey: .opaquePayload) {
            opaquePayloadJSON = preserved
        } else if let captured = try? HoloMemoryOpaqueJSONValue(from: decoder),
                  let data = try? JSONEncoder().encode(captured) {
            opaquePayloadJSON = String(decoding: data, as: UTF8.self)
        } else {
            opaquePayloadJSON = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        if let v2 {
            try v2.encode(to: encoder)
        } else if let opaquePayloadJSON {
            try c.encode(opaquePayloadJSON, forKey: .opaquePayload)
        }
    }
}

// MARK: - 五路决策输入推导（§6）
//
// 全部由程序从记录现有字段计算：模型与旧 admission 不参与最终裁决
//（admission 只作为核验结论的投影输入）。无法稳定推导的信号（明确记忆请求、
// 假设/引用语气）按保守路径处理，不用自由文本猜测补齐（方案 §13.1 门禁）。

nonisolated struct HoloMemoryDecisionInput: Equatable, Sendable {
    var sourceAuthority: HoloMemorySourceAuthority
    var evidenceVerdict: HoloMemoryEvidenceVerdict
    var impactLevel: HoloMemoryDecisionImpactLevel
    var persistencePermission: HoloMemoryPersistencePermission
    var hasUnresolvedConflict: Bool
    var isExpired: Bool
    /// 「今晚/这次」类一次性事件范围：默认最窄适用，不得推成永久偏好（§6.1 门禁 6）。
    var isTemporaryEventScope: Bool
    /// 结构化命题是否带时间边界（有界事实才可自动采用，§7.1）。
    var claimIsBoundedFact: Bool
}

nonisolated enum HoloMemoryDecisionInputDeriver {
    static func derive(for record: HoloMemoryRecord, now: Date) -> HoloMemoryDecisionInput {
        let payload = record.personalContext?.v1

        return HoloMemoryDecisionInput(
            sourceAuthority: sourceAuthority(for: record, payload: payload),
            evidenceVerdict: evidenceVerdict(for: record, payload: payload, now: now),
            impactLevel: impactLevel(for: record, payload: payload),
            persistencePermission: persistencePermission(for: record, payload: payload),
            hasUnresolvedConflict: !record.counterEvidenceRefs.isEmpty || record.state == .disputed,
            isExpired: isExpired(record, payload: payload, now: now),
            // 门禁 6 防的是「今晚/这次」推成永久偏好；带 applicability.conditionText 的
            // event 是「条件化经验」（如「出门时请人喂猫」），复用受条件约束不属泛化，
            // 恰是个人情境候选的主形态——不最窄化（否则该类候选全被 observeOnly 挡在
            // 建议门外，2026-09-23 端到端实锤）。
            isTemporaryEventScope: payload?.temporal?.kind == .event
                && (payload?.applicability.conditionText ?? "").isEmpty,
            claimIsBoundedFact: record.validFrom != nil
                || record.evidenceRefs.contains { $0.validFrom != nil }
        )
    }

    // MARK: 来源权威性（§6.1）

    private static func sourceAuthority(
        for record: HoloMemoryRecord,
        payload: HoloPersonalContextPayloadV1?
    ) -> HoloMemorySourceAuthority {
        if let payload {
            switch payload.epistemicStatus {
            case .declared:
                // 注：明确记忆请求（explicitMemoryRequest）与引用/假设语气判别
                // 缺少稳定信号，保守归入明确陈述处理（§13.1 门禁项 MTX-04/ADV-01/ADV-02）。
                return .explicitUserStatement
            case .observed:
                return .structuredObservation
            case .inferred:
                return .modelInference
            }
        }
        if record.scope == .crossDomain {
            return .modelInference
        }
        let lineages = Set(record.evidenceRefs.map(\.lineageKey))
        if record.evidenceRefs.contains(where: { $0.kind == .explicitUserStatement }) {
            return .explicitUserStatement
        }
        if lineages.count >= 2 {
            return .repeatedIndependentEvidence
        }
        if record.evidenceRefs.isEmpty {
            return .unknownSource
        }
        return .structuredObservation
    }

    // MARK: 证据核验（§6.2）

    private static func evidenceVerdict(
        for record: HoloMemoryRecord,
        payload: HoloPersonalContextPayloadV1?,
        now: Date
    ) -> HoloMemoryEvidenceVerdict {
        if let payload {
            // 个人情境：admission 是核验结论的投影（adviceEligible 仅在 supported 时授予）。
            if payload.admission.level == .forbidden { return .unsupported }
            if payload.admission.level != .adviceEligible { return .unreviewed }
            if !record.counterEvidenceRefs.isEmpty || record.state == .disputed {
                return .contradicted
            }
            return .supported
        }
        if record.evidenceRefs.isEmpty { return .insufficient }
        // 跨域：无共同时间窗/独立 lineage 的相关性 → 不支持（§7.2）。
        if record.scope == .crossDomain, !hasCommonEvidenceWindow(record) {
            return .unsupported
        }
        if !record.counterEvidenceRefs.isEmpty || record.state == .disputed {
            return .contradicted
        }
        // 单域关联/张力命题：一个领域支持不了关系结论 → 越界（§6.2 unsupported）。
        if record.scope == .domain, record.claimKind == .association || record.claimKind == .tension {
            return .unsupported
        }
        // 单次现象：样本量过低的有界观察等待补证（§9.4）。
        if record.claimKind == .observedFact,
           let samples = record.evidenceRefs.first?.sampleCount, samples < 5 {
            return .insufficient
        }
        // 过去状态不得写成当前事实（§6.4 时效）：只有「当前状态类」命题按时效判过期；
        // recurring/association/tension 表达「曾出现/曾同期」，validTo 是观察窗，
        // 过时由 freshness 半衰期治理（与 isExpired 同一口径）。
        if isCurrentStateClaim(record),
           record.validTo.map({ $0 < now }) == true {
            return .unsupported
        }
        // AI 解释类命题天然是限定结论，不给 supported（§6.1 modelInference）。
        if record.prohibitedInferences.isEmpty == false,
           record.claimKind == .hypothesis || record.claimKind == .association || record.claimKind == .tension {
            return .qualified
        }
        return .supported
    }

    private static func hasCommonEvidenceWindow(_ record: HoloMemoryRecord) -> Bool {
        let windows = record.evidenceRefs.compactMap { ref -> (Date, Date)? in
            guard let from = ref.validFrom, let to = ref.validTo else { return nil }
            return (from, to)
        }
        guard windows.count == record.evidenceRefs.count, !windows.isEmpty else { return false }
        let latestStart = windows.map(\.0).max()!
        let earliestEnd = windows.map(\.1).min()!
        return latestStart <= earliestEnd
    }

    // MARK: 错误影响（§6.3 首版程序规则）

    private static func impactLevel(
        for record: HoloMemoryRecord,
        payload: HoloPersonalContextPayloadV1?
    ) -> HoloMemoryDecisionImpactLevel {
        let involvesHealth = record.sourceDomains.contains(.health) || record.primaryDomain == .health
        if record.sensitivity == .highImpact { return .high }
        if record.sensitivity == .sensitive {
            return involvesHealth ? .high : .medium
        }
        // 推断类 + 医疗/心理/用药安全护栏 → 高影响（推断不可替代专业判断）。
        let authority = sourceAuthority(for: record, payload: payload)
        let medicalGuard = record.prohibitedInferences.contains {
            $0.hasPrefix("medical") || $0.hasPrefix("psychological") || $0.hasPrefix("medication")
        }
        if medicalGuard, authority == .modelInference { return .high }
        if record.claimKind == .explicitPreference { return .medium }
        if record.claimKind == .lifeEvent
            || record.claimKind == .phaseShift
            || record.primaryDomain == .profile
            || record.sourceDomains.contains(.profile) {
            return .medium
        }
        // 时间/节奏类重复规律会明显改变规划（习惯/任务/目标域）。
        if record.claimKind == .recurringPattern,
           !record.sourceDomains.filter({ [.habit, .task, .goal].contains($0) }).isEmpty {
            return .medium
        }
        // 单域关系命题按中影响保守处理（多数会被 unsupported 丢弃，此处兜底）。
        if record.scope == .domain, record.claimKind == .association || record.claimKind == .tension {
            return .medium
        }
        return .low
    }

    // MARK: 持久化权限（§4.2 / ADR-5）

    private static func persistencePermission(
        for record: HoloMemoryRecord,
        payload: HoloPersonalContextPayloadV1?
    ) -> HoloMemoryPersistencePermission {
        if isThirdParty(payload) {
            // 第三方信息默认不得形成长期记忆（除非明确记忆请求——信号待契约证明）。
            return .blocked
        }
        let authority = sourceAuthority(for: record, payload: payload)
        let structured = authority == .structuredObservation || authority == .repeatedIndependentEvidence
        if record.sensitivity != .normal, !structured {
            // 敏感/高影响自由文本默认 source scoped：一次聊天不等于无限期存储同意。
            return .sourceScoped
        }
        return .durable
    }

    /// 主体/对象包含非用户的人际指向（person/group）即视为第三方命题。
    private static func isThirdParty(_ payload: HoloPersonalContextPayloadV1?) -> Bool {
        guard let payload else { return false }
        let partyScopes: [HoloContextPartyRef.Scope] = [.person, .group]
        return payload.subjects.contains { partyScopes.contains($0.scope) }
            || payload.objects.contains { partyScopes.contains($0.scope) }
    }

    private static func isExpired(
        _ record: HoloMemoryRecord,
        payload: HoloPersonalContextPayloadV1?,
        now: Date
    ) -> Bool {
        if let end = payload?.temporal?.validTo, end < now { return true }
        // 只有「当前状态类」命题按 record.validTo 判过期；recurring/association/tension
        // 的 validTo 是观察窗（表达「曾出现/曾同期」），过时由 freshness 半衰期治理。
        if isCurrentStateClaim(record), record.validTo.map({ $0 < now }) == true {
            return true
        }
        return false
    }

    /// 当前状态类命题：描述「现在如何」，过期即失真。关系/规律类表达「曾出现」，不适用。
    private static func isCurrentStateClaim(_ record: HoloMemoryRecord) -> Bool {
        switch record.claimKind {
        case .observedFact, .phaseShift, .lifeEvent, .explicitPreference:
            return true
        case .recurringPattern, .association, .tension, .hypothesis:
            return false
        }
    }
}

// MARK: - 五路裁决（§7）

nonisolated struct HoloMemoryFiveWayDecision: Equatable, Sendable {
    var route: HoloMemoryFiveWayRoute
    var useLevel: HoloMemoryUseLevel
    var attentionPolicy: HoloMemoryAttentionPolicyKind
    var reasonCodes: [HoloMemoryDecisionReason]
    var input: HoloMemoryDecisionInput
    var evaluatedAt: Date
    var evidenceRevision: String

    /// 可直接挂到 record.decisionMetadata 的 v2 元数据。
    var metadata: HoloMemoryDecisionMetadataV2 {
        HoloMemoryDecisionMetadataV2(
            policyVersion: HoloMemoryDecisionPolicy.currentVersion,
            sourceAuthority: input.sourceAuthority,
            evidenceVerdict: input.evidenceVerdict,
            impactLevel: input.impactLevel,
            persistencePermission: input.persistencePermission,
            useLevel: useLevel,
            attentionPolicy: attentionPolicy,
            reasonCodes: reasonCodes,
            evaluatedAt: evaluatedAt,
            evidenceRevision: evidenceRevision
        )
    }

    /// personalContext.admission 的兼容投影：由决策结果单向派生，
    /// 新写入不得再独立裁决 admission（方案 §10.2/§11.1）。
    func projectedAdmission(now: Date) -> HoloContextAdmissionV1 {
        let level: HoloContextAdmissionLevel
        switch route {
        case .factEligible, .qualifiedAdvice: level = .adviceEligible
        case .observeOnly: level = .unreviewed
        case .askWhenRelevant: level = .confirmationOnly
        case .discard: level = .forbidden
        }
        return HoloContextAdmissionV1(
            level: level,
            policyVersion: HoloMemoryDecisionPolicy.currentVersion,
            decidedAt: now,
            reason: reasonCodes.map(\.rawValue).first
        )
    }
}

nonisolated enum HoloMemoryDecisionPolicy {
    static let currentVersion = 4

    /// v4 五路决策开关的规范 key；HoloAIFeatureFlags 同名属性从这里读取。
    static let enabledKey = "holo_memory_decisionPolicyV4Enabled"
    static let shadowLoggingKey = "holo_memory_decisionShadowLoggingEnabled"

    /// 默认启用：本交付面向内部验收（方案 §18.1 灰度第 3 步）；
    /// 生产放量按灰度顺序执行，回滚=UserDefaults 写 false（新内容走保守 observeOnly）。
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// shadow 日志：同时计算 v3/v4 只记 metadata 差异，不改状态（§18.1 第 1 步）。
    static var isShadowLoggingEnabled: Bool {
        UserDefaults.standard.object(forKey: shadowLoggingKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: shadowLoggingKey)
    }

    /// 五路统一裁决：唯一允许产出「是否使用/是否打扰」最终结论的组件（§11.1/ADR-6）。
    static func evaluate(_ record: HoloMemoryRecord, now: Date) -> HoloMemoryFiveWayDecision {
        let input = HoloMemoryDecisionInputDeriver.derive(for: record, now: now)
        return decide(record: record, input: input, now: now)
    }

    static func decide(
        record: HoloMemoryRecord,
        input: HoloMemoryDecisionInput,
        now: Date
    ) -> HoloMemoryFiveWayDecision {
        // 用户已拒绝/忘记、终态记录：不复活。
        if [.rejected, .forgotten].contains(record.userDecision)
            || [HoloMemoryState.suppressed, .tombstoned, .deleted].contains(record.state) {
            return make(
                route: .discard, useLevel: .blocked, attention: .neverAsk,
                reasons: [.userRejectedOrForgotten], input: input, now: now, record: record
            )
        }

        // 明确记忆请求（信号到位后直接采信；当前 deriver 不会产出该 authority）。
        if input.sourceAuthority == .explicitMemoryRequest,
           input.persistencePermission == .durable,
           !input.hasUnresolvedConflict {
            return make(
                route: .factEligible, useLevel: .factEligible, attention: .silent,
                reasons: [.explicitlyRequestedMemory], input: input, now: now, record: record
            )
        }

        // 越界/伪因果/无支持 → 丢弃（不能靠用户点击洗白）。
        if input.evidenceVerdict == .unsupported {
            return make(
                route: .discard, useLevel: .blocked, attention: .neverAsk,
                reasons: [.unsupportedClaim], input: input, now: now, record: record
            )
        }

        // 派生持久化未授权（第三方/敏感自由文本）→ 不写派生记忆（§7.1 第三行）。
        if input.persistencePermission != .durable {
            return make(
                route: .discard, useLevel: .blocked, attention: .neverAsk,
                reasons: [.derivedPersistenceNotAuthorized], input: input, now: now, record: record
            )
        }

        // 证据不足/未核验 → 继续观察（§9.4）。
        if input.evidenceVerdict == .insufficient || input.evidenceVerdict == .unreviewed {
            return make(
                route: .observeOnly, useLevel: .observeOnly, attention: .silent,
                reasons: [.awaitingEvidence], input: input, now: now, record: record
            )
        }

        // 未解冲突：中高影响且会改变规划 → 按需问最小问题；低影响 → 观察（§9.6）。
        if input.hasUnresolvedConflict {
            return input.impactLevel == .low
                ? make(route: .observeOnly, useLevel: .observeOnly, attention: .silent,
                       reasons: [.unresolvedConflict], input: input, now: now, record: record)
                : make(route: .askWhenRelevant, useLevel: .blocked, attention: .askWhenRelevant,
                       reasons: [.unresolvedConflict], input: input, now: now, record: record)
        }

        // 仅适用于过去阶段 → 丢弃（§6.4）。
        if input.isExpired {
            return make(
                route: .discard, useLevel: .blocked, attention: .neverAsk,
                reasons: [.staleOrExpired], input: input, now: now, record: record
            )
        }

        // 用户明确陈述 + 断言门禁：临时选择最窄范围（§6.1 门禁 6），其余自动采信不二次确认。
        if input.sourceAuthority == .explicitUserStatement, input.evidenceVerdict == .supported {
            if input.isTemporaryEventScope {
                return make(
                    route: .observeOnly, useLevel: .observeOnly, attention: .silent,
                    reasons: [.temporaryScopeNarrowed], input: input, now: now, record: record
                )
            }
            return make(
                route: .factEligible, useLevel: .factEligible, attention: .silent,
                reasons: [.declaredStatementAccepted], input: input, now: now, record: record
            )
        }

        // 结构化有界事实：低影响自动采信；高影响限定使用或实时查领域数据（§7.1/§7.2）。
        if input.sourceAuthority == .structuredObservation || input.sourceAuthority == .repeatedIndependentEvidence {
            if input.evidenceVerdict == .supported, input.claimIsBoundedFact {
                if input.sourceAuthority == .repeatedIndependentEvidence, input.impactLevel == .medium {
                    return make(
                        route: .qualifiedAdvice, useLevel: .qualifiedAdvice, attention: .silent,
                        reasons: [.qualifiedInferenceOnly], input: input, now: now, record: record
                    )
                }
                return input.impactLevel == .high
                    ? make(route: .qualifiedAdvice, useLevel: .qualifiedAdvice, attention: .silent,
                           reasons: [.boundedStructuredFact, .highImpactBlockedPendingClarification],
                           input: input, now: now, record: record)
                    : make(route: .factEligible, useLevel: .factEligible, attention: .silent,
                           reasons: [.boundedStructuredFact], input: input, now: now, record: record)
            }
        }

        // 限定推断：高影响 → 按需澄清（回答前 blocked）；其余 → 限定建议（§7.1）。
        if input.evidenceVerdict == .qualified || input.sourceAuthority == .modelInference {
            return input.impactLevel == .high
                ? make(route: .askWhenRelevant, useLevel: .blocked, attention: .askWhenRelevant,
                       reasons: [.highImpactBlockedPendingClarification], input: input, now: now, record: record)
                : make(route: .qualifiedAdvice, useLevel: .qualifiedAdvice, attention: .silent,
                       reasons: [.qualifiedInferenceOnly], input: input, now: now, record: record)
        }

        // 无界结构化/其余情况 → 观察。
        return make(
            route: .observeOnly, useLevel: .observeOnly, attention: .silent,
            reasons: [.awaitingEvidence], input: input, now: now, record: record
        )
    }

    /// 把决策挂回记录：写 decisionMetadata；factEligible/qualifiedAdvice 生效为 active，
    /// observe/ask 保持 candidate（silent，不构成每日任务——P1 口径已下线收件箱）。
    static func attach(
        _ decision: HoloMemoryFiveWayDecision,
        to record: HoloMemoryRecord,
        now: Date
    ) -> HoloMemoryRecord? {
        guard decision.route != .discard else { return nil }
        var updated = record
        updated.decisionMetadata = HoloMemoryDecisionMetadataEnvelope(v2: decision.metadata)
        switch decision.route {
        case .factEligible, .qualifiedAdvice:
            updated.state = .active
        case .observeOnly, .askWhenRelevant:
            updated.state = .candidate
        case .discard:
            return nil
        }
        if updated.personalContext?.v1 != nil {
            updated.personalContext?.v1?.admission = decision.projectedAdmission(now: now)
        }
        return updated
    }

    private static func make(
        route: HoloMemoryFiveWayRoute,
        useLevel: HoloMemoryUseLevel,
        attention: HoloMemoryAttentionPolicyKind,
        reasons: [HoloMemoryDecisionReason],
        input: HoloMemoryDecisionInput,
        now: Date,
        record: HoloMemoryRecord
    ) -> HoloMemoryFiveWayDecision {
        HoloMemoryFiveWayDecision(
            route: route,
            useLevel: useLevel,
            attentionPolicy: attention,
            reasonCodes: reasons,
            input: input,
            evaluatedAt: now,
            evidenceRevision: currentEvidenceRevision(record)
        )
    }

    private static func currentEvidenceRevision(_ record: HoloMemoryRecord) -> String {
        (record.evidenceRefs.map(\.revisionDigest) + record.counterEvidenceRefs.map(\.revisionDigest))
            .sorted()
            .joined(separator: "|")
    }
}
