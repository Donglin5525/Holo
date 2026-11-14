//
//  SufficiencyPolicy.swift
//  Holo
//
//  理解引擎 M2.9：证据水位政策（2026-11-15 东林拍板「数据分层水位」——
//  打卡 2 天和打卡 90 天不得产出同级理解）。
//
//  通用抽象：命题类型 × 知信轨 → 最低证据要求（规则类标签的阈值口径）。
//  不是任何单一域的特判——戒烟/养猫/重复行为全走同一张水位表。
//
//  知信轨来自方案 §4.2「根据什么知道」三档：
//    stated   轨——用户明确自述（quote 原话），一次即足（「开始上夜班」§3）；
//    recorded 轨——行为记录（打卡/交易），需广度+深度水位；
//    inferred ——AI 派生不构成充分性（同源非独立原则，M1.1 caseA），预留枚举。
//  关联类不开 stated 轨：用户主观归因（「我觉得咖啡影响睡眠」）保存为 quote
//  证据，不升级为因果命题（§5.2 咖啡案例）。
//

import Foundation

// MARK: - 三标记枚举（方案 §4.2）

/// 知信来源三档（「根据什么知道」）。
nonisolated enum EpistemicProvenance: String, Codable, Sendable, Equatable {
    case stated     // 用户明确说过（quote 原话）
    case recorded   // 记录直接显示（打卡/交易）
    case inferred   // 系统推断（预留：当前引擎无纯推断证据源）
}

/// 时效档（「适用于什么时候」）。
nonisolated enum EpistemicValidity: String, Codable, Sendable, Equatable {
    case moment        // 某次事件（预留）
    case phase         // 最近阶段（戒烟期/夜班期——断证自然过期）
    case enduring      // 持续有效（角色/偏好）
    case conditional   // 特定条件下有效（关联命题）
}

/// 使用范围档（「可以怎样使用」）。proactive 由「一个发现」通道授予，
/// 理解引擎最高只授 explicitBackground——主动展示不是理解的职责。
nonisolated enum EpistemicUsage: String, Codable, Sendable, Equatable {
    case internalOnly        // 仅内部观察
    case limitedReference    // 可有限参考（预留：弱证据采用）
    case explicitBackground  // 可作为明确背景
    case proactive           // 可以主动展示（发现通道专属，本引擎不授）

    /// 使用范围由台账终态推导：adoptable=可作为明确背景（影子期仍不自动使用）；
    /// observing/askWhenRelevant=仅内部观察（补问在途不算可用认识）；
    /// 拒绝/失效无使用价值。M3 上岗注入按 usage ≥ explicitBackground 放行。
    static func forStage(_ stage: ShadowStage) -> EpistemicUsage? {
        switch stage {
        case .adoptable: return .explicitBackground
        case .observing, .askWhenRelevant: return .internalOnly
        default: return nil
        }
    }
}

// MARK: - 水位政策

/// 一类命题的最低证据充分度要求。nil = 不要求该维度。
nonisolated struct SufficiencyPolicy: Sendable, Equatable {
    /// stated 轨达标条数（nil=该类不开自述轨——用户说了也不单独算数）。
    var statedMinCount: Int?
    /// recorded 轨：独立来源数下限。
    var recordedMinSources: Int?
    /// recorded 轨：需本人归属证据。
    var recordedRequiresSelf: Bool
    /// recorded 轨：行为证据时间跨度下限（天）。
    var recordedMinSpanDays: Int?
    /// recorded 轨：行为证据次数下限。
    var recordedMinOccurrences: Int?
    /// 跨域数下限（关联类专用维度）。
    var minDomains: Int?

    /// v1 水位表（2026-11-15 拍板）。数值是产品口径不是物理定律，集中此处可调。
    static func policy(for kind: ProposalCandidate.ClaimKind) -> SufficiencyPolicy {
        switch kind {
        case .role:
            // 猫粮案例（§5.1）：纯行为要「多源+跨度+归属」——短期重复可能是代购，
            // 次数解决不了归属；用户自述「我养猫」一条即足（自证豁免广度深度）。
            return SufficiencyPolicy(
                statedMinCount: 1,
                recordedMinSources: 2,
                recordedRequiresSelf: true,
                recordedMinSpanDays: 30,
                recordedMinOccurrences: 3,
                minDomains: nil)
        case .preference:
            // 偏好：自述一次即足；行为轨需同类选择重复出现 ≥3 次。
            return SufficiencyPolicy(
                statedMinCount: 1,
                recordedMinSources: nil,
                recordedRequiresSelf: false,
                recordedMinSpanDays: nil,
                recordedMinOccurrences: 3,
                minDomains: nil)
        case .recurringBehavior:
            // 「每周打羽毛球」需 ≥30 天跨度且 ≥3 次——21 天 3 次只是线索
            //（§3「日常消费重复三次，并不自动等于值得展示」）。
            return SufficiencyPolicy(
                statedMinCount: 1,
                recordedMinSources: nil,
                recordedRequiresSelf: false,
                recordedMinSpanDays: 30,
                recordedMinOccurrences: 3,
                minDomains: nil)
        case .phaseState:
            // 阶段水位（2026-11-15 东林命中缺口）：行为轨需持续 ≥14 天且 ≥10 次
            //——打卡 2 天不得产出「正在戒烟」同级理解；自述「开始上夜班」一次即足（§3）。
            return SufficiencyPolicy(
                statedMinCount: 1,
                recordedMinSources: nil,
                recordedRequiresSelf: false,
                recordedMinSpanDays: 14,
                recordedMinOccurrences: 10,
                minDomains: nil)
        case .conditionalAssociation:
            // 不开自述轨（§5.2）；跨 ≥2 域保持，深度由备择解释+强度封顶兜底。
            return SufficiencyPolicy(
                statedMinCount: nil,
                recordedMinSources: nil,
                recordedRequiresSelf: false,
                recordedMinSpanDays: nil,
                recordedMinOccurrences: nil,
                minDomains: 2)
        }
    }

    /// 命题类型中文标签（闸理由文案用，与历史文案同款）。
    static func kindLabel(_ kind: ProposalCandidate.ClaimKind) -> String {
        switch kind {
        case .role: return "角色类"
        case .preference: return "偏好类"
        case .recurringBehavior: return "重复行为类"
        case .phaseState: return "阶段类"
        case .conditionalAssociation: return "关联类"
        }
    }
}

// MARK: - 判定

nonisolated enum Sufficiency {

    /// stated 轨证据：用户原话且归属非代办/第三方（代办备注是用户的话，
    /// 但内容否定本人归属——「帮同事带的」不构成自证）。
    static func statedEvidence(in cited: [LifeObservation]) -> [LifeObservation] {
        cited.filter {
            $0.businessState == .quote && $0.attribution != .proxy && $0.attribution != .thirdParty
        }
    }

    /// recorded 轨证据：非派生行为记录（derived 不算——同源非独立，M1.1 caseA）。
    /// 发生时间不可信（midnightDefault）或不可知（nil）的不进深度计算。
    static func behavioralEvidence(in cited: [LifeObservation]) -> [LifeObservation] {
        cited.filter { $0.businessState != .derived }
    }

    static func timedEvidence(in cited: [LifeObservation]) -> [LifeObservation] {
        cited.filter { obs in
            obs.businessState != .derived
                && obs.occurredAt != nil
                && obs.timePrecision != .midnightDefault
        }
    }

    /// 水位判定：stated 轨达标即足（用户自证豁免其余维度）；否则 recorded 轨
    /// 全维度须满足。返回缺口理由（空=达标）。降级不拒——有价值线索保留观察。
    static func gaps(cited: [LifeObservation], policy: SufficiencyPolicy, kindLabel: String) -> [String] {
        if let need = policy.statedMinCount, statedEvidence(in: cited).count >= need {
            return []
        }
        let behavioral = behavioralEvidence(in: cited)
        var gaps: [String] = []
        if let need = policy.minDomains {
            let domains = Set(behavioral.map(\.domain))
            if domains.count < need {
                gaps.append("证据闸[\(kindLabel)需跨≥\(need)域证据，现\(domains.count)]")
            }
        }
        if let need = policy.recordedMinSources {
            let sources = Set(behavioral.map(\.sourceRef))
            if sources.count < need {
                gaps.append("证据闸[\(kindLabel)需≥\(need)独立来源，现\(sources.count)]")
            }
        }
        if policy.recordedRequiresSelf {
            // 与 stated 轨同语义：quote 是本人原话的形态仅想法域（投影器保证）；
            // 代办备注（quote 文本+proxy 归属）否定本人归属，不算本人证据。
            let selfOwned = behavioral.contains {
                $0.attribution == .self_
                    || ($0.businessState == .quote && $0.attribution != .proxy && $0.attribution != .thirdParty)
            }
            if !selfOwned {
                gaps.append("证据闸[\(kindLabel)缺本人归属证据(备注代办/归属未知不构成)]")
            }
        }
        let timed = timedEvidence(in: cited)
        let occ = timed.count
        let span = spanDays(of: timed)
        if let spanNeed = policy.recordedMinSpanDays, span < spanNeed {
            gaps.append("证据闸[\(kindLabel)需持续≥\(spanNeed)天行为证据，现跨度\(span)天]")
        }
        if let occNeed = policy.recordedMinOccurrences, occ < occNeed {
            gaps.append("证据闸[\(kindLabel)需≥\(occNeed)次行为证据，现\(occ)次]")
        }
        return gaps
    }

    /// 行为证据时间跨度（天，向下取整）。不足两个时间点=0。
    static func spanDays(of timed: [LifeObservation]) -> Int {
        let dates = timed.compactMap(\.occurredAt).sorted()
        guard dates.count >= 2 else { return 0 }
        return Int(dates.last!.timeIntervalSince(dates.first!) / 86_400)
    }
}

// MARK: - 认识标记推导（台账三标记的来源）

nonisolated enum EpistemicTags {

    /// 知信来源：引用证据含本人原话 → stated；纯行为记录 → recorded。
    static func provenance(cited: [LifeObservation]) -> EpistemicProvenance {
        let hasStated = !Sufficiency.statedEvidence(in: cited).isEmpty
        return hasStated ? .stated : .recorded
    }

    /// 时效：由命题类型映射（阶段/重复行为是阶段性的，断证自然过期；
    /// 角色/偏好是持续认识；关联命题条件成立才有效）。
    static func validity(kind: ProposalCandidate.ClaimKind?) -> EpistemicValidity {
        switch kind {
        case .role, .preference: return .enduring
        case .recurringBehavior, .phaseState: return .phase
        case .conditionalAssociation: return .conditional
        case nil: return .phase
        }
    }
}
