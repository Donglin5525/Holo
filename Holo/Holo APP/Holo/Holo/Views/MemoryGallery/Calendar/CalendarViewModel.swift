//
//  CalendarViewModel.swift
//  Holo
//
//  日历视图 ViewModel：持有 CalendarEventProvider，驱动周历取数与周导航。
//  init 零 I/O（只注入 Repository 引用），取数由 View.task 触发（CLAUDE.md 约定）。
//

import Foundation
import SwiftUI
import Combine
import os.log

/// 周历单日聚合（按天分组的事件）
struct DayEvents: Identifiable, Equatable {
    let day: Date               // startOfDay
    let events: [CalendarEvent]
    var id: Date { day }
}

@MainActor
final class CalendarViewModel: ObservableObject {

    /// 当前周锚点（周一首算所在周）
    @Published var weekAnchor: Date = Date()

    /// 聚合结果（含每模块加载状态，失败不静默）
    @Published private(set) var result: CalendarEventsResult = .empty

    /// 是否正在加载
    @Published private(set) var isLoading: Bool = false

    private let provider: CalendarEventProvider

    init(provider: CalendarEventProvider? = nil) {
        // 默认注入 4 个 Repository（同主 context，串行访问安全）
        self.provider = provider ?? CalendarEventProvider(
            financeRepo: .shared,
            habitRepo: .shared,
            todoRepo: .shared,
            thoughtRepo: ThoughtRepository()
        )
    }

    // MARK: - 衍生

    var weekRange: DateInterval { CalendarRangeBuilder.weekRange(around: weekAnchor) }

    /// 按 startOfDay 分组、组内按时间升序、组间按天升序
    var eventsByDay: [DayEvents] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: result.events) { cal.startOfDay(for: $0.date) }
        return groups
            .map { DayEvents(day: $0.key, events: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.day < $1.day }
    }

    var hasFailure: Bool { result.hasFailure }

    // MARK: - 加载

    func load() async {
        isLoading = true
        result = await provider.fetchEvents(in: weekRange)
        isLoading = false
    }

    // MARK: - 周导航

    func goToPrevWeek() {
        guard let prev = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: weekAnchor) else { return }
        weekAnchor = prev
        Task { await load() }
    }

    func goToNextWeek() {
        guard let next = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: weekAnchor) else { return }
        weekAnchor = next
        Task { await load() }
    }

    func goToToday() {
        weekAnchor = Date()
        Task { await load() }
    }
}
