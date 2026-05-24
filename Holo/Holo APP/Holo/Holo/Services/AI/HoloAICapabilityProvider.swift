//
//  HoloAICapabilityProvider.swift
//  Holo
//
//  根据用户状态返回能力启动台入口列表
//

import Foundation

struct HoloAICapabilityProviderContext: Equatable {
    let hasSufficientData: Bool
    let hasLongTermMemories: Bool
    let hasLongTermCandidates: Bool
    let onboardingCompleted: Bool

    static let empty = HoloAICapabilityProviderContext(
        hasSufficientData: false,
        hasLongTermMemories: false,
        hasLongTermCandidates: false,
        onboardingCompleted: false
    )
}

enum HoloAICapabilityProvider {

    static func visibleCapabilities(context: HoloAICapabilityProviderContext) -> [HoloAICapability] {
        var capabilities: [HoloAICapability] = []

        // 新人引导：未完成引导时展示
        if !context.onboardingCompleted {
            capabilities.append(HoloAICapability(
                id: .onboarding,
                title: "使用指南",
                systemImage: "sparkles",
                isEmphasized: true,
                isEnabled: true
            ))
        }

        // 今日状态：常驻
        capabilities.append(HoloAICapability(
            id: .todayState,
            title: "今日状态",
            systemImage: "sun.max",
            isEmphasized: false,
            isEnabled: true
        ))

        // 最近分析：有数据时强化展示
        capabilities.append(HoloAICapability(
            id: .recentAnalysis,
            title: "最近分析",
            systemImage: "chart.line.uptrend.xyaxis",
            isEmphasized: context.hasSufficientData,
            isEnabled: context.hasSufficientData
        ))

        // 长期模式：有记忆或候选时强化，否则弱化展示
        let hasMemoryContent = context.hasLongTermMemories || context.hasLongTermCandidates
        capabilities.append(HoloAICapability(
            id: .longTermPatterns,
            title: hasMemoryContent ? "长期模式" : "形成中",
            systemImage: "brain.head.profile",
            isEmphasized: hasMemoryContent,
            isEnabled: true
        ))

        // 规划目标：常驻
        capabilities.append(HoloAICapability(
            id: .goalPlanning,
            title: "规划目标",
            systemImage: "target",
            isEmphasized: false,
            isEnabled: true
        ))

        return capabilities
    }
}
