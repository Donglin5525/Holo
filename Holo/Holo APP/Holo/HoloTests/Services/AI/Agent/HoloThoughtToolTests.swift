//
//  HoloThoughtToolTests.swift
//  HoloTests
//
//  Agent V3.1 — ThoughtTool 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Tools/HoloDataTool.swift> \
//    <Services/AI/Agent/Tools/HoloThoughtTool.swift> <本测试> \
//    -o /tmp/holo_thought_tool_test && /tmp/holo_thought_tool_test
//

import Foundation

struct MockThoughtDataSource: HoloThoughtDataSource {
    let snapshot: HoloThoughtToolSnapshot
    func snapshot(timeRange: HoloAgentTimeRange?) async -> HoloThoughtToolSnapshot { snapshot }
}

@main
struct HoloThoughtToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test心情摘要产出分布指标与事件()
        try await test主题摘要产出标签与脱敏摘录()
        try await testTopic摘要产出收敛主题与标签证据()
        try await test活跃趋势产出每日事件()
        try await test空想法返回empty()
        test不支持查询返回invalid()
        print("HoloThoughtToolTests passed")
    }

    private static func makeRequest(query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "thought-1", tool: "thought", query: query,
            timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:]
        )
    }

    private static func makeSnapshot(
        totalCount: Int = 0,
        moodDistribution: [String: Int] = [:],
        topTags: [String] = [],
        snippets: [String] = [],
        dailyCounts: [String: Int] = [:],
        topics: [HoloThoughtTopicRecord] = []
    ) -> HoloThoughtToolSnapshot {
        HoloThoughtToolSnapshot(
            totalCount: totalCount,
            moodDistribution: moodDistribution,
            topTags: topTags,
            snippets: snippets,
            dailyCounts: dailyCounts,
            topics: topics
        )
    }

    private static func test心情摘要产出分布指标与事件() async throws {
        let snapshot = makeSnapshot(
            totalCount: 10,
            moodDistribution: ["happy": 6, "calm": 4]
        )
        let tool = HoloThoughtTool(dataSource: MockThoughtDataSource(snapshot: snapshot))

        let result = try await tool.execute(makeRequest(query: "mood_summary"))

        expect(result.status == .success, "mood_summary 应成功，实际 \(result.status)")
        expect(result.metrics.contains { $0.metricKey == "thought.count.total" && $0.value == 10 }, "想法总数应为 10")
        expect(result.metrics.contains { $0.metricKey == "thought.mood.count" && $0.value == 10 }, "有心情记录应为 10")
        expect(result.events.count == 2, "应为每种心情生成一条证据，实际 \(result.events.count)")
    }

    private static func test主题摘要产出标签与脱敏摘录() async throws {
        let snapshot = makeSnapshot(
            totalCount: 5,
            topTags: ["工作", "运动"],
            snippets: ["今天开会很有收获", "跑步感觉不错"]
        )
        let tool = HoloThoughtTool(dataSource: MockThoughtDataSource(snapshot: snapshot))

        let result = try await tool.execute(makeRequest(query: "thought_theme_summary"))

        expect(result.status == .success, "thought_theme_summary 应成功，实际 \(result.status)")
        expect(result.events.contains { $0.excerpt.contains("热门标签：工作") }, "应含标签事件")
        expect(result.events.contains { $0.excerpt.contains("最近想法出现") }, "应含脱敏摘录事件")
    }

    private static func test活跃趋势产出每日事件() async throws {
        let snapshot = makeSnapshot(
            totalCount: 8,
            dailyCounts: ["2026-06-25": 3, "2026-06-26": 5]
        )
        let tool = HoloThoughtTool(dataSource: MockThoughtDataSource(snapshot: snapshot))

        let result = try await tool.execute(makeRequest(query: "thought_activity_trend"))

        expect(result.status == .success, "thought_activity_trend 应成功，实际 \(result.status)")
        expect(result.metrics.contains { $0.metricKey == "thought.activity.daily_count" && $0.value == 5 }, "单日最大应为 5")
        expect(result.events.count == 2, "应为每天生成一条证据，实际 \(result.events.count)")
    }

    private static func testTopic摘要产出收敛主题与标签证据() async throws {
        let snapshot = makeSnapshot(
            topics: [
                HoloThoughtTopicRecord(
                    title: "产品与长期主义",
                    summary: "围绕产品判断和长期积累",
                    thoughtCount: 6,
                    associatedTagNames: ["产品", "长期主义"]
                )
            ]
        )
        let result = try await HoloThoughtTool(
            dataSource: MockThoughtDataSource(snapshot: snapshot)
        ).execute(makeRequest(query: "topic_summary"))

        expect(result.status == .success, "topic_summary 应成功")
        expect(result.metrics.contains { $0.metricKey == "thought.topic.count" && $0.value == 1 }, "应返回 1 个 Topic")
        expect(result.events.first?.excerpt.contains("产品与长期主义") == true, "应包含 Topic 标题")
        expect(result.events.first?.excerpt.contains("产品、长期主义") == true, "应包含关联标签")
        expect(result.sensitivity == .sensitive, "观点工具结果必须标记 sensitive")
    }

    private static func test空想法返回empty() async throws {
        let tool = HoloThoughtTool(dataSource: MockThoughtDataSource(snapshot: makeSnapshot()))

        let result = try await tool.execute(makeRequest(query: "mood_summary"))

        expect(result.status == .empty, "空想法应返回 empty，实际 \(result.status)")
        expect(result.metrics.isEmpty, "empty 不应带 metrics")
        expect(result.events.isEmpty, "empty 不应带 events")
    }

    private static func test不支持查询返回invalid() {
        let tool = HoloThoughtTool(dataSource: MockThoughtDataSource(snapshot: makeSnapshot()))
        let result = tool.validate(makeRequest(query: "unknown_query"))
        if case .invalid = result {
            return
        }
        fatalError("不支持查询应返回 .invalid，实际 \(result)")
    }
}
