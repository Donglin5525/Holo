//
//  HoloInsightToolTests.swift
//  HoloTests
//

import Foundation

struct MockInsightDataSource: HoloInsightDataSource {
    let records: [HoloInsightToolRecord]
    func recentInsights(limit: Int) async -> [HoloInsightToolRecord] {
        Array(records.prefix(limit))
    }
}

@main
struct HoloInsightToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test最新观察只返回最新一条()
        try await test近期观察最多返回六条且不含原始响应()
        try await test空洞察返回empty()
        print("HoloInsightToolTests passed")
    }

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func record(_ index: Int) -> HoloInsightToolRecord {
        HoloInsightToolRecord(
            id: UUID(),
            periodType: index.isMultiple(of: 2) ? "weekly" : "daily",
            periodStart: base.addingTimeInterval(Double(index) * 86_400),
            periodEnd: base.addingTimeInterval(Double(index + 1) * 86_400),
            title: "观察 \(index)",
            summary: "第 \(index) 条结构化摘要",
            generatedAt: base.addingTimeInterval(Double(index) * 100),
            status: "ready"
        )
    }

    private static func request(_ query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "insight-\(query)", tool: "insight", query: query,
            timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:]
        )
    }

    private static func test最新观察只返回最新一条() async throws {
        let result = try await HoloInsightTool(
            dataSource: MockInsightDataSource(records: [record(1), record(3), record(2)])
        ).execute(request("latest_observation"))

        expect(result.status == .success, "latest_observation 应成功")
        expect(result.events.count == 1, "最新观察只返回一条")
        expect(result.events.first?.excerpt.contains("观察 3") == true, "应按 generatedAt 选择最新观察")
    }

    private static func test近期观察最多返回六条且不含原始响应() async throws {
        let records = (1...8).map(record)
        let result = try await HoloInsightTool(
            dataSource: MockInsightDataSource(records: records)
        ).execute(request("recent_observations"))

        expect(result.events.count == 6, "近期观察最多返回 6 条")
        expect(result.metrics.first { $0.metricKey == "insight.observation.count" }?.value == 6, "数量指标应为 6")
        expect(result.events.allSatisfy { !$0.excerpt.contains("rawResponse") && !$0.excerpt.contains("cardsJSON") }, "不得返回原始模型响应")
        expect(result.sensitivity == .sensitive, "历史洞察应标记 sensitive")
    }

    private static func test空洞察返回empty() async throws {
        let result = try await HoloInsightTool(
            dataSource: MockInsightDataSource(records: [])
        ).execute(request("latest_observation"))

        expect(result.status == .empty, "空洞察应返回 empty")
        expect(result.warnings.contains { $0.code == "NO_INSIGHT_DATA" }, "应返回明确 warning")
    }
}
