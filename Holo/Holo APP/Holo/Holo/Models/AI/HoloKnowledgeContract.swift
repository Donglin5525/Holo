//
//  HoloKnowledgeContract.swift
//  Holo
//
//  通用知识契约（方案《Holo 记忆：从碎片记录到可用理解》v2.2 §2）
//
//  分开四种身份：topicID（主题容器）/ propositionID（命题身份）/
//  semanticRevisionID+digest（语义版本）/ evidenceSnapshotID（证据快照）。
//  语义修订一经生成不可原地改正文；普通证据刷新不改变语义版本。
//  纯值类型，不依赖 Core Data / UIKit；可独立单测。
//

import Foundation

// MARK: - 容错枚举基建（与 HoloMemoryDecisionPolicy 同纪律：未知值原样保留，消费端保守处理）

protocol HoloKnowledgeTolerantEnumValue: Equatable, Sendable {
    var rawValue: String { get }
    static var knownCases: [Self] { get }
    static func unrecognized(_ raw: String) -> Self
}

enum HoloKnowledgeTolerantEnumCodec {
    static func decode<T: HoloKnowledgeTolerantEnumValue>(
        _ type: T.Type,
        from decoder: Decoder
    ) throws -> T {
        let raw = try decoder.singleValueContainer().decode(String.self)
        return type.knownCases.first { $0.rawValue == raw } ?? type.unrecognized(raw)
    }
}

// MARK: - 分区（§7.1）

/// 知识的物理归属：普通知识随主库 CloudKit 同步；敏感来源及其派生只留本机分区，
/// 不通过迁移扩大同步范围。多来源取最高敏感级别，任何快照/操作/索引先决定分区再写。
nonisolated enum HoloKnowledgePartition: String, Codable, Equatable, Sendable {
    case normal
    case sensitiveLocal

    /// 限制性控制在全部别名上传播；分区合并时取更保守一侧。
    static func stricter(_ lhs: HoloKnowledgePartition, _ rhs: HoloKnowledgePartition) -> HoloKnowledgePartition {
        lhs == rhs ? lhs : .sensitiveLocal
    }
}

// MARK: - 形成方式（§5 如实标记）

nonisolated enum HoloKnowledgeFormation: String, Codable, Equatable, Sendable, CaseIterable {
    /// 用户明确表达（你告诉 Holo 的）
    case directExpression
    /// 关联现有业务实体或用户明确陈述的当前情境（来自关联记录）
    case sourceLinked
    /// 从多份证据学到的行为归纳（你确认的理解 / 待确认）
    case behavioralInference
    /// 用户纠正提交的新内容（独立来源的用户陈述）
    case userCorrection

    /// 行为归纳达到证据门槛后才进入「值得确认」；直接陈述不要求重复出现。
    var requiresConfirmationForUse: Bool { self == .behavioralInference }
}

// MARK: - 证据形态（§3.1：形态决定计算方式）

nonisolated enum HoloKnowledgeEvidenceForm: String, Codable, Equatable, Sendable, CaseIterable {
    /// 明确语义事实：用户陈述、纠正、明确记忆请求
    case explicitSemanticFact
    /// 独立事件集合：消费、任务完成、负向习惯发生等
    case independentEventSet
    /// 采样数值序列：体重、睡眠测量、按日记录
    case sampledNumericSeries
    /// 有效区间/周期与例外：每周责任、月付费用、临时限制
    case intervalRuleWithExceptions
    /// 多来源语义关系：责任、依赖、条件关联
    case multiSourceSemanticRelation
}

// MARK: - 允许用途（§2.2：禁止把记忆作为执行命令或精确实时统计）

nonisolated enum HoloKnowledgeAllowedUse: String, Codable, Equatable, Sendable, CaseIterable {
    /// 背景理解
    case backgroundUnderstanding
    /// 带限定的建议
    case qualifiedAdvice
    /// 精确查询所需的源关联（真源在原模块）
    case sourceLinkForPreciseQuery
}

// MARK: - 适用范围（§2.4 指纹组成部分）

nonisolated struct HoloKnowledgeApplicability: Codable, Equatable, Hashable, Sendable {
    /// 相对滚动窗口与明确历史窗口必须区分；不能把「三月如此」自动改成「现在一直如此」。
    nonisolated enum WindowRule: Codable, Equatable, Hashable, Sendable {
        /// 持续有效直至用户修改（偏好、约束类）
        case ongoing
        /// 明确事件时间/历史窗（重要事件按原发生时间保留）
        case absolute(from: Date?, to: Date?)
        /// 相对滚动窗（按确认的规则更新，不悄改成无限长期）
        case rolling(days: Int)
        /// 周期规则（frequency/interval/weekday 的规范化字串）
        case recurrence(rule: String)

        var isBounded: Bool {
            switch self {
            case .ongoing: return false
            case .absolute, .rolling, .recurrence: return true
            }
        }

        private enum CodingKeys: String, CodingKey {
            case kind, from, to, days, rule
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(String.self, forKey: .kind)
            switch kind {
            case "ongoing": self = .ongoing
            case "absolute":
                self = .absolute(
                    from: try c.decodeIfPresent(Date.self, forKey: .from),
                    to: try c.decodeIfPresent(Date.self, forKey: .to)
                )
            case "rolling": self = .rolling(days: try c.decodeIfPresent(Int.self, forKey: .days) ?? 0)
            case "recurrence": self = .recurrence(rule: try c.decodeIfPresent(String.self, forKey: .rule) ?? "")
            default: self = .absolute(from: nil, to: nil)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .ongoing: try c.encode("ongoing", forKey: .kind)
            case .absolute(let from, let to):
                try c.encode("absolute", forKey: .kind)
                try c.encodeIfPresent(from, forKey: .from)
                try c.encodeIfPresent(to, forKey: .to)
            case .rolling(let days):
                try c.encode("rolling", forKey: .kind)
                try c.encode(days, forKey: .days)
            case .recurrence(let rule):
                try c.encode("recurrence", forKey: .kind)
                try c.encode(rule, forKey: .rule)
            }
        }
    }

    /// 适用窗口规则
    var windowRule: WindowRule
    /// 适用条件（如「出差期间」「周末」；规范化后参与指纹）
    var conditionText: String?
    /// 单次例外（一次例外不覆盖整条规则）
    var exceptions: [String]

    init(
        windowRule: WindowRule = .ongoing,
        conditionText: String? = nil,
        exceptions: [String] = []
    ) {
        self.windowRule = windowRule
        self.conditionText = (conditionText ?? "").isEmpty ? nil : conditionText
        self.exceptions = exceptions
    }
}

// MARK: - 语义版本正文（§2.4）

/// 一份知识最少携带的语义。语义指纹只归一化结构事实，不用全文摘要作身份；
/// displayText 展示正文不参与指纹——措辞变化不产生独立事实。
nonisolated struct HoloKnowledgeSemantic: Codable, Equatable, Hashable, Sendable {
    /// 主体引用："self" 或业务实体稳定 ID（名字/商家名/习惯名不能充当唯一身份）
    var subjectRef: String
    /// 对象引用（业务实体 ID 或持久化自由语义槽位）
    var objectRef: String?
    /// 开放关系（规范化：fold+lowercase）
    var relation: String
    /// 肯/否定（否定不是独立命题，是语义版本差异）
    var polarity: Bool
    /// 关键对象值（如 "5000 CNY/月"）；月租里的 5000 属于语义
    var objectValue: String?
    /// 观察维度（参与命题身份：同对象不同维度分别保留）
    var dimension: String
    /// 必要限定（如「本人解释」「相关非因果」「转述」）
    var qualifiers: [String]
    /// 适用范围（条件 + 窗口规则 + 例外）
    var applicability: HoloKnowledgeApplicability
    /// 允许用途（消费者只能缩小，不能重新裁决为更高权限）
    var allowedUses: Set<HoloKnowledgeAllowedUse>
    /// 形成方式
    var formation: HoloKnowledgeFormation
    /// 证据形态
    var evidenceForm: HoloKnowledgeEvidenceForm
    /// 展示正文（不参与指纹）
    var displayText: String
    /// AI 使用正文（不参与指纹）
    var aiUseText: String
    var prohibitedInferences: [String]
    /// 用户独立陈述的规范化指纹（纠正/明确保存时设置；参与语义指纹）。
    /// 后台润色 displayText 不动它 → 同义润色不制造新事实；
    /// 用户提交新陈述 → 新指纹 → 新修订（纠正不被 upsert 幂等吞掉）。
    var statementDigest: String?

    init(
        subjectRef: String,
        objectRef: String? = nil,
        relation: String,
        polarity: Bool = true,
        objectValue: String? = nil,
        dimension: String,
        qualifiers: [String] = [],
        applicability: HoloKnowledgeApplicability = HoloKnowledgeApplicability(),
        allowedUses: Set<HoloKnowledgeAllowedUse> = [.backgroundUnderstanding],
        formation: HoloKnowledgeFormation,
        evidenceForm: HoloKnowledgeEvidenceForm,
        displayText: String,
        aiUseText: String,
        prohibitedInferences: [String] = [],
        statementDigest: String? = nil
    ) {
        self.subjectRef = subjectRef
        self.objectRef = (objectRef ?? "").isEmpty ? nil : objectRef
        self.relation = relation
        self.polarity = polarity
        self.objectValue = (objectValue ?? "").isEmpty ? nil : objectValue
        self.dimension = dimension
        self.qualifiers = qualifiers
        self.applicability = applicability
        self.allowedUses = allowedUses
        self.formation = formation
        self.evidenceForm = evidenceForm
        self.displayText = displayText
        self.aiUseText = aiUseText
        self.prohibitedInferences = prohibitedInferences
        self.statementDigest = (statementDigest ?? "").isEmpty ? nil : statementDigest
    }

    /// 语义指纹（§2.4）：主体/对象、关系与肯否定、关键对象值、条件、
    /// 绝对适用范围或相对窗口规则、必要限定和允许用途。
    var semanticDigest: String {
        HoloKnowledgeIdentity.semanticDigest(of: self)
    }
}

// MARK: - 四种身份（§2.1）

nonisolated enum HoloKnowledgeIdentity {
    /// propositionID：主体、对象、观察维度和适用条件下的一项独立知识。
    /// 存在不同观点、职责或条件时分别保留；无法确定同一身份时保留区别。
    static func propositionID(
        subjectRef: String,
        objectRef: String?,
        dimension: String,
        conditionText: String?
    ) -> String {
        let identity = [
            "holo-knowledge-v1",
            normalize(subjectRef),
            normalize(objectRef ?? "-"),
            normalize(dimension),
            normalize(conditionText ?? "-"),
        ].joined(separator: "|")
        return "holo-prop-\(fnv1a64(identity))"
    }

    static func propositionID(for semantic: HoloKnowledgeSemantic) -> String {
        propositionID(
            subjectRef: semantic.subjectRef,
            objectRef: semantic.objectRef,
            dimension: semantic.dimension,
            conditionText: semantic.applicability.conditionText
        )
    }

    /// 语义指纹：结构事实的规范化摘要。支持「月租 5000」「扩成长期」的改动改变指纹。
    static func semanticDigest(of semantic: HoloKnowledgeSemantic) -> String {
        let fingerprint = [
            normalize(semantic.subjectRef),
            normalize(semantic.objectRef ?? "-"),
            normalize(semantic.relation),
            semantic.polarity ? "affirm" : "negate",
            normalize(semantic.objectValue ?? "-"),
            normalize(semantic.applicability.conditionText ?? "-"),
            windowFingerprint(semantic.applicability.windowRule),
            semantic.applicability.exceptions.map(normalize).sorted().joined(separator: ","),
            semantic.qualifiers.map(normalize).sorted().joined(separator: ","),
            semantic.allowedUses.map(\.rawValue).sorted().joined(separator: ","),
            semantic.statementDigest ?? "-",
        ].joined(separator: "|")
        return "sd-\(fnv1a64(fingerprint))"
    }

    /// topicID：用户能理解的主题容器（展示分组用；主题不直接作为事实注入）。
    static func topicID(objectRef: String?, dimension: String) -> String {
        let identity = [
            normalize(objectRef ?? "-"),
            normalize(dimension),
        ].joined(separator: "|")
        return "holo-topic-\(fnv1a64(identity))"
    }

    /// evidenceSnapshotID：绑定**所有**影响核验的内容（09-R03）：
    /// 来源键与修订按 (lineageKey, revisionDigest) 配对（交换配对 = 不同证据）、
    /// 反例配对、观察窗、覆盖、独立事件数、反例检索状态、模板、holdout、
    /// 来源修订目录与统计摘要。仅改变覆盖或窗口，证据 ID 必须变化；
    /// capturedAt 捕获时刻不参与（不能以时间戳替代证据内容身份）。
    static func evidenceSnapshotID(of snapshot: HoloKnowledgeEvidenceSnapshot) -> String {
        func pair(_ refs: [HoloMemoryEvidenceRef]) -> String {
            refs
                .map { "\(normalize($0.lineageKey))@\(normalize($0.revisionDigest))" }
                .sorted()
                .joined(separator: ",")
        }
        let sourceRevisionPairs = snapshot.sourceRevisions
            .map { "\(normalize($0.key))@\(normalize($0.value))" }
            .sorted()
            .joined(separator: ",")
        let fingerprint = [
            pair(snapshot.supportRefs),
            pair(snapshot.counterRefs),
            encodeDate(snapshot.observationWindowFrom),
            encodeDate(snapshot.observationWindowTo),
            String(snapshot.independentEventCount),
            snapshot.coveragePercent.map { String(format: "%.4f", $0) } ?? "-",
            snapshot.counterexampleSearch.rawValue,
            snapshot.templateID ?? "-",
            String(snapshot.completePeriods ?? -1),
            String(snapshot.holdoutValidatedPeriods ?? -1),
            sourceRevisionPairs,
            normalize(snapshot.statsSummary ?? "-"),
        ].joined(separator: "|")
        return "es-\(fnv1a64(fingerprint))"
    }

    private static func encodeDate(_ date: Date?) -> String {
        date.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
    }

    /// 确定性修订 ID：同语义 + 同来源别名幂等（CloudKit 无唯一约束，重试/同步重复行在仓库归并）。
    static func semanticRevisionID(
        propositionID: String,
        semanticDigest: String,
        sourceAliases: [String]
    ) -> String {
        let identity = [
            propositionID,
            semanticDigest,
            sourceAliases.map(normalize).sorted().joined(separator: ","),
        ].joined(separator: "|")
        return "holo-rev-\(fnv1a64(identity))"
    }

    /// 自由语义槽位：新名词、新责任或偏好对象无需修改实体策略代码（§2.2）。
    static func freeSemanticSlot(_ text: String) -> String {
        "slot-\(fnv1a64(normalize(text)))"
    }

    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
    }

    private static func windowFingerprint(_ rule: HoloKnowledgeApplicability.WindowRule) -> String {
        switch rule {
        case .ongoing: return "ongoing"
        case .absolute(let from, let to):
            let f = from.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
            let t = to.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
            return "abs(\(f),\(t))"
        case .rolling(let days): return "roll(\(days))"
        case .recurrence(let rule): return "rec(\(normalize(rule)))"
        }
    }

    static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

// MARK: - 证据快照（§2.1 / §3.1）

nonisolated enum HoloKnowledgeCounterexampleSearchStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case notSearched
    case searchedNoneFound
    case searchedFound
}

/// 支持语义的来源修订、事件、时间窗、统计与反例快照。
/// 普通证据刷新不自动改变已确认的语义——快照更新走 evidenceSnapshot 操作。
nonisolated struct HoloKnowledgeEvidenceSnapshot: Codable, Equatable, Sendable {
    var supportRefs: [HoloMemoryEvidenceRef]
    var counterRefs: [HoloMemoryEvidenceRef]
    /// 观察窗（与命题适用范围区分）
    var observationWindowFrom: Date?
    var observationWindowTo: Date?
    /// 独立底层事件数（重叠聚合窗口回溯底层事件；同一事件在账单/想法/周报中只计一次）
    var independentEventCount: Int
    /// 覆盖率（0...1；无可比覆盖就只描述「已记录范围」）
    var coveragePercent: Double?
    /// 反例检索覆盖状态（准入统一问题：搜过反例吗）
    var counterexampleSearch: HoloKnowledgeCounterexampleSearchStatus
    /// 命中的统计模板（nil = 非数值归纳或未命中）
    var templateID: String?
    /// 观察窗内的完整统计周期数（完整自然周/可比周期；跨度足够 ≠ 周期完整，09-R12）
    var completePeriods: Int?
    /// 展示统计（如样本量、周期数；属于证据快照不属于语义）
    var statsSummary: String?
    /// 来源修订目录（sourceRef → revisionDigest；来源变化对账用，不能只靠 updatedAt）
    var sourceRevisions: [String: String]
    /// 冻结候选后已通过的未参与选择的完整验证周期数（跨域关联模板 holdout 要求）
    var holdoutValidatedPeriods: Int?
    var capturedAt: Date

    init(
        supportRefs: [HoloMemoryEvidenceRef] = [],
        counterRefs: [HoloMemoryEvidenceRef] = [],
        observationWindowFrom: Date? = nil,
        observationWindowTo: Date? = nil,
        independentEventCount: Int = 0,
        coveragePercent: Double? = nil,
        counterexampleSearch: HoloKnowledgeCounterexampleSearchStatus = .notSearched,
        templateID: String? = nil,
        completePeriods: Int? = nil,
        statsSummary: String? = nil,
        sourceRevisions: [String: String] = [:],
        holdoutValidatedPeriods: Int? = nil,
        capturedAt: Date
    ) {
        self.supportRefs = supportRefs
        self.counterRefs = counterRefs
        self.observationWindowFrom = observationWindowFrom
        self.observationWindowTo = observationWindowTo
        self.independentEventCount = independentEventCount
        self.coveragePercent = coveragePercent
        self.counterexampleSearch = counterexampleSearch
        self.templateID = templateID
        self.completePeriods = completePeriods
        self.statsSummary = statsSummary
        self.sourceRevisions = sourceRevisions
        self.holdoutValidatedPeriods = holdoutValidatedPeriods
        self.capturedAt = capturedAt
    }

    var id: String { HoloKnowledgeIdentity.evidenceSnapshotID(of: self) }
}

// MARK: - 冲突内容摘要（09-R07：同 ID 不同不可变内容检测）

extension HoloKnowledgeRevision {
    /// 规范化内容摘要：键序固定的 JSON 重编码后哈希。比较「同一逻辑 ID 的两行
    /// 是否同一份不可变内容」用，不用原始字节（编码差异不误报冲突）。
    var canonicalContentDigest: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "undigestible-\(semanticRevisionID)" }
        return HoloKnowledgeIdentity.fnv1a64(String(decoding: data, as: UTF8.self))
    }
}

extension HoloKnowledgeOperation {
    var canonicalContentDigest: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "undigestible-\(operationID)" }
        return HoloKnowledgeIdentity.fnv1a64(String(decoding: data, as: UTF8.self))
    }
}

// MARK: - 来源（§4 来源核验不以 Unknown 默认放行）

nonisolated enum HoloKnowledgeSourceStatus: String, Equatable, Sendable, CaseIterable {
    /// 存在且版本匹配
    case verified
    /// 存在但修订已变（重核）
    case revised
    case deleted
    /// 来源被 AI 排除（隐私优先）
    case excluded
    case permissionRevoked
    /// 当前未知（只保留历史与待核状态，不作为可用 fallback）
    case unknown

    /// 是否阻断当前用途。来源删除/排除/撤权 → 相应证据退出；未知不放行；
    /// 来源修订（编辑）→ 触发重核但不立即退出（§3.3「变化重核」与「退出」分列）。
    var isBlockingUsage: Bool {
        switch self {
        case .verified, .revised: return false
        case .deleted, .excluded, .permissionRevoked, .unknown: return true
        }
    }

    var needsRecheck: Bool { self == .revised }
}

extension HoloKnowledgeSourceStatus: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HoloKnowledgeSourceStatus(rawValue: raw) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 知识来源（origin 引用）

/// 知识的来源路径（详情页能解释形成路径：原发现过期时仍可核对获授权业务来源）。
nonisolated struct HoloKnowledgeOrigin: Codable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        case discoveryFinding
        case legacyRecord
        case userStatement
        case producer
    }

    var kind: Kind
    var findingID: String?
    var runID: String?
    var candidateID: String?
    var claimID: String?
    var legacyRecordID: String?
    /// 产生者标识（如 personalContextExtractor / signalAdapter）
    var producer: String?

    init(
        kind: Kind,
        findingID: String? = nil,
        runID: String? = nil,
        candidateID: String? = nil,
        claimID: String? = nil,
        legacyRecordID: String? = nil,
        producer: String? = nil
    ) {
        self.kind = kind
        self.findingID = findingID
        self.runID = runID
        self.candidateID = candidateID
        self.claimID = claimID
        self.legacyRecordID = legacyRecordID
        self.producer = producer
    }
}

// MARK: - 知识修订（新实体 1 的 Codable 载荷，§7.1）

/// 修订正文不可原地覆盖；每次语义修改产生新修订。必要物理属性带默认值/可选，
/// 符合 CloudKit 增量约束。
nonisolated struct HoloKnowledgeRevision: Codable, Equatable, Identifiable, Sendable {
    var id: String { semanticRevisionID }

    var propositionID: String
    var semanticRevisionID: String
    var semanticDigest: String
    var topicID: String
    /// 主题展示名（用户可理解；不参与身份）
    var topicLabel: String
    var domains: [HoloMemoryDomain]
    var sensitivity: HoloMemorySensitivity
    var partition: HoloKnowledgePartition
    var semantic: HoloKnowledgeSemantic
    /// 初始依据引用（证据刷新走 evidenceSnapshot 操作，不改本字段）
    var initialEvidenceSnapshot: HoloKnowledgeEvidenceSnapshot
    /// 旧 HoloMemoryRecord.id 等 provenance/alias（旧 ID 经别名解释）
    var sourceAliases: [String]
    var origin: HoloKnowledgeOrigin?
    var predecessorRevisionID: String?
    var createdAt: Date
    var schemaVersion: Int

    init(
        propositionID: String,
        semanticRevisionID: String,
        semanticDigest: String,
        topicID: String,
        topicLabel: String,
        domains: [HoloMemoryDomain],
        sensitivity: HoloMemorySensitivity,
        partition: HoloKnowledgePartition,
        semantic: HoloKnowledgeSemantic,
        initialEvidenceSnapshot: HoloKnowledgeEvidenceSnapshot,
        sourceAliases: [String] = [],
        origin: HoloKnowledgeOrigin? = nil,
        predecessorRevisionID: String? = nil,
        createdAt: Date,
        schemaVersion: Int = 1
    ) {
        self.propositionID = propositionID
        self.semanticRevisionID = semanticRevisionID
        self.semanticDigest = semanticDigest
        self.topicID = topicID
        self.topicLabel = topicLabel
        self.domains = domains
        self.sensitivity = sensitivity
        self.partition = partition
        self.semantic = semantic
        self.initialEvidenceSnapshot = initialEvidenceSnapshot
        self.sourceAliases = sourceAliases
        self.origin = origin
        self.predecessorRevisionID = predecessorRevisionID
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
    }

    /// 便捷构造：由语义推导四种身份后建修订。
    static func make(
        semantic: HoloKnowledgeSemantic,
        topicLabel: String,
        domains: [HoloMemoryDomain],
        sensitivity: HoloMemorySensitivity,
        partition: HoloKnowledgePartition,
        evidenceSnapshot: HoloKnowledgeEvidenceSnapshot,
        sourceAliases: [String] = [],
        origin: HoloKnowledgeOrigin? = nil,
        predecessorRevisionID: String? = nil,
        createdAt: Date
    ) -> HoloKnowledgeRevision {
        let propositionID = HoloKnowledgeIdentity.propositionID(for: semantic)
        let digest = semantic.semanticDigest
        return HoloKnowledgeRevision(
            propositionID: propositionID,
            semanticRevisionID: HoloKnowledgeIdentity.semanticRevisionID(
                propositionID: propositionID,
                semanticDigest: digest,
                sourceAliases: sourceAliases
            ),
            semanticDigest: digest,
            topicID: HoloKnowledgeIdentity.topicID(
                objectRef: semantic.objectRef,
                dimension: semantic.dimension
            ),
            topicLabel: topicLabel,
            domains: domains,
            sensitivity: sensitivity,
            partition: partition,
            semantic: semantic,
            initialEvidenceSnapshot: evidenceSnapshot,
            sourceAliases: sourceAliases,
            origin: origin,
            predecessorRevisionID: predecessorRevisionID,
            createdAt: createdAt
        )
    }
}

// MARK: - 知识操作（新实体 2 的 Codable 载荷，§7.1 / §2.4）

/// 操作种类。用户确认/纠正/限制在这里形成权威事件；系统操作（证据刷新、
/// 提示记录、迁移收据）与用户操作同表隔离存储（分区解析一致）。
/// 未知未来种类原样保留（09-R06）：解码不失败、不静默降级，
/// 并按限制保守处理（限制优先：宁可停用不可冒用）。
nonisolated enum HoloKnowledgeOperationKind: Equatable, Hashable, Sendable {
    // 用户权威（§4 / §5）
    /// 确认：绑定 propositionID + semanticDigest + 发起方见过的控制事件
    case confirm
    /// 纠正：携带新修订（独立用户来源陈述）
    case correct
    /// 不准确（证据错 / 理解错 / 现在不适用三种子作用域）
    case markInaccurate
    /// 现在不适用 → 收窄当前有效范围（保留历史）
    case narrowScope
    /// 停用（保留可恢复历史）
    case disable
    /// 恢复（因果校验后生效）
    case restore
    /// 遗忘（清除正文与派生，仅留最小无正文阻断）
    case forget
    /// 暂不处理（同语义候选默认冷却 30 天）
    case deferCooldown
    /// 撤销最近一次操作（本身是新的受控写操作）
    case undo
    // 系统
    /// 证据快照刷新（不改语义版本）
    case evidenceSnapshot
    /// 旧记录别名导入（迁移）
    case aliasImport
    /// 迁移收据（幂等游标）
    case migrationReceipt
    /// 共同提示记录（某语义版本在哪个入口呈现/询问过、是否已保存、是否暂缓）
    case promptRecord
    /// 来源失效（编辑/删除/排除/撤权）
    case sourceInvalidation
    /// 旧记录退役（迁移复评：此前按旧口径导入为「已记住」的命题，在新分类
    /// 口径下属自动低价值/未确认推断——不再作为当前理解使用，保留历史可查）
    case legacyRetire
    /// 未知种类：保留原始 rawValue 供诊断；保守按限制处理。
    case unknownPreserved(String)

    var rawValue: String {
        switch self {
        case .confirm: return "confirm"
        case .correct: return "correct"
        case .markInaccurate: return "markInaccurate"
        case .narrowScope: return "narrowScope"
        case .disable: return "disable"
        case .restore: return "restore"
        case .forget: return "forget"
        case .deferCooldown: return "deferCooldown"
        case .undo: return "undo"
        case .evidenceSnapshot: return "evidenceSnapshot"
        case .aliasImport: return "aliasImport"
        case .migrationReceipt: return "migrationReceipt"
        case .promptRecord: return "promptRecord"
        case .sourceInvalidation: return "sourceInvalidation"
        case .legacyRetire: return "legacyRetire"
        case .unknownPreserved(let raw): return raw
        }
    }

    static let knownCases: [HoloKnowledgeOperationKind] = [
        .confirm, .correct, .markInaccurate, .narrowScope, .disable, .restore,
        .forget, .deferCooldown, .undo, .evidenceSnapshot, .aliasImport,
        .migrationReceipt, .promptRecord, .sourceInvalidation, .legacyRetire,
    ]

    init?(rawValue: String) {
        self = HoloKnowledgeOperationKind.knownCases
            .first { $0.rawValue == rawValue } ?? .unknownPreserved(rawValue)
    }

    var isUsageRestricting: Bool {
        switch self {
        case .markInaccurate, .narrowScope, .disable, .forget, .sourceInvalidation, .legacyRetire:
            return true
        case .confirm, .correct, .restore, .deferCooldown, .undo,
             .evidenceSnapshot, .aliasImport, .migrationReceipt, .promptRecord:
            return false
        case .unknownPreserved:
            // 未知操作可能是未来版本的任何控制；限制优先，保守阻断（09-R06）。
            return true
        }
    }

    var isUserAuthority: Bool {
        switch self {
        case .confirm, .correct, .markInaccurate, .narrowScope, .disable, .restore, .forget, .deferCooldown, .undo:
            return true
        case .evidenceSnapshot, .aliasImport, .migrationReceipt, .promptRecord, .sourceInvalidation, .legacyRetire:
            return false
        case .unknownPreserved:
            return false
        }
    }
}

extension HoloKnowledgeOperationKind: HoloKnowledgeTolerantEnumValue, Codable, CaseIterable {
    static func unrecognized(_ raw: String) -> HoloKnowledgeOperationKind {
        .unknownPreserved(raw)
    }

    static var allCases: [HoloKnowledgeOperationKind] { knownCases }

    init(from decoder: Decoder) throws {
        self = try HoloKnowledgeTolerantEnumCodec.decode(Self.self, from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 「不准确」的作用域：阻断当前被否定命题/语义，不封禁整个主题（§7.6）。
nonisolated enum HoloKnowledgeInaccurateScope: String, Codable, Equatable, Sendable, CaseIterable {
    /// 依据不对（关联证据绑定退出并重算）
    case evidence
    /// 理解不对（该命题/范围的解释被否定）
    case understanding
    /// 现在不适用（收窄当前有效范围，保留历史事实）
    case applicability
}

nonisolated enum HoloKnowledgeOperationPayload: Equatable, Sendable {
    case none
    /// 确认提交时见到的语义与证据（重核对账用）
    case confirmation(semanticDigest: String, evidenceSnapshotID: String)
    /// 纠正：新修订 ID + 用户原文（正文只在这里，指纹不反推内容）
    case correction(newRevisionID: String, statement: String)
    case inaccurate(reason: String?, scope: HoloKnowledgeInaccurateScope)
    case narrowing(validTo: Date)
    case cooldown(until: Date)
    case undo(targetOperationID: String)
    /// 证据快照刷新
    case evidenceSnapshot(HoloKnowledgeEvidenceSnapshot)
    /// 旧别名导入：legacyRecordID + 当时的用户决定（原意与范围保留）
    case aliasImport(legacyRecordID: String, legacyUserDecision: String?)
    /// 迁移收据：处理键 + 状态（scanned/classified/committed/受限/需重建）
    case migrationReceipt(HoloKnowledgeMigrationReceipt)
    /// 共同提示记录：入口 + 语义指纹 + 结果（asked/saved/deferred）
    case promptRecord(entry: String, semanticDigest: String, outcome: String)
    case sourceInvalidation(sourceRefs: [String], status: String)
    /// 未知载荷：保留原始 kind 供诊断，不静默降级为 none（09-R06）。
    case unknownPreserved(kind: String)
}

/// 迁移收据（§7.3）：处理键包含 Store/分区、旧 ID/修订与新策略版本；
/// 游标只在持久化成功后推进，重复执行不重复确认或新增知识。
nonisolated struct HoloKnowledgeMigrationReceipt: Codable, Equatable, Sendable {
    nonisolated enum Status: String, Codable, Equatable, Sendable, CaseIterable {
        case scanned
        case classified
        case committed
        /// 受限保留（未知版本/无可核对来源/歧义身份：单条保留原数据、排除新能力）
        case restricted
        /// 需要重建（语义重建进入预算队列）
        case needsRebuild
        /// 无价值退出（自动单次流水/低价值内容退出主记忆）
        case exited
    }

    /// 处理键：legacyRecordID + 策略版本（确定性，两台设备并行导入收敛）
    var processingKey: String
    var legacyRecordID: String
    var legacyRecordVersion: Int
    var policyVersion: Int
    var partition: HoloKnowledgePartition
    var status: Status
    /// 导入产出的 propositionID（committed 时）
    var propositionID: String?
    var detail: String?
    var completedAt: Date

    init(
        processingKey: String,
        legacyRecordID: String,
        legacyRecordVersion: Int,
        policyVersion: Int,
        partition: HoloKnowledgePartition,
        status: Status,
        propositionID: String? = nil,
        detail: String? = nil,
        completedAt: Date
    ) {
        self.processingKey = processingKey
        self.legacyRecordID = legacyRecordID
        self.legacyRecordVersion = legacyRecordVersion
        self.policyVersion = policyVersion
        self.partition = partition
        self.status = status
        self.propositionID = propositionID
        self.detail = detail
        self.completedAt = completedAt
    }

    static func makeProcessingKey(legacyRecordID: String, policyVersion: Int) -> String {
        "mig-\(legacyRecordID)@p\(policyVersion)"
    }
}

/// 幂等操作：目标命题/语义、前驱控制、操作种类、版本化载荷。
/// 「新控制不能写入旧 HoloMemoryControlEventMO」——本操作表与旧控制事件隔离，
/// 但复用同一因果/限制优先代数（HoloControlEventAlgebra 语义在 Resolver 中实现）。
nonisolated struct HoloKnowledgeOperation: Codable, Equatable, Identifiable, Sendable {
    var id: String { operationID }

    var operationID: String
    var kind: HoloKnowledgeOperationKind
    var propositionID: String
    /// 操作绑定的语义修订（nil = 整个命题）
    var targetSemanticRevisionID: String?
    var targetSemanticDigest: String?
    /// 前驱操作集合（因果可见性；跨设备并发限制优先，不比较时间戳）
    var priorOperationIDs: Set<String>
    var controlGeneration: Int64
    var payload: HoloKnowledgeOperationPayload
    var partition: HoloKnowledgePartition
    var issuedAt: Date
    var schemaVersion: Int

    init(
        operationID: String,
        kind: HoloKnowledgeOperationKind,
        propositionID: String,
        targetSemanticRevisionID: String? = nil,
        targetSemanticDigest: String? = nil,
        priorOperationIDs: Set<String> = [],
        controlGeneration: Int64 = 0,
        payload: HoloKnowledgeOperationPayload = .none,
        partition: HoloKnowledgePartition,
        issuedAt: Date,
        schemaVersion: Int = 1
    ) {
        self.operationID = operationID
        self.kind = kind
        self.propositionID = propositionID
        self.targetSemanticRevisionID = targetSemanticRevisionID
        self.targetSemanticDigest = targetSemanticDigest
        self.priorOperationIDs = priorOperationIDs
        self.controlGeneration = controlGeneration
        self.payload = payload
        self.partition = partition
        self.issuedAt = issuedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - 操作载荷容错 Codable（陷阱 5：关联值枚举必须显式手写）

extension HoloKnowledgeOperationPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case semanticDigest, evidenceSnapshotID
        case newRevisionID, statement
        case reason, scope
        case validTo
        case until
        case targetOperationID
        case evidenceSnapshot
        case legacyRecordID, legacyUserDecision
        case migrationReceipt
        case entry, outcome
        case sourceRefs, status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "none":
            self = .none
        case "confirmation":
            self = .confirmation(
                semanticDigest: try c.decodeIfPresent(String.self, forKey: .semanticDigest) ?? "",
                evidenceSnapshotID: try c.decodeIfPresent(String.self, forKey: .evidenceSnapshotID) ?? ""
            )
        case "correction":
            self = .correction(
                newRevisionID: try c.decodeIfPresent(String.self, forKey: .newRevisionID) ?? "",
                statement: try c.decodeIfPresent(String.self, forKey: .statement) ?? ""
            )
        case "inaccurate":
            self = .inaccurate(
                reason: try c.decodeIfPresent(String.self, forKey: .reason),
                scope: (try c.decodeIfPresent(String.self, forKey: .scope)).flatMap(HoloKnowledgeInaccurateScope.init(rawValue:)) ?? .understanding
            )
        case "narrowing":
            self = .narrowing(validTo: try c.decodeIfPresent(Date.self, forKey: .validTo) ?? Date(timeIntervalSince1970: 0))
        case "cooldown":
            self = .cooldown(until: try c.decodeIfPresent(Date.self, forKey: .until) ?? Date(timeIntervalSince1970: 0))
        case "undo":
            self = .undo(targetOperationID: try c.decodeIfPresent(String.self, forKey: .targetOperationID) ?? "")
        case "evidenceSnapshot":
            self = .evidenceSnapshot(try c.decode(HoloKnowledgeEvidenceSnapshot.self, forKey: .evidenceSnapshot))
        case "aliasImport":
            self = .aliasImport(
                legacyRecordID: try c.decodeIfPresent(String.self, forKey: .legacyRecordID) ?? "",
                legacyUserDecision: try c.decodeIfPresent(String.self, forKey: .legacyUserDecision)
            )
        case "migrationReceipt":
            self = .migrationReceipt(try c.decode(HoloKnowledgeMigrationReceipt.self, forKey: .migrationReceipt))
        case "promptRecord":
            self = .promptRecord(
                entry: try c.decodeIfPresent(String.self, forKey: .entry) ?? "",
                semanticDigest: try c.decodeIfPresent(String.self, forKey: .semanticDigest) ?? "",
                outcome: try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
            )
        case "sourceInvalidation":
            self = .sourceInvalidation(
                sourceRefs: try c.decodeIfPresent([String].self, forKey: .sourceRefs) ?? [],
                status: try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            )
        default:
            // 未知载荷保留 kind 诊断信息（09-R06）：不降级为 none 冒充已理解；
            // 配合 kind 层 unknownPreserved 的保守限制语义。
            self = .unknownPreserved(kind: kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try c.encode("none", forKey: .kind)
        case .confirmation(let digest, let snapshotID):
            try c.encode("confirmation", forKey: .kind)
            try c.encode(digest, forKey: .semanticDigest)
            try c.encode(snapshotID, forKey: .evidenceSnapshotID)
        case .correction(let revisionID, let statement):
            try c.encode("correction", forKey: .kind)
            try c.encode(revisionID, forKey: .newRevisionID)
            try c.encode(statement, forKey: .statement)
        case .inaccurate(let reason, let scope):
            try c.encode("inaccurate", forKey: .kind)
            try c.encodeIfPresent(reason, forKey: .reason)
            try c.encode(scope.rawValue, forKey: .scope)
        case .narrowing(let validTo):
            try c.encode("narrowing", forKey: .kind)
            try c.encode(validTo, forKey: .validTo)
        case .cooldown(let until):
            try c.encode("cooldown", forKey: .kind)
            try c.encode(until, forKey: .until)
        case .undo(let targetID):
            try c.encode("undo", forKey: .kind)
            try c.encode(targetID, forKey: .targetOperationID)
        case .evidenceSnapshot(let snapshot):
            try c.encode("evidenceSnapshot", forKey: .kind)
            try c.encode(snapshot, forKey: .evidenceSnapshot)
        case .aliasImport(let recordID, let decision):
            try c.encode("aliasImport", forKey: .kind)
            try c.encode(recordID, forKey: .legacyRecordID)
            try c.encodeIfPresent(decision, forKey: .legacyUserDecision)
        case .migrationReceipt(let receipt):
            try c.encode("migrationReceipt", forKey: .kind)
            try c.encode(receipt, forKey: .migrationReceipt)
        case .promptRecord(let entry, let digest, let outcome):
            try c.encode("promptRecord", forKey: .kind)
            try c.encode(entry, forKey: .entry)
            try c.encode(digest, forKey: .semanticDigest)
            try c.encode(outcome, forKey: .outcome)
        case .sourceInvalidation(let refs, let status):
            try c.encode("sourceInvalidation", forKey: .kind)
            try c.encode(refs, forKey: .sourceRefs)
            try c.encode(status, forKey: .status)
        case .unknownPreserved(let kind):
            try c.encode(kind, forKey: .kind)
        }
    }
}
