//
//  MemoryInsightModels.swift
//  Holo
//
//  记忆洞察展示层值类型
//  包含周期类型、状态、卡片、证据、载荷等模型
//

import Foundation

// MARK: - Decimal Codable

extension Decimal {
    var codableValue: Double { (self as NSDecimalNumber).doubleValue }
    init(codableValue: Double) { self = Decimal(codableValue) }
}

// MARK: - Period Type

/// 洞察周期类型
enum MemoryInsightPeriodType: String, Codable, CaseIterable {
    case daily
    case weekly
    case monthly
    case quarterly
    case custom
}

// MARK: - Observation Stage

/// 本周观察的阶段（light3d 轻量版 / full7d 完整版）
/// 见本周观察方案 §3.2。旧数据 observationStage == nil 视为 full7d/legacy。
enum MemoryInsightObservationStage: String, Codable {
    case light3d   // 3 个有效记录日触发的轻量版
    case full7d    // 7 个有效记录日触发的完整版
}

// MARK: - Status

/// 洞察生成状态
enum MemoryInsightStatus: String, Codable {
    case generating
    case ready
    case failed
    case stale
}

// MARK: - Anomaly Severity

/// 异常严重度
enum AnomalySeverity: String, Codable {
    case info
    case warning
    case critical
}

// MARK: - Anomaly Type

/// 异常类型
enum AnomalyType: String, Codable {
    case spendingSpike
    case habitBreak
    case negativeHabitTrend
    case taskOverload
    case budgetOverrun
    case budgetWarning
}

// MARK: - Feedback Types

/// 准确性评分
enum AccuracyRating: String, Codable {
    case accurate
    case inaccurate
}

/// 价值感评分
enum ValueRating: String, Codable {
    case useful
    case notUseful
    case notMeaningful
}

/// 不准原因分类
enum FeedbackReasonType: String, Codable, CaseIterable {
    case dataWrong         // 数据不准
    case relationWrong     // 关联不准
    case priorityWrong     // 重点不准
    case suggestionWrong   // 建议不适合
    case toneWrong         // 语气不喜欢
    case tooFrequent       // 少提醒这个

    var displayName: String {
        switch self {
        case .dataWrong: return "数据不准"
        case .relationWrong: return "关联不准"
        case .priorityWrong: return "重点不准"
        case .suggestionWrong: return "建议不适合"
        case .toneWrong: return "语气不喜欢"
        case .tooFrequent: return "少提醒这个"
        }
    }
}

// MARK: - Anomaly Observation

/// 结构化异常观察
struct AnomalyObservation: Codable, Equatable {
    let type: AnomalyType
    let severity: AnomalySeverity
    let scopeKey: String
    let title: String
    let summary: String
    let evidence: [String]
    let metricValue: Double?
    let baselineValue: Double?
    let ratio: Double?
}

// MARK: - Card Type

/// 洞察卡类型（约束 AI 输出范围）
enum MemoryInsightCardType: String, Codable, CaseIterable {
    case habit
    case finance
    case task
    case thought
    case milestone
    case crossDomain = "cross_domain"
    case overview
    case anomaly
}

// MARK: - Evidence

/// AI 输出的 evidence 只有描述性字段，不直接引用 UUID。
/// 后处理映射在 MemoryInsightService.postProcessEvidence() 中完成。
nonisolated struct MemoryInsightEvidence: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let date: String?          // yyyy-MM-dd，AI 从 context 中引用
    let sourceType: String?    // "habitRecord" / "transaction" / "task" / "thought"
    /// 仅供后处理使用：AI 输出时为 nil，Service 后处理填充真实 UUID
    var matchedSourceId: UUID?
}

// MARK: - Memory Candidate Payload

/// LLM 输出的记忆候选语义字段（嵌入在洞察卡片中）
nonisolated struct MemoryCandidatePayload: Codable, Equatable {
    /// 语义类型：phaseShift / stablePattern / driftSignal / lifeEvent / statMilestone
    let semanticType: String
    /// 给用户审核的事实摘要，不含建议
    let displaySummary: String
    /// 给 HoloAI 使用的上下文摘要，含误用边界
    let aiUseSummary: String
}

// MARK: - Card

/// 单张洞察卡
nonisolated struct MemoryInsightCard: Codable, Identifiable, Equatable {
    let id: String
    let type: MemoryInsightCardType
    let title: String
    let body: String
    let evidence: [MemoryInsightEvidence]
    let suggestedQuestion: String?
    /// anomaly 卡片的严重度，其他类型为 nil
    let anomalySeverity: AnomalySeverity?
    /// overview/anomaly/crossDomain 等多模块卡片补充归属，post-process 填充
    let moduleHint: String?
    /// rerank 用的模式标识（如 spending_increase / habit_break），post-process 填充
    let patternType: String?
    /// 记忆候选语义字段（仅 habit/finance/task/milestone 卡片有值）
    let memoryCandidate: MemoryCandidatePayload?

    init(id: String, type: MemoryInsightCardType, title: String, body: String,
         evidence: [MemoryInsightEvidence], suggestedQuestion: String?,
         anomalySeverity: AnomalySeverity? = nil,
         moduleHint: String? = nil, patternType: String? = nil,
         memoryCandidate: MemoryCandidatePayload? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.body = body
        self.evidence = evidence
        self.suggestedQuestion = suggestedQuestion
        self.anomalySeverity = anomalySeverity
        self.moduleHint = moduleHint
        self.patternType = patternType
        self.memoryCandidate = memoryCandidate
    }
}

// MARK: - Payload

/// AI 生成结果完整载荷
nonisolated struct MemoryInsightPayload: Codable, Equatable {
    let title: String
    let summary: String
    let cards: [MemoryInsightCard]
    let suggestedQuestions: [String]
}

// MARK: - Generation State

/// ViewModel 中追踪洞察生成状态
enum InsightGenerationState: Equatable {
    case idle               // 初始态，尚未查询
    case notConfigured      // AI 未配置
    case generating         // 正在生成
    case ready              // 已生成，可用
    case stale              // 有更新数据，旧洞察可刷新
    case needConsent        // AI 数据处理授权未开启
    case failed(String)     // 生成失败
}

// MARK: - Error

/// 洞察生成错误
enum MemoryInsightError: LocalizedError {
    case aiNotConfigured
    case generationInProgress
    case generationTimeout
    case parsingFailed(String)
    case contextBuildFailed(String)
    /// AI 数据处理授权未开启（最终防线抛出，见本周观察方案 §4.1）
    case aiDataProcessingConsentRequired

    var errorDescription: String? {
        switch self {
        case .aiNotConfigured:
            return "AI 服务暂时不可用，请稍后重试"
        case .generationInProgress:
            return "正在生成中，请勿重复操作"
        case .generationTimeout:
            return "生成超时，请检查网络后重试"
        case .parsingFailed(let detail):
            return "AI 返回格式异常：\(detail)"
        case .contextBuildFailed(let detail):
            return "数据聚合失败：\(detail)"
        case .aiDataProcessingConsentRequired:
            return "未开启 AI 数据处理授权，无法生成洞察"
        }
    }
}

// MARK: - Context Models

/// 记忆洞察上下文（周期级数据快照）
struct MemoryInsightContext: Codable, Equatable {
    let periodType: MemoryInsightPeriodType
    let periodStart: Date
    let periodEnd: Date
    let generatedAt: Date
    let localeIdentifier: String

    let finance: MemoryInsightFinanceContext
    let habits: MemoryInsightHabitContext
    let tasks: MemoryInsightTaskContext
    let thoughts: MemoryInsightThoughtContext
    let milestones: [MemoryInsightMilestoneContext]
    let crossModuleCorrelations: [CrossModuleCorrelation]
    let monthlyInsightDigests: [MonthlyInsightDigest]
    let anomalies: [AnomalyObservation]
    let previousPeriodReview: PreviousPeriodReview?
    let dailySnapshots: [DailyLifeSnapshot]?
    let lifeEvents: [LifeEvent]?
    let personalBaseline: PersonalBaseline?
    let personalProfileContext: String?
    let insightPreferenceContext: String?
    let expressionDecisionContext: String?
    let lifePatternContext: String?
    /// 健康洞察上下文（Phase 5 新增，可选）
    let health: HealthInsightContext?

    init(
        periodType: MemoryInsightPeriodType,
        periodStart: Date,
        periodEnd: Date,
        generatedAt: Date,
        localeIdentifier: String,
        finance: MemoryInsightFinanceContext,
        habits: MemoryInsightHabitContext,
        tasks: MemoryInsightTaskContext,
        thoughts: MemoryInsightThoughtContext,
        milestones: [MemoryInsightMilestoneContext],
        crossModuleCorrelations: [CrossModuleCorrelation],
        monthlyInsightDigests: [MonthlyInsightDigest],
        anomalies: [AnomalyObservation],
        previousPeriodReview: PreviousPeriodReview?,
        dailySnapshots: [DailyLifeSnapshot]? = nil,
        lifeEvents: [LifeEvent]? = nil,
        personalBaseline: PersonalBaseline? = nil,
        personalProfileContext: String? = nil,
        insightPreferenceContext: String? = nil,
        expressionDecisionContext: String? = nil,
        lifePatternContext: String? = nil,
        health: HealthInsightContext? = nil
    ) {
        self.periodType = periodType
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.generatedAt = generatedAt
        self.localeIdentifier = localeIdentifier
        self.finance = finance
        self.habits = habits
        self.tasks = tasks
        self.thoughts = thoughts
        self.milestones = milestones
        self.crossModuleCorrelations = crossModuleCorrelations
        self.monthlyInsightDigests = monthlyInsightDigests
        self.anomalies = anomalies
        self.previousPeriodReview = previousPeriodReview
        self.dailySnapshots = dailySnapshots
        self.lifeEvents = lifeEvents
        self.personalBaseline = personalBaseline
        self.personalProfileContext = personalProfileContext
        self.insightPreferenceContext = insightPreferenceContext
        self.expressionDecisionContext = expressionDecisionContext
        self.lifePatternContext = lifePatternContext
        self.health = health
    }
}

// MARK: - Cross-Module Types

enum InsightModule: String, Codable {
    case finance, habit, task, thought, health
}

struct CrossModuleCorrelation: Codable, Equatable {
    let modulePair: [InsightModule]
    let observation: String
    let signalStrength: Double
    let summary: String
    let patternType: String?
    let evidenceDates: [String]

    init(
        modulePair: [InsightModule],
        observation: String,
        signalStrength: Double,
        summary: String,
        patternType: String? = nil,
        evidenceDates: [String] = []
    ) {
        self.modulePair = modulePair
        self.observation = observation
        self.signalStrength = signalStrength
        self.summary = summary
        self.patternType = patternType
        self.evidenceDates = evidenceDates
    }
}

// MARK: - Annual Review Types

struct MonthlyInsightDigest: Codable, Equatable {
    let periodStart: Date
    let periodEnd: Date
    let summary: String
    let keyFindings: [String]
    let moduleSnapshots: [ModuleSnapshot]
}

struct ModuleSnapshot: Codable, Equatable {
    let module: InsightModule
    let headline: String
}

struct MemoryInsightFinanceContext: Codable, Equatable {
    let totalExpense: Decimal
    let totalIncome: Decimal
    let topCategories: [CategoryAmountSummary]
    let dailyExpenses: [DailyAmountSummary]
    let previousPeriodExpense: Decimal
    let budgetPerformance: BudgetPerformanceSummary?
    let anomalyDescriptions: [String]
    let weekdayWeekendSpending: WeekdayWeekendSpendingSummary?
    let semanticSummary: FinanceSemanticSummary?
}

struct BudgetPerformanceSummary: Codable, Equatable {
    let totalBudget: Decimal
    let totalSpent: Decimal
    let progressPercent: Double
    let isOnTrack: Bool
    let warningCategories: [String]
}

struct MemoryInsightHabitContext: Codable, Equatable {
    let activeHabitCount: Int
    let completedRecordCount: Int
    let previousPeriodCompletedRecordCount: Int
    let streaks: [HabitStreakSummary]
    let averageCompletionRate: Double?
    let topPerformingHabits: [String]
    let strugglingHabits: [String]
    let habitPerformanceSummaries: [HabitPerformanceSummary]
    let habitCategoryCompletionSummaries: [HabitCategoryCompletionSummary]
}

struct HabitPerformanceSummary: Codable, Equatable {
    let habitName: String
    let polarity: HabitPolarity
    let successRule: HabitSuccessRule
    let completionRate: Double
    let totalValue: Double?
    let targetValue: Double?
    let unit: String?
    let controlledDays: Int?
    let overLimitDays: Int?
    let completedDays: Int
    let totalDays: Int
}

struct MemoryInsightTaskContext: Codable, Equatable {
    let completedCount: Int
    let overdueCount: Int
    let importantCompletedTasks: [String]
    let totalCount: Int
    let completionRate: Double
    let highPriorityCompletionRate: Double?
    let dailyCompletionTrend: [DailyTaskCount]
    let dueInPeriod: Int
    let createdInPeriod: Int
    let completedInPeriod: Int
    let newOverdueInPeriod: Int
    let carriedOverBacklogCount: Int
    let activeBacklogCount: Int
    let periodCompletionScopeNote: String
}

struct MemoryInsightThoughtContext: Codable, Equatable {
    let totalCount: Int
    let recentSnippets: [String]
    let textContents: [String]
    let moodDistribution: [String: Int]
    let topTags: [String]
    let thoughtSentimentSummary: ThoughtSentimentSummary
}

struct MemoryInsightMilestoneContext: Codable, Equatable {
    let title: String
    let description: String
    let date: Date
}

// MARK: - Context Sub-Types

struct CategoryAmountSummary: Codable, Equatable {
    let categoryName: String
    let amount: Decimal
}

struct DailyAmountSummary: Codable, Equatable {
    let date: String   // yyyy-MM-dd
    let amount: Decimal
}

struct HabitStreakSummary: Codable, Equatable {
    let habitName: String
    let streakDays: Int
}

// MARK: - Cross-Domain Context Summaries

struct WeekdayWeekendSpendingSummary: Codable, Equatable {
    let weekdayExpense: Decimal
    let weekendExpense: Decimal
    let weekdayTransactionCount: Int
    let weekendTransactionCount: Int
}

struct HabitCategoryCompletionSummary: Codable, Equatable {
    let categoryName: String
    let activeHabitCount: Int
    let averageCompletionRate: Double
}

struct ThoughtSentimentSummary: Codable, Equatable {
    let negativeRatio: Double?
    let source: String // "mood", "text", "none"
}

struct PreviousPeriodReview: Codable, Equatable {
    let previousSuggestions: [String]
    let previousAnomalyTitles: [String]
    let previousSummary: String?
}

// MARK: - Life Trajectory Models

struct LifeEvent: Codable, Equatable, Sendable {
    let id: String
    let date: String
    let module: String      // finance | habit | task | thought
    let type: String        // expense | income | habitCompleted | habitMissed | taskCompleted | taskOverdue | thoughtCreated
    let title: String
    let valueText: String?
    let tags: [String]
    let sourceId: String?
}

struct DailyLifeSnapshot: Codable, Equatable, Sendable {
    let date: String
    let expenseTotalText: String
    let taskCreatedCount: Int
    let taskCompletedCount: Int
    let overdueCount: Int
    let habitCompletionRate: Double?
    let thoughtCount: Int
    let topSignals: [String]
}

struct PersonalBaseline: Codable, Equatable, Sendable {
    let baselineStart: Date
    let baselineEnd: Date
    let effectiveWeekCount: Int
    let expenseWeeklyAverageText: String?
    let categoryAverages: [CategoryBaseline]
    let taskCompletionRateAverage: Double?
    let habitCompletionRateAverage: Double?
    let usualHighExpenseWeekdays: [String]
}

struct CategoryBaseline: Codable, Equatable, Sendable {
    let categoryName: String
    let weeklyAverageText: String
}
