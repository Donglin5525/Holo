//
//  HabitPhaseProposer.swift
//  Holo
//
//  理解引擎 M2.10：habit 域确定性提案器（程序直出，2026-11-15 拍板第三件事）。
//
//  习惯打卡=用户自建语义实体+主动行为，是「用户自证」（知信分层高于行为推断
//——自述与行为挖掘的权威性差异）。「习惯进行中」类阶段命题由程序按水位直出：
//  更快、零模型成本、措辞零幻觉；产出候选仍过全闸统一标准（含措辞闸——
//  habitName 含敏感词被拦是特性：系统不复述用户可能的自我医疗化措辞）。
//
//  跨域关联（如「加班周打卡更易断」）不走直出——那需要跨域证据与备择解释，
//  仍归模型通道（M3 关联路由）。
//

import Foundation

// MARK: - 确定性提案器协议（未来其他域的自证类命题可各自实现，共用同一闸）

nonisolated protocol DeterministicProposer: Sendable {
    /// 从主题成员观察直出候选。refs 必须用真实 sourceRef（不经短编号映射——
    /// 直出不上送模型，无抄写错误风险，且全量 refs 保证水位计算不被截断）。
    func propose(themeKey: String, members: [LifeObservation], now: Date) -> [ProposalCandidate]
}

// MARK: - habit 域实现

nonisolated struct HabitPhaseProposer: DeterministicProposer {

    /// 直出至多 1 条阶段候选：
    /// 有效打卡 <3 次 → 空数组（弱信号不成命题，Runner 主条目兜底 observing）；
    /// ≥3 次 → observe 候选（线索保留）；水位足（span≥14 天且≥10 次，与
    /// SufficiencyPolicy.phaseState 同口径——直出器不另设标准）→ adopt 候选。
    /// 中断模式：打卡日序列中 ≥2 段整日中断 →「期间有反复」（戒烟反复期实证；
    /// 单次中断算正常波动不注记）。
    func propose(themeKey: String, members: [LifeObservation], now: Date) -> [ProposalCandidate] {
        let habitMembers = members.filter { $0.domain == .habit }
        guard !habitMembers.isEmpty else { return [] }
        // 习惯名=成员概念众数（habit 投影 concepts=[习惯名]；混入的个别成员以多数为准）。
        var counts: [String: Int] = [:]
        for member in habitMembers {
            for concept in member.concepts { counts[concept, default: 0] += 1 }
        }
        guard let habitName = counts.max(by: { $0.value < $1.value })?.key else { return [] }

        // 深度只用发生时间可信的打卡（midnightDefault/无时间不进水位——与闸同口径）。
        let timed = habitMembers.filter {
            $0.occurredAt != nil && $0.timePrecision != .midnightDefault
        }
        let occ = timed.count
        guard occ >= 3 else { return [] }

        let calendar = Calendar.current
        let daySet = Set(timed.map { calendar.startOfDay(for: $0.occurredAt!) })
        let sortedDays = daySet.sorted()
        let span = sortedDays.count >= 2
            ? Int(sortedDays.last!.timeIntervalSince(sortedDays.first!) / 86_400) : 0
        var breaks = 0
        for i in 1..<sortedDays.count {
            let gap = Int(sortedDays[i].timeIntervalSince(sortedDays[i - 1]) / 86_400)
            if gap >= 2 { breaks += 1 }
        }

        // 水位判定与闸同源（单一真源：SufficiencyPolicy.phaseState 政策表）——
        // 直出器不另设标准，调水位只改政策表一处。
        let phasePolicy = SufficiencyPolicy.policy(for: .phaseState)
        let sufficient = (phasePolicy.recordedMinSpanDays.map { span >= $0 } ?? true)
            && (phasePolicy.recordedMinOccurrences.map { occ >= $0 } ?? true)
        var statement = "「\(habitName)」习惯进行中"
        if breaks >= 2 { statement += "，期间有反复" }
        return [ProposalCandidate(
            claimType: "phaseState",
            statement: statement,
            supportingRefs: habitMembers.map(\.sourceRef),
            alternativeExplanations: [],
            whatWouldChangeTheAnswer: "相关问答与回顾会带上「\(habitName)」的当前阶段",
            evidenceGrade: sufficient ? "支持" : "线索",
            action: sufficient ? "adopt" : "observe"
        )]
    }
}
