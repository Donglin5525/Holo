//
//  HoloAgentBudgetSelector.swift
//  Holo
//
//  Agent 成熟度演进 P1-A — 任务画像驱动的预算选择 + 工具能力软选择
//
//  根据确定性 TaskProfile 选择现有 budget、是否启用 plan、允许的工具轮次、
//  是否强制 verifier，以及模型/Token 上限。extendedDeep 只有在复杂任务满足条件时使用。
//  工具发现采用软选择：核心能力常驻 + 高置信领域 + 跨域能力 + 一次扩展回退。
//

import Foundation

// MARK: - 预算选择结果

/// 任务画像对应的执行配置。
nonisolated struct HoloAgentTaskExecutionConfig: Equatable, Sendable {
    /// 选择的预算预设名称。
    var budgetPreset: HoloAgentBudgetPresetName
    /// 是否启用正式 Plan。
    var enablePlan: Bool
    /// 允许的最大工具轮次（0 = 不限制，由 budget 控制）。
    var maxToolRounds: Int
    /// 是否强制 Claim Verifier 2.0。
    var requireVerifier: Bool
    /// 建议的模型 Token 上限倍率（相对 normalDeep）。
    var tokenBudgetMultiplier: Double
    /// 是否允许 extendedDeep（仅复杂任务满足条件时）。
    var allowExtendedDeep: Bool

    /// 软选择的工具能力集合。
    var selectedCapabilities: HoloAgentCapabilitySelection
}

nonisolated enum HoloAgentBudgetPresetName: String, Equatable, Sendable {
    case normalDeep
    case extendedDeep
    case observerFollowUp
}

// MARK: - 预算选择器

nonisolated enum HoloAgentBudgetSelector {

    /// 根据 TaskProfile 选择执行配置。
    static func selectConfig(
        for profile: HoloAgentTaskProfile,
        frame: HoloAgentQuerySemanticFrame,
        allowExtended: Bool = false
    ) -> HoloAgentTaskExecutionConfig {
        let budgetPreset: HoloAgentBudgetPresetName
        let enablePlan: Bool
        let maxToolRounds: Int
        let requireVerifier: Bool
        let tokenMultiplier: Double
        let allowExtendedDeep: Bool

        switch profile {
        case .simpleLookup:
            budgetPreset = .normalDeep
            enablePlan = false
            maxToolRounds = 2
            requireVerifier = false
            tokenMultiplier = 0.7  // 简单查数用更少 token
            allowExtendedDeep = false

        case .singleDomainAnalysis:
            budgetPreset = .normalDeep
            enablePlan = true
            maxToolRounds = 4
            requireVerifier = true
            tokenMultiplier = 1.0
            allowExtendedDeep = false

        case .comparisonAnalysis:
            budgetPreset = .normalDeep
            enablePlan = true
            maxToolRounds = 5
            requireVerifier = true
            tokenMultiplier = 1.2
            allowExtendedDeep = allowExtended

        case .crossDomainAnalysis:
            budgetPreset = allowExtended ? .extendedDeep : .normalDeep
            enablePlan = true
            maxToolRounds = 5
            requireVerifier = true
            tokenMultiplier = 1.5
            allowExtendedDeep = allowExtended

        case .sensitiveAnalysis:
            budgetPreset = .normalDeep
            enablePlan = true
            maxToolRounds = 4
            requireVerifier = true  // 敏感分析强制 verifier
            tokenMultiplier = 1.0
            allowExtendedDeep = false  // 敏感分析不扩展，避免过度推断

        case .observerFollowUp:
            budgetPreset = .observerFollowUp
            enablePlan = false  // Observer 跟进用轻量路径
            maxToolRounds = 2
            requireVerifier = true
            tokenMultiplier = 0.6
            allowExtendedDeep = false
        }

        // 能力软选择
        let capabilities = HoloAgentCapabilitySelector.selectCapabilities(
            profile: profile, domains: frame.domains
        )

        return HoloAgentTaskExecutionConfig(
            budgetPreset: budgetPreset,
            enablePlan: enablePlan,
            maxToolRounds: maxToolRounds,
            requireVerifier: requireVerifier,
            tokenBudgetMultiplier: tokenMultiplier,
            allowExtendedDeep: allowExtendedDeep,
            selectedCapabilities: capabilities
        )
    }

    /// 根据预设名构建实际预算（复用现有 HoloAgentBudget 工厂方法）。
    static func makeBudget(preset: HoloAgentBudgetPresetName, now: Date = Date()) -> HoloAgentBudget {
        switch preset {
        case .normalDeep:
            return .normalDeep(now: now)
        case .extendedDeep:
            return .extendedDeep(now: now)
        case .observerFollowUp:
            return .observerFollowUp(now: now)
        }
    }
}

// MARK: - 工具能力软选择

/// 软选择的工具能力集合。不使用不可恢复的单领域硬门控。
nonisolated struct HoloAgentCapabilitySelection: Equatable, Sendable {
    /// 核心能力（所有任务常驻）。
    var coreTools: Set<String>
    /// 高置信相关领域工具。
    var domainTools: Set<String>
    /// 跨域能力（明确跨域问题时注入）。
    var crossDomainTools: Set<String>
    /// 是否允许一次扩展回退。
    var allowOneExtensionFallback: Bool

    /// 合并后的完整工具集（用于 prompt 描述）。
    var allTools: Set<String> {
        coreTools.union(domainTools).union(crossDomainTools)
    }
}

nonisolated enum HoloAgentCapabilitySelector {

    /// 核心能力（小型常驻集）。
    static let coreCapabilities: Set<String> = ["conversation", "memory"]

    /// 域 → 工具映射。
    static let domainToolMap: [String: String] = [
        "finance": "finance",
        "health": "health",
        "habit": "habit",
        "task": "task",
        "goal": "goal",
        "thought": "thought",
        "profile": "profile",
        "insight": "insight",
    ]

    /// 跨域能力（fusion 相关）。
    static let crossDomainCapabilities: Set<String> = ["insight"]

    /// 根据 profile 和域选择工具能力。
    static func selectCapabilities(
        profile: HoloAgentTaskProfile,
        domains: [String]
    ) -> HoloAgentCapabilitySelection {
        // 1. 核心能力常驻
        var core = coreCapabilities

        // 2. 注入高置信相关领域
        var domainTools: Set<String> = []
        for domain in domains {
            if let tool = domainToolMap[domain] {
                domainTools.insert(tool)
            }
        }

        // 3. 跨域能力
        var crossDomain: Set<String> = []
        if profile == .crossDomainAnalysis || domains.count > 1 {
            crossDomain = crossDomainCapabilities
        }

        // 4. 简单查数只保留核心 + 单域
        if profile == .simpleLookup {
            // 只保留第一个域的工具，减少 token
            if let firstDomain = domains.first, let tool = domainToolMap[firstDomain] {
                domainTools = [tool]
            }
        }

        // 5. 所有任务都允许一次扩展回退
        return HoloAgentCapabilitySelection(
            coreTools: core,
            domainTools: domainTools,
            crossDomainTools: crossDomain,
            allowOneExtensionFallback: true
        )
    }
}
