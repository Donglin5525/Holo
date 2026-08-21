//
//  HoloAgentTimeSemanticsTests.swift
//  HoloTests
//
//  Agent 时间语义改造（2026-08-21）：L2 通用组合规则 / L3 模型窗口护栏 / 披露分型 的回归测试。
//

import XCTest
@testable import Holo

final class HoloAgentTimeSemanticsTests: XCTestCase {

    // 固定时区与参考日，保证窗口断言确定
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private let reference = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 12))!
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - L2 通用组合规则

    func testRelativeSpanHalfYear() {
        let scope = HoloAgentTimeSemanticResolver.resolve("近半年我的工资收入趋势是什么", referenceDate: reference, calendar: calendar)
        XCTAssertEqual(scope?.kind, .relativeSpan)
        XCTAssertEqual(scope?.matchedText, "近半年")
        XCTAssertEqual(scope?.timeRange.start, date(2026, 2, 22))
        XCTAssertEqual(scope?.timeRange.end, date(2026, 8, 22))
    }

    func testRelativeSpanVariants() {
        // 注：normalizeChineseYearAndMonth 会把「三月→3月」「一年→1年」归一，
        // matchedText 因此是归一后的文本（窗口语义不受影响）。
        let cases: [(String, String, Date, Date)] = [
            ("近3个月的支出", "近3个月", date(2026, 5, 22), date(2026, 8, 22)),
            ("近三个月睡眠怎么样", "近三个月", date(2026, 5, 22), date(2026, 8, 22)),
            ("最近半年习惯完成率", "最近半年", date(2026, 2, 22), date(2026, 8, 22)),
            ("过去半年的开销", "过去半年", date(2026, 2, 22), date(2026, 8, 22)),
            ("近一年任务完成率", "近1年", date(2025, 8, 22), date(2026, 8, 22)),
            ("近2周步数趋势", "近2周", date(2026, 8, 8), date(2026, 8, 22))
        ]
        for (question, matched, start, end) in cases {
            let scope = HoloAgentTimeSemanticResolver.resolve(question, referenceDate: reference, calendar: calendar)
            XCTAssertEqual(scope?.kind, .relativeSpan, question)
            XCTAssertEqual(scope?.matchedText, matched, question)
            XCTAssertEqual(scope?.timeRange.start, start, question)
            XCTAssertEqual(scope?.timeRange.end, end, question)
        }
    }

    /// L1 词表优先级不回归：这些问法仍由词表接管，不落入通用族
    func testLexicalPriorityUnchanged() {
        XCTAssertEqual(
            HoloAgentTimeSemanticResolver.resolve("最近30天花了多少", referenceDate: reference, calendar: calendar)?.kind,
            .recentDays
        )
        XCTAssertEqual(
            HoloAgentTimeSemanticResolver.resolve("本月支出多少", referenceDate: reference, calendar: calendar)?.kind,
            .currentMonth
        )
        XCTAssertEqual(
            HoloAgentTimeSemanticResolver.resolve("2026年7月的工资", referenceDate: reference, calendar: calendar)?.kind,
            .explicitMonth
        )
    }

    /// 「近3月」带相对前缀时按近三个月解析，不被 explicitMonth 误读成今年3月
    func testRelativePrefixBeatsExplicitMonth() {
        let scope = HoloAgentTimeSemanticResolver.resolve("近3月体重趋势", referenceDate: reference, calendar: calendar)
        XCTAssertEqual(scope?.kind, .relativeSpan)
        XCTAssertEqual(scope?.matchedText, "近3月")
    }

    /// 无时间语义的问法仍返回 nil（走 L3 模型兜底或默认窗口 + 披露）
    func testNoTimeExpressionStillNil() {
        XCTAssertNil(HoloAgentTimeSemanticResolver.resolve("我的工资收入趋势是什么", referenceDate: reference, calendar: calendar))
    }

    // MARK: - L3 模型窗口护栏

    private func modelRange(start: Date, end: Date, label: String = "近半年(3月22日-8月21日)") -> HoloAgentTimeRange {
        HoloAgentTimeRange(label: label, start: start, end: end)
    }

    func testPolicyAcceptsValidModelRange() {
        let range = modelRange(start: date(2026, 2, 22), end: date(2026, 8, 22))
        XCTAssertTrue(HoloAgentModelTimeRangePolicy.validate(range, asOf: reference, calendar: calendar))
    }

    func testPolicyRejectsInvertedRange() {
        let range = modelRange(start: date(2026, 8, 22), end: date(2026, 2, 22))
        XCTAssertFalse(HoloAgentModelTimeRangePolicy.validate(range, asOf: reference, calendar: calendar))
    }

    func testPolicyRejectsOversizedSpan() {
        let range = modelRange(start: date(2024, 1, 1), end: date(2026, 8, 21))
        XCTAssertFalse(HoloAgentModelTimeRangePolicy.validate(range, asOf: reference, calendar: calendar))
    }

    func testPolicyRejectsFutureEnd() {
        let range = modelRange(start: date(2026, 8, 1), end: date(2026, 9, 15))
        XCTAssertFalse(HoloAgentModelTimeRangePolicy.validate(range, asOf: reference, calendar: calendar))
    }

    func testPolicyRejectsEmptyLabel() {
        let range = modelRange(start: date(2026, 2, 22), end: date(2026, 8, 22), label: "  ")
        XCTAssertFalse(HoloAgentModelTimeRangePolicy.validate(range, asOf: reference, calendar: calendar))
    }

    func testFirstValidRangePrefersFirstLegalWindow() {
        let illegal = HoloToolRequest(
            id: "r1", tool: "finance", query: "工资",
            timeRange: modelRange(start: date(2026, 8, 1), end: date(2026, 8, 1)),
            baseline: nil, requiredMetrics: [], parameters: [:]
        )
        let legal = HoloToolRequest(
            id: "r2", tool: "finance", query: "工资",
            timeRange: modelRange(start: date(2026, 2, 22), end: date(2026, 8, 22)),
            baseline: nil, requiredMetrics: [], parameters: [:]
        )
        let picked = HoloAgentModelTimeRangePolicy.firstValidRange(in: [illegal, legal], asOf: reference, calendar: calendar)
        XCTAssertEqual(picked?.start, date(2026, 2, 22))
    }

    // MARK: - 披露分型

    func testDisplayLabelRuleShowsDateSpan() {
        let scope = HoloRenderedAnswerScope(
            label: "近半年",
            start: date(2026, 2, 22),
            end: date(2026, 8, 22),
            snapshotCutoffAt: date(2026, 8, 21),
            attribution: HoloAgentTimeRangeAttribution(provenance: .rule, matchedText: "近半年")
        )
        XCTAssertEqual(scope.displayLabel, "近半年（2月22日–8月22日） · 截至8月21日")
    }

    func testDisplayLabelLexicalKeepsLegacyFormat() {
        let scope = HoloRenderedAnswerScope(
            label: "本月",
            start: date(2026, 8, 1),
            end: date(2026, 8, 31),
            snapshotCutoffAt: date(2026, 8, 21),
            attribution: HoloAgentTimeRangeAttribution(provenance: .lexical, matchedText: "本月")
        )
        XCTAssertEqual(scope.displayLabel, "本月 · 截至8月21日")
    }

    func testDisplayLabelUnspecifiedDisclosesDefaultWindow() {
        let scope = HoloRenderedAnswerScope(
            label: "本期",
            start: date(2026, 7, 23),
            end: date(2026, 8, 22),
            snapshotCutoffAt: date(2026, 8, 21),
            attribution: HoloAgentTimeRangeAttribution(provenance: .unspecified, matchedText: nil)
        )
        XCTAssertEqual(scope.displayLabel, "默认范围（7月23日–8月22日） · 截至8月21日 · 未指定时间，按默认范围")
    }

    // MARK: - 换范围档位

    func testScopeChangePresetWindows() {
        XCTAssertEqual(AgentScopeChangePreset.last30Days.timeRange(asOf: reference, calendar: calendar).start, date(2026, 7, 23))
        XCTAssertEqual(AgentScopeChangePreset.last3Months.timeRange(asOf: reference, calendar: calendar).start, date(2026, 5, 22))
        XCTAssertEqual(AgentScopeChangePreset.last6Months.timeRange(asOf: reference, calendar: calendar).start, date(2026, 2, 22))
        XCTAssertEqual(AgentScopeChangePreset.last1Year.timeRange(asOf: reference, calendar: calendar).start, date(2025, 8, 22))
        for preset in AgentScopeChangePreset.allCases {
            XCTAssertEqual(preset.timeRange(asOf: reference, calendar: calendar).end, date(2026, 8, 22), preset.label)
        }
    }

    /// 换范围话术必须能被 FollowUpRouter 识别为 .changeScope（链路不脱锚）
    func testScopeChangeFollowUpTextClassified() {
        let parent = HoloAgentFollowUpParentContext(parentDomains: ["finance"], hasRecommendations: false)
        for preset in AgentScopeChangePreset.allCases {
            let relation = HoloAgentFollowUpRouter.classify(followUpText: preset.followUpText, parent: parent)
            XCTAssertEqual(relation, .changeScope, preset.followUpText)
        }
    }

    /// Draft → Request 只在 changeScope 关系透传 override 窗口
    func testContinuationRequestCarriesOverrideOnlyForChangeScope() {
        let draft = HoloAgentContinuationDraft(
            parentJobID: "job", parentResultID: "result", rootUserQuestion: "q",
            parentDomains: [], parentRecommendations: [],
            relation: .changeScope,
            overrideTimeRange: AgentScopeChangePreset.last6Months.timeRange(asOf: reference, calendar: calendar)
        )
        XCTAssertNotNil(draft.request.overrideTimeRange)

        var explainDraft = draft
        explainDraft.relation = .explain
        XCTAssertNil(explainDraft.request.overrideTimeRange)
    }
}
