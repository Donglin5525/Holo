//
//  HoloLongTermMemoryModels.swift
//  Holo
//
//  长期记忆模型：候选、确认、证据
//

import Foundation

enum HoloLongTermMemoryType: String, Codable, Equatable {
    case explicitUserPreference
    case stableFeedbackPreference
    case recurringPattern
    case longTermGoal
    case profileBackedFact
}

enum HoloMemoryConfidence: String, Codable, Equatable {
    case low
    case medium
    case high
}

enum HoloMemoryConfirmationState: String, Codable, Equatable {
    case candidate
    case silentlyAccepted
    case confirmed
    case rejected
    case archived
}

enum HoloMemorySensitivity: String, Codable, Equatable {
    case normal
    case highImpact
    case sensitive
}

struct HoloLongTermMemory: Codable, Equatable, Identifiable {
    var id: String
    var type: HoloLongTermMemoryType
    var title: String
    var summary: String
    var confidence: HoloMemoryConfidence
    var confirmationState: HoloMemoryConfirmationState
    var sensitivity: HoloMemorySensitivity
    var evidence: [HoloLongTermMemoryEvidence]
    var createdAt: Date
    var updatedAt: Date
    var expiresAt: Date?
}

struct HoloLongTermMemoryEvidence: Codable, Equatable, Identifiable {
    var id: String
    var source: HoloMemorySource
    var sourceID: String?
    var excerpt: String
    var observedAt: Date
}
