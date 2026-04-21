//
//  HabitStatsView.swift
//  Holo
//
//  习惯统计页面主视图
//  重构后：单页滚动仪表板（月份总览 + 周视图列表 + 单开展开月历）
//

import SwiftUI

struct HabitStatsView: View {
    let onBack: () -> Void

    @StateObject private var state = HabitStatsState()
    @State private var isMonthPickerPresented = false

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    HabitStatsMonthSwitcher(month: state.selectedMonth) {
                        isMonthPickerPresented = true
                    }

                    if state.hasAnyHabits {
                        HabitStatsSummaryCard(
                            totalHabits: state.summaryStats.totalHabits,
                            completionRate: state.summaryStats.averageCompletionRate,
                            bestStreak: state.summaryStats.totalStreak,
                            statusText: summaryStatusText
                        )
                    }

                    if state.displayItems.isEmpty {
                        emptyState
                    } else {
                        cardsList
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.xl)
            }
        }
        .background(Color.holoBackground)
        .navigationBarHidden(true)
        .sheet(isPresented: $isMonthPickerPresented) {
            monthPickerSheet
        }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
            state.refresh()
        }
    }

    // MARK: - 导航栏

    private var navigationBar: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            Text("统计")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 卡片列表

    private var cardsList: some View {
        LazyVStack(spacing: HoloSpacing.sm) {
            ForEach(state.displayItems) { item in
                HabitStatsExpandableCardView(
                    item: item,
                    isExpanded: state.expandedHabitId == item.habitId
                ) {
                    state.toggleExpansion(for: item.habitId)
                }
            }
        }
    }

    // MARK: - 空状态

    @ViewBuilder
    private var emptyState: some View {
        if state.hasAnyHabits && state.displayItems.isEmpty {
            ContentUnavailableView(
                "当前统计页没有已启用的习惯",
                systemImage: "slider.horizontal.3",
                description: Text("去设置页选择要展示在统计页的习惯。")
            )
        } else if !state.hasAnyHabits {
            ContentUnavailableView(
                "还没有习惯",
                systemImage: "checkmark.circle",
                description: Text("先去习惯页创建你的第一个习惯。")
            )
        }
    }

    // MARK: - 总览文案

    private var summaryStatusText: String {
        let rate = Int(state.summaryStats.averageCompletionRate.rounded())
        if rate >= 80 {
            return "\(rate)% 优秀"
        } else if rate >= 50 {
            return "\(rate)% 保持节奏"
        } else if rate > 0 {
            return "\(rate)% 继续加油"
        } else {
            return "暂无数据"
        }
    }

    // MARK: - 月份选择器

    private var monthPickerSheet: some View {
        let year = Calendar.current.component(.year, from: state.selectedMonth)
        let month = Calendar.current.component(.month, from: state.selectedMonth)

        return MonthYearPickerView(
            currentYear: year,
            currentMonth: month,
            onConfirm: { selectedYear, selectedMonth in
                let nextMonth = Calendar.current.date(
                    from: DateComponents(year: selectedYear, month: selectedMonth, day: 1)
                ) ?? state.selectedMonth
                Task { await state.selectMonth(nextMonth) }
                isMonthPickerPresented = false
            },
            onCancel: {
                isMonthPickerPresented = false
            }
        )
        .presentationDetents([.height(320)])
    }
}

// MARK: - Preview

#Preview("Stats View") {
    NavigationStack {
        HabitStatsView(onBack: {})
    }
}
