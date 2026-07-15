//
//  HoloDomainMemoryOutputValidator.swift
//  Holo
//
//  将模型视为不可信输入：先拦截指令字段，再逐条核验证据、锚点和领域边界。
//

import Foundation

nonisolated enum HoloDomainMemoryOutputValidator {
    static func decodeAndValidate(
        _ data: Data,
        against package: HoloDomainObservationPackage,
        now: Date,
        extractorVersion: Int,
        promptVersion: Int
    ) -> HoloDomainMemoryValidationResult {
        guard rawJSONIsSafe(data) else {
            return .init(validRecords: [], rejections: [.forbiddenInstruction])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(HoloDomainMemoryOutputEnvelope.self, from: data) else {
            return .init(validRecords: [], rejections: [.malformedJSON])
        }
        return validate(
            envelope: envelope,
            against: package,
            now: now,
            extractorVersion: extractorVersion,
            promptVersion: promptVersion
        )
    }

    static func validate(
        envelope: HoloDomainMemoryOutputEnvelope,
        against package: HoloDomainObservationPackage,
        now: Date,
        extractorVersion: Int,
        promptVersion: Int
    ) -> HoloDomainMemoryValidationResult {
        let evidenceByID = Dictionary(
            uniqueKeysWithValues: package.signals.map { ($0.evidence.id, $0.evidence) }
        )
        let allowedAnchorKeys = Set(package.signals.flatMap { $0.anchors.map(\.stableKey) })
        let allowedAnchorTypes = Set(package.allowedAnchorTypes)
        let allowedClaims = Set(package.allowedClaimKinds)
        var records: [HoloMemoryRecord] = []
        var rejections: [HoloDomainMemoryValidationRejection] = []

        for candidate in envelope.candidates.prefix(20) {
            if candidate.requestedActions?.isEmpty == false {
                rejections.append(.forbiddenInstruction)
                continue
            }
            guard candidate.domain == package.domain else {
                rejections.append(.domainMismatch)
                continue
            }
            guard allowedClaims.contains(candidate.claimKind) else {
                rejections.append(.claimKindNotAllowed)
                continue
            }
            let uniqueEvidenceIDs = Array(Set(candidate.evidenceIDs)).sorted()
            guard !uniqueEvidenceIDs.isEmpty,
                  uniqueEvidenceIDs.allSatisfy({ evidenceByID[$0]?.sourceDomain == package.domain }) else {
                rejections.append(.forgedEvidence)
                continue
            }
            let anchors = HoloMemoryIdentity.canonicalAnchors(candidate.anchors)
            guard !anchors.isEmpty,
                  anchors.allSatisfy({
                      allowedAnchorTypes.contains($0.type) && allowedAnchorKeys.contains($0.stableKey)
                  }) else {
                rejections.append(.forgedAnchor)
                continue
            }
            guard summaryIsSafe(candidate.displaySummary),
                  summaryIsSafe(candidate.aiUseSummary) else {
                rejections.append(.invalidSummary)
                continue
            }

            let evidence = uniqueEvidenceIDs.compactMap { evidenceByID[$0] }
            let canActivateSilently = evidence.contains {
                $0.kind == .explicitUserStatement ||
                ($0.kind == .aggregateSnapshot && ($0.sampleCount ?? 0) >= 3)
            }
            do {
                let id = try HoloMemoryIdentity.makeStableID(
                    scope: .domain,
                    primaryDomain: package.domain,
                    sourceDomains: [package.domain],
                    claimKind: candidate.claimKind,
                    anchors: anchors
                )
                let record = HoloMemoryRecord(
                    id: id,
                    scope: .domain,
                    primaryDomain: package.domain,
                    sourceDomains: [package.domain],
                    subjectKey: anchors.map(\.stableKey).joined(separator: ","),
                    anchorRefs: anchors,
                    claimKind: candidate.claimKind,
                    persistenceClass: candidate.persistenceClass,
                    displaySummary: String(candidate.displaySummary.prefix(500)),
                    aiUseSummary: String(candidate.aiUseSummary.prefix(500)),
                    prohibitedInferences: candidate.prohibitedInferences.map {
                        String(HoloDomainSignalBuilder.sanitizeUserText($0).prefix(300))
                    },
                    evidenceRefs: evidence,
                    upstreamMemoryIDs: [],
                    counterEvidenceRefs: [],
                    validFrom: package.window.start,
                    validTo: package.window.end,
                    lastSupportedAt: evidence.map(\.observedAt).max(),
                    confidenceScore: min(0.9, 0.55 + Double(evidence.count) * 0.1),
                    freshnessScore: 1,
                    scoringVersion: HoloMemoryScorer.currentVersion,
                    scoreComputedAt: now,
                    extractorVersion: extractorVersion,
                    promptVersion: promptVersion,
                    state: canActivateSilently ? .active : .candidate,
                    sensitivity: package.domain == .health ? .sensitive : .normal,
                    userDecision: .none,
                    createdAt: now,
                    updatedAt: now
                )
                try record.validate()
                records.append(record)
            } catch {
                rejections.append(.invalidRecord)
            }
        }

        var existingByID = Dictionary(
            uniqueKeysWithValues: package.existingMemories
                .filter { $0.scope == .domain && $0.primaryDomain == package.domain }
                .map { ($0.id, $0) }
        )
        for operation in envelope.counterEvidence ?? [] {
            guard var record = existingByID[operation.memoryID] else {
                rejections.append(.invalidExistingMemoryOperation)
                continue
            }
            let evidence = Array(Set(operation.evidenceIDs)).compactMap { evidenceByID[$0] }
            guard !evidence.isEmpty,
                  evidence.count == Set(operation.evidenceIDs).count,
                  evidence.allSatisfy({ $0.sourceDomain == package.domain }) else {
                rejections.append(.forgedEvidence)
                continue
            }
            for item in evidence {
                record = HoloMemoryLifecycle.apply(.counterEvidence(item), to: record, now: now)
            }
            existingByID[record.id] = record
        }

        let availableReplacementIDs = Set(records.map(\.id) + existingByID.keys)
        for operation in envelope.supersedes ?? [] {
            guard var record = existingByID[operation.memoryID],
                  operation.memoryID != operation.replacementMemoryID,
                  availableReplacementIDs.contains(operation.replacementMemoryID) else {
                rejections.append(.invalidExistingMemoryOperation)
                continue
            }
            let replacementVersionID = records.first(where: {
                $0.id == operation.replacementMemoryID
            })?.versionID ?? operation.replacementMemoryID
            record = HoloMemoryLifecycle.apply(
                .superseded(byVersionID: replacementVersionID),
                to: record,
                now: now
            )
            existingByID[record.id] = record
        }
        let touchedIDs = Set((envelope.counterEvidence ?? []).map(\.memoryID) +
            (envelope.supersedes ?? []).map(\.memoryID))
        records.append(contentsOf: existingByID.values.filter { touchedIDs.contains($0.id) })
        records = Dictionary(grouping: records, by: \.id).compactMap { $0.value.last }
        return HoloDomainMemoryValidationResult(
            validRecords: records,
            rejections: rejections
        )
    }

    private static func summaryIsSafe(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return false }
        let lowered = trimmed.lowercased()
        let forbidden = [
            "<|system|>", "<|assistant|>", "tool_call", "automaticmemoryenabled",
            "memoryassistedansweringenabled", "调用工具", "修改开关"
        ]
        return !forbidden.contains { lowered.contains($0) }
    }

    private static func rawJSONIsSafe(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return true }
        return inspectJSON(object)
    }

    private static func inspectJSON(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let normalized = key.lowercased().replacingOccurrences(of: "_", with: "")
                if normalized.contains("requestedaction") {
                    guard requestedActionValueIsSafe(child) else { return false }
                    continue
                }
                if normalized.contains("tool") ||
                    normalized.contains("command") ||
                    normalized.contains("automaticmemoryenabled") ||
                    normalized.contains("memoryassistedansweringenabled") {
                    return false
                }
                if !inspectJSON(child) { return false }
            }
        } else if let array = value as? [Any] {
            return array.allSatisfy(inspectJSON)
        } else if let string = value as? String {
            let normalized = string.lowercased().replacingOccurrences(of: "_", with: "")
            let forbiddenValues = [
                "<|system|>", "<|assistant|>", "toolcall", "call tool",
                "automaticmemoryenabled", "memoryassistedansweringenabled",
                "调用工具", "修改开关", "打开记忆开关"
            ]
            return !forbiddenValues.contains { normalized.contains($0) }
        }
        return true
    }

    /// `requestedActions` 是服务端 Prompt 的固定 Schema 字段。
    /// null/空数组代表模型没有请求动作；只有非空值才属于越权输出。
    private static func requestedActionValueIsSafe(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let values = value as? [Any] { return values.isEmpty }
        return false
    }
}
