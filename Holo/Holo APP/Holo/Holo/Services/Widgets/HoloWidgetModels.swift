//
//  HoloWidgetModels.swift
//  Holo
//
//  桌面小组件与主 App 共享的轻量模型。
//

import Foundation

enum HoloWidgetSharedContainer {
    static let appGroupIdentifier = "group.com.tangyuxuan.holo-app"
    static let directoryName = "HoloWidgetSnapshots"

    static let quickActionsFileName = "widget_quick_actions.json"
    static let financeFileName = "widget_finance_snapshot.json"
    static let thoughtMemoryFileName = "widget_thought_memory.json"
}

enum HoloWidgetKind: String {
    case voiceLaunch = "HoloVoiceLaunchWidget"
    case quickActions = "HoloQuickActionsWidget"
    case finance = "HoloFinanceWidget"
    case thoughtMemory = "HoloThoughtMemoryWidget"
}

struct HoloWidgetQuickActionsSnapshot: Codable, Equatable {
    let actions: [HoloWidgetQuickAction]
    let updatedAt: Date

    static func defaultSnapshot(date: Date = Date()) -> HoloWidgetQuickActionsSnapshot {
        HoloWidgetQuickActionsSnapshot(
            actions: [.askHolo, .addTransaction, .recordThought, .addTask],
            updatedAt: date
        )
    }
}

enum HoloWidgetQuickAction: String, CaseIterable, Codable, Equatable {
    case askHolo
    case addTransaction
    case recordThought
    case addTask

    var title: String {
        switch self {
        case .askHolo: return "问 Holo"
        case .addTransaction: return "记一笔"
        case .recordThought: return "写想法"
        case .addTask: return "加待办"
        }
    }

    var systemImageName: String {
        switch self {
        case .askHolo: return "waveform"
        case .addTransaction: return "yensign.circle.fill"
        case .recordThought: return "lightbulb.fill"
        case .addTask: return "checklist"
        }
    }

    var deepLink: URL {
        switch self {
        case .askHolo:
            return URL(string: "holo://ai")!
        case .addTransaction:
            return URL(string: "holo://finance/add")!
        case .recordThought:
            return URL(string: "holo://thoughts/new")!
        case .addTask:
            return URL(string: "holo://tasks/new")!
        }
    }
}

enum HoloWidgetDeepLink: Equatable {
    case ai(voiceInput: Bool)
    case addTransaction
    /// 今日收支小组件：打开财务分析页（本月概览）
    case financeAnalysis
    case recordThought
    case addTask
    case thoughtDetail(id: UUID)

    static func parse(_ url: URL) -> HoloWidgetDeepLink? {
        guard url.scheme == "holo" else { return nil }

        let path = [url.host, url.path]
            .compactMap { $0 }
            .joined()

        switch path {
        case "ai":
            return .ai(voiceInput: url.queryValue(for: "voiceInput") == "true")
        case "finance/add":
            return .addTransaction
        case "finance/analysis":
            return .financeAnalysis
        case "thoughts/new":
            return .recordThought
        case "tasks/new":
            return .addTask
        case "thoughts/detail":
            guard
                let rawId = url.queryValue(for: "id"),
                let id = UUID(uuidString: rawId)
            else { return nil }
            return .thoughtDetail(id: id)
        default:
            return nil
        }
    }
}

enum HoloWidgetBudgetStatus: String, Codable, Equatable {
    case noBudget
    case onTrack
    case aheadOfTime
    case overBudget
}

struct HoloWidgetFinanceSnapshot: Codable, Equatable {
    let todayExpense: Double
    let todayIncome: Double
    let monthExpense: Double
    let monthBudget: Double?
    let dayOfMonth: Int
    let daysInMonth: Int
    let updatedAt: Date

    var budgetProgress: Double? {
        guard let monthBudget, monthBudget > 0 else { return nil }
        return monthExpense / monthBudget
    }

    var timeProgress: Double {
        guard daysInMonth > 0 else { return 0 }
        return min(max(Double(dayOfMonth) / Double(daysInMonth), 0), 1)
    }

    var budgetStatus: HoloWidgetBudgetStatus {
        guard let budgetProgress else { return .noBudget }
        if budgetProgress >= 1 { return .overBudget }
        if budgetProgress > timeProgress + 0.1 { return .aheadOfTime }
        return .onTrack
    }
}

struct HoloWidgetThoughtMemorySnapshot: Codable, Equatable {
    let thoughtId: UUID
    let createdAt: Date
    let tags: [String]
    let excerpt: String
    let sourceHint: String
    let showsOriginalExcerpt: Bool

    var displayText: String {
        if showsOriginalExcerpt {
            return excerpt
        }
        return sourceHint
    }

    var detailDeepLink: URL {
        URL(string: "holo://thoughts/detail?id=\(thoughtId.uuidString)")!
    }
}

private extension URL {
    func queryValue(for name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}
