//
//  HoloKnowledgeResolution.swift
//  Holo
//
//  统一决策与消费契约（方案 v2.2 §3.4 首发模板 / §4 状态契约 / §6 ResolvedKnowledge）
//
//  保持「保存、可见、确认、可使用」四件事分开。一个最终决策驱动展示、确认和消费；
//  Usefulness / Recall / AnswerEligibility 消费同一判定，不再各自成为最终规则。
//

import Foundation

// MARK: - §4 六态决策

nonisolated enum HoloKnowledgeDecisionState: String, Codable, Equatable, Sendable, CaseIterable {
    /// 无价值/不支持/禁止保存：不展示为个人记忆，不沉淀；原模块仍提供事实查询
    case noValue
    /// 内部积累或身份待明确：不列为待确认事项；不作持续个人理解
    case internalAccumulating
    /// 已有直接陈述或有效来源关联：已记住，相关问题中使用（受权限/源状态/时间约束）
    case remembered
    /// 成熟但未确认的行为规律：值得确认——只可展示结论及依据，不暗中改变持续个性化
    case worthConfirming
    /// 已确认且仍有效的规律：已记住，按准确语义与允许范围提供背景和建议
    case confirmedValid
    /// 失效/过期/被替代/冲突/停用：次级历史或停用；不当作当前确定知识
    case inactive

    /// 是否可进入任何使用通道（回答背景、带限定建议）
    var isUsableForAnswering: Bool {
        switch self {
        case .remembered, .confirmedValid: return true
        case .noValue, .internalAccumulating, .worthConfirming, .inactive: return false
        }
    }

    /// 前台「已记住」
    var isShownAsRemembered: Bool { isUsableForAnswering }

    /// 前台「值得确认」
    var isShownAsWorthConfirming: Bool { self == .worthConfirming }
}

// MARK: - §6 统一消费载荷

/// 所有消费者共享同一份决策结果：携带命题/语义/证据版本、形成方式、适用条件与范围、
/// 来源状态、允许用途和控制代际。消费者只能按自己的操作能力缩小用途，
/// 不能重新裁决为更高权限；不直读 active 代替资格。
nonisolated struct HoloResolvedKnowledge: Codable, Equatable, Identifiable, Sendable {
    var id: String { propositionID }

    var propositionID: String
    var topicID: String
    var topicLabel: String
    var domains: [HoloMemoryDomain]
    var partition: HoloKnowledgePartition
    var sensitivity: HoloMemorySensitivity
    /// 当前权威语义版本（已确认且有效 / 直接陈述 / 有效来源关联）
    var currentRevision: HoloKnowledgeRevision?
    /// 待确认的新建议版本（可与 currentRevision 并存；只有前者可被持续使用）
    var proposedRevision: HoloKnowledgeRevision?
    /// 用户确认绑定的语义指纹（nil = 未确认）
    var confirmedSemanticDigest: String?
    /// 最新证据快照
    var latestEvidenceSnapshot: HoloKnowledgeEvidenceSnapshot?
    var decision: HoloKnowledgeDecisionState
    var decisionReasons: [String]
    var sourceStatus: HoloKnowledgeSourceStatus
    /// 已按控制与来源缩小后的允许用途
    var allowedUses: Set<HoloKnowledgeAllowedUse>
    /// 控制代际（对应 userDecisionVersion；提交和呈现时复查）
    var controlGeneration: Int64
    /// 当前生效的限制操作（不准确/停用/遗忘/来源失效）
    var restrictingOperationIDs: Set<String>
    /// 暂不处理的冷却截止
    var cooldownUntil: Date?
    var formation: HoloKnowledgeFormation
    var lastUpdatedAt: Date
    /// 旧 HoloMemoryRecord.id 别名（旧 ID 深链经别名解释）
    var legacyAliases: [String]
    /// 来自未迁移旧记录的受限只读投影（§7.3：不通过旧 active 查询悄悄回退）
    var isLegacyRestricted: Bool
    /// 可撤销的最近一次用户操作 ID（服务层决定）
    var undoableOperationID: String?

    init(
        propositionID: String,
        topicID: String,
        topicLabel: String,
        domains: [HoloMemoryDomain],
        partition: HoloKnowledgePartition,
        sensitivity: HoloMemorySensitivity,
        currentRevision: HoloKnowledgeRevision?,
        proposedRevision: HoloKnowledgeRevision?,
        confirmedSemanticDigest: String?,
        latestEvidenceSnapshot: HoloKnowledgeEvidenceSnapshot?,
        decision: HoloKnowledgeDecisionState,
        decisionReasons: [String],
        sourceStatus: HoloKnowledgeSourceStatus,
        allowedUses: Set<HoloKnowledgeAllowedUse>,
        controlGeneration: Int64,
        restrictingOperationIDs: Set<String>,
        cooldownUntil: Date?,
        formation: HoloKnowledgeFormation,
        lastUpdatedAt: Date,
        legacyAliases: [String],
        isLegacyRestricted: Bool,
        undoableOperationID: String? = nil
    ) {
        self.propositionID = propositionID
        self.topicID = topicID
        self.topicLabel = topicLabel
        self.domains = domains
        self.partition = partition
        self.sensitivity = sensitivity
        self.currentRevision = currentRevision
        self.proposedRevision = proposedRevision
        self.confirmedSemanticDigest = confirmedSemanticDigest
        self.latestEvidenceSnapshot = latestEvidenceSnapshot
        self.decision = decision
        self.decisionReasons = decisionReasons
        self.sourceStatus = sourceStatus
        self.allowedUses = allowedUses
        self.controlGeneration = controlGeneration
        self.restrictingOperationIDs = restrictingOperationIDs
        self.cooldownUntil = cooldownUntil
        self.formation = formation
        self.lastUpdatedAt = lastUpdatedAt
        self.legacyAliases = legacyAliases
        self.isLegacyRestricted = isLegacyRestricted
        self.undoableOperationID = undoableOperationID
    }

    /// 展示正文：权威版本优先，其次待确认版本。
    var displayText: String {
        currentRevision?.semantic.displayText ?? proposedRevision?.semantic.displayText ?? ""
    }

    var aiUseText: String {
        currentRevision?.semantic.aiUseText ?? ""
    }

    /// 消费者缩小用途（不能放宽）。
    func narrowed(to uses: Set<HoloKnowledgeAllowedUse>) -> HoloResolvedKnowledge {
        var copy = self
        copy.allowedUses = allowedUses.intersection(uses)
        return copy
    }

    /// 形成方式的如实标记（§5）。
    var formationLabel: String {
        switch formation {
        case .directExpression: return "你告诉 Holo 的"
        case .sourceLinked: return "来自关联记录"
        case .behavioralInference:
            return confirmedSemanticDigest == nil ? "Holo 的观察" : "你确认的理解"
        case .userCorrection: return "你修改的"
        }
    }
}

// MARK: - §3.4 首发模板与参数归属（可测试的工程定义，非普适科学证明）

nonisolated enum HoloKnowledgeTemplateID: String, Codable, Equatable, Sendable, CaseIterable {
    /// 周期规则/固定负担
    case periodicRule
    /// 可比较窗口变化
    case comparableWindowChange
    /// 周内重复节奏
    case weeklyRhythm
    /// 开放条件/跨域关联（只表达关联，不表达因果）
    case openConditionalAssociation
}

/// 每个模板的最低跨度/样本/对照/实际变化定义与反例要求；参数作为可测试配置登记。
nonisolated struct HoloKnowledgeTemplateParameters: Equatable, Sendable {
    var id: HoloKnowledgeTemplateID
    /// 最少独立底层事件数
    var minIndependentEvents: Int
    /// 最少观察跨度（天）
    var minSpanDays: Int
    /// 最少完整自然周期数（周期类）
    var minCompletePeriods: Int
    /// 存在应观察机会时的最低覆盖率
    var minCoverage: Double
    /// 必须完成反例检索
    var requiresCounterexampleSearch: Bool
    /// 冻结候选后至少增加的未参与选择的完整验证周期（跨域关联）
    var holdoutPeriods: Int
    var allowedEvidenceForms: Set<HoloKnowledgeEvidenceForm>
}

nonisolated enum HoloKnowledgeTemplateRegistry {
    static let currentVersion = 1

    static let all: [HoloKnowledgeTemplateID: HoloKnowledgeTemplateParameters] = [
        .periodicRule: HoloKnowledgeTemplateParameters(
            id: .periodicRule,
            minIndependentEvents: 3,
            minSpanDays: 21,
            minCompletePeriods: 3,
            minCoverage: 0,
            requiresCounterexampleSearch: true,
            holdoutPeriods: 0,
            allowedEvidenceForms: [.intervalRuleWithExceptions, .independentEventSet]
        ),
        .comparableWindowChange: HoloKnowledgeTemplateParameters(
            id: .comparableWindowChange,
            minIndependentEvents: 10,
            minSpanDays: 14,
            minCompletePeriods: 2,
            minCoverage: 0.7,
            requiresCounterexampleSearch: true,
            holdoutPeriods: 0,
            allowedEvidenceForms: [.sampledNumericSeries, .independentEventSet]
        ),
        .weeklyRhythm: HoloKnowledgeTemplateParameters(
            id: .weeklyRhythm,
            minIndependentEvents: 6,
            minSpanDays: 28,
            minCompletePeriods: 4,
            minCoverage: 0.7,
            requiresCounterexampleSearch: true,
            holdoutPeriods: 0,
            allowedEvidenceForms: [.independentEventSet, .sampledNumericSeries]
        ),
        .openConditionalAssociation: HoloKnowledgeTemplateParameters(
            id: .openConditionalAssociation,
            minIndependentEvents: 6,
            minSpanDays: 28,
            minCompletePeriods: 2,
            minCoverage: 0.7,
            requiresCounterexampleSearch: true,
            holdoutPeriods: 1,
            allowedEvidenceForms: [.multiSourceSemanticRelation, .independentEventSet]
        ),
    ]

    static func parameters(for id: HoloKnowledgeTemplateID) -> HoloKnowledgeTemplateParameters {
        all[id]!
    }

    /// 由旧 claimKind 映射到模板（无登记统计定义的指标不开放数值归纳）。
    static func templateID(for claimKind: HoloMemoryClaimKind, scope: HoloMemoryScope) -> HoloKnowledgeTemplateID? {
        switch claimKind {
        case .recurringPattern: return .weeklyRhythm
        case .phaseShift: return .comparableWindowChange
        case .association, .tension: return scope == .crossDomain ? .openConditionalAssociation : nil
        case .observedFact, .hypothesis, .explicitPreference, .lifeEvent: return nil
        }
    }
}

/// 数值指标必须注册单位、分辨率/误差处理、聚合方法、有效观察与最小实际变化规则。
/// 优先沿用原统计模块的已核对定义；没有定义时该数值模板不开放。
nonisolated struct HoloKnowledgeMetricDefinition: Equatable, Sendable {
    var metricID: String
    var unit: String
    var aggregation: String
    /// 最小实际变化（同单位）；低于此值不称为变化
    var minMeaningfulChange: Double
    var ownerModule: String
}

nonisolated enum HoloKnowledgeMetricRegistry {
    /// 首发只登记原模块已核对口径的指标；其余数值归纳退回「已记录范围」描述。
    static let definitions: [String: HoloKnowledgeMetricDefinition] = [
        "habit.completionCount": HoloKnowledgeMetricDefinition(
            metricID: "habit.completionCount", unit: "次", aggregation: "sum",
            minMeaningfulChange: 1, ownerModule: "HabitRepository"
        ),
        "habit.numericValue": HoloKnowledgeMetricDefinition(
            metricID: "habit.numericValue", unit: "habit.unit", aggregation: "sum",
            minMeaningfulChange: 0, ownerModule: "HabitRepository"
        ),
        "task.completionCount": HoloKnowledgeMetricDefinition(
            metricID: "task.completionCount", unit: "次", aggregation: "count",
            minMeaningfulChange: 1, ownerModule: "TodoRepository"
        ),
        "finance.expenseAmount": HoloKnowledgeMetricDefinition(
            metricID: "finance.expenseAmount", unit: "CNY", aggregation: "sum",
            minMeaningfulChange: 1, ownerModule: "FinanceRepository"
        ),
        "finance.transactionCount": HoloKnowledgeMetricDefinition(
            metricID: "finance.transactionCount", unit: "笔", aggregation: "count",
            minMeaningfulChange: 1, ownerModule: "FinanceRepository"
        ),
    ]

    static func isRegistered(_ metricID: String) -> Bool { definitions[metricID] != nil }
}

// MARK: - 共同观察契约（融合契约 §2 ObservationAssessment）

/// 一个发现与记忆的共同输入：真实业务 ID、源修订、事件血缘、时间精度、测量口径、
/// 覆盖、权限与敏感分区；支持/反例、适用范围、语义与证据版本。
/// 不新增最终事实库：只有达到持久化授权的命题进入两类新实体。
nonisolated struct HoloObservationAssessment: Codable, Equatable, Sendable {
    nonisolated enum Purpose: String, Codable, Equatable, Sendable {
        /// 发现目的（有限观察呈现）
        case discovery
        /// 记忆目的（长期保存）
        case memory
    }

    var purpose: Purpose
    var semantic: HoloKnowledgeSemantic
    var evidenceSnapshot: HoloKnowledgeEvidenceSnapshot
    var domains: [HoloMemoryDomain]
    var sensitivity: HoloMemorySensitivity
    /// 获授权来源集合（发现仅想法/任务/习惯；记忆八域；不互相扩大）
    var authorizedSourceDomains: Set<HoloMemoryDomain>
    /// 是否允许长期持久化（记忆自动学习开关 / 手动保存授权）
    var persistenceAuthorized: Bool
    var origin: HoloKnowledgeOrigin?

    var propositionID: String { HoloKnowledgeIdentity.propositionID(for: semantic) }
    var semanticDigest: String { semantic.semanticDigest }
    var partition: HoloKnowledgePartition {
        HoloKnowledgePartitionPolicy.partition(
            sensitivity: sensitivity,
            domains: domains,
            evidence: evidenceSnapshot.supportRefs + evidenceSnapshot.counterRefs
        )
    }
}

// MARK: - 分区策略（§7.1）

nonisolated enum HoloKnowledgePartitionPolicy {
    /// 健康或敏感来源及其派生、证据、向量和操作历史留在本机分区。
    /// 分级同时考虑来源限制与命题内容；多来源取最高敏感级别。
    static func partition(
        sensitivity: HoloMemorySensitivity,
        domains: [HoloMemoryDomain],
        evidence: [HoloMemoryEvidenceRef]
    ) -> HoloKnowledgePartition {
        if sensitivity == .sensitive { return .sensitiveLocal }
        if domains.contains(.health) { return .sensitiveLocal }
        if evidence.contains(where: { $0.sourceDomain == .health }) { return .sensitiveLocal }
        return .normal
    }

    static func partition(for record: HoloMemoryRecord) -> HoloKnowledgePartition {
        partition(
            sensitivity: record.sensitivity,
            domains: record.sourceDomains + (record.primaryDomain.map { [$0] } ?? []),
            evidence: record.evidenceRefs + record.counterEvidenceRefs
        )
    }
}

// MARK: - 准入裁决（§3.2 统一问题）

/// 「数据是真的」与「这个归纳有用」分别判断。未知和证据不足停留后台，
/// 不能把半成品交给用户判真假。
nonisolated enum HoloKnowledgeAdmissionVerdict: Equatable, Sendable {
    /// 无价值/不支持/禁止保存
    case reject(reason: HoloKnowledgeAdmissionReason)
    /// 内部积累（证据不足/身份待明确/模板未登记）
    case internalOnly(reason: HoloKnowledgeAdmissionReason)
    /// 直接陈述或有效来源关联：已记住
    case remembered
    /// 成熟行为规律：值得确认
    case worthConfirming

    var decisionState: HoloKnowledgeDecisionState {
        switch self {
        case .reject: return .noValue
        case .internalOnly: return .internalAccumulating
        case .remembered: return .remembered
        case .worthConfirming: return .worthConfirming
        }
    }

    var reason: HoloKnowledgeAdmissionReason? {
        switch self {
        case .reject(let reason), .internalOnly(let reason): return reason
        case .remembered, .worthConfirming: return nil
        }
    }
}

nonisolated enum HoloKnowledgeAdmissionReason: String, Codable, Equatable, Sendable, CaseIterable {
    case structureInvalid
    case evidenceUntraceable
    case unsupportedClaim
    case prohibitedInference
    case thirdPartyNotAuthorized
    case persistenceNotAuthorized
    case sourceNotAuthorized
    case routineFlowWithoutValue
    case templateNotRegistered
    case insufficientIndependentEvents
    case insufficientSpan
    case insufficientCoverage
    case insufficientCompletePeriods
    case counterexampleSearchIncomplete
    case counterexampleFound
    case holdoutNotValidated
    case temporaryScopeOnly
    case expired
    case directStatementAccepted
    case sourceLinkedAccepted
    case matureInference
}
