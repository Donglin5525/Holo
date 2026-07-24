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
        let habitProgress = fetchTodayHabitProgress(in: context, todayStart: todayStart)
        if let habitSignal = buildHabitSignal(
            todayCompleted: habitProgress.completed,
            totalActive: habitProgress.total,
            brokenHabits: brokenHabits,
            recoveredHabits: recoveredHabits
        ) {
            signals.append(habitSignal)
            if habitSignal.level == .warning {
                riskScore += 0.8
            } else if recoveredHabits > 0 || habitProgress.completed == habitProgress.total {
                recoveryScore += 1.0
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

    static func buildHabitSignal(
        todayCompleted: Int,
        totalActive: Int,
        brokenHabits: Int,
        recoveredHabits: Int
    ) -> DailySenseSignal? {
        guard totalActive > 0 else { return nil }

        if brokenHabits >= 2 {
            return DailySenseSignal(dimension: .habit, level: .warning, text: "\(brokenHabits) 个断了节奏")
        }

        if todayCompleted >= totalActive {
            return DailySenseSignal(dimension: .habit, level: .normal, text: "打卡都完成了")
        }

        if todayCompleted == 0 {
            return DailySenseSignal(dimension: .habit, level: .normal, text: "今天还没打卡")
        }

        if recoveredHabits > 0 {
            return DailySenseSignal(dimension: .habit, level: .normal, text: "\(todayCompleted)/\(totalActive) 已完成 · \(recoveredHabits) 个恢复打卡")
        }

        return DailySenseSignal(dimension: .habit, level: .normal, text: "\(todayCompleted)/\(totalActive) 已完成")
    }

    private static func fetchTodayHabitProgress(in context: NSManagedObjectContext, todayStart: Date) -> (completed: Int, total: Int) {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return (0, 0)
        }

        let habitRequest: NSFetchRequest<Habit> = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "isArchived == NO")

        let habits = (try? context.fetch(habitRequest)) ?? []
        guard !habits.isEmpty else { return (0, 0) }

        let completedCount = habits.filter { habit in
            isHabitCompletedToday(habit, in: context, todayStart: todayStart, tomorrow: tomorrow)
        }.count

        return (completedCount, habits.count)
    }

    private static func isHabitCompletedToday(
        _ habit: Habit,
        in context: NSManagedObjectContext,
        todayStart: Date,
        tomorrow: Date
    ) -> Bool {
        if habit.isCheckInType {
            let request: NSFetchRequest<HabitRecord> = HabitRecord.fetchRequest()
            request.predicate = NSPredicate(
                format: "habitId == %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
                habit.id as CVarArg,
                todayStart as CVarArg,
                tomorrow as CVarArg
            )
            request.fetchLimit = 1
            return ((try? context.count(for: request)) ?? 0) > 0
        }

        guard habit.isNumericType else { return false }

        let request: NSFetchRequest<HabitRecord> = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(
            format: "habitId == %@ AND date >= %@ AND date < %@ AND value != nil",
            habit.id as CVarArg,
            todayStart as CVarArg,
            tomorrow as CVarArg
        )

        let records = (try? context.fetch(request)) ?? []
        guard let todayValue = HabitNumericAggregator.aggregateDaily(
            samples: records.map { HabitNumericSample(date: $0.date, value: $0.valueDouble) },
            isCountType: habit.isCountType
        ).first?.value else {
            return false
        }

        if habit.isBadHabit {
            return false
        }

        guard let targetValue = habit.targetValueDouble else {
            return true
        }

        return todayValue >= targetValue
    }

    // MARK: - Expense Signal Fetchers

    struct ExpenseResult {
        let todayAmount: Double
        let dailyAvg: Double
        let hasData: Bool
    }

    struct DailySenseExpenseSample {
        let date: Date
        let amount: Double
    }

    static func calculateExpenseDeviation(
        samples: [DailySenseExpenseSample],
        weekStart: Date,
        todayStart: Date,
        calendar: Calendar = .current
    ) -> ExpenseResult {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return ExpenseResult(todayAmount: 0, dailyAvg: 0, hasData: false)
        }

        let previousWeekAmount = samples
            .filter { $0.date >= weekStart && $0.date < todayStart }
            .map(\.amount)
            .reduce(0, +)
        let days = max(calendar.dateComponents([.day], from: weekStart, to: todayStart).day ?? 1, 1)
        let dailyAvg = previousWeekAmount / Double(days)

        let todayAmount = samples
            .filter { $0.date >= todayStart && $0.date < tomorrow }
            .map(\.amount)
            .reduce(0, +)

        let hasData = dailyAvg > 0 || todayAmount > 0
        return ExpenseResult(todayAmount: todayAmount, dailyAvg: dailyAvg, hasData: hasData)
    }

    private static func fetchExpenseDeviation(
        in context: NSManagedObjectContext,
        weekStart: Date,
        todayStart: Date
    ) -> ExpenseResult {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: todayStart) else {
            return ExpenseResult(todayAmount: 0, dailyAvg: 0, hasData: false)
        }

        let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND type == %@",
            weekStart as CVarArg,
            tomorrow as CVarArg,
            "expense"
        )

        guard let transactions = try? context.fetch(request) else {
            return ExpenseResult(todayAmount: 0, dailyAvg: 0, hasData: false)
        }
        let samples = transactions.map {
            DailySenseExpenseSample(date: $0.date, amount: $0.amount.doubleValue)
        }
        return calculateExpenseDeviation(samples: samples, weekStart: weekStart, todayStart: todayStart)
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
