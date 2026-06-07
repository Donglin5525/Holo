//
//  DailySenseStateBuilder.swift
//  Holo
//
//  每日状态规则引擎（v2）
//  输出结构化 DailySenseSignal，async 支持 HealthRepository
//

import Foundation
import CoreData
import os.log

struct DailySenseStateBuilder {
    private static let logger = Logger(subsystem: "com.holo.app", category: "DailySenseStateBuilder")

    /// 生成今日状态快照
    static func buildToday() async -> DailySenseSnapshot? {
        let context = CoreDataStack.shared.viewContext
        let today = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: today)

        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: todayStart) else {
            return nil
        }

        var signals: [DailySenseSignal] = []
        var riskScore: Double = 0
        var recoveryScore: Double = 0

        // 待办信号
        let overdueCount = fetchOverdueTaskCount(in: context, asOf: todayStart)
        let hasTasks = hasAnyTasks(in: context)
        if hasTasks {
            if overdueCount >= 3 {
                signals.append(DailySenseSignal(dimension: .task, level: .warning, text: "\(overdueCount) 笔过了截止日"))
                riskScore += 1.0
            } else if overdueCount > 0 {
                signals.append(DailySenseSignal(dimension: .task, level: .warning, text: "\(overdueCount) 笔快到截止日了"))
                riskScore += 0.3
            } else {
                signals.append(DailySenseSignal(dimension: .task, level: .normal, text: "没有逾期"))
            }
        }

        // 习惯信号
        let brokenHabits = fetchBrokenHabitCount(in: context, asOf: todayStart)
        let recoveredHabits = fetchRecoveredHabitCount(in: context, asOf: todayStart)
        let hasHabits = hasAnyHabits(in: context)
        if hasHabits {
            if brokenHabits >= 2 {
                signals.append(DailySenseSignal(dimension: .habit, level: .warning, text: "\(brokenHabits) 个断了节奏"))
                riskScore += 0.8
            } else if recoveredHabits > 0 {
                signals.append(DailySenseSignal(dimension: .habit, level: .normal, text: "\(recoveredHabits) 个恢复打卡"))
                recoveryScore += 1.0
            } else {
                signals.append(DailySenseSignal(dimension: .habit, level: .normal, text: "打卡都完成了"))
            }
        }

        // 消费信号
        let expenseResult = fetchExpenseDeviation(in: context, weekStart: weekAgo, todayStart: todayStart)
        if expenseResult.hasData {
            let todayAmount = expenseResult.todayAmount
            let dailyAvg = expenseResult.dailyAvg

            if todayAmount > 100 && todayAmount / dailyAvg > 3.0 {
                signals.append(DailySenseSignal(
                    dimension: .expense,
                    level: .critical,
                    text: "今天 \(formatAmount(todayAmount)) · 平时 \(formatAmount(dailyAvg))"
                ))
                riskScore += 0.6
            } else if dailyAvg > 0 && todayAmount / dailyAvg > 1.5 {
                let diff = todayAmount - dailyAvg
                signals.append(DailySenseSignal(
                    dimension: .expense,
                    level: .warning,
                    text: "比平时多花了 \(formatAmount(diff))"
                ))
                riskScore += 0.3
            } else {
                signals.append(DailySenseSignal(dimension: .expense, level: .normal, text: "消费正常"))
                if dailyAvg > 0 && todayAmount / dailyAvg <= 1.0 && todayAmount > 0 {
                    recoveryScore += 0.3
                }
            }
        }

        // 健康信号
        if InsightFeatureFlags.healthContextEnabled {
            if let healthSignal = await buildHealthSignal() {
                signals.append(healthSignal)
                if healthSignal.level == .warning {
                    riskScore += 0.3
                } else if healthSignal.level == .critical {
                    riskScore += 0.5
                }
            }
        }

        // 数据不足时不生成快照
        guard !signals.isEmpty else {
            return nil
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

        let tags = buildTags(signals: signals, hasConfirmedNewStage: false)

        return DailySenseSnapshot(
            date: today,
            state: state,
            signals: signals,
            tags: tags,
            generatedAt: Date()
        )
    }

    static func buildTags(
        signals: [DailySenseSignal],
        hasConfirmedNewStage: Bool
    ) -> [DailySenseTag] {
        var tags: [DailySenseTag] = []
        let warningDimensions = Set(
            signals
                .filter { $0.level == .warning || $0.level == .critical }
                .map(\.dimension)
        )

        if warningDimensions.count >= 3 {
            tags.append(.highPressure)
        }

        if hasConfirmedNewStage {
            tags.append(.newStage)
        }

        return tags
    }

    // MARK: - Task Signal Fetchers

    private static func fetchOverdueTaskCount(in context: NSManagedObjectContext, asOf date: Date) -> Int {
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "completed == NO AND deletedFlag == NO AND archived == NO AND dueDate < %@",
            date as CVarArg
        )
        return (try? context.count(for: request)) ?? 0
    }

    private static func hasAnyTasks(in context: NSManagedObjectContext) -> Bool {
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "deletedFlag == NO AND archived == NO")
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    // MARK: - Habit Signal Fetchers

    private static func fetchBrokenHabitCount(in context: NSManagedObjectContext, asOf date: Date) -> Int {
        let calendar = Calendar.current
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

        let todayRequest: NSFetchRequest<HabitRecord> = HabitRecord.fetchRequest()
        todayRequest.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND isCompleted == YES",
            date as CVarArg,
            tomorrow as CVarArg
        )
        let todayCompleted = (try? context.fetch(todayRequest)) ?? []
        return min(Set(todayCompleted.map(\.habitId)).count, 3)
    }

    private static func hasAnyHabits(in context: NSManagedObjectContext) -> Bool {
        let request: NSFetchRequest<HabitRecord> = HabitRecord.fetchRequest()
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    // MARK: - Expense Signal Fetchers

    private struct ExpenseResult {
        let todayAmount: Double
        let dailyAvg: Double
        let hasData: Bool
    }

    private static func fetchExpenseDeviation(
        in context: NSManagedObjectContext,
        weekStart: Date,
        todayStart: Date
    ) -> ExpenseResult {
        let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND type == %@",
            weekStart as CVarArg,
            todayStart as CVarArg,
            "expense"
        )

        guard let transactions = try? context.fetch(request) else {
            return ExpenseResult(todayAmount: 0, dailyAvg: 0, hasData: false)
        }
        let totalAmount = transactions.map { $0.amount.doubleValue }.reduce(0, +)
        let days = max(Calendar.current.dateComponents([.day], from: weekStart, to: todayStart).day ?? 1, 1)
        let dailyAvg = totalAmount / Double(days)

        let todayRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        todayRequest.predicate = NSPredicate(
            format: "date >= %@ AND type == %@",
            todayStart as CVarArg,
            "expense"
        )
        let todayAmount = ((try? context.fetch(todayRequest)) ?? []).map { $0.amount.doubleValue }.reduce(0, +)

        let hasData = dailyAvg > 0 || todayAmount > 0
        return ExpenseResult(todayAmount: todayAmount, dailyAvg: dailyAvg, hasData: hasData)
    }

    // MARK: - Health Signal

    private static func buildHealthSignal() async -> DailySenseSignal? {
        let healthRepo = HealthRepository.shared

        guard healthRepo.isAuthorized else {
            return nil
        }

        // 如果缓存值为 0，尝试刷新一次
        if healthRepo.todaySleep == 0 && healthRepo.todaySteps == 0 {
            await healthRepo.refresh()
        }

        let sleepHours = healthRepo.todaySleep
        let steps = healthRepo.todaySteps
        let sleepAvailable = healthRepo.sleepAvailability == .available
        let stepsAvailable = healthRepo.stepsAvailability == .available

        guard sleepAvailable || stepsAvailable else {
            return nil
        }

        // 优先显示异常项
        if sleepAvailable && sleepHours < 5 {
            return DailySenseSignal(dimension: .health, level: .critical, text: "只睡了 \(String(format: "%.1f", sleepHours))h")
        }
        if stepsAvailable && steps < 2000 {
            return DailySenseSignal(dimension: .health, level: .warning, text: "步数偏少")
        }
        if sleepAvailable && sleepHours > 0 && sleepHours < 6 {
            return DailySenseSignal(dimension: .health, level: .warning, text: "\(String(format: "%.1f", sleepHours))h · 有点少")
        }

        // 无异常，显示睡眠时长
        if sleepAvailable && sleepHours > 0 {
            return DailySenseSignal(dimension: .health, level: .normal, text: "\(String(format: "%.1f", sleepHours))h")
        }
        if stepsAvailable && steps > 0 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            let formatted = formatter.string(from: Int(steps) as NSNumber) ?? "\(Int(steps))"
            return DailySenseSignal(dimension: .health, level: .normal, text: "走了 \(formatted) 步")
        }

        return nil
    }

    // MARK: - Formatting

    private static func formatAmount(_ value: Double) -> String {
        "¥\(Int(value.rounded()))"
    }
}
