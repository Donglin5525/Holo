//
//  HoloAICapability.swift
//  Holo
//
//  HoloAI 能力启动台入口模型
//

import Foundation
import Combine

enum HoloAICapabilityID: String, Codable, CaseIterable, Equatable {
    case onboarding
    case todayState
    case recentAnalysis
    case longTermPatterns
    case goalPlanning
}

struct HoloAICapability: Identifiable, Equatable {
    let id: HoloAICapabilityID
    let title: String
    let systemImage: String
    let isEmphasized: Bool
    let isEnabled: Bool
}

// MARK: - Memory Settings (User-Controlled)

final class HoloMemorySettings: ObservableObject {
    static let shared = HoloMemorySettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let longTermMemoryEnabled = "holo_memory_longTermEnabled"
        static let memoryInsightExtractionEnabled = "holo_memory_insightExtractionEnabled"
        static let memorySummaryInjectionEnabled = "holo_memory_summaryInjectionEnabled"
        static let episodicMemoryObservationEnabled = "holo_memory_episodicObservationEnabled"
    }

    @Published var longTermMemoryEnabled: Bool {
        didSet { defaults.set(longTermMemoryEnabled, forKey: Keys.longTermMemoryEnabled) }
    }

    @available(*, deprecated, message: "未使用，请使用 episodicMemoryObservationEnabled")
    @Published var memoryInsightExtractionEnabled: Bool {
        didSet { defaults.set(memoryInsightExtractionEnabled, forKey: Keys.memoryInsightExtractionEnabled) }
    }

    @Published var memorySummaryInjectionEnabled: Bool {
        didSet { defaults.set(memorySummaryInjectionEnabled, forKey: Keys.memorySummaryInjectionEnabled) }
    }

    @Published var episodicMemoryObservationEnabled: Bool {
        didSet { defaults.set(episodicMemoryObservationEnabled, forKey: Keys.episodicMemoryObservationEnabled) }
    }

    private init() {
        self.longTermMemoryEnabled = defaults.object(forKey: Keys.longTermMemoryEnabled) as? Bool ?? false
        self.memoryInsightExtractionEnabled = defaults.object(forKey: Keys.memoryInsightExtractionEnabled) as? Bool ?? false
        self.memorySummaryInjectionEnabled = defaults.object(forKey: Keys.memorySummaryInjectionEnabled) as? Bool ?? true
        self.episodicMemoryObservationEnabled = defaults.object(forKey: Keys.episodicMemoryObservationEnabled) as? Bool ?? false
    }
}

// MARK: - Feature Flags (Read from Settings)

enum HoloAIFeatureFlags {
    static var capabilityLaunchpadEnabled: Bool { true }
    static var memorySummaryInjectionEnabled: Bool { HoloMemorySettings.shared.memorySummaryInjectionEnabled }
    static var longTermMemoryWriteEnabled: Bool { HoloMemorySettings.shared.longTermMemoryEnabled }
    static var memoryInsightCandidateExtractionEnabled: Bool { HoloMemorySettings.shared.longTermMemoryEnabled }
    static var episodicMemoryObservationEnabled: Bool { HoloMemorySettings.shared.episodicMemoryObservationEnabled }
}
