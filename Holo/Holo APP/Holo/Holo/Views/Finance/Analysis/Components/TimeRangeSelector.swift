//
//  TimeRangeSelector.swift
//  Holo
//
//  时间范围选择器组件
//  复用 HoloFilterChip 样式
//

import SwiftUI

// MARK: - TimeRangeSelector

/// 时间范围选择器
struct TimeRangeSelector: View {
    @ObservedObject var state: FinanceAnalysisState
    var onCustomTap: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TimeRange.allCases) { range in
                    timeRangeChip(range)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)
        }
    }

    @ViewBuilder
    private func timeRangeChip(_ range: TimeRange) -> some View {
        if range == .custom {
            Button {
                onCustomTap()
            } label: {
                HStack(spacing: 4) {
                    if let icon = range.icon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text(range.rawValue)
                        .font(.holoCaption)
                }
                .foregroundColor(state.timeRange == .custom ? .white : .holoTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(state.timeRange == .custom ? Color.holoPrimary : Color.holoCardBackground)
                )
                .overlay(
                    Capsule()
                        .stroke(state.timeRange == .custom ? Color.clear : Color.holoDivider, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        } else {
            HoloFilterChip(
                title: range.rawValue,
                icon: range.icon,
                isSelected: state.timeRange == range
            ) {
                state.setTimeRange(range)
            }
        }
    }
}

// MARK: - 时间范围显示标签

/// 时间范围显示标签（显示当前选中的具体日期范围）
struct TimeRangeLabel: View {
    @ObservedObject var state: FinanceAnalysisState

    private var dateRangeText: String {
        let (start, end) = state.currentDateRange
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日"
        let startStr = df.string(from: start)
        let endStr = df.string(from: end.addingDays(-1)) // end 是开区间，显示前一天
        return "\(startStr) - \(endStr)"
    }

    var body: some View {
        Text(dateRangeText)
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary)
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.xs)
            .background(Color.holoCardBackground)
            .clipShape(Capsule())
    }
}

// MARK: - Preview

#Preview("Time Range Selector") {
    VStack {
        TimeRangeSelector(state: FinanceAnalysisState()) {}
        Spacer()
    }
    .background(Color.holoBackground)
}
