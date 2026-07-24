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

nonisolated enum HoloMemoryActivationPolicy {
    static let currentVersion = 3

    static func evaluate(
        _ record: HoloMemoryRecord,
        isFirstCrossDomainInference: Bool = false
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

    static func apply(
        to record: HoloMemoryRecord,
        isFirstCrossDomainInference: Bool = false,
        now: Date
    ) -> HoloMemoryRecord? {
        var updated = record
        switch evaluate(record, isFirstCrossDomainInference: isFirstCrossDomainInference) {
        case .discard:
            return nil
        case .activateAutomatically(let reason):
            updated.state = .active
            updated.adoptionMetadata = HoloMemoryAdoptionMetadata(
                policyVersion: currentVersion,
                disposition: .automatic,
                reason: reason,
                evaluatedAt: now
            )
        case .requiresConfirmation(let reason):
            updated.state = .candidate
            updated.adoptionMetadata = HoloMemoryAdoptionMetadata(
                policyVersion: currentVersion,
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
