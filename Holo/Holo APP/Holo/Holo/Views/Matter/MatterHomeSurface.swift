//
//  MatterHomeSurface.swift
//  Holo
//
//  首页焦点卡的选件与展示模型（方案 §13.2）
//
//  排序规则（确定性）：attention 最高（atRisk > needsAttention > waiting > onTrack > unknown）
//  → nextAction targetDate 最近 → 最近用户互动（updatedAt）。
//  多件进行中的事也只展示一件，其余收进「查看全部」。没有 active Matter 时整块消失。
//

import Foundation

nonisolated enum MatterHomeSurface {

    /// attention 的严重度权重（越大越值得关注）。
    nonisolated private static func weight(_ attention: HoloMatterAttention) -> Int {
        switch attention {
        case .atRisk: return 4
        case .needsAttention: return 3
        case .waiting: return 2
        case .onTrack: return 1
        case .unknown: return 0
        }
    }

    /// 焦点卡的展示项。loop 输入用于确定性重算 attention（不信任可能 stale 的投影）。
    nonisolated struct Candidate: Sendable {
        let id: UUID
        let title: String
        let targetDate: Date?
        let updatedAt: Date
        let nextActionTitle: String?
        let nextActionTargetDate: Date?
        let loops: [HoloMatterAttentionPolicy.LoopInput]
        let projectionAttention: HoloMatterAttention?
    }

    nonisolated static func select(_ candidates: [Candidate], now: Date = Date()) -> [MatterFocusCard.Item] {
        let scored = candidates.map { candidate -> (MatterFocusCard.Item, Int, Date, Date) in
            let attention = HoloMatterAttentionPolicy.evaluate(
                targetDate: candidate.targetDate, loops: candidate.loops, now: now
            )
            let effectiveAttention: HoloMatterAttention
            // 无日期无确认问题时的 unknown 优先级低于 onTrack（不制造噪音）
            effectiveAttention = attention.attention
            let item = MatterFocusCard.Item(
                id: candidate.id,
                title: candidate.title,
                attention: effectiveAttention,
                attentionReason: attention.reason,
                nextActionTitle: candidate.nextActionTitle,
                daysUntilTarget: candidate.targetDate.flatMap {
                    Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: Calendar.current.startOfDay(for: $0)).day
                }
            )
            return (item, weight(effectiveAttention), candidate.nextActionTargetDate ?? .distantFuture, candidate.updatedAt)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }          // attention 权重
                if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }          // nextAction 日期近者优先
                return lhs.3 > rhs.3                                 // 最近互动
            }
            .map(\.0)
    }
}
