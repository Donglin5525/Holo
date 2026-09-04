//
//  WeeklyGridView.swift
//  Holo
//
//  周档时间网格（方案 §8）：三日可视窗口浏览本周七天（周一首），
//  周内横滑逐列移动、到周边界弹性回弹不跨周；跨周由顶部箭头负责。
//
//  布局分三层（纵向滚 / 横向翻 / 日期格冻结 互不干扰）：
//  1. 日期格行 —— 钉在顶部（在所有 ScrollView 之外），与事件列共用同一份「本周七天」
//     数据源（方案 §8.4 边界对齐：周一首列贴左、周日末列贴右，头列永不错位）。
//  2. 时间轴和事件区 —— 共用一个纵向 ScrollView；事件区内部再横向翻页。
//     这样时间刻度与事件永远一起滚动，横向也只有事件区会翻页。
//  3. 所有顶部日期、凌晨摘要和事件列共用 36pt 时间轴基线，避免列坐标漂移。
//

import SwiftUI

struct WeeklyGridView: View {
    /// 本周七天（周一首）——渲染与翻页的唯一日期数据源
    let weekDays: [Date]
    /// 按天分组的事件字典（key = startOfDay）
    let eventsByDay: [Date: [CalendarEvent]]
    /// 聚焦日期（双向绑定：滑动手势 / 点日期头都改它）
    @Binding var focusedDate: Date
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
    /// 三条横向内容（日期、凌晨、事件）共用同一手势位移，保证任何时刻都在同一列基线上。
    @GestureState private var pagerDragOffset: CGFloat = 0

    /// 一屏显示的天数：v2 宽屏自适应——手机/窄屏 3 天，expanded 档 5 天，
    /// 让 12.9 寸横屏真正「多看几天」而不是把 3 列拉宽。窗口策略（周首贴左/周尾贴右）
    /// 按可见天数通用计算，天数变化无需其他改动。
    @Environment(\.holoWindowWidth) private var weekWindowWidth
    private var dayCount: Int {
        HoloAdaptiveLayout.isExpandedWidth(weekWindowWidth) ? 5 : 3
    }
    private let startHour = 0
    private let endHour = 23
    private let collapsedMorningHours = 0..<7
    private let timeAxisWidth: CGFloat = 40
    private let dayHeaderHeight: CGFloat = 54
    private let morningSummaryHeight: CGFloat = 38
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

    /// 聚焦日在本周七天中的下标（防越界兜底取中间）
    private var focusedIndex: Int {
        let cal = Calendar.current
        let start = cal.startOfDay(for: focusedDate)
        return weekDays.firstIndex { cal.isDate($0, inSameDayAs: start) }
            ?? min(3, max(0, weekDays.count - 1))
    }

    /// 当前周只允许浏览到今天所在窗口；历史周允许完整浏览七天。
    private var windowPolicy: WeeklyGridWindowPolicy {
        let calendar = Calendar.current
        let todayIndex = weekDays.firstIndex { calendar.isDateInToday($0) }
        return WeeklyGridWindowPolicy(
            totalDayCount: weekDays.count,
            visibleDayCount: dayCount,
            latestAllowedDayIndex: todayIndex
        )
    }

    /// 三日窗口起始下标：聚焦日尽量居中，周首贴左、周尾贴右（方案 §8.4 边界对齐）
    private var windowStartIndex: Int {
        windowPolicy.startIndex(focusedIndex: focusedIndex)
    }

    /// 时间轴密度：按当前完整周的七天计算（方案 §8.5——同一小时七天内同高同坐标，
    /// 周内滑动时高度稳定不跳变，跨周后随窗口统一更新）。
    private func computeProfile(_ eventsByDay: [Date: [CalendarEvent]]) -> WeeklyGridAxisProfile {
        let cal = Calendar.current
        let countsByDay: [[Int: Int]] = weekDays.map { day in
            let events = eventsByDay[cal.startOfDay(for: day)] ?? []
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
            .background(Color.holoCardBackground.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                    .stroke(Color.holoBorder.opacity(0.48), lineWidth: 1)
            )
            .simultaneousGesture(horizontalPagingGesture)

            legend
                .padding(.top, HoloSpacing.xs)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.lg)
    }

    // MARK: - 固定日期栏

    /// 泳道分隔线：内部边界 1pt（最外侧边界由卡片描边承担，避免叠成双线）
    private var laneSeparator: some View {
        Rectangle()
            .fill(Color.holoBorder.opacity(0.48))
            .frame(width: 1)
    }

    private var calendarHeader: some View {
        GeometryReader { geo in
            let columnWidth = max(0, (geo.size.width - timeAxisWidth) / CGFloat(dayCount))
            let viewportWidth = columnWidth * CGFloat(dayCount)
            HStack(spacing: 0) {
                morningToggleCell
                    .frame(width: timeAxisWidth, height: dayHeaderHeight)
                    .background(Color.holoNestedCardBackground.opacity(0.52))
                    .overlay(alignment: .trailing) { laneSeparator }

                HStack(spacing: 0) {
                    ForEach(Array(weekDays.enumerated()), id: \.element) { index, day in
                        dayHeader(day)
                            .frame(width: columnWidth, height: dayHeaderHeight)
                            .overlay(alignment: .trailing) {
                                if index < weekDays.count - 1 { laneSeparator }
                            }
                            // 视觉上已裁掉的日期也从辅助功能树中移除，避免 VoiceOver
                            // 聚焦到屏幕外的周内日期，造成“焦点跳走但画面没动”。
                            .accessibilityHidden(!isWindowIndexVisible(index))
                    }
                }
                .frame(width: columnWidth * CGFloat(weekDays.count), alignment: .leading)
                .offset(x: stripOffset(columnWidth: columnWidth))
                .animation(.easeOut(duration: 0.22), value: windowStartIndex)
                .frame(width: viewportWidth, height: dayHeaderHeight, alignment: .leading)
                .clipped()
            }
        }
        .frame(height: dayHeaderHeight)
        .background(Color.holoNestedCardBackground.opacity(0.52))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.holoBorder.opacity(0.45))
                .frame(height: 0.5)
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
        .accessibilityLabel(collapseMorning ? String(localized: "展开凌晨零点到七点") : String(localized: "收起凌晨零点到七点"))
        .accessibilityHint(String(localized: "显示或隐藏凌晨零点到七点的时间轴"))
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
                Color.holoPrimary.opacity(0.032)
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
        let isFocused = Calendar.current.isDate(day, inSameDayAs: focusedDate)
        // 未来日期弱化（方案 §6.3）：今天之后的列不暗示已有记忆
        let isFuture = day > Calendar.current.startOfDay(for: Date())
        let weekdayLabel = isToday
            ? String(localized: "\(Self.weekdayText(for: day)) · 今天")
            : Self.weekdayText(for: day)
        return Button {
            focusedDate = day
            onEnsureData(day)
        } label: {
            VStack(spacing: 3) {
                Text(weekdayLabel)
                    .font(.system(size: 10, weight: isToday ? .semibold : .medium))
                    .foregroundColor(headerWeekdayColor(isToday: isToday, isFuture: isFuture))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(Self.dayText(for: day))
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundColor(headerDayColor(isToday: isToday, isFocused: isFocused, isFuture: isFuture))
                    .frame(width: 30, height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(headerDayBackground(isToday: isToday, isFocused: isFocused))
                    }
            }
            .frame(maxWidth: .infinity)
            .frame(height: dayHeaderHeight)
            .background(isToday ? Color.holoPrimary.opacity(0.035) : Color.clear)
            .overlay(alignment: .bottom) {
                if isToday {
                    Rectangle()
                        .fill(Color.holoPrimary)
                        .frame(height: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityHint(isFuture ? String(localized: "未来日期还没有可回看的记忆") : "")
    }

    private func headerWeekdayColor(isToday: Bool, isFuture: Bool) -> Color {
        if isToday { return .holoPrimary }
        return isFuture ? .holoTextPlaceholder : .holoTextSecondary
    }

    private func headerDayColor(isToday: Bool, isFocused: Bool, isFuture: Bool) -> Color {
        if isToday { return .holoPrimary }
        if isFocused { return .holoTextPrimary }
        return isFuture ? .holoTextPlaceholder : .holoTextPrimary
    }

    private func headerDayBackground(isToday: Bool, isFocused: Bool) -> Color {
        if isToday { return .holoPrimary.opacity(0.11) }
        if isFocused { return .holoNestedCardBackground }
        return .clear
    }

    // MARK: - 凌晨摘要（卡片内部横带）

    private var morningSummaryRow: some View {
        GeometryReader { geo in
            let columnWidth = max(0, (geo.size.width - timeAxisWidth) / CGFloat(dayCount))
            let viewportWidth = columnWidth * CGFloat(dayCount)
            HStack(spacing: 0) {
                VStack(spacing: 1) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 9, weight: .medium))
                    Text("凌晨")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundColor(.holoTextSecondary)
                .frame(width: timeAxisWidth, height: morningSummaryHeight)
                .background(Color.holoNestedCardBackground.opacity(0.52))
                .overlay(alignment: .trailing) { laneSeparator }

                HStack(spacing: 0) {
                    ForEach(Array(weekDays.enumerated()), id: \.element) { index, day in
                        collapsedMorningCell(for: day)
                            .frame(width: columnWidth, height: morningSummaryHeight)
                            .overlay(alignment: .trailing) {
                                if index < weekDays.count - 1 { laneSeparator }
                            }
                            .accessibilityHidden(!isWindowIndexVisible(index))
                    }
                }
                .frame(width: columnWidth * CGFloat(weekDays.count), alignment: .leading)
                .offset(x: stripOffset(columnWidth: columnWidth))
                .animation(.easeOut(duration: 0.22), value: windowStartIndex)
                .frame(width: viewportWidth, height: morningSummaryHeight, alignment: .leading)
                .clipped()
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
        .background(Color.holoNestedCardBackground.opacity(0.52))
        .overlay(alignment: .trailing) { laneSeparator }
    }

    private func gridBackground(profile: WeeklyGridAxisProfile) -> some View {
        VStack(spacing: 0) {
            ForEach(profile.segments) { segment in
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: segment.height)
                    .overlay(
                        Rectangle().fill(Color.holoDivider.opacity(0.52)).frame(height: 0.5),
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
                ? String(localized: "\(Self.weekdayText(for: day))凌晨无记录")
                : String(localized: "\(Self.weekdayText(for: day))凌晨 \(earlyEvents.count) 条记录")
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

                    eventStrip(
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

    private func eventStrip(profile: WeeklyGridAxisProfile,
                            columnWidth: CGFloat,
                            viewportWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(weekDays, id: \.self) { day in
                eventColumn(
                    day,
                    columnWidth: columnWidth,
                    profile: profile,
                    events: eventsByDay[day] ?? []
                )
            }
        }
        .frame(width: columnWidth * CGFloat(weekDays.count), alignment: .leading)
        .offset(x: stripOffset(columnWidth: columnWidth))
        .animation(.easeOut(duration: 0.22), value: windowStartIndex)
        .frame(width: viewportWidth, height: profile.totalHeight, alignment: .topLeading)
        .clipped()
    }

    // MARK: - 横向三日窗口

    /// 三层共用的实际偏移。到今天/周首边界时保留少量橡皮筋反馈，但不会改变逻辑窗口。
    private func stripOffset(columnWidth: CGFloat) -> CGFloat {
        let base = -CGFloat(windowStartIndex) * columnWidth
        let isPastLeadingEdge = windowStartIndex == 0 && pagerDragOffset > 0
        let isPastTrailingEdge = windowStartIndex == windowPolicy.maximumStartIndex && pagerDragOffset < 0
        let drag = (isPastLeadingEdge || isPastTrailingEdge) ? pagerDragOffset * 0.16 : pagerDragOffset
        return base + drag
    }

    /// 自定义横向手势与纵向 ScrollView 同时识别：只有明显的横向移动才更新三日窗口，
    /// 从根上消除水平 ScrollView 嵌套导致的上下滑动抢占。
    private var horizontalPagingGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($pagerDragOffset) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.15 else {
                    state = 0
                    return
                }
                state = value.translation.width
            }
            .onEnded { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height) * 1.15
                guard isHorizontal else { return }

                let projected = abs(value.predictedEndTranslation.width) > abs(value.translation.width)
                    ? value.predictedEndTranslation.width
                    : value.translation.width
                guard abs(projected) >= 44 else { return }
                moveWindow(by: projected < 0 ? 1 : -1)
            }
    }

    private func moveWindow(by delta: Int) {
        let nextStart = windowPolicy.steppedStartIndex(from: windowStartIndex, by: delta)
        guard nextStart != windowStartIndex,
              weekDays.indices.contains(windowPolicy.focusIndex(forWindowStart: nextStart)) else { return }

        let nextDay = weekDays[windowPolicy.focusIndex(forWindowStart: nextStart)]
        withAnimation(.easeOut(duration: 0.22)) {
            focusedDate = nextDay
        }
        onEnsureData(nextDay)
    }

    /// 屏幕实际只显示三天；被裁掉的列不应继续接收辅助功能焦点。
    private func isWindowIndexVisible(_ index: Int) -> Bool {
        let end = min(weekDays.count, windowStartIndex + dayCount)
        return index >= windowStartIndex && index < end
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
            .background(accentColor.opacity(item.isOverflow ? 0.045 : 0.075))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(accentColor.opacity(item.isOverflow ? 0.65 : 0.82))
                    .frame(width: 2)
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
                    // 时间线完全收在今天列内，今天刚滑出窗口时不会从相邻列边缘露出。
                    .frame(width: max(0, columnWidth - 2), height: 1.5)
                    .offset(x: 1, y: top)
                Circle()
                    .fill(Color.holoPrimary)
                    .frame(width: 6, height: 6)
                    .offset(x: 1, y: top - 3)
            }
        }
    }

    // MARK: - 图例

    private var legend: some View {
        HStack(spacing: HoloSpacing.sm) {
            ForEach([CalendarModule.finance, .habit, .todo, .thought], id: \.self) { module in
                HStack(spacing: 4) {
                    Circle()
                        .fill(module.color.opacity(0.82))
                        .frame(width: 5, height: 5)
                    Text(module.displayName)
                }
            }
            Spacer(minLength: 0)
            if abs(clampedHourScale - 1) > 0.001 {
                Button(action: resetHourScale) {
                    Text(String(format: String(localized: "缩放 %.2f×"), clampedHourScale))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.holoPrimary.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "当前时间轴缩放 \(String(format: "%.2f", clampedHourScale)) 倍，轻点恢复一倍"))
            }
        }
        .font(.system(size: 10, weight: .medium))
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
