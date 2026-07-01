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

    func testAgentDeepAnalysisNarrativeModelUsesFinanceLedgerModeForFinanceEvidence() {
        let range = HoloAgentTimeRange(
            label: "本月",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 2000)
        )
        let drilldown = HoloRenderedFinanceDrilldown(
            sourceEvidenceID: "e1",
            label: "本月",
            keyword: nil,
            start: range.start!,
            end: range.end!,
            baselineStart: nil,
            baselineEnd: nil
        )
        let result = HoloRenderedAgentResult(
            title: "本月账单分析",
            summary: "本月总支出 1.4 万元，交通 5200 元、餐饮 3600 元、购物 2400 元。",
            sections: [
                HoloRenderedAgentSection(title: "钱主要去哪了", body: "交通、餐饮、购物是前三个去向。", confidence: 0.9)
            ],
            evidenceReferences: [
                HoloRenderedEvidenceReference(id: "e1", summary: "本月总支出：14000 元", financeDrilldown: drilldown)
            ]
        )

        let model = AgentDeepAnalysisNarrativeModel(result: result)

        XCTAssertEqual(model.openingTitle, "本月这笔钱，先按账单口径拆开看。")
        XCTAssertEqual(model.signalSummaries, [], "财务账单结果不应再生成三块看不懂的信号标签")
        XCTAssertEqual(model.closingTitle, "先核对最大头的去向。")
        XCTAssertTrue(model.evidence.first?.label.contains("账单依据") == true, "财务证据应叫账单依据")
    }

    func testAgentDeepAnalysisNarrativeModelUsesFinanceRangeLabelInOpeningTitle() {
        let drilldown = HoloRenderedFinanceDrilldown(
            sourceEvidenceID: "e1",
            label: "上月",
            keyword: nil,
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 2000),
            baselineStart: nil,
            baselineEnd: nil
        )
        let result = HoloRenderedAgentResult(
            title: "深度分析",
            summary: "上月账单总支出约 14599 元。",
            sections: [
                HoloRenderedAgentSection(title: "账单总览", body: "上月账单总支出约 14599 元。", confidence: 0.45)
            ],
            evidenceReferences: [
                HoloRenderedEvidenceReference(id: "e1", summary: "上月总支出：14599 元", financeDrilldown: drilldown)
            ]
        )

        let model = AgentDeepAnalysisNarrativeModel(result: result)

        XCTAssertEqual(model.openingTitle, "上月这笔钱，先按账单口径拆开看。")
        XCTAssertFalse(model.openingBody.contains("finance.total.amount"), "详情页不能暴露内部 metricKey")
    }

    func testAgentDeepAnalysisNarrativeModelKeepsMoneyTokenUnbroken() {
        let result = HoloRenderedAgentResult(
            title: "本月账单分析",
            summary: "记账显示本月总支出约 4981.83 元，与您提到的 1.4 万相差约 9000 元。",
            sections: [],
            evidenceReferences: []
        )

        let model = AgentDeepAnalysisNarrativeModel(result: result)
        let actual = model.openingParagraphs.joined()
        let readable = actual
            .replacingOccurrences(of: "\u{2060}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        XCTAssertTrue(
            readable.contains("4981.83 元"),
            "金额保护不能改变用户可读的小数点，实际：\(actual)"
        )
        XCTAssertTrue(
            actual.contains("\u{00A0}元"),
            "金额和单位之间应使用不可断开的空格，避免窄屏换行误读，实际：\(actual)"
        )
        XCTAssertFalse(
            actual.contains("4981\u{2060}83"),
            "金额不能丢失小数点后变成 498183，实际：\(actual)"
        )
    }
}
