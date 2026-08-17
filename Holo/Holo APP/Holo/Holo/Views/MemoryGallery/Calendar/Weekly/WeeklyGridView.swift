//
//  WeeklyGridView.swift
//  Holo
//
//  周历网格视图：3 日可滑动视图（昨天 / 今天 / 明天），
//  手指左右滑动逐天切换，今天始终在中间列。
//
//  布局分三层（纵向滚 / 横向翻 / 日期格冻结 互不干扰）：
//  1. 日期格行 —— 钉在顶部（在所有 ScrollView 之外），直接读 centerDay 显示 3 天。
//     翻页时 centerDay 变 → 它自动更新；上下滚时它纹丝不动。
//  2. 时间轴和事件区 —— 共用一个纵向 ScrollView；事件区内部再横向翻页。
//     这样时间刻度与事件永远一起滚动，横向也只有事件区会翻页。
//  3. 所有顶部日期、凌晨摘要和事件列共用 36pt 时间轴基线，避免列坐标漂移。
//

import SwiftUI

struct WeeklyGridView: View {
    /// 按天分组的事件字典（key = startOfDay）
    let eventsByDay: [Date: [CalendarEvent]]
    /// 当前中心日（双向绑定：手指滑动 / 箭头点击都改它）
    @Binding var centerDay: Date
    /// 选中事件
    let onSelect: (CalendarEvent) -> Void
    /// 选中事件分组（凌晨折叠溢出等）
    let onSelectGroup: ([CalendarEvent]) -> Void
    /// 滑动接近已加载边缘时续载
    let onEnsureData: (Date) -> Void

    @AppStorage("holo.memoryGallery.weeklyGrid.collapseMorning")
    private var collapseMorning: Bool = true
    /// 双指缩放的时间轴倍率（1 = 默认分档高度），持久化记忆用户偏好
    @AppStorage("holo.memoryGallery.weeklyGrid.hourScale")
    private var hourScale: Double = 1
    /// 捏合开始时的倍率，手势期间以此为基准连续变化
    @State private var pinchStartScale: Double?

    /// 一屏显示的天数
    private let dayCount = 3
    /// 翻页范围：以今天为中心 ±N 天（共 2N+1 天，LazyHStack 只渲染可见页附近）
    private let halfSpan = 180
    private let startHour = 0
    private let endHour = 23
    private let collapsedMorningHours = 0..<7
    private let timeAxisWidth: CGFloat = 36
    private let dayHeaderHeight: CGFloat = 48
    private let morningSummaryHeight: CGFloat = 40
    /// 缩放下限即默认密度：再缩小事件块放不下、只会制造更多溢出；上限看清密集时段
    private let minHourScale: Double = 1
    private let maxHourScale: Double = 2.6

    private var clampedHourScale: Double {
        min(maxHourScale, max(minHourScale, hourScale))
    }

    private func resetHourScale() {
        withAnimation(.easeInOut(duration: 0.2)) {
            hourScale = 1
        }
        pinchStartScale = nil
    }

    private var visibleStartHour: Int {
        collapseMorning ? 7 : startHour
    }

    /// 横向可滑动的日期列表（以今天为中心 ±halfSpan 天）
    private var visibleDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (-halfSpan...halfSpan).compactMap {
            cal.date(byAdding: .day, value: $0, to: today)
        }
    }

    /// 时间轴密度：基于「以今天为中心的固定 7 天」算。
    /// 范围固定不跟随中心日 —— 滑动时高度稳定不跳变，
    /// 也不被几个月前某天的事件拖高（全量算的缺点）。
    private func computeProfile(_ eventsByDay: [Date: [CalendarEvent]]) -> WeeklyGridAxisProfile {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // 固定窗口：今天前 3 天 ~ 后 3 天（共 7 天）
        let profileDays = (-3...3).compactMap {
            cal.date(byAdding: .day, value: $0, to: today)
        }
        let countsByDay: [[Int: Int]] = profileDays.map { day in
            let events = eventsByDay[day] ?? []
            return Dictionary(grouping: events) { event in
                cal.component(.hour, from: event.date)
            }.mapValues(\.count)
        }
        return WeeklyGridAxisProfile.make(
            eventCountsByDay: countsByDay,
            startHour: visibleStartHour,
            endHour: endHour,
            scale: CGFloat(clampedHourScale)
        )
    }

    var body: some View {
        let profile = computeProfile(eventsByDay)
        VStack(spacing: 0) {
            // 泳道卡片：表头、凌晨带、网格主体收进同一张卡；图例留在卡片外
            VStack(spacing: 0) {
                calendarHeader

                // 折叠时仅保留一行与日期列严格对齐的凌晨摘要；展开后这一行自然消失。
                if collapseMorning {
                    morningSummaryRow
                }

                // 时间轴和事件网格共用同一个纵向 ScrollView，滚动后仍保持刻度对齐。
                gridScroll(profile: profile)
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)

            legend
                .padding(.top, HoloSpacing.xs)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.lg)
    }

    /// 日期格行显示的 3 天：以 centerDay 为中心的前一天/当天/后一天
    private var frozenHeaderDays: [Date] {
        let cal = Calendar.current
        let center = cal.startOfDay(for: centerDay)
        return [-1, 0, 1].compactMap { cal.date(byAdding: .day, value: $0, to: center) }
    }

    // MARK: - 固定日期栏

    /// 泳道分隔线：内部边界 1pt（最外侧边界由卡片描边承担，避免叠成双线）
    private var laneSeparator: some View {
        Rectangle()
            .fill(Color.holoBorder)
            .frame(width: 1)
    }

    private var calendarHeader: some View {
        GeometryReader { geo in
            let columnWidth = max(0, (geo.size.width - timeAxisWidth) / CGFloat(dayCount))
            HStack(spacing: 0) {
                morningToggleCell
                    .frame(width: timeAxisWidth, height: dayHeaderHeight)
                    .background(Color.holoNestedCardBackground)
                    .overlay(alignment: .trailing) { laneSeparator }

                ForEach(Array(frozenHeaderDays.enumerated()), id: \.element) { index, day in
                    dayHeader(day)
                        .frame(width: columnWidth, height: dayHeaderHeight)
                        .overlay(alignment: .leading) {
                            if index > 0 { laneSeparator }
                        }
                }
            }
        }
        .frame(height: dayHeaderHeight)
        .background(Color.holoNestedCardBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.holoBorder)
                .frame(height: 1)
        }
    }

    private var morningToggleCell: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                collapseMorning.toggle()
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: collapseMorning ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                Text("0–7")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
            }
            .foregroundColor(collapseMorning ? .holoPrimary : .holoTextSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapseMorning ? "展开凌晨零点到七点" : "收起凌晨零点到七点")
        .accessibilityHint("显示或隐藏凌晨零点到七点的时间轴")
    }

    // MARK: - 事件区（单日竖条的事件部分）

    @ViewBuilder
    private func eventColumn(_ day: Date, columnWidth: CGFloat, profile: WeeklyGridAxisProfile, events: [CalendarEvent]) -> some View {
        let layout = WeeklyGridEventLayout.layout(
            events: events,
            axisProfile: profile,
            collapsedHours: collapseMorning ? collapsedMorningHours : nil
        )
        ZStack(alignment: .topLeading) {
            // 今日泳道：整列淡橙底贯穿全高，滑动翻页时随列移动
            if Calendar.current.isDateInToday(day) {
                Color.holoPrimary.opacity(0.045)
            }
            gridBackground(profile: profile)
            ForEach(layout.displayItems) { item in
                gridDisplayBlock(item, columnWidth: columnWidth)
            }
            // 当前时间线，只在「今天」这根竖条上显示
            if Calendar.current.isDateInToday(day) {
                nowLine(profile: profile, columnWidth: columnWidth)
            }
        }
        .frame(width: columnWidth, height: profile.totalHeight)
    }

    private func dayHeader(_ day: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        let weekdayLabel = isToday
            ? "\(Self.weekdayText(for: day)) · 今天"
            : Self.weekdayText(for: day)
        return VStack(spacing: 3) {
            Text(weekdayLabel)
                .font(.system(size: 10, weight: isToday ? .semibold : .medium))
                .foregroundColor(isToday ? .holoPrimary : .holoTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(Self.dayText(for: day))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(isToday ? .white : .holoTextPrimary)
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(isToday ? Color.holoPrimary : Color.clear)
                }
        }
        .frame(maxWidth: .infinity)
        .frame(height: dayHeaderHeight)
        .background(isToday ? Color.holoPrimary.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) {
            if isToday {
                Rectangle()
                    .fill(Color.holoPrimary)
                    .frame(height: 2)
            }
        }
    }

    // MARK: - 凌晨摘要（卡片内部横带）

    private var morningSummaryRow: some View {
        GeometryReader { geo in
            let columnWidth = max(0, (geo.size.width - timeAxisWidth) / CGFloat(dayCount))
            HStack(spacing: 0) {
                VStack(spacing: 1) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 9, weight: .medium))
                    Text("凌晨")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundColor(.holoTextSecondary)
                .frame(width: timeAxisWidth, height: morningSummaryHeight)
                .background(Color.holoNestedCardBackground)
                .overlay(alignment: .trailing) { laneSeparator }

                ForEach(Array(frozenHeaderDays.enumerated()), id: \.element) { index, day in
                    collapsedMorningCell(for: day)
                        .frame(width: columnWidth, height: morningSummaryHeight)
                        .overlay(alignment: .leading) {
                            if index > 0 { laneSeparator }
                        }
                }
            }
        }
        .frame(height: morningSummaryHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.holoBorder.opacity(0.5))
                .frame(height: 0.5)
        }
    }

    // MARK: - 时间轴导轨（左侧灰底竖轨，与表头左格连成 L 形）

    private func timeAxis(profile: WeeklyGridAxisProfile) -> some View {
        VStack(spacing: 0) {
            ForEach(profile.segments) { segment in
                Text(shouldShowHourLabel(segment.hour) ? "\(segment.hour)" : "")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: timeAxisWidth, height: segment.height, alignment: .topTrailing)
            }
            Text("24")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.holoTextSecondary)
                .frame(width: timeAxisWidth, height: 1, alignment: .bottomTrailing)
        }
        .frame(maxWidth: .infinity)
        .background(Color.holoNestedCardBackground)
        .overlay(alignment: .trailing) { laneSeparator }
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

    @ViewBuilder
    private func collapsedMorningCell(for day: Date) -> some View {
        let earlyEvents = morningEvents(for: day)
        Button {
            guard let first = earlyEvents.first else { return }
            if earlyEvents.count == 1 {
                onSelect(first)
            } else {
                onSelectGroup(earlyEvents)
            }
        } label: {
            HStack(spacing: 4) {
                if earlyEvents.isEmpty {
                    Text("—")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.holoTextPlaceholder)
                } else {
                    let moduleColor = earlyEvents[0].module.color
                    Text("\(earlyEvents.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.holoTextPrimary)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(moduleColor.opacity(0.18)))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: morningSummaryHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Calendar.current.isDateInToday(day)
                ? Color.holoPrimary.opacity(0.04)
                : Color.clear
        )
        .disabled(earlyEvents.isEmpty)
        .accessibilityLabel(
            earlyEvents.isEmpty
                ? "\(Self.weekdayText(for: day))凌晨无记录"
                : "\(Self.weekdayText(for: day))凌晨 \(earlyEvents.count) 条记录"
        )
    }

    private func morningEvents(for day: Date) -> [CalendarEvent] {
        let calendar = Calendar.current
        return (eventsByDay[calendar.startOfDay(for: day)] ?? [])
            .filter { event in
                collapsedMorningHours.contains(calendar.component(.hour, from: event.date))
            }
            .sorted { $0.date < $1.date }
    }

    // MARK: - 可滚动时间网格

    /// 双指捏合缩放整条时间轴；与单指滚动/横向翻页同时识别互不抢占
    private var hourScalePinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStartScale == nil {
                    pinchStartScale = clampedHourScale
                }
                hourScale = min(
                    maxHourScale,
                    max(minHourScale, (pinchStartScale ?? 1) * value.magnification)
                )
            }
            .onEnded { _ in
                // 松手圆整到 0.05 步进，避免高度停在亚像素值上
                hourScale = (clampedHourScale * 20).rounded() / 20
                pinchStartScale = nil
            }
    }

    private func gridScroll(profile: WeeklyGridAxisProfile) -> some View {
        GeometryReader { geo in
            let gridWidth = max(0, geo.size.width - timeAxisWidth)
            let columnWidth = gridWidth / CGFloat(dayCount)

            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    timeAxis(profile: profile)
                        .frame(width: timeAxisWidth, height: profile.totalHeight)

                    horizontalEventPager(
                        profile: profile,
                        columnWidth: columnWidth,
                        viewportWidth: gridWidth
                    )
                    .frame(width: gridWidth, height: profile.totalHeight)
                }
                .frame(width: geo.size.width, height: profile.totalHeight, alignment: .topLeading)
            }
            .simultaneousGesture(hourScalePinchGesture)
            // 双击重置用 onTapGesture：不能挡住子级横向翻页的跟手性
            .onTapGesture(count: 2, perform: resetHourScale)
            .overlay {
                // 泳道分隔线固定在视口三等分处：可见窗口恒为 3 列等宽，与列边界始终重合，
                // 且不随横向翻页移动（画在列内会跟着页走）。
                HStack(spacing: 0) {
                    Color.clear.frame(width: timeAxisWidth)
                    ForEach(0..<dayCount, id: \.self) { column in
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .leading) {
                                if column > 0 { laneSeparator }
                            }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func horizontalEventPager(profile: WeeklyGridAxisProfile,
                                      columnWidth: CGFloat,
                                      viewportWidth: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(visibleDays, id: \.self) { day in
                    eventColumn(
                        day,
                        columnWidth: columnWidth,
                        profile: profile,
                        events: eventsByDay[day] ?? []
                    )
                }
            }
            .scrollTargetLayout()
        }
        .frame(width: viewportWidth, height: profile.totalHeight)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(
            id: Binding<Date?>(
                get: { Calendar.current.startOfDay(for: centerDay) },
                set: { newValue in
                    guard let day = newValue else { return }
                    centerDay = day
                    onEnsureData(day)
                }
            ),
            anchor: .center
        )
    }

    // MARK: - 事件块

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
        hour >= visibleStartHour && (hour - visibleStartHour) % 2 == 0
    }

    // MARK: - 当前时间线（只在「今天」竖条内部显示）

    @ViewBuilder
    private func nowLine(profile: WeeklyGridAxisProfile, columnWidth: CGFloat) -> some View {
        let calendar = Calendar.current
        let now = Date()
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let hour = comps.hour ?? startHour
        if hour >= visibleStartHour && hour <= endHour {
            let top = profile.yPosition(hour: hour, minute: comps.minute ?? 0)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.holoPrimary)
                    .frame(width: columnWidth, height: 1.5)
                    .offset(x: 0, y: top)
                Circle()
                    .fill(Color.holoPrimary)
                    .frame(width: 7, height: 7)
                    .offset(x: -3, y: top - 3)
            }
        }
    }

    // MARK: - 图例

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
            Spacer(minLength: 0)
            if abs(clampedHourScale - 1) > 0.001 {
                Button(action: resetHourScale) {
                    Text(String(format: "缩放 %.2f×", clampedHourScale))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.holoPrimary.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("当前时间轴缩放 \(String(format: "%.2f", clampedHourScale)) 倍，轻点恢复一倍")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.holoTextSecondary)
        .padding(.top, HoloSpacing.xs)
        .animation(.easeInOut(duration: 0.2), value: abs(clampedHourScale - 1) > 0.001)
    }

    // MARK: - 格式化

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
