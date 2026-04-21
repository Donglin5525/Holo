//
//  HabitStatsState.swift
//  Holo
//
//  习惯统计模块的状态管理
//  重构后：月度仪表板模式（当前自然月 + 周视图优先 + 单开展开月历）
//

import SwiftUI
import Combine

// MARK: - HabitStatsDateRange（旧接口兼容）

/// 习惯统计时间范围（区别于 HabitDateRange）
enum HabitStatsDateRange: String, CaseIterable, Identifiable {
    case week = "7"
    case month = "30"
    case quarter = "90"
    case all = "all"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .week: return "7天"
        case .month: return "30天"
        case .quarter: return "90天"
        case .all: return "全部"
        }
    }

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        }
    }

    func dateRange() -> ClosedRange<Date>? {
        guard let days = days else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return nil
        }
        return startDate...Date()
    }
}

// MARK: - HabitTypeFilter（旧接口兼容）

enum HabitTypeFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case checkIn = "checkIn"
    case count = "count"
    case measure = "measure"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .checkIn: return "打卡型"
        case .count: return "计数类"
        case .measure: return "测量类"
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full.fill"
        case .checkIn: return "checkmark.circle"
        case .count: return "number"
        case .measure: return "chart.line.uptrend.xyaxis"
        }
    }
}

// MARK: - DailyCompletionData（旧接口兼容）

struct DailyCompletionData: Identifiable {
    let date: Date
    let completionRate: Double
    var id: Date { date }
}

// MARK: - HabitRankingItem（旧接口兼容）

struct HabitRankingItem: Identifiable {
    let habitId: UUID
    let name: String
    let icon: String
    let color: String
    let completionRate: Double
    let streak: Int
    var id: UUID { habitId }

    var habitColor: Color {
        HabitColorPresets.color(from: color)
    }
}

// MARK: - HabitStatsItem（旧接口兼容）

struct HabitStatsItem: Identifiable {
    let habitId: UUID
    let name: String
    let icon: String
    let color: String
    let typeRaw: Int16
    let aggregationTypeRaw: Int16
    let streak: Int
    let completionRate: Double
    let todayValue: Double?
    let todayTarget: Double?
    let unit: String?
    let dailyData: [DailyHabitData]
    let calendarData: [Date: Bool]

    var id: UUID { habitId }

    var type: HabitType {
        HabitType(rawValue: typeRaw) ?? .checkIn
    }

    var aggregationType: HabitAggregationType {
        HabitAggregationType(rawValue: aggregationTypeRaw) ?? .sum
    }

    var habitColor: Color {
        HabitColorPresets.color(from: color)
    }

    var isCheckInType: Bool {
        type == .checkIn
    }

    var isCountType: Bool {
        type == .numeric && aggregationType == .sum
    }

    var isMeasureType: Bool {
        type == .numeric && aggregationType == .latest
    }

    var unitText: String {
        unit ?? (isCountType ? "次" : "")
    }
}

// MARK: - HabitOverviewStats

/// 总览统计数据
struct HabitOverviewStats {
    let todayCompleted: Int
    let totalHabits: Int
    let averageCompletionRate: Double
    let totalStreak: Int

    var todayCompletionRate: Double {
        guard totalHabits > 0 else { return 0 }
        return Double(todayCompleted) / Double(totalHabits) * 100
    }

    static func empty() -> HabitOverviewStats {
        HabitOverviewStats(
            todayCompleted: 0,
            totalHabits: 0,
            averageCompletionRate: 0,
            totalStreak: 0
        )
    }
}

// MARK: - 月度统计投影类型

/// 统计卡片习惯类型
enum HabitStatsCardKind: Equatable {
    case checkIn
    case count
    case measure
}

/// 月份格子中的一天
struct HabitStatsDayCell: Identifiable, Equatable {
    let date: Date
    let dayNumber: Int?
    let isInCurrentMonth: Bool
    let isToday: Bool
    let hasRecord: Bool
    var id: Date { date }
}

/// 一周的数据切片（折叠态）
struct HabitStatsWeekSlice: Equatable {
    let weekStart: Date
    let days: [HabitStatsDayCell]
}

/// 月度日历矩阵（展开态）
struct HabitStatsMonthSection: Equatable {
    let monthStart: Date
    let weekdaySymbols: [String]
    let rows: [[HabitStatsDayCell]]
}

/// 习惯卡片摘要（按类型区分）
enum HabitStatsCardSummary: Equatable {
    case checkIn(completedDays: Int, streak: Int)
    case count(recordedDays: Int, totalCountText: String)
    case measure(recordedDays: Int, averageValueText: String)
}

/// 统计页习惯展示项
struct HabitStatsDisplayItem: Identifiable, Equatable {
    let habitId: UUID
    let name: String
    let icon: String
    let habitColorHex: String
    let type: HabitStatsCardKind
    let summary: HabitStatsCardSummary
    let collapsedWeek: HabitStatsWeekSlice
    let allWeeks: [HabitStatsWeekSlice]
    let month: HabitStatsMonthSection
    var id: UUID { habitId }
}

// MARK: - HabitStatsState

/// 习惯统计模块状态管理器（月度仪表板）
@MainActor
class HabitStatsState: ObservableObject {

    // MARK: - 发布属性

    @Published var selectedMonth: Date = Date()
    @Published var expandedHabitId: UUID?
    @Published var summaryStats: HabitOverviewStats = .empty()
    @Published var displayItems: [HabitStatsDisplayItem] = []
    @Published var hasAnyHabits: Bool = false

    // MARK: - 私有属性

    private let repository: HabitRepository
    private let displaySettings: HabitStatsDisplaySettings
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - 初始化

    init(
        repository: HabitRepository = .shared,
        displaySettings: HabitStatsDisplaySettings = .shared
    ) {
        self.repository = repository
        self.displaySettings = displaySettings
        bindDisplaySettings()
        Task { await reload() }
    }

    // MARK: - 月份操作

    func selectMonth(_ month: Date) async {
        selectedMonth = month
        expandedHabitId = nil
        await reload()
    }

    // MARK: - 展开/收起

    func toggleExpansion(for habitId: UUID) {
        if expandedHabitId == habitId {
            expandedHabitId = nil
        } else {
            expandedHabitId = habitId
        }
    }

    // MARK: - 数据加载

    func reload() async {
        hasAnyHabits = !repository.activeHabits.isEmpty
        summaryStats = repository.getOverviewStats(
            forMonth: selectedMonth,
            visibleHabitIds: displaySettings.visibleHabitIds
        )
        displayItems = repository.getHabitStatsDisplayItems(
            month: selectedMonth,
            visibleHabitIds: displaySettings.visibleHabitIds,
            orderedHabitIds: displaySettings.orderedHabitIds
        )
    }

    /// 刷新数据（数据变更后调用）
    func refresh() {
        Task { await reload() }
    }

    // MARK: - 设置绑定

    private func bindDisplaySettings() {
        displaySettings.$visibleHabitIds
            .combineLatest(displaySettings.$orderedHabitIds)
            .sink { [weak self] _, _ in
                guard let self else { return }
                Task { await self.reload() }
            }
            .store(in: &cancellables)
    }
}
