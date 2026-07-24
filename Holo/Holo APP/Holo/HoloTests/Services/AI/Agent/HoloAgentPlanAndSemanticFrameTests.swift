//
//  HoloAgentPlanAndSemanticFrameTests.swift
//  HoloTests
//
//  Agent 成熟度演进 P0-B — Semantic Frame / Plan / Clarification 测试
//

import Foundation

@main
struct HoloAgentPlanAndSemanticFrameTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        testSemanticFrame_简单查数_FastPath()
        testSemanticFrame_比较分析()
        testSemanticFrame_跨域分析()
        testSemanticFrame_敏感分析()
        testSemanticFrame_高影响歧义需澄清()
        testSemanticFrame_低影响歧义用默认()
        testTimeExtended_季度解析()
        testTimeExtended_年初至今()
        testTimeExtended_月至今标注Partial()
        testPlanCoverage_全部覆盖()
        testPlanCoverage_部分缺失()
        testPlanCoverage_需澄清()
        testClarificationPolicy_构建请求()
        testPlan_子问题状态流转()
        print("HoloAgentPlanAndSemanticFrameTests passed")
    }

    // MARK: - 固定参考日期

    private static var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "zh_CN")
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    private static let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!
    }()

    // MARK: - Semantic Frame

    private static func testSemanticFrame_简单查数_FastPath() {
        let frame = HoloAgentSemanticFrameBuilder.buildFrame(
            query: "本月消费多少", referenceDate: referenceDate, calendar: calendar
        )
        expect(frame.profile == .simpleLookup || frame.profile == .singleDomainAnalysis, "简单查数应走 fast path 或单域分析，实际 \(frame.profile)")
        expect(frame.domains.contains("finance"), "应识别 finance 域")
        expect(!frame.profile.requiresFormalPlan || frame.profile == .singleDomainAnalysis, "简单查数不需要正式 plan")
    }

    private static func testSemanticFrame_比较分析() {
        let frame = HoloAgentSemanticFrameBuilder.buildFrame(
            query: "本月比上个月消费多在哪", referenceDate: referenceDate, calendar: calendar
        )
        expect(frame.resolvedComparison != nil, "应解析出对比双窗")
        expect(frame.profile == .comparisonAnalysis || frame.profile == .singleDomainAnalysis, "应识别为比较分析")
    }

    private static func testSemanticFrame_跨域分析() {
        let frame = HoloAgentSemanticFrameBuilder.buildFrame(
            query: "消费和任务完成情况怎么样", referenceDate: referenceDate, calendar: calendar
        )
        expect(frame.domains.count >= 2, "应识别多域，实际 \(frame.domains)")
        expect(frame.profile == .crossDomainAnalysis, "应识别为跨域分析，实际 \(frame.profile)")
    }

    private static func testSemanticFrame_敏感分析() {
        let frame = HoloAgentSemanticFrameBuilder.buildFrame(
            query: "睡眠不足是不是焦虑了", referenceDate: referenceDate, calendar: calendar
        )
        expect(frame.sensitivity == .mentalHealth, "应识别为心理敏感")
        expect(frame.profile == .sensitiveAnalysis, "应识别为敏感分析")
    }

    private static func testSemanticFrame_高影响歧义需澄清() {
        let frame = HoloAgentSemanticFrameBuilder.buildFrame(
            query: "帮我看看", referenceDate: referenceDate, calendar: calendar
        )
        let highImpact = frame.ambiguities.filter { $0.impact == .high }
        expect(!highImpact.isEmpty, "模糊查询应产生高影响歧义")
        let clarifiable = HoloAgentClarificationPolicy.clarifiableAmbiguity(from: frame.ambiguities)
        expect(clarifiable != nil, "高影响歧义应触发澄清")
    }

    private static func testSemanticFrame_低影响歧义用默认() {
        let frame = HoloAgentSemanticFrameBuilder.buildFrame(
            query: "最近的消费趋势", referenceDate: referenceDate, calendar: calendar
        )
        let lowImpact = frame.ambiguities.filter { $0.impact == .low }
        if !lowImpact.isEmpty {
            expect(lowImpact.first?.defaultAssumption != nil, "低影响歧义应有默认假设")
        }
    }

    // MARK: - Time Extended

    private static func testTimeExtended_季度解析() {
        let result = HoloAgentTimeSemanticExtended.resolveExtended(
            "一季度的情况", referenceDate: referenceDate, calendar: calendar
        )
        expect(result != nil, "应解析季度")
        expect(result?.extendedKind == .quarter, "应为 quarter kind")
        expect(result?.assumption.completeness == .complete, "2026年7月看Q1应为完整周期")
    }

    private static func testTimeExtended_年初至今() {
        let result = HoloAgentTimeSemanticExtended.resolveExtended(
            "今年以来怎么样", referenceDate: referenceDate, calendar: calendar
        )
        expect(result != nil, "应解析年初至今")
        expect(result?.extendedKind == .yearToDate, "应为 yearToDate kind")
        expect(result?.assumption.isIncompletePeriod == true, "应为不完整周期")
    }

    private static func testTimeExtended_月至今标注Partial() {
        let result = HoloAgentTimeSemanticExtended.resolveExtended(
            "本月到现在", referenceDate: referenceDate, calendar: calendar
        )
        expect(result != nil, "应解析月至今")
        expect(result?.extendedKind == .monthToDate, "应为 monthToDate kind")
        expect(result?.assumption.completeness == .partial, "应标注 partial")
    }

    // MARK: - Plan Coverage

    private static func testPlanCoverage_全部覆盖() {
        let plan = HoloAgentPlan(
            objective: "分析本月消费",
            subQuestions: [
                HoloAgentSubQuestion(id: "sq1", question: "总额", relatedMetricKeys: ["finance.total"]),
                HoloAgentSubQuestion(id: "sq2", question: "明细", relatedMetricKeys: ["finance.breakdown"]),
            ],
            requirements: [
                HoloAgentMetricRequirement(id: "r1", metricKey: "finance.total"),
                HoloAgentMetricRequirement(id: "r2", metricKey: "finance.breakdown"),
            ]
        )
        let coverage = HoloAgentCoverageChecker.check(
            plan: plan,
            answeredSubQuestions: ["sq1": .answered, "sq2": .answered],
            availableMetricKeys: ["finance.total", "finance.breakdown"]
        )
        expect(coverage.overallStatus == .complete, "应判定为 complete，实际 \(coverage.overallStatus)")
        expect(coverage.missingMetricKeys.isEmpty, "不应有缺失")
    }

    private static func testPlanCoverage_部分缺失() {
        let plan = HoloAgentPlan(
            objective: "分析消费和睡眠",
            requirements: [
                HoloAgentMetricRequirement(id: "r1", metricKey: "finance.total"),
                HoloAgentMetricRequirement(id: "r2", metricKey: "health.sleep"),
            ]
        )
        let coverage = HoloAgentCoverageChecker.check(
            plan: plan,
            answeredSubQuestions: [:],
            availableMetricKeys: ["finance.total"]
        )
        expect(coverage.overallStatus == .missing, "应判定为 missing，实际 \(coverage.overallStatus)")
        expect(coverage.missingMetricKeys.contains("health.sleep"), "应缺失 health.sleep")
    }

    private static func testPlanCoverage_需澄清() {
        let plan = HoloAgentPlan(
            objective: "分析",
            subQuestions: [HoloAgentSubQuestion(id: "sq1", question: "?")],
            requirements: [HoloAgentMetricRequirement(id: "r1", metricKey: "finance.total")]
        )
        let coverage = HoloAgentCoverageChecker.check(
            plan: plan,
            answeredSubQuestions: ["sq1": .clarificationNeeded],
            availableMetricKeys: ["finance.total"]
        )
        expect(coverage.overallStatus == .needsClarification, "应判定为 needsClarification")
    }

    // MARK: - Clarification

    private static func testClarificationPolicy_构建请求() {
        let ambiguity = HoloAgentAmbiguity(
            id: "test-ambig",
            description: "测试歧义",
            impact: .high,
            candidates: ["选项A", "选项B"]
        )
        let request = HoloAgentClarificationPolicy.buildRequest(
            from: ambiguity, originalQuery: "原始问题", originalPlan: nil
        )
        expect(request.options == ["选项A", "选项B"], "应保留候选选项")
        expect(request.originalQuery == "原始问题", "应保存原始查询")
        expect(request.ambiguityID == "test-ambig", "应关联歧义 ID")
    }

    // MARK: - Plan 状态流转

    private static func testPlan_子问题状态流转() {
        var sq = HoloAgentSubQuestion(id: "sq1", question: "?")
        expect(sq.status == .pending, "初始应为 pending")
        sq.status = .answered
        expect(sq.status == .answered, "流转后应为 answered")
    }
}
