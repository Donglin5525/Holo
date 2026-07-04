//
//  CalendarRootView.swift
//  Holo
//
//  日历视图根容器：周历 / 月历 切换 + 顶部导航 + 失败态横条
//

import SwiftUI

struct CalendarRootView: View {

    @StateObject private var viewModel = CalendarViewModel()
    @State private var selectedEvent: CalendarEvent?

    var body: some View {
        VStack(spacing: 0) {
            modeSwitch
            navBar
            if viewModel.hasFailure {
                failureBanner
            }
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

    // MARK: - 内容（周历 / 月历）

    @ViewBuilder
    private var content: some View {
        switch viewModel.mode {
        case .weekly:
            WeeklyListView(
                eventsByDay: viewModel.eventsByDay,
                isLoading: viewModel.isLoading,
                onSelect: { selectedEvent = $0 }
            )
        case .monthly:
            monthlyContent
        }
    }

    private var monthlyContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.md) {
                // 健康保底入口（月历左上）
                HStack {
                    HealthStatusChip()
                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)

                MonthlyCalendarView(
                    monthAnchor: viewModel.anchor,
                    eventsByDay: viewModel.monthEventsByDay,
                    selectedDay: viewModel.selectedDay,
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

    // MARK: - 周历 / 月历 切换

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

    // MARK: - 导航 ◀ 标题 ▶ 今天

    private var navBar: some View {
        HStack(spacing: HoloSpacing.sm) {
            chevronButton(systemName: "chevron.left", action: viewModel.goToPrevWeek)
            Text(viewModel.title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity)
            chevronButton(systemName: "chevron.right", action: viewModel.goToNextWeek)
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

    // MARK: - 失败态横条（不静默丢模块）

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

private extension CalendarViewModel {
    // 导航按钮复用 goToPrev/goToNext（mode 无关命名兼容）
    func goToPrevWeek() { goToPrev() }
    func goToNextWeek() { goToNext() }
}
