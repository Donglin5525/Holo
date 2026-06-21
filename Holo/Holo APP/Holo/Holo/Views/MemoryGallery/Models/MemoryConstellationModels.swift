import Foundation
import SwiftUI

enum MemoryConstellationModule: String, CaseIterable, Identifiable, Equatable {
    case habit
    case finance
    case task
    case thought
    case health

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .habit:
            return "习惯"
        case .finance:
            return "财务"
        case .task:
            return "任务"
        case .thought:
            return "思考"
        case .health:
            return "健康"
        }
    }

    var iconName: String {
        switch self {
        case .habit:
            return "leaf.fill"
        case .finance:
            return "yensign.circle.fill"
        case .task:
            return "checkmark.circle.fill"
        case .thought:
            return "bubble.left.and.text.bubble.right.fill"
        case .health:
            return "heart.fill"
        }
    }
}

enum MemoryConstellationHealthState: Equatable {
    case unauthorized
    case agentPending
    case connected(summary: String)

    var displayText: String {
        switch self {
        case .unauthorized:
            return "等待健康数据"
        case .agentPending:
            return "健康证据接入中"
        case .connected(let summary):
            return summary
        }
    }
}

struct MemoryConstellationSummary: Equatable {
    let title: String
    let body: String

    static func fallback(hasInsight: Bool) -> MemoryConstellationSummary {
        if hasInsight {
            return MemoryConstellationSummary(
                title: "本期观察",
                body: "Holo 正在把这些生活信号整理成更清楚的星图。"
            )
        }

        return MemoryConstellationSummary(
            title: "记录还不多",
            body: "先从几个生活信号开始，等数据更多后 Holo 会帮你连成一张星图。"
        )
    }
}

struct MemoryConstellationSignal: Identifiable, Equatable {
    let module: MemoryConstellationModule
    let title: String
    let summary: String
    let detail: String
    let level: SignalLevel
    let isDashed: Bool

    var id: String { module.rawValue }

    static func health(state: MemoryConstellationHealthState) -> MemoryConstellationSignal {
        switch state {
        case .unauthorized:
            return MemoryConstellationSignal(
                module: .health,
                title: "健康",
                summary: state.displayText,
                detail: "授权后可把睡眠、步数、站立和运动恢复纳入生活星图。",
                level: .warning,
                isDashed: true
            )
        case .agentPending:
            return MemoryConstellationSignal(
                module: .health,
                title: "健康",
                summary: state.displayText,
                detail: "健康会用于解释睡眠、步数、站立和运动恢复；Agent Health 接入后这里会显示证据摘要。",
                level: .warning,
                isDashed: true
            )
        case .connected(let summary):
            return MemoryConstellationSignal(
                module: .health,
                title: "健康",
                summary: summary,
                detail: "健康证据已纳入本期观察，可在深度分析中查看来源。",
                level: .normal,
                isDashed: false
            )
        }
    }

    static func module(
        _ module: MemoryConstellationModule,
        summary: String,
        detail: String,
        level: SignalLevel = .normal,
        isDashed: Bool = false
    ) -> MemoryConstellationSignal {
        MemoryConstellationSignal(
            module: module,
            title: module.displayName,
            summary: summary,
            detail: detail,
            level: level,
            isDashed: isDashed
        )
    }
}

struct MemoryStorySnippet: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let iconName: String
    let module: MemoryConstellationModule

    static func financeSpendingPeak(id: String = "finance-spending-peak") -> MemoryStorySnippet {
        MemoryStorySnippet(
            id: id,
            title: "这天的外出支出比较集中",
            subtitle: "具体金额和对比留在详情里看",
            iconName: "fork.knife",
            module: .finance
        )
    }
}

struct FeaturedMemoryNode: Identifiable {
    let section: TimelineSection
    let node: MemoryTimelineNode

    var id: UUID { node.id }
}
