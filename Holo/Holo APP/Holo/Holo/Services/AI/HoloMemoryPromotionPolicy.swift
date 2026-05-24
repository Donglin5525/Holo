//
//  HoloMemoryPromotionPolicy.swift
//  Holo
//
//  长期记忆晋升规则：判断候选丢弃、观察、静默写入、要求确认
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
        // 敏感/高影响推断 → 必须确认
        if candidate.sensitivity == .sensitive || candidate.sensitivity == .highImpact {
            return .requireConfirmation(reason: "涉及\(sensitivityLabel(candidate.sensitivity))推断，需用户确认")
        }

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

        // 稳定反馈偏好 → 不新建同源记忆
        if candidate.type == .stableFeedbackPreference {
            return .silentlyAccept(reason: "稳定的反馈偏好")
        }

        // 档案背书的事实 → 需确认（可能与档案冲突）
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

    private static func sensitivityLabel(_ sensitivity: HoloMemorySensitivity) -> String {
        switch sensitivity {
        case .normal: return ""
        case .highImpact: return "高影响"
        case .sensitive: return "敏感"
        }
    }
}
