//
//  WeeklyGridView.swift
//  Holo
//
//  周历网格视图（P2）：7 列 × 24h 时间轴，事件按 timestamp 定位
//

import SwiftUI

struct WeeklyGridView: View {
    let weekStart: Date                      // 周一首
    let eventsByDay: [Date: [CalendarEvent]]
    let onSelect: (CalendarEvent) -> Void

    private let hourHeight: CGFloat = 42
    private let startHour = 6
    private let endHour = 23
    private let eventHeight: CGFloat = 26

    private var gridHeight: CGFloat {
        CGFloat(endHour - startHour + 1) * hourHeight
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.xs) {
                weekHeader
                earlyStrip
                HStack(alignment: .top, spacing: 0) {
                    timeAxis
                    ZStack(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<7, id: \.self) { dayOffset in
                                dayColumn(dayOffset)
                            }
                        }
                        nowLine
                    }
                }
                legend
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.bottom, HoloSpacing.lg)
        }
    }

    private var weekHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 32)
            ForEach(0..<7, id: \.self) { dayOffset in
                if let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: weekStart) {
                    let isToday = Calendar.current.isDateInToday(day)
                    VStack(spacing: 2) {
                        Text(Self.weekdayText(for: day))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isToday ? .holoPrimary : .holoTextSecondary)
                        Text(Self.dayText(for: day))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(isToday ? .holoPrimary : .holoTextPrimary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var earlyStrip: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 32)
            ForEach(0..<7, id: \.self) { dayOffset in
                if let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: weekStart) {
                    let early = layoutFor(day).early
                    if early.isEmpty {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                    } else {
                        Button {
                            if let event = early.first { onSelect(event) }
                        } label: {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(early.first?.module.color ?? .holoTextSecondary)
                                    .frame(width: 5, height: 5)
                                Text(early.count == 1 ? "凌晨" : "凌晨 \(early.count)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .foregroundColor(.holoTextSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .background(Color.holoCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
    }

    private var timeAxis: some View {
        VStack(spacing: 0) {
            ForEach(startHour...endHour, id: \.self) { h in
                Text(h % 2 == 0 ? "\(h)" : "")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: hourHeight, alignment: .topTrailing)
            }
        }
    }

    @ViewBuilder
    private func dayColumn(_ dayOffset: Int) -> some View {
        let cal = Calendar.current
        if let day = cal.date(byAdding: .day, value: dayOffset, to: weekStart) {
            let layout = layoutFor(day)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    gridBackground
                    ForEach(layout.visible) { item in
                        gridEventBlock(item, columnWidth: proxy.size.width)
                    }
                }
            }
            .frame(height: gridHeight)
            .frame(maxWidth: .infinity)
            .overlay(
                Rectangle()
                    .fill(Color.holoDivider)
                    .frame(width: 0.5),
                alignment: .trailing
            )
        }
    }

    private func layoutFor(_ day: Date) -> WeeklyGridEventLayout {
        let cal = Calendar.current
        return WeeklyGridEventLayout.layout(
            events: eventsByDay[cal.startOfDay(for: day)] ?? [],
            startHour: startHour,
            endHour: endHour,
            hourHeight: hourHeight
        )
    }

    private var gridBackground: some View {
        VStack(spacing: 0) {
            ForEach(startHour...endHour, id: \.self) { _ in
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: hourHeight)
                    .overlay(
                        Rectangle().fill(Color.holoDivider).frame(height: 0.5),
                        alignment: .top
                    )
            }
        }
    }

    private func gridEventBlock(_ item: WeeklyGridEventLayout.VisibleItem, columnWidth: CGFloat) -> some View {
        let laneCount = max(1, item.laneCount)
        let laneWidth = columnWidth / CGFloat(laneCount)
        return Button {
            onSelect(item.event)
        } label: {
            Text(item.event.title)
                .font(.system(size: laneCount > 2 ? 9 : 11, weight: .bold))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .padding(.leading, laneCount > 2 ? 4 : 6)
                .padding(.trailing, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: eventHeight)
                .background(item.event.module.color.opacity(0.14))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(item.event.module.color)
                        .frame(width: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .frame(width: max(12, laneWidth - 4))
        .offset(x: CGFloat(item.lane) * laneWidth + 2, y: item.top)
    }

    @ViewBuilder
    private var nowLine: some View {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let now = Date()
        if now >= weekStart && now < weekEnd {
            let comps = calendar.dateComponents([.hour, .minute], from: now)
            let hour = comps.hour ?? startHour
            if hour >= startHour && hour <= endHour {
                let weekdayOffset = calendar.dateComponents([.day], from: weekStart, to: todayStart).day ?? 0
                GeometryReader { proxy in
                    let columnWidth = proxy.size.width / 7.0
                    let top = CGFloat(hour - startHour) * hourHeight
                        + CGFloat(comps.minute ?? 0) / 60.0 * hourHeight
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.holoPrimary)
                            .frame(width: columnWidth, height: 1.5)
                            .offset(x: CGFloat(weekdayOffset) * columnWidth, y: top)
                        Circle()
                            .fill(Color.holoPrimary)
                            .frame(width: 7, height: 7)
                            .offset(x: CGFloat(weekdayOffset) * columnWidth - 3, y: top - 3)
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: HoloSpacing.md) {
            ForEach([CalendarModule.finance, .habit, .todo, .thought], id: \.self) { module in
                HStack(spacing: 5) {
                    Circle()
                        .fill(module.color)
                        .frame(width: 8, height: 8)
                    Text(module.displayName)
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.holoTextSecondary)
        .padding(.top, HoloSpacing.xs)
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "E"
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
