//
//  MemoryInsightContextBuilder.swift
//  Holo
//
//  记忆洞察上下文构建器
//  聚合周期级数据快照，供 AI 生成洞察使用
//

import Foundation
import CryptoKit
import CoreData
import os.log

/// 构建记忆洞察所需的周期级数据上下文
struct MemoryInsightContextBuilder {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryInsightContextBuilder")

    // MARK: - Token Budgets

    /// 周/月回放的输入 token 上限（粗估：1 中文字 ≈ 2 token）
    private static let weeklyTokenBudget = 2000
    private static let monthlyTokenBudget = 3500

    // MARK: - Build Context

    /// 构建指定周期的上下文
    /// - Parameters:
    ///   - periodType: 周期类型
    ///   - referenceDate: 参考日期（默认今天）
    /// - Returns: 上下文和 snapshotHash
    static func build(
        periodType: MemoryInsightPeriodType,
        referenceDate: Date = Date()
    ) async -> (context: MemoryInsightContext, snapshotHash: String) {
        let (start, end) = periodRange(periodType: periodType, referenceDate: referenceDate)

        let finance = await buildFinanceContext(start: start, end: end)
        let habits = buildHabitContext(start: start, end: end)
        let tasks = buildTaskContext(start: start, end: end)
        let thoughts = buildThoughtContext(start: start, end: end)
        let milestones = buildMilestoneContext(start: start, end: end)

        var context = MemoryInsightContext(
            periodType: periodType,
            periodStart: start,
            periodEnd: end,
            generatedAt: Date(),
            localeIdentifier: Locale.current.identifier,
            finance: finance,
            habits: habits,
            tasks: tasks,
            thoughts: thoughts,
            milestones: milestones
        )

        // Token 预算检查，超限时截断 dailyExpenses
        context = enforceTokenBudget(context, periodType: periodType)

        let snapshotHash = computeHash(context)
        return (context, snapshotHash)
    }

    // MARK: - Period Range

    /// 计算周期起止日期
    static func periodRange(periodType: MemoryInsightPeriodType, referenceDate: Date) -> (start: Date, end: Date) {
        switch periodType {
        case .weekly:
            let start = referenceDate.startOfWeek
            let end = min(start.addingDays(6), referenceDate)
            return (start.startOfDay, end.startOfDay)
        case .monthly:
            let start = referenceDate.startOfMonth
            let end = min(start.addingDays(referenceDate.daysInMonth - 1), referenceDate)
            return (start.startOfDay, end.startOfDay)
        case .daily:
            let start = referenceDate.startOfDay
            return (start, start)
        }
    }

    // MARK: - Finance

    private static func buildFinanceContext(
        start: Date,
        end: Date
    ) async -> MemoryInsightFinanceContext {
        let financeRepo = FinanceRepository.shared

        var totalExpense: Decimal = 0
        var totalIncome: Decimal = 0
        var topCategories: [CategoryAmountSummary] = []
        var dailyExpenses: [DailyAmountSummary] = []
        var previousPeriodExpense: Decimal = 0

        let endDate = end.addingDays(1)

        do {
            let transactions = try await financeRepo.getTransactions(from: start, to: endDate)
            for t in transactions {
                if t.type == "expense" {
                    totalExpense += (t.amount as NSDecimalNumber).decimalValue
                } else {
                    totalIncome += (t.amount as NSDecimalNumber).decimalValue
                }
            }

            // 日支出
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            var dailyMap: [String: Decimal] = [:]
            for t in transactions where t.type == "expense" {
                let key = dateFormatter.string(from: t.date)
                dailyMap[key, default: 0] += (t.amount as NSDecimalNumber).decimalValue
            }
            dailyExpenses = dailyMap.map { DailyAmountSummary(date: $0.key, amount: $0.value) }
                .sorted { $0.date < $1.date }

            // 分类支出（取 top 5）
            let aggregations = try await financeRepo.getCategoryAggregations(
                from: start, to: endDate, type: .expense
            )
            topCategories = aggregations.prefix(5).map {
                CategoryAmountSummary(
                    categoryName: $0.category.name,
                    amount: $0.amount
                )
            }
        } catch {
            logger.error("构建财务上下文失败：\(error.localizedDescription)")
        }

        // 上期对比
        let periodLength = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 7
        let prevStart = start.addingDays(-periodLength - 1)
        let prevEnd = start.addingDays(-1)
        do {
            let prevTransactions = try await financeRepo.getTransactions(from: prevStart, to: prevEnd)
            for t in prevTransactions where t.type == "expense" {
                previousPeriodExpense += (t.amount as NSDecimalNumber).decimalValue
            }
        } catch {
            logger.error("构建上期财务数据失败：\(error.localizedDescription)")
        }

        return MemoryInsightFinanceContext(
            totalExpense: totalExpense,
            totalIncome: totalIncome,
            topCategories: topCategories,
            dailyExpenses: dailyExpenses,
            previousPeriodExpense: previousPeriodExpense
        )
    }

    // MARK: - Habits

    private static func buildHabitContext(
        start: Date,
        end: Date
    ) -> MemoryInsightHabitContext {
        let habitRepo = HabitRepository.shared
        let range = start...end.addingDays(1)

        let habits = habitRepo.activeHabits
        var completedRecordCount = 0
        var streaks: [HabitStreakSummary] = []

        for habit in habits {
            let records = habitRepo.getRecords(for: habit, in: range)
            let completed = records.filter { $0.isCompleted }.count
            completedRecordCount += completed

            let streak = habitRepo.calculateStreak(for: habit)
            if streak >= 3 {
                streaks.append(HabitStreakSummary(
                    habitName: habit.name,
                    streakDays: streak
                ))
            }
        }

        // 上期对比
        let periodLength = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 7
        let prevStart = start.addingDays(-periodLength - 1)
        let prevEnd = start.addingDays(-1)
        var previousPeriodCompletedRecordCount = 0
        let prevRange = prevStart...prevEnd
        for habit in habits {
            let records = habitRepo.getRecords(for: habit, in: prevRange)
            previousPeriodCompletedRecordCount += records.filter { $0.isCompleted }.count
        }

        return MemoryInsightHabitContext(
            activeHabitCount: habits.count,
            completedRecordCount: completedRecordCount,
            previousPeriodCompletedRecordCount: previousPeriodCompletedRecordCount,
            streaks: streaks.sorted { $0.streakDays > $1.streakDays }
        )
    }

    // MARK: - Tasks

    private static func buildTaskContext(start: Date, end: Date) -> MemoryInsightTaskContext {
        let todoRepo = TodoRepository.shared
        let context = CoreDataStack.shared.viewContext

        var completedCount = 0
        var overdueCount = 0
        var importantCompletedTasks: [String] = []

        do {
            let request = TodoTask.fetchRequest()
            request.predicate = NSPredicate(
                format: "completed == YES AND completedAt >= %@ AND completedAt < %@ AND deletedFlag == NO AND archived == NO",
                start as CVarArg,
                end.addingDays(1) as CVarArg
            )
            let completedTasks = try context.fetch(request)
            completedCount = completedTasks.count

            importantCompletedTasks = completedTasks
                .filter { $0.priority >= 2 }
                .map { $0.title }
                .prefix(5)
                .map { String($0) }

            let overdue = todoRepo.getOverdueTasks()
            overdueCount = overdue.count
        } catch {
            logger.error("构建任务上下文失败：\(error.localizedDescription)")
        }

        return MemoryInsightTaskContext(
            completedCount: completedCount,
            overdueCount: overdueCount,
            importantCompletedTasks: importantCompletedTasks
        )
    }

    // MARK: - Thoughts

    private static func buildThoughtContext(start: Date, end: Date) -> MemoryInsightThoughtContext {
        let thoughtRepo = ThoughtRepository()
        var totalCount = 0
        var recentSnippets: [String] = []

        do {
            let filters = ThoughtFilters(startDate: start, endDate: end.addingDays(1))
            let thoughts = try thoughtRepo.search(query: "", filters: filters)
            totalCount = thoughts.count
            recentSnippets = thoughts
                .prefix(5)
                .map { String($0.content.prefix(50)) }
        } catch {
            logger.error("构建观点上下文失败：\(error.localizedDescription)")
        }

        return MemoryInsightThoughtContext(
            totalCount: totalCount,
            recentSnippets: recentSnippets
        )
    }

    // MARK: - Milestones

    private static func buildMilestoneContext(start: Date, end: Date) -> [MemoryInsightMilestoneContext] {
        let context = CoreDataStack.shared.viewContext
        let allMilestones = MilestoneDetector.detect(context: context)

        return allMilestones
            .filter { $0.date >= start && $0.date <= end.addingDays(1) }
            .map { MemoryInsightMilestoneContext(
                title: $0.data.title,
                description: $0.data.description,
                date: $0.date
            )
        }
    }

    // MARK: - Token Budget

    /// 检查 token 预算，超限时截断 dailyExpenses
    private static func enforceTokenBudget(
        _ context: MemoryInsightContext,
        periodType: MemoryInsightPeriodType
    ) -> MemoryInsightContext {
        let budget = periodType == .monthly ? monthlyTokenBudget : weeklyTokenBudget

        guard let encoded = try? JSONEncoder().encode(context),
              let json = String(data: encoded, encoding: .utf8) else {
            return context
        }

        let estimatedTokens = json.count / 2

        if estimatedTokens <= budget {
            return context
        }

        var truncatedFinance = context.finance
        if truncatedFinance.dailyExpenses.count > 14 {
            truncatedFinance = MemoryInsightFinanceContext(
                totalExpense: truncatedFinance.totalExpense,
                totalIncome: truncatedFinance.totalIncome,
                topCategories: truncatedFinance.topCategories,
                dailyExpenses: Array(truncatedFinance.dailyExpenses.suffix(14)),
                previousPeriodExpense: truncatedFinance.previousPeriodExpense
            )
        }

        return MemoryInsightContext(
            periodType: context.periodType,
            periodStart: context.periodStart,
            periodEnd: context.periodEnd,
            generatedAt: context.generatedAt,
            localeIdentifier: context.localeIdentifier,
            finance: truncatedFinance,
            habits: context.habits,
            tasks: context.tasks,
            thoughts: context.thoughts,
            milestones: context.milestones
        )
    }

    // MARK: - Snapshot Hash

    /// 计算 SHA256 hash，用于判断数据是否变化
    static func computeHash(_ context: MemoryInsightContext) -> String {
        guard let encoded = try? JSONEncoder().encode(context) else { return "" }
        let hash = SHA256.hash(data: encoded)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
