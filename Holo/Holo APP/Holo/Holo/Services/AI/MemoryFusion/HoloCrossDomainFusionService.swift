//
//  HoloCrossDomainFusionService.swift
//  Holo
//
//  将模型输出视为不可信候选；本地再次核验证据、表达边界和持久化门槛。
//

import Foundation

enum HoloCrossDomainRequestedStorageClass: String, Codable, Equatable, Sendable {
    case normal
    case sensitiveLocal
}

struct HoloCrossDomainFusionOutput: Codable, Equatable, Sendable {
    var claimKind: HoloMemoryClaimKind
    var displaySummary: String
    var aiUseSummary: String
    var anchors: [HoloMemoryAnchorRef]
    var upstreamMemoryIDs: [String]
    var evidenceIDs: [String]
    var prohibitedInferences: [String]
    var requestedStorageClass: HoloCrossDomainRequestedStorageClass

    enum CodingKeys: String, CodingKey {
        case claimKind, displaySummary, aiUseSummary, anchors
        case upstreamMemoryIDs, evidenceIDs, prohibitedInferences
        case requestedStorageClass = "storageClass"
    }
}

struct HoloCrossDomainFusionOutputEnvelope: Codable, Equatable, Sendable {
    var candidates: [HoloCrossDomainFusionOutput]
}

struct HoloCrossDomainFusionRequestPackage: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var candidates: [HoloCrossDomainFusionCandidate]
}

struct HoloCrossDomainTransientMemory: Equatable, Sendable {
    var candidateIdentityKey: String
    var displaySummary: String
    var aiUseSummary: String
    var sourceDomains: [HoloMemoryDomain]
    var upstreamMemoryIDs: [String]
    var evidenceRefs: [HoloMemoryEvidenceRef]
    var sensitivity: HoloMemorySensitivity
}

enum HoloCrossDomainFusionRejection: String, Equatable, Sendable {
    case malformedJSON
    case unsupportedClaimKind
    case forgedUpstreamMemory
    case forgedEvidence
    case forgedAnchor
    case invalidSummary
    case causalOrMedicalInference
    case invalidRecord
}

enum HoloCrossDomainFusionDecision: Equatable, Sendable {
    case transient(HoloCrossDomainTransientMemory)
    case persist(HoloMemoryRecord)
    case rejected(HoloCrossDomainFusionRejection)
}

enum HoloCrossDomainFusionOperationalError: Error, Equatable {
    case disabledByKillSwitch
}

enum HoloCrossDomainFusionService {
    static let extractorVersion = 1
    static let promptVersion = 2

    static func evaluate(
        _ data: Data,
        against candidates: [HoloCrossDomainFusionCandidate],
        priorOccurrenceCounts: [String: Int] = [:],
        userConfirmedIdentityKeys: Set<String> = [],
        now: Date = Date()
    ) -> [HoloCrossDomainFusionDecision] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(
            HoloCrossDomainFusionOutputEnvelope.self,
            from: data
        ) else {
            return [.rejected(.malformedJSON)]
        }
        return envelope.candidates.map { output in
            guard let candidate = candidates.first(where: { candidate in
                Set(candidate.sourceMemoryIDs) == Set(output.upstreamMemoryIDs) &&
                output.anchors.contains(where: {
                    $0.stableKey == candidate.sharedAnchor.stableKey
                })
            }) else {
                return .rejected(.forgedUpstreamMemory)
            }
            return evaluate(
                output,
                for: candidate,
                priorOccurrenceCount: priorOccurrenceCounts[candidate.identityKey] ?? 0,
                userConfirmed: userConfirmedIdentityKeys.contains(candidate.identityKey),
                now: now
            )
        }
    }

    #if !HOLO_MEMORY_STANDALONE
    static func requestFusion(
        for candidates: [HoloCrossDomainFusionCandidate]
    ) async throws -> Data {
        guard HoloAIFeatureFlags.memoryCrossDomainFusionEnabled else {
            throw HoloCrossDomainFusionOperationalError.disabledByKillSwitch
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let package = HoloCrossDomainFusionRequestPackage(candidates: candidates)
        let requestData = try encoder.encode(package)
        guard let json = String(data: requestData, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                package,
                .init(codingPath: [], debugDescription: "跨域融合 JSON 编码失败")
            )
        }
        let provider = HoloBackendAIProvider(baseURL: HoloBackendEnvironment.baseURL)
        let response = try await provider.chat(
            messages: [.user(json)],
            purpose: .memoryCrossDomainFusion
        )
        return Data(response.utf8)
    }
    #endif

    static func evaluate(
        _ output: HoloCrossDomainFusionOutput,
        for candidate: HoloCrossDomainFusionCandidate,
        priorOccurrenceCount: Int,
        userConfirmed: Bool,
        now: Date = Date()
    ) -> HoloCrossDomainFusionDecision {
        guard [.association, .tension].contains(output.claimKind) else {
            return .rejected(.unsupportedClaimKind)
        }
        guard Set(output.upstreamMemoryIDs) == Set(candidate.sourceMemoryIDs) else {
            return .rejected(.forgedUpstreamMemory)
        }

        let evidenceByID = Dictionary(
            uniqueKeysWithValues: candidate.evidenceRefs.map { ($0.id, $0) }
        )
        let evidenceIDs = Array(Set(output.evidenceIDs)).sorted()
        let selectedEvidence = evidenceIDs.compactMap { evidenceByID[$0] }
        guard evidenceIDs.count >= 2,
              selectedEvidence.count == evidenceIDs.count,
              Set(selectedEvidence.map(\.lineageKey)).count >= 2,
              Set(selectedEvidence.map(\.sourceDomain)).count >= 2 else {
            return .rejected(.forgedEvidence)
        }

        let anchors = HoloMemoryIdentity.canonicalAnchors(output.anchors)
        guard anchors.count == 1,
              anchors[0].stableKey == candidate.sharedAnchor.stableKey else {
            return .rejected(.forgedAnchor)
        }
        guard summaryIsValid(output.displaySummary), summaryIsValid(output.aiUseSummary) else {
            return .rejected(.invalidSummary)
        }
        guard expressionIsSafe(output.displaySummary), expressionIsSafe(output.aiUseSummary) else {
            return .rejected(.causalOrMedicalInference)
        }

        let sensitivity: HoloMemorySensitivity = .normal
        do {
            let id = try HoloMemoryIdentity.makeStableID(
                scope: .crossDomain,
                primaryDomain: nil,
                sourceDomains: candidate.sourceDomains,
                claimKind: output.claimKind,
                anchors: anchors
            )
            let prohibited = Array(Set(
                output.prohibitedInferences + ["causality", "medicalDiagnosis"]
            )).sorted()
            var record = HoloMemoryRecord(
                id: id,
                scope: .crossDomain,
                primaryDomain: nil,
                sourceDomains: candidate.sourceDomains,
                subjectKey: candidate.sharedAnchor.stableKey,
                anchorRefs: anchors,
                claimKind: output.claimKind,
                persistenceClass: .phase,
                displaySummary: String(output.displaySummary.prefix(500)),
                aiUseSummary: String(output.aiUseSummary.prefix(500)),
                prohibitedInferences: prohibited,
                evidenceRefs: selectedEvidence,
                upstreamMemoryIDs: candidate.sourceMemoryIDs,
                counterEvidenceRefs: [],
                validFrom: candidate.commonWindow.start,
                validTo: candidate.commonWindow.end,
                lastSupportedAt: selectedEvidence.map(\.observedAt).max(),
                confidenceScore: userConfirmed ? 0.95 : min(0.9, 0.65 + Double(selectedEvidence.count) * 0.05),
                freshnessScore: 1,
                scoringVersion: HoloMemoryScorer.currentVersion,
                scoreComputedAt: now,
                extractorVersion: extractorVersion,
                promptVersion: promptVersion,
                state: .candidate,
                sensitivity: sensitivity,
                userDecision: userConfirmed ? .confirmed : .none,
                createdAt: now,
                updatedAt: now
            )
            if userConfirmed {
                record.state = .active
                record.adoptionMetadata = HoloMemoryAdoptionMetadata(
                    policyVersion: HoloMemoryActivationPolicy.currentVersion,
                    disposition: .userConfirmed,
                    reason: .explicitUserConfirmation,
                    evaluatedAt: now
                )
            } else if let adopted = HoloMemoryActivationPolicy.apply(
                to: record,
                isFirstCrossDomainInference: priorOccurrenceCount < 1,
                now: now
            ) {
                record = adopted
            } else {
                return .rejected(.invalidRecord)
            }
            try record.validate()
            return .persist(record)
        } catch {
            return .rejected(.invalidRecord)
        }
    }

    private static func summaryIsValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 500
    }

    private static func expressionIsSafe(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let forbidden = [
            "导致", "证明", "造成", "引发", "因为", "因而",
            "睡眠障碍", "抑郁", "焦虑症", "疾病", "诊断",
            "personality", "diagnosis", "caused by", "leads to", "proves"
        ]
        return !forbidden.contains { normalized.contains($0) }
    }
}
