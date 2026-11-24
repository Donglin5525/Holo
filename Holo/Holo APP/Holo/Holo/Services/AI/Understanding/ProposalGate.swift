//
//  ProposalGate.swift
//  Holo
//
//  理解引擎 M2.4：核验闸（07-M2施工图）。
//
//  三道纯程序闸拦截提案层的越界冲动——词表与规则全部来自 M1.2/M1.4/M1.6 实测
//  抓到的失分模式（不是设计假设）。模型给的 evidenceGrade/action 只是建议，
//  能不能用由本闸说了算（工程稿 §4）。
//

import Foundation

/// 从模型提案输出解析出的候选（形状与 M1.3 提案提示词对齐）。
nonisolated struct ProposalCandidate: Codable, Sendable, Equatable {
    var claimType: String        // role | preference | recurringBehavior | phaseState | conditionalAssociation
    var statement: String
    var supportingRefs: [String]
    var alternativeExplanations: [String]
    var whatWouldChangeTheAnswer: String?
    var evidenceGrade: String?
    var action: String           // adopt | observe | ask（模型建议）

    enum ClaimKind: String {
        case role, preference, recurringBehavior, phaseState, conditionalAssociation
    }
    var kind: ClaimKind? { ClaimKind(rawValue: claimType) }
}

/// 闸判决：passed=false 为拒绝；downgradeTo 非空为降级采用（adopt→observe）。
nonisolated struct GateVerdict: Equatable, Sendable {
    var passed: Bool
    var downgradeTo: String?
    var reasons: [String]

    static let pass = GateVerdict(passed: true, downgradeTo: nil, reasons: [])
}

nonisolated enum ProposalGate {

    // MARK: - 闸1：措辞（标准 v1.1 词表；只扫命题与用途字段，条件句部分豁免）

    /// (模式, 违规类别)。因果词不豁免——命题里的因果断言始终拦截。
    static let wordingPatterns: [(pattern: String, category: String, conditionalExempt: Bool)] = [
        ("导致|造成|引发|使得", "因果断言", false),
        ("懒|自律差|缺乏毅力|拖延症|孤僻|社恐|上瘾|成瘾|自制力差|工作狂", "人格/道德标签", false),
        ("诊断|抑郁|焦虑症|建议就医", "医疗化", true),
        ("产后", "身份默认(养育者≠生育者)", true),
        ("约?[0-9]+[-到至][0-9]+个月|[0-9]+个月(大|龄)|满[0-9]+个月", "月龄精确化", false),
        ("患者", "疾病身份断言(命题层不得用患者措辞，用户自述应转述为证据)", false),
        ("法定|负责一切|已经确认|一定是", "强度越界", false),
    ]

    static func wordingGate(_ candidate: ProposalCandidate) -> GateVerdict {
        let conditionalContext = candidate.statement.contains("若") || candidate.statement.contains("如果")
            || candidate.statement.contains("如发现") || candidate.statement.contains("假设")
        var reasons: [String] = []
        for field in [candidate.statement, candidate.whatWouldChangeTheAnswer ?? ""] {
            for rule in wordingPatterns {
                guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
                let range = NSRange(field.startIndex..., in: field)
                if regex.firstMatch(in: field, range: range) != nil {
                    // 豁免只适用于条件语境下的医疗/身份类（「若确诊X则…」是查证语言，不是断言）
                    if rule.conditionalExempt && conditionalContext { continue }
                    reasons.append("措辞闸[\(rule.category)]")
                }
            }
        }
        return reasons.isEmpty ? .pass : GateVerdict(passed: false, downgradeTo: nil, reasons: reasons)
    }

    // MARK: - 闸2：证据对照（引用回源 + 水位政策 + 细节出处）

    /// 引用必须真实存在；命题类型 × 知信轨的最低水位由 SufficiencyPolicy 统一定
    ///（2026-11-15 拍板：打卡 2 天和 90 天不得产出同级理解——旧版阶段类只查
    /// 「有引用」的缺口已补）。水位不足→降级 observe（不拒——有价值线索保留
    /// 观察，M1.6 S04-weak 的正确处理）。
    static func evidenceGate(candidate: ProposalCandidate, observations: [LifeObservation]) -> GateVerdict {
        let byRef = Dictionary(observations.map { ($0.sourceRef, $0) }, uniquingKeysWith: { first, _ in first })
        // 便捷时段计算（与 evidence 视图 timeOfDayBand 同口径）
        func band(of obs: LifeObservation) -> String {
            if obs.timePrecision == .midnightDefault { return "unknown" }
            guard let at = obs.occurredAt else { return "unknown" }
            switch Calendar.current.component(.hour, from: at) {
            case 5..<11: return "morning"
            case 11..<17: return "afternoon"
            case 17..<23: return "evening"
            default: return "night"
            }
        }
        let cited = candidate.supportingRefs.compactMap { byRef[$0] }
        // 引用编造 → 拒（不可回源的候选没有存在资格）。
        if cited.count != candidate.supportingRefs.count {
            return GateVerdict(passed: false, downgradeTo: nil, reasons: ["证据闸[引用了不存在的观察]"])
        }

        var reasons: [String] = []
        var downgrade = false
        // 水位判定（SufficiencyPolicy v1 表）。未知类型（nil）维持旧行为：无引用即降级。
        if let kind = candidate.kind {
            let gaps = Sufficiency.gaps(
                cited: cited,
                policy: SufficiencyPolicy.policy(for: kind),
                kindLabel: SufficiencyPolicy.kindLabel(kind))
            if !gaps.isEmpty {
                reasons.append(contentsOf: gaps)
                downgrade = true
            }
        } else if Set(cited.map(\.sourceRef)).isEmpty {
            reasons.append("证据闸[无有效引用]")
            downgrade = true
        }
        // BUG-7 细节出处检查（真数据实锤：美团支付记录→「深夜外卖」——渠道升格+
        // 时段脑补都无证据出处）。时段词须有任一引用证据的 timeOfDay 匹配；
        // 渠道-方式词（外卖/打车等）须在引用证据的概念或原话中出现。违反 → 降级。
        let timeWords: [(word: String, band: String)] = [
            ("深夜", "night"), ("凌晨", "night"), ("夜间", "night"), ("半夜", "night"),
            ("早上", "morning"), ("清晨", "morning"), ("上午", "morning"),
            ("下午", "afternoon"), ("傍晚", "evening"), ("晚上", "evening"), ("晚间", "evening"),
        ]
        let channelWords = ["外卖", "打车", "代驾", "配送", "上门"]
        var citedConceptAndQuote = ""
        for obs in cited {
            let conceptsText = obs.concepts.joined(separator: " ")
            let quoteText = obs.quote ?? ""
            citedConceptAndQuote += conceptsText + " " + quoteText + " "
        }
        for pair in timeWords where candidate.statement.contains(pair.word) {
            let matched = cited.contains { band(of: $0) == pair.band }
            if !matched {
                reasons.append("证据闸[时段『\(pair.word)』无对应时段证据——命题细节超出材料]")
                downgrade = true
            }
        }
        for word in channelWords where candidate.statement.contains(word) {
            if !citedConceptAndQuote.contains(word) {
                reasons.append("证据闸[渠道词『\(word)』在证据概念/原话中无出处——支付渠道不得升格为消费方式]")
                downgrade = true
            }
        }
        if downgrade {
            return GateVerdict(passed: true, downgradeTo: "observe", reasons: reasons)
        }
        return .pass
    }

    // MARK: - 闸3：强度封顶（claimType 最高档；阶段状态不受限——阶段本身即暂时）

    /// 确定档措辞出现在角色/偏好/关联类命题中 → 越档（「很可能」是这三类的顶）。
    static let cappedKinds: Set<ProposalCandidate.ClaimKind> = [.role, .preference, .conditionalAssociation]

    static func strengthGate(_ candidate: ProposalCandidate) -> GateVerdict {
        let certaintyMarkers = ["一定是", "肯定是", "就是", "已经是", "始终是", "一直是", "长期都是"]
        guard let kind = candidate.kind, cappedKinds.contains(kind) else { return .pass }
        let hits = certaintyMarkers.filter { candidate.statement.contains($0) }
        if hits.isEmpty { return .pass }
        return GateVerdict(passed: false, downgradeTo: nil,
                           reasons: ["强度闸[该类命题最高档为『很可能』，出现确定措辞:\(hits.joined(separator: ","))]"])
    }

    // MARK: - 总闸

    /// 顺序：措辞（拒）→ 强度（拒）→ 证据（降级）。返回最终 action 与理由。
    static func evaluate(candidate: ProposalCandidate, observations: [LifeObservation])
        -> (accepted: Bool, action: String, reasons: [String]) {
        for verdict in [wordingGate(candidate), strengthGate(candidate)] where !verdict.passed {
            return (false, "rejected", verdict.reasons)
        }
        let evidence = evidenceGate(candidate: candidate, observations: observations)
        // 对抗回归实抓（11-13）：证据闸的硬拒绝（引用编造不可回源）必须短路——
        // 此前该分支被吞，编造引用的候选会以 adopt 放行。
        guard evidence.passed else {
            return (false, "rejected", evidence.reasons)
        }
        let finalAction = evidence.downgradeTo
            ?? (candidate.action == "adopt" ? "adopt" : candidate.action)
        return (true, finalAction, evidence.reasons)
    }
}
