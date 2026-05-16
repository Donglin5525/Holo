//
//  GoalModels.swift
//  Holo
//
//  目标系统值类型：状态、领域、草案、规划会话
//

import Foundation

enum GoalStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case paused
    case completed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active: return "进行中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        }
    }
}

enum GoalDomain: String, Codable, CaseIterable, Identifiable {
    case learning
    case health
    case career
    case finance
    case life
    case project
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .learning: return "学习"
        case .health: return "健康"
        case .career: return "职业"
        case .finance: return "财务"
        case .life: return "生活"
        case .project: return "项目"
        case .other: return "其他"
        }
    }

    var icon: String {
        switch self {
        case .learning: return "book.closed"
        case .health: return "figure.run"
        case .career: return "briefcase"
        case .finance: return "chart.pie"
        case .life: return "sparkles"
        case .project: return "folder"
        case .other: return "target"
        }
    }
}

enum GoalPlanningMode: String, Codable, CaseIterable, Identifiable {
    case concise
    case complete

    var id: String { rawValue }
    var displayName: String { self == .concise ? "精简" : "完整" }
}

enum GoalPlanningStatus: String, Codable, Equatable {
    case collecting
    case draftReady
    case confirming
    case confirmed
    case cancelled
}

struct GoalTaskDraft: Codable, Equatable, Identifiable {
    let id: String
    var isSelected: Bool
    var title: String
    var dueDateText: String?
    var priority: Int?
    var note: String?
}

struct GoalHabitDraft: Codable, Equatable, Identifiable {
    let id: String
    var isSelected: Bool
    var name: String
    var frequency: String
    var targetCount: Int?
    var type: String
    var unit: String?
    var targetValue: Double?

    var resolvedFrequency: HabitFrequency {
        HabitFrequency(rawValue: frequency) ?? .daily
    }
}

struct GoalDraft: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    var summary: String?
    var domain: GoalDomain
    var desiredOutcome: String?
    var motivation: String?
    var deadlineText: String?
    var tasks: [GoalTaskDraft]
    var habits: [GoalHabitDraft]
    var missingInfoWarnings: [String]
}

struct GoalPlanningSession: Identifiable, Equatable {
    let id: UUID
    var initialUserText: String?
    var turnCount: Int
    let maxTurns: Int
    var answers: [String]
    var mode: GoalPlanningMode
    var status: GoalPlanningStatus
    var draft: GoalDraft?

    static func fresh(seedText: String? = nil) -> GoalPlanningSession {
        GoalPlanningSession(
            id: UUID(),
            initialUserText: seedText,
            turnCount: 0,
            maxTurns: 3,
            answers: seedText.map { [$0] } ?? [],
            mode: .concise,
            status: .collecting,
            draft: nil
        )
    }
}

struct GoalPlanningRequest: Identifiable, Equatable {
    let id = UUID()
    let seedText: String?
}
