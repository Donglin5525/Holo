//
//  HoloMemoryPromotionPolicy.swift
//  Holo
//
//  长期记忆晋升规则：按 semanticType 决策
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

        return evaluateBySemanticType(candidate, semanticType: candidate.semanticType)
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
            if candidate.useScopes.contains(.coreContext) {
                return .requireConfirmation(reason: "轻量记录不能直接进入核心上下文")
            }
            return .silentlyAccept(reason: "轻量统计收藏，仅用于展示与回顾")
        }
    }

    private static func sensitivityLabel(_ sensitivity: HoloMemorySensitivity) -> String {
        switch sensitivity {
        case .normal: return ""
        case .highImpact: return "高影响"
        case .sensitive: return "敏感"
        }
    }
}
