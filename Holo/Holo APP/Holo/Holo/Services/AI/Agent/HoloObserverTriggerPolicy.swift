//
//  HoloObserverTriggerPolicy.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 6.4 Observer Tier2 触发策略
//  决定是否对一组 pattern 启动 Tier2 深度 Agent 跟进。确定性规则，可测试。
//

import Foundation

struct HoloObserverTriggerPolicy {

    /// Tier2 冷却时间（分钟），避免短时间内重复深度分析。
    var tier2CooldownMinutes: Int = 360

    /// 是否应触发 Tier2 Agent 跟进。
    /// - userRequested：用户手动触发，无视冷却。
    /// - 冷却未过且非手动：不触发。
    /// - 否则：存在 high/critical severity 或 goalConflict pattern 即触发。
    func shouldTriggerTier2(
        patterns: [HoloPatternSignal],
        lastTier2RunAt: Date?,
        now: Date,
        userRequested: Bool
    ) -> Bool {
        if userRequested { return true }
        if let lastTier2RunAt,
           now.timeIntervalSince(lastTier2RunAt) < TimeInterval(tier2CooldownMinutes * 60) {
            return false
        }
        return patterns.contains {
            $0.severity == .high || $0.severity == .critical || $0.type == .goalConflict
        }
    }
}
