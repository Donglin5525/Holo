//
//  HoloWidgetModels.swift
//  Holo
//
//  桌面小组件与主 App 共享的轻量模型。
//

import Foundation

nonisolated enum HoloWidgetSharedContainer {
    static let appGroupIdentifier = "group.com.tangyuxuan.holo-app"
    static let directoryName = "HoloWidgetSnapshots"

    static let quickActionsFileName = "widget_quick_actions.json"
    static let financeFileName = "widget_finance_snapshot.json"
    static let thoughtMemoryFileName = "widget_thought_memory.json"
    static let habitFileName = "widget_habit_snapshot.json"
    static let todoFileName = "widget_todo_snapshot.json"
    static let goalFileName = "widget_goal_snapshot.json"
    static let anniversaryFileName = "widget_anniversary_snapshot.json"
    static let entitlementFileName = "widget_entitlement.json"
}

nonisolated struct HoloWidgetEntitlementSnapshot: Codable, Equatable {
    let isPlusActive: Bool
    let source: String
    let updatedAt: Date

    static func free(date: Date = Date()) -> HoloWidgetEntitlementSnapshot {
        HoloWidgetEntitlementSnapshot(isPlusActive: false, source: "unavailable", updatedAt: date)
    }

    static func plusPreview(date: Date = Date()) -> HoloWidgetEntitlementSnapshot {
        HoloWidgetEntitlementSnapshot(isPlusActive: true, source: "preview", updatedAt: date)
    }
}

nonisolated enum HoloWidgetKind: String {
    case voiceLaunch = "HoloVoiceLaunchWidget"
    case quickActions = "HoloQuickActionsWidget"
    case finance = "HoloFinanceWidget"
    case thoughtMemory = "HoloThoughtMemoryWidget"
    case habit = "HoloHabitWidget"
    case todo = "HoloTodoWidget"
    case goal = "HoloGoalWidget"
    case anniversary = "HoloAnniversaryWidget"
}

nonisolated struct HoloWidgetQuickActionsSnapshot: Codable, Equatable {
    let actions: [HoloWidgetQuickAction]
    let updatedAt: Date

    static func defaultSnapshot(date: Date = Date()) -> HoloWidgetQuickActionsSnapshot {
        HoloWidgetQuickActionsSnapshot(
            actions: [.askHolo, .addTransaction, .recordThought, .addTask],
            updatedAt: date
        )
    }
}

nonisolated enum HoloWidgetQuickAction: String, CaseIterable, Codable, Equatable {
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

nonisolated enum HoloWidgetDeepLink: Equatable {
    case ai(voiceInput: Bool)
    case addTransaction
    /// 本月收支小组件：打开财务分析页（本月概览）
    case financeAnalysis
    case recordThought
    case addTask
    case thoughtDetail(id: UUID)
    /// 今日习惯小组件：打开习惯打卡页
    case habits
    /// 今日待办小组件：打开待办列表页
    case tasks
    case goalDetail(id: UUID)
    /// 纪念日倒数小组件：打开纪念日页
    case anniversaries

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
        case "tasks":
            return .tasks
        case "thoughts/detail":
            guard
                let rawId = url.queryValue(for: "id"),
                let id = UUID(uuidString: rawId)
            else { return nil }
            return .thoughtDetail(id: id)
        case "habits":
            return .habits
        case "goals/detail":
            guard
                let rawId = url.queryValue(for: "id"),
                let id = UUID(uuidString: rawId)
            else { return nil }
            return .goalDetail(id: id)
        case "anniversaries":
            return .anniversaries
        default:
            return nil
        }
    }
}

nonisolated enum HoloWidgetBudgetStatus: String, Codable, Equatable {
    case noBudget
    case onTrack
    case aheadOfTime
    case overBudget
}

nonisolated struct HoloWidgetFinanceSnapshot: Codable, Equatable {
    let monthExpense: Double
    let monthIncome: Double
    let monthBudget: Double?
    let dayOfMonth: Int
    let daysInMonth: Int
    /// 大号组件独享：最近 7 天逐日支出（旧快照无此字段时为 nil）
    let weekExpense: [HoloWidgetDailyExpense]?
    /// 大号组件独享：本月支出前三分类
    let topCategories: [HoloWidgetCategorySpend]?
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

nonisolated struct HoloWidgetDailyExpense: Codable, Equatable {
    /// 星期短名（"一"…"六"），今天固定为 "今"
    let weekdayText: String
    let amount: Double
    let isToday: Bool
}

nonisolated struct HoloWidgetCategorySpend: Codable, Equatable {
    let name: String
    let amount: Double
    /// 分类色（hex，与 App 内账本分类一致）
    let colorHex: String
}

nonisolated struct HoloWidgetThoughtMemorySnapshot: Codable, Equatable {
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

// MARK: - Habit（今日习惯）

nonisolated struct HoloWidgetHabitSnapshot: Codable, Equatable {
    let completedToday: Int
    let totalToday: Int
    /// 最长连续坚持（如 "34天"），空数据时为空串
    let longestStreakText: String
    /// 前 5 个活跃习惯（按 sortOrder）
    let habits: [HoloWidgetHabitItem]
    let updatedAt: Date

    var remainingCount: Int { max(0, totalToday - completedToday) }

    static func empty(date: Date = Date()) -> HoloWidgetHabitSnapshot {
        HoloWidgetHabitSnapshot(
            completedToday: 0,
            totalToday: 0,
            longestStreakText: "",
            habits: [],
            updatedAt: date
        )
    }

    /// 组件画廊占位 / 免费用户示意数据
    static func sample(date: Date = Date()) -> HoloWidgetHabitSnapshot {
        HoloWidgetHabitSnapshot(
            completedToday: 3,
            totalToday: 5,
            longestStreakText: "34天",
            habits: [
                HoloWidgetHabitItem(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    name: "跑步 5 公里",
                    icon: "🏃",
                    streakText: "12天",
                    isCompletedToday: true,
                    weekPattern: [true, true, false, true, true, true, true]
                ),
                HoloWidgetHabitItem(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    name: "喝够 8 杯水",
                    icon: "💧",
                    streakText: "34天",
                    isCompletedToday: true,
                    weekPattern: [true, true, true, true, true, true, true]
                ),
                HoloWidgetHabitItem(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    name: "睡前阅读 20 分钟",
                    icon: "📚",
                    streakText: "8天",
                    isCompletedToday: true,
                    weekPattern: [true, false, true, true, false, true, false]
                ),
                HoloWidgetHabitItem(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    name: "冥想 10 分钟",
                    icon: "🧘",
                    streakText: "5天",
                    isCompletedToday: false,
                    weekPattern: [true, true, true, false, true, false, false]
                ),
                HoloWidgetHabitItem(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    name: "7 点前起床",
                    icon: "🌱",
                    streakText: "21天",
                    isCompletedToday: false,
                    weekPattern: [true, true, true, true, true, false, false]
                )
            ],
            updatedAt: date
        )
    }
}

nonisolated struct HoloWidgetHabitItem: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    /// emoji 字符或 SF Symbol 名（与 App 内习惯图标同一存储）
    let icon: String
    /// 如 "12天"；0 连续时为空串（组件侧不渲染火焰）
    let streakText: String
    let isCompletedToday: Bool
    /// 本周逐日完成（下标 0 = 本周第一天，末位 = 今天；长度随星期推进 1…7）
    let weekPattern: [Bool]
}

// MARK: - Todo（今日待办）

nonisolated struct HoloWidgetTodoSnapshot: Codable, Equatable {
    let completedToday: Int
    let totalToday: Int
    /// 未完成（今天到期 + 逾期，按优先级降序）在前，末尾最多 1 条今日已完成（划线展示）
    let items: [HoloWidgetTodoItem]
    /// 如 "8.20 周三"
    let dateText: String
    let updatedAt: Date

    var pendingCount: Int { max(0, totalToday - completedToday) }

    static func empty(date: Date = Date()) -> HoloWidgetTodoSnapshot {
        HoloWidgetTodoSnapshot(completedToday: 0, totalToday: 0, items: [], dateText: "", updatedAt: date)
    }

    static func sample(date: Date = Date()) -> HoloWidgetTodoSnapshot {
        HoloWidgetTodoSnapshot(
            completedToday: 1,
            totalToday: 4,
            items: [
                HoloWidgetTodoItem(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    title: "回复小组件设计稿意见",
                    isCompleted: false,
                    priority: 3,
                    isOverdue: false
                ),
                HoloWidgetTodoItem(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    title: "预约牙医复诊",
                    isCompleted: false,
                    priority: 2,
                    isOverdue: false
                ),
                HoloWidgetTodoItem(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    title: "给妈妈打电话",
                    isCompleted: false,
                    priority: 1,
                    isOverdue: false
                ),
                HoloWidgetTodoItem(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    title: "买咖啡豆",
                    isCompleted: true,
                    priority: 0,
                    isOverdue: false
                )
            ],
            dateText: "8.20 周三",
            updatedAt: date
        )
    }
}

nonisolated struct HoloWidgetTodoItem: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let isCompleted: Bool
    /// 3=紧急 2=高 1=中 0=低（TodoTask.priority 同口径）
    let priority: Int
    let isOverdue: Bool
}

// MARK: - Goal（目标进度）

nonisolated struct HoloWidgetGoalSnapshot: Codable, Equatable {
    /// 当前没有进行中的目标时为 nil（组件展示空态）
    let goal: HoloWidgetGoalItem?
    let updatedAt: Date

    static func empty(date: Date = Date()) -> HoloWidgetGoalSnapshot {
        HoloWidgetGoalSnapshot(goal: nil, updatedAt: date)
    }

    static func sample(date: Date = Date()) -> HoloWidgetGoalSnapshot {
        HoloWidgetGoalSnapshot(
            goal: HoloWidgetGoalItem(
                goalId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                title: "MacBook 基金",
                icon: "💻",
                progress: 0.68,
                percentText: "68%",
                currentText: "¥10,200",
                targetText: "¥15,000",
                remainingText: "¥4,800",
                forecastText: "按当前节奏 · 预计 10.24 达成",
                kindText: nil
            ),
            updatedAt: date
        )
    }
}

nonisolated struct HoloWidgetGoalItem: Codable, Equatable {
    let goalId: UUID
    let title: String
    /// emoji
    let icon: String
    /// 0~1；过程型目标为 nil（组件走「行动中」展示）
    let progress: Double?
    let percentText: String?
    let currentText: String?
    let targetText: String?
    let remainingText: String?
    /// 如 "按当前节奏 · 预计 10.24 达成" / "已达成 🎉"
    let forecastText: String?
    /// 过程型目标的说明行
    let kindText: String?

    var detailDeepLink: URL {
        URL(string: "holo://goals/detail?id=\(goalId.uuidString)")!
    }
}

// MARK: - Anniversary（纪念日倒数）

nonisolated struct HoloWidgetAnniversarySnapshot: Codable, Equatable {
    /// 距今天数升序（未来的在前），最多 3 条
    let items: [HoloWidgetAnniversaryItem]
    let updatedAt: Date

    static func empty(date: Date = Date()) -> HoloWidgetAnniversarySnapshot {
        HoloWidgetAnniversarySnapshot(items: [], updatedAt: date)
    }

    static func sample(date: Date = Date()) -> HoloWidgetAnniversarySnapshot {
        HoloWidgetAnniversarySnapshot(
            items: [
                HoloWidgetAnniversaryItem(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    title: "妈妈生日",
                    icon: "🎂",
                    monthText: "9月",
                    dayText: "01",
                    dateText: "9.1 · 周二",
                    days: 12
                ),
                HoloWidgetAnniversaryItem(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    title: "结婚纪念日",
                    icon: "💐",
                    monthText: "9月",
                    dayText: "15",
                    dateText: "9.15 · 周二",
                    days: 26
                ),
                HoloWidgetAnniversaryItem(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    title: "东京之行出发",
                    icon: "✈️",
                    monthText: "10月",
                    dayText: "03",
                    dateText: "10.3 · 周六",
                    days: 44
                )
            ],
            updatedAt: date
        )
    }
}

nonisolated struct HoloWidgetAnniversaryItem: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    /// emoji
    let icon: String
    /// "9月"
    let monthText: String
    /// "01"（两位补零）
    let dayText: String
    /// "9.1 · 周二"（每年重复的取下一个周年日）
    let dateText: String
    /// 正=未来还有 N 天；0=就是今天；负=已过 N 天
    let days: Int

    var displayDays: Int { abs(days) }

    var isToday: Bool { days == 0 }
}

private nonisolated extension URL {
    func queryValue(for name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}
