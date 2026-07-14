//
//  HoloDomainMemoryObservation.swift
//  Holo
//
//  各业务模块共享的结构化信号、观察包与模型输出契约。
//

import Foundation

nonisolated enum HoloDomainSignalKind: String, Codable, CaseIterable, Sendable {
    case entity
    case aggregate
    case trend
    case explicitUserText
}

nonisolated struct HoloDomainMemorySignal: Codable, Equatable, Sendable {
    var id: String
    var domain: HoloMemoryDomain
    var kind: HoloDomainSignalKind
    var evidence: HoloMemoryEvidenceRef
    var anchors: [HoloMemoryAnchorRef]
    var numericFacts: [String: Double]
    var prohibitedInferences: [String]
    /// 用户原文只作为 JSON 数据字段传输，永远不参与 system instruction 拼接。
    var userText: String?
    /// 仅当用户明确表达立场时填写，与普通原文分开。
    var explicitUserStance: String?
    /// AI 生成的摘要只能辅助表达，不能替代 evidence。
    var aiSummary: String?
}

nonisolated struct HoloDomainObservationPackage: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var domain: HoloMemoryDomain
    var window: HoloMemoryObservationWindow
    var signals: [HoloDomainMemorySignal]
    var existingMemories: [HoloMemoryRecord]
    var allowedClaimKinds: [HoloMemoryClaimKind]
    var allowedAnchorTypes: [HoloMemoryAnchorType]
}

nonisolated struct HoloDomainObservationRequest: Equatable, Sendable {
    var systemInstruction: String
    var userDataJSON: String
}

nonisolated struct HoloDomainMemoryCandidateOutput: Codable, Equatable, Sendable {
    var domain: HoloMemoryDomain
    var claimKind: HoloMemoryClaimKind
    var persistenceClass: HoloMemoryPersistenceClass
    var displaySummary: String
    var aiUseSummary: String
    var anchors: [HoloMemoryAnchorRef]
    var evidenceIDs: [String]
    var prohibitedInferences: [String]
    var requestedActions: [String]?

    init(
        domain: HoloMemoryDomain,
        claimKind: HoloMemoryClaimKind,
        persistenceClass: HoloMemoryPersistenceClass,
        displaySummary: String,
        aiUseSummary: String,
        anchors: [HoloMemoryAnchorRef],
        evidenceIDs: [String],
        prohibitedInferences: [String],
        requestedActions: [String]? = nil
    ) {
        self.domain = domain
        self.claimKind = claimKind
        self.persistenceClass = persistenceClass
        self.displaySummary = displaySummary
        self.aiUseSummary = aiUseSummary
        self.anchors = anchors
        self.evidenceIDs = evidenceIDs
        self.prohibitedInferences = prohibitedInferences
        self.requestedActions = requestedActions
    }
}

nonisolated struct HoloDomainCounterEvidenceOutput: Codable, Equatable, Sendable {
    var memoryID: String
    var evidenceIDs: [String]
}

nonisolated struct HoloDomainSupersedeOutput: Codable, Equatable, Sendable {
    var memoryID: String
    var replacementMemoryID: String
}

nonisolated struct HoloDomainMemoryOutputEnvelope: Codable, Equatable, Sendable {
    var candidates: [HoloDomainMemoryCandidateOutput]
    var counterEvidence: [HoloDomainCounterEvidenceOutput]?
    var supersedes: [HoloDomainSupersedeOutput]?

    init(
        candidates: [HoloDomainMemoryCandidateOutput],
        counterEvidence: [HoloDomainCounterEvidenceOutput]? = nil,
        supersedes: [HoloDomainSupersedeOutput]? = nil
    ) {
        self.candidates = candidates
        self.counterEvidence = counterEvidence
        self.supersedes = supersedes
    }
}

nonisolated enum HoloDomainMemoryValidationRejection: String, Equatable, Sendable {
    case malformedJSON
    case forbiddenInstruction
    case domainMismatch
    case claimKindNotAllowed
    case forgedEvidence
    case forgedAnchor
    case invalidSummary
    case invalidExistingMemoryOperation
    case invalidRecord
}

nonisolated struct HoloDomainMemoryValidationResult: Equatable, Sendable {
    var validRecords: [HoloMemoryRecord]
    var rejections: [HoloDomainMemoryValidationRejection]
}
