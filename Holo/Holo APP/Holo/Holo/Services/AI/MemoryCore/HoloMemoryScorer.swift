//
//  HoloMemoryScorer.swift
//  Holo
//
//  分离成立置信度、新鲜度与召回相关度
//

import Foundation

struct HoloMemoryConfidenceInput: Equatable, Sendable {
    var sourceReliability: Double
    var evidenceCoverage: Double
    var crossCycleConsistency: Double
    var independentEvidenceCount: Int
    var counterEvidenceCount: Int
    var userDecision: HoloMemoryUserDecision
}

struct HoloMemoryRankedScore: Equatable, Sendable {
    var memoryID: String
    var value: Double
    var scoringVersion: Int
}

enum HoloMemoryScoringError: Error, Equatable {
    case incomparableVersions
}

enum HoloMemoryScorer {
    static let currentVersion = 2

    static func confidence(_ input: HoloMemoryConfidenceInput) -> Double {
        let evidenceBoost = min(1, 0.55 + Double(max(0, input.independentEvidenceCount)) * 0.12)
        let counterPenalty = pow(0.75, Double(max(0, input.counterEvidenceCount)))
        let userMultiplier: Double
        switch input.userDecision {
        case .none:
            userMultiplier = 1
        case .confirmed:
            userMultiplier = 1.15
        case .corrected:
            userMultiplier = 1.2
        case .markedIrrelevant:
            userMultiplier = 0.7
        case .rejected:
            userMultiplier = 0.25
        case .forgotten:
            userMultiplier = 0
        }

        return clamp(
            clamp(input.sourceReliability) *
            clamp(input.evidenceCoverage) *
            clamp(input.crossCycleConsistency) *
            evidenceBoost *
            counterPenalty *
            userMultiplier
        )
    }

    static func freshness(
        persistenceClass: HoloMemoryPersistenceClass,
        lastSupportedAt: Date?,
        now: Date
    ) -> Double {
        guard persistenceClass != .permanentFact else { return 1 }
        guard let lastSupportedAt else { return 0 }
        let ageInDays = max(0, now.timeIntervalSince(lastSupportedAt) / 86_400)
        let halfLifeDays: Double
        switch persistenceClass {
        case .currentState:
            halfLifeDays = 14
        case .phase:
            halfLifeDays = 60
        case .durable:
            halfLifeDays = 150
        case .permanentFact:
            return 1
        }
        return pow(0.5, ageInDays / halfLifeDays)
    }

    static func recallScore(
        relevance: Double,
        freshness: Double,
        confidence: Double,
        contextApplicability: Double
    ) -> Double {
        clamp(relevance) *
        clamp(freshness) *
        clamp(confidence) *
        clamp(contextApplicability)
    }

    static func isHigherRanked(
        _ lhs: HoloMemoryRankedScore,
        than rhs: HoloMemoryRankedScore
    ) throws -> Bool {
        guard lhs.scoringVersion == rhs.scoringVersion else {
            throw HoloMemoryScoringError.incomparableVersions
        }
        if lhs.value == rhs.value { return lhs.memoryID < rhs.memoryID }
        return lhs.value > rhs.value
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
