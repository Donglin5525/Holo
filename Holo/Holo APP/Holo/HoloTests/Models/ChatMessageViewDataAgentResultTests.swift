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

    func testDecodeAgentResult_legacyJSONWithoutAnswerContract() throws {
        let legacy = #"{"title":"旧","summary":"s","sections":[],"evidenceReferences":[]}"#
        let result = try XCTUnwrap(ChatMessageViewData.decodeAgentResult(legacy))

        XCTAssertNil(result.question)
        XCTAssertNil(result.headline)
        XCTAssertNil(result.directAnswer)
        XCTAssertNil(result.coverageText)
        XCTAssertNil(result.limitations)
    }

    func testDecodeAgentResult_newAnswerContract() throws {
        let json = #"{"title":"深度分析","summary":"日均 6991 步","sections":[],"evidenceReferences":[],"question":"最近一个月平均步数是多少？","headline":"最近一个月的步数","directAnswer":"最近一个月，日均 6,991 步","coverageText":"最近 30 天中有 28/30 天有效记录","limitations":[]}"#
        let result = try XCTUnwrap(ChatMessageViewData.decodeAgentResult(json))

        XCTAssertEqual(result.headline, "最近一个月的步数")
        XCTAssertEqual(result.directAnswer, "最近一个月，日均 6,991 步")
        XCTAssertEqual(result.coverageText, "最近 30 天中有 28/30 天有效记录")
        XCTAssertEqual(result.limitations, [])
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
        XCTAssertEqual(model.observations.map(\.label), ["", ""])
        XCTAssertEqual(model.observations[1].title, "值得留意的变化")
        XCTAssertEqual(model.observations[1].body, "戒烟习惯在 6 月 27 日出现明显反复。")
    }

    func testAgentDeepAnalysisNarrativeModelUsesAnswerContractWithoutObservationNumbers() {
        let result = HoloRenderedAgentResult(
            title: "深度分析",
            summary: "最近一个月，日均 6,991 步",
            sections: [
                HoloRenderedAgentSection(title: "平均步数", body: "最近一个月，日均 6,991 步", confidence: 0.9),
                HoloRenderedAgentSection(title: "达标情况", body: "有 1 天达到 10,000 步", confidence: 0.9)
            ],
            evidenceReferences: [],
            question: "最近一个月平均步数是多少？",
            headline: "最近一个月的步数",
            directAnswer: "最近一个月，日均 6,991 步",
            coverageText: "最近 30 天中有 28/30 天有效记录",
            limitations: []
        )

        let model = AgentDeepAnalysisNarrativeModel(result: result)

        XCTAssertEqual(model.openingTitle, "最近一个月的步数")
        XCTAssertEqual(model.openingBody, "最近一个月，日均 6,991 步")
        XCTAssertEqual(model.openingParagraphs, ["最近一个月，日均 6,991 步"])
        XCTAssertEqual(model.coverageText, "最近 30 天中有 28/30 天有效记录")
        XCTAssertFalse(model.observations.contains { $0.label.contains("观察") })
        XCTAssertFalse(model.observations.contains { $0.body == model.openingBody })
        XCTAssertEqual(model.observations.map(\.title), ["达标情况"])
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
        XCTAssertTrue(model.observations.isEmpty)
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

        XCTAssertEqual(model.openingTitle, "本月账单结果")
        XCTAssertEqual(model.signalSummaries, [], "财务账单结果不应再生成三块看不懂的信号标签")
        XCTAssertEqual(model.closingTitle, "从金额最高的分类开始核对。")
        XCTAssertFalse(model.shouldShowClosing, "账单查询不应强行展示下一步建议")
        XCTAssertTrue(model.evidence.first?.label.contains("账单依据") == true, "财务证据应叫账单依据")
    }

    func testHealthNarrativeUsesHealthModeAndNoGenericNextStep() {
        let result = HoloRenderedAgentResult(
            title: "深度分析",
            summary: "最近平均睡眠 6.5 小时，有效记录 7 晚。当前只能评估睡眠时长，不能完整判断睡眠质量。",
            sections: [HoloRenderedAgentSection(title: "观察 1", body: "最近平均睡眠 6.5 小时。", confidence: 0.8)],
            evidenceReferences: [HoloRenderedEvidenceReference(id: "h1", summary: "睡眠汇总：平均 6.5 小时", financeDrilldown: nil, sourceModule: .health)]
        )

        let model = AgentDeepAnalysisNarrativeModel(result: result)
        XCTAssertTrue(model.isHealthMode)
        XCTAssertEqual(model.openingTitle, "本期的健康数据")
        XCTAssertEqual(model.signalSummaries, [])
        XCTAssertFalse(model.shouldShowClosing, "健康查询不应展示通用下一步")
        XCTAssertFalse(model.openingTitle.contains("信号值得回看"))
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

        XCTAssertEqual(model.openingTitle, "上月账单结果")
        XCTAssertFalse(model.openingBody.contains("finance.total.amount"), "详情页不能暴露内部 metricKey")
    }

    func testMerchantAverageQueryAnswersEveryRequestedMetric() throws {
        let result = makeMerchantAverageResult()

        let answer = FlexibleQueryAnswerBuilder().answer(result)
        let readable = answer
            .replacingOccurrences(of: "\u{2060}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        XCTAssertTrue(readable.contains("麦当劳"))
        XCTAssertTrue(readable.contains("5 顿"))
        XCTAssertTrue(readable.contains("239.00"))
        XCTAssertTrue(readable.contains("平均每顿"))
        XCTAssertTrue(readable.contains("47.80"))

        let card = try XCTUnwrap(ChatCardData.fromFlexibleQueryResult(result))
        guard case .flexibleQuery(let data) = card else {
            return XCTFail("Expected flexible query card")
        }
        XCTAssertEqual(data.resultCountText, "5 顿")
        XCTAssertEqual(data.averageLabelText, "平均每顿")
        XCTAssertTrue(data.averageAmountText?.contains("47.80") == true)
    }

    func testMerchantAggregateResolverBuildsDeterministicMealPlan() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 9,
            hour: 12
        )))

        let plan = try XCTUnwrap(MerchantAggregatePlanResolver.resolve(
            userQuestion: "最近一个月吃了多少吨麦当劳，花了多少钱，平均一顿多少钱",
            extractedData: [
                "queryGoal": "最近一个月麦当劳的消费次数、总花费和平均每顿花费",
                "categoryCandidate": "麦当劳",
                "periodLabel": "最近一个月"
            ],
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(plan.operation, .sumAmount)
        XCTAssertEqual(plan.calculation, .averageAmount)
        XCTAssertEqual(plan.averageUnit, .meal)
        XCTAssertEqual(plan.filters.type, .expense)
        XCTAssertEqual(plan.filters.keywords, ["麦当劳"])
        XCTAssertEqual(plan.filters.startDate, "2026-06-10")
        XCTAssertEqual(plan.filters.endDate, "2026-07-09")
    }

    func testMerchantAggregateResolverRejectsMissingMerchant() {
        XCTAssertNil(MerchantAggregatePlanResolver.resolve(
            userQuestion: "最近一个月吃了多少顿，花了多少钱，平均一顿多少钱",
            extractedData: [
                "queryGoal": "最近一个月的消费次数、总花费和平均每顿花费",
                "periodLabel": "最近一个月"
            ]
        ))
    }

    func testMerchantAggregateResolverRejectsTrendAnalysis() {
        XCTAssertNil(MerchantAggregatePlanResolver.resolve(
            userQuestion: "最近一个月麦当劳消费趋势怎么样",
            extractedData: [
                "queryGoal": "分析麦当劳消费趋势",
                "categoryHint": "麦当劳",
                "periodLabel": "最近一个月"
            ]
        ))
    }

    func testKeywordFinanceNarrativeAvoidsGenericObservationAndUnrelatedNextStep() {
        let range = HoloAgentTimeRange(
            label: "近30天",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 2000)
        )
        let drilldown = HoloRenderedFinanceDrilldown(
            sourceEvidenceID: "e1",
            label: "近30天",
            keyword: "麦当劳",
            start: range.start!,
            end: range.end!,
            baselineStart: nil,
            baselineEnd: nil
        )
        let result = HoloRenderedAgentResult(
            title: "深度分析",
            summary: "近30天麦当劳 5 次，共 239 元，平均每顿 47.80 元。",
            sections: [
                HoloRenderedAgentSection(
                    title: "观察 1",
                    body: "近30天麦当劳 5 次，共 239 元，平均每顿 47.80 元。",
                    confidence: 1
                )
            ],
            evidenceReferences: [
                HoloRenderedEvidenceReference(
                    id: "e1",
                    summary: "麦当劳 5 次 / 239 元",
                    financeDrilldown: drilldown
                )
            ]
        )

        let model = AgentDeepAnalysisNarrativeModel(result: result)

        XCTAssertEqual(model.openingTitle, "近30天「麦当劳」消费结果")
        XCTAssertTrue(model.observations.isEmpty, "与直接回答重复的观察不应再次展示")
        XCTAssertFalse(model.shouldShowClosing)
        XCTAssertFalse(model.closingTitle.contains("最大头"))
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

    private func makeMerchantAverageResult() -> FlexibleQueryResult {
        let plan = FlexibleQueryPlan(
            domain: .finance,
            operation: .sumAmount,
            filters: FinanceQueryFilters(
                type: .expense,
                amountGreaterThan: nil,
                amountGreaterThanOrEqual: nil,
                amountLessThan: nil,
                amountLessThanOrEqual: nil,
                amountEqual: nil,
                keywords: ["麦当劳"],
                excludedKeywords: [],
                categoryNames: [],
                startDate: "2026-06-10",
                endDate: "2026-07-09",
                accountNames: [],
                includeNote: true,
                includeRemark: true,
                includeTags: true,
                includeCategory: true
            ),
            calculation: .averageAmount,
            averageUnit: .meal,
            sort: nil,
            limit: 20,
            explanationHints: []
        )
        let amounts: [Decimal] = [42, 43, 57, 48, 49]
        let transactions = amounts.enumerated().map { index, amount in
            FlexibleTransactionEvidence(
                id: UUID().uuidString,
                date: "2026-07-0\(index + 1)",
                amount: amount,
                type: "expense",
                note: "麦当劳",
                remark: nil,
                tags: [],
                primaryCategory: "餐饮",
                subCategory: "快餐",
                matchedFields: ["note"],
                matchReason: "关键词匹配"
            )
        }
        return FlexibleQueryResult(
            plan: plan,
            status: .success,
            summary: FlexibleQuerySummary(
                totalMatched: 5,
                totalAmount: 239,
                dateRange: "2026-06-10 ~ 2026-07-09",
                topCategory: "餐饮"
            ),
            matchedTransactions: transactions,
            calculationResult: FlexibleCalculationResult(
                type: .averageAmount,
                valueText: "平均 ¥47.80",
                days: nil,
                amount: Decimal(string: "47.8"),
                count: nil,
                date: nil
            ),
            emptyReason: nil,
            followUpSuggestion: nil
        )
    }
}
