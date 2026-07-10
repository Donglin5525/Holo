//
//  HoloAgentEvidencePolicy.swift
//  Holo
//
//  Agent 工具结果进入证据账本时的统一来源策略。
//

import Foundation

nonisolated enum HoloAgentEvidencePolicy {

    static func sourceModule(for tool: String) -> HoloEvidenceSourceModule {
        switch tool {
        case "finance": return .finance
        case "habit": return .habit
        case "task": return .task
        case "goal": return .goal
        case "thought": return .thought
        case "health": return .health
        case "memory": return .memory
        case "profile": return .profile
        case "conversation": return .conversation
        case "insight": return .memoryInsight
        default: return .agent
        }
    }

    static func sensitivity(for result: HoloDataToolResult) -> HoloEvidenceSensitivity {
        result.sensitivity ?? .normal
    }
}
