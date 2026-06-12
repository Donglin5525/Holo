//
//  HoloMemoryToolTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 2.3 MemoryTool 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Tools/HoloDataTool.swift> \
//    <Services/AI/Agent/Tools/HoloMemoryTool.swift> <本测试> \
//    -o /tmp/holo_memory_tool_test && /tmp/holo_memory_tool_test
//

import Foundation

/// MemoryTool 测试专用数据源（独立命名，避免联合编译重复）。
struct MockMemoryDataSource: HoloMemoryDataSource {
    let longTerm: [HoloMemoryToolRecord]
    let episodic: [HoloMemoryToolRecord]
    let suppressions: [HoloMemoryToolSuppression]

    func longTermConfirmed() async -> [HoloMemoryToolRecord] { longTerm }
    func episodicActive() async -> [HoloMemoryToolRecord] { episodic }
    func suppressionRules() async -> [HoloMemoryToolSuppression] { suppressions }
}

@main
struct HoloMemoryToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await testRecallSummary读取长期确认记忆()
        try await testRecentEpisodic读取情景活跃记忆()
        try await testSuppressionSummary读取抑制规则()
        try await test无记忆返回empty()
        print("HoloMemoryToolTests passed")
    }

    private static func makeRequest(query: String) -> HoloToolRequest {
        HoloToolRequest(id: "req-1", tool: "memory", query: query,
                        timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:])
    }

    /// recall_summary 应返回长期确认记忆，带计数 metric 与摘要 events。
    private static func testRecallSummary读取长期确认记忆() async throws {
        let source = MockMemoryDataSource(
            longTerm: [
                HoloMemoryToolRecord(id: "lt-1", title: "作息", summary: "用户通常早上6点起床", occurredAt: nil),
                HoloMemoryToolRecord(id: "lt-2", title: "消费", summary: "每月餐饮预算2000", occurredAt: nil)
            ],
            episodic: [], suppressions: []
        )
        let tool = HoloMemoryTool(dataSource: source)

        let result = try await tool.execute(makeRequest(query: "recall_summary"))

        expect(result.status == .success, "recall_summary 应成功，实际 \(result.status)")
        let countMetric = result.metrics.first { $0.metricKey == "memory.long_term.count" }
        expect(countMetric?.value == 2, "长期记忆计数应为 2，实际 \(String(describing: countMetric?.value))")
        expect(result.events.contains { $0.excerpt.contains("6点起床") }, "events 应含长期记忆摘要")
    }

    /// recent_episodic 应返回情景活跃记忆。
    private static func testRecentEpisodic读取情景活跃记忆() async throws {
        let source = MockMemoryDataSource(
            longTerm: [],
            episodic: [HoloMemoryToolRecord(id: "ep-1", title: "加班", summary: "本周加班明显增多", occurredAt: nil)],
            suppressions: []
        )
        let tool = HoloMemoryTool(dataSource: source)

        let result = try await tool.execute(makeRequest(query: "recent_episodic"))

        expect(result.status == .success, "recent_episodic 应成功")
        let countMetric = result.metrics.first { $0.metricKey == "memory.episodic.active_count" }
        expect(countMetric?.value == 1, "情景记忆计数应为 1")
        expect(result.events.contains { $0.excerpt.contains("加班") }, "events 应含情景记忆摘要")
    }

    /// suppression_summary 应返回抑制规则摘要。
    private static func testSuppressionSummary读取抑制规则() async throws {
        let source = MockMemoryDataSource(
            longTerm: [], episodic: [],
            suppressions: [HoloMemoryToolSuppression(id: "sup-1", originalSummary: "不再提醒「多喝热水」")]
        )
        let tool = HoloMemoryTool(dataSource: source)

        let result = try await tool.execute(makeRequest(query: "suppression_summary"))

        expect(result.status == .success, "suppression_summary 应成功")
        let countMetric = result.metrics.first { $0.metricKey == "memory.suppression.active_count" }
        expect(countMetric?.value == 1, "抑制规则计数应为 1")
        expect(result.events.contains { $0.excerpt.contains("多喝热水") }, "events 应含抑制规则摘要")
    }

    /// 无记忆时应返回 .empty。
    private static func test无记忆返回empty() async throws {
        let source = MockMemoryDataSource(longTerm: [], episodic: [], suppressions: [])
        let tool = HoloMemoryTool(dataSource: source)

        let result = try await tool.execute(makeRequest(query: "recall_summary"))

        expect(result.status == .empty, "无记忆应返回 empty，实际 \(result.status)")
        expect(result.metrics.isEmpty, "empty 不应带 metrics")
        expect(result.events.isEmpty, "empty 不应带 events")
    }
}
