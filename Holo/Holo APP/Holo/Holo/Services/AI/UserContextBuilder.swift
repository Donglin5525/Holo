//
//  UserContextBuilder.swift
//  Holo
//
//  用户上下文构建器
//  从各 Repository 收集数据，构建 AI 所需的 UserContext
//

import Foundation
import os.log

@MainActor
final class UserContextBuilder {

    static let shared = UserContextBuilder()

    private let logger = Logger(subsystem: "com.holo.app", category: "UserContextBuilder")

    private init() {}

    /// 构建当前用户上下文
    func buildContext() async -> UserContext {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 EEEE"
        let todayDate = dateFormatter.string(from: Date())

        let transactions = await buildTransactionSummary()
        let habits = buildHabitSummary()
        let tasks = buildTaskSummary()
        let thoughts = buildThoughtSummary()

        return UserContext(
            todayDate: todayDate,
            transactions: transactions,
            habits: habits,
            tasks: tasks,
            thoughts: thoughts
        )
    }

    // MARK: - Transaction Summary

    private func buildTransactionSummary() async -> TransactionSummary {
        do {
            let repo = FinanceRepository.shared
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

            let todayTransactions = try await repo.getTransactions(from: today, to: tomorrow)

            var todayExpense: Decimal = 0
            var todayIncome: Decimal = 0
            var recentList: [String] = []

            for t in todayTransactions {
                if t.type == "expense" {
                    todayExpense += t.amount as Decimal
                } else {
                    todayIncome += t.amount as Decimal
                }
                recentList.append("\(t.note ?? t.category.name) ¥\(t.amount)")
            }

            return TransactionSummary(
                todayExpense: "¥\(todayExpense)",
                todayIncome: "¥\(todayIncome)",
                recentTransactions: Array(recentList.prefix(5))
            )
        } catch {
            logger.warning("构建交易摘要失败：\(error.localizedDescription)")
            return TransactionSummary(todayExpense: "未知", todayIncome: "未知", recentTransactions: [])
        }
    }

    // MARK: - Habit Summary

    private func buildHabitSummary() -> HabitSummary {
        let repo = HabitRepository.shared
        let progress = repo.getTodayCheckInProgress()

        var recentCheckIns: [String] = []
        // 通过 activeHabits 获取习惯列表
        let activeHabits = repo.activeHabits.filter { !$0.isArchived }

        return HabitSummary(
            totalActive: activeHabits.count,
            todayCompleted: progress.completed,
            todayTotal: progress.total,
            recentCheckIns: recentCheckIns
        )
    }

    // MARK: - Task Summary

    private func buildTaskSummary() -> TaskSummary {
        let repo = TodoRepository.shared
        let stats = repo.getTaskStatistics()
        let todayTasks = repo.getTodayTasks()

        var recentList: [String] = []
        for task in todayTasks.prefix(5) {
            let status = task.completed ? "✓" : "○"
            recentList.append("\(status) \(task.title)")
        }

        return TaskSummary(
            todayTotal: stats.total,
            todayCompleted: stats.completed,
            overdueCount: stats.overdue,
            recentTasks: recentList
        )
    }

    // MARK: - Thought Summary

    private func buildThoughtSummary() -> ThoughtSummary {
        do {
            let repo = ThoughtRepository()
            let thoughts = try repo.fetchAll(limit: 5)

            var recentList: [String] = []
            for thought in thoughts {
                let prefix = String(thought.content.prefix(30))
                recentList.append(prefix)
            }

            let allThoughts = try repo.fetchAll()
            return ThoughtSummary(
                recentThoughts: recentList,
                totalThoughts: allThoughts.count
            )
        } catch {
            logger.warning("构建观点摘要失败：\(error.localizedDescription)")
            return ThoughtSummary(recentThoughts: [], totalThoughts: 0)
        }
    }
}
