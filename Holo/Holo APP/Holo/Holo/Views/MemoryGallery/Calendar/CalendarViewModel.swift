//
//  CalendarViewModel.swift
//  Holo
//
//  日历视图 ViewModel：周历 / 月历共用，驱动取数与导航。
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
            let last = range.end.addingTimeInterval(-1)   // 半开区间 end 是下周一 00:00，显示前一天
            return "\(Self.rangeFormatter.string(from: range.start)) – \(Self.rangeFormatter.string(from: last))"
        case .monthly:
            return Self.monthFormatter.string(from: anchor)
        }
    }

    // MARK: - 衍生数据

    /// 周历：按天分组的事件列表（组内升序、组间升序）
    var eventsByDay: [DayEvents] {
        let cal = Calendar.current
        return Dictionary(grouping: result.events) { cal.startOfDay(for: $0.date) }
            .map { DayEvents(day: $0.key, events: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.day < $1.day }
    }

    /// 月历：按天分组的事件字典（key = startOfDay）
    var monthEventsByDay: [Date: [CalendarEvent]] {
        let cal = Calendar.current
        return Dictionary(grouping: result.events) { cal.startOfDay(for: $0.date) }
    }

    /// 月历选中天的详情事件
    var selectedDayEvents: [CalendarEvent] {
        guard let day = selectedDay else { return [] }
        return monthEventsByDay[Calendar.current.startOfDay(for: day)] ?? []
    }

    var hasFailure: Bool { result.hasFailure }

    // MARK: - 加载

    func load() async {
        isLoading = true
        result = await provider.fetchEvents(in: currentRange)
        isLoading = false
    }

    func switchMode(_ m: Mode) {
        guard mode != m else { return }
        mode = m
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
        selectedDay = Date()    // 月历默认选中今天
        Task { await load() }
    }

    func selectDay(_ day: Date) {
        selectedDay = day
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
}
