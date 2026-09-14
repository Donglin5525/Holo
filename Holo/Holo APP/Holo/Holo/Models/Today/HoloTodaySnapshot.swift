//
//  HoloTodaySnapshot.swift
//  Holo
//
//  「今天」统一读模型契约（今日看板 Matter 化方案 §6）
//
//  - 纯值类型：不持有 NSManagedObject，可跨线程传递、可 Equatable 比较；
//  - referenceTime/dayStart/dayEnd 冻结在同一次构建，避免各模块跨午夜口径不一致；
//  - sectionStates 区分 缺数据 与 真实 0，局部失败不让整页空白；
//  - primaryFocus 由唯一 HoloTodayFocusResolver 决定，UI 不做第二套排序。
//

import Foundation

// MARK: - 快照主体

nonisolated struct HoloTodaySnapshot: Equatable, Sendable {
    /// 本次构建的判定时刻（所有相对时间计算以此为基准）。
    let referenceTime: Date
    let dayStart: Date
    let dayEnd: Date
    let timeZoneIdentifier: String
    let generatedAt: Date
    let freshness: HoloTodayFreshness
    let primaryFocus: HoloTodayFocus?
    let matters: [HoloTodayMatterItem]
    let agenda: [HoloTodayAgendaItem]
    let routine: HoloTodayRoutineSummary
    let overview: HoloTodayOverview
    let sectionStates: [HoloTodaySection: HoloTodaySectionState]
}

nonisolated enum HoloTodayFreshness: Equatable, Sendable {
    /// 首次构建中（UI 显示骨架）。
    case loading
    /// 全部模块成功。
    case fresh
    /// 部分模块失败，已展示缓存或空态。
    case partial
    /// 全部模块失败，整页使用最后一次成功快照。
    case stale
}

// MARK: - 区块状态

nonisolated enum HoloTodaySection: String, CaseIterable, Sendable {
    case focus
    case matters
    case agenda
    case routine
    case overview
}

nonisolated enum HoloTodaySectionState: Equatable, Sendable {
    case loading
    case content
    case empty
    /// 构建失败；有缓存时记录缓存时间，UI 才允许写「最近可用」。
    case failed(lastSuccessfulAt: Date?)
}

// MARK: - Primary Focus（现在最值得推进）

nonisolated struct HoloTodayFocus: Equatable, Sendable, Identifiable {
    let id: String
    let source: HoloTodayFocusSource
    let title: String
    let reasonCode: HoloTodayFocusReason
    let reasonArguments: HoloTodayReasonArguments
    let dueAt: Date?
    let severity: HoloTodaySeverity
    let matterID: UUID?
    /// 唯一动作出口；卡片不得根据标题猜路由。
    let action: HoloTodayAction
}

nonisolated enum HoloTodayFocusSource: String, Sendable {
    case currentSchedule
    case upcomingSchedule
    case matterLinkedTask
    case matterOpenLoop
    case overdueTask
    case todayTask
    case habitWindow
}

/// 类型化原因：UI 在单一 renderer 中本地化，不拼接/解析自然语言。
nonisolated enum HoloTodayFocusReason: Equatable, Sendable {
    case scheduleInProgress
    case scheduleStartingSoon
    case overdueTask
    case matterAtRisk
    case matterNeedsAttention
    case dueToday
    case plannedToday
    case habitWindowOpen
}

/// 原因本地化所需的参数包（renderer 按 reasonCode 取用）。
nonisolated struct HoloTodayReasonArguments: Equatable, Sendable {
    var matterTitle: String?
    var minutesUntilStart: Int?
    var daysUntilTarget: Int?
    var overdueDays: Int?

    init(
        matterTitle: String? = nil,
        minutesUntilStart: Int? = nil,
        daysUntilTarget: Int? = nil,
        overdueDays: Int? = nil
    ) {
        self.matterTitle = matterTitle
        self.minutesUntilStart = minutesUntilStart
        self.daysUntilTarget = daysUntilTarget
        self.overdueDays = overdueDays
    }
}

nonisolated enum HoloTodaySeverity: String, Sendable {
    /// 红色系（holoError）：正在发生/已逾期的硬事实。
    case risk
    /// 主色系（holoPrimary）：需要今天关注。
    case attention
    /// 中性：按节奏推进即可。
    case normal
}

/// 唯一动作出口（方案 §6.1）：resolver 产出，dispatcher 消费。
nonisolated enum HoloTodayAction: Equatable, Sendable {
    case openTask(UUID)
    case openSchedule(String)
    case openMatter(UUID, focusOpenLoopID: UUID?)
    case createTaskFromOpenLoop(matterID: UUID, openLoopID: UUID)
    case discussMatter(UUID)
    case none
}

// MARK: - 进行中的事区块

nonisolated struct HoloTodayMatterItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    /// 确定性重算后的关注状态（不信任可能 stale 的投影）。
    let attention: HoloMatterAttention
    let attentionReason: String?
    /// 仅投影 fresh 时携带；stale 时为 nil，UI 不显示旧摘要。
    let summary: String?
    let nextActionTitle: String?
    /// nil = 还没有明确下一步（UI 显示「和 Holo 梳理」）。
    let nextAction: HoloTodayAction?
    let daysUntilTarget: Int?
    /// 待用户确认的 AI 建议数（提示「N 个建议待确认」）。
    let suggestedCount: Int
    /// 首个完整卡，其余紧凑行。
    let isFocus: Bool
    /// 整卡点击动作（进详情）。
    let cardAction: HoloTodayAction
}

// MARK: - 今天的安排区块

nonisolated struct HoloTodayAgendaItem: Equatable, Sendable, Identifiable {
    let id: String
    let kind: HoloTodayAgendaKind
    let title: String
    /// 日程开始时间或任务截止时间；无日期任务为 nil。
    let timeAt: Date?
    let isCompleted: Bool
    /// 关联 Matter 的轻标签（显示名称，不显示内部 ID）。
    let matterTitle: String?
    let action: HoloTodayAction
}

nonisolated enum HoloTodayAgendaKind: Equatable, Sendable {
    case scheduleOngoing
    case scheduleUpcoming
    case taskOverdue
    case taskDueToday
    case taskPlannedToday
    case taskRecent
}

// MARK: - 保持状态区块

nonisolated struct HoloTodayRoutineSummary: Equatable, Sendable {
    let habitCompleted: Int
    let habitTotal: Int
    /// 可展开快速打卡的行（仅未完成习惯；负向习惯只报告不鼓励打卡）。
    let habitRows: [HoloTodayHabitRow]
    let sleepHours: Double?
    let steps: Int?
    let healthAuthorized: Bool
    let hasHealthData: Bool

    static let empty = HoloTodayRoutineSummary(
        habitCompleted: 0,
        habitTotal: 0,
        habitRows: [],
        sleepHours: nil,
        steps: nil,
        healthAuthorized: false,
        hasHealthData: false
    )
}

nonisolated struct HoloTodayHabitRow: Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let isDone: Bool
    /// 负向（减少型）习惯：不以「打卡越多越好」形式渲染。
    let isNegative: Bool
    let isMeasurable: Bool
    /// 仓库侧已格式化的进度文本（如「2/3」或「1500/2000 ml」）。
    let progressText: String?
}

// MARK: - 今日概况区块

nonisolated struct HoloTodayOverview: Equatable, Sendable {
    /// 今日支出；nil = 加载失败（UI 显示 `--`，不误报 ¥0）。
    let spentToday: Decimal?
    /// 确定性超支/达风险阈值时为 true，提升为 attention signal。
    let budgetAtRisk: Bool

    static let unavailable = HoloTodayOverview(spentToday: nil, budgetAtRisk: false)
}
