//
//  HoloAgentBudgetSelectorTests.swift
//  HoloTests
//
//  Agent 成熟度演进 P1-A — Budget Selector + Capability Selection 测试
//

import Foundation

@main
struct HoloAgentBudgetSelectorTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test简单查数_轻量预算()
        test单域分析_标准预算()
        test比较分析_可扩展()
        test跨域分析_扩展预算()
        test敏感分析_强制verifier()
        testObserverFollowUp_克制预算()
        test核心能力常驻()
        test域工具注入()
        test跨域能力注入()
        test简单查数只保留单域工具()
        test一次扩展回退始终允许()
        testToken倍率合理()
        test预算工厂映射正确()
        print("HoloAgentBudgetSelectorTests passed")
    }

    private static var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "zh_CN")
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    private static let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)

    private static func makeFrame(profile: HoloAgentTaskProfile, domains: [String]) -> HoloAgentQuerySemanticFrame {
        HoloAgentQuerySemanticFrame(
            query: "test", profile: profile, resolvedTime: nil, resolvedComparison: nil,
            ambiguities: [], domains: domains, sensitivity: .normal
        )
    }

    // MARK: - 预算选择

    private static func test简单查数_轻量预算() {
        let config = HoloAgentBudgetSelector.selectConfig(
            for: .simpleLookup, frame: makeFrame(profile: .simpleLookup, domains: ["finance"])
        )
        expect(config.budgetPreset == .normalDeep, "简单查数用 normalDeep")
        expect(!config.enablePlan, "简单查数不启用 plan")
        expect(config.maxToolRounds == 2, "简单查数最多 2 轮")
        expect(!config.requireVerifier, "简单查数不强制 verifier")
        expect(config.tokenBudgetMultiplier < 1.0, "简单查数 token 倍率 < 1.0")
    }

    private static func test单域分析_标准预算() {
        let config = HoloAgentBudgetSelector.selectConfig(
            for: .singleDomainAnalysis, frame: makeFrame(profile: .singleDomainAnalysis, domains: ["health"])
        )
        expect(config.budgetPreset == .normalDeep, "单域分析用 normalDeep")
        expect(config.enablePlan, "单域分析启用 plan")
        expect(config.requireVerifier, "单域分析强制 verifier")
    }

    private static func test比较分析_可扩展() {
        let config = HoloAgentBudgetSelector.selectConfig(
            for: .comparisonAnalysis, frame: makeFrame(profile: .comparisonAnalysis, domains: ["finance"]), allowExtended: true
        )
        expect(config.enablePlan, "比较分析启用 plan")
        expect(config.requireVerifier, "比较分析强制 verifier")
        expect(config.tokenBudgetMultiplier > 1.0, "比较分析 token 倍率 > 1.0")
    }

    private static func test跨域分析_扩展预算() {
        let config = HoloAgentBudgetSelector.selectConfig(
            for: .crossDomainAnalysis, frame: makeFrame(profile: .crossDomainAnalysis, domains: ["finance", "health"]), allowExtended: true
        )
        expect(config.budgetPreset == .extendedDeep, "跨域分析允许时用 extendedDeep")
        expect(config.allowExtendedDeep, "应允许 extended deep")
        expect(config.tokenBudgetMultiplier > 1.0, "跨域分析 token 倍率 > 1.0")
    }

    private static func test敏感分析_强制verifier() {
        let config = HoloAgentBudgetSelector.selectConfig(
            for: .sensitiveAnalysis, frame: makeFrame(profile: .sensitiveAnalysis, domains: ["health"])
        )
        expect(config.requireVerifier, "敏感分析强制 verifier")
        expect(!config.allowExtendedDeep, "敏感分析不扩展")
    }

    private static func testObserverFollowUp_克制预算() {
        let config = HoloAgentBudgetSelector.selectConfig(
            for: .observerFollowUp, frame: makeFrame(profile: .observerFollowUp, domains: ["health"])
        )
        expect(config.budgetPreset == .observerFollowUp, "Observer 用 observerFollowUp")
        expect(config.tokenBudgetMultiplier < 1.0, "Observer token 倍率 < 1.0")
        expect(!config.enablePlan, "Observer 不启用 plan")
    }

    // MARK: - 能力选择

    private static func test核心能力常驻() {
        let config = HoloAgentBudgetSelector.selectConfig(
            for: .simpleLookup, frame: makeFrame(profile: .simpleLookup, domains: ["finance"])
        )
        expect(config.selectedCapabilities.coreTools.contains("conversation"), "核心能力 conversation 应常驻")
        expect(config.selectedCapabilities.coreTools.contains("memory"), "核心能力 memory 应常驻")
    }

    private static func test域工具注入() {
        let config = HoloAgentBudgetSelector.selectConfig(
            for: .singleDomainAnalysis, frame: makeFrame(profile: .singleDomainAnalysis, domains: ["health"])
        )
        expect(config.selectedCapabilities.domainTools.contains("health"), "应注入 health 工具")
    }

    private static func test跨域能力注入() {
        let config = HoloAgentBudgetSelector.selectConfig(
            for: .crossDomainAnalysis, frame: makeFrame(profile: .crossDomainAnalysis, domains: ["finance", "health"])
        )
        expect(!config.selectedCapabilities.crossDomainTools.isEmpty, "跨域分析应注入跨域能力")
    }

    private static func test简单查数只保留单域工具() {
        let config = HoloAgentBudgetSelector.selectConfig(
            for: .simpleLookup, frame: makeFrame(profile: .simpleLookup, domains: ["finance", "health"])
        )
        expect(config.selectedCapabilities.domainTools.count <= 1, "简单查数只保留单域工具，实际 \(config.selectedCapabilities.domainTools)")
    }

    private static func test一次扩展回退始终允许() {
        for profile in [HoloAgentTaskProfile.simpleLookup, .crossDomainAnalysis, .sensitiveAnalysis] {
            let config = HoloAgentBudgetSelector.selectConfig(
                for: profile, frame: makeFrame(profile: profile, domains: ["finance"])
            )
            expect(config.selectedCapabilities.allowOneExtensionFallback, "\(profile) 应允许一次扩展回退")
        }
    }

    private static func testToken倍率合理() {
        let simple = HoloAgentBudgetSelector.selectConfig(
            for: .simpleLookup, frame: makeFrame(profile: .simpleLookup, domains: ["finance"])
        )
        let cross = HoloAgentBudgetSelector.selectConfig(
            for: .crossDomainAnalysis, frame: makeFrame(profile: .crossDomainAnalysis, domains: ["finance", "health"])
        )
        expect(simple.tokenBudgetMultiplier < cross.tokenBudgetMultiplier, "简单查数 token 应少于跨域分析")
    }

    private static func test预算工厂映射正确() {
        for preset in [HoloAgentBudgetPresetName.normalDeep, .extendedDeep, .observerFollowUp] {
            let budget = HoloAgentBudgetSelector.makeBudget(preset: preset)
            expect(budget.maxLLMRounds > 0, "\(preset) 预算应有 LLM 轮次")
            expect(budget.maxInputTokens > 0, "\(preset) 预算应有输入 token")
        }
        // extendedDeep 应比 normalDeep 有更多 token
        let normal = HoloAgentBudgetSelector.makeBudget(preset: .normalDeep)
        let extended = HoloAgentBudgetSelector.makeBudget(preset: .extendedDeep)
        expect(extended.maxInputTokens > normal.maxInputTokens, "extendedDeep 输入 token 应 > normalDeep")
        // observerFollowUp 应最少
        let observer = HoloAgentBudgetSelector.makeBudget(preset: .observerFollowUp)
        expect(observer.maxInputTokens < normal.maxInputTokens, "observerFollowUp 输入 token 应 < normalDeep")
    }
}
