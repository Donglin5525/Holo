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

    init(
        daily: [HoloHealthMetricKind: [HoloHealthDailyRecord]] = [:],
        workouts: [HoloHealthWorkoutRecord] = []
    ) {
        self.daily = daily
        self.workouts = workouts
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
}

@main
struct HoloHealthToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test睡眠摘要产出平均值达标天数和每日证据()
        try await test步数摘要产出日均达标天数和每日证据()
        try await test站立摘要产出日均达标天数和每日证据()
        try await test活动摘要产出日均达标天数和每日证据()
        try await test运动摘要产出总时长会话数和每日证据()
        try await test综合健康保留已有指标并报告缺失项()
        try await test覆盖率遵循闭开时间范围()
        try await test无睡眠数据返回empty()
        print("HoloHealthToolTests passed")
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

        expect(result.status == .success, "sleep_summary 应成功，实际 \(result.status)")
        expect(abs((metric("health.sleep.average_hours", in: result) ?? 0) - 6.9) < 0.01, "应计算平均睡眠 6.9 小时")
        expect(metric("health.sleep.goal_met_days", in: result) == 1, "应统计达标 1 天")
        expect(metric("health.sleep.low_days", in: result) == 1, "应统计少于 6 小时 1 天")
        expect(result.events.count == 3, "应为每天睡眠生成证据")
        expect(result.events.allSatisfy { $0.metricKey == "health.sleep.hours" }, "睡眠证据 metricKey 应一致")
        expect(result.sensitivity == .sensitive, "健康结果必须标记为敏感证据")
    }

    private static func test步数摘要产出日均达标天数和每日证据() async throws {
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(daily: [
            .steps: records([8_000, 10_000, 12_000])
        ]))

        let result = try await tool.execute(makeRequest(query: "steps_summary"))

        expect(result.status == .success, "steps_summary 应成功")
        expect(metric("health.steps.average", in: result) == 10_000, "日均步数应为 10000")
        expect(metric("health.steps.goal_met_days", in: result) == 2, "步数达标应为 2 天")
        expect(result.events.allSatisfy { $0.metricKey == "health.steps.daily" }, "应输出逐日步数证据")
    }

    private static func test站立摘要产出日均达标天数和每日证据() async throws {
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(daily: [
            .stand: records([8, 12, 13])
        ]))

        let result = try await tool.execute(makeRequest(query: "stand_summary"))

        expect(result.status == .success, "stand_summary 应成功")
        expect(abs((metric("health.stand.average_hours", in: result) ?? 0) - 11) < 0.01, "日均站立应为 11 小时")
        expect(metric("health.stand.goal_met_days", in: result) == 2, "站立达标应为 2 天")
        expect(result.events.allSatisfy { $0.metricKey == "health.stand.hours" }, "应输出逐日站立证据")
    }

    private static func test活动摘要产出日均达标天数和每日证据() async throws {
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(daily: [
            .activity: records([15, 30, 45])
        ]))

        let result = try await tool.execute(makeRequest(query: "activity_summary"))

        expect(result.status == .success, "activity_summary 应成功")
        expect(metric("health.activity.average_minutes", in: result) == 30, "日均活动应为 30 分钟")
        expect(metric("health.activity.goal_met_days", in: result) == 2, "活动达标应为 2 天")
        expect(result.events.allSatisfy { $0.metricKey == "health.activity.minutes" }, "应输出逐日活动证据")
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
        expect(result.events.count == 2, "应输出 2 天运动证据")
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
}
