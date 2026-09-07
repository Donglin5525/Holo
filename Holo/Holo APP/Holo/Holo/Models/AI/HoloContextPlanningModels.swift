//
//  HoloContextPlanningModels.swift
//  Holo
//
//  通用个人情境规划的 DTO（实施方案 §7/§8）。
//
//  本文件首版交付 frame（P5 检索输入）；run/draft 状态机 DTO 随 P6 补齐。
//  全部纯数据，可 standalone 编译。
//

import Foundation

// MARK: - 规划请求框架（§7 输入）

/// 一轮规划请求的目标框架：由意图识别或显式入口准备；检索方向由模型按目标提出，
/// 不用场景词表（§0）。
nonisolated struct HoloPlanningRequestFrame: Codable, Equatable, Sendable {
    /// 本轮用户原话。
    var utterance: String
    /// 一句话目标。
    var goalSummary: String
    /// 成功条件（模型反推或用户明说）。
    var successConditions: [String]
    /// 范围限定（如「只考虑工作日」「老家的房子」）。
    var scope: String?
    /// 时间表达（保留相对表述；锚点时间由程序注入 referenceTime 解析）。
    var timeRangeExpression: String?
    /// 已有安排（用户提到的既有日程/计划）。
    var existingArrangements: [String]
    /// 当前未知。
    var unknowns: [String]
    /// 最多 4 个开放语义检索方向（覆盖责任/时间/依赖/约束/偏好等角度）。
    var retrievalDirections: [String]
    /// 解析时间（相对时间锚点）。
    var referenceTime: Date

    init(
        utterance: String,
        goalSummary: String,
        successConditions: [String] = [],
        scope: String? = nil,
        timeRangeExpression: String? = nil,
        existingArrangements: [String] = [],
        unknowns: [String] = [],
        retrievalDirections: [String] = [],
        referenceTime: Date
    ) {
        self.utterance = utterance
        self.goalSummary = goalSummary
        self.successConditions = successConditions
        self.scope = scope
        self.timeRangeExpression = timeRangeExpression
        self.existingArrangements = existingArrangements
        self.unknowns = unknowns
        self.retrievalDirections = Array(retrievalDirections.prefix(4))
        self.referenceTime = referenceTime
    }

    enum CodingKeys: String, CodingKey {
        case utterance, goalSummary, successConditions, scope
        case timeRangeExpression, existingArrangements, unknowns
        case retrievalDirections, referenceTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utterance = try c.decode(String.self, forKey: .utterance)
        goalSummary = try c.decode(String.self, forKey: .goalSummary)
        successConditions = try c.decodeIfPresent([String].self, forKey: .successConditions) ?? []
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        timeRangeExpression = try c.decodeIfPresent(String.self, forKey: .timeRangeExpression)
        existingArrangements = try c.decodeIfPresent([String].self, forKey: .existingArrangements) ?? []
        unknowns = try c.decodeIfPresent([String].self, forKey: .unknowns) ?? []
        retrievalDirections = Array((try c.decodeIfPresent([String].self, forKey: .retrievalDirections) ?? []).prefix(4))
        referenceTime = try c.decode(Date.self, forKey: .referenceTime)
    }
}

// MARK: - 检索结果条目（§7.1）

/// 检索命中的情境条目：命题 + 时间/条件 + 引用，不重复整个档案。
nonisolated struct HoloContextCatalogEntry: Equatable, Sendable {
    var recordID: String
    var versionID: String
    var payload: HoloPersonalContextPayloadV1
    /// 推断类需要限定表达。
    var needsQualifiedExpression: Bool
    /// 命中来源（诊断/份额统计用，不进用户回答）。
    var matchedBy: Set<HoloContextRetrievalSignal>
    /// 周期规则的当前实例状态（本月完成不能当未做；无证据为 unknown，不默认 pending）。
    var currentOccurrenceStatus: HoloContextOccurrence.Status?

    init(
        recordID: String,
        versionID: String,
        payload: HoloPersonalContextPayloadV1,
        needsQualifiedExpression: Bool,
        matchedBy: Set<HoloContextRetrievalSignal> = [],
        currentOccurrenceStatus: HoloContextOccurrence.Status? = nil
    ) {
        self.recordID = recordID
        self.versionID = versionID
        self.payload = payload
        self.needsQualifiedExpression = needsQualifiedExpression
        self.matchedBy = matchedBy
        self.currentOccurrenceStatus = currentOccurrenceStatus
    }
}

/// 检索命中信号（份额统计：向量热度不得独占，时间/条件保份额）。
nonisolated enum HoloContextRetrievalSignal: String, Equatable, Sendable, CaseIterable {
    /// 语义向量候选。
    case semantic
    /// 明确主体/对象匹配。
    case partyMatch
    /// 与计划时间重叠的职责/规则。
    case temporalOverlap
    /// 条件及依赖匹配。
    case conditionMatch
    /// 当前会话明确相关来源。
    case sessionSource
}

/// 检索覆盖状态（§7.2 降级标注）。
nonisolated enum HoloContextSemanticCoverage: String, Codable, Equatable, Sendable {
    case full
    case degraded
}

// MARK: - 规划运行（§8.1）

nonisolated enum HoloPlanningRunState: String, Codable, Equatable, Sendable, CaseIterable {
    case preparing
    case retrieving
    case generating
    case needsInput
    case draftReady
    case failed
    case cancelled

    /// 终态（回调核对用：终态后不得再落新草案）。
    var isTerminal: Bool {
        switch self {
        case .draftReady, .failed, .cancelled: return true
        case .preparing, .retrieving, .generating, .needsInput: return false
        }
    }
}

/// 一次规划运行：runID 贯穿；每轮新需求推进 requestRevision；
/// 旧回调须同时核对 runID + requestRevision + accessGeneration（§8.1）。
nonisolated struct HoloPlanningRun: Codable, Equatable, Sendable {
    var runID: String
    var parentMessageID: String?
    var requestRevision: Int
    var state: HoloPlanningRunState
    var frame: HoloPlanningRequestFrame
    /// 发出请求时捕获的权限代际（P2 guard）。
    var accessGuard: HoloContextAccessGuard
    /// 草案修订号（每次成功生成 +1）。
    var draftRevision: Int
    /// 预算：每 run 最多 2 次生成（§11）。
    var generationsUsed: Int
    /// 已用的一次补查次数（≤1，§7.1）。
    var rawFallbacksUsed: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        runID: String = UUID().uuidString,
        parentMessageID: String? = nil,
        requestRevision: Int = 1,
        state: HoloPlanningRunState = .preparing,
        frame: HoloPlanningRequestFrame,
        accessGuard: HoloContextAccessGuard,
        draftRevision: Int = 0,
        generationsUsed: Int = 0,
        rawFallbacksUsed: Int = 0,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.runID = runID
        self.parentMessageID = parentMessageID
        self.requestRevision = requestRevision
        self.state = state
        self.frame = frame
        self.accessGuard = accessGuard
        self.draftRevision = draftRevision
        self.generationsUsed = generationsUsed
        self.rawFallbacksUsed = rawFallbacksUsed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - 方案草案（§8.2）

nonisolated enum HoloContextPlanItemKind: String, Codable, Equatable, Sendable, CaseIterable {
    case task
    case checklistItem
    case adjustment
    case information
}

/// 建议依据类型：个性化证据 / 一般常识 / 推断。
nonisolated enum HoloContextPlanBasis: String, Codable, Equatable, Sendable, CaseIterable {
    case personalEvidence
    case generalKnowledge
    case inference
}

nonisolated struct HoloContextPlanItem: Codable, Equatable, Sendable, Identifiable {
    var id: String { itemID }
    var itemID: String
    var title: String
    var kind: HoloContextPlanItemKind
    var reason: String
    var basis: HoloContextPlanBasis
    /// 采用的情境 contextID（personalEvidence 时必填且必须存在于 usedContextRefs）。
    var sourceRefs: [String]
    var preconditions: [String]
    /// 相对时间保留相对表达；缺少锚点不得伪造日历日期。
    var relativeTiming: String?
    /// 用户确认后的具体日期（仅用户选定后由程序填）。
    var confirmedDate: Date?
    var selected: Bool

    init(
        itemID: String,
        title: String,
        kind: HoloContextPlanItemKind,
        reason: String = "",
        basis: HoloContextPlanBasis = .generalKnowledge,
        sourceRefs: [String] = [],
        preconditions: [String] = [],
        relativeTiming: String? = nil,
        confirmedDate: Date? = nil,
        selected: Bool = false
    ) {
        self.itemID = itemID
        self.title = title
        self.kind = kind
        self.reason = reason
        self.basis = basis
        self.sourceRefs = sourceRefs
        self.preconditions = preconditions
        self.relativeTiming = relativeTiming
        self.confirmedDate = confirmedDate
        self.selected = selected
    }

    enum CodingKeys: String, CodingKey {
        case itemID, title, kind, reason, basis, sourceRefs
        case preconditions, relativeTiming, confirmedDate, selected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.decodeIfPresent(String.self, forKey: .itemID) ?? UUID().uuidString
        title = try c.decode(String.self, forKey: .title)
        kind = (try? c.decode(HoloContextPlanItemKind.self, forKey: .kind)) ?? .information
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        basis = (try? c.decode(HoloContextPlanBasis.self, forKey: .basis)) ?? .generalKnowledge
        sourceRefs = try c.decodeIfPresent([String].self, forKey: .sourceRefs) ?? []
        preconditions = try c.decodeIfPresent([String].self, forKey: .preconditions) ?? []
        relativeTiming = try c.decodeIfPresent(String.self, forKey: .relativeTiming)
        confirmedDate = try c.decodeIfPresent(Date.self, forKey: .confirmedDate)
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
    }
}

nonisolated struct HoloContextPlanUnknown: Codable, Equatable, Sendable {
    var question: String
    /// 为什么影响结果。
    var impact: String
    /// 哪些部分不依赖答案。
    var independentParts: String

    init(question: String, impact: String = "", independentParts: String = "") {
        self.question = question
        self.impact = impact
        self.independentParts = independentParts
    }

    private enum CodingKeys: String, CodingKey {
        case question, impact, independentParts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decode(String.self, forKey: .question)
        impact = try c.decodeIfPresent(String.self, forKey: .impact) ?? ""
        independentParts = try c.decodeIfPresent(String.self, forKey: .independentParts) ?? ""
    }
}

nonisolated struct HoloContextPlanDependencyEdge: Codable, Equatable, Sendable {
    var from: String
    var to: String

    init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// 覆盖情况（自然表达给用户，不露内部评分）。
nonisolated struct HoloContextPlanCoverage: Codable, Equatable, Sendable {
    var readSources: [String]
    var missingScopes: [String]
    /// 外部事实是否已核验（无法核验时输出待核验事项，不宣称已核实）。
    var externalFactsVerified: Bool

    init(
        readSources: [String] = [],
        missingScopes: [String] = [],
        externalFactsVerified: Bool = false
    ) {
        self.readSources = readSources
        self.missingScopes = missingScopes
        self.externalFactsVerified = externalFactsVerified
    }
}

/// 方案影响（P0）：证明个人情况改变了什么——增加/取消/调序/改时/方案选择，
/// 每个变化连接有效依据。可选字段（旧草案兼容）；没有个人依据的变化不展示。
nonisolated struct HoloContextPlanEffect: Codable, Equatable, Sendable {
    /// 变化类型：add / remove / reorder / reschedule / choice（渲染层白名单映射）。
    var kind: String
    /// 用户可读的一句话变化说明。
    var summary: String
    /// 该变化依据的情境 ID（一般性调整时空，不进「因你的情况」区块）。
    var contextRefs: [String]?

    init(kind: String, summary: String, contextRefs: [String]? = nil) {
        self.kind = kind
        self.summary = summary
        self.contextRefs = contextRefs
    }
}

/// 依据快照（P0：依据区可核对——命题在生成时从本机检索命中条目固化，非模型复述；
/// 后续来源修订/遗忘不影响已交付草案的历史展示）。
nonisolated struct HoloContextPlanBasisEntry: Codable, Equatable, Sendable {
    /// 情境 ID（对应 draft.usedContextRefs / items.sourceRefs）。
    var contextID: String
    /// 本机情境命题（萃取管道产物）。
    var statement: String
    /// 认识状态原始值（declared/observed/inferred），渲染限定表达用。
    var epistemicStatus: String?
    /// 周期实例状态原始值（unknown/done/exception）。
    var occurrenceStatus: String?

    init(
        contextID: String,
        statement: String,
        epistemicStatus: String? = nil,
        occurrenceStatus: String? = nil
    ) {
        self.contextID = contextID
        self.statement = statement
        self.epistemicStatus = epistemicStatus
        self.occurrenceStatus = occurrenceStatus
    }
}

nonisolated struct HoloContextPlanDraft: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    var runID: String
    var draftRevision: Int
    var goalSummary: String
    /// 用户可读的完整回答兜底（结构化缺失时仍能阅读）。
    var answerText: String
    /// 实际采用的情境 ID（不可用 ID 必须剔除）。
    var usedContextRefs: [String]
    var items: [HoloContextPlanItem]
    /// 最多优先展示 2 个真正影响安排的问题（§8.2）。
    var unknowns: [HoloContextPlanUnknown]
    /// 前置→后续，必须为无环图。
    var dependencyEdges: [HoloContextPlanDependencyEdge]
    var coverage: HoloContextPlanCoverage
    /// 依据快照（生成时回填；可选解码保证旧草案 JSON 兼容）。
    var basisEntries: [HoloContextPlanBasisEntry]?
    /// 方案影响（P0）：因个人情况产生的变化；模型未输出时为空，卡片诚实降级。
    var planEffects: [HoloContextPlanEffect]?

    init(
        runID: String,
        draftRevision: Int,
        goalSummary: String,
        answerText: String,
        usedContextRefs: [String] = [],
        items: [HoloContextPlanItem] = [],
        unknowns: [HoloContextPlanUnknown] = [],
        dependencyEdges: [HoloContextPlanDependencyEdge] = [],
        coverage: HoloContextPlanCoverage = HoloContextPlanCoverage(),
        basisEntries: [HoloContextPlanBasisEntry]? = nil,
        planEffects: [HoloContextPlanEffect]? = nil
    ) {
        self.schemaVersion = Self.supportedSchemaVersion
        self.runID = runID
        self.draftRevision = draftRevision
        self.goalSummary = goalSummary
        self.answerText = answerText
        self.usedContextRefs = usedContextRefs
        self.items = items
        self.unknowns = unknowns
        self.dependencyEdges = dependencyEdges
        self.coverage = coverage
        self.basisEntries = basisEntries
        self.planEffects = planEffects
    }

    /// 稳定逻辑项 ID：跨 draftRevision 对账用（P8 幂等）。
    var logicalItemKeys: Set<String> {
        Set(items.map(\.itemID))
    }
}

// MARK: - 草案解析（模型输出 → 契约 DTO）

nonisolated enum HoloContextPlanDraftParser {
    enum ParseError: Error, Equatable {
        case notJSON
        case missingAnswerText
    }

    /// 从模型原始输出解析草案（容忍围栏/噪声；answerText 必填兜底）。
    static func parse(_ raw: String, runID: String, draftRevision: Int) throws -> HoloContextPlanDraft {
        let json = HoloPersonalContextResponseParser.extractJSON(from: raw)
        guard let data = json.data(using: .utf8) else { throw ParseError.notJSON }
        struct Partial: Decodable {
            var goalSummary: String?
            var answerText: String?
            var usedContextRefs: [String]?
            var items: [HoloContextPlanItem]?
            var unknowns: [HoloContextPlanUnknown]?
            var dependencyEdges: [HoloContextPlanDependencyEdge]?
            var coverage: HoloContextPlanCoverage?
            var planEffects: [HoloContextPlanEffect]?
        }
        guard let partial = try? JSONDecoder().decode(Partial.self, from: data) else {
            throw ParseError.notJSON
        }
        guard let answerText = partial.answerText,
              !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ParseError.missingAnswerText
        }
        return HoloContextPlanDraft(
            runID: runID,
            draftRevision: draftRevision,
            goalSummary: partial.goalSummary ?? "",
            answerText: answerText,
            usedContextRefs: partial.usedContextRefs ?? [],
            items: partial.items ?? [],
            unknowns: Array((partial.unknowns ?? []).prefix(2)),
            dependencyEdges: partial.dependencyEdges ?? [],
            coverage: partial.coverage ?? HoloContextPlanCoverage(),
            planEffects: partial.planEffects
        )
    }
}
