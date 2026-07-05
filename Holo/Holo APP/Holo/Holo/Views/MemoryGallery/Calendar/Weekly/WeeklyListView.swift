//
//  WeeklyListView.swift
//  Holo
//
//  周历列表视图：7 天每天一行，事件横向铺开
//  含 WeeklyDayRow 与 WeeklyEventChip
//

import SwiftUI

struct WeeklyListView: View {
    let eventsByDay: [DayEvents]
    let isLoading: Bool
    let onSelect: (CalendarEvent) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            if !isLoading && eventsByDay.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: HoloSpacing.xs) {
                    ForEach(eventsByDay) { dayEvents in
                        WeeklyDayRow(dayEvents: dayEvents, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.lg)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "calendar")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.holoTextPlaceholder)
            Text("本周没有记录")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, HoloSpacing.xxl)
    }
}

// MARK: - 单日行

struct WeeklyDayRow: View {
    let dayEvents: DayEvents
    let onSelect: (CalendarEvent) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            dayLabel

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.xs) {
                    if dayEvents.events.isEmpty {
                        Text("无记录")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextPlaceholder)
                            .padding(.vertical, HoloSpacing.xs)
                    } else {
                        ForEach(dayEvents.events) { event in
                            WeeklyEventChip(event: event) { onSelect(event) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, HoloSpacing.xs)
    }

    private var dayLabel: some View {
        let isToday = Calendar.current.isDateInToday(dayEvents.day)
        return VStack(spacing: 2) {
            Text(Self.weekdayText(for: dayEvents.day))
                .font(.holoTinyLabel)
                .foregroundColor(isToday ? .holoPrimary : .holoTextSecondary)
            Text(Self.dayText(for: dayEvents.day))
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(isToday ? .holoPrimary : .holoTextPrimary)
        }
        .frame(width: 42)
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE"
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "d"
        return f
    }()
    private static func weekdayText(for date: Date) -> String { weekdayFormatter.string(from: date) }
    private static func dayText(for date: Date) -> String { dayFormatter.string(from: date) }
}

// MARK: - 事件 chip（模块色条 + 时间 + 标题 + 副信息）

struct WeeklyEventChip: View {
    let event: CalendarEvent
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.timeText(for: event.date))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.holoTextSecondary)
                Text(event.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                if let detail = event.detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(event.module.color)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(minWidth: 74, alignment: .leading)
            .background(event.module.color.opacity(0.12))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(event.module.color)
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        }
        .buttonStyle(.plain)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static func timeText(for date: Date) -> String { timeFormatter.string(from: date) }
}
