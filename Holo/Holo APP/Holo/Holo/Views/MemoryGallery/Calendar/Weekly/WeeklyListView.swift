//
//  WeeklyListView.swift
//  Holo
//
//  周历列表视图：每天一张卡片，事件 chip 自动换行铺满
//  周间倒序、周内升序，滚到底自动加载上一周（往下滚=向过去翻）
//  含 WeeklyDayRow 与 WeeklyEventChip
//

import SwiftUI

struct WeeklyListView: View {
    let eventsByDay: [DayEvents]
    let isLoading: Bool
    var isLoadingEarlier = false
    var hasEarlierWeeks = true
    var onLoadEarlier: (() -> Void)? = nil
    /// 当天的里程碑卡（key = startOfDay）
    var milestonesByDay: [Date: [MilestoneData]] = [:]
    /// 当天的高光卡（key = startOfDay）
    var highlightsByDay: [Date: [HighlightData]] = [:]
    /// 模块筛选激活时隐藏叙事卡（高光为跨模块事件，无法按单模块过滤）
    var showsNarrative = true
    let onSelect: (CalendarEvent) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            if !isLoading && eventsByDay.isEmpty {
                VStack(spacing: 0) {
                    emptyState
                    // 本周无记录时也要能向过去翻（否则空态死锁，看不到上周数据）
                    if hasEarlierWeeks {
                        earlierWeeksFooter
                    }
                }
            } else {
                LazyVStack(spacing: HoloSpacing.sm) {
                    ForEach(eventsByDay) { dayEvents in
                        WeeklyDayRow(dayEvents: dayEvents, onSelect: onSelect)
                        if showsNarrative {
                            narrativeCards(for: dayEvents.day)
                        }
                    }

                    if hasEarlierWeeks {
                        earlierWeeksFooter
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.lg)
            }
        }
    }

    /// 当天的里程碑/高光卡：先事实后解读，里程碑在前（与时间线惯例一致）
    @ViewBuilder
    private func narrativeCards(for day: Date) -> some View {
        let dayStart = Calendar.current.startOfDay(for: day)
        let milestones = milestonesByDay[dayStart] ?? []
        let highlights = highlightsByDay[dayStart] ?? []

        if !milestones.isEmpty || !highlights.isEmpty {
            VStack(spacing: HoloSpacing.xs) {
                ForEach(Array(milestones.enumerated()), id: \.offset) { _, data in
                    MilestoneNode(data: data)
                }
                ForEach(Array(highlights.enumerated()), id: \.offset) { _, data in
                    GentleHighlightNode(data: data)
                }
            }
        }
    }

    /// 底部触发器：滚到这里加载上一周；上一周 append 在尾部，无滚动跳动
    private var earlierWeeksFooter: some View {
        HStack {
            Spacer()
            if isLoadingEarlier {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .holoPrimary))
            }
            Spacer()
        }
        .frame(height: 44)
        .onAppear {
            onLoadEarlier?()
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

// MARK: - 单日行（有记录 = 每日卡片；无记录 = 弱化细行）

struct WeeklyDayRow: View {
    let dayEvents: DayEvents
    let onSelect: (CalendarEvent) -> Void

    private var isToday: Bool {
        Calendar.current.isDateInToday(dayEvents.day)
    }

    var body: some View {
        if dayEvents.events.isEmpty {
            emptyDayRow
        } else {
            dayCard
        }
    }

    // MARK: 每日卡片：日期头 + 条数摘要 + 模块色点 + chip 换行铺满（无截断、无横滑）

    private var dayCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(alignment: .center, spacing: HoloSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isToday
                         ? "\(Self.weekdayText(for: dayEvents.day)) · 今天"
                         : Self.weekdayText(for: dayEvents.day))
                        .font(.holoTinyLabel)
                        .foregroundColor(isToday ? .holoPrimary : .holoTextSecondary)
                    Text(Self.dayText(for: dayEvents.day))
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundColor(isToday ? .holoPrimary : .holoTextPrimary)
                }

                Spacer(minLength: 0)

                Text("\(dayEvents.events.count) 条")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                HStack(spacing: 3) {
                    ForEach(presentModules, id: \.self) { module in
                        Circle()
                            .fill(module.color)
                            .frame(width: 5, height: 5)
                    }
                }
            }

            FlowLayout(spacing: HoloSpacing.xs) {
                ForEach(dayEvents.events) { event in
                    WeeklyEventChip(event: event) { onSelect(event) }
                }
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.8), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            // 今日卡左缘 3pt 橙条，与网格「今日泳道」同一强调语言
            if isToday {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.holoPrimary)
                    .frame(width: 3)
                    .padding(.vertical, HoloSpacing.md)
            }
        }
    }

    /// 当天涉及模块按固定顺序去重，口径与图例一致
    private var presentModules: [CalendarModule] {
        let present = Set(dayEvents.events.map(\.module))
        return CalendarModule.allCases.filter { present.contains($0) }
    }

    // MARK: 无记录：弱化为一条细行，保留「那天确实没记录」的信息

    private var emptyDayRow: some View {
        HStack(spacing: HoloSpacing.sm) {
            Text(Self.weekdayText(for: dayEvents.day))
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)
            Text(Self.dayText(for: dayEvents.day))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.holoTextPlaceholder)
            Spacer(minLength: 0)
            Text("无记录")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder.opacity(0.8))
        }
        .padding(.horizontal, HoloSpacing.xs)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.weekdayText(for: dayEvents.day)) \(Self.dayText(for: dayEvents.day)) 无记录")
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
