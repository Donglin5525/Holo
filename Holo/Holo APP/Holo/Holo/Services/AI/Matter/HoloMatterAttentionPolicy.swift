//
//  HoloMatterAttentionPolicy.swift
//  Holo
//
//  Matter 关注状态的唯一确定性规则源（方案 §5.3）
//
//  模型可以解释原因，但不能自由决定状态；UI 颜色只来自这里的输出。
//  首版规则（全部确定性）：
//  - 无可靠目标日期、无明确高优先 Open Loop → unknown / onTrack，不制造风险
//  - 所有已确认关键项等待外部结果 → waiting
//  - 已确认关键期限已错过 → atRisk
//  - 已确认问题进入建议处理窗口（14 天）→ needsAttention
//  - suggested Open Loop 不参与任何风险升级
//

import Foundation

nonisolated enum HoloMatterAttentionPolicy {

    /// 建议处理窗口：期限进入这个天数内即提醒关注。
    static let handlingWindowDays: Int = 14

    /// 规则输入：一条 active Open Loop 的最小快照。
    nonisolated struct LoopInput: Sendable {
        /// loop 真实 ID（携带时 Next Action 可指向真实实体；展示层旧调用可不传）。
        let id: UUID?
        let title: String
        let state: HoloMatterOpenLoopState
        let epistemic: HoloMatterOpenLoopEpistemic
        let targetDate: Date?
        /// loop 已链接的真实任务（Next Action 从 openLoopAction 升级为 linkedTask）。
        let linkedTaskID: UUID?

        init(
            id: UUID? = nil,
            title: String,
            state: HoloMatterOpenLoopState,
            epistemic: HoloMatterOpenLoopEpistemic,
            targetDate: Date? = nil,
            linkedTaskID: UUID? = nil
        ) {
            self.id = id
            self.title = title
            self.state = state
            self.epistemic = epistemic
            self.targetDate = targetDate
            self.linkedTaskID = linkedTaskID
        }
    }

    struct Result: Equatable, Sendable {
        let attention: HoloMatterAttention
        /// 解释文字（可由模型润色，但状态本身不改）。
        let reason: String?
    }

    /// 评估一件 Matter 的关注状态。
    static func evaluate(
        targetDate: Date?,
        loops: [LoopInput],
        now: Date = Date()
    ) -> Result {
        let confirmedLoops = loops.filter { $0.epistemic == .confirmed }

        // 规则 1：所有已确认关键项都在等待外部结果 → waiting。
        if !confirmedLoops.isEmpty,
           confirmedLoops.allSatisfy({ $0.state == .waiting }) {
            return Result(attention: .waiting, reason: String(localized: "关键事项都在等待外部结果"))
        }

        // 规则 2：已确认关键期限已错过 → atRisk。
        for loop in confirmedLoops where loop.state == .open {
            if let deadline = loop.targetDate, deadline < now {
                return Result(
                    attention: .atRisk,
                    reason: String(localized: "「\(loop.title)」的期限已过")
                )
            }
        }
        if let targetDate, targetDate < now {
            return Result(attention: .atRisk, reason: String(localized: "目标日期已过"))
        }

        // 规则 3：已确认问题进入建议处理窗口 → needsAttention。
        for loop in confirmedLoops where loop.state == .open {
            if let deadline = loop.targetDate,
               let days = Self.days(until: deadline, from: now),
               days <= handlingWindowDays {
                return Result(
                    attention: .needsAttention,
                    reason: String(localized: "「\(loop.title)」临近处理窗口")
                )
            }
        }
        if let targetDate,
           let days = Self.days(until: targetDate, from: now),
           days <= handlingWindowDays,
           confirmedLoops.contains(where: { $0.state == .open }) {
            return Result(
                attention: .needsAttention,
                reason: String(localized: "距离目标日期不远，还有未解决的问题")
            )
        }

        // 规则 4：无可靠日期、无已确认问题 → unknown（不制造风险）。
        if targetDate == nil && confirmedLoops.isEmpty {
            return Result(attention: .unknown, reason: nil)
        }

        // 规则 5：其余情况 → onTrack。
        return Result(attention: .onTrack, reason: nil)
    }

    nonisolated private static func days(until date: Date, from now: Date) -> Int? {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day
    }
}
