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
                ForEach(TimeRange.allCases.filter { $0 != .day }) { range in
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

/// 时间范围显示标签（显示当前选中的具体日期范围，可点击下钻，支持左右切换，含自定义按钮）
struct TimeRangeLabel: View {
    @ObservedObject var state: FinanceAnalysisState
    var onCustomTap: () -> Void

    private var dateRangeText: String {
        let (start, end) = state.currentDateRange
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日"
        let startStr = df.string(from: start)
        let endStr = df.string(from: end.addingDays(-1)) // end 是开区间，显示前一天
        return "\(startStr) - \(endStr)"
    }

    /// 是否可以切换（始终可以切换）
    private var canNavigate: Bool {
        true
    }

    /// 获取当前时间范围类型（用于导航计算）
    private var effectiveTimeRange: TimeRange {
        state.originalTimeRange
    }

    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            Spacer()
            // 上一时间段按钮
            if canNavigate {
                Button {
                    navigateToPrevious()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.holoCardBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // 日期范围标签：点击直接进入起止日期选择（融合原「自定义」入口）
            Button {
                onCustomTap()
            } label: {
                HStack(spacing: 4) {
                    Text(dateRangeText)
                        .font(.holoCaption)

                    Image(systemName: "calendar")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.xs)
                .background(Color.holoCardBackground)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // 下一时间段按钮
            if canNavigate {
                Button {
                    navigateToNext()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.holoCardBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.xs)
    }

    // MARK: - 导航方法

    private func navigateToPrevious() {
        let calendar = Calendar.current
        let (currentStart, _) = state.currentDateRange
        var newStart: Date?

        switch effectiveTimeRange {
        case .day:
            newStart = calendar.date(byAdding: .day, value: -1, to: currentStart)
        case .week:
            newStart = calendar.date(byAdding: .weekOfYear, value: -1, to: currentStart)
        case .month:
            newStart = calendar.date(byAdding: .month, value: -1, to: currentStart)
        case .quarter:
            newStart = calendar.date(byAdding: .month, value: -3, to: currentStart)
        case .year:
            newStart = calendar.date(byAdding: .year, value: -1, to: currentStart)
        case .custom:
            return
        }

        if let start = newStart {
            let end = calculateEnd(for: start, timeRange: effectiveTimeRange)
            state.navigateToRange(start: start, end: end)
        }
    }

    private func navigateToNext() {
        let calendar = Calendar.current
        let (currentStart, _) = state.currentDateRange
        var newStart: Date?

        switch effectiveTimeRange {
        case .day:
            newStart = calendar.date(byAdding: .day, value: 1, to: currentStart)
        case .week:
            newStart = calendar.date(byAdding: .weekOfYear, value: 1, to: currentStart)
        case .month:
            newStart = calendar.date(byAdding: .month, value: 1, to: currentStart)
        case .quarter:
            newStart = calendar.date(byAdding: .month, value: 3, to: currentStart)
        case .year:
            newStart = calendar.date(byAdding: .year, value: 1, to: currentStart)
        case .custom:
            return
        }

        if let start = newStart {
            let end = calculateEnd(for: start, timeRange: effectiveTimeRange)
            state.navigateToRange(start: start, end: end)
        }
    }

    private func calculateEnd(for start: Date, timeRange: TimeRange) -> Date {
        let calendar = Calendar.current
        switch timeRange {
        case .day:
            return calendar.date(byAdding: .day, value: 1, to: start) ?? start
        case .week:
            return calendar.date(byAdding: .day, value: 7, to: start) ?? start
        case .month:
            return calendar.date(byAdding: .month, value: 1, to: start) ?? start
        case .quarter:
            return calendar.date(byAdding: .month, value: 3, to: start) ?? start
        case .year:
            return calendar.date(byAdding: .year, value: 1, to: start) ?? start
        case .custom:
            return start
        }
    }
}

// MARK: - Preview

#Preview("Time Range Selector") {
    VStack {
        TimeRangeLabel(state: FinanceAnalysisState()) {}
        Spacer()
    }
    .background(Color.holoBackground)
}
