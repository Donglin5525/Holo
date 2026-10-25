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

    /// 空状态卡片展示的能力入口（首次进入空会话时的引导建议）。
    /// - 未完成引导：突出「使用指南」。
    /// - 已完成引导：给三条常用建议问题。
    /// （2026-10-23「一个发现」上线替换「今日状态」：发现胶囊仅在有效发现时出现在常驻行，
    /// 不进空态建议；今日状态入口退役。）
    static func emptyStateCapabilities(context: HoloAICapabilityProviderContext) -> [HoloAICapability] {
        var capabilities: [HoloAICapability] = []

        // 新人引导：未完成引导时置顶展示
        if !context.onboardingCompleted {
            capabilities.append(HoloAICapability(
                id: .onboarding,
                title: "使用指南",
                systemImage: "sparkles",
                isEmphasized: true,
                isEnabled: true
            ))
        }

        // 已完成引导的老用户，补充数据类建议
        if context.onboardingCompleted {
            capabilities.append(HoloAICapability(
                id: .recentAnalysis,
                title: "深度分析",
                systemImage: "chart.line.uptrend.xyaxis",
                isEmphasized: false,
                isEnabled: true
            ))

            let hasMemoryContent = context.hasLongTermMemories || context.hasLongTermCandidates
            capabilities.append(HoloAICapability(
                id: .longTermPatterns,
                title: hasMemoryContent ? "长期模式" : "长期模式 · 形成中",
                systemImage: "brain.head.profile",
                isEmphasized: false,
                isEnabled: true
            ))
        }

        return capabilities
    }

    /// 输入框上方常驻能力行的入口（对话全程可见）。
    /// 顺序（2026-10-23「一个发现」替换「今日状态」后）：深度分析 / 一个发现（有效时才有，
    /// 由 QuickActionBar 内 DiscoveryCapsuleView 渲染，不在此列）/ 周期回放 / 规划目标。
    /// 「深度分析」排第一（2026-08-22 东林拍板）；不含「使用指南」（新用户引导归空态卡）。
    static func persistentCapabilities(context: HoloAICapabilityProviderContext = .empty) -> [HoloAICapability] {
        return [
            HoloAICapability(
                id: .recentAnalysis,
                title: "深度分析",
                systemImage: "chart.line.uptrend.xyaxis",
                isEmphasized: context.hasSufficientData,
                isEnabled: true
            ),
            HoloAICapability(
                id: .periodReplay,
                title: "周期回放",
                systemImage: "play.rectangle.fill",
                isEmphasized: false,
                isEnabled: true
            ),
            HoloAICapability(
                id: .goalPlanning,
                title: "规划目标",
                systemImage: "target",
                isEmphasized: false,
                isEnabled: true
            )
        ]
    }
}
