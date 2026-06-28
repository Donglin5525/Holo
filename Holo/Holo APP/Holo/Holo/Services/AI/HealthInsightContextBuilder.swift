//
//  HealthInsightContextBuilder.swift
//  Holo
//
//  健康洞察 LLM 生成 — 上下文构建器。
//  复用 HealthRepository / FinanceRepository / HabitRepository / TodoRepository / ThoughtRepository 的同源数据，
//  把 HealthKit（睡眠/步数/站立/活动/锻炼会话）与跨模块信号整理成模型可用的脱敏证据包。
//
//  关键约束：
//  - evidence.id 统一规范 `<domain>-<subKind>-<yyyyMMdd>`，由本 Builder 一处生成。
//  - 所有指标通过注入的 dataSource 拉取，显式 14d 窗口（start=今日0点-13天，end=明日0点）。
//  - 跨域候选使用按日集合交叉 + lift（不只使用聚合总数）。
//  - 多域候选最多 top-4（按 confidenceHint），避免 prompt 过载；evidence 裁剪：核心日 + 候选命中日。
//  - 动态阈值（按用户个人基线），适应不同记录密度。
//  - contextHashInput 只取稳定摘要，不含逐笔 evidence / 当日实时值。
//

import Foundation

// MARK: - 跨域脱敏值类型（避免测试/并发依赖 NSManagedObject）

struct HealthInsightFinanceRecord: Codable, Equatable, Sendable {
    var date: Date
    var searchableText: String
    var amount: Double
}

/// 每日习惯完成率（达标习惯数 / 活跃习惯数，0...1）。
struct HealthInsightHabitRecord: Codable, Equatable, Sendable {
    var date: Date
    var completionRate: Double
}

/// 每日待办完成数。
struct HealthInsightTaskRecord: Codable, Equatable, Sendable {
    var date: Date
    var completedCount: Int
}

/// 每日观点条数。
struct HealthInsightThoughtRecord: Codable, Equatable, Sendable {
    var date: Date
    var count: Int
}

// MARK: - DataSource 协议（生产 + 测试可注入）

protocol HealthInsightDataSource: Sendable {
    func dailySleep(from start: Date, to end: Date) async -> [DailyHealthData]
    func dailySteps(from start: Date, to end: Date) async -> [DailyHealthData]
    func dailyStand(from start: Date, to end: Date) async -> [DailyHealthData]
    func dailyActive(from start: Date, to end: Date) async -> [DailyHealthData]
    /// 每日锻炼会话聚合（HKWorkout）。
    func dailyWorkouts(from start: Date, to end: Date) async -> [DailyWorkoutData]
    /// 脱敏后的支出记录（仅 expense，已合并 note/remark/category/tags 为 searchableText）。
    func financeRecords(from start: Date, to end: Date) async -> [HealthInsightFinanceRecord]
    /// 每日习惯完成率。
    func habitDailyCompletion(from start: Date, to end: Date) async -> [HealthInsightHabitRecord]
    /// 每日待办完成数。
    func taskDailyCompletion(from start: Date, to end: Date) async -> [HealthInsightTaskRecord]
    /// 每日观点条数。
    func thoughtDailyCount(from start: Date, to end: Date) async -> [HealthInsightThoughtRecord]
}

/// 生产实现：包裹各模块 Repository。
/// Core Data 访问统一在 @MainActor 闭包内完成，只把 Sendable 值类型带出并发上下文，
/// 避免非主线程访问主线程 viewContext 的 NSManagedObject（曾导致健康页闪退）。
struct HoloHealthInsightDataSource: HealthInsightDataSource {

    func dailySleep(from start: Date, to end: Date) async -> [DailyHealthData] {
        await HealthRepository.shared.fetchSleepRange(from: start, to: end)
    }

    func dailySteps(from start: Date, to end: Date) async -> [DailyHealthData] {
        await HealthRepository.shared.fetchStepsRange(from: start, to: end)
    }

    func dailyStand(from start: Date, to end: Date) async -> [DailyHealthData] {
        await HealthRepository.shared.fetchStandTimeRange(from: start, to: end)
    }

    func dailyActive(from start: Date, to end: Date) async -> [DailyHealthData] {
        await HealthRepository.shared.fetchActiveMinutesRange(from: start, to: end)
    }

    func dailyWorkouts(from start: Date, to end: Date) async -> [DailyWorkoutData] {
        await HealthRepository.shared.fetchWorkoutsRange(from: start, to: end)
    }

    func financeRecords(from start: Date, to end: Date) async -> [HealthInsightFinanceRecord] {
        await Self.extractExpenseRecords(from: start, to: end)
    }

    func habitDailyCompletion(from start: Date, to end: Date) async -> [HealthInsightHabitRecord] {
        await Self.extractHabitCompletion(from: start, to: end)
    }

    func taskDailyCompletion(from start: Date, to end: Date) async -> [HealthInsightTaskRecord] {
        await Self.extractTaskCompletion(from: start, to: end)
    }

    func thoughtDailyCount(from start: Date, to end: Date) async -> [HealthInsightThoughtRecord] {
        await Self.extractThoughtCount(from: start, to: end)
    }

    // MARK: - @MainActor 脱敏提取（Repository 均 @MainActor，NSManagedObject 必须在主线程消费）

    @MainActor
    private static func extractExpenseRecords(from start: Date, to end: Date) async -> [HealthInsightFinanceRecord] {
        guard let txs = try? await FinanceRepository.shared.getTransactions(from: start, to: end) else {
            return []
        }
        return txs.filter { $0.transactionType == .expense }.map { tx in
            HealthInsightFinanceRecord(
                date: tx.date,
                searchableText: [
                    tx.note,
                    tx.remark,
                    tx.category?.name,
                    tx.tags?.joined(separator: " ")
                ].compactMap { $0 }.joined(separator: " "),
                amount: tx.amount.doubleValue
            )
        }
    }

    /// 每日习惯完成率 = 当日有记录的活跃习惯数 / 活跃习惯总数。
    /// 习惯达标口径遵循开发规范：看「有记录」而非 target 达标（打卡/数值型统一）。
    @MainActor
    private static func extractHabitCompletion(from start: Date, to end: Date) async -> [HealthInsightHabitRecord] {
        let repo = HabitRepository.shared
        let habits = repo.activeHabits
        guard !habits.isEmpty else { return [] }
        let total = Double(habits.count)
        let calendar = Calendar.current
        let range = start...end

        var dayHitCount: [Date: Int] = [:]
        for habit in habits {
            let records = repo.getRecords(for: habit, in: range)
            var daySet = Set<Date>()
            for record in records {
                daySet.insert(calendar.startOfDay(for: record.date))
            }
            for day in daySet {
                dayHitCount[day, default: 0] += 1
            }
        }
        return dayHitCount.map { (day, hit) in
            HealthInsightHabitRecord(date: day, completionRate: Double(hit) / total)
        }
    }

    @MainActor
    private static func extractTaskCompletion(from start: Date, to end: Date) async -> [HealthInsightTaskRecord] {
        let trend = TodoRepository.shared.getCompletionTrend(from: start, to: end)
        return trend.map { HealthInsightTaskRecord(date: $0.date, completedCount: $0.completedCount) }
    }

    @MainActor
    private static func extractThoughtCount(from start: Date, to end: Date) async -> [HealthInsightThoughtRecord] {
        // ThoughtRepository 非单例，方法内实例化（默认绑 viewContext，已在 @MainActor，安全）。
        let counts = ThoughtRepository().getThoughtCountByDay(from: start, to: end)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return counts.compactMap { (key, count) -> HealthInsightThoughtRecord? in
            guard let date = formatter.date(from: key) else { return nil }
            return HealthInsightThoughtRecord(date: date, count: count)
        }
    }
}

// MARK: - 上下文 JSON 结构（camelCase + convertToSnakeCase 序列化）

struct HealthInsightGenerationContext: Codable {
    var schemaVersion: Int
    var locale: String
    var period: Period
    var healthSummary: HealthSummary
    var candidateCorrelations: [CandidateCorrelation]
    var evidence: [ContextEvidence]
    var preferenceHints: PreferenceHints

    struct Period: Codable {
        var start: String
        var end: String
        var days: Int
    }

    struct HealthSummary: Codable {
        var sleepAverageHours: Double
        var lowSleepDays: Int
        var stepsAverage: Double
        var stepsGoalMetDays: Int
        var standOrActiveSummary: String
        var workoutSummary: String
    }

    struct CandidateCorrelation: Codable {
        var id: String
        var description: String
        var confidenceHint: Double
        var evidenceIds: [String]
    }

    struct ContextEvidence: Codable {
        var id: String
        var domain: String
        var title: String
        var detail: String
    }

    struct PreferenceHints: Codable {
        var avoidPatterns: [String]
        var preferTone: String
    }
}

// MARK: - 构建结果

/// ContextBuilder 一次构建产出：发给 LLM 的 user message + 同源证据表 + 合法 id 集合 + 缓存哈希输入。
struct HealthInsightContextBuildResult: Sendable {
    /// 序列化后的 context JSON 字符串（作为 LLM user message）。
    var contextJSON: String
    /// 同源 evidence 表（供 UI 证据详情展示 + Verifier 校验）。
    var evidence: [HealthInsightEvidence]
    /// 合法 evidence id 集合（Verifier 用，LLM 回填的 evidenceIds 必须命中此处）。
    var legalEvidenceIds: Set<String>
    var period: HealthInsightPeriod
    /// 稳定摘要（Cache 据此计算 hash）。
    var contextHashInput: String
    /// 数据是否充足（不足时 Service 应走 insufficientData，不调用 LLM）。
    var isDataSufficient: Bool
}

// MARK: - Builder

struct HealthInsightContextBuilder {

    private let dataSource: HealthInsightDataSource
    private let now: Date
    private let calendar: Calendar

    /// 低睡眠阈值（小时）。
    private let lowSleepThreshold: Double = 6.0
    /// 步数达标阈值。
    private let stepsGoal: Double = 10_000
    /// 跨域候选关键词。
    private let coffeeKeyword: String = "咖啡"
    /// 运动充足阈值（分钟）。
    private let workoutSufficientMinutes: Double = 30.0
    /// 候选纳入门槛（base 集合最小规模）。
    private let minBaseDays: Int = 2
    /// 候选 lift 下限。
    private let minLiftRatio: Double = 1.5
    /// 候选最多保留数（top-N，按 confidenceHint）。
    private let maxCandidates: Int = 4
    /// 低睡眠 evidence 允许的最大条数（近 N 天优先）。
    private let maxSleepEvidence: Int = 10

    init(
        dataSource: HealthInsightDataSource,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.dataSource = dataSource
        self.now = now
        self.calendar = calendar
    }

    // MARK: - Public

    /// @MainActor：所有 Repository 绑主线程 viewContext，build 必须在主线程串行拉取，
    /// 避免 async let 并发导致 Core Data 跨线程 trap（健康页闪退根因，记忆 12724）。
    @MainActor
    func build() async -> HealthInsightContextBuildResult {
        let window = makeFourteenDayWindow()

        // 串行拉取（去 async let 并发）：9 路并发会在主线程制造 fetch 风暴 + 跨线程 trap，串行确保安全。
        let sleepData = await dataSource.dailySleep(from: window.start, to: window.end)
        let stepsData = await dataSource.dailySteps(from: window.start, to: window.end)
        let standData = await dataSource.dailyStand(from: window.start, to: window.end)
        let activeData = await dataSource.dailyActive(from: window.start, to: window.end)
        let workoutData = await dataSource.dailyWorkouts(from: window.start, to: window.end)
        let financeData = await dataSource.financeRecords(from: window.start, to: window.end)
        let habitData = await dataSource.habitDailyCompletion(from: window.start, to: window.end)
        let taskData = await dataSource.taskDailyCompletion(from: window.start, to: window.end)
        let thoughtData = await dataSource.thoughtDailyCount(from: window.start, to: window.end)

        // 睡眠是核心指标，无睡眠数据视为数据不足。
        let isDataSufficient = sleepData.contains { $0.value > 0 }

        // 按日索引
        let sleepByDay = byDay(sleepData, dateFor: { $0.date })
        let financeByDay = byDayFinance(financeData)
        let habitByDay = byDay(habitData, dateFor: { $0.date })
        let taskByDay = byDay(taskData, dateFor: { $0.date })
        let thoughtByDay = byDay(thoughtData, dateFor: { $0.date })
        let workoutByDay = byDay(workoutData, dateFor: { $0.date })

        // 集合（低睡眠为 base，其余为 target；阈值动态化按个人基线）
        let lowSleepDays = daySet(from: sleepData) { $0.value > 0 && $0.value < lowSleepThreshold }
        let workoutSufficientDays = daySet(from: workoutData) { $0.totalMinutes >= workoutSufficientMinutes }
        let coffeeDays = coffeeDaySet(from: financeData)
        let lowTaskDays = lowTaskDaySet(from: taskData)
        let lowHabitDays = lowHabitDaySet(from: habitData)
        let highThoughtDays = highThoughtDaySet(from: thoughtData)

        // 多域候选（base=低睡眠 ∩ target={咖啡,低待办,低习惯,高观点}），top-4
        let specs: [CandidateSpec] = [
            .init(id: "candidate-sleep-coffee", description: "低睡眠日咖啡支出频率更高",
                  baseDays: lowSleepDays, targetDays: coffeeDays,
                  baseKind: "health-sleep", targetKind: "finance-keyword-coffee"),
            .init(id: "candidate-sleep-task", description: "低睡眠日待办完成更少",
                  baseDays: lowSleepDays, targetDays: lowTaskDays,
                  baseKind: "health-sleep", targetKind: "task-completion"),
            .init(id: "candidate-sleep-habit", description: "低睡眠日习惯完成率更低",
                  baseDays: lowSleepDays, targetDays: lowHabitDays,
                  baseKind: "health-sleep", targetKind: "habit-completion"),
            .init(id: "candidate-sleep-thought", description: "低睡眠日观点记录更多",
                  baseDays: lowSleepDays, targetDays: highThoughtDays,
                  baseKind: "health-sleep", targetKind: "thought-count")
        ]
        let candidates = topCandidates(from: specs, windowDays: window.days)

        // 候选命中的日子（多域 evidence 仅生成这些日，控制 prompt 长度）
        let candidateTargetDays = Set(candidates.flatMap { $0.matchedDays })

        // evidence 组装（裁剪：sleep 近 maxSleepEvidence 条；其余只放候选命中日 + workout 代表日）
        var evidence: [HealthInsightEvidence] = []
        evidence.append(contentsOf: sleepEvidence(for: lowSleepDays, sleepByDay: sleepByDay))
        evidence.append(contentsOf: taskEvidence(for: candidateTargetDays, taskByDay: taskByDay))
        evidence.append(contentsOf: habitEvidence(for: candidateTargetDays, habitByDay: habitByDay))
        evidence.append(contentsOf: thoughtEvidence(for: candidateTargetDays, thoughtByDay: thoughtByDay))
        evidence.append(contentsOf: financeEvidence(for: candidates, financeByDay: financeByDay))
        evidence.append(contentsOf: workoutEvidence(for: workoutSufficientDays, workoutByDay: workoutByDay))

        let healthSummary = makeHealthSummary(
            sleepData: sleepData,
            lowSleepCount: lowSleepDays.count,
            stepsData: stepsData,
            standData: standData,
            activeData: activeData,
            workoutData: workoutData
        )

        let candidateCorrelations = candidates.map {
            HealthInsightGenerationContext.CandidateCorrelation(
                id: $0.id,
                description: $0.description,
                confidenceHint: $0.confidenceHint,
                evidenceIds: $0.evidenceIds
            )
        }

        let contextEvidence = evidence.map {
            HealthInsightGenerationContext.ContextEvidence(
                id: $0.id,
                domain: $0.domain.rawValue,
                title: $0.title,
                detail: $0.detail
            )
        }

        let context = HealthInsightGenerationContext(
            schemaVersion: 1,
            locale: "zh_CN",
            period: HealthInsightGenerationContext.Period(
                start: Self.dateString(from: window.start),
                end: Self.dateString(from: window.end),
                days: window.days
            ),
            healthSummary: healthSummary,
            candidateCorrelations: candidateCorrelations,
            evidence: contextEvidence,
            preferenceHints: defaultPreferenceHints()
        )

        let contextJSON = Self.encode(context)
        let contextHashInput = makeContextHashInput(
            window: window,
            healthSummary: healthSummary,
            candidates: candidateCorrelations
        )

        return HealthInsightContextBuildResult(
            contextJSON: contextJSON,
            evidence: evidence,
            legalEvidenceIds: Set(evidence.map(\.id)),
            period: HealthInsightPeriod(start: window.start, end: window.end, days: window.days),
            contextHashInput: contextHashInput,
            isDataSufficient: isDataSufficient
        )
    }

    // MARK: - 时间窗口（显式 14d）

    private struct TimeWindow {
        var start: Date
        var end: Date
        var days: Int
    }

    private func makeFourteenDayWindow() -> TimeWindow {
        let todayStart = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -13, to: todayStart) ?? todayStart
        let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        return TimeWindow(start: start, end: end, days: 14)
    }

    // MARK: - 按日索引

    /// 通用按日索引（同日多条取最后一条； finance 单独聚合金额）。
    private func byDay<T>(_ items: [T], dateFor: (T) -> Date) -> [String: T] {
        var grouped: [String: T] = [:]
        for item in items {
            grouped[Self.dayKey(from: dateFor(item))] = item
        }
        return grouped
    }

    /// 财务按日聚合：同一天可能有多笔支出，金额累加（避免重复 key 行为未定义）。
    private func byDayFinance(_ records: [HealthInsightFinanceRecord]) -> [String: HealthInsightFinanceRecord] {
        var grouped: [String: HealthInsightFinanceRecord] = [:]
        for record in records {
            let key = Self.dayKey(from: record.date)
            if let existing = grouped[key] {
                grouped[key] = HealthInsightFinanceRecord(
                    date: existing.date,
                    searchableText: existing.searchableText,
                    amount: existing.amount + record.amount
                )
            } else {
                grouped[key] = record
            }
        }
        return grouped
    }

    // MARK: - 集合（按日 dayKey）

    private func daySet<T>(from data: [T], where predicate: (T) -> Bool) -> Set<String> where T: DayDatable {
        Set(data.filter(predicate).map { Self.dayKey(from: $0.dayDate) })
    }

    private func coffeeDaySet(from records: [HealthInsightFinanceRecord]) -> Set<String> {
        Set(records
            .filter { $0.searchableText.localizedCaseInsensitiveContains(coffeeKeyword) }
            .map { Self.dayKey(from: $0.date) })
    }

    /// 低待办完成日：完成数 ≤ 个人日均的 60%（至少阈值 1）。
    private func lowTaskDaySet(from data: [HealthInsightTaskRecord]) -> Set<String> {
        let avg = average(of: data.map { Double($0.completedCount) }.filter { $0 > 0 })
        let threshold = max(1.0, avg * 0.6)
        return Set(data.filter { Double($0.completedCount) <= threshold }.map { Self.dayKey(from: $0.date) })
    }

    /// 低习惯完成日：完成率 ≤ 个人日均的 70%（至少阈值 0.2）。
    private func lowHabitDaySet(from data: [HealthInsightHabitRecord]) -> Set<String> {
        let avg = average(of: data.map { $0.completionRate }.filter { $0 > 0 })
        let threshold = max(0.2, avg * 0.7)
        return Set(data.filter { $0.completionRate <= threshold }.map { Self.dayKey(from: $0.date) })
    }

    /// 高观点日：条数 ≥ 个人日均的 130%（至少阈值 2）。
    private func highThoughtDaySet(from data: [HealthInsightThoughtRecord]) -> Set<String> {
        let avg = average(of: data.map { Double($0.count) }.filter { $0 > 0 })
        let threshold = max(2.0, avg * 1.3)
        return Set(data.filter { Double($0.count) >= threshold }.map { Self.dayKey(from: $0.date) })
    }

    // MARK: - evidence 生成（各域，id 遵循 <domain>-<subKind>-<yyyyMMdd>）

    private func sleepEvidence(for lowDays: Set<String>, sleepByDay: [String: DailyHealthData]) -> [HealthInsightEvidence] {
        // 近 maxSleepEvidence 条优先（按日期倒序），控制 prompt 长度
        let sortedDays = lowDays.sorted().reversed()
        var result: [HealthInsightEvidence] = []
        for dayKey in sortedDays.prefix(maxSleepEvidence) {
            guard let record = sleepByDay[dayKey] else { continue }
            result.append(HealthInsightEvidence(
                id: "health-sleep-\(dayKey)",
                domain: .health,
                occurredAt: record.date,
                title: "\(Self.displayDate(from: record.date)) 睡眠 \(String(format: "%.1f", record.value)) 小时",
                detail: "低于 \(Int(lowSleepThreshold)) 小时阈值",
                metricKey: "health.sleep.hours",
                metricValue: record.value,
                unit: "小时"
            ))
        }
        return result
    }

    private func taskEvidence(for days: Set<String>, taskByDay: [String: HealthInsightTaskRecord]) -> [HealthInsightEvidence] {
        days.sorted().compactMap { dayKey in
            guard let record = taskByDay[dayKey] else { return nil }
            return HealthInsightEvidence(
                id: "task-completion-\(dayKey)",
                domain: .task,
                occurredAt: record.date,
                title: "\(Self.displayDate(from: record.date)) 完成 \(record.completedCount) 项待办",
                detail: "当日待办完成数",
                metricKey: "task.completed.count",
                metricValue: Double(record.completedCount),
                unit: "项"
            )
        }
    }

    private func habitEvidence(for days: Set<String>, habitByDay: [String: HealthInsightHabitRecord]) -> [HealthInsightEvidence] {
        days.sorted().compactMap { dayKey in
            guard let record = habitByDay[dayKey] else { return nil }
            return HealthInsightEvidence(
                id: "habit-completion-\(dayKey)",
                domain: .habit,
                occurredAt: record.date,
                title: "\(Self.displayDate(from: record.date)) 习惯完成 \(Int(record.completionRate * 100))%",
                detail: "当日达标习惯占比",
                metricKey: "habit.completion.rate",
                metricValue: record.completionRate,
                unit: "比例"
            )
        }
    }

    private func thoughtEvidence(for days: Set<String>, thoughtByDay: [String: HealthInsightThoughtRecord]) -> [HealthInsightEvidence] {
        days.sorted().compactMap { dayKey in
            guard let record = thoughtByDay[dayKey] else { return nil }
            return HealthInsightEvidence(
                id: "thought-count-\(dayKey)",
                domain: .thought,
                occurredAt: record.date,
                title: "\(Self.displayDate(from: record.date)) 记录 \(record.count) 条想法",
                detail: "当日观点条数",
                metricKey: "thought.count",
                metricValue: Double(record.count),
                unit: "条"
            )
        }
    }

    private func financeEvidence(
        for candidates: [CrossDomainCandidate],
        financeByDay: [String: HealthInsightFinanceRecord]
    ) -> [HealthInsightEvidence] {
        // 仅候选命中的咖啡日
        let coffeeDays = Set(candidates.flatMap { $0.matchedDays })
        return coffeeDays.sorted().compactMap { dayKey in
            guard let record = financeByDay[dayKey] else { return nil }
            return HealthInsightEvidence(
                id: "finance-keyword-coffee-\(dayKey)",
                domain: .finance,
                occurredAt: record.date,
                title: "\(Self.displayDate(from: record.date)) 咖啡支出",
                detail: "命中关键词：\(coffeeKeyword)",
                metricKey: "finance.keyword.amount",
                metricValue: record.amount,
                unit: "元"
            )
        }
    }

    private func workoutEvidence(for days: Set<String>, workoutByDay: [String: DailyWorkoutData]) -> [HealthInsightEvidence] {
        // 近 7 天运动充足日代表（最多 3 条）
        let sortedDays = days.sorted().reversed().prefix(3)
        return sortedDays.compactMap { dayKey in
            guard let record = workoutByDay[dayKey] else { return nil }
            let typeText = record.topType.map { "（\($0)）" } ?? ""
            return HealthInsightEvidence(
                id: "health-workout-\(dayKey)",
                domain: .health,
                occurredAt: record.date,
                title: "\(Self.displayDate(from: record.date)) 运动 \(Int(record.totalMinutes)) 分钟\(typeText)",
                detail: "锻炼会话 \(record.sessionCount) 次",
                metricKey: "health.workout.minutes",
                metricValue: record.totalMinutes,
                unit: "分钟"
            )
        }
    }

    // MARK: - 跨域候选（按日集合交叉 + lift，top-N）

    private struct CandidateSpec {
        let id: String
        let description: String
        let baseDays: Set<String>
        let targetDays: Set<String>
        let baseKind: String
        let targetKind: String
    }

    private struct CrossDomainCandidate {
        var id: String
        var description: String
        var confidenceHint: Double
        var evidenceIds: [String]
        var matchedDays: Set<String>
    }

    private func topCandidates(from specs: [CandidateSpec], windowDays: Int) -> [CrossDomainCandidate] {
        let built = specs.compactMap { spec -> CrossDomainCandidate? in
            guard spec.baseDays.count >= minBaseDays, !spec.targetDays.isEmpty else { return nil }
            let intersection = spec.baseDays.intersection(spec.targetDays)
            guard !intersection.isEmpty else { return nil }
            let hitRate = Double(intersection.count) / Double(spec.baseDays.count)
            let baseRate = Double(spec.targetDays.count) / Double(windowDays)
            guard baseRate > 0 else { return nil }
            let lift = hitRate / baseRate
            guard lift >= minLiftRatio else { return nil }

            var evidenceIds: [String] = []
            for day in intersection.sorted() {
                evidenceIds.append("\(spec.baseKind)-\(day)")
                evidenceIds.append("\(spec.targetKind)-\(day)")
            }
            let confidenceHint = min(0.75, 0.55 + (lift - minLiftRatio) * 0.1)
            return CrossDomainCandidate(
                id: spec.id,
                description: spec.description,
                confidenceHint: confidenceHint,
                evidenceIds: evidenceIds,
                matchedDays: intersection
            )
        }
        return Array(built.sorted { $0.confidenceHint > $1.confidenceHint }.prefix(maxCandidates))
    }

    // MARK: - healthSummary

    private func makeHealthSummary(
        sleepData: [DailyHealthData],
        lowSleepCount: Int,
        stepsData: [DailyHealthData],
        standData: [DailyHealthData],
        activeData: [DailyHealthData],
        workoutData: [DailyWorkoutData]
    ) -> HealthInsightGenerationContext.HealthSummary {
        let sleepAvg = average(of: sleepData.map(\.value).filter { $0 > 0 })
        let stepsAvg = average(of: stepsData.map(\.value).filter { $0 > 0 })
        let stepsGoalMet = stepsData.filter { $0.value >= stepsGoal }.count

        let standSummary: String
        if standData.contains(where: { $0.value > 0 }) {
            let standMet = standData.filter { $0.value >= HealthMetricType.standHours.dailyGoal }.count
            standSummary = "近 \(sleepData.count > 0 ? sleepData.count : 14) 天站立达标 \(standMet) 天"
        } else if activeData.contains(where: { $0.value > 0 }) {
            let activeAvg = average(of: activeData.map(\.value).filter { $0 > 0 })
            standSummary = "近 14 天活动均值 \(Int(activeAvg)) 分钟"
        } else {
            standSummary = "站立/活动数据不足"
        }

        let workoutDays = workoutData.filter { $0.totalMinutes >= workoutSufficientMinutes }
        let workoutSummary: String
        if workoutDays.isEmpty {
            workoutSummary = workoutData.contains(where: { $0.totalMinutes > 0 }) ? "近 14 天偶有运动" : "近 14 天无锻炼记录"
        } else {
            let totalMinutes = workoutDays.reduce(0.0) { $0 + $1.totalMinutes }
            let topType = workoutDays.compactMap(\.topType).first
            workoutSummary = "近 14 天运动充足 \(workoutDays.count) 天，累计 \(Int(totalMinutes)) 分钟\(topType.map { "（主要是\($0)）" } ?? "")"
        }

        return HealthInsightGenerationContext.HealthSummary(
            sleepAverageHours: round1(sleepAvg),
            lowSleepDays: lowSleepCount,
            stepsAverage: round1(stepsAvg),
            stepsGoalMetDays: stepsGoalMet,
            standOrActiveSummary: standSummary,
            workoutSummary: workoutSummary
        )
    }

    // MARK: - contextHashInput（稳定摘要）

    private func makeContextHashInput(
        window: TimeWindow,
        healthSummary: HealthInsightGenerationContext.HealthSummary,
        candidates: [HealthInsightGenerationContext.CandidateCorrelation]
    ) -> String {
        let candidatePart = candidates
            .map { "\($0.id):\($0.confidenceHint)" }
            .joined(separator: ",")
        return [
            "\(window.days)",
            String(format: "%.1f", healthSummary.sleepAverageHours),
            "\(healthSummary.lowSleepDays)",
            String(format: "%.1f", healthSummary.stepsAverage),
            "\(healthSummary.stepsGoalMetDays)",
            "candidates:\(candidatePart)"
        ].joined(separator: "|")
    }

    private func defaultPreferenceHints() -> HealthInsightGenerationContext.PreferenceHints {
        HealthInsightGenerationContext.PreferenceHints(
            avoidPatterns: ["泛泛鼓励", "无证据因果判断", "把观点条数等同于情绪差"],
            preferTone: "观察者视角，轻建议，不下诊断"
        )
    }

    // MARK: - Helpers

    private func average(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    // MARK: - 日期格式化

    /// 证据 id 用：yyyyMMdd（en_US_POSIX，稳定）。
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    /// context JSON period 用：yyyy-MM-dd。
    private static let isoDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 展示用：M月d日（zh_CN）。
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func dayKey(from date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    static func dateString(from date: Date) -> String {
        isoDayFormatter.string(from: date)
    }

    static func displayDate(from date: Date) -> String {
        displayFormatter.string(from: date)
    }

    private static func encode(_ context: HealthInsightGenerationContext) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(context), let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

// MARK: - DayDatable（按日集合提取的统一抽象）

/// 支持按日 dayKey 提取的健康/活动值类型（DailyHealthData / DailyWorkoutData）。
protocol DayDatable {
    var dayDate: Date { get }
}

extension DailyHealthData: DayDatable {
    var dayDate: Date { date }
}

extension DailyWorkoutData: DayDatable {
    var dayDate: Date { date }
}
