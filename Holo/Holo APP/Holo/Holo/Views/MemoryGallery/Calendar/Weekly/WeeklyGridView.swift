//
//  WeeklyGridView.swift
//  Holo
//
//  周历网格视图（P2）：7 列共享弹性时间轴，按小时密度动态拉伸
//

import SwiftUI

struct WeeklyGridView: View {
    let weekStart: Date                      // 周一首
    let eventsByDay: [Date: [CalendarEvent]]
    let onSelect: (CalendarEvent) -> Void
    let onSelectGroup: ([CalendarEvent]) -> Void

    @AppStorage("holo.memoryGallery.weeklyGrid.collapseMorning")
    private var collapseMorning: Bool = true

    private let startHour = 0
    private let endHour = 23
    private let collapsedMorningHours = 0..<7

    private var visibleStartHour: Int {
        collapseMorning ? 7 : startHour
    }

    var body: some View {
        let profile = axisProfile
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.xs) {
                weekHeader
                morningCollapseControl
                HStack(alignment: .top, spacing: 0) {
                    timeAxis(profile: profile)
                    ZStack(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<7, id: \.self) { dayOffset in
                                dayColumn(dayOffset, profile: profile)
                            }
                        }
                        nowLine(profile: profile)
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
                    let early = layoutFor(day, profile: axisProfile).early
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

    private func timeAxis(profile: WeeklyGridAxisProfile) -> some View {
        VStack(spacing: 0) {
            ForEach(profile.segments) { segment in
                Text(shouldShowHourLabel(segment.hour) ? "\(segment.hour)" : "")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: segment.height, alignment: .topTrailing)
            }
            Text("24")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 32, height: 1, alignment: .bottomTrailing)
        }
    }

    @ViewBuilder
    private func dayColumn(_ dayOffset: Int, profile: WeeklyGridAxisProfile) -> some View {
        let cal = Calendar.current
        if let day = cal.date(byAdding: .day, value: dayOffset, to: weekStart) {
            let layout = layoutFor(day, profile: profile)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    gridBackground(profile: profile)
                    ForEach(layout.displayItems) { item in
                        gridDisplayBlock(item, columnWidth: proxy.size.width)
                    }
                }
            }
            .frame(height: profile.totalHeight)
            .frame(maxWidth: .infinity)
            .overlay(
                Rectangle()
                    .fill(Color.holoDivider)
                    .frame(width: 0.5),
                alignment: .trailing
            )
        }
    }

    private func layoutFor(_ day: Date, profile: WeeklyGridAxisProfile) -> WeeklyGridEventLayout {
        let cal = Calendar.current
        return WeeklyGridEventLayout.layout(
            events: eventsByDay[cal.startOfDay(for: day)] ?? [],
            axisProfile: profile,
            collapsedHours: collapseMorning ? collapsedMorningHours : nil
        )
    }

    private func gridBackground(profile: WeeklyGridAxisProfile) -> some View {
        VStack(spacing: 0) {
            ForEach(profile.segments) { segment in
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: segment.height)
                    .overlay(
                        Rectangle().fill(Color.holoDivider).frame(height: 0.5),
                        alignment: .top
                    )
            }
        }
    }

    private var morningCollapseControl: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                collapseMorning.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapseMorning ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                Text(collapseMorning ? "0:00-6:59 已收起" : "收起 0:00-6:59")
                    .font(.system(size: 10, weight: .semibold))
                if collapseMorning {
                    let count = collapsedMorningCount
                    Text(count > 0 ? "\(count) 条" : "低频时段")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(.holoTextSecondary)
            .padding(.horizontal, HoloSpacing.sm)
            .frame(height: 26)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(.leading, 32 + HoloSpacing.md)
        .padding(.trailing, HoloSpacing.md)
    }

    private var collapsedMorningCount: Int {
        let calendar = Calendar.current
        return eventsByDay.values.flatMap { $0 }.filter { event in
            collapsedMorningHours.contains(calendar.component(.hour, from: event.date))
        }.count
    }

    private func gridDisplayBlock(_ item: WeeklyGridEventLayout.DisplayItem, columnWidth: CGFloat) -> some View {
        let accentColor = item.isOverflow ? Color.holoTextSecondary : item.module.color
        return Button {
            if item.isOverflow {
                onSelectGroup(item.events)
            } else {
                onSelect(item.primaryEvent)
            }
        } label: {
            HStack(spacing: 3) {
                Text(item.displayTitle)
                    .font(.system(size: item.isOverflow ? 8.5 : 10, weight: .bold))
                    .foregroundColor(item.isOverflow ? .holoTextSecondary : .holoTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Spacer(minLength: 0)
            }
            .padding(.leading, item.isOverflow ? 5 : 6)
            .padding(.trailing, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: item.height)
            .background(accentColor.opacity(item.isOverflow ? 0.07 : 0.14))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: item.isOverflow ? 2 : 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: item.isOverflow ? 4 : 6))
        }
        .buttonStyle(.plain)
        .frame(width: max(24, columnWidth - 4))
        .offset(x: 2, y: item.top)
    }

    private func shouldShowHourLabel(_ hour: Int) -> Bool {
        hour == visibleStartHour || hour % 2 == 0
    }

    @ViewBuilder
    private func nowLine(profile: WeeklyGridAxisProfile) -> some View {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let now = Date()
        if now >= weekStart && now < weekEnd {
            let comps = calendar.dateComponents([.hour, .minute], from: now)
            let hour = comps.hour ?? startHour
            if hour >= visibleStartHour && hour <= endHour {
                let weekdayOffset = calendar.dateComponents([.day], from: weekStart, to: todayStart).day ?? 0
                GeometryReader { proxy in
                    let columnWidth = proxy.size.width / 7.0
                    let top = profile.yPosition(hour: hour, minute: comps.minute ?? 0)
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

    private var axisProfile: WeeklyGridAxisProfile {
        let calendar = Calendar.current
        let countsByDay: [[Int: Int]] = (0..<7).compactMap { dayOffset in
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else {
                return nil
            }
            let events = eventsByDay[calendar.startOfDay(for: day)] ?? []
            return Dictionary(grouping: events) { event in
                calendar.component(.hour, from: event.date)
            }.mapValues(\.count)
        }
        return WeeklyGridAxisProfile.make(
            eventCountsByDay: countsByDay,
            startHour: visibleStartHour,
            endHour: endHour
        )
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
