//
//  HoloAgentTimeRange.swift
//  Holo
//
//  HoloAI Agent V3.1 — 时间范围（查询窗口 / baseline 对照窗口）
//

import Foundation

nonisolated struct HoloAgentTimeRange: Codable, Equatable, Sendable {
    var label: String
    var start: Date?
    var end: Date?
}
