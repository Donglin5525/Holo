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
}

// MARK: - Status

/// 洞察生成状态
enum MemoryInsightStatus: String, Codable {
    case generating
    case ready
    case failed
    case stale
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
}

// MARK: - Evidence

/// AI 输出的 evidence 只有描述性字段，不直接引用 UUID。
/// 后处理映射在 MemoryInsightService.postProcessEvidence() 中完成。
struct MemoryInsightEvidence: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let date: String?          // yyyy-MM-dd，AI 从 context 中引用
    let sourceType: String?    // "habitRecord" / "transaction" / "task" / "thought"
    /// 仅供后处理使用：AI 输出时为 nil，Service 后处理填充真实 UUID
    var matchedSourceId: UUID?
}

// MARK: - Card

/// 单张洞察卡
struct MemoryInsightCard: Codable, Identifiable, Equatable {
    let id: String
    let type: MemoryInsightCardType
    let title: String
    let body: String
    let evidence: [MemoryInsightEvidence]
    let suggestedQuestion: String?
}

// MARK: - Payload

/// AI 生成结果完整载荷
struct MemoryInsightPayload: Codable, Equatable {
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

    var errorDescription: String? {
        switch self {
        case .aiNotConfigured:
            return "AI 服务未配置，请先在设置中配置 AI Provider"
        case .generationInProgress:
            return "正在生成中，请勿重复操作"
        case .generationTimeout:
            return "生成超时，请检查网络后重试"
        case .parsingFailed(let detail):
            return "AI 返回格式异常：\(detail)"
        case .contextBuildFailed(let detail):
            return "数据聚合失败：\(detail)"
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
}

// MARK: - Cross-Module Types

enum InsightModule: String, Codable {
    case finance, habit, task, thought
}

struct CrossModuleCorrelation: Codable, Equatable {
    let modulePair: [InsightModule]
    let observation: String
    let signalStrength: Double
    let summary: String
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
}

struct MemoryInsightTaskContext: Codable, Equatable {
    let completedCount: Int
    let overdueCount: Int
    let importantCompletedTasks: [String]
    let totalCount: Int
    let completionRate: Double
    let highPriorityCompletionRate: Double?
    let dailyCompletionTrend: [DailyTaskCount]
}

struct MemoryInsightThoughtContext: Codable, Equatable {
    let totalCount: Int
    let recentSnippets: [String]
    let textContents: [String]
    let moodDistribution: [String: Int]
    let topTags: [String]
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
