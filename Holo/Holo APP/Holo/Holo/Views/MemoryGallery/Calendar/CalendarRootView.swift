//
//  CalendarRootView.swift
//  Holo
//
//  日历视图根容器：周历/月历切换 + 周历布局切换 + 失败态
//

import SwiftUI

struct CalendarRootView: View {

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel = CalendarViewModel()
    @State private var selectedEvent: CalendarEvent?
    @State private var selectedEventGroup: CalendarEventGroup?

    var body: some View {
        VStack(spacing: 0) {
            modeSwitch
            navBar
            CalendarObservationSummaryView(summary: viewModel.observationSummary)
                .padding(.horizontal, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.sm)
            if viewModel.mode == .weekly { weekListGridSwitch }
            if viewModel.hasFailure { failureBanner }
            content
        }
        .background(Color.holoBackground)
        .task {
            if viewModel.eventsByDay.isEmpty && viewModel.monthEventsByDay.isEmpty {
                await viewModel.load()
            }
        }
        .refreshable {
            await viewModel.load()
        }
        .sheet(item: $selectedEvent) { event in
            CalendarEventDetailSheet(event: event)
        }
        .sheet(item: $selectedEventGroup) { group in
            CalendarEventGroupDetailSheet(group: group)
        }
    }

    // MARK: - 内容（周历 / 月历）

    @ViewBuilder
    private var content: some View {
        switch viewModel.mode {
        case .weekly:  weeklyContent
        case .monthly: monthlyContent
        }
    }

    @ViewBuilder
    private var weeklyContent: some View {
        switch viewModel.weekViewMode {
        case .list:
            WeeklyListView(
                eventsByDay: viewModel.eventsByDay,
                isLoading: viewModel.isLoading,
                onSelect: { selectedEvent = $0 }
            )
        case .grid:
            WeeklyGridView(
                weekStart: viewModel.currentRange.start,
                eventsByDay: viewModel.monthEventsByDay,
                onSelect: { selectedEvent = $0 },
                onSelectGroup: { selectedEventGroup = CalendarEventGroup(events: $0) }
            )
        }
    }

    private var monthlyContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.md) {
                HStack {
                    HealthStatusChip()
                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)

                MonthlyCalendarView(
                    monthAnchor: viewModel.anchor,
                    eventsByDay: viewModel.monthEventsByDay,
                    selectedDay: viewModel.selectedDay,
                    cellStyle: .heatmap,
                    onSelectDay: { viewModel.selectDay($0) }
                )
                .padding(.horizontal, HoloSpacing.md)

                monthLegend
                    .padding(.horizontal, HoloSpacing.md)

                if let day = viewModel.selectedDay {
                    DayDetailCard(day: day, events: viewModel.selectedDayEvents)
                        .padding(.horizontal, HoloSpacing.md)
                    Spacer(minLength: HoloSpacing.lg)
                }
            }
            .padding(.top, HoloSpacing.sm)
        }
    }

    // MARK: - 切换器

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            ForEach([CalendarViewModel.Mode.weekly, .monthly], id: \.self) { m in
                Button {
                    viewModel.switchMode(m)
                } label: {
                    Text(m == .weekly ? "周历" : "月历")
                        .font(.system(size: 13, weight: viewModel.mode == m ? .semibold : .medium))
                        .foregroundColor(viewModel.mode == m ? .white : .holoTextSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: HoloRadius.sm)
                                .fill(viewModel.mode == m ? Color.holoPrimary : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.55), lineWidth: 1)
        )
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.sm)
    }

    private var weekListGridSwitch: some View {
        HStack(spacing: 0) {
            weekModeButton(.grid, title: "网格视图")
            weekModeButton(.list, title: "列表视图")
        }
        .padding(2)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .stroke(Color.holoBorder.opacity(0.8), lineWidth: 1)
        )
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.bottom, HoloSpacing.sm)
    }

    private func weekModeButton(_ mode: WeekViewMode, title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                viewModel.weekViewMode = mode
            }
        } label: {
            let isSelected = viewModel.weekViewMode == mode
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : .holoTextSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.holoPrimary : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 导航

    private var navBar: some View {
        HStack(spacing: HoloSpacing.sm) {
            chevronButton(systemName: "chevron.left", action: viewModel.goToPrev)
            Text(viewModel.title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity)
            chevronButton(systemName: "chevron.right", action: viewModel.goToNext)
            Button {
                viewModel.goToToday()
            } label: {
                Text(viewModel.mode == .weekly ? "本周" : "今天")
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimaryDark)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Color.holoPrimaryLight)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
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
            legendDot(color: CalendarHeatmap.color(forLevel: 0, colorScheme: colorScheme))
            Text("少")
            legendDot(color: CalendarHeatmap.color(forLevel: 2, colorScheme: colorScheme))
            legendDot(color: CalendarHeatmap.color(forLevel: 4, colorScheme: colorScheme))
            Text("多")
            Text("色深=活跃度 · 底条=模块")
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
                Task { await viewModel.load() }
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

private struct CalendarObservationSummaryView: View {
    let summary: CalendarObservationSummary

    var body: some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 22, height: 22)
                .background(iconColor.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)
                Text(summary.evidence)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, HoloSpacing.sm)
        .padding(.vertical, HoloSpacing.sm)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.65), lineWidth: 1)
        )
    }

    private var iconName: String {
        switch summary.tone {
        case .empty: return "moon"
        case .quiet: return "eye"
        case .normal: return "sparkles"
        case .notable: return "sparkles"
        }
    }

    private var iconColor: Color {
        switch summary.tone {
        case .empty, .quiet: return .holoTextSecondary
        case .normal: return .holoChart1
        case .notable: return .holoPrimary
        }
    }

    private var backgroundColor: Color {
        switch summary.tone {
        case .empty, .quiet: return Color.holoCardBackground
        case .normal: return Color.holoChart1.opacity(0.06)
        case .notable: return Color.holoPrimary.opacity(0.08)
        }
    }
}
