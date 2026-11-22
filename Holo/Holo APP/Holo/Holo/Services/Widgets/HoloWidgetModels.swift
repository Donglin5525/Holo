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
    static let thoughtWalkPoolFileName = "widget_thought_walk_pool.json"
    static let thoughtWalkSelectionFileName = "widget_thought_walk_selection.json"
    static let healthFileName = "widget_health_snapshot.json"
    static let insightPoolFileName = "widget_insight_pool.json"
    static let insightSelectionFileName = "widget_insight_selection.json"
    static let memoryFileName = "widget_memory_snapshot.json"
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
    case dailyKanban = "HoloDailyKanbanWidget"
    case dailyInsight = "HoloDailyInsightWidget"
    case health = "HoloHealthWidget"
    case memoryGallery = "HoloMemoryGalleryWidget"
    case controlVoice = "HoloControlVoiceWidget"
    case controlBookkeeping = "HoloControlBookkeepingWidget"
    case controlThought = "HoloControlThoughtWidget"
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
        case .askHolo: return String(localized: "问 Holo")
        case .addTransaction: return String(localized: "记一笔")
        case .recordThought: return String(localized: "写想法")
        case .addTask: return String(localized: "加待办")
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
    /// 今日待办小组件：直达指定待办详情
    case taskDetail(id: UUID)
    case goalDetail(id: UUID)
    /// 纪念日倒数小组件：打开纪念日页
    case anniversaries
    /// 今日健康小组件：打开健康仪表盘
    case health
    /// 记忆长廊 / 每日洞察小组件：打开记忆长廊（可聚焦洞察 Tab）
    case memoryGallery(focusInsights: Bool)
    /// 每日洞察小组件：精准回放某条洞察
    case memoryInsight(id: UUID)
    /// 每日洞察小组件「追问 Holo」：携带洞察 ID 进聊天，由主 App 反查完整洞察上下文；
    /// 若洞察已删除或为示例态，回退使用 fallbackPrefill 预填文本。
    case insightFollowUp(id: UUID, fallbackPrefill: String?)
    /// 带预填问题进入 AI 对话
    case chat(prefill: String?)
    /// 今日全览小组件：回到首页今日看板
    case dailyKanban

    static func parse(_ url: URL) -> HoloWidgetDeepLink? {
        guard url.scheme == "holo" else { return nil }

        let path = [url.host, url.path]
            .compactMap { $0 }
            .joined()

        switch path {
        case "ai":
            return .ai(voiceInput: url.queryValue(for: "voiceInput") == "true")
        case "chat":
            let prefill = url.queryValue(for: "prefill")
            if let rawInsightId = url.queryValue(for: "insightId"),
               let insightId = UUID(uuidString: rawInsightId) {
                return .insightFollowUp(id: insightId, fallbackPrefill: prefill)
            }
            return .chat(prefill: prefill)
        case "home":
            return .dailyKanban
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
        case "tasks/detail":
            guard
                let rawId = url.queryValue(for: "id"),
                let id = UUID(uuidString: rawId)
            else { return nil }
            return .taskDetail(id: id)
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
        case "health":
            return .health
        case "memory":
            return .memoryGallery(focusInsights: url.queryValue(for: "focus") == "insights")
        case "insight/detail":
            guard
                let rawId = url.queryValue(for: "id"),
                let id = UUID(uuidString: rawId)
            else { return nil }
            return .memoryInsight(id: id)
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

    /// 今日支出：直接复用 weekExpense 末尾 isToday 桶，零破坏性兼容旧快照
    var todayExpense: Double {
        weekExpense?.last(where: \.isToday)?.amount ?? 0
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

/// 「想法随机漫步」候选池：主 App 预建的全部合格候选（摘要/标签/来源已解析），
/// 小组件「换一条」只在池内轮换显示，不自行访问数据库。
nonisolated struct HoloWidgetThoughtWalkSnapshot: Codable, Equatable {
    let items: [HoloWidgetThoughtMemorySnapshot]
    /// 当日主推下标（延续旧版按日期轮换口径，未手选时桌面显示不变）
    let featuredIndex: Int
    let updatedAt: Date
}

/// 用户点「换一条」的手选记录：当天内有效，次日自动恢复主推轮换
nonisolated struct HoloWidgetThoughtWalkSelection: Codable, Equatable {
    let thoughtId: UUID
    let date: Date

    func isActive(on date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(self.date, inSameDayAs: date)
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
            longestStreakText: String(localized: "34天"),
            habits: [
                HoloWidgetHabitItem(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    name: String(localized: "跑步 5 公里"),
                    icon: "figure.run",
                    streakText: String(localized: "12天"),
                    isCompletedToday: true,
                    weekPattern: [true, true, false, true, true, true, true]
                ),
                HoloWidgetHabitItem(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    name: String(localized: "喝够 8 杯水"),
                    icon: "drop.fill",
                    streakText: String(localized: "34天"),
                    isCompletedToday: true,
                    weekPattern: [true, true, true, true, true, true, true]
                ),
                HoloWidgetHabitItem(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    name: String(localized: "睡前阅读 20 分钟"),
                    icon: "book.fill",
                    streakText: String(localized: "8天"),
                    isCompletedToday: true,
                    weekPattern: [true, false, true, true, false, true, false]
                ),
                HoloWidgetHabitItem(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    name: String(localized: "冥想 10 分钟"),
                    icon: "figure.mind.and.body",
                    streakText: String(localized: "5天"),
                    isCompletedToday: false,
                    weekPattern: [true, true, true, false, true, false, false]
                ),
                HoloWidgetHabitItem(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    name: String(localized: "7 点前起床"),
                    icon: "leaf.fill",
                    streakText: String(localized: "21天"),
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
    /// 未完成总数（今天到期 + 逾期，与 items 列表同口径）——标题「剩 N 项」与列表
    /// 内容必须一致，否则全逾期日会出现「剩 0 项」配 3 条待办。var+默认值：旧快照
    /// JSON 无此 key 时按 0 解码，进前台刷新后即修正。
    var pendingCount: Int = 0

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
                    title: String(localized: "回复小组件设计稿意见"),
                    isCompleted: false,
                    priority: 3,
                    isOverdue: false
                ),
                HoloWidgetTodoItem(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    title: String(localized: "预约牙医复诊"),
                    isCompleted: false,
                    priority: 2,
                    isOverdue: false
                ),
                HoloWidgetTodoItem(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    title: String(localized: "给妈妈打电话"),
                    isCompleted: false,
                    priority: 1,
                    isOverdue: false
                ),
                HoloWidgetTodoItem(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    title: String(localized: "买咖啡豆"),
                    isCompleted: true,
                    priority: 0,
                    isOverdue: false
                )
            ],
            dateText: String(localized: "8.20 周三"),
            updatedAt: date,
            pendingCount: 3
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

    var detailDeepLink: URL {
        URL(string: "holo://tasks/detail?id=\(id.uuidString)") ?? URL(string: "holo://tasks")!
    }
}

// MARK: - Goal（目标进度）

nonisolated struct HoloWidgetGoalSnapshot: Codable, Equatable {
    /// 当前没有进行中的目标时为 nil（组件展示空态）
    let goal: HoloWidgetGoalItem?
    let updatedAt: Date
    /// 进行中的前 4 个目标（Large 多目标总览 & 长按编辑选目标用；旧快照缺省为 nil）
    var goals: [HoloWidgetGoalItem]? = nil

    var allGoals: [HoloWidgetGoalItem] {
        if let goals, !goals.isEmpty { return goals }
        return goal.map { [$0] } ?? []
    }

    static func empty(date: Date = Date()) -> HoloWidgetGoalSnapshot {
        HoloWidgetGoalSnapshot(goal: nil, updatedAt: date, goals: [])
    }

    static func sample(date: Date = Date()) -> HoloWidgetGoalSnapshot {
        let first = HoloWidgetGoalItem(
            goalId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: String(localized: "MacBook 基金"),
            icon: "desktopcomputer",
            progress: 0.68,
            percentText: "68%",
            currentText: "¥10,200",
            targetText: "¥15,000",
            remainingText: "¥4,800",
            forecastText: String(localized: "按当前节奏 · 预计 10.24 达成"),
            kindText: nil
        )
        let second = HoloWidgetGoalItem(
            goalId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: String(localized: "全年阅读 24 本"),
            icon: "book.fill",
            progress: 0.75,
            percentText: "75%",
            currentText: "18 本",
            targetText: "24 本",
            remainingText: "6 本",
            forecastText: nil,
            kindText: nil
        )
        let third = HoloWidgetGoalItem(
            goalId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            title: String(localized: "保持规律运动"),
            icon: "figure.run",
            progress: 0.50,
            percentText: "50%",
            currentText: "10 次",
            targetText: "20 次",
            remainingText: "10 次",
            forecastText: nil,
            kindText: nil
        )
        return HoloWidgetGoalSnapshot(
            goal: first,
            updatedAt: date,
            goals: [first, second, third]
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
    /// 如 "按当前节奏 · 预计 10.24 达成" / "已达成"
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
                    title: String(localized: "和小林的纪念日"),
                    icon: "heart.fill",
                    monthText: String(localized: "10月"),
                    dayText: "24",
                    dateText: String(localized: "10.24 · 周六"),
                    days: 51,
                    themeColorHex: "#EC4899",
                    subtitleText: String(localized: "第 3 个周年"),
                    cycleProgress: 0.86
                ),
                HoloWidgetAnniversaryItem(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    title: String(localized: "发工资"),
                    icon: "hourglass",
                    monthText: String(localized: "9月"),
                    dayText: "10",
                    dateText: String(localized: "9.10 · 周四"),
                    days: 7,
                    themeColorHex: "#60A5FA"
                ),
                HoloWidgetAnniversaryItem(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    title: String(localized: "领证纪念日"),
                    icon: "sparkles",
                    monthText: String(localized: "12月"),
                    dayText: "12",
                    dateText: String(localized: "12.12 · 周六"),
                    days: 100,
                    themeColorHex: "#EC4899",
                    subtitleText: String(localized: "第 5 个周年"),
                    cycleProgress: 0.62
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
    /// 主题色 hex（"#EC4899"），旧快照缺失时组件回退品牌色
    let themeColorHex: String?
    /// 语义行（"第 3 个周年"）
    let subtitleText: String?
    /// 每年重复的本轮周期进度（0...1），非重复为 nil
    let cycleProgress: Double?

    init(
        id: UUID,
        title: String,
        icon: String,
        monthText: String,
        dayText: String,
        dateText: String,
        days: Int,
        themeColorHex: String? = nil,
        subtitleText: String? = nil,
        cycleProgress: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.monthText = monthText
        self.dayText = dayText
        self.dateText = dateText
        self.days = days
        self.themeColorHex = themeColorHex
        self.subtitleText = subtitleText
        self.cycleProgress = cycleProgress
    }

    /// 旧版本快照缺新字段（themeColorHex 等）时按 nil 解码，不整包失败
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        icon = try c.decode(String.self, forKey: .icon)
        monthText = try c.decode(String.self, forKey: .monthText)
        dayText = try c.decode(String.self, forKey: .dayText)
        dateText = try c.decode(String.self, forKey: .dateText)
        days = try c.decode(Int.self, forKey: .days)
        themeColorHex = try? c.decodeIfPresent(String.self, forKey: .themeColorHex)
        subtitleText = try? c.decodeIfPresent(String.self, forKey: .subtitleText)
        cycleProgress = try? c.decodeIfPresent(Double.self, forKey: .cycleProgress)
    }

    var displayDays: Int { abs(days) }

    var isToday: Bool { days == 0 }
}

// MARK: - Health · 身心节律快照

nonisolated struct HoloWidgetHealthSnapshot: Codable, Equatable {
    let steps: Int
    let stepsGoal: Int
    let sleepHours: Double
    let sleepGoalHours: Double
    let activeMinutes: Int
    let vitalityScore: Int
    let statusLabel: String
    let insightSummary: String?
    let isAuthorized: Bool
    let updatedAt: Date

    var stepsProgress: Double {
        guard stepsGoal > 0 else { return 0 }
        return min(max(Double(steps) / Double(stepsGoal), 0), 1)
    }

    var sleepProgress: Double {
        guard sleepGoalHours > 0 else { return 0 }
        return min(max(sleepHours / sleepGoalHours, 0), 1)
    }

    var sleepText: String {
        guard sleepHours > 0 else { return "--" }
        let totalMinutes = Int((sleepHours * 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }

    var sleepShortText: String {
        guard sleepHours > 0 else { return "--" }
        return String(format: "%.1fh", sleepHours)
    }

    var stepsShortText: String {
        if steps >= 10_000 {
            return String(format: "%.1fw", Double(steps) / 10_000.0)
        }
        if steps >= 1_000 {
            return String(format: "%.1fk", Double(steps) / 1_000.0)
        }
        return "\(steps)"
    }

    static func sample(date: Date = Date()) -> HoloWidgetHealthSnapshot {
        HoloWidgetHealthSnapshot(
            steps: 7_420,
            stepsGoal: 8_000,
            sleepHours: 7.4,
            sleepGoalHours: 8.0,
            activeMinutes: 42,
            vitalityScore: 88,
            statusLabel: String(localized: "状态佳"),
            insightSummary: String(localized: "昨晚睡眠充足，精力恢复很好，适合安排高专注任务。"),
            isAuthorized: true,
            updatedAt: date
        )
    }

    static func unauthorized(date: Date = Date()) -> HoloWidgetHealthSnapshot {
        HoloWidgetHealthSnapshot(
            steps: 0,
            stepsGoal: 8_000,
            sleepHours: 0,
            sleepGoalHours: 8.0,
            activeMinutes: 0,
            vitalityScore: 0,
            statusLabel: String(localized: "未授权"),
            insightSummary: nil,
            isAuthorized: false,
            updatedAt: date
        )
    }
}

// MARK: - Daily Insight · 一个发现快照

nonisolated struct HoloWidgetInsightComparison: Codable, Equatable {
    let title: String
    let deltaText: String
    let primaryLabel: String
    let primaryRatio: Double
    let primaryValueText: String
    let secondaryLabel: String
    let secondaryRatio: Double
    let secondaryValueText: String
}

nonisolated struct HoloWidgetInsightItem: Codable, Equatable, Identifiable {
    let id: UUID
    let tag: String
    let badgeText: String
    let isWarning: Bool
    let title: String
    let body: String
    let metaText: String
    let comparison: HoloWidgetInsightComparison?
    let generatedAt: Date

    var detailDeepLink: URL {
        URL(string: "holo://insight/detail?id=\(id.uuidString)") ?? URL(string: "holo://memory?focus=insights")!
    }

    var askHoloDeepLink: URL {
        var components = URLComponents(string: "holo://chat")
        let prompt = String(localized: "展开说说这条发现：\(title)")
        components?.queryItems = [
            URLQueryItem(name: "insightId", value: id.uuidString),
            URLQueryItem(name: "prefill", value: prompt)
        ]
        return components?.url ?? URL(string: "holo://ai")!
    }
}

nonisolated struct HoloWidgetInsightPoolSnapshot: Codable, Equatable {
    let items: [HoloWidgetInsightItem]
    let updatedAt: Date

    static func sample(date: Date = Date()) -> HoloWidgetInsightPoolSnapshot {
        let first = HoloWidgetInsightItem(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444441")!,
            tag: String(localized: "消费 × 习惯"),
            badgeText: String(localized: "正向信号"),
            isWarning: false,
            title: String(localized: "早睡日的外卖消费明显更克制"),
            body: String(localized: "过去两周，你在 23:30 前入睡的日子里，次日餐饮与外卖支出比平时低了 18%，专注度更稳。"),
            metaText: String(localized: "基于近 14 天跨模块规律"),
            comparison: HoloWidgetInsightComparison(
                title: String(localized: "次日日均餐饮对比"),
                deltaText: String(localized: "-18% 波动"),
                primaryLabel: String(localized: "早睡日"),
                primaryRatio: 0.54,
                primaryValueText: "¥42",
                secondaryLabel: String(localized: "晚睡日"),
                secondaryRatio: 0.86,
                secondaryValueText: "¥68"
            ),
            generatedAt: date
        )
        let second = HoloWidgetInsightItem(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444442")!,
            tag: String(localized: "效率节律"),
            badgeText: String(localized: "本周观察"),
            isWarning: false,
            title: String(localized: "上午是你推进高优待办的黄金窗"),
            body: String(localized: "近三周高优先级待办有 74% 在中午前完成，且当天往往伴随 1 条以上想法记录。"),
            metaText: String(localized: "记忆长廊 · 每日自动更新"),
            comparison: nil,
            generatedAt: date
        )
        return HoloWidgetInsightPoolSnapshot(items: [first, second], updatedAt: date)
    }

    static func empty(date: Date = Date()) -> HoloWidgetInsightPoolSnapshot {
        HoloWidgetInsightPoolSnapshot(items: [], updatedAt: date)
    }
}

nonisolated struct HoloWidgetInsightSelection: Codable, Equatable {
    let insightId: UUID
    let date: Date

    func isActive(on referenceDate: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.isDate(date, inSameDayAs: referenceDate)
    }
}

// MARK: - Memory Gallery · 记忆长廊快照（生活热力图 & 历史上的今天）

nonisolated struct HoloWidgetOnThisDaySnapshot: Codable, Equatable {
    let labelText: String
    let dateText: String
    let excerpt: String
    let spendText: String?
    let habitText: String?
    let milestoneText: String?
    let thoughtId: UUID?

    var deepLink: URL {
        if let thoughtId {
            return URL(string: "holo://thoughts/detail?id=\(thoughtId.uuidString)") ?? URL(string: "holo://memory")!
        }
        return URL(string: "holo://memory")!
    }
}

nonisolated struct HoloWidgetMemorySnapshot: Codable, Equatable {
    let streakDays: Int
    let monthRecordCount: Int
    /// 最近 80 天逐日活跃等级（0...4），末尾为今天
    let heatmapLevels: [Int]
    let onThisDay: HoloWidgetOnThisDaySnapshot?
    let updatedAt: Date

    static func sample(date: Date = Date()) -> HoloWidgetMemorySnapshot {
        let levels = (0..<80).map { i in
            (i * 7 + (i % 5) * 3 + (i / 8)) % 5
        }
        return HoloWidgetMemorySnapshot(
            streakDays: 28,
            monthRecordCount: 64,
            heatmapLevels: levels,
            onThisDay: HoloWidgetOnThisDaySnapshot(
                labelText: String(localized: "1 年前的今天"),
                dateText: "2025.11.21",
                excerpt: String(localized: "第一次把每天的开销、习惯和念头串在一起回看，突然觉得平淡的日子也有了形状。"),
                spendText: String(localized: "当日 ¥86"),
                habitText: String(localized: "习惯 5/5"),
                milestoneText: String(localized: "早起满 30 天"),
                thoughtId: nil
            ),
            updatedAt: date
        )
    }

    static func empty(date: Date = Date()) -> HoloWidgetMemorySnapshot {
        HoloWidgetMemorySnapshot(
            streakDays: 0,
            monthRecordCount: 0,
            heatmapLevels: Array(repeating: 0, count: 80),
            onThisDay: nil,
            updatedAt: date
        )
    }
}

private nonisolated extension URL {
    func queryValue(for name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}
