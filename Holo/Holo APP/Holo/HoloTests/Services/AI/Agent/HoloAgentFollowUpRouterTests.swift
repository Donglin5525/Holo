//
//  HoloAgentFollowUpRouterTests.swift
//  HoloTests
//
//  连续追问 Phase 3：FollowUpRouter 确定性关系判定验证。
//  运行：swiftc -parse-as-library <源码> <本测试> -o /tmp/holo_router_tests && /tmp/holo_router_tests
//

import Foundation

@main
struct HoloAgentFollowUpRouterTests {

    static func expect(_ c: @autoclosure () -> Bool, _ m: String) { if !c() { fatalError(m) } }

    static func main() {
        testExecuteFromResult_FirstRecommendation()
        testExecuteFromResult_SecondRecommendation()
        testExecuteFromResult_NoRecommendations_NotTriggered()
        testCorrect_KeywordDetection()
        testChangeScope_ExplicitVerb()
        testChangeScope_TrailingTimeQuestion()
        testCrossDomain_HealthParentFinanceFollowUp()
        testCrossDomain_SameDomainNotCrossDomain()
        testDrillDown_DetailRequest()
        testExplain_WhyQuestion()
        testNewTopic_UnrelatedDomain()
        testAmbiguous_EmptyText()
        testAmbiguous_NoMarkerFallback()
        print("HoloAgentFollowUpRouterTests passed")
    }

    // MARK: - Helpers

    static func parent(domains: [String], hasRecs: Bool = false, question: String? = nil) -> HoloAgentFollowUpParentContext {
        HoloAgentFollowUpParentContext(parentDomains: domains, hasRecommendations: hasRecs, parentQuestion: question)
    }

    // MARK: - executeFromResult

    static func testExecuteFromResult_FirstRecommendation() {
        let p = parent(domains: ["finance"], hasRecs: true)
        expect(HoloAgentFollowUpRouter.classify(followUpText: "按这个建议建个待办", parent: p) == .executeFromResult, "按建议建待办")
        expect(HoloAgentFollowUpRouter.classify(followUpText: "第一条建议创建待办", parent: p) == .executeFromResult, "第一条建议")
    }

    static func testExecuteFromResult_SecondRecommendation() {
        let p = parent(domains: ["finance"], hasRecs: true)
        expect(HoloAgentFollowUpRouter.classify(followUpText: "就按第二条建议", parent: p) == .executeFromResult, "第二条建议")
    }

    static func testExecuteFromResult_NoRecommendations_NotTriggered() {
        let p = parent(domains: ["finance"], hasRecs: false)
        expect(HoloAgentFollowUpRouter.classify(followUpText: "按这个建议做", parent: p) != .executeFromResult, "无建议不触发 execute")
    }

    // MARK: - correct

    static func testCorrect_KeywordDetection() {
        let p = parent(domains: ["health"])
        expect(HoloAgentFollowUpRouter.classify(followUpText: "这个数算错了吧", parent: p) == .correct, "算错了")
        expect(HoloAgentFollowUpRouter.classify(followUpText: "口径不对", parent: p) == .correct, "口径不对")
        expect(HoloAgentFollowUpRouter.classify(followUpText: "应该是上个月的", parent: p) == .correct, "应该是")
    }

    // MARK: - changeScope

    static func testChangeScope_ExplicitVerb() {
        let p = parent(domains: ["health"])
        expect(HoloAgentFollowUpRouter.classify(followUpText: "换成今年的", parent: p) == .changeScope, "换成今年")
        expect(HoloAgentFollowUpRouter.classify(followUpText: "改成近三个月", parent: p) == .changeScope, "改成近三个月")
    }

    static func testChangeScope_TrailingTimeQuestion() {
        let p = parent(domains: ["health"])
        expect(HoloAgentFollowUpRouter.classify(followUpText: "上周的呢", parent: p) == .changeScope, "上周的呢")
        expect(HoloAgentFollowUpRouter.classify(followUpText: "上月的情况", parent: p) == .changeScope, "上月的情况")
    }

    // MARK: - crossDomain

    static func testCrossDomain_HealthParentFinanceFollowUp() {
        let p = parent(domains: ["health"])
        expect(HoloAgentFollowUpRouter.classify(followUpText: "那消费情况呢", parent: p) == .crossDomain, "健康父→消费追问应跨域")
    }

    static func testCrossDomain_SameDomainNotCrossDomain() {
        let p = parent(domains: ["health"])
        // 同域追问不应判跨域
        expect(HoloAgentFollowUpRouter.classify(followUpText: "睡眠具体怎么样", parent: p) != .crossDomain, "同域不应跨域")
    }

    // MARK: - drillDown

    static func testDrillDown_DetailRequest() {
        let p = parent(domains: ["finance"])
        expect(HoloAgentFollowUpRouter.classify(followUpText: "具体看看餐饮的", parent: p) == .drillDown, "具体看看")
        expect(HoloAgentFollowUpRouter.classify(followUpText: "详细展开一下", parent: p) == .drillDown, "详细展开")
    }

    // MARK: - explain

    static func testExplain_WhyQuestion() {
        let p = parent(domains: ["health"])
        expect(HoloAgentFollowUpRouter.classify(followUpText: "为什么步数变少了", parent: p) == .explain, "为什么")
        expect(HoloAgentFollowUpRouter.classify(followUpText: "这个结论什么意思", parent: p) == .explain, "什么意思")
    }

    // MARK: - newTopic

    static func testNewTopic_UnrelatedDomain() {
        let p = parent(domains: ["health"], question: "本周睡眠")
        // 明确的新域 + 无追问标记
        expect(HoloAgentFollowUpRouter.classify(followUpText: "帮我看看本月消费", parent: p) == .crossDomain, "有「帮我看看」且跨域——注意这里 crossDomain 优先于 newTopic")
    }

    // MARK: - ambiguous

    static func testAmbiguous_EmptyText() {
        let p = parent(domains: ["health"])
        expect(HoloAgentFollowUpRouter.classify(followUpText: "", parent: p) == .ambiguous, "空文本应 ambiguous")
        expect(HoloAgentFollowUpRouter.classify(followUpText: "   ", parent: p) == .ambiguous, "纯空格应 ambiguous")
    }

    static func testAmbiguous_NoMarkerFallback() {
        let p = parent(domains: ["health"])
        // 无任何关键词、无域、无追问标记 → ambiguous
        expect(HoloAgentFollowUpRouter.classify(followUpText: "嗯", parent: p) == .ambiguous, "无标记应 ambiguous")
    }
}
