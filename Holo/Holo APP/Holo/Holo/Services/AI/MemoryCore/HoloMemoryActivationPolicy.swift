//
//  HoloMemoryActivationPolicy.swift
//  Holo
//
//  统一决定校验通过的记忆是自动采用、等待确认还是拒绝写入。
//

import Foundation

enum HoloMemoryActivationDecision: Equatable, Sendable {
    case activateAutomatically(HoloMemoryAdoptionReason)
    case requiresConfirmation(HoloMemoryAdoptionReason)
    case discard
}

/// 过滤“统计上成立、但不足以改变未来回答”的低价值记忆，并让旧版本误判退出展示与召回。
nonisolated enum HoloMemoryUsefulnessPolicy {
    static func isEligible(_ record: HoloMemoryRecord) -> Bool {
        // 用户明确确认或纠正过的内容优先于自动质量门，不静默撤销用户决定。
        if [.confirmed, .corrected].contains(record.userDecision) {
            return true
        }

        let lineages = record.evidenceRefs.map(\.lineageKey)
        if lineages.contains(where: {
            $0.hasPrefix("finance-repeated-category-") ||
            $0.hasPrefix("finance-repeated-merchant-") ||
            $0 == "task-completion-rhythm"
        }) {
            return false
        }

        if record.sourceDomains.contains(.finance),
           record.evidenceRefs.contains(where: {
               $0.lineageKey.hasPrefix("finance-fixed-expense-") &&
               ($0.sampleCount ?? 0) > 8
           }) {
            return false
        }

        if record.sourceDomains.contains(.task) {
            let text = record.displaySummary + "\n" + record.aiUseSummary
            if text.contains("无逾期") {
                return false
            }
            let activityOnlyLineages = ["task-completion-activity", "task-open-backlog"]
            let unsupportedClaims = ["节奏稳定", "稳定完成", "按时完成", "完成稳定"]
            if lineages.contains(where: { activityOnlyLineages.contains($0) }),
               unsupportedClaims.contains(where: { text.contains($0) }) {
                return false
            }
        }
        return true
    }
}

/// 记忆在用户界面的统一可见口径：收件箱计数与长廊列表分组共用同一把尺子，保证两边数字一致。
nonisolated enum HoloMemoryUserVisibility {
    static func isVisible(_ record: HoloMemoryRecord) -> Bool {
        guard HoloMemoryUsefulnessPolicy.isEligible(record) else { return false }
        if record.userDecision == .rejected { return record.state == .suppressed }
        guard [HoloMemoryState.candidate, .active, .disputed, .invalidated, .archived].contains(record.state) else {
            return false
        }
        return ![HoloMemoryUserDecision.forgotten, .markedIrrelevant].contains(record.userDecision)
    }

    /// 「想和你确认的」队列成员：委托 HoloMemoryAttentionPolicy 统一判定（方案 §11.3：
    /// 打扰判断必须包含产品口径与 admission/attention 语义，禁止再单独用 state == candidate）。
    static func isPendingConfirmation(_ record: HoloMemoryRecord) -> Bool {
        HoloMemoryAttentionPolicy.requiresDailyConfirmation(record)
    }
}

nonisolated enum HoloMemoryActivationPolicy {
    /// v4 启用时决策与元数据版本随 DecisionPolicy；关闭（回滚）回到 v3 口径。
    static var currentVersion: Int {
        HoloMemoryDecisionPolicy.isEnabled ? HoloMemoryDecisionPolicy.currentVersion : 3
    }

    static func evaluate(
        _ record: HoloMemoryRecord,
        isFirstCrossDomainInference: Bool = false,
        now: Date = Date()
    ) -> HoloMemoryActivationDecision {
        guard HoloMemoryDecisionPolicy.isEnabled else {
            return legacyEvaluate(record, isFirstCrossDomainInference: isFirstCrossDomainInference)
        }
        let legacy = legacyEvaluate(record, isFirstCrossDomainInference: isFirstCrossDomainInference)
        let decision = HoloMemoryDecisionPolicy.evaluate(record, now: now)
        recordShadowDiff(legacy: legacy, decision: decision)
        switch decision.route {
        case .factEligible, .qualifiedAdvice:
            return .activateAutomatically(adoptionReason(for: decision))
        case .observeOnly, .askWhenRelevant:
            // 保持 candidate 生命周期但不构成用户任务（每日收件箱已下线，P1）。
            return .requiresConfirmation(adoptionReason(for: decision))
        case .discard:
            return .discard
        }
    }

    static func apply(
        to record: HoloMemoryRecord,
        isFirstCrossDomainInference: Bool = false,
        now: Date
    ) -> HoloMemoryRecord? {
        guard HoloMemoryDecisionPolicy.isEnabled else {
            return legacyApply(to: record, isFirstCrossDomainInference: isFirstCrossDomainInference, now: now)
        }
        let decision = HoloMemoryDecisionPolicy.evaluate(record, now: now)
        guard var updated = HoloMemoryDecisionPolicy.attach(decision, to: record, now: now) else {
            return nil
        }
        updated.adoptionMetadata = HoloMemoryAdoptionMetadata(
            policyVersion: HoloMemoryDecisionPolicy.currentVersion,
            disposition: updated.state == .active ? .automatic : .pendingConfirmation,
            reason: adoptionReason(for: decision),
            evaluatedAt: now
        )
        return updated
    }

    /// shadow：v3/v4 双算只记 metadata 差异，不改状态（方案 §18.1 灰度第 1 步）。
    private static func recordShadowDiff(
        legacy: HoloMemoryActivationDecision,
        decision: HoloMemoryFiveWayDecision
    ) {
        #if !HOLO_MEMORY_STANDALONE
        guard HoloMemoryDecisionPolicy.isShadowLoggingEnabled else { return }
        let legacyRoute: String
        switch legacy {
        case .activateAutomatically: legacyRoute = "activate"
        case .requiresConfirmation: legacyRoute = "confirm"
        case .discard: legacyRoute = "discard"
        }
        let agrees: Bool
        switch (legacy, decision.route) {
        case (.activateAutomatically, .factEligible), (.activateAutomatically, .qualifiedAdvice):
            agrees = true
        case (.requiresConfirmation, .observeOnly), (.requiresConfirmation, .askWhenRelevant):
            agrees = true
        case (.discard, .discard):
            agrees = true
        default:
            agrees = false
        }
        Task {
            await HoloMemoryQualityMetrics.shared.recordShadowDecision(
                legacyRoute: legacyRoute,
                v4Route: decision.route,
                agrees: agrees
            )
        }
        #endif
    }

    private static func adoptionReason(for decision: HoloMemoryFiveWayDecision) -> HoloMemoryAdoptionReason {
        switch decision.route {
        case .factEligible, .qualifiedAdvice:
            if decision.reasonCodes.contains(.explicitlyRequestedMemory) {
                return .explicitUserConfirmation
            }
            return .normalValidatedMemory
        case .observeOnly, .askWhenRelevant:
            return .hypothesis
        case .discard:
            return .hypothesis
        }
    }

    // MARK: - v3 回滚矩阵（原实现原样保留；回滚=UserDefaults 写 false）

    static func legacyEvaluate(
        _ record: HoloMemoryRecord,
        isFirstCrossDomainInference: Bool
    ) -> HoloMemoryActivationDecision {
        guard HoloMemoryUsefulnessPolicy.isEligible(record),
              !record.evidenceRefs.isEmpty,
              !record.displaySummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.aiUseSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .discard
        }

        // v2：健康域客观数据不再一律视为敏感，仅保留显式敏感标记需确认
        if record.sensitivity != .normal {
            return .requiresConfirmation(.sensitiveMemory)
        }
        if record.primaryDomain == .profile ||
            record.sourceDomains.contains(.profile) ||
            record.anchorRefs.contains(where: { $0.type == .profile }) {
            return .requiresConfirmation(.profileOrIdentity)
        }
        if record.persistenceClass == .permanentFact || record.claimKind == .lifeEvent {
            return .requiresConfirmation(.permanentFact)
        }
        if record.claimKind == .hypothesis {
            return .requiresConfirmation(.hypothesis)
        }
        if record.scope == .crossDomain, isFirstCrossDomainInference {
            return .requiresConfirmation(.firstCrossDomainInference)
        }
        if record.scope == .crossDomain {
            return .activateAutomatically(.repeatedCrossDomainInference)
        }
        return .activateAutomatically(.normalValidatedMemory)
    }

    static func legacyApply(
        to record: HoloMemoryRecord,
        isFirstCrossDomainInference: Bool,
        now: Date
    ) -> HoloMemoryRecord? {
        var updated = record
        switch legacyEvaluate(record, isFirstCrossDomainInference: isFirstCrossDomainInference) {
        case .discard:
            return nil
        case .activateAutomatically(let reason):
            updated.state = .active
            updated.adoptionMetadata = HoloMemoryAdoptionMetadata(
                policyVersion: 3,
                disposition: .automatic,
                reason: reason,
                evaluatedAt: now
            )
        case .requiresConfirmation(let reason):
            updated.state = .candidate
            updated.adoptionMetadata = HoloMemoryAdoptionMetadata(
                policyVersion: 3,
                disposition: .pendingConfirmation,
                reason: reason,
                evaluatedAt: now
            )
        }
        return updated
    }
}

nonisolated enum HoloMemoryRecallPolicy {
    enum ExclusionReason: String, Sendable {
        case stateNotActive
        case expired
        case freshnessBelowThreshold
        case lowValueOrUnsupported
        case useLevelRestricted
    }

    static let refreshFreshnessThreshold = 0.35
    static let minimumFreshness = 0.20
    static let minimumRecallScore = 0.08

    static func effectiveFreshness(for record: HoloMemoryRecord, now: Date) -> Double {
        min(
            record.freshnessScore,
            HoloMemoryScorer.freshness(
                persistenceClass: record.persistenceClass,
                lastSupportedAt: record.lastSupportedAt,
                now: now
            )
        )
    }

    static func isExpired(_ record: HoloMemoryRecord, now: Date) -> Bool {
        record.expiresAt.map { $0 <= now } ?? false
    }

    static func isEligible(_ record: HoloMemoryRecord, now: Date) -> Bool {
        exclusionReason(for: record, now: now) == nil
    }

    static func exclusionReason(
        for record: HoloMemoryRecord,
        now: Date
    ) -> ExclusionReason? {
        guard record.state == .active else { return .stateNotActive }
        guard HoloMemoryUsefulnessPolicy.isEligible(record) else {
            return .lowValueOrUnsupported
        }
        // 五路决策使用权限（§11.2）：普通事实召回只放行 factEligible；
        // 元数据缺失=旧记录按旧口径；不可靠解码/其余等级一律保守拦截。
        if let v2 = record.decisionMetadata?.v2 {
            guard v2.isReliablyDecoded, v2.useLevel == .factEligible else {
                return .useLevelRestricted
            }
        }
        guard !isExpired(record, now: now) else { return .expired }
        guard effectiveFreshness(for: record, now: now) >= minimumFreshness else {
            return .freshnessBelowThreshold
        }
        return nil
    }

    static func needsRefresh(_ record: HoloMemoryRecord, now: Date) -> Bool {
        isExpired(record, now: now) ||
            effectiveFreshness(for: record, now: now) < refreshFreshnessThreshold
    }
}
