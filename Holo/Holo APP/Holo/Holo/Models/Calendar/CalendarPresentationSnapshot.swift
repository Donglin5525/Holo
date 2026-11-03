//
//  CalendarPresentationSnapshot.swift
//  Holo
//
//  日/周/月共享的展示快照：分组、排序、叙事与章节文案只在数据改变时后台生成。
//  滚动跨日、切档和切筛选只查索引，不重新遍历整段历史。
//

import Foundation

nonisolated struct CalendarDayPresentation {
    let day: Date
    let events: [CalendarEvent]
    let blocks: [DailyReplayPresentation.PeriodBlock]
    let narrative: String?
    let moments: [DailyReplayMoment]
    let chapter: MemoryTimeChapterPresentation
    let hourCounts: [Int: Int]

    init(day: Date, events: [CalendarEvent], calendar: Calendar = .current, now: Date = Date()) {
        self.day = day
        self.events = events
        blocks = DailyReplayPresentation.readingOrderBlocks(from: events, calendar: calendar)
        moments = blocks.flatMap(\.moments)
        narrative = DailyReplayPresentation.narrative(for: events, calendar: calendar)
        hourCounts = Dictionary(grouping: events) { calendar.component(.hour, from: $0.date) }.mapValues(\.count)
        let reliable = events.filter(\.hasReliableTime)
        let range = CalendarRangeBuilder.dayRange(day)
        chapter = MemoryTimeChapterPresentation.make(
            scale: .day, focusedDate: day, periodStart: range.start, periodEnd: range.end,
            eventCount: events.count, momentCount: blocks.reduce(0) { $0 + $1.moments.count },
            activeDayCount: events.isEmpty ? 0 : 1,
            firstEventDate: reliable.map(\.date).min(), lastEventDate: reliable.map(\.date).max(),
            isCurrentPeriod: calendar.startOfDay(for: day) == calendar.startOfDay(for: now), calendar: calendar
        )
    }


}

nonisolated struct CalendarPeriodPresentation {
    let events: [CalendarEvent]
    let chapter: MemoryTimeChapterPresentation
    let observation: CalendarObservationSummary
}

nonisolated struct CalendarPresentationIndex {
    let eventsByDay: [Date: [CalendarEvent]]
    let days: [Date: CalendarDayPresentation]
    let weeks: [Date: CalendarPeriodPresentation]
    let months: [Date: CalendarPeriodPresentation]
    let moduleHints: [Date: Set<CalendarModule>]
    let eventCounts: [Date: Int]

    static let empty = CalendarPresentationIndex(events: [], range: nil)

    init(events: [CalendarEvent], range: DateInterval?, calendar: Calendar = .current, now: Date = Date()) {
        let grouped = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
        eventsByDay = grouped
        moduleHints = grouped.mapValues { Set($0.map(\.module)) }
        eventCounts = grouped.mapValues(\.count)
        var prepared = grouped.mapValues { CalendarDayPresentation(day: calendar.startOfDay(for: $0[0].date),
                                                                  events: $0, calendar: calendar, now: now) }
        // 空日期也提前准备，避免日回放滚到空白章节时临时创建多份日期格式器。
        if let range {
            var day = calendar.startOfDay(for: range.start)
            while day < range.end {
                if prepared[day] == nil {
                    prepared[day] = CalendarDayPresentation(day: day, events: [], calendar: calendar, now: now)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        days = prepared
        weeks = Self.periods(events: events, days: prepared, scale: .week, calendar: calendar, now: now)
        months = Self.periods(events: events, days: prepared, scale: .month, calendar: calendar, now: now)
    }

    private static func periods(events: [CalendarEvent], days: [Date: CalendarDayPresentation],
                                scale: MemoryTimeChapterScale, calendar: Calendar, now: Date) -> [Date: CalendarPeriodPresentation] {
        var grouped = Dictionary(grouping: events) {
            scale == .week ? CalendarRangeBuilder.weekRange(around: $0.date).start : CalendarRangeBuilder.monthRange($0.date).start
        }
        for day in days.keys {
            let start = scale == .week ? CalendarRangeBuilder.weekRange(around: day).start : CalendarRangeBuilder.monthRange(day).start
            if grouped[start] == nil { grouped[start] = [] }
        }
        var prepared: [Date: CalendarPeriodPresentation] = [:]
        for (start, periodEvents) in grouped {
            let range = scale == .week ? CalendarRangeBuilder.weekRange(around: start) : CalendarRangeBuilder.monthRange(start)
            let activeDays = Set(periodEvents.map { calendar.startOfDay(for: $0.date) })
            let moments = activeDays.reduce(0) { $0 + (days[$1]?.blocks.reduce(0) { $0 + $1.moments.count } ?? 0) }
            prepared[start] = CalendarPeriodPresentation(
                events: periodEvents,
                chapter: MemoryTimeChapterPresentation.make(
                    scale: scale, focusedDate: start, periodStart: range.start, periodEnd: range.end,
                    eventCount: periodEvents.count, momentCount: moments, activeDayCount: activeDays.count,
                    firstEventDate: nil, lastEventDate: nil,
                    isCurrentPeriod: CalendarRangeBuilder.contains(now, in: range), calendar: calendar
                ),
                observation: CalendarObservationSummary.make(events: periodEvents, scope: scale == .week ? .week : .month)
            )
        }
        return prepared
    }
}

nonisolated struct CalendarPresentationSnapshot {
    let revision = UUID()
    let all: CalendarPresentationIndex
    let modules: [CalendarModule: CalendarPresentationIndex]
    private let emptyIndex: CalendarPresentationIndex

    static let empty = CalendarPresentationSnapshot(events: [], range: nil)

    init(events: [CalendarEvent], range: DateInterval?, now: Date = Date()) {
        all = CalendarPresentationIndex(events: events, range: range, now: now)
        emptyIndex = CalendarPresentationIndex(events: [], range: range, now: now)
        let grouped = Dictionary(grouping: events, by: \.module)
        modules = grouped.mapValues { CalendarPresentationIndex(events: $0, range: range, now: now) }
    }

    func index(for module: CalendarModule?) -> CalendarPresentationIndex {
        guard let module else { return all }
        return modules[module] ?? emptyIndex
    }

    /// 刷新窗口内只替换成功模块：修改/删除能反映，失败模块仍保留已显示的事实。
    static func merging(existing: [CalendarEvent], fetched: CalendarEventsResult, range: DateInterval) -> [CalendarEvent] {
        let successful = Set(fetched.moduleStates.compactMap { module, state -> CalendarModule? in
            if case .failed = state { return nil }
            return module
        })
        let fetchedIDs = Dictionary(grouping: fetched.events, by: \.module).mapValues { Set($0.map(\.id)) }
        let retained = existing.filter {
            fetchedIDs[$0.module]?.contains($0.id) != true
                && (!successful.contains($0.module) || !CalendarRangeBuilder.contains($0.date, in: range))
        }
        return (retained + fetched.events).sorted { $0.date < $1.date }
    }
}
