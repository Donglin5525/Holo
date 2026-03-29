//
//  HabitTimeRangeSelector.swift
//  Holo
//
//  习惯统计时间范围选择器组件
//

import SwiftUI

// MARK: - HabitTimeRangeSelector

/// 习惯统计时间范围选择器
struct HabitTimeRangeSelector: View {
    @Binding var selectedRange: HabitStatsDateRange
    var onRangeChanged: ((HabitStatsDateRange) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HabitStatsDateRange.allCases) { range in
                    HoloFilterChip(
                        title: range.displayName,
                        isSelected: selectedRange == range
                    ) {
                        selectedRange = range
                        onRangeChanged?(range)
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)
        }
    }
}

// MARK: - HabitTypeFilterSelector

/// 习惯类型筛选选择器
struct HabitTypeFilterSelector: View {
    @Binding var selectedFilter: HabitTypeFilter
    var onFilterChanged: ((HabitTypeFilter) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HoloSpacing.sm) {
                ForEach(HabitTypeFilter.allCases) { filter in
                    HoloFilterChip(
                        title: filter.displayName,
                        icon: filter.icon,
                        isSelected: selectedFilter == filter
                    ) {
                        selectedFilter = filter
                        onFilterChanged?(filter)
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.md)
        }
    }
}

// MARK: - Preview

#Preview("Time Range Selector") {
    VStack(spacing: 20) {
        HabitTimeRangeSelector(selectedRange: .constant(.month))
        HabitTypeFilterSelector(selectedFilter: .constant(.all))
    }
    .padding()
    .background(Color.holoBackground)
}
