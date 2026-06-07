//
//  HoloMemoryPromotionPolicy.swift
//  Holo
//
//  长期记忆晋升规则：按 semanticType 决策
//  旧 type 分支保留作为 fallback（semanticType == nil 时）
//

import Foundation

enum HoloMemoryPromotionDecision: Equatable {
    case discard(reason: String)
    case observe(reason: String)
    case silentlyAccept(reason: String)
    case requireConfirmation(reason: String)
}

enum HoloMemoryPromotionPolicy {

    /// 评估候选记忆的晋升决策
    static func evaluate(candidate: HoloLongTermMemory) -> HoloMemoryPromotionDecision {
        // 敏感/高影响 → 必须确认（优先级最高）
        if candidate.sensitivity == .sensitive || candidate.sensitivity == .highImpact {
            return .requireConfirmation(reason: "涉及\(sensitivityLabel(candidate.sensitivity))内容，需用户确认")
        }

        // 新语义类型路由
        if let semanticType = candidate.semanticType {
            return evaluateBySemanticType(candidate, semanticType: semanticType)
        }

        // 旧类型 fallback（semanticType == nil）
        return evaluateByLegacyType(candidate)
    }

    // MARK: - 新语义类型路由

    private static func evaluateBySemanticType(
        _ candidate: HoloLongTermMemory,
        semanticType: HoloMemorySemanticType
    ) -> HoloMemoryPromotionDecision {
        switch semanticType {
        case .phaseShift:
            guard candidate.evidence.count >= 2 else {
                return .observe(reason: "阶段变化证据不足，继续观察")
            }
            // 阶段变化都需确认，避免 AI 过早替用户定义阶段
            return .requireConfirmation(reason: "阶段变化需确认")

        case .stablePattern:
            // 多周期证据 + 非敏感 → 可静默写入
            if candidate.evidence.count >= 3 && candidate.sensitivity == .normal {
                return .silentlyAccept(reason: "稳定模式，有 \(candidate.evidence.count) 个证据")
            }
            return .requireConfirmation(reason: "稳定模式需确认（证据 \(candidate.evidence.count) 个）")

        case .driftSignal:
            guard candidate.evidence.count >= 2 else {
                return .observe(reason: "偏离提醒证据不足，继续观察")
            }
            // 偏离提醒始终需确认，并应有过期时间
            return .requireConfirmation(reason: "偏离提醒需确认")

        case .lifeEvent:
            // 人生节点始终需确认
            return .requireConfirmation(reason: "人生节点需确认")

        case .statMilestone:
            // 轻量统计收藏默认只展示，不进入 core context
            if candidate.useScopes?.contains(.coreContext) == true {
                return .requireConfirmation(reason: "轻量记录不能直接进入核心上下文")
            }
            return .observe(reason: "轻量统计收藏")
        }
    }

    // MARK: - 旧类型 Fallback

    private static func evaluateByLegacyType(_ candidate: HoloLongTermMemory) -> HoloMemoryPromotionDecision {
        // 用户明确表达 + 非敏感 → 静默写入
        if candidate.type == .explicitUserPreference && candidate.sensitivity == .normal {
            return .silentlyAccept(reason: "用户明确表达的偏好")
        }

        // 长期目标 → 由 UI 行为决定确认或静默
        if candidate.type == .longTermGoal {
            if candidate.confirmationState == .confirmed {
                return .silentlyAccept(reason: "已确认的长期目标")
            }
            return .requireConfirmation(reason: "长期目标需确认")
        }

        // 重复模式 + 多证据 → 需确认
        if candidate.type == .recurringPattern {
            if candidate.evidence.count >= 2 {
                return .requireConfirmation(reason: "检测到重复模式，有 \(candidate.evidence.count) 个证据")
            }
            return .observe(reason: "证据不足，继续观察")
        }

        // 稳定反馈偏好 → 静默写入
        if candidate.type == .stableFeedbackPreference {
            return .silentlyAccept(reason: "稳定的反馈偏好")
        }

        // 档案背书的事实 → 需确认
        if candidate.type == .profileBackedFact {
            return .requireConfirmation(reason: "与档案相关的事实，需确认")
        }

        // 证据不足
        if candidate.evidence.count < 2 {
            return candidate.evidence.isEmpty
                ? .discard(reason: "无证据支撑")
                : .observe(reason: "证据不足，继续观察")
        }

        return .observe(reason: "需更多观察")
    }

    // MARK: - Helper

    private static func sensitivityLabel(_ sensitivity: HoloMemorySensitivity) -> String {
        switch sensitivity {
        case .normal: return ""
        case .highImpact: return "高影响"
        case .sensitive: return "敏感"
        }
    }
}
