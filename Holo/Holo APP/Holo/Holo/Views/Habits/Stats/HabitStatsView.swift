//
//  HabitStatsView.swift
//  Holo
//
//  习惯统计页面主视图
//  使用 Tab 架构：总览 / 习惯
//

import SwiftUI

// MARK: - HabitStatsView

/// 习惯统计页面
struct HabitStatsView: View {
    let onBack: () -> Void

    @StateObject private var state = HabitStatsState()

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            navigationBar

            // Tab 选择器（总览/习惯）
            tabBar

            // 时间范围选择器
            timeRangeSelector

            // 内容 Tab 栏
            tabContent
        }
        .background(Color.holoBackground)
        .navigationBarHidden(true)
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

    // MARK: - Tab 选择器

    private var tabBar: some View {
        Picker("Tab", selection: $state.selectedTab) {
            Text("总览").tag(0)
            Text("习惯").tag(1)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
    }

    // MARK: - 时间范围选择器

    private var timeRangeSelector: some View {
        HabitTimeRangeSelector(
            selectedRange: $state.selectedDateRange
        ) { range in
            state.setDateRange(range)
        }
        .padding(.horizontal, HoloSpacing.md)
    }

    // MARK: - Tab 内容

    @ViewBuilder
    private var tabContent: some View {
        if state.isLoading {
            loadingView
        } else if state.selectedTab == 0 {
            HabitStatsOverviewTab(state: state)
        } else {
            HabitStatsHabitsTab(state: state)
        }
    }

    // MARK: - 加载视图

    private var loadingView: some View {
        VStack(spacing: HoloSpacing.md) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.holoPrimary)

            Text("加载中...")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview("Stats View") {
    NavigationStack {
        HabitStatsView(onBack: {})
    }
}
