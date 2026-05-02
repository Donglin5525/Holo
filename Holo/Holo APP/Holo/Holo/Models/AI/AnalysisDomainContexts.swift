//
//  AnalysisDomainContexts.swift
//  Holo
//
//  各分析领域的数据上下文模型
//  每个领域定义自己的结构化数据，用于卡片渲染和 LLM 注入
//

import Foundation

// MARK: - Finance

struct FinanceAnalysisContext: Codable, Equatable, Sendable {
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

    var isDataFree: Bool {
        totalExpense == 0 && totalIncome == 0 && transactionCount == 0
    }
}

struct FinanceCategoryItem: Codable, Equatable, Sendable {
    let categoryName: String
    let amount: Decimal
    let percentage: Double
}

struct FinanceMonthlyItem: Codable, Equatable, Sendable {
    let month: String
    let expense: Decimal
    let income: Decimal
}

struct FinanceBudgetItem: Codable, Equatable, Sendable {
    let budgetAmount: Decimal
    let spentAmount: Decimal
    let remainingAmount: Decimal
    let utilizationRate: Double
    let periodType: String
}

struct SubCategoryDetail: Codable, Equatable, Sendable {
    let parentCategoryName: String
    let subCategories: [FinanceCategoryItem]
}

struct CategoryTrendItem: Codable, Equatable, Sendable {
    let categoryName: String
    let currentAmount: Decimal
    let previousAmount: Decimal?
    let changePercent: Double?
}

struct SpendingPatterns: Codable, Equatable, Sendable {
    let highestSpendingDayOfWeek: DayOfWeekSpending?
    let weekdayVsWeekend: WeekdayWeekendComparison?
    let topFrequentCategories: [FrequentCategory]
}

struct DayOfWeekSpending: Codable, Equatable, Sendable {
    let dayName: String
    let averageAmount: Decimal
}

struct WeekdayWeekendComparison: Codable, Equatable, Sendable {
    let weekdayAverage: Decimal
    let weekendAverage: Decimal
}

struct FrequentCategory: Codable, Equatable, Sendable {
    let categoryName: String
    let transactionCount: Int
    let totalAmount: Decimal
}

// MARK: - Habit

struct HabitAnalysisContext: Codable, Equatable, Sendable {
    let activeHabitCount: Int
    let completedRecordCount: Int
    let averageCompletionRate: Double?
    let topPerformingHabits: [HabitPerformanceItem]
    let strugglingHabits: [HabitPerformanceItem]
    let streaks: [HabitStreakItem]
    let dailyCompletionTrend: [DailyRatePoint]
    let previousPeriodCompletedRecordCount: Int?

    var isDataFree: Bool {
        activeHabitCount == 0 && completedRecordCount == 0
    }
}

struct HabitPerformanceItem: Codable, Equatable, Sendable {
    let habitName: String
    let completionRate: Double
    let streak: Int
}

struct HabitStreakItem: Codable, Equatable, Sendable {
    let habitName: String
    let currentStreak: Int
    let longestStreak: Int
}

struct DailyRatePoint: Codable, Equatable, Sendable {
    let date: String
    let rate: Double
}

// MARK: - Task

struct TaskAnalysisContext: Codable, Equatable, Sendable {
    let totalCount: Int
    let completedCount: Int
    let overdueCount: Int
    let completionRate: Double
    let highPriorityCompletionRate: Double?
    let importantCompletedTasks: [String]
    let dailyCompletionTrend: [DailyCountPoint]
    let previousPeriodCompletedCount: Int?

    var isDataFree: Bool {
        totalCount == 0
    }
}

struct DailyCountPoint: Codable, Equatable, Sendable {
    let date: String
    let count: Int
}

// MARK: - Thought

struct ThoughtAnalysisContext: Codable, Equatable, Sendable {
    let totalCount: Int
    let moodDistribution: [MoodDistributionItem]
    let topTags: [String]
    let recentSnippets: [String]
    let dailyThoughtTrend: [DailyCountPoint]

    var isDataFree: Bool {
        totalCount == 0
    }
}

struct MoodDistributionItem: Codable, Equatable, Sendable {
    let mood: String
    let count: Int
    let percentage: Double
}

// MARK: - CrossModule

struct CrossModuleAnalysisContext: Codable, Equatable, Sendable {
    let highlights: [String]
    let warnings: [String]

    var isDataFree: Bool {
        highlights.isEmpty && warnings.isEmpty
    }
}
