//
//  HoloHabitTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.4 习惯工具 MVP
//  计算负向习惯控制（频率变化/超限/控制率/目标冲突）与正向习惯（完成率/连续中断），转为 Agent 证据。
//  依赖 HoloHabitDataSource 协议而非真实 repository，便于测试注入；生产适配后续集成。
//

import Foundation

/// 每日计数：dayOffset=0 为最新天，正数为更早。数组顺序由调用方提供，内部按 dayOffset 降序（早→近）排序后使用。
struct HoloHabitDailyCount: Codable, Equatable, Sendable {
    var dayOffset: Int
    var count: Double
}

enum HoloHabitPolarity: String, Codable, Sendable {
    case positive
    case negative
}

/// HabitTool 读取的习惯记录（中性视图）。
struct HoloHabitToolRecord: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var polarity: HoloHabitPolarity
    /// 负向习惯=每日上限；正向习惯=每日目标次数。
    var dailyGoal: Double?
    var dailyCounts: [HoloHabitDailyCount]
    /// 数值型习惯的单位（如 kg）；打卡型为 nil，展示时按「次」处理。
    var unit: String? = nil
    /// 是否为测量型习惯（如体重/体脂）。
    /// 测量型：未记录日 value=0 表示「没测」，是缺失值，统计时必须跳过，否则 average/trend 被零稀释。
    /// 打卡/计数型：value=0 表示「今天没做」，是真实语义，必须保留。
    /// 默认 false 以兼容旧持久化数据。
    var isMeasureType: Bool = false
}

/// 习惯数据源协议：生产实现适配真实 habit repository（后续集成），测试用 mock。
protocol HoloHabitDataSource: Sendable {
    func habits(timeRange: HoloAgentTimeRange?) async -> [HoloHabitToolRecord]
}

/// 习惯工具：把每日打卡数据计算为可信指标与证据。
struct HoloHabitTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "habit",
        description: "习惯数据分析（负向控制 / 趋势 / 目标冲突）",
        supportedQueries: ["trend_summary", "negative_habit_control", "goal_conflict"],
        supportedTimeRanges: [],
        outputMetrics: [
            "habit.negative.frequency_change",
            "habit.negative.over_limit_days",
            "habit.negative.control_rate",
            "habit.negative.goal_conflict_days",
            "habit.positive.completion_rate",
            "habit.streak_break_days"
        ],
        sensitivityPolicy: "normal"
    )

    private let dataSource: HoloHabitDataSource

    init(dataSource: HoloHabitDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        let supported: Set<String> = ["trend_summary", "negative_habit_control", "goal_conflict"]
        if supported.contains(request.query) { return .valid }
        return .invalid(reason: "不支持的查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        let historicalRange = HoloAgentHistoricalTimePolicy.resolve(request.timeRange)
        guard !historicalRange.isEntirelyFuture else { return Self.emptyResult(request) }
        var scopedRequest = request
        scopedRequest.timeRange = historicalRange.effectiveRange
        let habits = await dataSource.habits(timeRange: scopedRequest.timeRange)
        let result: HoloDataToolResult
        switch scopedRequest.query {
        case "negative_habit_control":
            result = negativeControlResult(request: scopedRequest, habits: habits)
        case "goal_conflict":
            result = goalConflictResult(request: scopedRequest, habits: habits)
        case "trend_summary":
            result = trendSummaryResult(request: scopedRequest, habits: habits)
        default:
            result = Self.errorResult(scopedRequest, reason: "不支持的查询：\(scopedRequest.query)")
        }
        // P3：固定指标统一挂类型化语义
        return HoloMetricSemanticFactory.attachFixedToolSemantics(to: result)
    }

    // MARK: - 各 query 实现

    private func negativeControlResult(request: HoloToolRequest, habits: [HoloHabitToolRecord]) -> HoloDataToolResult {
        let negatives = habits.filter { $0.polarity == .negative }
        if negatives.isEmpty { return Self.emptyResult(request) }

        var metrics: [HoloMetric] = []
        var events: [HoloEvidenceEvent] = []
        for habit in negatives {
            let counts = Self.sortedCounts(habit)
            metrics.append(contentsOf: Self.negativeMetrics(habit: habit, counts: counts))
            events.append(contentsOf: Self.negativeEvents(habit: habit, counts: counts))
        }
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil,
            recordCount: habits.count
        )
    }

    private func goalConflictResult(request: HoloToolRequest, habits: [HoloHabitToolRecord]) -> HoloDataToolResult {
        let negatives = habits.filter { $0.polarity == .negative }
        if negatives.isEmpty { return Self.emptyResult(request) }

        var metrics: [HoloMetric] = []
        var events: [HoloEvidenceEvent] = []
        for habit in negatives {
            let counts = Self.sortedCounts(habit)
            let overLimit = Self.overLimitDays(counts: counts, goal: habit.dailyGoal)
            metrics.append(HoloMetric(metricKey: "habit.negative.goal_conflict_days",
                                      value: Double(overLimit), unit: "天", baselineValue: nil, comparison: nil))
            events.append(contentsOf: Self.negativeEvents(habit: habit, counts: counts))
        }
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil,
            recordCount: habits.count
        )
    }

    private func trendSummaryResult(request: HoloToolRequest, habits: [HoloHabitToolRecord]) -> HoloDataToolResult {
        let positives = habits.filter { $0.polarity == .positive }
        if positives.isEmpty { return Self.emptyResult(request) }

        var metrics: [HoloMetric] = []
        var events: [HoloEvidenceEvent] = []
        for habit in positives {
            let counts = Self.sortedCounts(habit)
            metrics.append(HoloMetric(metricKey: "habit.positive.completion_rate",
                                      value: Self.completionRate(counts: counts, goal: habit.dailyGoal),
                                      unit: "", baselineValue: nil, comparison: nil))
            metrics.append(HoloMetric(metricKey: "habit.streak_break_days",
                                      value: Double(Self.streakBreakDays(counts: counts, goal: habit.dailyGoal)),
                                      unit: "天", baselineValue: nil, comparison: nil))
            events.append(contentsOf: Self.positiveEvents(habit: habit, counts: counts))
        }
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil,
            recordCount: habits.count
        )
    }

    // MARK: - 计算辅助

    /// 按 dayOffset 降序（早 → 近），保证 first=最早、last=最新。
    private static func sortedCounts(_ habit: HoloHabitToolRecord) -> [HoloHabitDailyCount] {
        habit.dailyCounts.sorted { $0.dayOffset > $1.dayOffset }
    }

    private static func negativeMetrics(habit: HoloHabitToolRecord, counts: [HoloHabitDailyCount]) -> [HoloMetric] {
        let first = counts.first?.count ?? 0
        let last = counts.last?.count ?? 0
        let change = last - first
        let direction = last > first ? "increasing" : (last < first ? "decreasing" : "stable")
        let overLimit = overLimitDays(counts: counts, goal: habit.dailyGoal)
        let total = counts.count
        let controlRate = total > 0 ? Double(total - overLimit) / Double(total) : 0

        return [
            HoloMetric(metricKey: "habit.negative.frequency_change", value: change, unit: "次",
                       baselineValue: first, comparison: direction),
            HoloMetric(metricKey: "habit.negative.over_limit_days", value: Double(overLimit), unit: "天",
                       baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "habit.negative.control_rate", value: controlRate, unit: "",
                       baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "habit.negative.goal_conflict_days", value: Double(overLimit), unit: "天",
                       baselineValue: nil, comparison: nil)
        ]
    }

    /// 超过上限的天数（严格大于 goal）。
    private static func overLimitDays(counts: [HoloHabitDailyCount], goal: Double?) -> Int {
        guard let goal else { return 0 }
        return counts.filter { $0.count > goal }.count
    }

    /// 完成率 = 达标天数 / 总天数（count >= goal）。
    private static func completionRate(counts: [HoloHabitDailyCount], goal: Double?) -> Double {
        guard let goal, !counts.isEmpty else { return 0 }
        let met = counts.filter { $0.count >= goal }.count
        return Double(met) / Double(counts.count)
    }

    /// 从最新天（数组末尾）往前，连续未达标的天数；遇到达标即停。
    private static func streakBreakDays(counts: [HoloHabitDailyCount], goal: Double?) -> Int {
        guard let goal else { return 0 }
        var streak = 0
        for entry in counts.reversed() {
            if entry.count < goal {
                streak += 1
            } else {
                break
            }
        }
        return streak
    }

    private static func negativeEvents(habit: HoloHabitToolRecord, counts: [HoloHabitDailyCount]) -> [HoloEvidenceEvent] {
        // 只为 count > 0 的天生成证据（与 positiveEvents 一致）。count = 0 表示当天没发生，
        // 生成"发生 0 次"的证据是噪音，会让 AI 误以为用户频繁触发该习惯。
        counts
            .filter { $0.count > 0 }
            .map {
                HoloEvidenceEvent(id: "\(habit.id)-d\($0.dayOffset)", occurredAt: nil,
                                  metricKey: "habit.negative.frequency_change",
                                  metricValue: $0.count, excerpt: "\(habit.name) 发生 \(Int($0.count)) 次")
            }
    }

    private static func positiveEvents(habit: HoloHabitToolRecord, counts: [HoloHabitDailyCount]) -> [HoloEvidenceEvent] {
        // 只为 count > 0 的天生成证据。count = 0 表示当天没打卡，是"没做"而非"做了 0 次"；
        // 生成"完成 0 次"的证据会制造噪音，让 AI 误以为用户频繁打卡（看到 N 条同名证据）。
        counts
            .filter { $0.count > 0 }
            .map {
                HoloEvidenceEvent(id: "\(habit.id)-d\($0.dayOffset)", occurredAt: nil,
                                  metricKey: "habit.positive.completion_rate",
                                  metricValue: $0.count, excerpt: "\(habit.name) 完成 \(Int($0.count)) 次")
            }
    }

    private static func emptyResult(_ request: HoloToolRequest) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .empty,
            coverage: nil, metrics: [], events: [], warnings: [], error: nil
        )
    }

    private static func errorResult(_ request: HoloToolRequest, reason: String) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .error,
            coverage: nil, metrics: [], events: [], warnings: [],
            error: HoloToolError(code: HoloToolErrorCode.invalidParams, message: reason, recoverable: true)
        )
    }
}
