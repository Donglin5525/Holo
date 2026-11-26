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
    /// 嵌入式顶栏紧凑模式（2026-11-26 瘦身顶栏：直接居中于导航栏，去掉外层横铺 Spacer）
    var isCompactHeader: Bool = false
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
        if isCompactHeader {
            pillControl
        } else {
            HStack(spacing: HoloSpacing.sm) {
                Spacer()
                pillControl
                Spacer()
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.xs)
        }
    }

    private var pillControl: some View {
        let canGoNext = state.canNavigateToNext
        return HStack(spacing: 0) {
            // 上一周期（历史不设限）
            Button {
                state.navigate(.previous)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 32, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "上一周期")))

            // 日期范围：点击内联展开时间筛选条
            Button {
                onCustomTap()
            } label: {
                HStack(spacing: 4) {
                    Text(dateRangeText)
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(.holoToolText)
                        .lineLimit(1)

                    if let suffix = yearBasisSuffix {
                        Text(suffix)
                            .font(.system(size: 10.5))
                            .foregroundColor(.holoToolTextSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 下一周期（当前/未来周期禁用：窗口末端已越过现在）
            Button {
                state.navigate(.next)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary.opacity(canGoNext ? 1 : 0.3))
                    .frame(width: 32, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNext)
            .accessibilityLabel(Text(String(localized: "下一周期")))
        }
        .background(Color.holoToolInset)
        .clipShape(Capsule())
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
