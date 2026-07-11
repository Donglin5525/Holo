//
//  HoloHealthToolTests.swift
//  HoloTests
//
//  Agent V3.1 — HealthTool 全指标分析测试
//

import Foundation

struct MockHealthDataSource: HoloHealthDataSource {
    let daily: [HoloHealthMetricKind: [HoloHealthDailyRecord]]
    let workouts: [HoloHealthWorkoutRecord]
    let sleeps: [HoloSleepRecord]?

    init(
        daily: [HoloHealthMetricKind: [HoloHealthDailyRecord]] = [:],
        workouts: [HoloHealthWorkoutRecord] = [],
        sleeps: [HoloSleepRecord]? = nil
    ) {
        self.daily = daily
        self.workouts = workouts
        self.sleeps = sleeps
    }

    func dailyRecords(
        for metric: HoloHealthMetricKind,
        timeRange: HoloAgentTimeRange?
    ) async -> [HoloHealthDailyRecord] {
        daily[metric] ?? []
    }

    func workoutRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthWorkoutRecord] {
        workouts
    }

    func sleepRecords(timeRange: HoloAgentTimeRange?) async -> [HoloSleepRecord] {
        if let sleeps { return sleeps }
        return (daily[.sleep] ?? []).map {
            HoloSleepRecord(date: $0.date, totalHours: $0.value, coreHours: nil, deepHours: nil,
                            remHours: nil, awakeHours: nil, inBedHours: nil, bedtime: nil,
                            wakeTime: nil, interruptionCount: nil)
        }
    }
}

@main
struct HoloHealthToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test睡眠摘要产出平均值达标天数和每日证据()
        try await test睡眠阶段存在时输出完整质量维度()
        try await test步数摘要产出日均达标天数和每日证据()
        try await test站立摘要产出日均达标天数和每日证据()
        try await test活动摘要产出日均达标天数和每日证据()
        try await test运动摘要产出总时长会话数和每日证据()
        try await test综合健康保留已有指标并报告缺失项()
        try await test覆盖率遵循闭开时间范围()
        try await test无睡眠数据返回empty()
        try test动态查询可现场计算平均睡眠与低睡眠占比()
        try test动态查询可比较周末与工作日步数()
        try test动态查询拒绝未注册字段和超长范围()
        print("HoloHealthToolTests passed")
    }

    private static func test睡眠阶段存在时输出完整质量维度() async throws {
        let sleeps = [1, 2].map { day in
            HoloSleepRecord(date: date(day), totalHours: 8, coreHours: 4, deepHours: 1.5,
                            remHours: 2, awakeHours: 0.5, inBedHours: 8.5,
                            bedtime: date(day).addingTimeInterval(23 * 3600),
                            wakeTime: date(day + 1).addingTimeInterval(7.5 * 3600), interruptionCount: 2)
        }
        let result = try await HoloHealthTool(dataSource: MockHealthDataSource(sleeps: sleeps))
            .execute(makeRequest(query: "sleep_summary"))
        expect(result.status == .success, "阶段覆盖完整时应为 success")
        expect(metric("health.sleep.deep_hours", in: result) == 1.5, "应输出深睡")
        expect(metric("health.sleep.core_hours", in: result) == 4, "应输出核心睡眠")
        expect(metric("health.sleep.rem_hours", in: result) == 2, "应输出 REM")
        expect(metric("health.sleep.efficiency", in: result) != nil, "应输出睡眠效率")
        expect(metric("health.sleep.average_bedtime_minutes", in: result) != nil, "应输出平均入睡时间")
        expect(metric("health.sleep.average_wake_minutes", in: result) != nil, "应输出平均起床时间")
        expect(!result.warnings.contains { $0.code == "SLEEP_DURATION_ONLY" }, "阶段齐全时不应降级")
    }

    private static func makeRequest(
        query: String,
        timeRange: HoloAgentTimeRange? = nil
    ) -> HoloToolRequest {
        HoloToolRequest(
            id: "health-\(query)",
            tool: "health",
            query: query,
            timeRange: timeRange,
            baseline: nil,
            requiredMetrics: [],
            parameters: [:]
        )
    }

    private static func date(_ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 7, day: day)
        )!
    }

    private static func records(_ values: [Double]) -> [HoloHealthDailyRecord] {
        values.enumerated().map { index, value in
            HoloHealthDailyRecord(date: date(index + 1), value: value)
        }
    }

    private static func metric(_ key: String, in result: HoloDataToolResult) -> Double? {
        result.metrics.first { $0.metricKey == key }?.value
    }

    private static func test睡眠摘要产出平均值达标天数和每日证据() async throws {
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(daily: [
            .sleep: records([5.5, 7.0, 8.2])
        ]))

        let result = try await tool.execute(makeRequest(query: "sleep_summary"))

        expect(result.status == .partial, "只有时长时应降级为 partial，实际 \(result.status)")
        expect(abs((metric("health.sleep.average_hours", in: result) ?? 0) - 6.9) < 0.01, "应计算平均睡眠 6.9 小时")
        expect(metric("health.sleep.goal_met_days", in: result) == 1, "应统计达标 1 天")
        expect(metric("health.sleep.low_days", in: result) == 1, "应统计少于 6 小时 1 天")
        expect(metric("health.sleep.recorded_nights", in: result) == 3, "应统计 3 晚有效记录")
        expect(result.events.filter { $0.metricKey == "health.sleep.hours" }.count == 3, "应为每天睡眠生成证据")
        expect(result.events.contains { $0.metricKey == "health.sleep.average_hours" && $0.metricValue == 6.9 }, "平均睡眠指标必须有可校验的汇总证据")
        expect(result.events.contains { $0.metricKey == "health.sleep.goal_met_days" && $0.metricValue == 1 }, "睡眠达标天数必须有可校验的汇总证据")
        expect(result.sensitivity == .sensitive, "健康结果必须标记为敏感证据")
        expect(result.warnings.contains { $0.code == "SLEEP_DURATION_ONLY" }, "只有时长时必须明确能力边界")
        expect(result.events.contains { $0.excerpt.contains("不能完整判断睡眠质量") }, "证据必须说明不能伪装成质量分析")
    }

    private static func test步数摘要产出日均达标天数和每日证据() async throws {
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(daily: [
            .steps: records([8_000, 10_000, 12_000])
        ]))

        let result = try await tool.execute(makeRequest(query: "steps_summary"))

        expect(result.status == .success, "steps_summary 应成功")
        expect(metric("health.steps.average", in: result) == 10_000, "日均步数应为 10000")
        expect(metric("health.steps.goal_met_days", in: result) == 2, "步数达标应为 2 天")
        expect(result.events.filter { $0.metricKey == "health.steps.daily" }.count == 3, "应输出逐日步数证据")
        expect(result.events.contains { $0.metricKey == "health.steps.average" && $0.metricValue == 10_000 }, "日均步数必须有汇总证据")
    }

    private static func test站立摘要产出日均达标天数和每日证据() async throws {
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(daily: [
            .stand: records([8, 12, 13])
        ]))

        let result = try await tool.execute(makeRequest(query: "stand_summary"))

        expect(result.status == .success, "stand_summary 应成功")
        expect(abs((metric("health.stand.average_hours", in: result) ?? 0) - 11) < 0.01, "日均站立应为 11 小时")
        expect(metric("health.stand.goal_met_days", in: result) == 2, "站立达标应为 2 天")
        expect(result.events.filter { $0.metricKey == "health.stand.hours" }.count == 3, "应输出逐日站立证据")
        expect(result.events.contains { $0.metricKey == "health.stand.average_hours" && $0.metricValue == 11 }, "日均站立必须有汇总证据")
    }

    private static func test活动摘要产出日均达标天数和每日证据() async throws {
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(daily: [
            .activity: records([15, 30, 45])
        ]))

        let result = try await tool.execute(makeRequest(query: "activity_summary"))

        expect(result.status == .success, "activity_summary 应成功")
        expect(metric("health.activity.average_minutes", in: result) == 30, "日均活动应为 30 分钟")
        expect(metric("health.activity.goal_met_days", in: result) == 2, "活动达标应为 2 天")
        expect(result.events.filter { $0.metricKey == "health.activity.minutes" }.count == 3, "应输出逐日活动证据")
        expect(result.events.contains { $0.metricKey == "health.activity.average_minutes" && $0.metricValue == 30 }, "日均活动必须有汇总证据")
    }

    private static func test运动摘要产出总时长会话数和每日证据() async throws {
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(workouts: [
            HoloHealthWorkoutRecord(date: date(1), totalMinutes: 30, sessionCount: 1, topType: "跑步"),
            HoloHealthWorkoutRecord(date: date(3), totalMinutes: 45, sessionCount: 2, topType: "力量训练")
        ]))

        let result = try await tool.execute(makeRequest(query: "workout_summary"))

        expect(result.status == .success, "workout_summary 应成功")
        expect(metric("health.workout.total_minutes", in: result) == 75, "运动总时长应为 75 分钟")
        expect(metric("health.workout.session_count", in: result) == 3, "运动会话应为 3 次")
        expect(metric("health.workout.active_days", in: result) == 2, "运动天数应为 2 天")
        expect(result.events.filter { $0.metricKey == "health.workout.daily_minutes" }.count == 2, "应输出 2 天运动证据")
        expect(result.events.contains { $0.metricKey == "health.workout.total_minutes" && $0.metricValue == 75 }, "运动总时长必须有汇总证据")
    }

    private static func test综合健康保留已有指标并报告缺失项() async throws {
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(daily: [
            .steps: records([9_000, 11_000]),
            .sleep: records([7, 8])
        ]))

        let result = try await tool.execute(makeRequest(query: "health_overview"))

        expect(result.status == .partial, "部分健康指标可用时应返回 partial")
        expect(metric("health.steps.average", in: result) != nil, "综合健康应保留步数")
        expect(metric("health.sleep.average_hours", in: result) != nil, "综合健康应保留睡眠")
        expect(result.warnings.contains { $0.code == "NO_STAND_DATA" }, "应报告站立缺失")
        expect(result.warnings.contains { $0.code == "NO_ACTIVITY_DATA" }, "应报告活动缺失")
        expect(result.warnings.contains { $0.code == "NO_WORKOUT_DATA" }, "应报告运动缺失")
    }

    private static func test覆盖率遵循闭开时间范围() async throws {
        let range = HoloAgentTimeRange(label: "7天", start: date(1), end: date(8))
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(daily: [
            .steps: records([8_000, 9_000])
        ]))

        let result = try await tool.execute(makeRequest(query: "steps_summary", timeRange: range))

        expect(result.coverage?.coveredDays == 2, "有效覆盖应为 2 天")
        expect(result.coverage?.totalDays == 7, "[7/1, 7/8) 应为 7 天")
        expect(abs((result.coverage?.coverageRatio ?? 0) - 2.0 / 7.0) < 0.001, "覆盖率应为 2/7")
    }

    private static func test无睡眠数据返回empty() async throws {
        let tool = HoloHealthTool(dataSource: MockHealthDataSource())

        let result = try await tool.execute(makeRequest(query: "sleep_summary"))

        expect(result.status == .empty, "无睡眠数据应返回 empty")
        expect(result.metrics.isEmpty, "empty 不应带 metrics")
        expect(result.events.isEmpty, "empty 不应带 events")
        expect(result.warnings.contains { $0.code == "NO_SLEEP_DATA" }, "应明确睡眠数据缺失")
    }

    private static func test动态查询可现场计算平均睡眠与低睡眠占比() throws {
        let rows = records([5.5, 7.0, 8.2]).map { record in
            HoloQueryRow(id: UUID().uuidString, occurredAt: record.date, fields: ["date": .date(record.date), "value": .number(record.value)], excerpt: "sleep")
        }
        let plan = HoloDynamicQueryPlan(
            source: "health.sleep",
            aggregations: [
                HoloDynamicAggregation(id: "average_sleep", operation: .average, field: "value", unit: "小时"),
                HoloDynamicAggregation(id: "low_days", operation: .count, filters: [HoloDynamicFilter(field: "value", operation: .lessThan, value: .number(6))]),
                HoloDynamicAggregation(id: "total_days", operation: .count)
            ],
            derivations: [HoloDynamicDerivation(id: "low_ratio", operation: .rate, metricID: "low_days", denominatorMetricID: "total_days", unit: "比例")]
        )
        let output = try HoloDynamicQueryEngine.execute(plan: plan, catalog: HoloHealthTool.dynamicCatalog, currentRows: rows)
        expect(output.metrics.contains { $0.metricKey.contains("average_sleep") && abs(($0.value ?? 0) - 6.9) < 0.01 }, "应现场计算平均睡眠")
        expect(output.metrics.contains { $0.metricKey.contains("low_ratio") && abs(($0.value ?? 0) - 1.0 / 3.0) < 0.001 }, "应现场计算低睡眠占比")
        expect(output.events.allSatisfy { $0.formula?.isEmpty == false && !($0.sourceRecordIDs ?? []).isEmpty }, "动态指标必须带公式和来源")
    }

    private static func test动态查询可比较周末与工作日步数() throws {
        let rows = [
            HoloQueryRow(id: "fri", occurredAt: date(3), fields: ["date": .date(date(3)), "value": .number(8_000)], excerpt: "fri"),
            HoloQueryRow(id: "sat", occurredAt: date(4), fields: ["date": .date(date(4)), "value": .number(12_000)], excerpt: "sat"),
            HoloQueryRow(id: "sun", occurredAt: date(5), fields: ["date": .date(date(5)), "value": .number(10_000)], excerpt: "sun")
        ]
        let plan = HoloDynamicQueryPlan(
            source: "health.steps",
            groupBy: [HoloDynamicGrouping(type: .weekend)],
            aggregations: [HoloDynamicAggregation(id: "average_steps", operation: .average, field: "value", unit: "步")]
        )
        let output = try HoloDynamicQueryEngine.execute(plan: plan, catalog: HoloHealthTool.dynamicCatalog, currentRows: rows)
        expect(output.metrics.contains { $0.comparison == "weekend" && $0.value == 11_000 }, "周末平均步数应为 11000")
        expect(output.metrics.contains { $0.comparison == "weekday" && $0.value == 8_000 }, "工作日平均步数应为 8000")
    }

    private static func test动态查询拒绝未注册字段和超长范围() throws {
        let invalidField = HoloDynamicQueryPlan(source: "health.sleep", aggregations: [HoloDynamicAggregation(id: "x", operation: .average, field: "heartRate")])
        do {
            _ = try HoloDynamicQueryEngine.execute(plan: invalidField, catalog: HoloHealthTool.dynamicCatalog, currentRows: [])
            fatalError("未注册字段必须被拒绝")
        } catch HoloDynamicQueryValidationError.unknownField("heartRate") {}

        let range = HoloAgentTimeRange(label: "过长", start: date(1), end: Calendar.current.date(byAdding: .day, value: 400, to: date(1)))
        let longRange = HoloDynamicQueryPlan(source: "health.sleep", timeRange: range, aggregations: [HoloDynamicAggregation(id: "count", operation: .count)])
        do {
            _ = try HoloDynamicQueryEngine.execute(plan: longRange, catalog: HoloHealthTool.dynamicCatalog, currentRows: [])
            fatalError("超长范围必须被拒绝")
        } catch HoloDynamicQueryValidationError.rangeTooLarge {}
    }
}
