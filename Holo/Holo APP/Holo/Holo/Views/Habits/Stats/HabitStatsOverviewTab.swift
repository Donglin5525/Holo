//
//  HabitStatsOverviewTab.swift
//  Holo
//
//  习惯统计 - 总览 Tab
//

import SwiftUI
import Charts

// MARK: - HabitStatsOverviewTab
struct HabitStatsOverviewTab: View {
    @ObservedObject var state: HabitStatsState

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                // 总览卡片
                HabitOverviewCard(stats: state.overviewStats)

                // 完成率趋势图
                HabitTrendChartView(
                    data: state.completionTrend,
                    selectedDate: nil
                ) { _ in }

                // 习惯排行榜
                HabitRankingCard(ranking: state.habitRanking)
            }
            .padding(.horizontal, HoloSpacing.md)
        }
        .refreshable {
            Task {
                await state.loadData()
            }
        }
    }
}

// MARK: - Preview
#Preview("Overview Tab") {
    HabitStatsOverviewTab(state: HabitStatsState())
}
