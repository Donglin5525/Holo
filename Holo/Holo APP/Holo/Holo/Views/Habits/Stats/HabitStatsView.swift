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

    @ObservedObject var state: HabitStatsState
    @State private var isMonthPickerPresented = false
    @State private var isMonthSwitcherFloating = false

    /// 滚动坐标系：用于追踪月份切换条是否已滚出屏幕顶部
    private static let scrollSpace = "habitStatsScroll"
    /// 触发悬浮的滚动距离：月份条高约 36pt，滚过它后悬浮条接管
    private static let floatThreshold: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    monthSwitcher

                    if state.hasAnyHabits {
                        HabitStatsCockpitCard(
                            selectedMonth: state.selectedMonth,
                            completionRate: state.summaryStats.averageCompletionRate,
                            previousRate: state.previousRate,
                            monthlyTrend: state.monthlyTrend,
                            todayCompleted: state.summaryStats.todayCompleted,
                            totalHabits: state.summaryStats.totalHabits,
                            bestStreak: state.summaryStats.bestStreak,
                            isCurrentMonth: isCurrentMonth
                        )

                        if !state.displayItems.isEmpty {
                            HabitStatsInsightCard(
                                items: state.displayItems,
                                completionRate: state.summaryStats.averageCompletionRate,
                                previousRate: state.previousRate
                            )
                        }
                    }

                    if state.displayItems.isEmpty {
                        emptyState
                    } else {
                        cardsList
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.xl)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: HabitStatsScrollOffsetKey.self,
                            value: geo.frame(in: .named(Self.scrollSpace)).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: Self.scrollSpace)
            .overlay(alignment: .top) {
                if isMonthSwitcherFloating {
                    floatingMonthSwitcher
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .modifier(MonthSwitcherFloatTracker(
                threshold: Self.floatThreshold,
                isFloating: $isMonthSwitcherFloating
            ))
        }
        .background(Color.holoBackground)
        .navigationBarHidden(true)
        .sheet(isPresented: $isMonthPickerPresented) {
            monthPickerSheet
        }
    }

    // MARK: - 月份切换条

    private var monthSwitcher: some View {
        HabitStatsMonthSwitcher(
            month: state.selectedMonth,
            canGoNext: state.canGoToNextMonth,
            onPrevious: { Task { await state.goToPreviousMonth() } },
            onNext: { Task { await state.goToNextMonth() } },
            onTap: { isMonthPickerPresented = true }
        )
    }

    /// 滚动后悬浮在顶部的月份切换条（与原位样式一致，加浮层底色与投影）。
    /// identifier 会向下覆盖子元素：悬浮条内按钮以 floating id 暴露，与原位条区分，供 UITest 定位
    private var floatingMonthSwitcher: some View {
        monthSwitcher
            .accessibilityIdentifier("habit_stats_switcher_floating")
            .padding(.horizontal, HoloSpacing.md)
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, HoloSpacing.sm)
            .frame(maxWidth: .infinity)
            .background(Color.holoBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.holoTextPrimary.opacity(0.06))
                    .frame(height: 0.5)
            }
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
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

    // MARK: - 当前月判断

    /// 选中的月份是否为当前自然月（决定驾驶舱是否显示"今日"模块）
    private var isCurrentMonth: Bool {
        let calendar = Calendar.current
        return calendar.dateComponents([.year, .month], from: state.selectedMonth)
            == calendar.dateComponents([.year, .month], from: Date())
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

// MARK: - 滚动偏移

private struct HabitStatsScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 悬浮判定：滚过月份条高度后置 isFloating = true，回到顶部后复位。
/// iOS 18+ 用 onScrollGeometryChange（新 ScrollView 下 GeometryReader preference 滚动中不再更新）；
/// iOS 17 退回 GeometryReader + preference 的传统方案。
private struct MonthSwitcherFloatTracker: ViewModifier {
    /// 触发悬浮的滚动距离（正数，pt）
    let threshold: CGFloat
    @Binding var isFloating: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                setFloating(offset > threshold)
            }
        } else {
            content.onPreferenceChange(HabitStatsScrollOffsetKey.self) { minY in
                setFloating(minY < -threshold)
            }
        }
    }

    private func setFloating(_ newValue: Bool) {
        guard newValue != isFloating else { return }
        withAnimation(HoloAnimation.quick) {
            isFloating = newValue
        }
    }
}

// MARK: - Preview

#Preview("Stats View") {
    NavigationStack {
        HabitStatsView(onBack: {}, state: HabitStatsState())
    }
}
