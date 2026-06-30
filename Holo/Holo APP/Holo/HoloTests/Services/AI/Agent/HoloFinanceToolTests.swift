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
    func snapshot(
        timeRange: HoloAgentTimeRange?,
        baseline: HoloAgentTimeRange?,
        parameters: [String: String]
    ) async -> HoloFinanceToolRecord? { record }
}

@main
struct HoloFinanceToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test晚间餐饮频次相对baseline增加()
        try await test分类集中度输出top分类()
        try await test金额变化证据包含解析后的时间范围()
        try await test本月支出拆解返回分类金额和明细依据()
        try await test关键词趋势读取账单文本命中()
        try await test无财务记录返回empty()
        print("HoloFinanceToolTests passed")
    }

    private static func makeRequest(query: String, parameters: [String: String] = [:]) -> HoloToolRequest {
        HoloToolRequest(id: "req-1", tool: "finance", query: query,
                        timeRange: nil, baseline: nil, requiredMetrics: [], parameters: parameters)
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
    private static func test金额变化证据包含解析后的时间范围() async throws {
        let calendar = Calendar.current
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        let currentRange = HoloAgentTimeRange(
            label: "近两周",
            start: date(2024, 6, 2),
            end: date(2024, 6, 16)
        )
        let baselineRange = HoloAgentTimeRange(
            label: "对比期",
            start: date(2024, 5, 19),
            end: date(2024, 6, 2)
        )
        let record = HoloFinanceToolRecord(
            nighttimeMealCurrent: 0,
            nighttimeMealBaseline: 0,
            categoryCounts: [:],
            totalCurrentAmount: 9115,
            totalBaselineAmount: 6630,
            currentRange: currentRange,
            baselineRange: baselineRange
        )
        let tool = HoloFinanceTool(dataSource: MockFinanceDataSource(record: record))

        let result = try await tool.execute(makeRequest(query: "spending_pattern"))

        let event = result.events.first
        expect(event?.excerpt.contains("近两周") == true, "金额证据应写明用户口径标签")
        expect(event?.excerpt.contains("6月2日-6月15日") == true, "金额证据应写明本期实际日期")
        expect(event?.excerpt.contains("5月19日-6月1日") == true, "金额证据应写明对比期实际日期")
        expect(event?.timeRange == currentRange, "event 应携带本期时间范围供下钻复用")
        expect(event?.baselineTimeRange == baselineRange, "event 应携带对比期时间范围")
    }

    private static func test关键词趋势读取账单文本命中() async throws {
        let record = HoloFinanceToolRecord(
            nighttimeMealCurrent: 0,
            nighttimeMealBaseline: 0,
            categoryCounts: [:],
            totalCurrentAmount: 0,
            totalBaselineAmount: 0,
            keyword: "咖啡",
            keywordCurrentCount: 6,
            keywordBaselineCount: 2,
            keywordCurrentAmount: 96,
            keywordBaselineAmount: 34,
            keywordSampleExcerpts: ["6月10日 餐饮 咖啡 -¥17", "6月12日 餐饮 星巴克咖啡 -¥28"]
        )
        let tool = HoloFinanceTool(dataSource: MockFinanceDataSource(record: record))

        let result = try await tool.execute(makeRequest(query: "keyword_trend", parameters: ["keyword": "咖啡"]))

        expect(result.status == .success, "keyword_trend 应成功")
        expect(result.metrics.contains { $0.metricKey == "finance.keyword.count" && $0.value == 6 }, "应返回关键词命中次数")
        expect(result.metrics.contains { $0.metricKey == "finance.keyword.amount" && $0.value == 96 }, "应返回关键词命中金额")
        expect(result.events.first?.excerpt.contains("咖啡") == true, "证据摘要应包含关键词")
        expect(result.events.first?.excerpt.contains("6 次") == true, "证据摘要应包含当前命中次数")
        expect(result.events.first?.excerpt.contains("样例") == true, "证据摘要应包含账单样例")
    }

    private static func test本月支出拆解返回分类金额和明细依据() async throws {
        let calendar = Calendar.current
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        let currentRange = HoloAgentTimeRange(
            label: "本月",
            start: date(2026, 6, 1),
            end: date(2026, 7, 1)
        )
        let record = HoloFinanceToolRecord(
            nighttimeMealCurrent: 0,
            nighttimeMealBaseline: 0,
            categoryCounts: ["交通": 8, "餐饮": 21],
            categoryAmounts: ["交通": 5200, "餐饮": 3600, "购物": 2400],
            totalCurrentAmount: 14_000,
            totalBaselineAmount: 0,
            transactionCount: 42,
            currentRange: currentRange,
            topExpenseExcerpts: ["6月12日 交通 停车 -¥1200", "6月18日 餐饮 聚餐 -¥680"]
        )
        let tool = HoloFinanceTool(dataSource: MockFinanceDataSource(record: record))

        let result = try await tool.execute(makeRequest(query: "spending_breakdown"))

        expect(result.status == .success, "spending_breakdown 应成功")
        let hasTotalMetric = result.metrics.contains { metric in
            metric.metricKey == "finance.total.amount" && metric.value == 14_000
        }
        let trafficMetric = result.metrics.first { metric in
            metric.metricKey == "finance.category.amount"
                && metric.comparison == "交通"
        }
        let hasTrafficMetric = trafficMetric?.value == 5200
        let hasTotalEvent = result.events.contains { event in
            event.metricKey == "finance.total.amount" && event.excerpt.contains("本月总支出：14000 元")
        }
        let hasTrafficEvent = result.events.contains { event in
            event.metricKey == "finance.category.amount" && event.excerpt.contains("交通：5200 元")
        }
        let hasSampleEvent = result.events.contains { event in
            event.metricKey == "finance.transaction.sample" && event.excerpt.contains("停车")
        }
        expect(hasTotalMetric, "应返回本月总支出 14000")
        expect(hasTrafficMetric, "应返回交通分类金额")
        expect(hasTotalEvent, "应有总额证据")
        expect(hasTrafficEvent, "应有分类金额证据")
        expect(hasSampleEvent, "应有可核对明细样例")
        expect(result.events.allSatisfy { $0.timeRange == currentRange }, "所有拆解证据应携带本月时间范围")
    }

    /// 无财务记录返回 .empty。
    private static func test无财务记录返回empty() async throws {
        let tool = HoloFinanceTool(dataSource: MockFinanceDataSource(record: nil))

        let result = try await tool.execute(makeRequest(query: "spending_pattern"))

        expect(result.status == .empty, "无数据应返回 empty，实际 \(result.status)")
        expect(result.metrics.isEmpty, "empty 不应带 metrics")
    }
}
