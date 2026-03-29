//
//  HabitStatsState.swift
//  Holo
//
//  习惯统计模块的状态管理
// 参考 FinanceAnalysisState 模式实现
//

import SwiftUI
import Combine

// MARK: - HabitStatsDateRange

/// 习惯统计时间范围（区别于 HabitDateRange）
enum HabitStatsDateRange: String, CaseIterable, Identifiable {
    case week = "7"      // 近 7 天
    case month = "30"    // 近 30 天
    case quarter = "90"  // 近 90 天
    case all = "all"     // 全部

    var id: String { rawValue }

    /// 显示名称
    var displayName: String {
        switch self {
        case .week: return "7天"
        case .month: return "30天"
        case .quarter: return "90天"
        case .all: return "全部"
        }
    }

    /// 天数（nil 表示全部）
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        }
    }

    /// 获取日期范围
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

// MARK: - HabitTypeFilter

/// 习惯类型筛选
enum HabitTypeFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case checkIn = "checkIn"
    case count = "count"
    case measure = "measure"

    var id: String { rawValue }

    /// 显示名称
    var displayName: String {
        switch self {
        case .all: return "全部"
        case .checkIn: return "打卡型"
        case .count: return "计数类"
        case .measure: return "测量类"
        }
    }

    /// 筛选图标
    var icon: String {
        switch self {
        case .all: return "tray.full.fill"
        case .checkIn: return "checkmark.circle"
        case .count: return "number"
        case .measure: return "chart.line.uptrend.xyaxis"
        }
    }
}

// MARK: - DailyCompletionData

/// 每日完成率数据
struct DailyCompletionData: Identifiable {
    let date: Date
    let completionRate: Double  // 0-100
    var id: Date { date }
}

// MARK: - HabitRankingItem

/// 习惯排行榜项
struct HabitRankingItem: Identifiable {
    let habitId: UUID
    let name: String
    let icon: String
    let color: String
    let completionRate: Double
    let streak: Int
    var id: UUID { habitId }

    /// 习惯颜色
    var habitColor: Color {
        HabitColorPresets.color(from: color)
    }
}

// MARK: - HabitStatsItem

/// 习惯统计项（用于习惯列表）
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

    /// 习惯类型
    var type: HabitType {
        HabitType(rawValue: typeRaw) ?? .checkIn
    }

    /// 聚合类型
    var aggregationType: HabitAggregationType {
        HabitAggregationType(rawValue: aggregationTypeRaw) ?? .sum
    }

    /// 习惯颜色
    var habitColor: Color {
        HabitColorPresets.color(from: color)
    }

    /// 是否为打卡型
    var isCheckInType: Bool {
        type == .checkIn
    }

    /// 是否为计数类
    var isCountType: Bool {
        type == .numeric && aggregationType == .sum
    }

    /// 是否为测量类
    var isMeasureType: Bool {
        type == .numeric && aggregationType == .latest
    }

    /// 单位文本
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

    /// 今日完成率（0-100）
    var todayCompletionRate: Double {
        guard totalHabits > 0 else { return 0 }
        return Double(todayCompleted) / Double(totalHabits) * 100
    }

    /// 空数据
    static func empty() -> HabitOverviewStats {
        HabitOverviewStats(
            todayCompleted: 0,
            totalHabits: 0,
            averageCompletionRate: 0,
            totalStreak: 0
        )
    }
}

// MARK: - HabitStatsState

/// 习惯统计模块状态管理器
@MainActor
class HabitStatsState: ObservableObject {

    // MARK: - 发布属性

    /// 当前选中的时间范围
    @Published var selectedDateRange: HabitStatsDateRange = .month

    /// 当前选中的类型筛选
    @Published var typeFilter: HabitTypeFilter = .all

    /// 总览统计数据
    @Published var overviewStats: HabitOverviewStats = .empty()

    /// 完成率趋势数据
    @Published var completionTrend: [DailyCompletionData] = []

    /// 习惯排行榜
    @Published var habitRanking: [HabitRankingItem] = []

    /// 习惯统计项列表
    @Published var habitStatsItems: [HabitStatsItem] = []

    /// 是否正在加载
    @Published var isLoading: Bool = false

    /// 当前选中的 Tab（0: 总览, 1: 习惯）
    @Published var selectedTab: Int = 0

    /// 展开的习惯 ID
    @Published var expandedHabitId: UUID?

    // MARK: - 私有属性

    private let repository = HabitRepository.shared

    // MARK: - 计算属性

    /// 筛选后的习惯统计项
    var filteredHabitStatsItems: [HabitStatsItem] {
        switch typeFilter {
        case .all:
            return habitStatsItems
        case .checkIn:
            return habitStatsItems.filter { $0.isCheckInType }
        case .count:
            return habitStatsItems.filter { $0.isCountType }
        case .measure:
            return habitStatsItems.filter { $0.isMeasureType }
        }
    }

    // MARK: - 初始化

    init() {
        Task { await loadData() }
    }

    // MARK: - 时间范围操作

    /// 切换时间范围
    /// 注意：HabitTimeRangeSelector 通过 @Binding 已经先修改了 selectedDateRange，
    /// 所以这里不需要再赋值，只需触发数据重新加载
    func setDateRange(_ range: HabitStatsDateRange) {
        Task { await loadData() }
    }

    /// 切换类型筛选
    func setTypeFilter(_ filter: HabitTypeFilter) {
        typeFilter = filter
    }

    // MARK: - 数据加载

    /// 加载所有数据
    func loadData() async {
        isLoading = true

        // 加载总览统计
        overviewStats = repository.getOverviewStats(range: selectedDateRange)

        // 加载完成率趋势
        completionTrend = repository.getOverallCompletionTrend(range: selectedDateRange)

        // 加载排行榜
        habitRanking = repository.getHabitRanking(range: selectedDateRange, limit: 5)

        // 加载习惯统计项
        habitStatsItems = repository.getHabitStatsItems(range: selectedDateRange, filter: typeFilter)

        isLoading = false
    }

    /// 刷新数据（数据变更后调用）
    func refresh() {
        Task { await loadData() }
    }

    // MARK: - 交互操作

    /// 切换习惯展开状态
    func toggleHabitExpansion(_ habitId: UUID) {
        if expandedHabitId == habitId {
            expandedHabitId = nil
        } else {
            expandedHabitId = habitId
        }
    }
}
