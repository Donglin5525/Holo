//
//  CalendarViewModel.swift
//  Holo
//
//  日历视图 ViewModel：周历 / 月历共用，驱动取数与导航。
//  init 零 I/O（只注入 Repository 引用），取数由 View.task 触发（CLAUDE.md 约定）。
//  P2：加 moduleFilter（按模块过滤）+ todoDimension（待办时间维度）。
//

import Foundation
import SwiftUI
import Combine
import CoreData
import os.log

/// 周历单日聚合（按天分组的事件）
struct DayEvents: Identifiable, Equatable {
    let day: Date               // startOfDay
    let events: [CalendarEvent]
    var id: Date { day }
}

/// 周历视图模式（P2：列表 / 网格）
enum WeekViewMode: Hashable {
    case list
    case grid
}

/// 月历色块形式（P2：热力色深 / 数字徽章）
enum MonthCellStyle: Hashable {
    case heatmap
    case badge
}

@MainActor
final class CalendarViewModel: ObservableObject {

    static let defaultWeekViewMode: WeekViewMode = .grid

    enum Mode: Hashable {
        case weekly
        case monthly
    }

    /// 当前选定日（周/月各算区间）
    @Published var anchor: Date = Date()

    /// 当前模式
    @Published var mode: Mode = .weekly

    /// 月历选中的天（详情卡用）
    @Published var selectedDay: Date?

    /// 聚合结果（含每模块加载状态，失败不静默）
    @Published private(set) var result: CalendarEventsResult = .empty

    /// 是否正在加载
    @Published private(set) var isLoading: Bool = false

    /// P2 模块筛选（nil = 全部）
    @Published var moduleFilter: CalendarModule? = nil

    /// P2 待办时间维度（完成/到期/计划）
    @Published var todoDimension: TodoTimeDimension = .completed

    /// P2 周历视图模式（列表 / 网格）
    @Published var weekViewMode: WeekViewMode = defaultWeekViewMode

    /// P2 月历色块形式（热力 / 徽章）
    @Published var monthCellStyle: MonthCellStyle = .heatmap

    /// 3 日网格视图：当前中心日（今天/选中日落在中间列）
    @Published var gridCenterDay: Date = Date()

    /// 3 日网格视图：预载到内存的原始事件（未筛选）
    /// 滑动时直接取，不边滑边查库；切换 moduleFilter 即时过滤，不用重查
    @Published private(set) var gridRawEvents: [CalendarEvent] = []

    /// 3 日网格视图：已加载的数据范围（接近边缘自动续载）
    private var gridLoadedRange: DateInterval?

    /// 3 日网格视图：是否正在初次加载
    @Published private(set) var gridIsInitialLoading: Bool = false

    private let provider: CalendarEventProvider

    init(provider: CalendarEventProvider? = nil) {
        self.provider = provider ?? CalendarEventProvider(
            financeRepo: .shared,
            habitRepo: .shared,
            todoRepo: .shared,
            thoughtRepo: ThoughtRepository()
        )
    }

    // MARK: - 区间与标题

    var currentRange: DateInterval {
        switch mode {
        case .weekly:  return CalendarRangeBuilder.weekRange(around: anchor)
        case .monthly: return CalendarRangeBuilder.monthRange(anchor)
        }
    }

    var title: String {
        switch mode {
        case .weekly:
            let range = CalendarRangeBuilder.weekRange(around: anchor)
            let last = range.end.addingTimeInterval(-1)
            return "\(Self.rangeFormatter.string(from: range.start)) – \(Self.rangeFormatter.string(from: last))"
        case .monthly:
            return Self.monthFormatter.string(from: anchor)
        }
    }

    // MARK: - 衍生数据（按 moduleFilter 过滤）

    /// 当前筛选下的事件
    private var filteredEvents: [CalendarEvent] {
        guard let filter = moduleFilter else { return result.events }
        return result.events.filter { $0.module == filter }
    }

    /// 周历：按天分组的事件列表（组内升序、组间升序）
    var eventsByDay: [DayEvents] {
        let cal = Calendar.current
        return Dictionary(grouping: filteredEvents) { cal.startOfDay(for: $0.date) }
            .map { DayEvents(day: $0.key, events: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.day < $1.day }
    }

    /// 月历：按天分组的事件字典（key = startOfDay）
    var monthEventsByDay: [Date: [CalendarEvent]] {
        let cal = Calendar.current
        return Dictionary(grouping: filteredEvents) { cal.startOfDay(for: $0.date) }
    }

    /// 月历选中天的详情事件
    var selectedDayEvents: [CalendarEvent] {
        guard let day = selectedDay else { return [] }
        return monthEventsByDay[Calendar.current.startOfDay(for: day)] ?? []
    }

    var observationSummary: CalendarObservationSummary {
        CalendarObservationSummary.make(
            events: filteredEvents,
            scope: mode == .weekly ? .week : .month
        )
    }

    var hasFailure: Bool { result.hasFailure }

    // MARK: - 加载

    func load() async {
        isLoading = true
        result = await provider.fetchEvents(in: currentRange, todoDimension: todoDimension)
        isLoading = false
    }

    func switchMode(_ m: Mode) {
        guard mode != m else { return }
        mode = m
        Task { await load() }
    }

    func setModuleFilter(_ filter: CalendarModule?) {
        moduleFilter = filter
    }

    func setTodoDimension(_ d: TodoTimeDimension) {
        todoDimension = d
        Task { await load() }
    }

    // MARK: - 导航

    func goToPrev() {
        anchor = step(by: -1)
        Task { await load() }
    }

    func goToNext() {
        anchor = step(by: 1)
        Task { await load() }
    }

    func goToToday() {
        anchor = Date()
        selectedDay = Date()
        Task { await load() }
    }

    func selectDay(_ day: Date) {
        selectedDay = day
    }

    // MARK: - 3 日网格视图导航与数据

    /// 网格标题：显示中心日（如「8月10日 周一」）
    var gridTitle: String {
        Self.gridTitleFormatter.string(from: gridCenterDay)
    }

    /// 网格视图：当前筛选下的按天事件字典（key = startOfDay）
    var gridEventsByDay: [Date: [CalendarEvent]] {
        let cal = Calendar.current
        let filtered = gridFilteredEvents
        return Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
    }

    /// 网格箭头：按天步进（+1 往后一天，-1 往前一天）
    func gridStep(by delta: Int) {
        let next = Calendar.current.date(byAdding: .day, value: delta, to: gridCenterDay) ?? gridCenterDay
        gridCenterDay = next
        gridEnsureData(around: next)
    }

    /// 回到今天
    func gridGoToToday() {
        gridCenterDay = Date()
        gridEnsureData(around: Date())
    }

    /// 进网格视图时调用：预载中心日 ±60 天到内存
    func gridLoadInitial() async {
        if gridLoadedRange != nil { return }       // 已预载过，不重复
        gridIsInitialLoading = true
        await gridFetch(center: Date(), halfSpanDays: 60)
        gridIsInitialLoading = false
    }

    /// 滑动接近边缘时续载（剩余 < 14 天触发）
    func gridEnsureData(around center: Date) {
        guard let loaded = gridLoadedRange else { return }
        let cal = Calendar.current
        let dayBeforeEdge = cal.date(byAdding: .day, value: 14, to: loaded.start) ?? loaded.start
        let dayAfterEdge = cal.date(byAdding: .day, value: -14, to: loaded.end) ?? loaded.end
        if center < dayBeforeEdge || center >= dayAfterEdge {
            Task { await gridFetch(center: center, halfSpanDays: 60) }
        }
    }

    /// 取数：以 center 为中心取 ±halfSpanDays 天，与已加载数据合并（按 originID 去重）。
    /// 续载 = 扩展窗口（取并集），不是覆盖替换 —— 避免滑动中途把屏幕上看得到的事件刷没。
    /// originID 是原始 Core Data 实体 ID，同一条记录稳定不变，可可靠判重。
    private func gridFetch(center: Date, halfSpanDays: Int) async {
        let cal = Calendar.current
        guard let fetchStart = cal.date(byAdding: .day, value: -halfSpanDays, to: cal.startOfDay(for: center)),
              let fetchEnd = cal.date(byAdding: .day, value: halfSpanDays, to: cal.startOfDay(for: center)) else { return }
        let fetchRange = DateInterval(start: fetchStart, end: fetchEnd)
        let fetched = await provider.fetchEvents(in: fetchRange, todoDimension: todoDimension)

        let newStart = gridLoadedRange.map { min($0.start, fetchRange.start) } ?? fetchRange.start
        let newEnd = gridLoadedRange.map { max($0.end, fetchRange.end) } ?? fetchRange.end
        gridLoadedRange = DateInterval(start: newStart, end: newEnd)

        var seen = Set(gridRawEvents.map { $0.originID })
        var merged = gridRawEvents
        for ev in fetched.events where seen.insert(ev.originID).inserted {
            merged.append(ev)
        }
        gridRawEvents = merged
    }

    private var gridFilteredEvents: [CalendarEvent] {
        guard let filter = moduleFilter else { return gridRawEvents }
        return gridRawEvents.filter { $0.module == filter }
    }

    private func step(by delta: Int) -> Date {
        let component: Calendar.Component = (mode == .weekly) ? .weekOfYear : .month
        return Calendar.current.date(byAdding: component, value: delta, to: anchor) ?? anchor
    }

    // MARK: - 格式化

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f
    }()
    private static let gridTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f
    }()
}
