//
//  DateRangeCalendar.swift
//  Holo
//
// 日期范围月历：范围内日期铺浅品牌色，首尾端点圆形高亮
// 替代原生 DatePicker(.graphical) —— 系统组件不支持高亮一段范围
//

import SwiftUI

/// 日期范围月历
///
/// - 范围内（start 与 end 之间）的日期铺浅品牌色背景，连成「范围条」
/// - 首尾端点（start / end）用实心圆形高亮 + 白字
/// - 支持左右切换月份
struct DateRangeCalendar: View {
    /// 当前选中的开始日期
    let startDate: Date
    /// 当前选中的结束日期
    let endDate: Date
    /// 点击某一天
    let onSelect: (Date) -> Void

    /// 当前显示的月份（用户可切换）
    @State private var displayMonth: Date

    init(start: Date, end: Date, onSelect: @escaping (Date) -> Void) {
        self.startDate = start
        self.endDate = end
        self.onSelect = onSelect
        // 默认显示开始日期所在月
        _displayMonth = State(initialValue: start.startOfMonth)
    }

    var body: some View {
        VStack(spacing: 12) {
            monthNav
            weekdayHeader
            grid
        }
    }

    // MARK: - 月份切换

    private var monthNav: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayMonth = displayMonth.addingMonths(-1)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(CalendarDateFormatter.monthTitle(for: displayMonth))
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayMonth = displayMonth.addingMonths(1)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 周标题

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(CalendarDateFormatter.weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 月历网格

    private var grid: some View {
        let days = CalendarGridGenerator.generateGrid(for: displayMonth)
        let rowCount = days.count / 7
        return VStack(spacing: 6) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        dayCell(days[row * 7 + col])
                    }
                }
            }
        }
    }

    // MARK: - 单日格子

    /// 范围横条高度（= 端点圆直径，保证两者等高融合成连续胶囊）
    private static let barHeight: CGFloat = 34

    private func dayCell(_ day: Date) -> some View {
        let inMonth = day.isSameMonth(as: displayMonth)
        // 归一化范围（兼容 end 早于 start）
        let lo = min(startDate, endDate)
        let hi = max(startDate, endDate)
        let isLo = day.isSameDay(as: lo)
        let isHi = day.isSameDay(as: hi)
        let isSingle = lo.isSameDay(as: hi)
        let isMiddle = !isLo && !isHi && day > lo && day < hi

        // 范围横条：中间格左右都画，左端点画右半，右端点画左半，单点不画条
        let leftHalf = inMonth && (isMiddle || (isHi && !isSingle))
        let rightHalf = inMonth && (isMiddle || (isLo && !isSingle))
        let isEndpoint = inMonth && (isLo || isHi)

        return Button {
            guard inMonth else { return }
            onSelect(day)
        } label: {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 15, weight: isEndpoint ? .bold : .regular))
                .foregroundColor(cellTextColor(inMonth: inMonth, isEndpoint: isEndpoint, isToday: day.isToday))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    ZStack {
                        // 范围横条（高度 = 端点圆直径，相邻格子连片）
                        rangeBarTrack(left: leftHalf, right: rightHalf)
                        // 端点圆：与横条等高，半圆正好衔接横条端点 → 融为一体
                        if isEndpoint {
                            Circle()
                                .fill(Color.holoPrimary)
                                .frame(width: Self.barHeight, height: Self.barHeight)
                        }
                    }
                )
                .opacity(inMonth ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .disabled(!inMonth)
    }

    /// 范围横条：左右各占半格，按需填浅品牌色，相邻格子的半条拼接成连续胶囊体
    private func rangeBarTrack(left: Bool, right: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(left ? Color.holoPrimary.opacity(0.15) : Color.clear)
            Rectangle().fill(right ? Color.holoPrimary.opacity(0.15) : Color.clear)
        }
        .frame(height: Self.barHeight)
    }

    private func cellTextColor(inMonth: Bool, isEndpoint: Bool, isToday: Bool) -> Color {
        if isEndpoint { return .white }
        if !inMonth { return .holoTextSecondary }
        if isToday { return .holoPrimary }
        return .holoTextPrimary
    }
}
