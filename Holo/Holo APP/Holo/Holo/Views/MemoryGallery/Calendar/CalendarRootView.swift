//
//  CalendarRootView.swift
//  Holo
//
//  日历视图根容器：周历/月历切换 + 模块筛选 + 待办维度 + 失败态
//  P2：周历列表/网格切换、月历色块形式切换
//

import SwiftUI

struct CalendarRootView: View {

    @StateObject private var viewModel = CalendarViewModel()
    @State private var selectedEvent: CalendarEvent?

    var body: some View {
        VStack(spacing: 0) {
            modeSwitch
            navBar
            CalendarFilterBar(moduleFilter: $viewModel.moduleFilter)
                .padding(.vertical, HoloSpacing.xs)
            if showsTodoDimensionBar { todoDimensionBar }
            if viewModel.mode == .weekly { weekListGridSwitch }
            if viewModel.mode == .monthly { monthCellStyleSwitch }
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
    }

    private var showsTodoDimensionBar: Bool {
        viewModel.moduleFilter == nil || viewModel.moduleFilter == .todo
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
                onSelect: { selectedEvent = $0 }
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
                    cellStyle: viewModel.monthCellStyle,
                    onSelectDay: { viewModel.selectDay($0) }
                )
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
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.holoGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.55), lineWidth: 1)
        )
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.sm)
    }

    private var weekListGridSwitch: some View {
        HStack {
            Picker("", selection: $viewModel.weekViewMode) {
                Image(systemName: "list.bullet").tag(WeekViewMode.list)
                Image(systemName: "square.grid.2x2").tag(WeekViewMode.grid)
            }
            .pickerStyle(.segmented)
            .frame(width: 100)
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.xs)
    }

    private var monthCellStyleSwitch: some View {
        HStack {
            Picker("", selection: $viewModel.monthCellStyle) {
                Text("热力").tag(MonthCellStyle.heatmap)
                Text("徽章").tag(MonthCellStyle.badge)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.xs)
    }

    private var todoDimensionBar: some View {
        HStack(spacing: HoloSpacing.xs) {
            Text("待办")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            ForEach(TodoTimeDimension.allCases, id: \.self) { dim in
                Button {
                    viewModel.setTodoDimension(dim)
                } label: {
                    Text(dim.displayName)
                        .font(.holoLabel)
                        .foregroundColor(viewModel.todoDimension == dim ? .white : .holoTextSecondary)
                        .padding(.horizontal, HoloSpacing.sm)
                        .padding(.vertical, 3)
                        .background(
                            viewModel.todoDimension == dim
                                ? Color.holoChart9
                                : Color.holoChart9.opacity(0.10)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.xs)
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
                Text("今天")
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
