//
//  HoloMemoryResourceBudget.swift
//  Holo
//
//  静默记忆任务的设备与调用预算门控。
//

import Foundation

nonisolated struct HoloMemoryResourceSnapshot: Equatable, Sendable {
    /// 全局静默记忆 AI 调用的每日上限。8 个领域 + 跨域融合共 9 个目标，
    /// 额度须覆盖全部目标，否则排在队尾的跨域融合会被挤掉整天没机会跑。
    static let defaultDailyAICallLimit = 10

    var networkAvailable: Bool
    var lowPowerModeEnabled: Bool
    var lowDataModeEnabled: Bool
    var foregroundCriticalOperation: Bool
    var thermalPressureHigh: Bool
    var dailyAICallCount: Int
    var dailyAICallLimit: Int

    init(
        networkAvailable: Bool = true,
        lowPowerModeEnabled: Bool = false,
        lowDataModeEnabled: Bool = false,
        foregroundCriticalOperation: Bool = false,
        thermalPressureHigh: Bool = false,
        dailyAICallCount: Int = 0,
        dailyAICallLimit: Int = HoloMemoryResourceSnapshot.defaultDailyAICallLimit
    ) {
        self.networkAvailable = networkAvailable
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.lowDataModeEnabled = lowDataModeEnabled
        self.foregroundCriticalOperation = foregroundCriticalOperation
        self.thermalPressureHigh = thermalPressureHigh
        self.dailyAICallCount = dailyAICallCount
        self.dailyAICallLimit = dailyAICallLimit
    }
}

nonisolated enum HoloMemoryResourceDeferral: Equatable, Sendable {
    case noNetwork
    case lowPowerMode
    case lowDataMode
    case foregroundCriticalOperation
    case thermalPressure
    case dailyBudgetExhausted
}

nonisolated enum HoloMemoryResourceDecision: Equatable, Sendable {
    case allowed
    case deferred(HoloMemoryResourceDeferral)
}

nonisolated enum HoloMemoryResourceBudget {
    static func evaluate(_ snapshot: HoloMemoryResourceSnapshot) -> HoloMemoryResourceDecision {
        if !snapshot.networkAvailable { return .deferred(.noNetwork) }
        if snapshot.lowPowerModeEnabled { return .deferred(.lowPowerMode) }
        if snapshot.lowDataModeEnabled { return .deferred(.lowDataMode) }
        if snapshot.foregroundCriticalOperation {
            return .deferred(.foregroundCriticalOperation)
        }
        if snapshot.thermalPressureHigh { return .deferred(.thermalPressure) }
        if snapshot.dailyAICallCount >= snapshot.dailyAICallLimit {
            return .deferred(.dailyBudgetExhausted)
        }
        return .allowed
    }
}
