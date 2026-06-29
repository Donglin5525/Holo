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

    func testLightweightQueryAnalysisWithAgentResultIsLoadedWithoutRawLogOrExecutionBatch() throws {
        let message = ChatMessageViewData(lightweightDictionary: [
            "id": UUID(),
            "role": "assistant",
            "content": "本期观察",
            "timestamp": Date(),
            "intent": AIIntent.queryAnalysis.rawValue,
            "extractedDataJSON": "",
            "isStreaming": false,
            "parentMessageId": UUID(),
            "agentResultJSON": sampleResultJSON()
        ])

        XCTAssertEqual(message?.metadataState, .loaded)
        XCTAssertNotNil(message?.agentResult)
    }

    func testAgentDeepAnalysisNarrativeModelBuildsReadableChapters() {
        let result = HoloRenderedAgentResult(
            title: "深度分析",
            summary: "近两周睡眠时长波动明显，戒烟习惯出现反复，消费金额明显下降。",
            sections: [
                HoloRenderedAgentSection(title: "观察 1", body: "睡眠时长波动明显，有两天不足 6 小时。", confidence: 0.82),
                HoloRenderedAgentSection(title: "", body: "戒烟习惯在 6 月 27 日出现明显反复。", confidence: 0.74)
            ],
            evidenceReferences: []
        )

        let model = AgentDeepAnalysisNarrativeModel(result: result)

        XCTAssertEqual(model.openingTitle, "这段时间，有几个信号值得回看。")
        XCTAssertEqual(model.openingBody, result.summary)
        XCTAssertEqual(model.openingParagraphs, ["近两周睡眠时长波动明显", "戒烟习惯出现反复", "消费金额明显下降"])
        XCTAssertEqual(model.signalSummaries, ["睡眠时长波动明显", "戒烟习惯出现反复", "消费金额明显下降"])
        XCTAssertEqual(model.observations.map(\.label), ["观察 01", "观察 02"])
        XCTAssertEqual(model.observations[1].title, "值得留意的变化")
        XCTAssertEqual(model.observations[1].body, "戒烟习惯在 6 月 27 日出现明显反复。")
    }

    func testAgentDeepAnalysisNarrativeModelSplitsLongSummaryIntoReadableParagraphs() {
        let result = HoloRenderedAgentResult(
            title: "深度分析",
            summary: "近两周睡眠时长波动明显；戒烟习惯在 6 月 27 日出现明显反复；近期消费金额明显下降，可能反映消费行为或需求的调整；今天待办任务已完成，任务方面压力较小。",
            sections: [
                HoloRenderedAgentSection(title: "观察 1", body: "睡眠时长波动明显。", confidence: 0.82)
            ],
            evidenceReferences: []
        )

        let model = AgentDeepAnalysisNarrativeModel(result: result)

        XCTAssertEqual(model.openingParagraphs.count, 4)
        XCTAssertEqual(model.openingParagraphs[0], "近两周睡眠时长波动明显")
        XCTAssertEqual(model.openingParagraphs[3], "今天待办任务已完成，任务方面压力较小")
    }

    func testAgentDeepAnalysisNarrativeModelFallsBackForEmptyResult() {
        let result = HoloRenderedAgentResult(
            title: "",
            summary: "",
            sections: [],
            evidenceReferences: []
        )

        let model = AgentDeepAnalysisNarrativeModel(result: result)

        XCTAssertEqual(model.openingBody, "本期暂无显著观察")
        XCTAssertEqual(model.signalSummaries, ["暂无显著观察"])
        XCTAssertEqual(model.observations.count, 1)
        XCTAssertEqual(model.observations[0].label, "观察 01")
        XCTAssertEqual(model.observations[0].title, "本期暂无显著观察")
    }
}
