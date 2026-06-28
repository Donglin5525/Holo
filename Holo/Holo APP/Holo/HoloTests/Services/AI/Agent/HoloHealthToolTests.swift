//
//  HoloHealthToolTests.swift
//  HoloTests
//
//  Agent V3.1 — HealthTool 睡眠分析测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Tools/HoloDataTool.swift> \
//    <Services/AI/Agent/Tools/HoloHealthTool.swift> <本测试> \
//    -o /tmp/holo_health_tool_test && /tmp/holo_health_tool_test
//

import Foundation

struct MockHealthDataSource: HoloHealthDataSource {
    let sleep: [HoloHealthDailyRecord]
    func sleepRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthDailyRecord] { sleep }
}

@main
struct HoloHealthToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test睡眠摘要产出平均值达标天数和每日证据()
        try await test无睡眠数据返回empty()
        print("HoloHealthToolTests passed")
    }

    private static func makeRequest(query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "health-1",
            tool: "health",
            query: query,
            timeRange: nil,
            baseline: nil,
            requiredMetrics: [],
            parameters: [:]
        )
    }

    private static func test睡眠摘要产出平均值达标天数和每日证据() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 6, day: 24))!
        let records = [
            HoloHealthDailyRecord(date: start, value: 5.5),
            HoloHealthDailyRecord(date: calendar.date(byAdding: .day, value: 1, to: start)!, value: 7.0),
            HoloHealthDailyRecord(date: calendar.date(byAdding: .day, value: 2, to: start)!, value: 8.2)
        ]
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(sleep: records))

        let result = try await tool.execute(makeRequest(query: "sleep_summary"))

        expect(result.status == .success, "sleep_summary 应成功，实际 \(result.status)")
        expect(result.metrics.contains { $0.metricKey == "health.sleep.average_hours" && abs(($0.value ?? 0) - 6.9) < 0.01 }, "应计算平均睡眠 6.9 小时")
        expect(result.metrics.contains { $0.metricKey == "health.sleep.goal_met_days" && $0.value == 1 }, "应统计达标 1 天")
        expect(result.metrics.contains { $0.metricKey == "health.sleep.low_days" && $0.value == 1 }, "应统计少于 6 小时 1 天")
        expect(result.events.count == 3, "应为每天睡眠生成证据，实际 \(result.events.count)")
        expect(result.events.allSatisfy { $0.metricKey == "health.sleep.hours" }, "睡眠证据 metricKey 应一致")
        expect(result.events.first?.excerpt.contains("睡眠") == true, "证据摘要应明确是睡眠")
    }

    private static func test无睡眠数据返回empty() async throws {
        let tool = HoloHealthTool(dataSource: MockHealthDataSource(sleep: []))

        let result = try await tool.execute(makeRequest(query: "sleep_summary"))

        expect(result.status == .empty, "无睡眠数据应返回 empty，实际 \(result.status)")
        expect(result.metrics.isEmpty, "empty 不应带 metrics")
        expect(result.events.isEmpty, "empty 不应带 events")
    }
}
