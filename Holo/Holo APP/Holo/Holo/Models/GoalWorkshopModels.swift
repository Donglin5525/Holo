//
//  GoalWorkshopModels.swift
//  Holo
//
//  目标共创（GoalWorkshop）纯值模型：会话状态机、事实分级、路径、契约请求/响应
//  方案：docs/_common/plans/2026-09-17-Holo目标共创-完整开发计划.md §2
//
//  本文件只含值类型与状态转移，不做持久化、不做网络。
//  apply(response:) 只接受通过 GoalWorkshopValidator 校验的候选；
//  任何校验失败在变更发生前抛错，revision 不前进。
//

import Foundation

// MARK: - 预算（§2.3）

enum GoalWorkshopBudget {
    /// 最多追问 3 个会改变目标或路径的问题（事实已足够时零追问）
    static let maxDecisionQuestions = 3
    /// 一个完整会话最多 8 次模型请求。
    /// 口径：完整流程最多 6 次（开始 1 + ≤3 追问 + 出路径 1 + 出草案 1），留 2 次余量给「继续」等补问；
    /// 失败的请求由协调器退款不占预算，所以只有真正推进流程的成功轮次才消耗。
    /// 产品决策（2026-09-19 东林拍板）：预算只是防滥用的保险丝，不是计费器；「一起想清楚」不占对话额度。
    static let maxModelRequests = 8
}

// MARK: - 阶段（§2.1）

enum GoalWorkshopPhase: String, Codable, Equatable, Sendable {
    /// 澄清：模型一次一个问题补关键缺口
    case understanding
    /// 路线：呈现 2–3 条实质不同的路径供比较
    case exploring
    /// 已选路径，待产草案
    case choosing
    /// 草案确认页
    case reviewing
    /// 已确认落库（终态，仅由提交服务写入）
    case saved
    /// 用户放弃（终态）
    case abandoned

    var isTerminal: Bool { self == .saved || self == .abandoned }
}

// MARK: - 事实（§2.1）

enum GoalWorkshopFactProvenance: String, Codable, Equatable, Sendable {
    /// 本轮用户原话（最高优先级）
    case userStated
    /// 用户授权打开的既有记录（P0 仅目标快照；P2 扩展）
    case authorizedRecord
    /// 模型推断，可被纠正
    case inference
    /// 明示的未知（缺口），不算事实参与建议
    case unknown
}

struct GoalWorkshopFact: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var text: String
    var provenance: GoalWorkshopFactProvenance
    /// authorizedRecord 必须有稳定来源标识与版本
    var sourceID: String?
    var sourceRevision: Int?
    /// 被纠正/撤回后保留痕迹，但不再进入请求快照与建议
    var isRetracted: Bool

    init(id: String = UUID().uuidString,
         text: String,
         provenance: GoalWorkshopFactProvenance,
         sourceID: String? = nil,
         sourceRevision: Int? = nil,
         isRetracted: Bool = false) {
        self.id = id
        self.text = text
        self.provenance = provenance
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.isRetracted = isRetracted
    }

    var isActive: Bool { !isRetracted && provenance != .unknown }
}

/// 外部输入边界：模型响应里的 facts 不带 sourceID/sourceRevision/isRetracted，
/// 解码缺键回退默认值，不阻断链路
extension GoalWorkshopFact {
    enum CodingKeys: String, CodingKey {
        case id, text, provenance, sourceID, sourceRevision, isRetracted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        provenance = try c.decode(GoalWorkshopFactProvenance.self, forKey: .provenance)
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID)
        sourceRevision = try c.decodeIfPresent(Int.self, forKey: .sourceRevision)
        isRetracted = (try? c.decodeIfPresent(Bool.self, forKey: .isRetracted)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(provenance, forKey: .provenance)
        try c.encodeIfPresent(sourceID, forKey: .sourceID)
        try c.encodeIfPresent(sourceRevision, forKey: .sourceRevision)
        try c.encode(isRetracted, forKey: .isRetracted)
    }
}

// MARK: - 路径与问题（§2.2）

struct GoalWorkshopQuestion: Codable, Equatable, Sendable {
    let text: String
    let whyItMatters: String
}

struct GoalRouteOption: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// 什么情况下这条路更合适
    let fit: String
    /// 大致投入
    let effort: String
    /// 这条路的代价
    let tradeoff: String
    /// 推荐理由（为什么适合用户当前状况）
    let reason: String
}

// MARK: - 目标定义（理解收敛后的核心）

struct GoalWorkshopGoalDefinition: Codable, Equatable, Sendable {
    var title: String
    var desiredOutcome: String?
    var motivation: String?
    var deadlineText: String?
}

// MARK: - 计划（§2.2 kind=plan）

struct GoalWorkshopMilestone: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    /// 严格 yyyy-MM-dd（用户时区），nil = 无日期节点
    var dateText: String?
}

struct GoalWorkshopPlan: Codable, Equatable, Sendable {
    /// 复用现有草案类型；量化字段沿用 GoalEditForm 同一口径
    var draft: GoalDraft
    /// 怎么观察「成了」
    var successEvidence: String
    var milestones: [GoalWorkshopMilestone]
    /// 引用 draft 内任务/习惯 id；可为 nil（未选行动的目标）
    var firstActionID: String?
    /// 草案依赖的未确认假设，逐条明示
    var assumptions: [String]
    /// 下次复盘日期，严格 yyyy-MM-dd
    var reviewDateText: String?

    // MARK: 目标闭环 v2 扩展（2026-10-20；全部可选，v1 响应解码为 nil，由确认页补齐）

    /// 主要结果从哪里读（manual / habit / ledger）；只能引用授权候选或本草案内的新建数值习惯
    var resultSource: GoalWorkshopResultSourceDraft? = nil
    /// 定期回顾周期（天）；nil = 用默认每周
    var reviewCadenceDays: Int? = nil
    /// 可选预算（财务模块全局约定，确认后在财务创建/复用）
    var budget: GoalWorkshopBudgetDraft? = nil
    /// 资金期次（存钱类）：明确的应存日期与金额
    var fundSchedule: [GoalWorkshopFundInstallmentDraft]? = nil
    /// 行为限制（如每周奶茶 ≤ 2 杯）：从原始数量另算，不改习惯通用完成规则
    var constraints: [GoalWorkshopConstraintDraft]? = nil

    var allActionIDs: [String] { draft.tasks.map(\.id) + draft.habits.map(\.id) }
}

// MARK: - 授权候选（客户端维护；模型只能引用其中 ID，未授权来源不进模型）

struct GoalWorkshopHabitCandidate: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    /// "checkIn" / "numeric"
    let type: String
    let unit: String?
    /// "sum" / "latest"
    let aggregation: String
    let isBadHabit: Bool

    var ref: String { "habit:\(id.uuidString)" }
}

struct GoalWorkshopAccountCandidate: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    /// AccountType.rawValue
    let type: String
    /// 信用负债账户：不能被默认为专款来源
    let isCreditLiability: Bool

    var ref: String { "account:\(id.uuidString)" }
}

struct GoalWorkshopAuthorizedCandidates: Codable, Equatable, Sendable {
    var habits: [GoalWorkshopHabitCandidate] = []
    var accounts: [GoalWorkshopAccountCandidate] = []

    static let empty = GoalWorkshopAuthorizedCandidates()

    var habitIDs: Set<UUID> { Set(habits.map(\.id)) }
    var accountIDs: Set<UUID> { Set(accounts.map(\.id)) }

    func habit(ref: String) -> GoalWorkshopHabitCandidate? {
        guard let id = Self.parse(ref, prefix: "habit:") else { return nil }
        return habits.first { $0.id == id }
    }

    func account(ref: String) -> GoalWorkshopAccountCandidate? {
        guard let id = Self.parse(ref, prefix: "account:") else { return nil }
        return accounts.first { $0.id == id }
    }

    /// 给模型的上下文引用：只含名称/单位/类型摘要，不含任何记录
    func contextRefs() -> [GoalWorkshopContextRef] {
        habits.map {
            GoalWorkshopContextRef(sourceID: $0.ref, sourceRevision: 1,
                                   summary: "既有习惯「\($0.name)」\($0.type == "numeric" ? "数值型" : "打卡型")\($0.unit.map { "，单位\($0)" } ?? "")\($0.isBadHabit ? "，坏习惯" : "")")
        } + accounts.map {
            GoalWorkshopContextRef(sourceID: $0.ref, sourceRevision: 1,
                                   summary: "财务账户「\($0.name)」\($0.isCreditLiability ? "（信用负债，不可作专款）" : "")")
        }
    }

    private static func parse(_ ref: String, prefix: String) -> UUID? {
        guard ref.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(ref.dropFirst(prefix.count)))
    }
}

// MARK: - 计划 v2 扩展载荷

struct GoalWorkshopResultSourceDraft: Codable, Equatable, Sendable {
    /// GoalResultSourceKind.rawValue：manual / habit / ledger
    var sourceType: String
    /// GoalLedgerScopeKind.rawValue：whole_ledger_delta / account_balance（仅 ledger）
    var ledgerScope: String?
    /// 授权候选引用："habit:<uuid>" / "account:<uuid>"
    var candidateRef: String?
    /// 引用本草案内新建数值习惯作为结果来源
    var habitDraftID: String?
    var unit: String?
    /// GoalHabitAggregationKind.rawValue：sum / latest / window_trend
    var aggregation: String?
    /// GoalResultComparison.rawValue：reach / stayBelow / trendDown / trendUp
    var comparison: String?
    var targetValue: Double?
    var baselineValue: Double?
    /// 没有可靠来源：结果待补齐，计划照常建立
    var isPending: Bool?
}

struct GoalWorkshopFundInstallmentDraft: Codable, Equatable, Sendable {
    /// 严格 yyyy-MM-dd
    var dueDateText: String
    var amount: Double
}

struct GoalWorkshopBudgetDraft: Codable, Equatable, Sendable {
    var isSelected: Bool
    var amount: Double
    /// BudgetPeriod.rawValue：week / month / year
    var period: String
    var accountCandidateRef: String?
    /// 分类名（确认页映射到真实分类；nil = 账户总预算）
    var categoryName: String?
    var note: String?
}

struct GoalWorkshopConstraintDraft: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var isSelected: Bool
    var title: String
    /// 二选一：本草案新建习惯 id，或授权候选引用
    var habitDraftID: String?
    var habitCandidateRef: String?
    var limitValue: Double
    var unit: String?
    /// 窗口天数（7 = 每周）
    var windowDays: Int
}

// MARK: - 响应契约（§2.2）

struct GoalWorkshopResponseV1: Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case question
        case options
        case plan
    }

    var schemaVersion: Int
    var sessionID: UUID
    var revision: Int
    var kind: Kind
    var assistantText: String?
    var question: GoalWorkshopQuestion?
    var options: [GoalRouteOption]?
    var recommendedOptionID: String?
    var plan: GoalWorkshopPlan?
    /// 模型本轮的推断/未知声明（可选；userStated/authorizedRecord 由客户端维护，模型不得代答）
    var facts: [GoalWorkshopFact]?

    init(schemaVersion: Int = 1,
         sessionID: UUID,
         revision: Int,
         kind: Kind,
         assistantText: String? = nil,
         question: GoalWorkshopQuestion? = nil,
         options: [GoalRouteOption]? = nil,
         recommendedOptionID: String? = nil,
         plan: GoalWorkshopPlan? = nil,
         facts: [GoalWorkshopFact]? = nil) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.revision = revision
        self.kind = kind
        self.assistantText = assistantText
        self.question = question
        self.options = options
        self.recommendedOptionID = recommendedOptionID
        self.plan = plan
        self.facts = facts
    }
}

extension GoalWorkshopResponseV1: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionID, revision, kind, assistantText
        case question, options, recommendedOptionID, plan, facts
    }

    /// 外部输入边界：版本/枚举未知直接抛错，由调用方做一次受控重试，
    /// 不把未知 schema 当空草案覆盖当前会话
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else {
            throw GoalWorkshopValidationError.unsupportedSchemaVersion(version)
        }
        schemaVersion = version
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        revision = try c.decode(Int.self, forKey: .revision)
        let kindRaw = try c.decode(String.self, forKey: .kind)
        guard let parsedKind = Kind(rawValue: kindRaw) else {
            throw GoalWorkshopValidationError.unknownKind(kindRaw)
        }
        kind = parsedKind
        assistantText = try c.decodeIfPresent(String.self, forKey: .assistantText)
        question = try c.decodeIfPresent(GoalWorkshopQuestion.self, forKey: .question)
        options = try c.decodeIfPresent([GoalRouteOption].self, forKey: .options)
        recommendedOptionID = try c.decodeIfPresent(String.self, forKey: .recommendedOptionID)
        plan = try c.decodeIfPresent(GoalWorkshopPlan.self, forKey: .plan)
        facts = try c.decodeIfPresent([GoalWorkshopFact].self, forKey: .facts)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(revision, forKey: .revision)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(assistantText, forKey: .assistantText)
        try c.encodeIfPresent(question, forKey: .question)
        try c.encodeIfPresent(options, forKey: .options)
        try c.encodeIfPresent(recommendedOptionID, forKey: .recommendedOptionID)
        try c.encodeIfPresent(plan, forKey: .plan)
        try c.encodeIfPresent(facts, forKey: .facts)
    }
}

// MARK: - 请求契约（§2.2）

struct GoalWorkshopContextRef: Codable, Equatable, Sendable {
    /// 经授权的既有记录引用（P0：用户打开的目标快照）
    let sourceID: String
    let sourceRevision: Int
    let summary: String
}

struct GoalWorkshopSessionSnapshotV1: Codable, Equatable, Sendable {
    let phase: GoalWorkshopPhase
    let questionsAsked: Int
    let originalText: String
    /// 未撤回的有效事实（含来源分级）
    let activeFacts: [GoalWorkshopFact]
    let routeOptions: [GoalRouteOption]
    let selectedRouteID: String?
    let goalDefinition: GoalWorkshopGoalDefinition?
    /// 用户时区当天，严格 yyyy-MM-dd
    let today: String
}

struct GoalWorkshopRequestV1: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Equatable, Sendable {
        case understand
        case proposeOptions = "propose_options"
        case buildPlan = "build_plan"
        case replan
    }

    var schemaVersion: Int = 1
    var sessionID: UUID
    var revision: Int
    var operation: Operation
    /// 本轮用户输入；nil = 无新输入（如直接请求产草案）
    var input: String?
    /// 用户跳过了当前问题（understand 操作携带）
    var skippedQuestion: Bool
    var sessionSnapshot: GoalWorkshopSessionSnapshotV1
    /// 经授权的上下文引用；P0 仅目标快照，P2 扩展
    var contextRefs: [GoalWorkshopContextRef]

    init(sessionID: UUID,
         revision: Int,
         operation: Operation,
         input: String? = nil,
         skippedQuestion: Bool = false,
         sessionSnapshot: GoalWorkshopSessionSnapshotV1,
         contextRefs: [GoalWorkshopContextRef] = []) {
        self.schemaVersion = 1
        self.sessionID = sessionID
        self.revision = revision
        self.operation = operation
        self.input = input
        self.skippedQuestion = skippedQuestion
        self.sessionSnapshot = sessionSnapshot
        self.contextRefs = contextRefs
    }
}

// MARK: - 状态机错误

enum GoalWorkshopStateError: Error, Equatable {
    /// 用户操作发生在不允许的阶段
    case phaseDoesNotAllow(GoalWorkshopPhase, String)
    case noRecommendedRouteToSkip
    case factNotFound(String)
    case requestBudgetExhausted
    case alreadyTerminal(GoalWorkshopPhase)
}

// MARK: - 会话（§2.1）

struct GoalWorkshopSessionV1: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// P0：已有目标入口只给建议不写回，goalID 仅作引用；新建时 nil
    var goalID: UUID?
    var phase: GoalWorkshopPhase
    /// 乐观并发版本：用户操作与通过的模型响应各 +1；校验失败不前进
    var revision: Int
    var originalText: String
    /// 全部事实（含撤回痕迹）；请求快照只取 active
    var facts: [GoalWorkshopFact]
    /// 当前单个待答问题
    var currentQuestion: GoalWorkshopQuestion?
    var questionsAsked: Int
    /// 用户跳过追问后，协调器据此改发 propose_options
    var questioningSkipped: Bool
    var routeOptions: [GoalRouteOption]
    var recommendedRouteID: String?
    var selectedRouteID: String?
    var goalDefinition: GoalWorkshopGoalDefinition?
    var plan: GoalWorkshopPlan?
    /// 已发出的模型请求数（≤ GoalWorkshopBudget.maxModelRequests）
    var requestCount: Int
    var createdAt: Date
    var updatedAt: Date
    /// 保存成功后由提交服务写入
    var appliedGoalID: UUID?
    /// 最近一次模型输出失败原因（展示用；不影响状态）
    var lastModelFailureText: String?
    /// 模型最近一轮的回应语（协议里有、此前被丢弃；2026-09-19 起随问题/路径卡展示，补对话感）
    var lastAssistantText: String?
    /// 用户最近一次回答原话（问答卡回显，让「我说过什么」可见）
    var lastUserReply: String?
    /// 本会话开始时授权给模型引用的既有习惯/账户候选（客户端维护；nil = 旧会话/无候选）。
    /// 校验器只放行其中的 ID；提交时据此解析复用对象。
    var authorizedCandidates: GoalWorkshopAuthorizedCandidates?

    init(id: UUID = UUID(),
         goalID: UUID? = nil,
         phase: GoalWorkshopPhase = .understanding,
         revision: Int = 0,
         originalText: String,
         facts: [GoalWorkshopFact] = [],
         currentQuestion: GoalWorkshopQuestion? = nil,
         questionsAsked: Int = 0,
         questioningSkipped: Bool = false,
         routeOptions: [GoalRouteOption] = [],
         recommendedRouteID: String? = nil,
         selectedRouteID: String? = nil,
         goalDefinition: GoalWorkshopGoalDefinition? = nil,
         plan: GoalWorkshopPlan? = nil,
         requestCount: Int = 0,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         appliedGoalID: UUID? = nil,
         lastModelFailureText: String? = nil,
         lastAssistantText: String? = nil,
         lastUserReply: String? = nil,
         authorizedCandidates: GoalWorkshopAuthorizedCandidates? = nil) {
        self.id = id
        self.goalID = goalID
        self.phase = phase
        self.revision = revision
        self.originalText = originalText
        self.facts = facts
        self.currentQuestion = currentQuestion
        self.questionsAsked = questionsAsked
        self.questioningSkipped = questioningSkipped
        self.routeOptions = routeOptions
        self.recommendedRouteID = recommendedRouteID
        self.selectedRouteID = selectedRouteID
        self.goalDefinition = goalDefinition
        self.plan = plan
        self.requestCount = requestCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.appliedGoalID = appliedGoalID
        self.lastModelFailureText = lastModelFailureText
        self.lastAssistantText = lastAssistantText
        self.lastUserReply = lastUserReply
        self.authorizedCandidates = authorizedCandidates
    }

    var candidates: GoalWorkshopAuthorizedCandidates { authorizedCandidates ?? .empty }

    var activeFacts: [GoalWorkshopFact] { facts.filter(\.isActive) }

    /// 定义/草案卡是否有内容可显；没有就不渲染（避免空卡渲染成小灰圆的怪相）
    var hasDefinitionContent: Bool { goalDefinition != nil || plan != nil }

    // MARK: 用户操作（各 +1 revision；非法阶段抛错且不变更）

    /// 记录用户本轮回答：追加 userStated 事实并清掉当前问题
    mutating func applyUserReply(_ text: String) throws {
        try ensureNotTerminal("reply")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GoalWorkshopStateError.phaseDoesNotAllow(phase, "空回复")
        }
        facts.append(GoalWorkshopFact(text: trimmed, provenance: .userStated))
        lastUserReply = trimmed
        currentQuestion = nil
        touch()
    }

    /// 跳过当前问题：understanding 只清问题并标记跳过（协调器改问路径）；
    /// exploring 等价于接受推荐路径
    mutating func skipQuestion() throws {
        try ensureNotTerminal("skip")
        switch phase {
        case .understanding:
            currentQuestion = nil
            questioningSkipped = true
            lastUserReply = nil
            touch()
        case .exploring:
            guard let recommended = recommendedRouteID else {
                throw GoalWorkshopStateError.noRecommendedRouteToSkip
            }
            selectedRouteID = recommended
            phase = .choosing
            touch()
        default:
            throw GoalWorkshopStateError.phaseDoesNotAllow(phase, "skip")
        }
    }

    /// 选择路径：exploring（或 choosing 重选）→ choosing
    mutating func choose(routeID: String) throws {
        try ensureNotTerminal("choose")
        guard phase == .exploring || phase == .choosing else {
            throw GoalWorkshopStateError.phaseDoesNotAllow(phase, "choose")
        }
        guard routeOptions.contains(where: { $0.id == routeID }) else {
            throw GoalWorkshopStateError.factNotFound(routeID)
        }
        selectedRouteID = routeID
        phase = .choosing
        currentQuestion = nil
        touch()
    }

    /// 纠正事实：撤回旧条目（保留痕迹）并追加用户陈述
    mutating func correctFact(id: String, with text: String) throws {
        try ensureNotTerminal("correctFact")
        guard let index = facts.firstIndex(where: { $0.id == id }) else {
            throw GoalWorkshopStateError.factNotFound(id)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GoalWorkshopStateError.phaseDoesNotAllow(phase, "空纠正")
        }
        facts[index].isRetracted = true
        facts.append(GoalWorkshopFact(text: trimmed, provenance: .userStated))
        touch()
    }

    /// 返回上一步：reviewing→choosing（清草案）；choosing→exploring（清选择）
    mutating func goBack() throws {
        try ensureNotTerminal("goBack")
        switch phase {
        case .reviewing:
            plan = nil
            phase = .choosing
            touch()
        case .choosing:
            selectedRouteID = nil
            phase = .exploring
            touch()
        default:
            throw GoalWorkshopStateError.phaseDoesNotAllow(phase, "goBack")
        }
    }

    /// 放弃会话：任何未保存阶段可进入终态
    mutating func abandon() throws {
        guard !phase.isTerminal else {
            throw GoalWorkshopStateError.alreadyTerminal(phase)
        }
        phase = .abandoned
        touch()
    }

    /// 保存回执（仅提交服务调用）：reviewing→saved
    mutating func markSaved(appliedGoalID: UUID) throws {
        guard phase == .reviewing else {
            throw GoalWorkshopStateError.phaseDoesNotAllow(phase, "markSaved")
        }
        phase = .saved
        self.appliedGoalID = appliedGoalID
        touch()
    }

    /// 记录一次模型输出失败（展示用）。前进 revision：
    /// 既让不前进状态的变更能落库（store 单调守卫），也让随后到达的旧轮响应天然变 stale。
    mutating func recordModelFailure(_ text: String) {
        lastModelFailureText = text
        touch()
    }

    // MARK: 模型请求预算

    /// 发起模型请求前调用：超出预算抛错（协调器据此给「重新开始」出口）。
    /// 预算消耗是会话状态：前进 revision 使其可落库，请求体按新 revision 构建并要求模型回显。
    mutating func beginModelRequest() throws {
        guard requestCount < GoalWorkshopBudget.maxModelRequests else {
            throw GoalWorkshopStateError.requestBudgetExhausted
        }
        requestCount += 1
        touch()
    }

    /// 请求失败后退款：没拿到结果的轮次不占预算（预算是保险丝，不是计费器）。
    /// 退款也前进 revision，保证能越过 store 的单调守卫落库。
    mutating func refundModelRequest() {
        guard requestCount > 0 else { return }
        requestCount -= 1
        touch()
    }

    // MARK: 模型响应应用（先校验后转移，失败不前进 revision）

    /// 校验并应用模型响应：sessionID/revision 匹配才接受；
    /// 同轮重复提交的第二次因 revision 已前进而变 stale，天然丢弃
    mutating func apply(_ response: GoalWorkshopResponseV1) throws {
        try GoalWorkshopValidator.validate(response, for: self)

        switch response.kind {
        case .question:
            currentQuestion = response.question
            questionsAsked += 1
        case .options:
            routeOptions = response.options ?? []
            recommendedRouteID = response.recommendedOptionID
            selectedRouteID = nil
            currentQuestion = nil
            phase = .exploring
        case .plan:
            plan = response.plan
            if let draft = response.plan?.draft {
                goalDefinition = GoalWorkshopGoalDefinition(
                    title: draft.title,
                    desiredOutcome: draft.desiredOutcome,
                    motivation: draft.motivation,
                    deadlineText: draft.deadlineText
                )
            }
            currentQuestion = nil
            phase = .reviewing
        }

        mergeInferences(response.facts ?? [])
        lastModelFailureText = nil
        lastAssistantText = response.assistantText
        touch()
    }

    /// 模型推断整组替换（最新一轮为准）；userStated/authorizedRecord 只由客户端写入
    private mutating func mergeInferences(_ incoming: [GoalWorkshopFact]) {
        facts.removeAll { $0.provenance == .inference }
        for var fact in incoming where fact.provenance == .inference {
            fact.isRetracted = false
            facts.append(fact)
        }
    }

    private mutating func touch() {
        revision += 1
        updatedAt = Date()
    }

    private func ensureNotTerminal(_ action: String) throws {
        guard !phase.isTerminal else {
            throw GoalWorkshopStateError.alreadyTerminal(phase)
        }
    }

    // MARK: 请求快照

    func buildSnapshot(today: Date = Date(), timeZone: TimeZone = .current) -> GoalWorkshopSessionSnapshotV1 {
        GoalWorkshopSessionSnapshotV1(
            phase: phase,
            questionsAsked: questionsAsked,
            originalText: originalText,
            activeFacts: activeFacts,
            routeOptions: routeOptions,
            selectedRouteID: selectedRouteID,
            goalDefinition: goalDefinition,
            today: Self.dayString(from: today, timeZone: timeZone)
        )
    }

    static func dayString(from date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
