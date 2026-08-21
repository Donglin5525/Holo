//
//  CalendarRootView.swift
//  Holo
//
//  日历视图根容器（统一时间章节）
//  日 / 周 / 月都把日期、事实证据和筛选收进同一套章节头，避免工具面板式堆叠。
//  三档内容（统一浏览方案）：日=单日回放、周=本周七天网格、月=热力月历；
//  三档共享 viewModel.focusedDate，切换尺度日期上下文不丢。
//

import SwiftUI

struct CalendarRootView: View {

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel = CalendarViewModel()
    @State private var selectedEvent: CalendarEvent?
    @State private var selectedEventGroup: CalendarEventGroup?
    @State private var showWeekNarrative = false
    @State private var showScaleDatePicker = false
    @State private var pickerDate = Calendar.current.startOfDay(for: Date())

    var body: some View {
        VStack(spacing: 0) {
            navRow
            if viewModel.hasFailure { failureBanner }
            content
        }
        .background(Color.holoBackground)
        .task {
            await viewModel.loadInitial()
        }
        .refreshable {
            await viewModel.refreshForCurrentScale()
        }
        .sheet(item: $selectedEvent) { event in
            CalendarEventDetailSheet(event: event)
        }
        .sheet(item: $selectedEventGroup) { group in
            CalendarEventGroupDetailSheet(group: group)
        }
        .sheet(isPresented: $showWeekNarrative) {
            WeekNarrativeSheet(
                highlights: viewModel.weekHighlights,
                milestones: viewModel.weekMilestones
            )
        }
        .sheet(isPresented: $showScaleDatePicker) {
            CalendarScaleDatePickerSheet(
                selection: $pickerDate,
                isPresented: $showScaleDatePicker,
                onCommit: { viewModel.focusDay(pickerDate) }
            )
        }
    }

    // MARK: - 内容（日 / 周 / 月）

    @ViewBuilder
    private var content: some View {
        switch viewModel.scale {
        case .day:   dayContent
        case .week:  weekContent
        case .month: monthlyContent
        }
    }

    /// 日档：日期章节连续向今天流动；日期、筛选与当天证据都由章节头承载。
    private var dayContent: some View {
        DailyReplayView(
            focusedDate: $viewModel.focusedDate,
            eventsByDay: viewModel.eventsByDay,
            moduleFilter: $viewModel.moduleFilter,
            isInitialLoading: viewModel.isInitialLoading,
            onSelect: { selectedEvent = $0 },
            onSelectGroup: { selectedEventGroup = CalendarEventGroup(events: $0) },
            onEnsureData: { viewModel.ensureTimelineData(around: $0) }
        )
    }

    /// 周档：同一套时间章节 + 一句可信观察 + 本周七天网格。
    private var weekContent: some View {
        VStack(spacing: 0) {
            scaleChapterHeader

            if viewModel.observationSummary.tone != .empty {
                MemoryNarrativeStrip(
                    text: viewModel.observationSummary.title,
                    actionTitle: weekNarrativeActionTitle,
                    action: weekNarrativeActionTitle == nil ? nil : { showWeekNarrative = true }
                )
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, HoloSpacing.sm)
            }

            WeeklyGridView(
                weekDays: viewModel.currentWeekDays,
                eventsByDay: viewModel.eventsByDay,
                focusedDate: $viewModel.focusedDate,
                onSelect: { selectedEvent = $0 },
                onSelectGroup: { selectedEventGroup = CalendarEventGroup(events: $0) },
                onEnsureData: { viewModel.ensureTimelineData(around: $0) }
            )
        }
    }

    private var weekNarrativeActionTitle: String? {
        let count = viewModel.weekMilestones.count + viewModel.weekHighlights.count
        return count == 0 ? nil : "高光 \(count)"
    }

    /// 月档：时间章节 + 安静月历 + 当天记忆时刻。健康周摘要移出月历，避免跨口径信息干扰。
    private var monthlyContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                scaleChapterHeader

                if viewModel.observationSummary.tone != .empty {
                    MemoryNarrativeStrip(text: viewModel.observationSummary.title)
                        .padding(.horizontal, HoloSpacing.md)
                        .padding(.top, HoloSpacing.sm)
                }

                MonthlyCalendarView(
                    monthAnchor: viewModel.focusedDate,
                    eventsByDay: viewModel.monthEventsByDay,
                    selectedDay: viewModel.focusedDate,
                    cellStyle: .heatmap,
                    onSelectDay: { viewModel.focusDay($0) }
                )
                .padding(.horizontal, HoloSpacing.md)
                .padding(.top, HoloSpacing.md)

                monthLegend
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.top, HoloSpacing.sm)

                DayDetailCard(
                    day: viewModel.focusedDate,
                    events: viewModel.selectedDayEvents,
                    onSelect: { selectedEvent = $0 },
                    onSelectGroup: { selectedEventGroup = CalendarEventGroup(events: $0) },
                    onReplay: viewModel.selectedDayEvents.isEmpty ? nil : {
                        viewModel.enterDayReplay()
                    }
                )
                .padding(.horizontal, HoloSpacing.md)
                .padding(.top, HoloSpacing.lg)
                Spacer(minLength: HoloSpacing.lg)
            }
        }
    }

    /// 周/月章节头：视觉与日回放一致，轻点大时间直接选择日期。
    private var scaleChapterHeader: some View {
        MemoryTimeChapterHeader(
            presentation: viewModel.chapterPresentation,
            moduleFilter: $viewModel.moduleFilter
        ) {
            Button(action: openScaleDatePicker) {
                Text(viewModel.chapterPresentation.primaryText)
                    .font(chapterPrimaryFont)
                    .foregroundColor(.holoTextPrimary)
                    .tracking(viewModel.scale == .week ? -1.5 : -2)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 66, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(viewModel.chapterPresentation.accessibilityLabel)，选择日期")
            .accessibilityHint("轻点打开日期选择器")
        }
    }

    private var chapterPrimaryFont: Font {
        switch viewModel.scale {
        case .day: return .system(size: 48, weight: .medium, design: .serif)
        case .week: return .system(size: 36, weight: .medium, design: .serif)
        case .month: return .system(size: 42, weight: .medium, design: .serif)
        }
    }

    private func openScaleDatePicker() {
        pickerDate = min(viewModel.focusedDate, Date())
        showScaleDatePicker = true
    }

    // MARK: - 导航行：‹ 档位 › 当前期

    private var navRow: some View {
        HStack(spacing: 6) {
            if viewModel.scale != .day {
                chevronButton(systemName: "chevron.left") {
                    viewModel.step(by: -1)
                }
            }

            scaleSwitch

            if viewModel.scale != .day {
                chevronButton(systemName: "chevron.right") {
                    viewModel.step(by: 1)
                }
                .disabled(!viewModel.canStepForward)
                .opacity(viewModel.canStepForward ? 1 : 0.35)
            }

            todayButton
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, HoloSpacing.xs)
    }

    /// 日|周|月 撑满两箭头之间、三档等宽——头部主控件，不做收缩小胶囊
    private var scaleSwitch: some View {
        HStack(spacing: 0) {
            ForEach(CalendarScale.allCases, id: \.self) { scale in
                scaleButton(scale)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(Color.holoNestedCardBackground.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.55), lineWidth: 1)
        )
    }

    private func scaleButton(_ scale: CalendarScale) -> some View {
        let isSelected = viewModel.scale == scale
        return Button {
            withAnimation(HoloAnimation.quick) {
                viewModel.switchScale(scale)
            }
        } label: {
            Text(scale.displayName)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(isSelected ? Color.holoCardBackground : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .stroke(isSelected ? Color.holoPrimary.opacity(0.16) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 回正按钮：已在当前期时置灰免点
    private var todayButton: some View {
        Button {
            viewModel.goToToday()
        } label: {
            Text(viewModel.todayLabel)
                .font(.holoLabel)
                .foregroundColor(viewModel.isAtCurrentPeriod ? .holoTextPlaceholder : .holoPrimary)
                .padding(.horizontal, HoloSpacing.sm)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(viewModel.isAtCurrentPeriod ? Color.holoBorder.opacity(0.28) : Color.holoPrimary.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isAtCurrentPeriod)
    }

    private func chevronButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var monthLegend: some View {
        HStack(spacing: HoloSpacing.sm) {
            legendDot(color: Color.holoCardBackground)
            Text("少")
            legendDot(color: CalendarHeatmap.color(forLevel: 2, colorScheme: colorScheme))
            legendDot(color: CalendarHeatmap.color(forLevel: 4, colorScheme: colorScheme))
            Text("多")
            Text("暖色=活跃度 · 细线=来源")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.holoTextSecondary)
        .padding(.top, 2)
    }

    private func legendDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    // MARK: - 失败态横条

    private var failureBanner: some View {
        HStack(spacing: HoloSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.holoError)
            Text("部分数据暂未载入")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Button {
                Task { await viewModel.refreshForCurrentScale() }
            } label: {
                Text("重试")
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoErrorLight.opacity(0.5))
    }
}

private struct CalendarScaleDatePickerSheet: View {
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
            .tint(.holoPrimary)
            .padding()
            .navigationTitle("回到一段生活")
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
