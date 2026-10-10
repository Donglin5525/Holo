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
        case .day: return String(localized: "日")
        case .week: return String(localized: "周")
        case .month: return String(localized: "月")
        case .timeline: return String(localized: "轴")
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
    private(set) var timelineEvents: [CalendarEvent] = []
    @Published private(set) var presentationSnapshot = CalendarPresentationSnapshot.empty

    private var index: CalendarPresentationIndex { presentationSnapshot.index(for: moduleFilter) }
    var dayPresentations: [Date: CalendarDayPresentation] { index.days }

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
    /// 进行中保留最新请求，完成后顺序补齐。
    private var isFetchInFlight = false
    private var pendingFetch: (center: Date, span: Int)?
    private var narrativeTask: Task<Void, Never>?
    private var narrativeWeek: Date?

    // MARK: - 周叙事（高光/里程碑，周档摘要卡轻量入口消费）

    @Published private(set) var weekHighlights: [HighlightData] = []
    @Published private(set) var weekMilestones: [MilestoneData] = []

    private let provider: CalendarEventProvider

    init(provider: CalendarEventProvider? = nil) {
        self.provider = provider ?? CalendarEventProvider(context: CoreDataStack.shared.viewContext)
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
        case .day: return String(localized: "今天")
        case .week: return String(localized: "本周")
        case .month: return String(localized: "本月")
        case .timeline: return String(localized: "今天")
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

    /// 轴档未来排布上限（天）：轴是回放与排布的双面工具，过去回看、未来排事；
    /// 任务本身可排任意远，导航给一年封顶避免无限空翻，更远的排期走正常建任务。
    private static let timelineFutureLimitDays = 365

    /// 轴档能翻到的最远日期（一年后的今天，取当天零点）
    var timelineFutureLimit: Date {
        Calendar.current.date(
            byAdding: .day,
            value: Self.timelineFutureLimitDays,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Calendar.current.startOfDay(for: Date())
    }

    /// 轴档是否允许继续向未来步进（未到一年上限）
    private var canTimelineStepForward: Bool {
        Calendar.current.startOfDay(for: focusedDate) < timelineFutureLimit
    }

    /// 未来导航限制：日/周/月三档只回看已经发生的生活，不翻到当前期之后；
    /// 轴档例外——排布未来是它的本职，翻到一年上限为止。
    var canStepForward: Bool {
        scale == .timeline ? canTimelineStepForward : !isAtCurrentPeriod
    }

    var hasFailure: Bool { timelineResult.hasFailure }

    // MARK: - 筛选派生数据

    /// 取数完成后一次发布索引；滚动和切档不再重建事件分组与记忆时刻。
    var focusedDayEvents: [CalendarEvent] { index.eventsByDay[Calendar.current.startOfDay(for: focusedDate)] ?? [] }
    var eventsByDay: [Date: [CalendarEvent]] { index.eventsByDay }

    var monthEventsByDay: [Date: [CalendarEvent]] {
        let range = currentMonthRange
        return index.eventsByDay.filter { CalendarRangeBuilder.contains($0.key, in: range) }
    }

    var selectedDayEvents: [CalendarEvent] { focusedDayEvents }
    var selectedDayPresentation: CalendarDayPresentation {
        index.days[Calendar.current.startOfDay(for: focusedDate)]
            ?? CalendarDayPresentation(day: focusedDate, events: [])
    }

    private var periodPresentation: CalendarPeriodPresentation? {
        scale == .week ? index.weeks[currentWeekRange.start] : index.months[currentMonthRange.start]
    }

    var currentPeriodEvents: [CalendarEvent] {
        (scale == .day || scale == .timeline) ? focusedDayEvents : (periodPresentation?.events ?? [])
    }

    var chapterPresentation: MemoryTimeChapterPresentation {
        if scale == .day || scale == .timeline { return selectedDayPresentation.chapter }
        if let prepared = periodPresentation { return prepared.chapter }
        let range = scale == .week ? currentWeekRange : currentMonthRange
        return MemoryTimeChapterPresentation.make(
            scale: scale == .week ? .week : .month, focusedDate: focusedDate,
            periodStart: range.start, periodEnd: range.end,
            eventCount: 0, momentCount: 0, activeDayCount: 0,
            firstEventDate: nil, lastEventDate: nil, isCurrentPeriod: isAtCurrentPeriod
        )
    }

    var dayModuleHints: [Date: Set<CalendarModule>] {
        index.moduleHints
    }
    var dayEventCounts: [Date: Int] { index.eventCounts }

    var observationSummary: CalendarObservationSummary {
        if scale == .day || scale == .timeline {
            return CalendarObservationSummary.make(events: focusedDayEvents, scope: .day, moduleFilter: moduleFilter)
        }
        return periodPresentation?.observation
            ?? CalendarObservationSummary.make(events: [], scope: scale == .week ? .week : .month)
    }

    // MARK: - 加载

    /// 进日历页时调用：首屏只拉小窗口立即可交互，全量 ±60 天错峰补齐。
    func loadInitial() async {
        guard loadedRange == nil else { return }       // 已预载过，不重复
        isInitialLoading = true
        await fetchTimeline(around: focusedDate, halfSpanDays: initialHalfSpanDays)
        isInitialLoading = false
        if scale == .week { refreshWeekNarrative() }

        do { try await Task.sleep(nanoseconds: fullPreloadDelayNanoseconds) }
        catch { return }
        guard !Task.isCancelled else { return }
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
        if scale == .week { refreshWeekNarrative(force: true) }
    }

    /// 取数：以 center 为中心取指定半径窗口，与已加载窗口合并（按 originID 去重）。
    /// 续载 = 扩展窗口取并集，不是覆盖替换——避免滑动中途把屏幕上看得到的事件刷没。
    /// originID 是原始 Core Data 实体 ID，同一条记录稳定不变，可可靠判重。
    private func fetchTimeline(around center: Date, halfSpanDays: Int? = nil) async {
        let requestedSpan = halfSpanDays ?? preloadHalfSpanDays
        if isFetchInFlight {
            // 快速滚到另一段历史时保留最后一个请求；不能以“正在取数”为由永远漏掉它。
            pendingFetch = (center, requestedSpan)
            return
        }
        isFetchInFlight = true
        defer { isFetchInFlight = false }
        var request: (center: Date, span: Int)? = (center, requestedSpan)
        while let current = request, !Task.isCancelled {
            let cal = Calendar.current
            guard let fetchStart = cal.date(byAdding: .day, value: -current.span, to: cal.startOfDay(for: current.center)),
                  let fetchEnd = cal.date(byAdding: .day, value: current.span + 1, to: cal.startOfDay(for: current.center)) else { break }
            let fetchRange = DateInterval(start: fetchStart, end: fetchEnd)
            let fetched = await provider.fetchEvents(in: fetchRange, todoDimension: todoDimension)
            guard !Task.isCancelled else { break }
            // 跨年跳转不能把中间未取数的日期当成已加载，也不能为整段空洞创建展示快照。
            let newRange: DateInterval
            if let loadedRange, loadedRange.intersects(fetchRange) {
                newRange = DateInterval(start: min(loadedRange.start, fetchStart), end: max(loadedRange.end, fetchEnd))
            } else {
                newRange = fetchRange
            }
            let existing = timelineEvents
            let prepared = await Task.detached(priority: .userInitiated) {
                let merged = CalendarPresentationSnapshot.merging(existing: existing, fetched: fetched, range: fetchRange)
                return (merged, CalendarPresentationSnapshot(events: merged, range: newRange))
            }.value
            guard !Task.isCancelled else { break }
            loadedRange = newRange
            timelineEvents = prepared.0
            timelineResult = fetched
            presentationSnapshot = prepared.1
            if scale == .week { refreshWeekNarrative(force: true) }
            request = pendingFetch
            pendingFetch = nil
        }
    }

    // MARK: - 周叙事（高光/里程碑，与记忆长廊时间线同一检测器，口径一致）

    private func refreshWeekNarrative(force: Bool = false) {
        let week = currentWeekRange
        guard force || narrativeWeek != week.start else { return }
        if narrativeWeek != week.start {
            weekHighlights = []
            weekMilestones = []
        }
        narrativeWeek = week.start
        narrativeTask?.cancel()
        // 先呈现网格。检测只在后台读库，不在切档点击和滚动帧内逐日查询习惯。
        narrativeTask = Task {
            let snapshot = try? await CoreDataStack.shared.performBackgroundTask { context in
                let cal = Calendar.current
                let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: week.start) }
                let achievements = MemoryAchievementSnapshot(context: context)
                let detected = HighlightDetector.detect(for: days, context: context, achievements: achievements)
                let highlights = days.flatMap { detected[cal.startOfDay(for: $0)] ?? [] }
                let milestones = MilestoneDetector.detect(context: context, achievements: achievements)
                    .filter { CalendarRangeBuilder.contains($0.date, in: week) }.map(\.data)
                return (highlights, milestones)
            }
            guard !Task.isCancelled, currentWeekRange.start == week.start, let snapshot else { return }
            weekHighlights = snapshot.0
            weekMilestones = snapshot.1
        }
    }

    // MARK: - 导航

    /// 切换时间刻度：聚焦日期保持不变（统一浏览方案 §6.2 切换规则）。
    /// 例外：轴档可以聚焦未来日（排布），日/周/月只回看——离开轴档时
    /// 把未来的聚焦日期带回今天，避免三档出现「回放一个还没发生的日子」。
    func switchScale(_ s: CalendarScale) {
        guard scale != s else { return }
        if scale == .timeline && s != .timeline,
           focusedDate > Calendar.current.startOfDay(for: Date()) {
            focusedDate = Calendar.current.startOfDay(for: Date())
        }
        scale = s
        ensureTimelineData(around: focusedDate)
        if s == .week { refreshWeekNarrative() }
    }

    /// 箭头步进：日/轴 ±1 天、周 ±1 周、月 ±1 月，全部只改 focusedDate
    func step(by delta: Int) {
        let cal = Calendar.current
        let today = Date()
        let component: Calendar.Component = scale == .month ? .month : (scale == .week ? .weekOfYear : .day)
        guard var next = cal.date(byAdding: component, value: delta, to: focusedDate) else { return }
        next = cal.startOfDay(for: next)

        // 未来限制：日/周/月不越过当前期；轴档允许排布未来，钳在一年上限。
        if delta > 0 {
            if scale == .timeline {
                let limit = timelineFutureLimit
                if next > limit { next = limit }
            } else if next > today {
                next = cal.startOfDay(for: today)
            }
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
