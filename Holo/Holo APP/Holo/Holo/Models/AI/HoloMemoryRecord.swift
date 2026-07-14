//
//  HoloMemoryRecord.swift
//  Holo
//
//  领域记忆与跨域记忆共享的统一契约
//

import Foundation

enum HoloMemoryScope: String, Codable, CaseIterable, Sendable {
    case domain
    case crossDomain
}

enum HoloMemoryDomain: String, Codable, CaseIterable, Comparable, Sendable {
    case finance
    case thought
    case health
    case habit
    case task
    case goal
    case conversation
    case profile

    static func < (lhs: HoloMemoryDomain, rhs: HoloMemoryDomain) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum HoloMemoryClaimKind: String, Codable, CaseIterable, Sendable {
    case observedFact
    case recurringPattern
    case phaseShift
    case association
    case tension
    case hypothesis
    case explicitPreference
    case lifeEvent
}

enum HoloMemoryPersistenceClass: String, Codable, CaseIterable, Sendable {
    case currentState
    case phase
    case durable
    case permanentFact
}

enum HoloMemoryState: String, Codable, CaseIterable, Sendable {
    case candidate
    case active
    case disputed
    case superseded
    case invalidated
    case archived
    case suppressed
    case tombstoned
    case deleted
}

enum HoloMemoryUserDecision: String, Codable, CaseIterable, Sendable {
    case none
    case confirmed
    case corrected
    case markedIrrelevant
    case rejected
    case forgotten
}

enum HoloMemorySchemaError: Error, Equatable, CustomStringConvertible {
    case emptyAnchorValue
    case missingCanonicalAnchor
    case invalidDomainScope
    case invalidCrossDomainScope
    case missingSummary
    case missingEvidence
    case invalidScore
    case invalidVersion
    case mismatchedStableID

    var description: String {
        switch self {
        case .emptyAnchorValue: return "anchor value 不能为空"
        case .missingCanonicalAnchor: return "记忆至少需要一个 canonical anchor"
        case .invalidDomainScope: return "领域记忆只能包含一个 primaryDomain"
        case .invalidCrossDomainScope: return "跨域记忆至少需要两个独立领域"
        case .missingSummary: return "可用记忆必须包含摘要"
        case .missingEvidence: return "可用记忆必须包含可追溯证据"
        case .invalidScore: return "记忆分数必须位于 0...1"
        case .invalidVersion: return "Schema 与算法版本必须为正数"
        case .mismatchedStableID: return "记忆 ID 与 canonical identity 不一致"
        }
    }
}

struct HoloMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var scope: HoloMemoryScope
    var primaryDomain: HoloMemoryDomain?
    var sourceDomains: [HoloMemoryDomain]
    /// 仅供可读与检索辅助，不参与稳定身份。
    var subjectKey: String
    var anchorRefs: [HoloMemoryAnchorRef]
    var claimKind: HoloMemoryClaimKind
    var persistenceClass: HoloMemoryPersistenceClass

    var displaySummary: String
    var aiUseSummary: String
    var prohibitedInferences: [String]

    var evidenceRefs: [HoloMemoryEvidenceRef]
    var upstreamMemoryIDs: [String]
    var counterEvidenceRefs: [HoloMemoryEvidenceRef]

    var validFrom: Date?
    var validTo: Date?
    var lastSupportedAt: Date?
    var expiresAt: Date?

    var confidenceScore: Double
    var freshnessScore: Double
    var scoringVersion: Int
    var scoreComputedAt: Date
    var extractorVersion: Int
    var promptVersion: Int
    var lastObservationKey: String?
    var state: HoloMemoryState
    var sensitivity: HoloMemorySensitivity
    var userDecision: HoloMemoryUserDecision

    var recordVersion: Int
    var predecessorVersionID: String?
    var supersedesMemoryID: String?
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int

    init(
        id: String,
        scope: HoloMemoryScope,
        primaryDomain: HoloMemoryDomain?,
        sourceDomains: [HoloMemoryDomain],
        subjectKey: String,
        anchorRefs: [HoloMemoryAnchorRef],
        claimKind: HoloMemoryClaimKind,
        persistenceClass: HoloMemoryPersistenceClass,
        displaySummary: String,
        aiUseSummary: String,
        prohibitedInferences: [String],
        evidenceRefs: [HoloMemoryEvidenceRef],
        upstreamMemoryIDs: [String],
        counterEvidenceRefs: [HoloMemoryEvidenceRef],
        validFrom: Date? = nil,
        validTo: Date? = nil,
        lastSupportedAt: Date? = nil,
        expiresAt: Date? = nil,
        confidenceScore: Double,
        freshnessScore: Double,
        scoringVersion: Int,
        scoreComputedAt: Date,
        extractorVersion: Int,
        promptVersion: Int,
        lastObservationKey: String? = nil,
        state: HoloMemoryState,
        sensitivity: HoloMemorySensitivity,
        userDecision: HoloMemoryUserDecision,
        recordVersion: Int = 1,
        predecessorVersionID: String? = nil,
        supersedesMemoryID: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.scope = scope
        self.primaryDomain = primaryDomain
        self.sourceDomains = sourceDomains
        self.subjectKey = subjectKey
        self.anchorRefs = anchorRefs
        self.claimKind = claimKind
        self.persistenceClass = persistenceClass
        self.displaySummary = displaySummary
        self.aiUseSummary = aiUseSummary
        self.prohibitedInferences = prohibitedInferences
        self.evidenceRefs = evidenceRefs
        self.upstreamMemoryIDs = upstreamMemoryIDs
        self.counterEvidenceRefs = counterEvidenceRefs
        self.validFrom = validFrom
        self.validTo = validTo
        self.lastSupportedAt = lastSupportedAt
        self.expiresAt = expiresAt
        self.confidenceScore = confidenceScore
        self.freshnessScore = freshnessScore
        self.scoringVersion = scoringVersion
        self.scoreComputedAt = scoreComputedAt
        self.extractorVersion = extractorVersion
        self.promptVersion = promptVersion
        self.lastObservationKey = lastObservationKey
        self.state = state
        self.sensitivity = sensitivity
        self.userDecision = userDecision
        self.recordVersion = recordVersion
        self.predecessorVersionID = predecessorVersionID
        self.supersedesMemoryID = supersedesMemoryID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    func validate() throws {
        let anchors = HoloMemoryIdentity.canonicalAnchors(anchorRefs)
        guard !anchors.isEmpty else { throw HoloMemorySchemaError.missingCanonicalAnchor }

        let domains = Array(Set(sourceDomains)).sorted()
        switch scope {
        case .domain:
            guard let primaryDomain,
                  domains == [primaryDomain] else {
                throw HoloMemorySchemaError.invalidDomainScope
            }
        case .crossDomain:
            guard primaryDomain == nil,
                  domains.count >= 2,
                  Set(upstreamMemoryIDs).count >= 2 else {
                throw HoloMemorySchemaError.invalidCrossDomainScope
            }
        }

        if ![HoloMemoryState.tombstoned, .deleted, .suppressed].contains(state) {
            guard !displaySummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !aiUseSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HoloMemorySchemaError.missingSummary
            }
            guard !evidenceRefs.isEmpty else { throw HoloMemorySchemaError.missingEvidence }
        }

        guard (0...1).contains(confidenceScore),
              (0...1).contains(freshnessScore) else {
            throw HoloMemorySchemaError.invalidScore
        }
        guard schemaVersion > 0,
              recordVersion > 0,
              scoringVersion > 0,
              extractorVersion > 0,
              promptVersion > 0 else {
            throw HoloMemorySchemaError.invalidVersion
        }
        guard id == (try HoloMemoryIdentity.makeStableID(for: self)) else {
            throw HoloMemorySchemaError.mismatchedStableID
        }
    }

    var versionID: String { "\(id)@v\(recordVersion)" }
}
