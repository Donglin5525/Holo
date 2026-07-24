//
//  HoloAgentPlanModels.swift
//  Holo
//
//  Agent 成熟度演进 P0-B — AgentPlan + Clarification + Semantic Frame
//
//  让复杂任务先形成明确计划（子问题、指标要求、依赖、完成标准、歧义），
//  同时保留简单查数的 fast path。所有字段用稳定 ID，可被 Coverage Check 引用。
//

import Foundation

// MARK: - Query Semantic Frame

/// 查询语义帧：意图、时间、歧义、敏感度。由确定性解析 + 轻量分类生成。
nonisolated struct HoloAgentQuerySemanticFrame: Equatable, Sendable {
    /// 原始查询。
    var query: String
    /// 任务画像（决定 fast path / plan）。
    var profile: HoloAgentTaskProfile
    /// 解析出时间语义（如有）。
    var resolvedTime: HoloAgentResolvedTimeScopeExtended?
    /// 解析出的对比双窗（如有）。
    var resolvedComparison: HoloAgentResolvedComparison?
    /// 识别到的歧义。
    var ambiguities: [HoloAgentAmbiguity]
    /// 涉及的数据域（用于能力选择）。
    var domains: [String]
    /// 敏感度标记（健康/心理等需要降级表达）。
    var sensitivity: HoloAgentQuerySensitivity
}

nonisolated enum HoloAgentQuerySensitivity: String, Equatable, Sendable {
    case normal
    case healthData      // 健康数据
    case mentalHealth    // 心理/情绪相关
    case financial       // 财务相关
}

// MARK: - TaskProfile（P0-B 定义，P1-A 扩展使用）

/// 确定性任务画像，决定预算、是否启用 plan、工具轮次、是否强制 verifier。
nonisolated enum HoloAgentTaskProfile: String, Equatable, Sendable {
    case simpleLookup            // 单域简单查数 → fast path
    case singleDomainAnalysis    // 单域分析
    case comparisonAnalysis      // 比较分析
    case crossDomainAnalysis     // 跨域分析
    case sensitiveAnalysis       // 敏感分析（健康/心理）
    case observerFollowUp        // Observer 跟进

    /// 是否需要正式 Plan（只有复杂任务进入 plan）。
    var requiresFormalPlan: Bool {
        switch self {
        case .simpleLookup:
            return false
        case .singleDomainAnalysis, .comparisonAnalysis, .crossDomainAnalysis, .sensitiveAnalysis, .observerFollowUp:
            return true
        }
    }

    /// 是否强制 Claim Verifier 2.0。
    var requiresVerifier: Bool {
        switch self {
        case .simpleLookup:
            return false
        default:
            return true
        }
    }
}

// MARK: - AgentPlan

/// 复杂任务的正式计划。模型可提出拆解，但所有工具/字段/指标/依赖必须经 Registry 校验。
nonisolated struct HoloAgentPlan: Codable, Equatable, Sendable {
    var objective: String
    var subQuestions: [HoloAgentSubQuestion]
    var requirements: [HoloAgentMetricRequirement]
    var dependencies: [HoloAgentDependency]
    var completionCriteria: [HoloAgentCompletionCriterion]
    var unresolvedAmbiguities: [HoloAgentAmbiguity]

    /// 计划创建时间，用于持久化和恢复。
    var createdAt: Date

    init(
        objective: String,
        subQuestions: [HoloAgentSubQuestion] = [],
        requirements: [HoloAgentMetricRequirement] = [],
        dependencies: [HoloAgentDependency] = [],
        completionCriteria: [HoloAgentCompletionCriterion] = [],
        unresolvedAmbiguities: [HoloAgentAmbiguity] = [],
        createdAt: Date = Date()
    ) {
        self.objective = objective
        self.subQuestions = subQuestions
        self.requirements = requirements
        self.dependencies = dependencies
        self.completionCriteria = completionCriteria
        self.unresolvedAmbiguities = unresolvedAmbiguities
        self.createdAt = createdAt
    }
}

/// 计划中的子问题。稳定 ID 可被 Coverage Check 引用。
nonisolated struct HoloAgentSubQuestion: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var question: String
    /// 该子问题关联的 metricKey（覆盖检查用）。
    var relatedMetricKeys: [String]
    /// 当前状态。
    var status: HoloAgentSubQuestionStatus

    init(id: String, question: String, relatedMetricKeys: [String] = [], status: HoloAgentSubQuestionStatus = .pending) {
        self.id = id
        self.question = question
        self.relatedMetricKeys = relatedMetricKeys
        self.status = status
    }
}

nonisolated enum HoloAgentSubQuestionStatus: String, Codable, Equatable, Sendable {
    case pending              // 未处理
    case answered             // 已回答
    case unsupported          // 数据不足，无法回答
    case clarificationNeeded  // 需要澄清
}

/// 指标要求：计划声明的 metricKey 及其期望。
nonisolated struct HoloAgentMetricRequirement: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var metricKey: String
    var description: String
    /// 是否为必须覆盖（vs 可选）。
    var isRequired: Bool

    init(id: String, metricKey: String, description: String = "", isRequired: Bool = true) {
        self.id = id
        self.metricKey = metricKey
        self.description = description
        self.isRequired = isRequired
    }
}

/// 子问题/指标之间的依赖。
nonisolated struct HoloAgentDependency: Codable, Equatable, Sendable {
    /// 依赖项 ID（subQuestion 或 requirement）。
    var fromID: String
    var toID: String
    var reason: String
}

/// 完成标准：判断计划是否完成。
nonisolated struct HoloAgentCompletionCriterion: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var description: String
    var isMet: Bool

    init(id: String, description: String, isMet: Bool = false) {
        self.id = id
        self.description = description
        self.isMet = isMet
    }
}

// MARK: - Ambiguity（歧义分级）

/// 查询中的歧义。由系统决定处理方式，不交给模型自由发挥。
nonisolated struct HoloAgentAmbiguity: Codable, Equatable, Sendable {
    var id: String
    var description: String
    var impact: HoloAgentAmbiguityImpact
    /// 系统采用的默认假设（低影响时使用，并在回答中说明）。
    var defaultAssumption: String?
    /// 候选解析（用于中影响双算或高影响澄清）。
    var candidates: [String]

    init(id: String, description: String, impact: HoloAgentAmbiguityImpact, defaultAssumption: String? = nil, candidates: [String] = []) {
        self.id = id
        self.description = description
        self.impact = impact
        self.defaultAssumption = defaultAssumption
        self.candidates = candidates
    }
}

nonisolated enum HoloAgentAmbiguityImpact: String, Codable, Equatable, Sendable {
    case low       // 采用产品默认，并在回答中说明
    case medium    // 可在同一预算内双算，差异显著再说明
    case high      // 返回 ClarificationRequest
}

// MARK: - Clarification Request

/// Agent Loop 内的结构化澄清请求。保存恢复上下文，用户回答后恢复原 job。
nonisolated struct HoloAgentClarificationRequest: Codable, Equatable, Sendable {
    /// 澄清问题 ID。
    var id: String
    /// 向用户展示的澄清问题。
    var question: String
    /// 候选选项（如有）。
    var options: [String]
    /// 原 plan 的快照（用于恢复）。
    var originalPlan: HoloAgentPlan?
    /// 原 semantic frame 的快照。
    var originalQuery: String
    /// 澄清针对的歧义 ID。
    var ambiguityID: String
    /// 创建时间。
    var createdAt: Date

    init(
        id: String,
        question: String,
        options: [String] = [],
        originalPlan: HoloAgentPlan? = nil,
        originalQuery: String,
        ambiguityID: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.originalPlan = originalPlan
        self.originalQuery = originalQuery
        self.ambiguityID = ambiguityID
        self.createdAt = createdAt
    }
}

// MARK: - Coverage Check

/// 计划覆盖检查结果。v10 的 metric 补齐逻辑并入此处。
nonisolated struct HoloAgentPlanCoverage: Equatable, Sendable {
    var plan: HoloAgentPlan
    /// 每个 subQuestion 的状态。
    var subQuestionStatuses: [String: HoloAgentSubQuestionStatus]
    /// 覆盖的 metricKey。
    var coveredMetricKeys: Set<String>
    /// 缺失的 metricKey。
    var missingMetricKeys: Set<String>
    /// 整体覆盖状态。
    var overallStatus: HoloAgentCoverageStatus

    var isComplete: Bool {
        overallStatus == .complete
    }
}

nonisolated enum HoloAgentCoverageStatus: String, Equatable, Sendable {
    case complete      // 全部子问题 answered
    case partial       // 部分 answered，部分 unsupported
    case missing       // 有必须指标缺失
    case needsClarification  // 有子问题需澄清
}
