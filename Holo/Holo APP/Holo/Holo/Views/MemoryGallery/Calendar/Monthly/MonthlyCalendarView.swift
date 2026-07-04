//
//  MonthlyCalendarView.swift
//  Holo
//
//  月历：31 格色块网格（周一首）+ 选中联动 DayDetailCard
//

import SwiftUI

struct MonthlyCalendarView: View {
    let monthAnchor: Date
    let eventsByDay: [Date: [CalendarEvent]]   // key = startOfDay
    let selectedDay: Date?
    let onSelectDay: (Date) -> Void

    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    /// 周一首的日历（与 CalendarRangeBuilder 一致）
    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    var body: some View {
        VStack(spacing: HoloSpacing.xs) {
            weekdayHeader
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                spacing: 6
            ) {
                ForEach(monthCells, id: \.self) { day in
                    MonthCell(
                        day: day,
                        events: eventsFor(day),
                        isThisMonth: calendar.isDate(day, equalTo: monthAnchor, toGranularity: .month),
                        isToday: calendar.isDateInToday(day),
                        isSelected: isSelected(day),
                        onTap: { onSelectDay(day) }
                    )
                }
            }
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdays, id: \.self) { w in
                Text(w)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func isSelected(_ day: Date) -> Bool {
        guard let selectedDay = selectedDay else { return false }
        return calendar.isDate(selectedDay, inSameDayAs: day)
    }

    private func eventsFor(_ day: Date) -> [CalendarEvent] {
        eventsByDay[calendar.startOfDay(for: day)] ?? []
    }

    /// 本月网格：从本月首日所在周的周一首开始，到本月末日所在周的周日，凑满整周
    private var monthCells: [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: monthAnchor),
              let firstWeekStart = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)?.start else {
            return []
        }
        var cells: [Date] = []
        var cursor = firstWeekStart
        // 月历最多 6 行（42 格），覆盖所有跨月补位
        while cells.count < 42 {
            cells.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            // 已填满且超过月末则停
            if cells.count >= 35 && cursor > monthInterval.end { break }
        }
        return cells
    }
}
