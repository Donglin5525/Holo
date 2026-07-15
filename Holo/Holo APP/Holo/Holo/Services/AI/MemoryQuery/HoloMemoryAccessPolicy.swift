//
//  HoloMemoryAccessPolicy.swift
//  Holo
//
//  统一记忆权限入口：萃取、回答与调试读取都必须经过这里。
//

import Foundation

struct HoloMemoryAccessState: Equatable, Sendable {
    var automaticMemoryEnabled: Bool
    var memoryAssistedAnsweringEnabled: Bool
    var aiDataProcessingConsentGranted: Bool
}

enum HoloMemoryExtractionMode: CaseIterable, Sendable {
    case localDeterministic
    case externalAI
}

enum HoloMemoryExtractionDecision: Equatable, Sendable {
    case allowedLocalOnly
    case allowedExternalAI
    case deniedByAutomaticMemorySetting
    case deniedByDataProcessingConsent
}

enum HoloMemoryAnsweringDecision: Equatable, Sendable {
    case allowed
    case disabled
}

struct HoloMemoryAccessPolicy: Sendable {
    let state: HoloMemoryAccessState

    static var current: HoloMemoryAccessPolicy {
        let operational = HoloMemoryOperationalControls.current()
        return HoloMemoryAccessPolicy(
            state: HoloMemoryAccessState(
                automaticMemoryEnabled: HoloMemorySettings.shared.automaticMemoryEnabled &&
                    operational.allowsExtraction,
                memoryAssistedAnsweringEnabled: HoloMemorySettings.shared.memoryAssistedAnsweringEnabled &&
                    operational.allowsAnswerInjection,
                aiDataProcessingConsentGranted: HoloAIDataProcessingConsent.shared.isGranted
            )
        )
    }

    var canReadExistingMemoryForManagement: Bool { true }

    func extractionDecision(for mode: HoloMemoryExtractionMode) -> HoloMemoryExtractionDecision {
        guard state.automaticMemoryEnabled else {
            return .deniedByAutomaticMemorySetting
        }
        switch mode {
        case .localDeterministic:
            return .allowedLocalOnly
        case .externalAI:
            return state.aiDataProcessingConsentGranted
                ? .allowedExternalAI
                : .deniedByDataProcessingConsent
        }
    }

    func answeringDecision(for consumer: HoloMemoryAnswerConsumer) -> HoloMemoryAnsweringDecision {
        _ = consumer
        return state.memoryAssistedAnsweringEnabled ? .allowed : .disabled
    }

    func answeringDecision(for capability: HoloAICapabilityID) -> HoloMemoryAnsweringDecision {
        answeringDecision(for: capability.memoryAnswerConsumer)
    }
}

private extension HoloAICapabilityID {
    var memoryAnswerConsumer: HoloMemoryAnswerConsumer {
        switch self {
        case .onboarding: .capabilityOnboarding
        case .todayState: .capabilityTodayState
        case .recentAnalysis: .capabilityRecentAnalysis
        case .longTermPatterns: .capabilityLongTermPatterns
        case .goalPlanning: .capabilityGoalPlanning
        }
    }
}
