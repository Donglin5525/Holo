//
//  CalendarRootView.swift
//  Holo
//
//  日历视图根容器（P1A：仅周历列表；P1B 加月历 Tab）
//

import SwiftUI

struct CalendarRootView: View {

    @StateObject private var viewModel = CalendarViewModel()
    @State private var selectedEvent: CalendarEvent?

    var body: some View {
        VStack(spacing: 0) {
            weekNavBar
            if viewModel.hasFailure {
                failureBanner
            }
            WeeklyListView(
                eventsByDay: viewModel.eventsByDay,
                isLoading: viewModel.isLoading,
                onSelect: { selectedEvent = $0 }
            )
        }
        .background(Color.holoBackground)
        .task {
            if viewModel.eventsByDay.isEmpty {
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

    // MARK: - 周导航 ◀ 标题 ▶ 今天

    private var weekNavBar: some View {
        HStack(spacing: HoloSpacing.sm) {
            chevronButton(systemName: "chevron.left", action: viewModel.goToPrevWeek)

            Text(weekTitle)
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

    private var weekTitle: String {
        let range = viewModel.weekRange
        // range.end 是下周一首日 00:00（半开），显示前一天即本周日
        let lastDay = range.end.addingTimeInterval(-1)
        return "\(Self.rangeFormatter.string(from: range.start)) – \(Self.rangeFormatter.string(from: lastDay))"
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

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()
}
