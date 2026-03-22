//
//  HabitStatsHabitsTab.swift
//  Holo
//
//  习惯统计 - 习惯 Tab
//

import SwiftUI
import Charts

// MARK: - HabitStatsHabitsTab
struct HabitStatsHabitsTab: View {
    @ObservedObject var state: HabitStatsState

    var body: some View {
        VStack(spacing: 0) {
            // 类型筛选器
            HabitTypeFilterSelector(
                selectedFilter: $state.typeFilter
            ) { filter in
                state.setTypeFilter(filter)
            }

            // 习惯列表
            if state.filteredHabitStatsItems.isEmpty {
                emptyView
            } else {
                habitsList
            }
        }
    }

    // MARK: - 习惯列表

    private var habitsList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: HoloSpacing.sm) {
                ForEach(state.filteredHabitStatsItems) { item in
                    HabitStatsCardView(
                        item: item,
                        isExpanded: state.expandedHabitId == item.habitId
                    ) {
                        state.toggleHabitExpansion(item.habitId)
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
        }
        .refreshable {
            Task {
                await state.loadData()
            }
        }
    }

    // MARK: - 空状态

    private var emptyView: some View {
        VStack(spacing: HoloSpacing.md) {
            Spacer()

            Image(systemName: "checkmark.circle.trianglebadge.exclamationmark")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无习惯数据")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text("创建习惯后即可查看统计数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

