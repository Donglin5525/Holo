//
//  HoloWidgetSnapshotService.swift
//  Holo
//
//  生成桌面小组件使用的轻量数据快照。
//

import Foundation
import WidgetKit

@MainActor
final class HoloWidgetSnapshotService {
    static let shared = HoloWidgetSnapshotService()

    private let store: HoloWidgetSnapshotStore
    private var observers: [NSObjectProtocol] = []

    private init(store: HoloWidgetSnapshotStore = HoloWidgetSnapshotStore()) {
        self.store = store
    }

    func startObserving() {
        guard observers.isEmpty else { return }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .financeDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshFinanceSnapshot()
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .thoughtDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshThoughtMemorySnapshot()
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .habitDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshHabitSnapshot()
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .todoDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshTodoSnapshot()
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .goalDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshGoalSnapshot()
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .anniversaryDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshAnniversarySnapshot()
            }
        )
    }

    func refreshAllSnapshots() async {
        refreshEntitlementSnapshot(
            isPlusActive: HoloEntitlementState.shared.isPlusActive,
            source: HoloEntitlementState.shared.source == .acceptance ? "acceptance" : "backend"
        )
        writeQuickActionsSnapshot()
        await refreshFinanceSnapshot()
        refreshThoughtMemorySnapshot()
        refreshHabitSnapshot()
        refreshTodoSnapshot()
        refreshGoalSnapshot()
        refreshAnniversarySnapshot()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func refreshEntitlementSnapshot(
        isPlusActive: Bool,
        source: String,
        date: Date = Date()
    ) {
        try? store.writeEntitlement(HoloWidgetEntitlementSnapshot(
            isPlusActive: isPlusActive,
            source: source,
            updatedAt: date
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    func writeQuickActionsSnapshot(date: Date = Date()) {
        try? store.writeQuickActions(.defaultSnapshot(date: date))
    }

    func refreshFinanceSnapshot(date: Date = Date()) async {
        FinanceRepository.shared.setup()

        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let monthTransactions = (try? await FinanceRepository.shared.getTransactions(for: monthStart)) ?? []
        let budgetSummary = BudgetRepository.shared.computeGlobalTotalBudgetStatus(period: .month)
        let dayRange = calendar.range(of: .day, in: .month, for: date)

        let monthExpense = budgetSummary?.totalSpentAmount.doubleValue
            ?? monthTransactions.amountSum(for: .expense)
        let monthIncome = monthTransactions.amountSum(for: .income)
        let monthBudget = budgetSummary?.totalBudgetAmount.doubleValue

        let weekExpense = await buildWeekExpense(calendar: calendar, date: date, monthStart: monthStart, monthTransactions: monthTransactions)
        let topCategories = buildTopCategories(monthTransactions: monthTransactions)

        let snapshot = HoloWidgetFinanceSnapshot(
            monthExpense: monthExpense,
            monthIncome: monthIncome,
            monthBudget: monthBudget,
            dayOfMonth: calendar.component(.day, from: date),
            daysInMonth: dayRange?.count ?? 30,
            weekExpense: weekExpense,
            topCategories: topCategories,
            updatedAt: date
        )

        try? store.writeFinance(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.finance.rawValue)
    }

    /// 大号收支组件：最近 7 天（含今天）逐日支出；跨月时补拉上一个月账目
    private func buildWeekExpense(
        calendar: Calendar,
        date: Date,
        monthStart: Date,
        monthTransactions: [Transaction]
    ) async -> [HoloWidgetDailyExpense] {
        let today = calendar.startOfDay(for: date)
        guard let weekStart = calendar.date(byAdding: .day, value: -6, to: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }

        var transactions = monthTransactions
        let weekStartMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: weekStart)) ?? weekStart
        if weekStartMonth < monthStart {
            let previousMonthTransactions = (try? await FinanceRepository.shared.getTransactions(for: weekStartMonth)) ?? []
            transactions += previousMonthTransactions
        }

        let expenses = transactions.filter {
            $0.transactionType == .expense && $0.date >= weekStart && $0.date < tomorrow
        }

        return (0..<7).map { offset -> HoloWidgetDailyExpense in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else {
                return HoloWidgetDailyExpense(weekdayText: "", amount: 0, isToday: false)
            }
            let sum = expenses
                .filter { $0.date >= day && $0.date < dayEnd }
                .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
            let isToday = offset == 6
            let weekdayName = isToday ? "今" : Self.weekdayShortNames[calendar.component(.weekday, from: day) - 1]
            return HoloWidgetDailyExpense(weekdayText: weekdayName, amount: sum.doubleValue, isToday: isToday)
        }
    }

    /// 大号收支组件：本月支出前三分类
    private func buildTopCategories(monthTransactions: [Transaction]) -> [HoloWidgetCategorySpend] {
        struct Bucket {
            var name: String
            var colorHex: String
            var sum: Decimal
        }

        var buckets: [String: Bucket] = [:]
        for transaction in monthTransactions where transaction.transactionType == .expense {
            let name = transaction.category?.name ?? "未分类"
            let colorHex = transaction.category?.color ?? "#F46D38"
            buckets[name, default: Bucket(name: name, colorHex: colorHex, sum: 0)]
                .sum += transaction.amount.decimalValue
        }

        return buckets.values
            .sorted { $0.sum > $1.sum }
            .prefix(3)
            .map { HoloWidgetCategorySpend(name: $0.name, amount: $0.sum.doubleValue, colorHex: $0.colorHex) }
    }

    func refreshThoughtMemorySnapshot(date: Date = Date()) {
        guard let snapshot = buildThoughtMemorySnapshot(date: date) else { return }
        try? store.writeThoughtMemory(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.thoughtMemory.rawValue)
    }

    private func buildThoughtMemorySnapshot(date: Date) -> HoloWidgetThoughtMemorySnapshot? {
        let repository = ThoughtRepository()
        let thoughts = (try? repository.fetchAll(limit: 120, sortBy: .createdAtDescending)) ?? []
        let candidates = thoughts
            .filter { $0.deletedAt == nil && !$0.isArchived }
            .filter { $0.plainContent.count >= 8 }

        guard !candidates.isEmpty else { return nil }

        let sorted = candidates.sorted { lhs, rhs in
            let lhsScore = thoughtWalkScore(lhs)
            let rhsScore = thoughtWalkScore(rhs)
            if lhsScore == rhsScore {
                return lhs.createdAt > rhs.createdAt
            }
            return lhsScore > rhsScore
        }

        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1
        let selected = sorted[(dayOfYear - 1) % sorted.count]
        let tags = Array(selected.tagArray.map(\.name).prefix(2))
        let excerpt = selected.plainContent.truncatedForWidget(maxLength: 72)

        return HoloWidgetThoughtMemorySnapshot(
            thoughtId: selected.id,
            createdAt: selected.createdAt,
            tags: tags,
            excerpt: excerpt,
            sourceHint: sourceHint(for: selected),
            showsOriginalExcerpt: HoloWidgetPrivacySettings.showsThoughtExcerpt
        )
    }

    private func thoughtWalkScore(_ thought: Thought) -> Int {
        let tagScore = min(thought.tagArray.count, 3) * 3
        let referencesScore = min(((thought.references?.count ?? 0) + (thought.referencedBy?.count ?? 0)), 3) * 4
        let lengthScore = thought.plainContent.count <= 180 ? 2 : 0
        return tagScore + referencesScore + lengthScore
    }

    private func sourceHint(for thought: Thought) -> String {
        let hour = Calendar.current.component(.hour, from: thought.createdAt)
        switch hour {
        case 0..<6: return "来自一次深夜记录"
        case 18..<24: return "来自一次夜间记录"
        default: return "来自一条过往想法"
        }
    }

    // MARK: - 今日习惯

    func refreshHabitSnapshot(date: Date = Date()) {
        let repository = HabitRepository.shared
        repository.setup()

        let progress = repository.getTodayCheckInProgress()
        let weekPatterns = repository.getWeekCompletionPatterns()

        var longestStreakText = ""
        var longestStreak = 0
        let items = repository.getActiveHabits().prefix(5).map { habit -> HoloWidgetHabitItem in
            let streak = repository.calculateStreakInfo(for: habit)
            if streak.value > longestStreak {
                longestStreak = streak.value
                longestStreakText = streak.displayText
            }
            // 数值型「今日有记录即算完成」与 getTodayCheckInProgress 口径一致
            let isCompleted = habit.isCheckInType
                ? repository.isTodayCompleted(for: habit)
                : repository.getTodayValue(for: habit) != nil
            return HoloWidgetHabitItem(
                id: habit.id,
                name: habit.name,
                icon: habit.icon,
                streakText: streak.value > 0 ? streak.displayText : "",
                isCompletedToday: isCompleted,
                weekPattern: weekPatterns[habit.id] ?? []
            )
        }

        let snapshot = HoloWidgetHabitSnapshot(
            completedToday: progress.completed,
            totalToday: progress.total,
            longestStreakText: longestStreakText,
            habits: Array(items),
            updatedAt: date
        )
        try? store.writeHabit(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.habit.rawValue)
    }

    // MARK: - 今日待办

    func refreshTodoSnapshot(date: Date = Date()) {
        let repository = TodoRepository.shared
        repository.setup()

        // 与任务页「今日」筛选同口径：今天到期 + 逾期未完成
        var pending = repository.getTodayTasks() + repository.getOverdueTasks()
        pending.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            let lhsDue = lhs.dueDate ?? .distantFuture
            let rhsDue = rhs.dueDate ?? .distantFuture
            if lhsDue != rhsDue { return lhsDue < rhsDue }
            return lhs.title < rhs.title
        }

        // 末尾带一条今日已完成的划线样本，桌面能看到「今天推进了什么」
        let completedToday = repository.activeTasks
            .filter { $0.completed && $0.isDueToday }
            .max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }

        var items = pending.prefix(5).map { task in
            HoloWidgetTodoItem(
                id: task.id,
                title: task.title,
                isCompleted: false,
                priority: Int(task.priority),
                isOverdue: task.isOverdue
            )
        }
        if let completedToday {
            items.append(HoloWidgetTodoItem(
                id: completedToday.id,
                title: completedToday.title,
                isCompleted: true,
                priority: Int(completedToday.priority),
                isOverdue: false
            ))
        }

        let progress = repository.getTodayTaskProgress()
        let snapshot = HoloWidgetTodoSnapshot(
            completedToday: progress.completed,
            totalToday: progress.total,
            items: items,
            dateText: Self.shortDateText(date),
            updatedAt: date
        )
        try? store.writeTodo(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.todo.rawValue)
    }

    // MARK: - 目标进度

    func refreshGoalSnapshot(date: Date = Date()) {
        guard let goal = GoalRepository.shared.activeGoals().first else {
            try? store.writeGoal(.empty(date: date))
            WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.goal.rawValue)
            return
        }

        let item: HoloWidgetGoalItem
        if
            let metric = GoalMetricEvaluator.evaluate(goal: goal),
            let target = goal.metricTargetValueDouble
        {
            let unitSuffix = goal.metricUnitText.isEmpty ? "" : " \(goal.metricUnitText)"
            let remaining = goal.goalKindEnum == .target
                ? abs(target - metric.currentValue)
                : max(0, target - metric.currentValue)
            item = HoloWidgetGoalItem(
                goalId: goal.id,
                title: goal.title,
                icon: goal.displayIcon,
                progress: metric.progress,
                percentText: "\(Int((metric.progress * 100).rounded()))%",
                currentText: GoalMetricEvaluator.formatValue(metric.currentValue) + unitSuffix,
                targetText: GoalMetricEvaluator.formatValue(target) + unitSuffix,
                remainingText: remaining > 0 ? GoalMetricEvaluator.formatValue(remaining) + unitSuffix : nil,
                forecastText: goalForecastText(metric),
                kindText: nil
            )
        } else {
            item = HoloWidgetGoalItem(
                goalId: goal.id,
                title: goal.title,
                icon: goal.displayIcon,
                progress: nil,
                percentText: nil,
                currentText: nil,
                targetText: nil,
                remainingText: nil,
                forecastText: nil,
                kindText: "过程型目标 · 拆成任务与习惯推进"
            )
        }

        try? store.writeGoal(HoloWidgetGoalSnapshot(goal: item, updatedAt: date))
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.goal.rawValue)
    }

    private func goalForecastText(_ metric: GoalMetricProgress) -> String? {
        if metric.isAchieved { return "已达成 🎉" }
        guard let forecast = metric.forecast else { return nil }
        var text = "按当前节奏 · 预计 \(Self.monthDayText(forecast.predictedDate)) 达成"
        if forecast.meetsDeadline == false {
            text += " · 晚于截止日"
        }
        return text
    }

    // MARK: - 纪念日倒数

    func refreshAnniversarySnapshot(date: Date = Date()) {
        let repository = AnniversaryRepository.shared
        repository.setup()

        let items = repository.sortedForDisplay.prefix(3).map { anniversary -> HoloWidgetAnniversaryItem in
            let occurrence = anniversary.repeatYearly ? anniversary.nextOccurrenceDate() : anniversary.date
            let month = Calendar.current.component(.month, from: occurrence)
            let day = Calendar.current.component(.day, from: occurrence)
            return HoloWidgetAnniversaryItem(
                id: anniversary.id,
                title: anniversary.title,
                icon: anniversary.icon,
                monthText: "\(month)月",
                dayText: String(format: "%02d", day),
                dateText: Self.anniversaryDateText(occurrence),
                days: anniversary.daysFromToday()
            )
        }

        try? store.writeAnniversary(HoloWidgetAnniversarySnapshot(items: Array(items), updatedAt: date))
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.anniversary.rawValue)
    }

    // MARK: - 日期文案

    private static let weekdayShortNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// "8.20 周三"
    static func shortDateText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day, .weekday], from: date)
        guard let month = components.month, let day = components.day, let weekday = components.weekday else {
            return ""
        }
        return "\(month).\(day) \(weekdayShortNames[weekday - 1])"
    }

    /// "8.20"
    static func monthDayText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else { return "" }
        return "\(month).\(day)"
    }

    /// "9.1 · 周二"
    static func anniversaryDateText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day, .weekday], from: date)
        guard let month = components.month, let day = components.day, let weekday = components.weekday else {
            return ""
        }
        return "\(month).\(day) · \(weekdayShortNames[weekday - 1])"
    }
}

enum HoloWidgetPrivacySettings {
    static let thoughtExcerptKey = "holoWidgetShowsThoughtExcerpt"

    static var showsThoughtExcerpt: Bool {
        UserDefaults.standard.bool(forKey: thoughtExcerptKey)
    }
}

private extension Array where Element == Transaction {
    func amountSum(for type: TransactionType) -> Double {
        filter { $0.transactionType == type }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
            .doubleValue
    }
}

private extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}

private extension String {
    func truncatedForWidget(maxLength: Int) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
