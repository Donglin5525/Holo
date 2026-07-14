//
//  HoloDomainSignalBuilder.swift
//  Holo
//
//  统一清洗模块信号，隔离用户原文与模型指令边界。
//

import Foundation

nonisolated enum HoloDomainSignalBuilderError: Error, Equatable {
    case evidenceDomainMismatch
    case missingAnchor
    case invalidNumericFact
}

nonisolated enum HoloDomainSignalBuilder {
    static let maximumUserTextLength = 1_000

    static func make(
        id: String,
        domain: HoloMemoryDomain,
        kind: HoloDomainSignalKind,
        evidence: HoloMemoryEvidenceRef,
        anchors: [HoloMemoryAnchorRef],
        numericFacts: [String: Double] = [:],
        userText: String? = nil
    ) throws -> HoloDomainMemorySignal {
        guard evidence.sourceDomain == domain else {
            throw HoloDomainSignalBuilderError.evidenceDomainMismatch
        }
        let canonicalAnchors = HoloMemoryIdentity.canonicalAnchors(anchors)
        guard !canonicalAnchors.isEmpty else {
            throw HoloDomainSignalBuilderError.missingAnchor
        }
        guard numericFacts.values.allSatisfy(\.isFinite) else {
            throw HoloDomainSignalBuilderError.invalidNumericFact
        }
        return HoloDomainMemorySignal(
            id: id,
            domain: domain,
            kind: kind,
            evidence: evidence,
            anchors: canonicalAnchors,
            numericFacts: numericFacts,
            userText: userText.map(sanitizeUserText)
        )
    }

    static func sanitizeUserText(_ value: String) -> String {
        let withoutControls = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        let roleMarkers = [
            "<|system|>", "<|assistant|>", "<|user|>",
            "system:", "assistant:", "user:"
        ]
        var isolated = withoutControls
        for marker in roleMarkers {
            isolated = isolated.replacingOccurrences(
                of: marker,
                with: "［role-marker］",
                options: [.caseInsensitive]
            )
        }
        return String(isolated.prefix(maximumUserTextLength))
    }
}
