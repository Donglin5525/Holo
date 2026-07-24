//
//  HoloHabitToolTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 2.4 HabitTool MVP 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Tools/HoloDataTool.swift> \
//    <Services/AI/Agent/Tools/HoloHabitTool.swift> <本测试> \
//    -o /tmp/holo_habit_tool_test && /tmp/holo_habit_tool_test
//

import Foundation

/// HabitTool 测试专用数据源（独立命名，避免联合编译重复）。
struct MockHabitDataSource: HoloHabitDataSource {
    let habits: [HoloHabitToolRecord]
    func habits(timeRange: HoloAgentTimeRange?) async -> [HoloHabitToolRecord] { habits }
}

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloHabitToolTests.main()
    }
}
#endif
struct HoloHabitToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test负向习惯控制_频率上升与目标冲突()
        try await test正向习惯_完成率与连续中断()
        try await test无习惯数据返回empty()
        print("HoloHabitToolTests passed")
    }

    private static func makeRequest(query: String) -> HoloToolRequest {
        HoloToolRequest(id: "req-1", tool: "habit", query: query,
                        timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:])
    }

    /// 负向习惯：最近 3 天发生量 8 → 12 → 20，目标每天不超过 8。
    private static func test负向习惯控制_频率上升与目标冲突() async throws {
        let habit = HoloHabitToolRecord(
            id: "h-neg", name: "刷手机", polarity: .negative, dailyGoal: 8,
            // 数组顺序：旧 → 新
            dailyCounts: [
                HoloHabitDailyCount(dayOffset: 2, count: 8),
                HoloHabitDailyCount(dayOffset: 1, count: 12),
                HoloHabitDailyCount(dayOffset: 0, count: 20)
            ]
        )
        let tool = HoloHabitTool(dataSource: MockHabitDataSource(habits: [habit]))

        let result = try await tool.execute(makeRequest(query: "negative_habit_control"))

        expect(result.status == .success, "negative_habit_control 应成功，实际 \(result.status)")

        let freq = result.metrics.first { $0.metricKey == "habit.negative.frequency_change" }
        expect(freq?.value == 12, "频率变化应为 12（20-8），实际 \(freq?.value ?? -1)")
        expect(freq?.comparison == "increasing", "方向应为 increasing，实际 \(freq?.comparison ?? "nil")")

        let conflict = result.metrics.first { $0.metricKey == "habit.negative.goal_conflict_days" }
        expect(conflict?.value == 2, "目标冲突天数应为 2（12、20 超过 8），实际 \(conflict?.value ?? -1)")

        let overLimit = result.metrics.first { $0.metricKey == "habit.negative.over_limit_days" }
        expect(overLimit?.value == 2, "超限天数应为 2")

        expect(result.events.count >= 3, "evidence 至少含 3 天记录，实际 \(result.events.count)")
        expect(result.events.allSatisfy { !$0.excerpt.contains("完成") }, "负向习惯不应使用正向表达「完成」")
    }

    /// 正向习惯：完成率与连续中断天数。
    private static func test正向习惯_完成率与连续中断() async throws {
        let habit = HoloHabitToolRecord(
            id: "h-pos", name: "读书", polarity: .positive, dailyGoal: 1,
            // 旧 → 新：达标 1 天，最近 2 天未达标
            dailyCounts: [
                HoloHabitDailyCount(dayOffset: 2, count: 1),
                HoloHabitDailyCount(dayOffset: 1, count: 0),
                HoloHabitDailyCount(dayOffset: 0, count: 0)
            ]
        )
        let tool = HoloHabitTool(dataSource: MockHabitDataSource(habits: [habit]))

        let result = try await tool.execute(makeRequest(query: "trend_summary"))

        expect(result.status == .success, "trend_summary 应成功")

        let completion = result.metrics.first { $0.metricKey == "habit.positive.completion_rate" }
        expect(completion?.value != nil, "应有完成率")
        if let value = completion?.value {
            expect(value > 0 && value < 1, "完成率应在 (0,1)，实际 \(value)")
        }

        let streak = result.metrics.first { $0.metricKey == "habit.streak_break_days" }
        expect(streak?.value == 2, "最近连续中断应为 2 天，实际 \(streak?.value ?? -1)")
    }

    /// 无习惯数据时返回 .empty。
    private static func test无习惯数据返回empty() async throws {
        let tool = HoloHabitTool(dataSource: MockHabitDataSource(habits: []))

        let result = try await tool.execute(makeRequest(query: "negative_habit_control"))

        expect(result.status == .empty, "无数据应返回 empty，实际 \(result.status)")
        expect(result.metrics.isEmpty, "empty 不应带 metrics")
    }
}
