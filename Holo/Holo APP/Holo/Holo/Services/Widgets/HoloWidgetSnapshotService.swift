//
//  HoloWidgetSnapshotService.swift
//  Holo
//
//  生成桌面小组件使用的轻量数据快照。
//

import CoreData
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
                    self?.scheduleRefresh(.finance)
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .thoughtDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh(.thought)
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .habitDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh(.habit)
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .todoDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh(.todo)
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .goalDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh(.goal)
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .anniversaryDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh(.anniversary)
                }
            }
        )
    }

    // MARK: - 密集刷新合并（R12，2026-10-04 体检）
    //
    // 单一监听下短时间多条记录/一批同步会逐次重做全部快照查询与 reload。这里把同 kind
    // 的密集请求合并进一个短窗任务：窗口内新到的变更并入下一轮；正在跑的轮次结束后
    // 若又有脏标记则再跑一轮——最后一次变更永远会被执行，不丢更新。
    // refreshAllSnapshots（启动/手动全量刷新）不走合并，保持即时。

    private enum RefreshKind {
        case finance, thought, habit, todo, goal, anniversary
    }

    private var pendingKinds: Set<RefreshKind> = []
    private var isFlushScheduled = false
    /// 财务刷新代数：异步轮次结束时若已有更新的请求，过期轮次不得覆盖新结果
    private var financeGeneration = 0
    /// 记忆长廊热力图增量刷新节流（避免高频记账/打卡反复全扫 80 天表）
    private var lastMemoryRefreshAt: Date?
    private static let memoryThrottleInterval: TimeInterval = 10

    /// 合并窗口：密集变更在此时间内只安排一轮刷新
    private static let coalesceWindow: TimeInterval = 0.3

    private func scheduleRefresh(_ kind: RefreshKind) {
        pendingKinds.insert(kind)
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.coalesceWindow))
            guard let self else { return }
            self.isFlushScheduled = false
            self.flushPendingRefreshes()
        }
    }

    private func flushPendingRefreshes() {
        let kinds = pendingKinds
        pendingKinds.removeAll()
        if kinds.contains(.thought) {
            refreshThoughtMemorySnapshot()
            refreshMemorySnapshot()
        }
        if kinds.contains(.habit) {
            refreshHabitSnapshot()
            refreshMemorySnapshot()
        }
        if kinds.contains(.todo) {
            refreshTodoSnapshot()
            refreshMemorySnapshot()
        }
        if kinds.contains(.goal) { refreshGoalSnapshot() }
        if kinds.contains(.anniversary) { refreshAnniversarySnapshot() }
        if kinds.contains(.finance) {
            Task { @MainActor in
                await self.refreshFinanceSnapshot()
                self.refreshMemorySnapshot()
            }
        }
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
        await refreshHealthSnapshot()
        refreshInsightSnapshot()
        refreshMemorySnapshot(force: true)
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
        // R12：代数守卫——期间来了新请求时，过期轮次直接作废，由新一轮负责写入
        financeGeneration += 1
        let myGeneration = financeGeneration

        FinanceRepository.shared.setup()

        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let monthTransactions = (try? await FinanceRepository.shared.getStatisticsTransactions(for: monthStart)) ?? []
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

        guard myGeneration == financeGeneration else { return }
        try? store.writeFinance(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.finance.rawValue)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.dailyKanban.rawValue)
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
            let previousMonthTransactions = (try? await FinanceRepository.shared.getStatisticsTransactions(for: weekStartMonth)) ?? []
            transactions += previousMonthTransactions
        }

        let expenses = transactions.filter {
            $0.statisticsType == .expense && $0.date >= weekStart && $0.date < tomorrow
        }

        return (0..<7).map { offset -> HoloWidgetDailyExpense in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else {
                return HoloWidgetDailyExpense(weekdayText: "", amount: 0, isToday: false)
            }
            let sum = expenses
                .filter { $0.date >= day && $0.date < dayEnd }
                .reduce(Decimal(0)) { $0 + $1.statisticsAmount }
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
        for transaction in monthTransactions where transaction.statisticsType == .expense {
            let name = transaction.category?.name ?? "未分类"
            let colorHex = transaction.category?.color ?? "#F46D38"
            buckets[name, default: Bucket(name: name, colorHex: colorHex, sum: 0)]
                .sum += transaction.statisticsAmount
        }

        return buckets.values
            .sorted { $0.sum > $1.sum }
            .prefix(3)
            .map { HoloWidgetCategorySpend(name: $0.name, amount: $0.sum.doubleValue, colorHex: $0.colorHex) }
    }

    func refreshThoughtMemorySnapshot(date: Date = Date()) {
        guard let pool = buildThoughtWalkPool(date: date) else { return }
        try? store.writeThoughtWalkPool(pool)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.thoughtMemory.rawValue)
    }

    /// 候选池：合格想法全部入池（摘要/标签/来源逐条解析好），小组件「换一条」只在此池内轮换；
    /// featuredIndex 延续旧版按日期轮换口径，未手选时桌面显示与旧版完全一致。
    private func buildThoughtWalkPool(date: Date) -> HoloWidgetThoughtWalkSnapshot? {
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
        let items = sorted.map { makeThoughtWalkItem(for: $0) }
        return HoloWidgetThoughtWalkSnapshot(
            items: items,
            featuredIndex: (dayOfYear - 1) % items.count,
            updatedAt: date
        )
    }

    private func makeThoughtWalkItem(for selected: Thought) -> HoloWidgetThoughtMemorySnapshot {
        let tags = Array(selected.tagArray.map(\.name).prefix(2))
        // 摘要剥掉内联标签：纯文本正文剥 # 后只剩裸标签词，与底部标签行重复；
        // 标签一律由快照 tags 字段（标签行胶囊）统一展示
        let excerpt = InlineTagDetector.removingInlineTags(from: selected.plainContent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // 上限需覆盖 iOS 26 拉大后的大尺寸卡片：正文区可容纳 100+ 字
            .truncatedForWidget(maxLength: 220)

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
        HoloWidgetHabitTodoSnapshotWriter.refreshHabitSnapshot(repository: repository, store: store, date: date)
    }

    // MARK: - 今日待办

    func refreshTodoSnapshot(date: Date = Date()) {
        HoloWidgetHabitTodoSnapshotWriter.refreshTodoSnapshot(context: CoreDataStack.shared.viewContext, store: store, date: date)
    }

    // MARK: - 目标进度

    func refreshGoalSnapshot(date: Date = Date()) {
        let activeGoals = Array(GoalRepository.shared.activeGoals().prefix(4))
        guard !activeGoals.isEmpty else {
            try? store.writeGoal(.empty(date: date))
            WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.goal.rawValue)
            return
        }

        let items: [HoloWidgetGoalItem] = activeGoals.map { goal in
            if
                let metric = GoalMetricEvaluator.evaluate(goal: goal),
                let target = goal.metricTargetValueDouble
            {
                let unitSuffix = goal.metricUnitText.isEmpty ? "" : " \(goal.metricUnitText)"
                let remaining = goal.goalKindEnum == .target
                    ? abs(target - metric.currentValue)
                    : max(0, target - metric.currentValue)
                return HoloWidgetGoalItem(
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
                return HoloWidgetGoalItem(
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
        }

        try? store.writeGoal(HoloWidgetGoalSnapshot(goal: items.first, updatedAt: date, goals: items))
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.goal.rawValue)
    }

    private func goalForecastText(_ metric: GoalMetricProgress) -> String? {
        if metric.isAchieved { return "已达成" }
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
            var subtitle: String? = nil
            if anniversary.repeatYearly {
                let n = anniversary.anniversaryNumber + 1
                subtitle = String(localized: "第 \(n) 个周年")
            }
            return HoloWidgetAnniversaryItem(
                id: anniversary.id,
                title: anniversary.title,
                icon: anniversary.icon,
                monthText: "\(month)月",
                dayText: String(format: "%02d", day),
                dateText: Self.anniversaryDateText(occurrence),
                days: anniversary.daysFromToday(),
                themeColorHex: anniversary.color,
                subtitleText: subtitle,
                cycleProgress: anniversary.yearlyCycleProgress
            )
        }

        try? store.writeAnniversary(HoloWidgetAnniversarySnapshot(items: Array(items), updatedAt: date))
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.anniversary.rawValue)
    }

    // MARK: - 今日健康快照

    func refreshHealthSnapshot(date: Date = Date()) async {
        let repo = HealthRepository.shared
        guard repo.isAuthorized else {
            try? store.writeHealth(.unauthorized(date: date))
            WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.health.rawValue)
            WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.dailyKanban.rawValue)
            return
        }

        if repo.todaySteps == 0 && repo.todaySleep == 0 {
            await repo.fetchTodayData()
        }

        let steps = Int(repo.todaySteps.rounded())
        let stepsGoal = 8_000
        let sleepHours = repo.todaySleep
        let sleepGoalHours = 8.0
        let activeMinutes = Int(repo.todayActiveMinutes.rounded())

        let stepsScore = min(1.0, Double(steps) / Double(stepsGoal))
        let sleepScore = sleepHours > 0 ? min(1.0, sleepHours / sleepGoalHours) : 0.6
        let vitality = Int(((stepsScore * 0.45 + sleepScore * 0.55) * 100).rounded())

        let statusLabel: String
        if vitality >= 80 {
            statusLabel = String(localized: "状态佳")
        } else if vitality >= 60 {
            statusLabel = String(localized: "平稳")
        } else {
            statusLabel = String(localized: "需休息")
        }

        let cachedInsight = HealthInsightCache.shared.loadLatestSnapshot(now: date)
        let insightSummary = cachedInsight?.coreInsight?.summary.truncatedForWidget(maxLength: 52)
            ?? cachedInsight?.coreInsight?.title.truncatedForWidget(maxLength: 40)

        let snapshot = HoloWidgetHealthSnapshot(
            steps: steps,
            stepsGoal: stepsGoal,
            sleepHours: sleepHours,
            sleepGoalHours: sleepGoalHours,
            activeMinutes: activeMinutes,
            vitalityScore: max(0, min(100, vitality)),
            statusLabel: statusLabel,
            insightSummary: insightSummary,
            isAuthorized: true,
            updatedAt: date
        )
        try? store.writeHealth(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.health.rawValue)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.dailyKanban.rawValue)
    }

    // MARK: - 每日洞察 / 一个发现快照

    func refreshInsightSnapshot(date: Date = Date()) {
        let context = CoreDataStack.shared.viewContext
        let request = MemoryInsight.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(
                format: "status IN %@",
                [MemoryInsightStatus.ready.rawValue, MemoryInsightStatus.stale.rawValue]
            ),
            NSPredicate(format: "deletedAt == nil")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "generatedAt", ascending: false)]
        request.fetchLimit = 6

        let fetched = (try? context.fetch(request)) ?? []
        let items: [HoloWidgetInsightItem] = fetched.map { insight in
            let firstCard = insight.parsedCards.first
            let tag: String
            switch insight.insightPeriodType {
            case .daily: tag = String(localized: "每日观察")
            case .weekly: tag = String(localized: "本周观察")
            case .monthly: tag = String(localized: "月度洞察")
            default: tag = String(localized: "生活观察")
            }

            let isWarning = (firstCard?.type == .anomaly)
            let badgeText = isWarning ? String(localized: "值得留意") : String(localized: "正向信号")
            let bodyText = (firstCard?.body.isEmpty == false ? firstCard?.body : nil) ?? insight.summary
            let titleText = (firstCard?.title.isEmpty == false ? firstCard?.title : nil) ?? insight.title

            return HoloWidgetInsightItem(
                id: insight.id,
                tag: tag,
                badgeText: badgeText,
                isWarning: isWarning,
                title: titleText.truncatedForWidget(maxLength: 28),
                body: bodyText.truncatedForWidget(maxLength: 82),
                metaText: "\(insight.formattedPeriodRange) · \(String(localized: "记忆长廊"))",
                comparison: nil,
                generatedAt: insight.generatedAt
            )
        }

        try? store.writeInsightPool(HoloWidgetInsightPoolSnapshot(items: items, updatedAt: date))
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.dailyInsight.rawValue)
    }

    // MARK: - 记忆长廊快照（生活热力图 & 历史上的今天）

    func refreshMemorySnapshot(date: Date = Date(), force: Bool = false) {
        if !force, let last = lastMemoryRefreshAt, date.timeIntervalSince(last) < Self.memoryThrottleInterval {
            return
        }
        lastMemoryRefreshAt = date

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: date)
        let totalDays = 80
        guard let windowStart = calendar.date(byAdding: .day, value: -(totalDays - 1), to: todayStart),
              let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return
        }

        let context = CoreDataStack.shared.viewContext
        var heatScoreByDay: [Date: Int] = [:]
        var rawCountByDay: [Date: Int] = [:]

        // 1. 交易记录
        let txReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        txReq.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND deletedAt == nil",
            windowStart as CVarArg,
            tomorrowStart as CVarArg
        )
        if let txs = try? context.fetch(txReq) {
            for tx in txs {
                let day = calendar.startOfDay(for: tx.date)
                heatScoreByDay[day, default: 0] += 1
                rawCountByDay[day, default: 0] += 1
            }
        }

        // 2. 想法记录（热力图权重 ×2，真实条数 +1）
        let thoughtReq: NSFetchRequest<Thought> = Thought.fetchRequest()
        thoughtReq.predicate = NSPredicate(
            format: "createdAt >= %@ AND createdAt < %@ AND deletedAt == nil",
            windowStart as CVarArg,
            tomorrowStart as CVarArg
        )
        if let thoughts = try? context.fetch(thoughtReq) {
            for thought in thoughts {
                let day = calendar.startOfDay(for: thought.createdAt)
                heatScoreByDay[day, default: 0] += 2
                rawCountByDay[day, default: 0] += 1
            }
        }

        // 3. 习惯打卡记录
        let habitReq: NSFetchRequest<HabitRecord> = HabitRecord.fetchRequest()
        habitReq.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND isCompleted == YES AND deletedAt == nil",
            windowStart as CVarArg,
            tomorrowStart as CVarArg
        )
        if let records = try? context.fetch(habitReq) {
            for record in records {
                let day = calendar.startOfDay(for: record.date)
                heatScoreByDay[day, default: 0] += 1
                rawCountByDay[day, default: 0] += 1
            }
        }

        let heatmapLevels: [Int] = (0..<totalDays).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: windowStart) else { return 0 }
            let score = heatScoreByDay[day, default: 0]
            switch score {
            case 0: return 0
            case 1: return 1
            case 2...3: return 2
            case 4...6: return 3
            default: return 4
            }
        }

        // 连续活跃天数（从今天或昨天往回数）
        var streak = 0
        var cursor = todayStart
        if rawCountByDay[cursor, default: 0] == 0,
           let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) {
            cursor = yesterday
        }
        while rawCountByDay[cursor, default: 0] > 0 {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? todayStart
        let monthCount = rawCountByDay.reduce(0) { acc, pair in
            pair.key >= monthStart ? acc + pair.value : acc
        }

        let onThisDay = buildOnThisDaySnapshot(date: date, calendar: calendar)

        let snapshot = HoloWidgetMemorySnapshot(
            streakDays: streak,
            monthRecordCount: monthCount,
            heatmapLevels: heatmapLevels,
            onThisDay: onThisDay,
            updatedAt: date
        )
        try? store.writeMemory(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.memoryGallery.rawValue)
    }

    private func buildOnThisDaySnapshot(date: Date, calendar: Calendar) -> HoloWidgetOnThisDaySnapshot? {
        let repository = ThoughtRepository()
        let allThoughts = (try? repository.fetchAll(limit: 200, sortBy: .createdAtDescending)) ?? []
        let validThoughts = allThoughts.filter { $0.deletedAt == nil && !$0.isArchived && $0.plainContent.count >= 6 }
        guard !validThoughts.isEmpty else { return nil }

        let targetMonth = calendar.component(.month, from: date)
        let targetDay = calendar.component(.day, from: date)
        let currentYear = calendar.component(.year, from: date)

        // 优先匹配往年同月同日
        let sameMonthDay = validThoughts.first {
            let comps = calendar.dateComponents([.year, .month, .day], from: $0.createdAt)
            return comps.month == targetMonth && comps.day == targetDay && (comps.year ?? currentYear) < currentYear
        }
        // 回退：至少 30 天前的一条记录
        let fallbackCutoff = calendar.date(byAdding: .day, value: -30, to: date) ?? date
        let chosen = sameMonthDay ?? validThoughts.first(where: { $0.createdAt < fallbackCutoff }) ?? validThoughts.last
        guard let thought = chosen else { return nil }

        let yearsAgo = max(0, currentYear - calendar.component(.year, from: thought.createdAt))
        let labelText: String
        if sameMonthDay != nil && yearsAgo > 0 {
            labelText = String(localized: "\(yearsAgo) 年前的今天")
        } else {
            let daysAgo = max(1, calendar.dateComponents([.day], from: thought.createdAt, to: date).day ?? 1)
            labelText = String(localized: "\(daysAgo) 天前的回忆")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        let excerpt = InlineTagDetector.removingInlineTags(from: thought.plainContent)
            .truncatedForWidget(maxLength: 56)

        return HoloWidgetOnThisDaySnapshot(
            labelText: labelText,
            dateText: formatter.string(from: thought.createdAt),
            excerpt: excerpt,
            spendText: nil,
            habitText: nil,
            milestoneText: thought.tagArray.first.map { "#\($0.name)" },
            thoughtId: thought.id
        )
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

    /// 默认在桌面小组件显示想法原文；用户显式关闭过才隐藏
    static var showsThoughtExcerpt: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: thoughtExcerptKey) != nil else { return true }
        return defaults.bool(forKey: thoughtExcerptKey)
    }

    static func setShowsThoughtExcerpt(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: thoughtExcerptKey)
    }
}

private extension Array where Element == Transaction {
    /// 统计口径金额合计：退款笔按负支出冲减，与收支统计/日历同口径
    func amountSum(for type: TransactionType) -> Double {
        filter { $0.statisticsType == type }
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }
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
