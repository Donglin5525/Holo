//
//  CalendarViewModel.swift
//  Holo
//
//  日历视图 ViewModel：focusedDate 单一事实源，日/周/月三档全部从它派生。
//  数据通道统一为 timelineEvents 滑动窗口（±60 天预载 + 边缘续载），三档共用，不再按档位分通道取数。
//  init 零 I/O（只注入 Repository 引用），取数由 View.task 触发（CLAUDE.md 约定）。
//

import Foundation
import SwiftUI
import Combine
import CoreData
import os.log

/// 月历色块形式（热力色深 / 数字徽章）——MonthlyCalendarView 显示形式参数
enum MonthCellStyle: Hashable {
    case heatmap
    case badge
}

/// 日历时间刻度（L1 三档合一）：日=单日回放、周=本周七天网格、月=热力月历。
/// 三档是同一段生活记录的三种观察距离，共享同一个聚焦日期。
enum CalendarScale: String, CaseIterable {
    /// 按日看：单日回放
    case day
    /// 按周看：多日时间网格（本周七天，三日可视窗口）
    case week
    /// 按月看：热力月历
    case month
    /// 按时间轴看：0–24 点纵向刻度，任务时间段与系统日程同轴回放（三期）
    case timeline

    var displayName: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        case .timeline: return "轴"
        }
    }
}

@MainActor
final class CalendarViewModel: ObservableObject {

    // MARK: - 单一事实源（统一浏览方案 §6.1）

    /// 聚焦日期：日档回放它、周档高亮它所在周、月历锚定它所在月。
    /// 页面上不再有 anchor / gridCenterDay / selectedDay 等平行日期状态，全部由它派生。
    @Published var focusedDate: Date = Calendar.current.startOfDay(for: Date())

    @Published var scale: CalendarScale = .day

    /// 模块筛选（nil = 全部），三档间保持
    @Published var moduleFilter: CalendarModule? = nil

    /// 待办时间维度（完成/到期）
    @Published var todoDimension: TodoTimeDimension = .completed

    // MARK: - 时间线数据通道（日/周/月共享）

    /// 预载到内存的原始事件（未筛选）：切日/切周/翻月直接取，不边滑边查库；
    /// 切换 moduleFilter 即时过滤，不用重查
    @Published private(set) var timelineEvents: [CalendarEvent] = []

    /// 最近一次拉取的模块加载状态（失败不静默，三档共用）
    @Published private(set) var timelineResult: CalendarEventsResult = .empty

    /// 已加载的数据范围（接近边缘自动续载）
    private var loadedRange: DateInterval?

    /// 是否正在初次加载
    @Published private(set) var isInitialLoading: Bool = false

    /// 预载半径（天）：窗口内切日/切周/翻月即时显示缓存数据
    private let preloadHalfSpanDays = 60
    /// 首屏半径（天）：打开页面只拉当前回放窗口与近程翻页所需数据，
    /// 全量预载错峰补齐——首帧不与 ±60 天四模块查询抢主线程。
    private let initialHalfSpanDays = 20
    /// 首帧渲染后等待这段时间再拉全量，避开转场与首屏布局的高峰。
    private let fullPreloadDelayNanoseconds: UInt64 = 400_000_000
    /// 距边缘剩余天数低于此值时触发续载
    private let edgeMarginDays = 14
    /// 取数进行中标记：续载/预载/重试共用一条主线程通道，并行触发时只跑一个，
    /// 被丢弃的请求由下一次边缘检查自然补上。
    private var isFetchInFlight = false

    // MARK: - 周叙事（高光/里程碑，周档摘要卡轻量入口消费）

    @Published private(set) var weekHighlights: [HighlightData] = []
    @Published private(set) var weekMilestones: [MilestoneData] = []

    private let provider: CalendarEventProvider

    init(provider: CalendarEventProvider? = nil) {
        self.provider = provider ?? CalendarEventProvider(
            financeRepo: .shared,
            habitRepo: .shared,
            todoRepo: .shared,
            thoughtRepo: ThoughtRepository()
        )
    }

    // MARK: - 区间与标题（全部从 focusedDate 派生）

    var currentWeekRange: DateInterval { CalendarRangeBuilder.weekRange(around: focusedDate) }
    var currentMonthRange: DateInterval { CalendarRangeBuilder.monthRange(focusedDate) }

    /// 本周七天（周一首）：周档网格渲染与翻页的唯一日期数据源
    var currentWeekDays: [Date] {
        let cal = Calendar.current
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: currentWeekRange.start) }
    }

    /// 回正按钮按观察尺度命名，避免月档仍写「今天」造成动作语义不清。
    var todayLabel: String {
        switch scale {
        case .day: return "今天"
        case .week: return "本周"
        case .month: return "本月"
        case .timeline: return "今天"
        }
    }

    /// 是否已处在当前期（「今天/本周」置灰免点）
    var isAtCurrentPeriod: Bool {
        switch scale {
        case .day:  return Calendar.current.isDateInToday(focusedDate)
        case .week: return CalendarRangeBuilder.weekRange(around: focusedDate).contains(Date())
        case .month: return Calendar.current.isDate(focusedDate, equalTo: Date(), toGranularity: .month)
        case .timeline: return Calendar.current.isDateInToday(focusedDate)
        }
    }

    /// 未来导航限制：记忆长廊只回看已经发生的生活，三档都不翻到当前期之后。
    var canStepForward: Bool {
        !isAtCurrentPeriod
    }

    var hasFailure: Bool { timelineResult.hasFailure }

    // MARK: - 筛选派生数据

    private var filteredTimeline: [CalendarEvent] {
        guard let filter = moduleFilter else { return timelineEvents }
        return timelineEvents.filter { $0.module == filter }
    }

    /// 日档：聚焦日当天事件（已筛选）
    var focusedDayEvents: [CalendarEvent] {
        let range = CalendarRangeBuilder.dayRange(focusedDate)
        return filteredTimeline.filter { CalendarRangeBuilder.contains($0.date, in: range) }
    }

    /// 周档网格 / 日档日期珠：按天分组的筛选事件（key = startOfDay）
    var eventsByDay: [Date: [CalendarEvent]] {
        let cal = Calendar.current
        return Dictionary(grouping: filteredTimeline) { cal.startOfDay(for: $0.date) }
    }

    /// 月档：本月按天分组（key = startOfDay）
    var monthEventsByDay: [Date: [CalendarEvent]] {
        let range = currentMonthRange
        let cal = Calendar.current
        let inMonth = filteredTimeline.filter { CalendarRangeBuilder.contains($0.date, in: range) }
        return Dictionary(grouping: inMonth) { cal.startOfDay(for: $0.date) }
    }

    /// 月档当天详情卡（聚焦日）事件
    var selectedDayEvents: [CalendarEvent] { focusedDayEvents }

    /// 当前观察尺度内的筛选后事件。时间章节、观察摘要与主体内容统一使用这份事实。
    var currentPeriodEvents: [CalendarEvent] {
        switch scale {
        case .day:
            return focusedDayEvents
        case .week:
            return filteredTimeline.filter { CalendarRangeBuilder.contains($0.date, in: currentWeekRange) }
        case .month:
            return filteredTimeline.filter { CalendarRangeBuilder.contains($0.date, in: currentMonthRange) }
        case .timeline:
            return focusedDayEvents
        }
    }

    /// 周/月时间章节：大时间标题与证据合并，不再额外堆一行日期标题和统计卡。
    var chapterPresentation: MemoryTimeChapterPresentation {
        let events = currentPeriodEvents
        let calendar = Calendar.current
        let activeDayCount = Set(events.map { calendar.startOfDay(for: $0.date) }).count
        let momentCount = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
            .values
            .reduce(0) { $0 + DailyReplayPresentation.moments(from: $1).count }
        let reliable = events.filter(\.hasReliableTime).sorted { $0.date < $1.date }
        let range: DateInterval
        let chapterScale: MemoryTimeChapterScale

        switch scale {
        case .day:
            range = CalendarRangeBuilder.dayRange(focusedDate)
            chapterScale = .day
        case .week:
            range = currentWeekRange
            chapterScale = .week
        case .month:
            range = currentMonthRange
            chapterScale = .month
        case .timeline:
            range = CalendarRangeBuilder.dayRange(focusedDate)
            chapterScale = .day
        }

        return MemoryTimeChapterPresentation.make(
            scale: chapterScale,
            focusedDate: focusedDate,
            periodStart: range.start,
            periodEnd: range.end,
            eventCount: events.count,
            momentCount: momentCount,
            activeDayCount: activeDayCount,
            firstEventDate: reliable.first?.date,
            lastEventDate: reliable.last?.date,
            isCurrentPeriod: isAtCurrentPeriod
        )
    }

    /// 日档日期珠的模块提示（key = startOfDay → 当天出现过的模块集合）
    var dayModuleHints: [Date: Set<CalendarModule>] {
        let cal = Calendar.current
        var hints: [Date: Set<CalendarModule>] = [:]
        for event in filteredTimeline {
            hints[cal.startOfDay(for: event.date), default: []].insert(event.module)
        }
        return hints
    }

    /// 日档日期珠拖动轻提示的计数（key = startOfDay → 当天事件数）
    var dayEventCounts: [Date: Int] {
        let cal = Calendar.current
        return Dictionary(grouping: filteredTimeline) { cal.startOfDay(for: $0.date) }
            .mapValues(\.count)
    }

    // MARK: - 观察摘要（按档位口径：日=当天、周=本周、月=本月）

    var observationSummary: CalendarObservationSummary {
        switch scale {
        case .day:
            return CalendarObservationSummary.make(
                events: focusedDayEvents,
                scope: .day,
                moduleFilter: moduleFilter
            )
        case .week:
            return CalendarObservationSummary.make(events: currentPeriodEvents, scope: .week)
        case .month:
            return CalendarObservationSummary.make(events: currentPeriodEvents, scope: .month)
        case .timeline:
            return CalendarObservationSummary.make(
                events: focusedDayEvents,
                scope: .day,
                moduleFilter: moduleFilter
            )
        }
    }

    // MARK: - 加载

    /// 进日历页时调用：首屏只拉小窗口立即可交互，全量 ±60 天错峰补齐。
    func loadInitial() async {
        guard loadedRange == nil else { return }       // 已预载过，不重复
        isInitialLoading = true
        await fetchTimeline(around: focusedDate, halfSpanDays: initialHalfSpanDays)
        isInitialLoading = false
        refreshWeekNarrative()

        try? await Task.sleep(nanoseconds: fullPreloadDelayNanoseconds)
        await fetchTimeline(around: focusedDate, halfSpanDays: preloadHalfSpanDays)
    }

    /// 聚焦日接近已加载边缘时续载（剩余 < 14 天触发）
    func ensureTimelineData(around center: Date) {
        guard let loaded = loadedRange else { return }
        let cal = Calendar.current
        let dayBeforeEdge = cal.date(byAdding: .day, value: edgeMarginDays, to: loaded.start) ?? loaded.start
        let dayAfterEdge = cal.date(byAdding: .day, value: -edgeMarginDays, to: loaded.end) ?? loaded.end
        if center < dayBeforeEdge || center >= dayAfterEdge {
            Task { await fetchTimeline(around: center) }
        }
    }

    /// 下拉刷新/失败重试：刷新时间线窗口（三档共用一个通道）
    func refreshForCurrentScale() async {
        await fetchTimeline(around: focusedDate)
        refreshWeekNarrative()
    }

    /// 取数：以 center 为中心取指定半径窗口，与已加载窗口合并（按 originID 去重）。
    /// 续载 = 扩展窗口取并集，不是覆盖替换——避免滑动中途把屏幕上看得到的事件刷没。
    /// originID 是原始 Core Data 实体 ID，同一条记录稳定不变，可可靠判重。
    private func fetchTimeline(around center: Date, halfSpanDays: Int? = nil) async {
        guard !isFetchInFlight else { return }
        isFetchInFlight = true
        defer { isFetchInFlight = false }

        let span = halfSpanDays ?? preloadHalfSpanDays
        let cal = Calendar.current
        guard let fetchStart = cal.date(byAdding: .day, value: -span, to: cal.startOfDay(for: center)),
              let fetchEnd = cal.date(byAdding: .day, value: span, to: cal.startOfDay(for: center)) else { return }
        let fetchRange = DateInterval(start: fetchStart, end: fetchEnd)
        let fetched = await provider.fetchEvents(in: fetchRange, todoDimension: todoDimension)

        let newStart = loadedRange.map { min($0.start, fetchRange.start) } ?? fetchRange.start
        let newEnd = loadedRange.map { max($0.end, fetchRange.end) } ?? fetchRange.end
        loadedRange = DateInterval(start: newStart, end: newEnd)
        timelineResult = fetched

        var seen = Set(timelineEvents.map { $0.originID })
        var merged = timelineEvents
        for ev in fetched.events where seen.insert(ev.originID).inserted {
            merged.append(ev)
        }
        timelineEvents = merged
    }

    // MARK: - 周叙事（高光/里程碑，与记忆长廊时间线同一检测器，口径一致）

    private func refreshWeekNarrative() {
        let week = currentWeekRange
        let cal = Calendar.current
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: week.start) }

        let detected = HighlightDetector.detect(for: days, context: CoreDataStack.shared.viewContext)
        weekHighlights = days.flatMap { detected[cal.startOfDay(for: $0)] ?? [] }

        weekMilestones = MilestoneDetector.detect(context: CoreDataStack.shared.viewContext)
            .filter { CalendarRangeBuilder.contains($0.date, in: week) }
            .map(\.data)
    }

    // MARK: - 导航

    /// 切换时间刻度：聚焦日期保持不变（统一浏览方案 §6.2 切换规则）
    func switchScale(_ s: CalendarScale) {
        guard scale != s else { return }
        scale = s
        ensureTimelineData(around: focusedDate)
        if s == .week { refreshWeekNarrative() }
    }

    /// 箭头步进：日 ±1 天、周 ±1 周、月 ±1 月，全部只改 focusedDate
    func step(by delta: Int) {
        let cal = Calendar.current
        let today = Date()
        let component: Calendar.Component = scale == .month ? .month : (scale == .week ? .weekOfYear : .day)
        guard var next = cal.date(byAdding: component, value: delta, to: focusedDate) else { return }
        next = cal.startOfDay(for: next)

        // 未来限制：任何尺度都不越过当前期。
        if delta > 0 && next > today {
            next = cal.startOfDay(for: today)
        }
        guard !cal.isDate(next, inSameDayAs: focusedDate) else { return }

        focusedDate = next
        ensureTimelineData(around: next)
        if scale == .week { refreshWeekNarrative() }
    }

    /// 回到今天/本周/本月：聚焦日期归位，不切档
    func goToToday() {
        focusedDate = Calendar.current.startOfDay(for: Date())
        ensureTimelineData(around: focusedDate)
        if scale == .week { refreshWeekNarrative() }
    }

    /// 聚焦某一天（月历点日期 / 周网格点日期头 / 日档日期珠切日）。
    /// 只改聚焦日期，不切档不翻页——下钻由明确的「回放这一天」动作触发。
    func focusDay(_ day: Date) {
        let next = Calendar.current.startOfDay(for: day)
        guard next != Calendar.current.startOfDay(for: focusedDate) else { return }
        focusedDate = next
        ensureTimelineData(around: next)
    }

    /// 月档「回放这一天」：保持日期，切到日档
    func enterDayReplay() {
        scale = .day
    }

}
