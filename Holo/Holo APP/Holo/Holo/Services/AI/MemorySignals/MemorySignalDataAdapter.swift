//
//  MemorySignalDataAdapter.swift
//  Holo
//
//  从 Repository 层采集数据并转换为 Memory Observer 信号输入
//

import Foundation
import CoreData

enum MemorySignalDataAdapter {

    // MARK: - Finance → FinanceMemorySnapshotInput

    static func buildFinanceMemorySnapshotInput(
        now: Date = Date()
    ) async -> FinanceMemorySnapshotInput {
        let calendar = Calendar.current
        let currentStart = calendar.date(byAdding: .day, value: -90, to: now) ?? now
        let previousStart = calendar.date(byAdding: .day, value: -180, to: now) ?? currentStart
        let transactions = (try? await FinanceRepository.shared.getAllTransactions()) ?? []
        let mapped = transactions.compactMap { transaction -> FinanceMemoryTransactionInput? in
            guard let category = transaction.category else { return nil }
            let names = FinanceRepository.shared.resolveCategoryNames(from: category)
            let categoryName = names.sub ?? names.primary
            let merchant = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            return FinanceMemoryTransactionInput(
                id: transaction.id.uuidString,
                amount: transaction.amount.doubleValue,
                isExpense: transaction.transactionType == .expense,
                categoryID: category.id.uuidString,
                categoryName: categoryName,
                merchant: merchant?.isEmpty == false ? merchant : nil,
                occurredAt: transaction.date,
                revisionDigest: "\(transaction.updatedAt.timeIntervalSince1970)-\(transaction.amount.stringValue)-\(category.id.uuidString)"
            )
        }

        let request = Budget.fetchRequest()
        let budgets = (try? FinanceRepository.shared.context.fetch(request)) ?? []
        let budgetInputs = budgets.compactMap { budget -> FinanceMemoryBudgetInput? in
            guard let status = BudgetRepository.shared.computeBudgetStatus(budget: budget) else {
                return nil
            }
            let categoryName: String
            if let categoryID = budget.categoryId,
               let category = FinanceRepository.shared.findCategory(by: categoryID) {
                categoryName = FinanceRepository.shared.resolveCategoryNames(from: category).primary
            } else {
                categoryName = "总预算"
            }
            return FinanceMemoryBudgetInput(
                id: budget.id.uuidString,
                categoryID: budget.categoryId?.uuidString,
                categoryName: categoryName,
                budgetAmount: NSDecimalNumber(decimal: status.budgetAmount).doubleValue,
                spentAmount: NSDecimalNumber(decimal: status.spentAmount).doubleValue,
                revisionDigest: "\(budget.updatedAt.timeIntervalSince1970)-\(budget.amount.stringValue)-\(status.spentAmount)"
            )
        }

        return FinanceMemorySnapshotInput(
            currentTransactions: mapped.filter { $0.occurredAt >= currentStart && $0.occurredAt <= now },
            previousTransactions: mapped.filter { $0.occurredAt >= previousStart && $0.occurredAt < currentStart },
            budgets: budgetInputs,
            windowStart: currentStart,
            windowEnd: now
        )
    }

    // MARK: - Habit → HabitFocusSummary

    static func buildHabitFocusSummaries() -> [HabitFocusSummary] {
        let repo = HabitRepository.shared
        repo.loadActiveHabits()
        let habits = repo.activeHabits
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 当前窗口：过去 14 天
        guard let currentStart = calendar.date(byAdding: .day, value: -14, to: today) else { return [] }
        let currentRange = currentStart...today

        // 上一窗口：再往前 14 天
        guard let previousStart = calendar.date(byAdding: .day, value: -14, to: currentStart) else { return [] }
        let previousRange = previousStart...currentStart

        return habits.compactMap { habit in
            let current = repo.evaluatePerformance(for: habit, in: currentRange)
            let previous = repo.evaluatePerformance(for: habit, in: previousRange)
            let streak = repo.calculateStreakInfo(for: habit)
            let signal = HabitFocusSignal.classify(
                habitName: habit.name,
                isBadHabit: habit.isBadHabit,
                goalTitle: habit.goal?.title,
                profileContext: nil
            )

            return HabitFocusSummary(
                habitName: habit.name,
                signal: signal,
                current: current,
                previous: previous,
                currentStreak: streak.value,
                goalTitle: habit.goal?.title
            )
        }
    }

    static func buildHabitDomainMemoryInputs(now: Date = Date()) -> [HabitDomainMemoryInput] {
        let repo = HabitRepository.shared
        repo.loadActiveHabits()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let currentStart = calendar.date(byAdding: .day, value: -14, to: today),
              let previousStart = calendar.date(byAdding: .day, value: -14, to: currentStart) else {
            return []
        }
        return repo.activeHabits.map { habit in
            let current = repo.evaluatePerformance(for: habit, in: currentStart...today)
            let previous = repo.evaluatePerformance(for: habit, in: previousStart...currentStart)
            return HabitDomainMemoryInput(
                id: habit.id.uuidString,
                name: habit.name,
                isBadHabit: habit.isBadHabit,
                totalDays: current.totalDays,
                completedDays: current.completedDays,
                previousCompletionRate: previous.completionRate,
                currentStreak: repo.calculateStreakInfo(for: habit).value,
                revisionDigest: "\(habit.updatedAt.timeIntervalSince1970)-\(current.completedDays)-\(current.totalDays)",
                observedAt: now
            )
        }
    }

    // MARK: - Goal → GoalProgressInput

    static func buildGoalProgressInputs() -> [GoalProgressInput] {
        let goals = GoalRepository.shared.activeGoalsForAI(limit: 10)

        return goals.compactMap { goal in
            let tasks = goal.sortedTasks
            let completed = tasks.filter { $0.completed }.count

            return GoalProgressInput(
                id: goal.id.uuidString,
                title: goal.title,
                deadline: goal.deadline,
                createdAt: goal.createdAt,
                completedAt: goal.completedAt,
                status: goal.status,
                taskTotal: tasks.count,
                taskCompleted: completed
            )
        }
    }

    static func buildGoalDomainMemoryInputs(now: Date = Date()) -> [GoalDomainMemoryInput] {
        GoalRepository.shared.activeGoalsForAI(limit: 20).map { goal in
            let tasks = goal.sortedTasks
            let completed = tasks.filter(\.completed).count
            let progress = tasks.isEmpty
                ? (goal.completedAt != nil ? 1 : 0)
                : Double(completed) / Double(tasks.count)
            let expectedProgress: Double
            if let deadline = goal.deadline {
                let total = Calendar.current.dateComponents(
                    [.day], from: goal.createdAt, to: deadline
                ).day ?? 1
                let elapsed = Calendar.current.dateComponents(
                    [.day], from: goal.createdAt, to: now
                ).day ?? 0
                expectedProgress = total > 0
                    ? min(max(Double(elapsed) / Double(total), 0), 1)
                    : 1
            } else {
                let elapsed = Calendar.current.dateComponents(
                    [.day], from: goal.createdAt, to: now
                ).day ?? 0
                expectedProgress = min(max(Double(elapsed) / 30, 0), 1)
            }
            return GoalDomainMemoryInput(
                id: goal.id.uuidString,
                title: goal.title,
                // 只有已进入用户目标库的实体才进入记忆；未确认的系统建议不在此查询结果中。
                isUserCreated: goal.source != "suggestion",
                isCompleted: goal.completedAt != nil || goal.status == "completed",
                progress: progress,
                expectedProgress: expectedProgress,
                taskTotal: tasks.count,
                taskCompleted: completed,
                deadline: goal.deadline,
                previousDeadline: nil,
                revisionDigest: "\(goal.updatedAt.timeIntervalSince1970)-\(completed)-\(tasks.count)",
                observedAt: now
            )
        }
    }
}
