//
//  HoloKnowledgeLegacySweep.swift
//  Holo
//
//  存量大扫除（2026-10-29 东林拍板「扫」；2026-11-01 第二刀升级）：
//  把历史上被错误激活的自动记忆从「已记住」收进历史（state=archived），
//  主列表退出、历史可查、原始账单/打卡不受影响。
//
//  第二刀（2026-11-01，真数据驱动）：第一刀句式匹配漏掉大量变体
//  （「记录了一次晚餐支出」「完成了一条任务」等）。升级为分类驱动——
//  读取端 formation 防线（错标 explicitUserStatement 只认对话域、业务域
//  declared 降级）生效后，凡是自动产生、无用户表态、且统一分类落为
//  「自动低价值 / 未确认推断」的 active 记录，一律收进历史。
//  值得确认候选（candidate 态）不在本刀范围：它们留在孵化区等统计引擎。
//
//  铁律（保护边界，一条不碰）：用户确认过/纠正过/否决过的、敏感的、
//  用户原话（对话/想法域直接陈述）、以及非 active 状态的记录。
//  幂等：archived 后不再命中，空转无害；走正常持久化通道随 CloudKit 同步。
//

import Foundation

nonisolated enum HoloLegacySweepPolicy {
    /// 第一刀（2026-11-01 扩域）：单次消费流水报告（「有一笔/记录了一笔 X 支出」）。
    /// 域不限——财务库的单笔流水、对话里「记一笔 X」转述的单笔消费同样无记忆
    /// 价值（账单本身更准）；证据 ≤3 条防误伤真正的跨期聚合。
    static func isSingleExpenseFlow(_ record: HoloMemoryRecord) -> Bool {
        guard isSweepableBaseline(record),
              record.claimKind == .observedFact,
              record.evidenceRefs.count <= 3 else { return false }
        return matchesSingleExpensePhrase(record.displaySummary)
    }

    /// 第二刀（保留兼容）：单日打卡碎片（打卡句式 + 无跨期/频次词）。
    static func isSingleDayCheckinFragment(_ record: HoloMemoryRecord) -> Bool {
        guard isSweepableBaseline(record),
              record.claimKind == .recurringPattern,
              record.displaySummary.contains("打卡") else { return false }
        let s = record.displaySummary
        for marker in ["至", "期间", "每周", "每天", "规律", "最近"] where s.contains(marker) {
            return false
        }
        return true
    }

    /// 第三刀（2026-11-01）：分类驱动。自动产生 + 无用户表态 + 统一分类
    /// 为自动低价值或未确认推断的 active 记录 → 收进历史。
    /// 分类闸（reliableUserStatement 等）本身就是保护边界：用户原话、
    /// 已确认、已纠正的记录分类不会落在这两档，天然不命中。
    static func isAutoClassifiedJunk(_ record: HoloMemoryRecord) -> Bool {
        guard isSweepableBaseline(record) else { return false }
        switch HoloKnowledgeLegacyAdapter.classify(record) {
        case .autoLowValue, .autoInferenceUnconfirmed:
            return true
        default:
            return false
        }
    }

    static func shouldSweep(_ record: HoloMemoryRecord) -> Bool {
        record.state == .active
            && (isSingleExpenseFlow(record)
                || isSingleDayCheckinFragment(record)
                || isAutoClassifiedJunk(record))
    }

    /// 保护边界：用户有过明确决定的、敏感内容的一律不碰。
    private static func isSweepableBaseline(_ record: HoloMemoryRecord) -> Bool {
        record.userDecision == .none && record.sensitivity == .normal
    }

    private static func matchesSingleExpensePhrase(_ summary: String) -> Bool {
        summary.range(
            of: "(有一笔|记录了一笔|记录了多笔|又一笔|记录了).{0,40}(支出|消费)",
            options: .regularExpression
        ) != nil
    }
}
