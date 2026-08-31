//
//  DailyReplayView.swift
//  Holo
//
//  「记忆河流」日回放：日期是章节，不是右侧索引。列表自最新向过去流动——
//  打开就在今天，向上滑动回看更早的一天；翻页把更早的页追加在列表底部，
//  永远不动正在阅读的位置（此前「往顶部插入更早内容再钉回位置」的两轮方案
//  在 SwiftUI 下时序不可靠，已在踩坑速查表结案：位置保持类方案禁止再用于首屏定位）。
//  无意义的小时网格和常驻彩色导航被移除，视觉重心回到可理解的生活事件。
//

import SwiftUI

struct DailyReplayView: View {
    @Binding var focusedDate: Date
    let eventsByDay: [Date: [CalendarEvent]]
    @Binding var moduleFilter: CalendarModule?
    let isInitialLoading: Bool
    let onSelect: (CalendarEvent) -> Void
    let onSelectGroup: ([CalendarEvent]) -> Void
    let onEnsureData: (Date) -> Void

    /// 窗口两端：end=最晚一天（列表顶部，通常为聚焦/今天），start=最早一天（列表底部，翻页向过去扩）。
    @State private var rangeStart: Date
    @State private var rangeEnd: Date
    @State private var showDatePicker = false
    @State private var pickerDate: Date
    @State private var portalDate: Date?
    @State private var scrollDrivenDate: Date?

    private let pageSize = 12
    /// 最早章节（列表底端）进入视口下方这段距离内即向过去再铺一页；追加在底部不动视口。
    private let earlierPagePrefetchDistance: CGFloat = 2
    private let scrollSpace = "holo.memoryGallery.dailyReplay"
    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }

    init(focusedDate: Binding<Date>,
         eventsByDay: [Date: [CalendarEvent]],
         moduleFilter: Binding<CalendarModule?>,
         isInitialLoading: Bool,
         onSelect: @escaping (CalendarEvent) -> Void,
         onSelectGroup: @escaping ([CalendarEvent]) -> Void,
         onEnsureData: @escaping (Date) -> Void) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let anchorDay = min(calendar.startOfDay(for: focusedDate.wrappedValue), today)
        let start = calendar.date(byAdding: .day, value: -12, to: anchorDay) ?? anchorDay

        self._focusedDate = focusedDate
        self.eventsByDay = eventsByDay
        self._moduleFilter = moduleFilter
        self.isInitialLoading = isInitialLoading
        self.onSelect = onSelect
        self.onSelectGroup = onSelectGroup
        self.onEnsureData = onEnsureData
        self._rangeStart = State(initialValue: start)
        self._rangeEnd = State(initialValue: anchorDay)
        self._pickerDate = State(initialValue: anchorDay)
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            if isInitialLoading && eventsByDay.isEmpty {
                                loadingChapter
                            } else {
                                chapterList(
                                    proxy: proxy,
                                    minimumDayContentHeight: max(260, viewport.size.height - 92)
                                )
                            }
                        }
                    }
                    .coordinateSpace(name: scrollSpace)
                    .background(Color.holoPaper)
                    .onPreferenceChange(DailyReplayChapterOffsetKey.self) { offsets in
                        updateFocusedDate(from: offsets)
                        appendEarlierPageIfNeeded(
                            from: offsets,
                            viewportHeight: viewport.size.height
                        )
                    }

                    if let shownDate = portalDate {
                        DailyReplayDatePortal(
                            date: shownDate,
                            eventCount: eventsByDay[calendar.startOfDay(for: shownDate)]?.count ?? 0,
                            onScrub: { scrubbed in
                                portalDate = scrubbed
                            },
                            onCommit: {
                                guard let target = portalDate else { return }
                                withAnimation(HoloAnimation.quick) { portalDate = nil }
                                jump(to: target, proxy: proxy)
                            },
                            onCancel: {
                                withAnimation(HoloAnimation.quick) { portalDate = nil }
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(30)
                    }
                }
                .sensoryFeedback(.selection, trigger: portalDate)
                .onAppear {
                    onEnsureData(focusedDate)
                }
                .onChange(of: focusedDate) { _, newDate in
                    let target = calendar.startOfDay(for: min(newDate, today))
                    if let scrollDrivenDate, calendar.isDate(scrollDrivenDate, inSameDayAs: target) {
                        self.scrollDrivenDate = nil
                        return
                    }
                    jump(to: target, proxy: proxy)
                }
                .sheet(isPresented: $showDatePicker) {
                    DailyReplayDatePickerSheet(
                        selection: $pickerDate,
                        isPresented: $showDatePicker,
                        onCommit: { jump(to: pickerDate, proxy: proxy) }
                    )
                }
            }
        }
    }

    // MARK: - 连续章节

    @ViewBuilder
    private func chapterList(proxy: ScrollViewProxy,
                             minimumDayContentHeight: CGFloat) -> some View {
        if calendar.isDate(rangeEnd, inSameDayAs: today) {
            DailyReplayTodayEndView()
        }

        ForEach(chapters) { chapter in
            switch chapter {
            case .day(let day):
                daySection(
                    day,
                    proxy: proxy,
                    minimumDayContentHeight: minimumDayContentHeight
                )
            case .gap(let days):
                ForEach(days, id: \.self) { day in
                    daySection(
                        day,
                        proxy: proxy,
                        minimumDayContentHeight: minimumDayContentHeight
                    )
                }
            }
        }
    }

    private func daySection(_ day: Date,
                            proxy: ScrollViewProxy,
                            minimumDayContentHeight: CGFloat) -> some View {
        let dayStart = calendar.startOfDay(for: day)
        let events = eventsByDay[dayStart] ?? []
        return Section {
            DailyReplayDayContent(
                day: dayStart,
                events: events,
                moduleFilter: moduleFilter,
                onSelect: onSelect,
                onSelectGroup: onSelectGroup,
                minimumHeight: minimumDayContentHeight,
                onEmptySwipe: { direction in
                    navigateEmptyDay(from: dayStart, direction: direction, proxy: proxy)
                }
            )
        } header: {
            DailyReplayChapterHeader(
                day: dayStart,
                events: events,
                moduleFilter: $moduleFilter,
                onChooseDate: {
                    pickerDate = dayStart
                    showDatePicker = true
                },
                onPortalChanged: { offset in
                    updatePortal(anchor: dayStart, offset: offset)
                },
                onPortalCommitted: { offset in
                    // 拖动过再松手：前往门上正显示的日期。原地松手（offset 为 0）则把门留在
                    // 屏上，交给门自身的拖动/轻点/点空白接手——长按只负责开门，不再要求
                    // 一气呵成；这也保证了手势被系统中断时门永远有出口，不会卡死在屏上。
                    guard offset != 0, let current = portalDate else { return }
                    withAnimation(HoloAnimation.quick) { portalDate = nil }
                    jump(to: current, proxy: proxy)
                },
                onPortalCancelled: {
                    withAnimation(HoloAnimation.quick) { portalDate = nil }
                }
            )
            .id(dayStart)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: DailyReplayChapterOffsetKey.self,
                        value: [dayStart: geometry.frame(in: .named(scrollSpace)).minY]
                    )
                }
            )
        }
    }

    /// 自最新向过去排列：构建器产出升序，这里反转为降序——最晚一天在列表顶部。
    private var chapters: [DailyReplayChapter] {
        DailyReplayChapterBuilder.make(
            from: rangeStart,
            through: rangeEnd,
            eventCountsByDay: eventsByDay.mapValues(\.count),
            collapseEmptyRuns: false
        ).reversed()
    }

    /// 最早章节（列表底端）接近视口时向过去再铺一页。追加发生在底部，
    /// 不触碰正在阅读的位置——没有任何滚动补偿或锚定，也因此没有时序风险。
    private func appendEarlierPageIfNeeded(from offsets: [Date: CGFloat],
                                           viewportHeight: CGFloat) {
        guard let earliestOffset = offsets[calendar.startOfDay(for: rangeStart)],
              earliestOffset <= viewportHeight * earlierPagePrefetchDistance,
              let earlier = DailyReplayPageWindow.earlierPage(before: rangeStart, pageSize: pageSize, calendar: calendar) else { return }
        rangeStart = earlier
        onEnsureData(earlier)
    }

    /// 章节头进入顶部后同步全局聚焦日期；周/月切换会延续用户正在阅读的这一天。
    private func updateFocusedDate(from offsets: [Date: CGFloat]) {
        guard !offsets.isEmpty else { return }
        let passed = offsets.filter { $0.value <= 10 }
        let candidate = passed.max(by: { $0.value < $1.value })?.key
            ?? offsets.min(by: { abs($0.value) < abs($1.value) })?.key
        guard let day = candidate,
              !calendar.isDate(day, inSameDayAs: focusedDate) else { return }
        scrollDrivenDate = day
        focusedDate = day
        onEnsureData(day)
    }

    private func jump(to rawDate: Date, proxy: ScrollViewProxy) {
        let target = calendar.startOfDay(for: min(rawDate, today))
        rangeEnd = target
        rangeStart = calendar.date(byAdding: .day, value: -pageSize, to: target) ?? target
        onEnsureData(target)
        if !calendar.isDate(target, inSameDayAs: focusedDate) {
            focusedDate = target
        }
        DispatchQueue.main.async {
            withAnimation(HoloAnimation.standard) {
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }

    private func navigateEmptyDay(from day: Date,
                                  direction: DailyReplayEmptyDaySwipeDirection,
                                  proxy: ScrollViewProxy) {
        let target = DailyReplayEmptyDayNavigation.target(
            from: day,
            direction: direction,
            today: today,
            calendar: calendar
        )
        guard !calendar.isDate(target, inSameDayAs: day) else { return }
        jump(to: target, proxy: proxy)
    }

    // MARK: - 日期时间门

    private func updatePortal(anchor: Date, offset: Int) {
        let target = portalTarget(anchor: anchor, offset: offset)
        if portalDate == nil {
            withAnimation(HoloAnimation.quick) { portalDate = target }
        } else {
            // 已经开门后的连续穿梭直接赋值，套动画会让数字追着手指跑，显得不跟手。
            portalDate = target
        }
    }

    private func portalTarget(anchor: Date, offset: Int) -> Date {
        let target = calendar.date(byAdding: .day, value: offset, to: anchor) ?? anchor
        return calendar.startOfDay(for: min(target, today))
    }

    // MARK: - 加载态

    private var loadingChapter: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(alignment: .center, spacing: HoloSpacing.md) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.holoNestedCardBackground)
                    .frame(width: 66, height: 54)
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.holoNestedCardBackground)
                        .frame(width: 108, height: 14)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.holoNestedCardBackground)
                        .frame(width: 150, height: 9)
                }
            }
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color.holoCardBackground)
                    .frame(height: 94)
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.lg)
                            .stroke(Color.holoBorder.opacity(0.4), lineWidth: 1)
                    )
            }
        }
        .padding(HoloSpacing.md)
    }
}

// MARK: - 章节头

private struct DailyReplayChapterHeader: View {
    let day: Date
    let events: [CalendarEvent]
    @Binding var moduleFilter: CalendarModule?
    let onChooseDate: () -> Void
    let onPortalChanged: (Int) -> Void
    let onPortalCommitted: (Int) -> Void
    let onPortalCancelled: () -> Void

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        MemoryTimeChapterHeader(
            presentation: presentation,
            moduleFilter: $moduleFilter,
            backgroundColor: .holoPaper
        ) {
            dateControl
        }
    }

    private var dateControl: some View {
        Text("\(calendar.component(.day, from: day))")
            .font(.system(size: 48, weight: .medium, design: .serif))
            .foregroundColor(.holoTextPrimary)
            .tracking(-2)
            .frame(width: 66, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onChooseDate)
            .highPriorityGesture(portalGesture)
            .accessibilityLabel("\(Self.fullDateFormatter.string(from: day))，轻点选择日期，长按快速穿梭")
            .accessibilityAddTraits(.isButton)
    }

    private var presentation: MemoryTimeChapterPresentation {
        let reliable = events.filter(\.hasReliableTime).sorted { $0.date < $1.date }
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return MemoryTimeChapterPresentation.make(
            scale: .day,
            focusedDate: day,
            periodStart: day,
            periodEnd: end,
            eventCount: events.count,
            momentCount: DailyReplayPresentation.moments(from: events).count,
            activeDayCount: events.isEmpty ? 0 : 1,
            firstEventDate: reliable.first?.date,
            lastEventDate: reliable.last?.date,
            isCurrentPeriod: calendar.isDateInToday(day)
        )
    }

    private var portalGesture: some Gesture {
        // 长按开门后同一根手指继续拖即穿梭；时长与位移阈值放得比一般长按更宽，
        // 否则用户「按下就开始滑」时触摸会被底层列表抢走，门根本开不出来。
        LongPressGesture(minimumDuration: 0.3, maximumDistance: 24)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    onPortalChanged(0)
                case .second(true, let drag):
                    onPortalChanged(portalOffset(for: drag?.translation.height ?? 0))
                default:
                    break
                }
            }
            .onEnded { value in
                switch value {
                case .second(true, let drag):
                    onPortalCommitted(portalOffset(for: drag?.translation.height ?? 0))
                case .first(true):
                    onPortalCommitted(0)
                default:
                    onPortalCancelled()
                }
            }
    }

    private func portalOffset(for translation: CGFloat) -> Int {
        // 与列表方向一致：向上拖回看更早，向下拖去往更近的日期；每 42pt 跨一天。
        Int((translation / 42).rounded())
    }

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()
}

// MARK: - 单日内容

private struct DailyReplayDayContent: View {
    let day: Date
    let events: [CalendarEvent]
    let moduleFilter: CalendarModule?
    let onSelect: (CalendarEvent) -> Void
    let onSelectGroup: ([CalendarEvent]) -> Void
    let minimumHeight: CGFloat
    let onEmptySwipe: (DailyReplayEmptyDaySwipeDirection) -> Void

    private var momentsByPeriod: [DailyReplayPeriod: [DailyReplayMoment]] {
        DailyReplayPresentation.momentsByPeriod(from: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if events.isEmpty {
                emptyState
                Spacer(minLength: 48)
            } else {
                if let narrative = DailyReplayPresentation.narrative(for: events) {
                    dayNarrative(narrative)
                }

                ForEach(DailyReplayPeriod.allCases) { period in
                    if let moments = momentsByPeriod[period], !moments.isEmpty {
                        periodBlock(period, moments: moments)
                    }
                }
            }

            HStack(spacing: 9) {
                Rectangle().fill(Color.holoBorder.opacity(0.35)).frame(height: 1)
                Text(footerText)
                    .font(.system(size: 9, weight: .medium, design: .serif))
                    .foregroundColor(.holoTextPlaceholder)
                    .fixedSize()
                Rectangle().fill(Color.holoBorder.opacity(0.35)).frame(height: 1)
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .frame(minHeight: events.isEmpty ? minimumHeight : 0, alignment: .top)
        .contentShape(Rectangle())
        .simultaneousGesture(emptyDaySwipeGesture)
    }

    private var footerText: String {
        guard events.isEmpty else {
            return Calendar.current.isDateInToday(day) ? "此刻" : "继续向下，回看前一天"
        }
        return Calendar.current.isDateInToday(day) ? "上滑回看昨天" : "上滑回看前一天"
    }

    private var emptyDaySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard events.isEmpty,
                      abs(value.translation.height) > abs(value.translation.width) * 1.15,
                      abs(value.translation.height) >= 44 else { return }
                onEmptySwipe(value.translation.height < 0 ? .upward : .downward)
            }
    }

    private func periodBlock(_ period: DailyReplayPeriod, moments: [DailyReplayMoment]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Text(period.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .serif))
                    .foregroundColor(.holoTextSecondary)
                    .tracking(1.5)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.holoBorder.opacity(0.55), Color.holoBorder.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
            }
            .padding(.leading, 56)

            ForEach(moments) { moment in
                HStack(alignment: .top, spacing: 10) {
                    Text(moment.timeText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.holoTextSecondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                        .padding(.top, 14)

                    DailyReplayEventCard(
                        moment: moment,
                        onSelect: onSelect,
                        onSelectGroup: onSelectGroup
                    )
                }
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, 16)
    }

    private func dayNarrative(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.holoPrimary)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .serif))
                .foregroundColor(.holoTextSecondary)
                .lineSpacing(4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            LinearGradient(
                colors: [Color.holoPrimary.opacity(0.085), Color.holoCardBackground.opacity(0.45)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.13), lineWidth: 1)
        )
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, HoloSpacing.sm)
    }

    private var emptyState: some View {
        Text(moduleFilter.map { "这一天没有\($0.displayName)记录" } ?? "这一天没有留下记录，生活安静地经过。")
            .font(.system(size: 11, weight: .medium, design: .serif))
            .foregroundColor(.holoTextPlaceholder)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.holoCardBackground.opacity(0.32))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .stroke(Color.holoBorder.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .padding(.horizontal, HoloSpacing.md)
            .padding(.top, HoloSpacing.sm)
    }
}

// MARK: - 今天终点 / 日期选择 / 时间门

/// 今日开篇轻刻度（A 案定稿）：一行居中小字＋两侧渐隐细线，标记时间轴的「现在」端点。
/// 替代原满宽渐变大卡——无背景无描边，不再与今天的内容卡抢首屏视觉权重。
private struct DailyReplayTodayEndView: View {
    var body: some View {
        HStack(spacing: 12) {
            dividerLine
            Text("今天的记忆还在继续")
                .font(.system(size: 11, weight: .medium, design: .serif))
                .foregroundColor(.holoTextPlaceholder)
                .fixedSize()
            dividerLine
        }
        .padding(.horizontal, 56)
        .padding(.top, HoloSpacing.lg)
        .accessibilityLabel("时间轴从今天开始，上滑回看更早")
    }

    private var dividerLine: some View {
        LinearGradient(
            colors: [Color.holoBorder.opacity(0), Color.holoBorder.opacity(0.9), Color.holoBorder.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }
}

private struct DailyReplayDatePickerSheet: View {
    @Binding var selection: Date
    @Binding var isPresented: Bool
    let onCommit: () -> Void

    var body: some View {
        NavigationStack {
            DatePicker(
                "选择回看的日期",
                selection: $selection,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("回到某一天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("前往") {
                        isPresented = false
                        onCommit()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 时间门：长按日期唤出的模态蒙层。蒙层拦下一切触摸——点空白处退出；
/// 门上的日期可上下拖动继续穿梭，松手或轻点门即前往所选日期。
/// 此前它是纯展示贴图（关闭触摸测试），蒙层形同虚设且只能靠手势结束来关闭，
/// 手势一旦被系统中断门就永远挂在屏上，与底下的交互互相打架。
private struct DailyReplayDatePortal: View {
    let date: Date
    let eventCount: Int
    let onScrub: (Date) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    /// 拖动基准日：本次手势起点时门上显示的日期。用 GestureState 承载，
    /// 手势结束或被系统中断都会自动归 nil，不会把上一次的基准带进下一次。
    @GestureState private var scrubBase: Date?

    var body: some View {
        ZStack {
            Color.black.opacity(0.56)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            portalCard
        }
    }

    private var portalCard: some View {
        VStack(spacing: 8) {
            Text("时间门")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.holoPrimary)
                .tracking(2)
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 76, weight: .medium, design: .serif))
                .foregroundColor(.white)
                .tracking(-4)
            Text(Self.formatter.string(from: date))
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundColor(.white.opacity(0.86))
            Text("\(eventCount) 条记录 · 上下拖动穿梭")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.48))
            Text("轻点日期前往 · 点空白处退出")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.32))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.xl, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.xl, style: .continuous))
        .onTapGesture(perform: onCommit)
        .highPriorityGesture(scrubGesture)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("上下拖动穿梭日期，松手或轻点前往")
        .accessibilityAction(named: "取消并关闭") { onCancel() }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($scrubBase) { _, state, _ in
                if state == nil { state = date }
            }
            .onChanged { value in
                let base = scrubBase ?? date
                onScrub(Self.shift(base, by: value.translation.height))
            }
            .onEnded { _ in
                onCommit()
            }
    }

    /// 与章节头长按穿梭同一口径：向上拖回看更早，每 42pt 一天，不越过今天。
    private static func shift(_ base: Date, by translation: CGFloat) -> Date {
        let calendar = Calendar.current
        let target = calendar.date(byAdding: .day, value: Int((translation / 42).rounded()), to: base) ?? base
        return calendar.startOfDay(for: min(target, Date()))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月 · EEEE"
        return formatter
    }()
}

private struct DailyReplayChapterOffsetKey: PreferenceKey {
    static var defaultValue: [Date: CGFloat] = [:]

    static func reduce(value: inout [Date: CGFloat], nextValue: () -> [Date: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
