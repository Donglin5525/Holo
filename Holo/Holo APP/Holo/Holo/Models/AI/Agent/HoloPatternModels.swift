//
//  HoloPatternModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — Pattern Miner 输出的确定性趋势信号
//

import Foundation

nonisolated enum HoloPatternType: String, Codable, CaseIterable, Sendable {
    case frequencyChange = "frequency_change"
    case goalConflict = "goal_conflict"
    case streakBreak = "streak_break"
    case amountShift = "amount_shift"
    case timeDistributionShift = "time_distribution_shift"
    case categoryConcentration = "category_concentration"
    case backlogPressure = "backlog_pressure"
    case recoverySignal = "recovery_signal"
}

nonisolated enum HoloPatternSeverity: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case critical
}

nonisolated struct HoloPatternSignal: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var type: HoloPatternType
    var title: String
    var metricKey: String
    var value: Double?
    var baselineValue: Double?
    var severity: HoloPatternSeverity
    var evidenceIDs: [String]
    var reason: String
    var generatedAt: Date
}
