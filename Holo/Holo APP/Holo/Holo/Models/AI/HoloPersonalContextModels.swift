//
//  HoloPersonalContextModels.swift
//  Holo
//
//  通用个人情境理解与规划的数据契约（实施方案 §4）。
//
//  设计要点：
//  - 所有新增持久化字段用 decodeIfPresent / 带默认值解码；未知 schemaVersion 的载荷
//    通过 HoloPersonalContextPayloadEnvelope 保留原始 JSON，禁止降为 nil 后覆盖存储。
//  - contextID 由程序分配（UUID），模型输出只能给 candidateRef / existingRef。
//  - 时间表达区分 event / ongoing / recurring / conditional；模糊时间保留原文，
//    不得擅自转成固定日期。
//  - 本文件不依赖 App 运行时类型，可被 standalone 测试直接编译。
//

import Foundation

// MARK: - 通用 JSON 值（未知版本载荷的无损保留）

/// 任意 JSON 值的保真表示，用于未知 schemaVersion 载荷的原样读写。
indirect enum HoloContextJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HoloContextJSONValue])
    case object([String: HoloContextJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([HoloContextJSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: HoloContextJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let fields): try container.encode(fields)
        }
    }
}

// MARK: - 原始来源快照（§4.1）

/// 萃取输入的统一来源视图：想法、对话、业务记录都规范化成这个形状。
nonisolated struct HoloContextSourceSnapshot: Codable, Equatable, Sendable {
    /// 来源域。复用既有记忆域枚举的原始值（thought/conversation/…），开放场景不靠枚举限死语义。
    var sourceID: String
    var sourceDomain: String
    /// 来源种类（userNote/chatMessage/structuredRecord…，开放集合）。
    var sourceKind: String
    /// 规范化正文+必要业务状态的稳定摘要；UI 样式调整不触发重学。
    var revisionDigest: String
    var sourceCreatedAt: Date
    var sourceUpdatedAt: Date
    /// 统一富文本转纯文本的结果；不可解析附件仅标记覆盖缺口，不编造内容。
    var plainText: String
    /// 敏感性继承底层证据最高级别，不因来源是 thought 就降级。
    var sensitivity: HoloMemorySensitivity
    /// 权限代际：进行中的请求携带，返回前复查。
    var accessGeneration: Int
    /// 事件实际发生时间；与记录日期分开（补记不算新事件）。
    var eventTime: Date?
    /// 结构化业务状态摘要（可选）。
    var structuredStateDigest: String?
    /// 既有对象 ID（可选）。
    var linkedObjectID: String?
    /// 消息 role 必须保留；助手回复/AI 摘要不可成为独立用户事实。
    var role: String?
    /// 覆盖缺口说明（附件无法解析等）。
    var coverageGaps: [String]

    init(
        sourceID: String,
        sourceDomain: String,
        sourceKind: String,
        revisionDigest: String,
        sourceCreatedAt: Date,
        sourceUpdatedAt: Date,
        plainText: String,
        sensitivity: HoloMemorySensitivity,
        accessGeneration: Int,
        eventTime: Date? = nil,
        structuredStateDigest: String? = nil,
        linkedObjectID: String? = nil,
        role: String? = nil,
        coverageGaps: [String] = []
    ) {
        self.sourceID = sourceID
        self.sourceDomain = sourceDomain
        self.sourceKind = sourceKind
        self.revisionDigest = revisionDigest
        self.sourceCreatedAt = sourceCreatedAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.plainText = plainText
        self.sensitivity = sensitivity
        self.accessGeneration = accessGeneration
        self.eventTime = eventTime
        self.structuredStateDigest = structuredStateDigest
        self.linkedObjectID = linkedObjectID
        self.role = role
        self.coverageGaps = coverageGaps
    }

    enum CodingKeys: String, CodingKey {
        case sourceID
        case sourceDomain
        case sourceKind
        case revisionDigest
        case sourceCreatedAt
        case sourceUpdatedAt
        case plainText
        case sensitivity
        case accessGeneration
        case eventTime
        case structuredStateDigest
        case linkedObjectID
        case role
        case coverageGaps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        sourceDomain = try c.decode(String.self, forKey: .sourceDomain)
        sourceKind = try c.decodeIfPresent(String.self, forKey: .sourceKind) ?? "unknown"
        revisionDigest = try c.decode(String.self, forKey: .revisionDigest)
        sourceCreatedAt = try c.decode(Date.self, forKey: .sourceCreatedAt)
        sourceUpdatedAt = try c.decode(Date.self, forKey: .sourceUpdatedAt)
        plainText = try c.decode(String.self, forKey: .plainText)
        sensitivity = try c.decodeIfPresent(HoloMemorySensitivity.self, forKey: .sensitivity) ?? .normal
        accessGeneration = try c.decodeIfPresent(Int.self, forKey: .accessGeneration) ?? 0
        eventTime = try c.decodeIfPresent(Date.self, forKey: .eventTime)
        structuredStateDigest = try c.decodeIfPresent(String.self, forKey: .structuredStateDigest)
        linkedObjectID = try c.decodeIfPresent(String.self, forKey: .linkedObjectID)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        coverageGaps = try c.decodeIfPresent([String].self, forKey: .coverageGaps) ?? []
    }
}

// MARK: - 时间表达（§4.3）

nonisolated enum HoloContextTemporalKind: String, Codable, CaseIterable, Sendable {
    /// 一次性事件（已发生或明确将发生）。
    case event
    /// 持续状态（当前成立，无明确终点）。
    case ongoing
    /// 周期规律（有明确或观察到的频率）。
    case recurring
    /// 条件性（满足条件时才成立）。
    case conditional
}

/// 时间精度：原文只说「月初/上个月」时保留模糊，不得伪造精确日期。
nonisolated enum HoloContextTemporalPrecision: String, Codable, CaseIterable, Sendable {
    case exact
    case day
    case month
    case unknown
}

/// 明确周期。未知锚点留空；月初、工作日、节假日等不擅自转成固定日期。
nonisolated struct HoloContextRecurrenceV1: Codable, Equatable, Sendable {
    nonisolated enum Frequency: String, Codable, CaseIterable, Sendable {
        case daily
        case weekly
        case monthly
        case yearly
    }

    var frequency: Frequency
    var interval: Int
    /// 周锚点（1=周日 … 7=周六，仅 weekly）。
    var weekday: Int?
    /// 月内日锚点（仅 monthly/yearly）。
    var dayOfMonth: Int?
    /// 年内月锚点（仅 yearly）。
    var month: Int?

    init(
        frequency: Frequency,
        interval: Int = 1,
        weekday: Int? = nil,
        dayOfMonth: Int? = nil,
        month: Int? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.weekday = weekday
        self.dayOfMonth = dayOfMonth
        self.month = month
    }

    private enum CodingKeys: String, CodingKey {
        case frequency, interval, weekday, dayOfMonth, month
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = (try? c.decode(Frequency.self, forKey: .frequency)) ?? .monthly
        interval = (try? c.decodeIfPresent(Int.self, forKey: .interval)) ?? nil ?? 1
        weekday = try c.decodeIfPresent(Int.self, forKey: .weekday)
        dayOfMonth = try c.decodeIfPresent(Int.self, forKey: .dayOfMonth)
        month = try c.decodeIfPresent(Int.self, forKey: .month)
    }
}

nonisolated struct HoloContextTemporalV1: Codable, Equatable, Sendable {
    var kind: HoloContextTemporalKind
    /// 原文时间表达，保留模糊措辞。
    var originalExpression: String
    var precision: HoloContextTemporalPrecision
    var validFrom: Date?
    var validTo: Date?
    var recurrence: HoloContextRecurrenceV1?
    /// conditional 的触发条件原文。
    var triggerText: String?
    /// 已知例外（如本次延期），不改变规则本体。
    var exceptions: [String]

    init(
        kind: HoloContextTemporalKind,
        originalExpression: String,
        precision: HoloContextTemporalPrecision = .unknown,
        validFrom: Date? = nil,
        validTo: Date? = nil,
        recurrence: HoloContextRecurrenceV1? = nil,
        triggerText: String? = nil,
        exceptions: [String] = []
    ) {
        self.kind = kind
        self.originalExpression = originalExpression
        self.precision = precision
        self.validFrom = validFrom
        self.validTo = validTo
        self.recurrence = recurrence
        self.triggerText = triggerText
        self.exceptions = exceptions
    }

    private enum CodingKeys: String, CodingKey {
        case kind, originalExpression, precision, validFrom, validTo
        case recurrence, triggerText, exceptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(HoloContextTemporalKind.self, forKey: .kind)) ?? .ongoing
        originalExpression = try c.decodeIfPresent(String.self, forKey: .originalExpression) ?? ""
        precision = (try? c.decode(HoloContextTemporalPrecision.self, forKey: .precision)) ?? nil ?? .unknown
        validFrom = try c.decodeIfPresent(Date.self, forKey: .validFrom)
        validTo = try c.decodeIfPresent(Date.self, forKey: .validTo)
        recurrence = try c.decodeIfPresent(HoloContextRecurrenceV1.self, forKey: .recurrence)
        triggerText = try c.decodeIfPresent(String.self, forKey: .triggerText)
        exceptions = (try? c.decodeIfPresent([String].self, forKey: .exceptions)) ?? nil ?? []
    }
}

/// 周期实例：某规则在某周期的实际状态。没有完成证据时是 unknown，不能默认 pending。
nonisolated struct HoloContextOccurrence: Codable, Equatable, Sendable {
    nonisolated enum Status: String, Codable, CaseIterable, Sendable {
        case unknown
        case done
        case exception
    }

    var contextID: String
    /// 周期标识（如 2026-09、2026-W36）。
    var periodKey: String
    var status: Status
    var evidenceRefs: [String]

    init(
        contextID: String,
        periodKey: String,
        status: Status = .unknown,
        evidenceRefs: [String] = []
    ) {
        self.contextID = contextID
        self.periodKey = periodKey
        self.status = status
        self.evidenceRefs = evidenceRefs
    }
}

// MARK: - 载荷主体（§4.2）

/// 命题涉及的对象：用户本人、他人、项目、地点等。
/// 未知对象不自动视为用户本人；scope 是开放语义的粗分类，仅辅助检索。
nonisolated struct HoloContextPartyRef: Codable, Equatable, Sendable {
    nonisolated enum Scope: String, Codable, CaseIterable, Sendable {
        case user
        case person
        case group
        case project
        case place
        case object
        case open
    }

    /// 程序或既有对象 ID；未消歧对象为空。
    var ref: String?
    var label: String
    var scope: Scope

    init(ref: String? = nil, label: String, scope: Scope = .open) {
        self.ref = ref
        self.label = label
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case ref, label, scope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 模型输出缺 scope/ref 时用默认值；scope 非法值回落 open（§4 容错解码）。
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        scope = (try? c.decodeIfPresent(Scope.self, forKey: .scope)) ?? nil ?? .open
    }
}

/// 检索视角。other 必须连同 statement 一起保留，不得丢弃。
nonisolated struct HoloContextFacet: Codable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, CaseIterable, Sendable {
        case responsibility
        case time
        case dependency
        case constraint
        case preference
        case state
        case other
    }

    var kind: Kind
    var note: String?

    init(kind: Kind, note: String? = nil) {
        self.kind = kind
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case kind, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .other
    }
}

/// 与是否经用户确认分开的知识状态。
nonisolated enum HoloContextEpistemicStatus: String, Codable, CaseIterable, Sendable {
    /// 用户明说。
    case declared
    /// 从记录观察到的行为/事实。
    case observed
    /// 推断。
    case inferred
}

/// 作用范围与条件表达：命题在什么主体/项目/地点范围内成立。
nonisolated struct HoloContextApplicabilityV1: Codable, Equatable, Sendable {
    var partyRefs: [HoloContextPartyRef]
    var projectRefs: [String]
    var placeRefs: [String]
    /// 范围限定原文（如「只限工作日」「老家的房子」）。
    var conditionText: String?

    init(
        partyRefs: [HoloContextPartyRef] = [],
        projectRefs: [String] = [],
        placeRefs: [String] = [],
        conditionText: String? = nil
    ) {
        self.partyRefs = partyRefs
        self.projectRefs = projectRefs
        self.placeRefs = placeRefs
        self.conditionText = conditionText
    }

    private enum CodingKeys: String, CodingKey {
        case partyRefs, projectRefs, placeRefs, conditionText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partyRefs = (try? c.decodeIfPresent([HoloContextPartyRef].self, forKey: .partyRefs)) ?? nil ?? []
        projectRefs = (try? c.decodeIfPresent([String].self, forKey: .projectRefs)) ?? nil ?? []
        placeRefs = (try? c.decodeIfPresent([String].self, forKey: .placeRefs)) ?? nil ?? []
        conditionText = try c.decodeIfPresent(String.self, forKey: .conditionText)
    }
}

/// 证据引用：源 evidenceID、quote/UTF-16 范围、立场、来源修订。
nonisolated struct HoloContextBasisRef: Codable, Equatable, Sendable {
    nonisolated enum Stance: String, Codable, CaseIterable, Sendable {
        case support
        case contradiction
    }

    var sourceID: String
    var evidenceID: String?
    var quote: String?
    /// 规范化文本内的 UTF-16 范围（location + length），与 quote 配对出现。
    var quoteUTF16Location: Int?
    var quoteUTF16Length: Int?
    var eventID: String?
    var stance: Stance
    var sourceRevision: String

    init(
        sourceID: String,
        evidenceID: String? = nil,
        quote: String? = nil,
        quoteUTF16Location: Int? = nil,
        quoteUTF16Length: Int? = nil,
        eventID: String? = nil,
        stance: Stance = .support,
        sourceRevision: String
    ) {
        self.sourceID = sourceID
        self.evidenceID = evidenceID
        self.quote = quote
        self.quoteUTF16Location = quoteUTF16Location
        self.quoteUTF16Length = quoteUTF16Length
        self.eventID = eventID
        self.stance = stance
        self.sourceRevision = sourceRevision
    }
}

/// 准入状态：由程序和验证结果决定，模型不能自行标注。
nonisolated enum HoloContextAdmissionLevel: String, Codable, CaseIterable, Sendable {
    /// 未审核：不可作为建议背景。
    case unreviewed
    /// 验证通过，可作为建议背景（限定表达）。
    case adviceEligible
    /// 仅待确认：需要用户决策，不进建议背景。
    case confirmationOnly
    /// 禁止使用（敏感/高影响/验证失败/被压制）。
    case forbidden
}

nonisolated struct HoloContextAdmissionV1: Codable, Equatable, Sendable {
    var level: HoloContextAdmissionLevel
    var policyVersion: Int
    var decidedAt: Date
    /// 简短可审计理由（refs/结论级，不含原文）。
    var reason: String?

    init(
        level: HoloContextAdmissionLevel,
        policyVersion: Int,
        decidedAt: Date,
        reason: String? = nil
    ) {
        self.level = level
        self.policyVersion = policyVersion
        self.decidedAt = decidedAt
        self.reason = reason
    }
}

// MARK: - V1 载荷

nonisolated struct HoloPersonalContextPayloadV1: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    /// 程序分配的 UUID；模型不能任意指定本地身份。
    var contextID: String
    /// 可独立理解的克制命题，保留必要条件。
    var statement: String
    var subjects: [HoloContextPartyRef]
    var objects: [HoloContextPartyRef]
    /// 开放文本关系，不限定为场景枚举。
    var relationText: String
    var facets: [HoloContextFacet]
    var epistemicStatus: HoloContextEpistemicStatus
    var applicability: HoloContextApplicabilityV1
    var temporal: HoloContextTemporalV1?
    var basis: [HoloContextBasisRef]
    /// 关系依赖；持久化引用同时进入 record.upstreamMemoryIDs。
    var linkedContextIDs: [String]
    /// 当前未知，不能被模型填成事实。
    var openQuestions: [String]
    var admission: HoloContextAdmissionV1

    init(
        contextID: String,
        statement: String,
        subjects: [HoloContextPartyRef] = [],
        objects: [HoloContextPartyRef] = [],
        relationText: String,
        facets: [HoloContextFacet] = [],
        epistemicStatus: HoloContextEpistemicStatus,
        applicability: HoloContextApplicabilityV1 = HoloContextApplicabilityV1(),
        temporal: HoloContextTemporalV1? = nil,
        basis: [HoloContextBasisRef] = [],
        linkedContextIDs: [String] = [],
        openQuestions: [String] = [],
        admission: HoloContextAdmissionV1
    ) {
        self.schemaVersion = Self.supportedSchemaVersion
        self.contextID = contextID
        self.statement = statement
        self.subjects = subjects
        self.objects = objects
        self.relationText = relationText
        self.facets = facets
        self.epistemicStatus = epistemicStatus
        self.applicability = applicability
        self.temporal = temporal
        self.basis = basis
        self.linkedContextIDs = linkedContextIDs
        self.openQuestions = openQuestions
        self.admission = admission
    }

    // MARK: Codable（带默认值解码，旧数据缺 key 不失败）

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case contextID
        case statement
        case subjects
        case objects
        case relationText
        case facets
        case epistemicStatus
        case applicability
        case temporal
        case basis
        case linkedContextIDs
        case openQuestions
        case admission
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.supportedSchemaVersion
        contextID = try c.decode(String.self, forKey: .contextID)
        statement = try c.decode(String.self, forKey: .statement)
        subjects = try c.decodeIfPresent([HoloContextPartyRef].self, forKey: .subjects) ?? []
        objects = try c.decodeIfPresent([HoloContextPartyRef].self, forKey: .objects) ?? []
        relationText = try c.decode(String.self, forKey: .relationText)
        facets = try c.decodeIfPresent([HoloContextFacet].self, forKey: .facets) ?? []
        epistemicStatus = try c.decode(HoloContextEpistemicStatus.self, forKey: .epistemicStatus)
        applicability = try c.decodeIfPresent(HoloContextApplicabilityV1.self, forKey: .applicability) ?? HoloContextApplicabilityV1()
        temporal = try c.decodeIfPresent(HoloContextTemporalV1.self, forKey: .temporal)
        basis = try c.decodeIfPresent([HoloContextBasisRef].self, forKey: .basis) ?? []
        linkedContextIDs = try c.decodeIfPresent([String].self, forKey: .linkedContextIDs) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        admission = try c.decode(HoloContextAdmissionV1.self, forKey: .admission)
    }

    // MARK: 身份与合并（§4.4）

    /// 新情境命名空间锚点：程序生成并持久保存；沿用既有 anchor 枚举，旧端可解码。
    var contextAnchorValue: String { "personal-context:\(contextID)" }

    /// 归一化命题指纹：主体/对象/关系/范围/claimKind 一致才可合并；只有主题相同不得合并。
    func isMergeable(with other: HoloPersonalContextPayloadV1) -> Bool {
        guard contextID == other.contextID || normalizedSignature == other.normalizedSignature
        else { return false }
        if contextID == other.contextID { return true }
        return signatureComponentsEqual(other)
    }

    /// 结构签名一致性：主体、对象、范围与命题（归一化后）都一致。
    func signatureComponentsEqual(_ other: HoloPersonalContextPayloadV1) -> Bool {
        normalizedText(relationText) == normalizedText(other.relationText)
            && normalizedText(statement) == normalizedText(other.statement)
            && Set(subjects.map(\.refLabelKey)) == Set(other.subjects.map(\.refLabelKey))
            && Set(objects.map(\.refLabelKey)) == Set(other.objects.map(\.refLabelKey))
            && applicability.scopeSignature == other.applicability.scopeSignature
            && epistemicStatus == other.epistemicStatus
    }

    var normalizedSignature: String {
        [
            normalizedText(relationText),
            normalizedText(statement),
            subjects.map(\.refLabelKey).sorted().joined(separator: ","),
            objects.map(\.refLabelKey).sorted().joined(separator: ","),
            applicability.scopeSignature,
            epistemicStatus.rawValue
        ].joined(separator: "|")
    }

    private func normalizedText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

nonisolated extension HoloContextPartyRef {
    /// ref 优先、label 兜底的稳定键（大小写与空白归一）。
    var refLabelKey: String {
        let raw = ref ?? label
        return raw.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

nonisolated extension HoloContextApplicabilityV1 {
    var scopeSignature: String {
        [
            partyRefs.map(\.refLabelKey).sorted().joined(separator: ","),
            projectRefs.sorted().joined(separator: ","),
            placeRefs.sorted().joined(separator: ","),
            conditionText ?? ""
        ].joined(separator: "|")
    }
}

// MARK: - 抑制键（§5 遗忘联动）

/// 情境记录的非正文抑制键：阻止「换一个 contextID 重生」。
///
/// 键由程序按（来源、修订、命题归一化）生成，不让模型决定哪些用户记录被禁用；
/// 命题参与键组成，保证同来源不同命题不被一刀切压制（只忘「父亲低盐」不伤同文的「母亲晕车」）。
/// 跨设备 contextID 可不同，但同一底层来源与命题得到相同键。语义改写无法保证完美匹配，
/// 未知改写走保守停用与 coverage 记录（公开前门槛）。
nonisolated enum HoloContextSuppressionKeys {
    static let prefix = "ctx-"
    static let spanPrefix = "ctx-source-span:"
    static let aliasPrefix = "ctx-alias:"

    /// 每条证据一个 span 键：来源 + 修订 + 命题归一化摘要。
    static func spanKeys(for payload: HoloPersonalContextPayloadV1) -> [String] {
        let statement = normalizedStatementDigest(payload)
        return payload.basis.map { basis in
            spanPrefix + stableDigest("\(basis.sourceID)|\(basis.sourceRevision)|\(statement)")
        }
    }

    /// 已验证语义别名的稳定键（跨设备一致；别名来自程序侧验证，不让模型自定）。
    static func aliasKeys(aliases: [String]) -> [String] {
        aliases
            .map { normalizedStatementDigestText($0) }
            .filter { !$0.isEmpty }
            .map { aliasPrefix + stableDigest($0) }
    }

    /// 墓碑里属于情境命名空间的键（matcher 用，不当普通业务 anchor）。
    static func contextKeys(in anchorKeys: [String]) -> Set<String> {
        Set(anchorKeys.filter { $0.hasPrefix(prefix) })
    }

    private static func normalizedStatementDigest(_ payload: HoloPersonalContextPayloadV1) -> String {
        normalizedStatementDigestText(payload.statement)
    }

    private static func normalizedStatementDigestText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 键派生用的稳定散列（FNV-1a 64，与身份算法同族；非安全用途）。
    static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

// MARK: - 版本信封（未知 schemaVersion 无损保留）

/// personalContext 的存储信封：先读 schemaVersion，再解已支持载荷；
/// 未知版本把原始对象整份序列化进保留键 holoOpaquePayload，重编码时原样写回，
/// 禁止降为 nil 后覆盖存储。情境记录仅进本机存储（单写入方），保留键不存在形状兼容问题。
nonisolated struct HoloPersonalContextPayloadEnvelope: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1
    /// 未知版本载荷的保留键。
    static let opaquePayloadKey = "holoOpaquePayload"

    var schemaVersion: Int
    /// 已支持版本的解析结果；未知/无法解析时为 nil。
    var v1: HoloPersonalContextPayloadV1?
    /// 未知版本的原始 JSON 文本（整个对象含 schemaVersion 键）。
    private var opaquePayloadJSON: String?

    init(v1: HoloPersonalContextPayloadV1) {
        self.schemaVersion = v1.schemaVersion
        self.v1 = v1
        self.opaquePayloadJSON = nil
    }

    init(unknownVersion: Int, rawJSON: String) {
        self.schemaVersion = unknownVersion
        self.v1 = nil
        self.opaquePayloadJSON = rawJSON
    }

    /// 新端是否可把它当结构化情境使用。
    var isReadable: Bool { v1 != nil }

    /// 未知版本载荷的原始 JSON（诊断与无损迁移用）。
    var unknownPayloadJSON: String? { opaquePayloadJSON }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case opaquePayload = "holoOpaquePayload"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        let preservedOpaque = try? c.decodeIfPresent(String.self, forKey: .opaquePayload)
        if version == HoloPersonalContextPayloadV1.supportedSchemaVersion,
           let payload = try? HoloPersonalContextPayloadV1(from: decoder),
           preservedOpaque == nil {
            self.schemaVersion = version
            self.v1 = payload
            self.opaquePayloadJSON = nil
            return
        }
        // 未知或无法解析的版本：优先取保留键；否则把整个对象原样序列化收进保留键。
        self.schemaVersion = version
        self.v1 = nil
        if let preserved = try c.decodeIfPresent(String.self, forKey: .opaquePayload) {
            self.opaquePayloadJSON = preserved
        } else if let captured = try? HoloContextJSONValue(from: decoder),
                  let data = try? JSONEncoder().encode(captured) {
            self.opaquePayloadJSON = String(decoding: data, as: UTF8.self)
        } else {
            self.opaquePayloadJSON = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let v1 {
            try v1.encode(to: encoder)
        } else {
            try c.encode(schemaVersion, forKey: .schemaVersion)
            try c.encodeIfPresent(opaquePayloadJSON, forKey: .opaquePayload)
        }
    }
}
