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
                    Text(range.displayName)
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
                // 自定义时间范围入口也保持内容宽度，与共享筛选胶囊一致
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
        } else {
            HoloFilterChip(
                title: range.displayName,
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
        // 最小信息原则：年档只标年份、季档只标第几季度（完整起止收在弹层里查），
        // 避免「2026年1月25日 - 2027年1月24日」长文案把胶囊撑到换行
        return TimeRange.pillLabel(timeRange: state.timeRange, start: start, end: end)
    }

    /// 年档在区间尾部附口径小字（记账起始日=1 时两口径等价，不显示）
    private var yearBasisSuffix: String? {
        guard state.timeRange == .year, state.yearBasisSwitchAvailable else { return nil }
        return "· \(state.yearBasis.displayName)"
    }

    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            Spacer()
            // 上一时间段按钮（历史不设限）
            Button {
                state.navigate(.previous)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoCardBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // 日期范围标签：点击直接进入起止日期选择（融合原「自定义」入口；年档口径选项也收在这里）
            Button {
                onCustomTap()
            } label: {
                HStack(spacing: 4) {
                    Text(dateRangeText)
                        .font(.holoCaption)
                        .lineLimit(1)

                    if let suffix = yearBasisSuffix {
                        Text(suffix)
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                    }

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

            // 下一时间段按钮（当前/未来周期禁用：窗口末端已越过现在）
            let canGoNext = state.canNavigateToNext
            Button {
                state.navigate(.next)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoCardBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(canGoNext ? 1 : 0.3)
            .disabled(!canGoNext)

            Spacer()
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.xs)
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
