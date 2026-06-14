//
//  ChatMessageViewDataAgentResultTests.swift
//  HoloTests
//
//  测试 ChatMessageViewData 的 agentResult 编解码
//

import XCTest
@testable import Holo

final class ChatMessageViewDataAgentResultTests: XCTestCase {

    private func sampleResultJSON() -> String {
        """
        {"title":"本期观察","summary":"支出偏高","sections":[{"title":"观察 1","body":"餐饮超预算","confidence":0.8}],"evidenceReferences":[]}
        """
    }

    func testDecodeAgentResult_validJSON() throws {
        let decoded = ChatMessageViewData.decodeAgentResult(sampleResultJSON())
        let result = try XCTUnwrap(decoded)
        XCTAssertEqual(result.title, "本期观察")
        XCTAssertEqual(result.sections.count, 1)
        // confidence 是 Double?，解码为 0.8
        XCTAssertEqual(result.sections[0].confidence, 0.8)
    }

    func testDecodeAgentResult_nilInput() {
        XCTAssertNil(ChatMessageViewData.decodeAgentResult(nil))
    }

    func testDecodeAgentResult_invalidJSON() {
        XCTAssertNil(ChatMessageViewData.decodeAgentResult("not a json"))
    }

    /// 旧 JSON（无 confidence 字段）向后兼容，confidence 解码为 nil
    func testDecodeAgentResult_legacyJSONWithoutConfidence() throws {
        let legacy = #"{"title":"旧","summary":"s","sections":[{"title":"观察 1","body":"b"}],"evidenceReferences":[]}"#
        let result = try XCTUnwrap(ChatMessageViewData.decodeAgentResult(legacy))
        XCTAssertNil(result.sections.first?.confidence, "旧 JSON 无 confidence 应解码为 nil")
    }
}
