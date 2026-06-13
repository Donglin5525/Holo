//
//  HoloFinanceToolTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 2.5 FinanceTool MVP 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Tools/HoloDataTool.swift> \
//    <Services/AI/Agent/Tools/HoloFinanceTool.swift> <本测试> \
//    -o /tmp/holo_finance_tool_test && /tmp/holo_finance_tool_test
//

import Foundation

/// FinanceTool 测试专用数据源（独立命名，避免联合编译重复）。
struct MockFinanceDataSource: HoloFinanceDataSource {
    let record: HoloFinanceToolRecord?
    func snapshot(timeRange: HoloAgentTimeRange?, baseline: HoloAgentTimeRange?) async -> HoloFinanceToolRecord? { record }
}

@main
struct HoloFinanceToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test晚间餐饮频次相对baseline增加()
        try await test分类集中度输出top分类()
        try await test无财务记录返回empty()
        print("HoloFinanceToolTests passed")
    }

    private static func makeRequest(query: String) -> HoloToolRequest {
        HoloToolRequest(id: "req-1", tool: "finance", query: query,
                        timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:])
    }

    /// last_14 晚间餐饮 4 次，previous_14 1 次 → 增加。
    private static func test晚间餐饮频次相对baseline增加() async throws {
        let record = HoloFinanceToolRecord(
            nighttimeMealCurrent: 4, nighttimeMealBaseline: 1,
            categoryCounts: [:], totalCurrentAmount: 0, totalBaselineAmount: 0
        )
        let tool = HoloFinanceTool(dataSource: MockFinanceDataSource(record: record))

        let result = try await tool.execute(makeRequest(query: "meal_time_distribution"))

        expect(result.status == .success, "meal_time_distribution 应成功，实际 \(result.status)")
        let metric = result.metrics.first { $0.metricKey == "finance.meal.nighttime_count" }
        expect(metric?.value == 4, "晚间餐饮次数应为 4，实际 \(metric?.value ?? -1)")
        expect(metric?.baselineValue == 1, "基线应为 1")
        expect(metric?.comparison == "increasing", "方向应为 increasing（4 > 1）")
    }

    /// 分类集中度应输出 top 分类与占比。
    private static func test分类集中度输出top分类() async throws {
        let record = HoloFinanceToolRecord(
            nighttimeMealCurrent: 0, nighttimeMealBaseline: 0,
            categoryCounts: ["餐饮": 5, "交通": 2, "购物": 1],
            totalCurrentAmount: 0, totalBaselineAmount: 0
        )
        let tool = HoloFinanceTool(dataSource: MockFinanceDataSource(record: record))

        let result = try await tool.execute(makeRequest(query: "category_concentration"))

        expect(result.status == .success, "category_concentration 应成功")
        let metric = result.metrics.first { $0.metricKey == "finance.category.concentration" }
        expect(metric?.value != nil, "应有集中度指标")
        expect(metric?.comparison == "餐饮", "top 分类应为 餐饮，实际 \(metric?.comparison ?? "nil")")
        if let value = metric?.value {
            expect(value > 0 && value <= 1, "集中度应为占比 (0,1]，实际 \(value)")
        }
    }

    /// 无财务记录返回 .empty。
    private static func test无财务记录返回empty() async throws {
        let tool = HoloFinanceTool(dataSource: MockFinanceDataSource(record: nil))

        let result = try await tool.execute(makeRequest(query: "spending_pattern"))

        expect(result.status == .empty, "无数据应返回 empty，实际 \(result.status)")
        expect(result.metrics.isEmpty, "empty 不应带 metrics")
    }
}
