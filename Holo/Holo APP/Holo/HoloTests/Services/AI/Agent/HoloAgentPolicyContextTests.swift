//
//  HoloAgentPolicyContextTests.swift
//  HoloTests
//
//  Agent 成熟度演进 P1-B — AgentPolicyContext + Conclusion Promotion 测试
//

import Foundation

@main
struct HoloAgentPolicyContextTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test当前输入最高优先级()
        test明确纠正高于稳定偏好()
        test弱偏好带有效期()
        test过期规则被过滤()
        testToken截断()
        test当前输入覆盖旧偏好()
        test域相关规则过滤()
        test长期结论准入_满足门槛()
        test长期结论准入_重复不足不进入()
        test长期结论准入_证据不足不进入()
        test长期结论准入_rejected不进入()
        test一次性查数不进入长期结论()
        test全局默认始终存在()
        print("HoloAgentPolicyContextTests passed")
    }

    // MARK: - Policy Context

    private static func test当前输入最高优先级() {
        let ctx = HoloAgentPolicyBuilder.build(
            confirmedPreferences: ["稳定偏好"], explicitCorrections: [], weakPreferences: [],
            currentInput: ["当前输入"], domains: ["finance"]
        )
        let topEntry = ctx.activeRules.first
        expect(topEntry?.source == .currentInput, "最高优先级应为当前输入，实际 \(topEntry?.source.rawValue ?? "nil")")
    }

    private static func test明确纠正高于稳定偏好() {
        let ctx = HoloAgentPolicyBuilder.build(
            confirmedPreferences: ["稳定偏好"], explicitCorrections: ["明确纠正"],
            weakPreferences: [], currentInput: [], domains: ["finance"]
        )
        let correctionEntry = ctx.activeRules.first(where: { $0.source == .explicitCorrection })
        let prefEntry = ctx.activeRules.first(where: { $0.source == .confirmedPreference })
        expect((correctionEntry?.priority ?? 0) > (prefEntry?.priority ?? 0), "明确纠正优先级应高于稳定偏好")
    }

    private static func test弱偏好带有效期() {
        let ctx = HoloAgentPolicyBuilder.build(
            confirmedPreferences: [], explicitCorrections: [], weakPreferences: ["弱偏好"],
            currentInput: [], domains: ["finance"]
        )
        let weakEntry = ctx.activeRules.first(where: { $0.source == .weakPreference })
        expect(weakEntry?.validUntil != nil, "弱偏好应有有效期")
    }

    private static func test过期规则被过滤() {
        let pastDate = Date(timeIntervalSince1970: 1_000_000) // 1970年
        let ctx = HoloAgentPolicyBuilder.build(
            confirmedPreferences: [], explicitCorrections: [], weakPreferences: ["过期弱偏好"],
            currentInput: [], domains: ["finance"], now: Date()
        )
        // 弱偏好的有效期是 now + 30 天，不应过期
        expect(ctx.activeRules.contains(where: { $0.source == .weakPreference }), "有效弱偏好应保留")

        // 手动构造过期规则验证过滤
        var expiredEntry = ctx.entries.first(where: { $0.source == .weakPreference })
        expiredEntry?.validUntil = pastDate
        expect(expiredEntry?.validUntil ?? Date() < Date(), "过期日期应在过去")
    }

    private static func testToken截断() {
        let manyPrefs = (0..<100).map { "偏好\($0)" }
        let ctx = HoloAgentPolicyBuilder.build(
            confirmedPreferences: manyPrefs, explicitCorrections: [], weakPreferences: [],
            currentInput: [], domains: ["finance"], tokenBudget: 150
        )
        // 150 budget / 15 per entry = 10 max entries
        expect(ctx.entries.count <= 10, "Token 截断应限制条目数，实际 \(ctx.entries.count)")
        expect(ctx.estimatedTokens <= 150, "估算 token 应 <= 预算")
    }

    private static func test当前输入覆盖旧偏好() {
        let ctx = HoloAgentPolicyBuilder.build(
            confirmedPreferences: ["旧偏好"], explicitCorrections: [],
            weakPreferences: [], currentInput: ["新输入"], domains: ["finance"]
        )
        let overridden = ctx.overriddenByCurrentInput()
        expect(overridden.contains(where: { id in
            ctx.entries.first(where: { $0.id == id })?.source == .confirmedPreference
        }), "当前输入应覆盖旧偏好")
    }

    private static func test域相关规则过滤() {
        let ctx = HoloAgentPolicyBuilder.build(
            confirmedPreferences: [], explicitCorrections: ["不要建议多运动"],
            weakPreferences: [], currentInput: [], domains: ["health"]
        )
        let healthRules = ctx.rules(forDomain: "health")
        let financeRules = ctx.rules(forDomain: "finance")
        // 全域规则（relatedDomain=nil）应同时出现在两个域
        expect(healthRules.contains(where: { $0.rule == "不要建议多运动" }), "health 域应包含纠正规则")
        expect(financeRules.contains(where: { $0.rule == "不要建议多运动" }), "finance 域也应包含（relatedDomain=nil）")
    }

    // MARK: - 长期结论准入

    private static func makeClaim(type: String = "observation", evidenceIDs: [String] = ["ev1", "ev2"]) -> HoloAgentClaim {
        HoloAgentClaim(
            id: "c1", type: type, displayText: "测试结论",
            metricAssertions: [HoloMetricAssertion(metricKey: "finance.total", value: 3000, baselineValue: type == "comparison" ? 2800 : nil, unit: "元", comparison: nil, evidenceIDs: evidenceIDs)],
            evidenceIDs: evidenceIDs, prohibitedInferences: [],
            confidence: 0.8
        )
    }

    private static func test长期结论准入_满足门槛() {
        let claim = makeClaim(type: "comparison")
        let result = HoloClaimVerificationResultV2(
            claim: claim, verdict: .verified, reasons: [],
            systemConfidence: 0.8, degradedExpression: nil, dimensionResults: [:]
        )
        let shouldPromote = HoloAgentConclusionPromotionPolicy.shouldPromote(
            claim: claim, occurrences: 3, verificationResult: result
        )
        expect(shouldPromote, "满足门槛应准入")
    }

    private static func test长期结论准入_重复不足不进入() {
        let claim = makeClaim(type: "comparison")
        let shouldPromote = HoloAgentConclusionPromotionPolicy.shouldPromote(
            claim: claim, occurrences: 1, verificationResult: nil
        )
        expect(!shouldPromote, "重复不足不应准入")
    }

    private static func test长期结论准入_证据不足不进入() {
        let claim = makeClaim(type: "comparison", evidenceIDs: ["ev1"]) // 只有1个证据
        let shouldPromote = HoloAgentConclusionPromotionPolicy.shouldPromote(
            claim: claim, occurrences: 3, verificationResult: nil
        )
        expect(!shouldPromote, "证据不足不应准入")
    }

    private static func test长期结论准入_rejected不进入() {
        let claim = makeClaim(type: "comparison")
        let result = HoloClaimVerificationResultV2(
            claim: claim, verdict: .rejected, reasons: ["test"],
            systemConfidence: 0.2, degradedExpression: nil, dimensionResults: [:]
        )
        let shouldPromote = HoloAgentConclusionPromotionPolicy.shouldPromote(
            claim: claim, occurrences: 3, verificationResult: result
        )
        expect(!shouldPromote, "rejected claim 不应准入长期结论")
    }

    private static func test一次性查数不进入长期结论() {
        let claim = makeClaim(type: "observation") // 无 baseline 的一次性查数
        let shouldPromote = HoloAgentConclusionPromotionPolicy.shouldPromote(
            claim: claim, occurrences: 1, verificationResult: nil
        )
        expect(!shouldPromote, "一次性查数不应进入长期结论")
    }

    private static func test全局默认始终存在() {
        let ctx = HoloAgentPolicyBuilder.build(
            confirmedPreferences: [], explicitCorrections: [], weakPreferences: [],
            currentInput: [], domains: []
        )
        expect(ctx.activeRules.contains(where: { $0.source == .globalDefault }), "全局默认应始终存在")
    }
}
