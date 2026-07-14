//
//  HoloMemoryLifecycle.swift
//  Holo
//
//  记忆支持、反例、争议、替代与用户纠正状态机
//

import Foundation

enum HoloMemoryLifecycleEvent: Equatable, Sendable {
    case supportingEvidence(HoloMemoryEvidenceRef)
    case counterEvidence(HoloMemoryEvidenceRef)
    case userConfirmed
    case superseded(byVersionID: String)
    case sourceInvalidated
    case archived
}

struct HoloMemoryCorrectionResult: Equatable, Sendable {
    var previous: HoloMemoryRecord
    var corrected: HoloMemoryRecord
}

enum HoloMemoryLifecycle {
    static func apply(
        _ event: HoloMemoryLifecycleEvent,
        to record: HoloMemoryRecord,
        now: Date = Date()
    ) -> HoloMemoryRecord {
        var updated = record
        updated.updatedAt = now

        switch event {
        case .supportingEvidence(let evidence):
            appendUnique(evidence, to: &updated.evidenceRefs)
            updated.lastSupportedAt = max(updated.lastSupportedAt ?? evidence.observedAt, evidence.observedAt)
            if updated.state == .disputed,
               independentLineageCount(updated.evidenceRefs) > independentLineageCount(updated.counterEvidenceRefs),
               updated.userDecision != .rejected,
               updated.userDecision != .forgotten {
                updated.state = .active
            }
            updated = recalculate(updated, now: now)

        case .counterEvidence(let evidence):
            appendUnique(evidence, to: &updated.counterEvidenceRefs)
            updated.confidenceScore = max(0, updated.confidenceScore * 0.75)
            updated.scoreComputedAt = now
            let counterCount = independentLineageCount(updated.counterEvidenceRefs)
            if counterCount >= 2,
               updated.userDecision != .confirmed,
               updated.userDecision != .corrected {
                updated.state = .disputed
            }

        case .userConfirmed:
            updated.userDecision = .confirmed
            updated.state = .active
            updated.confidenceScore = max(updated.confidenceScore, 0.95)
            updated.scoreComputedAt = now

        case .superseded(let replacementVersionID):
            updated.state = .superseded
            updated.supersedesMemoryID = replacementVersionID

        case .sourceInvalidated:
            updated.state = .invalidated

        case .archived:
            updated.state = .archived
        }

        return updated
    }

    static func correct(
        _ record: HoloMemoryRecord,
        displaySummary: String,
        aiUseSummary: String,
        evidence: HoloMemoryEvidenceRef,
        now: Date = Date()
    ) -> HoloMemoryCorrectionResult {
        var previous = record
        previous.state = .superseded
        previous.updatedAt = now

        var corrected = record
        corrected.recordVersion += 1
        corrected.predecessorVersionID = record.versionID
        corrected.supersedesMemoryID = record.versionID
        corrected.displaySummary = displaySummary
        corrected.aiUseSummary = aiUseSummary
        corrected.evidenceRefs = record.evidenceRefs
        appendUnique(evidence, to: &corrected.evidenceRefs)
        corrected.counterEvidenceRefs = []
        corrected.userDecision = .corrected
        corrected.state = .active
        corrected.confidenceScore = max(record.confidenceScore, 0.97)
        corrected.freshnessScore = 1
        corrected.lastSupportedAt = now
        corrected.scoreComputedAt = now
        corrected.updatedAt = now

        previous.supersedesMemoryID = corrected.versionID
        return HoloMemoryCorrectionResult(previous: previous, corrected: corrected)
    }

    static func recalculateScoresIfNeeded(
        _ record: HoloMemoryRecord,
        now: Date = Date()
    ) -> HoloMemoryRecord {
        guard record.scoringVersion != HoloMemoryScorer.currentVersion else { return record }
        return recalculate(record, now: now)
    }

    private static func recalculate(
        _ record: HoloMemoryRecord,
        now: Date
    ) -> HoloMemoryRecord {
        var updated = record
        let supportCount = independentLineageCount(record.evidenceRefs)
        let sourceReliability: Double
        if record.evidenceRefs.contains(where: { $0.kind == .explicitUserStatement }) {
            sourceReliability = 1
        } else if record.evidenceRefs.allSatisfy({ $0.kind == .aggregateSnapshot }) {
            sourceReliability = 0.9
        } else {
            sourceReliability = 0.95
        }
        updated.confidenceScore = HoloMemoryScorer.confidence(
            HoloMemoryConfidenceInput(
                sourceReliability: sourceReliability,
                evidenceCoverage: min(1, Double(supportCount) / 3),
                crossCycleConsistency: record.counterEvidenceRefs.isEmpty ? 1 : 0.8,
                independentEvidenceCount: supportCount,
                counterEvidenceCount: independentLineageCount(record.counterEvidenceRefs),
                userDecision: record.userDecision
            )
        )
        updated.freshnessScore = HoloMemoryScorer.freshness(
            persistenceClass: record.persistenceClass,
            lastSupportedAt: record.lastSupportedAt ?? record.updatedAt,
            now: now
        )
        updated.scoringVersion = HoloMemoryScorer.currentVersion
        updated.scoreComputedAt = now
        return updated
    }

    private static func appendUnique(
        _ evidence: HoloMemoryEvidenceRef,
        to values: inout [HoloMemoryEvidenceRef]
    ) {
        guard !values.contains(where: {
            $0.id == evidence.id || $0.lineageKey == evidence.lineageKey
        }) else { return }
        values.append(evidence)
    }

    private static func independentLineageCount(
        _ evidence: [HoloMemoryEvidenceRef]
    ) -> Int {
        Set(evidence.map(\.lineageKey)).count
    }
}
