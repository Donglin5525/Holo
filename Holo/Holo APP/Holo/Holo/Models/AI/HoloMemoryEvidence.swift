//
//  HoloMemoryEvidence.swift
//  Holo
//
//  统一记忆的证据与类型化锚点契约
//

import Foundation

enum HoloMemoryEvidenceKind: String, Codable, CaseIterable, Sendable {
    case entityRef
    case aggregateSnapshot
    case explicitUserStatement
}

struct HoloMemoryEvidenceRef: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: HoloMemoryEvidenceKind
    var sourceDomain: HoloMemoryDomain
    /// 指向最底层业务事件或用户表达，用于跨域独立性去重。
    var lineageKey: String
    var sourceID: String?
    var revisionDigest: String
    var observedAt: Date
    var validFrom: Date?
    var validTo: Date?
    var aggregateDefinition: String?
    var sampleCount: Int?
    /// 仅保留验证与用户来源说明所需的最小摘要，不复制健康原始样本。
    var summary: String?

    init(
        id: String,
        kind: HoloMemoryEvidenceKind,
        sourceDomain: HoloMemoryDomain,
        lineageKey: String,
        sourceID: String? = nil,
        revisionDigest: String,
        observedAt: Date,
        validFrom: Date? = nil,
        validTo: Date? = nil,
        aggregateDefinition: String? = nil,
        sampleCount: Int? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sourceDomain = sourceDomain
        self.lineageKey = lineageKey
        self.sourceID = sourceID
        self.revisionDigest = revisionDigest
        self.observedAt = observedAt
        self.validFrom = validFrom
        self.validTo = validTo
        self.aggregateDefinition = aggregateDefinition
        self.sampleCount = sampleCount
        self.summary = summary
    }
}

enum HoloMemoryAnchorType: String, Codable, CaseIterable, Sendable {
    case goal
    case habit
    case financeCategory
    case merchant
    case thoughtTopic
    case healthMetric
    case task
    case conversation
    case profile
    case userTheme
}

struct HoloMemoryAnchorRef: Codable, Equatable, Hashable, Sendable {
    var type: HoloMemoryAnchorType
    var canonicalValue: String
    var displayLabel: String?

    var stableKey: String { "\(type.rawValue):\(canonicalValue)" }

    init(
        type: HoloMemoryAnchorType,
        value: String,
        displayLabel: String? = nil
    ) throws {
        let normalized = Self.normalize(value)
        guard !normalized.isEmpty else {
            throw HoloMemorySchemaError.emptyAnchorValue
        }
        self.type = type
        canonicalValue = normalized
        self.displayLabel = displayLabel
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
    }
}
