//
//  DailySenseStateBuilder.swift
//  Holo
//
//  每日状态规则引擎
//  基于任务、习惯、消费、想法信号判断 stable/atRisk/recovering
//

import Foundation
import CoreData
import os.log

struct DailySenseStateBuilder {
    private static let logger = Logger(subsystem: "com.holo.app", category: "DailySenseStateBuilder")

    /// 生成今日状态快照（纯规则引擎，不调用 AI）
    static func buildToday() -> DailySenseSnapshot? {
        let context = CoreDataStack.shared.viewContext
        let today = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: today)

        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart),
              let weekAgo = calendar.date(byAdding: .day, value: -7, to: todayStart) else {
            return nil
        }

        var reasons: [String] = []
        var riskScore: Double = 0
        var recoveryScore: Double = 0

        // 任务信号
        let overdueCount = fetchOverdueTaskCount(in: context, asOf: todayStart)
        if overdueCount >= 3 {
            reasons.append("\(overdueCount) 个任务逾期")
            riskScore += 1.0
        }
        if overdueCount > 0 && overdueCount <= 2 {
            // 轻微逾期不触发 atRisk，但不是完美 stable
            riskScore += 0.3
        }

        // 习惯信号
        let brokenHabits = fetchBrokenHabitCount(in: context, asOf: todayStart)
        if brokenHabits >= 2 {
            reasons.append("\(brokenHabits) 个习惯断连")
            riskScore += 0.8
        }

        // 恢复信号：断连习惯恢复打卡
        let recoveredHabits = fetchRecoveredHabitCount(in: context, asOf: todayStart)
        if recoveredHabits > 0 {
            reasons.append("\(recoveredHabits) 个习惯恢复打卡")
            recoveryScore += 1.0
        }

        // 消费信号
        let expenseDeviation = fetchExpenseDeviation(in: context, weekStart: weekAgo, todayStart: todayStart)
        if expenseDeviation > 1.5 {
            reasons.append("消费偏离均值 \(String(format: "%.1f", expenseDeviation))x")
            riskScore += 0.6
        }
        if expenseDeviation <= 1.0 && expenseDeviation > 0 {
            recoveryScore += 0.3
        }

        // 健康信号（如果 Feature Flag 开启）
        if InsightFeatureFlags.healthContextEnabled {
            let healthSignals = buildHealthSignals()
            for signal in healthSignals {
                if signal.severity == "warning" {
                    reasons.append(signal.title)
                    riskScore += 0.5
                }
            }
        }

        // 数据不足时返回 stable 或不展示
        guard !reasons.isEmpty || recoveryScore > 0 else {
            return DailySenseSnapshot(
                date: today,
                state: .stable,
                confidence: 0.5,
                reasons: [],
                generatedAt: Date()
            )
        }

        // 状态优先级：atRisk > recovering > stable
        let state: DailySenseState
        if riskScore >= 1.0 {
            state = .atRisk
        } else if recoveryScore >= 0.5 {
            state = .recovering
        } else {
            state = .stable
        }

        return DailySenseSnapshot(
            date: today,
            state: state,
            confidence: min(riskScore + recoveryScore, 1.0),
            reasons: Array(reasons.prefix(3)),
            generatedAt: Date()
        )
    }

    // MARK: - Signal Fetchers

    private static func fetchOverdueTaskCount(in context: NSManagedObjectContext, asOf date: Date) -> Int {
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "completed == NO AND deletedFlag == NO AND archived == NO AND dueDate < %@",
            date as CVarArg
        )
        return (try? context.count(for: request)) ?? 0
    }

    private static func fetchBrokenHabitCount(in context: NSManagedObjectContext, asOf date: Date) -> Int {
        let calendar = Calendar.current
        // 检查昨天是否有断连（正向打卡习惯昨天没记录）
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: date) else { return 0 }

        let request: NSFetchRequest<HabitRecord> = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND habit.isBadHabit == NO AND isCompleted == NO",
            yesterday as CVarArg,
            date as CVarArg
        )
        let records = (try? context.fetch(request)) ?? []
        return Set(records.map(\.habitId)).count
    }

    private static func fetchRecoveredHabitCount(in context: NSManagedObjectContext, asOf date: Date) -> Int {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { return 0 }

        // 今天已完成的习惯（简化：查今天的记录）
        let todayRequest: NSFetchRequest<HabitRecord> = HabitRecord.fetchRequest()
        todayRequest.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND isCompleted == YES",
            date as CVarArg,
            tomorrow as CVarArg
        )
        let todayCompleted = (try? context.fetch(todayRequest)) ?? []

        // 前天断连的习惯（简化：假设今天打卡 + 前天没打卡 = 恢复）
        return min(Set(todayCompleted.map(\.habitId)).count, 3) // 上限 3
    }

    private static func fetchExpenseDeviation(in context: NSManagedObjectContext, weekStart: Date, todayStart: Date) -> Double {
        // 查过去 7 天的日均消费
        let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND type == %@",
            weekStart as CVarArg,
            todayStart as CVarArg,
            "expense"
        )

        guard let transactions = try? context.fetch(request) else { return 0 }
        let totalAmount = transactions.map { $0.amount.doubleValue }.reduce(0, +)
        let days = max(Calendar.current.dateComponents([.day], from: weekStart, to: todayStart).day ?? 1, 1)
        let dailyAvg = totalAmount / Double(days)

        // 今日消费
        let todayRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        todayRequest.predicate = NSPredicate(
            format: "date >= %@ AND type == %@",
            todayStart as CVarArg,
            "expense"
        )
        let todayAmount = ((try? context.fetch(todayRequest)) ?? []).map { $0.amount.doubleValue }.reduce(0, +)

        guard dailyAvg > 0 else { return 0 }
        return todayAmount / dailyAvg
    }

    private static func buildHealthSignals() -> [HealthSignal] {
        // 健康信号获取需要 async，Daily Sense 在同步上下文生成
        // 第一版暂不集成实时健康数据，Phase 5 稳定后改为 async
        return []
    }
}
