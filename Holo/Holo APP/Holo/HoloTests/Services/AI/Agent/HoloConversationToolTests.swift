//
//  HoloConversationToolTests.swift
//  HoloTests
//

import Foundation

struct MockConversationDataSource: HoloConversationDataSource {
    let records: [HoloConversationRecord]
    var status: HoloDataSourceReadStatus = .success
    var totalCount: Int? = nil
    func recentRecords(limit: Int) async -> HoloDataSourceRead<[HoloConversationRecord]> {
        let values = Array(records.prefix(limit))
        return HoloDataSourceRead(
            value: values,
            status: status == .success && values.isEmpty ? .empty : status,
            requestedCount: limit,
            returnedCount: values.count,
            totalCount: totalCount,
            isTruncated: (totalCount ?? values.count) > values.count,
            warning: status == .unavailable ? "测试读取失败" : nil
        )
    }
}

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloConversationToolTests.main()
    }
}
#endif
struct HoloConversationToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test近期意图摘要只输出元数据()
        try await test当前会话按四小时间隔截断()
        try await test空对话返回empty()
        try await test读取失败不得伪装为空数据()
        try await test证据ID不随排序变化()
        print("HoloConversationToolTests passed")
    }

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func record(
        role: String,
        intent: String?,
        hoursAfterBase: Double
    ) -> HoloConversationRecord {
        HoloConversationRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", Int(hoursAfterBase * 10) + (role == "user" ? 1 : 2)))!,
            role: role,
            intent: intent,
            timestamp: base.addingTimeInterval(hoursAfterBase * 3600)
        )
    }

    private static func request(_ query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "conversation-\(query)", tool: "conversation", query: query,
            timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:]
        )
    }

    private static func metric(_ key: String, in result: HoloDataToolResult) -> Double? {
        result.metrics.first { $0.metricKey == key }?.value
    }

    private static func test近期意图摘要只输出元数据() async throws {
        let source = MockConversationDataSource(records: [
            record(role: "user", intent: "query_analysis", hoursAfterBase: 0),
            record(role: "assistant", intent: "query_analysis", hoursAfterBase: 0.1),
            record(role: "user", intent: "record_expense", hoursAfterBase: 0.2)
        ])
        let result = try await HoloConversationTool(dataSource: source)
            .execute(request("recent_intent_summary"))

        expect(metric("conversation.message.count", in: result) == 3, "消息总数应为 3")
        expect(metric("conversation.user.count", in: result) == 2, "用户消息应为 2")
        expect(metric("conversation.assistant.count", in: result) == 1, "助手消息应为 1")
        expect(result.events.contains { $0.excerpt.contains("query_analysis：2") }, "应统计 intent 次数")
        expect(result.events.allSatisfy { !$0.excerpt.contains("测试消息原文") }, "不得包含历史消息原文")
        expect(result.sensitivity == .sensitive, "对话元数据仍应标记 sensitive")
    }

    private static func test当前会话按四小时间隔截断() async throws {
        let source = MockConversationDataSource(records: [
            record(role: "user", intent: "query", hoursAfterBase: 0),
            record(role: "user", intent: "query_analysis", hoursAfterBase: 10),
            record(role: "assistant", intent: "query_analysis", hoursAfterBase: 10.2)
        ])
        let result = try await HoloConversationTool(dataSource: source)
            .execute(request("session_activity"))

        expect(metric("conversation.session.message_count", in: result) == 2, "4 小时间隔后应只统计最新会话 2 条")
        expect(result.events.count == 1, "会话活动只需一条摘要证据")
    }

    private static func test空对话返回empty() async throws {
        let result = try await HoloConversationTool(
            dataSource: MockConversationDataSource(records: [])
        ).execute(request("recent_intent_summary"))

        expect(result.status == .empty, "空对话应返回 empty")
        expect(result.warnings.contains { $0.code == "NO_CONVERSATION_DATA" }, "应返回明确 warning")
    }

    private static func test读取失败不得伪装为空数据() async throws {
        let result = try await HoloConversationTool(
            dataSource: MockConversationDataSource(records: [], status: .unavailable)
        ).execute(request("recent_intent_summary"))

        expect(result.status == .unavailable, "读取失败必须返回 unavailable")
        expect(result.error?.code == "DATA_SOURCE_UNAVAILABLE", "读取失败应携带可恢复错误")
    }

    private static func test证据ID不随排序变化() async throws {
        let records = [
            record(role: "user", intent: "query_analysis", hoursAfterBase: 0),
            record(role: "assistant", intent: "query_analysis", hoursAfterBase: 0.1)
        ]
        let first = try await HoloConversationTool(dataSource: MockConversationDataSource(records: records))
            .execute(request("recent_intent_summary"))
        let second = try await HoloConversationTool(dataSource: MockConversationDataSource(records: Array(records.reversed())))
            .execute(request("recent_intent_summary"))
        expect(first.events.map(\.id) == second.events.map(\.id), "相同意图的证据 ID 不应受数据源顺序影响")
    }
}
