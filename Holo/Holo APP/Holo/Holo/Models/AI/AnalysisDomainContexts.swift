//
//  AnalysisDomainContexts.swift
//  Holo
//
//  各分析领域的数据上下文模型
//  每个领域定义自己的结构化数据，用于卡片渲染和 LLM 注入
//

import Foundation

// MARK: - Finance

nonisolated struct FinanceAnalysisContext: Codable, Equatable, Sendable {
    let totalExpense: Decimal
    let totalIncome: Decimal
    let transactionCount: Int
    let averageDailyExpense: Decimal
    let topExpenseCategories: [FinanceCategoryItem]
    let monthlyBreakdown: [FinanceMonthlyItem]
    let previousPeriodExpense: Decimal?
    let anomalyDescriptions: [String]
    let budgetPerformance: FinanceBudgetItem?
    let subCategoryDetails: [SubCategoryDetail]?
    let categoryTrends: [CategoryTrendItem]?
    let spendingPatterns: SpendingPatterns?
    let semanticSummary: FinanceSemanticSummary?

    var isDataFree: Bool {
        totalExpense == 0 && totalIncome == 0 && transactionCount == 0
    }
}

nonisolated struct FinanceCategoryItem: Codable, Equatable, Sendable {
    let categoryName: String
    let amount: Decimal
    let percentage: Double
}

nonisolated struct FinanceMonthlyItem: Codable, Equatable, Sendable {
    let month: String
    let expense: Decimal
    let income: Decimal
}

nonisolated struct FinanceBudgetItem: Codable, Equatable, Sendable {
    let budgetAmount: Decimal
    let spentAmount: Decimal
    let remainingAmount: Decimal
    let utilizationRate: Double
    let periodType: String
}

nonisolated struct SubCategoryDetail: Codable, Equatable, Sendable {
    let parentCategoryName: String
    let subCategories: [FinanceCategoryItem]
}

nonisolated struct CategoryTrendItem: Codable, Equatable, Sendable {
    let categoryName: String
    let currentAmount: Decimal
    let previousAmount: Decimal?
    let changePercent: Double?
}

nonisolated struct SpendingPatterns: Codable, Equatable, Sendable {
    let highestSpendingDayOfWeek: DayOfWeekSpending?
    let weekdayVsWeekend: WeekdayWeekendComparison?
    let topFrequentCategories: [FrequentCategory]
}

nonisolated struct DayOfWeekSpending: Codable, Equatable, Sendable {
    let dayName: String
    let averageAmount: Decimal
}

nonisolated struct WeekdayWeekendComparison: Codable, Equatable, Sendable {
    let weekdayAverage: Decimal
    let weekendAverage: Decimal
}

nonisolated struct FrequentCategory: Codable, Equatable, Sendable {
    let categoryName: String
    let transactionCount: Int
    let totalAmount: Decimal
}

nonisolated struct FinanceSemanticSummary: Codable, Equatable, Sendable {
    let fixedNecessaryExpenseTotal: Decimal
    let actionableExpenseTotal: Decimal
    let fixedNecessaryCategories: [FinanceCategoryItem]
    let transport: TransportSpendingSummary?
    let incomeCadenceHint: String?
}

nonisolated struct TransportSpendingSummary: Codable, Equatable, Sendable {
    let totalAmount: Decimal
    let transactionCount: Int
    let taxiAmount: Decimal
    let taxiCount: Int
    let publicTransitAmount: Decimal
    let publicTransitCount: Int
    let longDistanceAmount: Decimal
    let longDistanceCount: Int
    let taxiAmountRatio: Double?
    let analysisHint: String
}

// MARK: - Habit

nonisolated struct HabitAnalysisContext: Codable, Equatable, Sendable {
    let activeHabitCount: Int
    let completedRecordCount: Int
    let averageCompletionRate: Double?
    let topPerformingHabits: [HabitPerformanceItem]
    let strugglingHabits: [HabitPerformanceItem]
    let habitPerformanceSummaries: [HabitPerformanceItem]?
    let streaks: [HabitStreakItem]
    let dailyCompletionTrend: [DailyRatePoint]
    let previousPeriodCompletedRecordCount: Int?

    var isDataFree: Bool {
        activeHabitCount == 0 && completedRecordCount == 0
    }
}

nonisolated struct HabitPerformanceItem: Codable, Equatable, Sendable {
    let habitName: String
    let completionRate: Double
    let streak: Int
    let polarity: HabitPolarity
    let successRule: HabitSuccessRule
    let totalValue: Double?
    let targetValue: Double?
    let unit: String?
    let controlledDays: Int?
    let overLimitDays: Int?
    let completedDays: Int?
    let totalDays: Int?

    init(
        habitName: String,
        completionRate: Double,
        streak: Int,
        polarity: HabitPolarity = .positive,
        successRule: HabitSuccessRule = .completeWhenDone,
        totalValue: Double? = nil,
        targetValue: Double? = nil,
        unit: String? = nil,
        controlledDays: Int? = nil,
        overLimitDays: Int? = nil,
        completedDays: Int? = nil,
        totalDays: Int? = nil
    ) {
        self.habitName = habitName
        self.completionRate = completionRate
        self.streak = streak
        self.polarity = polarity
        self.successRule = successRule
        self.totalValue = totalValue
        self.targetValue = targetValue
        self.unit = unit
        self.controlledDays = controlledDays
        self.overLimitDays = overLimitDays
        self.completedDays = completedDays
        self.totalDays = totalDays
    }
}

nonisolated struct HabitStreakItem: Codable, Equatable, Sendable {
    let habitName: String
    let currentStreak: Int
    let longestStreak: Int
}

nonisolated struct DailyRatePoint: Codable, Equatable, Sendable {
    let date: String
    let rate: Double
}

// MARK: - Task

nonisolated struct TaskAnalysisContext: Codable, Equatable, Sendable {
    let totalCount: Int
    let completedCount: Int
    let overdueCount: Int
    let completionRate: Double
    let highPriorityCompletionRate: Double?
    let importantCompletedTasks: [String]
    let dailyCompletionTrend: [DailyCountPoint]
    let previousPeriodCompletedCount: Int?
    let dueInPeriod: Int
    let createdInPeriod: Int
    let completedInPeriod: Int
    let newOverdueInPeriod: Int
    let carriedOverBacklogCount: Int
    let activeBacklogCount: Int
    let periodCompletionScopeNote: String

    var isDataFree: Bool {
        dueInPeriod == 0 && completedInPeriod == 0 && createdInPeriod == 0 && activeBacklogCount == 0
    }
}

nonisolated struct DailyCountPoint: Codable, Equatable, Sendable {
    let date: String
    let count: Int
}

// MARK: - Thought

nonisolated struct ThoughtAnalysisContext: Codable, Equatable, Sendable {
    let totalCount: Int
    let moodDistribution: [MoodDistributionItem]
    let topTags: [String]
    let recentSnippets: [String]
    let dailyThoughtTrend: [DailyCountPoint]

    var isDataFree: Bool {
        totalCount == 0
    }
}

nonisolated struct MoodDistributionItem: Codable, Equatable, Sendable {
    let mood: String
    let count: Int
    let percentage: Double
}

// MARK: - CrossModule

nonisolated struct CrossModuleAnalysisContext: Codable, Equatable, Sendable {
    let highlights: [String]
    let warnings: [String]

    var isDataFree: Bool {
        highlights.isEmpty && warnings.isEmpty
    }
}

// MARK: - Health

nonisolated struct HealthMetricAnalysis: Codable, Equatable, Sendable {
    let totalValue: Double
    let dailyAverage: Double
    let goalMetDays: Int
    let totalDays: Int
    let dailyTrend: [DailyRatePoint]
    let bestDay: DailyRatePoint?

    var isDataFree: Bool {
        totalDays == 0 || (totalValue == 0 && goalMetDays == 0)
    }
}

nonisolated struct HealthAnalysisContext: Codable, Equatable, Sendable {
    let steps: HealthMetricAnalysis?
    let sleep: HealthMetricAnalysis?
    let stand: HealthMetricAnalysis?
    let activeMinutes: HealthMetricAnalysis?
    let overallBodyScore: Double?
    let previousPeriodScore: Double?
    let anomalyNotes: [String]

    var isDataFree: Bool {
        let metrics = [steps, sleep, stand, activeMinutes].compactMap { $0 }
        return metrics.isEmpty || metrics.allSatisfy(\.isDataFree)
    }
}

// MARK: - Goal

nonisolated struct GoalProgressItem: Codable, Equatable, Sendable {
    let title: String
    let domain: String
    let status: String
    let deadline: String?
    let daysRemaining: Int?
    let linkedTaskTotal: Int
    let linkedTaskCompleted: Int
    let linkedHabitTotal: Int
    let linkedHabitAverageRate: Double?
    let overallProgress: Double?
    let isOverdue: Bool
}

nonisolated struct GoalAnalysisContext: Codable, Equatable, Sendable {
    let totalActiveGoals: Int
    let goals: [GoalProgressItem]
    let completedGoalsInPeriod: Int
    let atRiskGoals: [String]
    let domainDistribution: [String: Int]
    let previousPeriodCompleted: Int?

    var isDataFree: Bool {
        totalActiveGoals == 0 && completedGoalsInPeriod == 0
    }
}
