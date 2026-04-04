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
    @State private var showDatePicker: Bool = false

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

            // 日期范围标签
            Button {
                showDatePicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(dateRangeText)
                        .font(.holoCaption)

                    Image(systemName: "chevron.down")
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

            // 自定义按钮
            Button {
                onCustomTap()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                    Text("自定义")
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
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.xs)
        .sheet(isPresented: $showDatePicker) {
            DrillDownDatePicker(state: state)
        }
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

// MARK: - Drill Down Date Picker

/// 下钻日期选择器
struct DrillDownDatePicker: View {
    @ObservedObject var state: FinanceAnalysisState
    @Environment(\.dismiss) var dismiss
    @State private var selectedDate: Date = Date()

    var body: some View {
        NavigationView {
            VStack(spacing: HoloSpacing.lg) {
                // 提示信息
                Text(drillDownHint)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal)

                // 日期选择器
                DatePicker(
                    "选择日期",
                    selection: $selectedDate,
                    in: dateRange,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .padding()

                Spacer()

                // 确认按钮
                Button {
                    applyDrillDown()
                    dismiss()
                } label: {
                    Text("查看该\(timeUnit)数据")
                        .font(.holoBody)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HoloSpacing.md)
                        .background(Color.holoPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .padding()
            }
            .background(Color.holoBackground)
            .navigationTitle("选择\(timeUnit)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("确认") {
                        applyDrillDown()
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    /// 时间单位
    private var timeUnit: String {
        switch state.originalTimeRange {
        case .week: return "周"
        case .month: return "月"
        case .quarter: return "季度"
        case .year: return "年"
        default: return "日期"
        }
    }

    /// 下钻提示
    private var drillDownHint: String {
        switch state.originalTimeRange {
        case .week:
            return "选择某一天，查看该周的数据"
        case .month:
            return "选择某一天，查看该月的数据"
        case .quarter:
            return "选择某一天，查看该季度的数据"
        case .year:
            return "选择某一天，查看该年的数据"
        default:
            return ""
        }
    }

    /// 可选日期范围
    private var dateRange: ClosedRange<Date> {
        let now = Date()
        let calendar = Calendar.current

        // 允许选择过去一年到未来的日期
        guard let start = calendar.date(byAdding: .year, value: -1, to: now),
              let end = calendar.date(byAdding: .year, value: 1, to: now) else {
            return now...now
        }
        return start...end
    }

    /// 应用下钻
    private func applyDrillDown() {
        let calendar = Calendar.current
        let newRange: (start: Date, end: Date)

        // 使用 originalTimeRange 确定时间单位，因为 timeRange 可能在导航后变为 .custom
        let effectiveRange = state.originalTimeRange

        switch effectiveRange {
        case .day:
            let dayStart = calendar.startOfDay(for: selectedDate)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
            newRange = (dayStart, dayEnd)

        case .week:
            let weekStart = selectedDate.startOfWeek
            guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return }
            newRange = (weekStart, weekEnd)

        case .month:
            let monthStart = selectedDate.startOfMonth
            guard let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return }
            newRange = (monthStart, monthEnd)

        case .quarter:
            let month = calendar.component(.month, from: selectedDate)
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1
            var components = calendar.dateComponents([.year], from: selectedDate)
            components.month = quarterStartMonth
            components.day = 1
            guard let quarterStart = calendar.date(from: components),
                  let quarterEnd = calendar.date(byAdding: .month, value: 3, to: quarterStart) else { return }
            newRange = (quarterStart, quarterEnd)

        case .year:
            var components = calendar.dateComponents([.year], from: selectedDate)
            components.month = 1
            components.day = 1
            guard let yearStart = calendar.date(from: components),
                  let yearEnd = calendar.date(byAdding: .year, value: 1, to: yearStart) else { return }
            newRange = (yearStart, yearEnd)

        case .custom:
            return
        }

        // 使用 navigateToRange 而不是 setCustomDateRange，保持 originalTimeRange 不变
        state.navigateToRange(start: newRange.start, end: newRange.end)
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
