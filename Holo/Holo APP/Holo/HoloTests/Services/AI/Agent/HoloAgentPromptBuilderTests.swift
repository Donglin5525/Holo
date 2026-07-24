//
//  HoloAgentPromptBuilderTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 3.4 Prompt Builder 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/HoloAgentPromptBuilder.swift> <本测试> \
//    -o /tmp/holo_agent_prompt_test && /tmp/holo_agent_prompt_test
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        HoloAgentPromptBuilderTests.main()
    }
}
#endif
struct HoloAgentPromptBuilderTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test包含工具描述()
        test包含脱敏证据()
        test不包含完整敏感原文()
        test包含会话状态()
        print("HoloAgentPromptBuilderTests passed")
    }

    private static func makeEvidence(redacted: String, excerpt: String) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: "e1", dedupeKey: "k", sourceModule: .habit, sourceID: nil, sourceKind: "kind",
            timeRange: nil, occurredAt: nil, metricKey: "m", metricValue: 1, unit: "次",
            baselineValue: nil, comparison: nil, excerpt: excerpt, redactedExcerpt: redacted,
            sensitivity: .sensitive, confidence: 1.0, status: .active,
            generatedBy: "test", generatedAt: Date(timeIntervalSince1970: 1000),
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
    }

    private static func combined(_ messages: [HoloAgentMessage]) -> String {
        messages.map { $0.content }.joined(separator: "\n")
    }

    private static func test包含工具描述() {
        let messages = HoloAgentPromptBuilder.build(
            systemTemplate: "你是 Agent", toolDescriptions: "【habit】习惯数据分析工具",
            evidence: [], conversationState: [], userQuestion: "最近习惯怎么样"
        )
        expect(combined(messages).contains("习惯数据分析工具"), "应包含工具描述")
    }

    private static func test包含脱敏证据() {
        let messages = HoloAgentPromptBuilder.build(
            systemTemplate: "你是 Agent", toolDescriptions: "",
            evidence: [makeEvidence(redacted: "脱敏摘要_开心就好", excerpt: "完整敏感原文")],
            conversationState: [], userQuestion: "q"
        )
        expect(combined(messages).contains("脱敏摘要_开心就好"), "应包含脱敏证据 redactedExcerpt")
    }

    private static func test不包含完整敏感原文() {
        let messages = HoloAgentPromptBuilder.build(
            systemTemplate: "你是 Agent", toolDescriptions: "",
            evidence: [makeEvidence(redacted: "脱敏", excerpt: "SECRET_FULL_TEXT_999")],
            conversationState: [], userQuestion: "q"
        )
        expect(!combined(messages).contains("SECRET_FULL_TEXT_999"), "不应包含完整敏感原文 excerpt")
    }

    private static func test包含会话状态() {
        let conversation = [
            HoloAgentMessage(role: .assistant, content: "CONVERSATION_MARKER_42",
                             toolRequestID: nil, toolName: nil,
                             timestamp: Date(timeIntervalSince1970: 1), tokenEstimate: nil)
        ]
        let messages = HoloAgentPromptBuilder.build(
            systemTemplate: "你是 Agent", toolDescriptions: "",
            evidence: [], conversationState: conversation, userQuestion: "q"
        )
        expect(combined(messages).contains("CONVERSATION_MARKER_42"), "应包含会话状态")
    }
}
