//
//  DailyReplayView.swift
//  Holo
//
//  「记忆河流」日回放：日期是章节，不是右侧索引；向下阅读自然进入下一天，直到今天。
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

    @State private var rangeStart: Date
    @State private var rangeEnd: Date
    @State private var showDatePicker = false
    @State private var pickerDate: Date
    @State private var portalDate: Date?
    @State private var scrollDrivenDate: Date?

    private let pageSize = 12
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
        let start = min(calendar.startOfDay(for: focusedDate.wrappedValue), today)
        let candidateEnd = calendar.date(byAdding: .day, value: 11, to: start) ?? start

        self._focusedDate = focusedDate
        self.eventsByDay = eventsByDay
        self._moduleFilter = moduleFilter
        self.isInitialLoading = isInitialLoading
        self.onSelect = onSelect
        self.onSelectGroup = onSelectGroup
        self.onEnsureData = onEnsureData
        self._rangeStart = State(initialValue: start)
        self._rangeEnd = State(initialValue: min(candidateEnd, today))
        self._pickerDate = State(initialValue: start)
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
                    .onPreferenceChange(DailyReplayChapterOffsetKey.self) { offsets in
                        updateFocusedDate(from: offsets)
                    }

                    if let portalDate {
                        DailyReplayDatePortal(
                            date: portalDate,
                            eventCount: eventsByDay[calendar.startOfDay(for: portalDate)]?.count ?? 0
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .allowsHitTesting(false)
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

        if calendar.isDate(rangeEnd, inSameDayAs: today) {
            DailyReplayTodayEndView()
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
            .onAppear {
                appendNextPageIfNeeded(after: dayStart)
            }
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
                    let target = portalTarget(anchor: dayStart, offset: offset)
                    withAnimation(HoloAnimation.quick) { portalDate = nil }
                    jump(to: target, proxy: proxy)
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

    private var chapters: [DailyReplayChapter] {
        DailyReplayChapterBuilder.make(
            from: rangeStart,
            through: rangeEnd,
            eventCountsByDay: eventsByDay.mapValues(\.count),
            collapseEmptyRuns: false
        )
    }

    private func appendNextPageIfNeeded(after visibleDay: Date) {
        guard calendar.isDate(visibleDay, inSameDayAs: rangeEnd), rangeEnd < today else { return }
        let candidate = calendar.date(byAdding: .day, value: pageSize, to: rangeEnd) ?? today
        let nextEnd = min(candidate, today)
        guard nextEnd > rangeEnd else { return }
        rangeEnd = nextEnd
        onEnsureData(nextEnd)
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
        rangeStart = target
        rangeEnd = initialEnd(for: target)
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

    private func initialEnd(for start: Date) -> Date {
        min(calendar.date(byAdding: .day, value: pageSize - 1, to: start) ?? start, today)
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
        withAnimation(HoloAnimation.quick) {
            portalDate = portalTarget(anchor: anchor, offset: offset)
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
            moduleFilter: $moduleFilter
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
        LongPressGesture(minimumDuration: 0.38, maximumDistance: 18)
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
        // 向上拖去往未来，向下拖回到更早日期；每 42pt 跨一天。
        Int((-translation / 42).rounded())
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
            return Calendar.current.isDateInToday(day) ? "此刻" : "继续向下，进入下一天"
        }
        return Calendar.current.isDateInToday(day) ? "上滑回看昨天" : "上滑进入下一天"
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

private struct DailyReplayTodayEndView: View {
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.holoPrimary)
            Text("今天的记忆还在继续")
                .font(.system(size: 12, weight: .semibold, design: .serif))
                .foregroundColor(.holoTextSecondary)
            Text("新的记录会继续汇入这里")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.holoTextPlaceholder)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            LinearGradient(
                colors: [Color.holoPrimary.opacity(0.07), Color.holoCardBackground.opacity(0.22)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoPrimary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .padding(.horizontal, 72)
        .padding(.bottom, HoloSpacing.xl)
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

private struct DailyReplayDatePortal: View {
    let date: Date
    let eventCount: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.56).ignoresSafeArea()
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
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.xl, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
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
