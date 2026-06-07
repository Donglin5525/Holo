//
//  HoloLifePatternModel.swift
//  Holo
//
//  用户长期生活模式。只沉淀稳定、多证据、可解释的模式。
//

import Foundation

enum LifePatternSource: String, Codable, Equatable {
    case dailySense
    case insightFeedback
    case confirmedMemory
    case multiPeriodInsight
}

struct LifePatternEntry: Codable, Equatable, Identifiable {
    let key: String
    var summary: String
    var evidenceCount: Int
    var confidence: Double
    var lastSeenAt: Date
    var source: LifePatternSource

    var id: String { key }
}

struct HoloLifePatternModel: Codable, Equatable {
    var schemaVersion: Int
    var pressurePatterns: [LifePatternEntry]
    var recoveryPatterns: [LifePatternEntry]
    var effectiveInterventionStyles: [LifePatternEntry]
    var lowValueTopics: [LifePatternEntry]
    var updatedAt: Date

    static func empty() -> HoloLifePatternModel {
        HoloLifePatternModel(
            schemaVersion: 1,
            pressurePatterns: [],
            recoveryPatterns: [],
            effectiveInterventionStyles: [],
            lowValueTopics: [],
            updatedAt: Date()
        )
    }
}

