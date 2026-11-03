//
//  TaskCalendarMonthGrid.swift
//  Holo
//
//  月览 7 列日期格与日程周日期条（多视图方案 §5.1）：周一为始、每月补齐自然周
//  （4/5/6 行，不补固定 42 格）、邻月日期浅色可点；今天橙色细圈、选中日橙底反白、
//  今天同时选中只保留实底；数字 = |U(D)|（去重）。
//

import SwiftUI

// MARK: - 网格日期模型（纯计算，便于测试与复用）

enum TaskCalendarGridModel {

    /// 某月网格的全部日期（首周周一起补齐到整周；末行到本月最后一个周日为止，
    /// 4/5/6 行由实际月份决定，不固定 42 格）
    static func monthGridDays(anchor: Date, calendar: Calendar) -> [Date] {
        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: anchor))!
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        // 周一为一周之始：Monday=2 → 前补 (weekday + 5) % 7 天
        let leading = (weekday + 5) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: firstOfMonth)!
        let firstOfNextMonth = calendar.date(byAdding: .month, value: 1, to: firstOfMonth)!
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: gridStart)
        // 输出到「进入下月且对齐周一」为止
        while cursor < firstOfNextMonth || calendar.component(.weekday, from: cursor) != 2 {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return days
    }

    /// 选中日所在周的 7 天（周一起）
    static func weekDays(around anchor: Date, calendar: Calendar) -> [Date] {
        let weekday = calendar.component(.weekday, from: anchor)
        let leading = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -leading, to: anchor)!
        return (0..<7).map {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: $0, to: monday)!)
        }
    }
}

// MARK: - 月览网格

struct TaskCalendarMonthGrid: View {

    let monthAnchor: Date
    let selectedDay: Date
    let today: Date
    let calendar: Calendar
    /// 日期 → |U(D)|（调用方预计算索引）
    let dayCounts: [Date: Int]
    let onSelectDay: (Date) -> Void

    private var gridDays: [Date] {
        TaskCalendarGridModel.monthGridDays(anchor: monthAnchor, calendar: calendar)
    }

    var body: some View {
        VStack(spacing: 4) {
            weekdayLabels
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(gridDays, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
    }

    private var weekdayLabels: some View {
        HStack(spacing: 0) {
            ForEach([String(localized: "一"), String(localized: "二"), String(localized: "三"),
                     String(localized: "四"), String(localized: "五"), String(localized: "六"),
                     String(localized: "日")], id: \.self) { label in
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let count = dayCounts[day] ?? 0
        let inMonth = calendar.dateComponents([.month], from: monthAnchor, to: day).month == 0

        return Button {
            onSelectDay(day)
        } label: {
            VStack(spacing: 3) {
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundColor(dayNumberColor(isSelected: isSelected, inMonth: inMonth))
                    .frame(width: 27, height: 27)
                    .background(
                        Circle().fill(isSelected ? Color.holoPrimary : Color.clear)
                    )
                    .overlay(
                        // 今天橙圈；今天同时选中只保留实底（§5.1-3）
                        Circle().strokeBorder(isToday && !isSelected ? Color.holoPrimary : Color.clear, lineWidth: 1)
                    )
                Text(verbatim: count > 0 ? String(format: "%d项", count) : " ")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundColor(inMonth ? Color.holoToolTextSecondary : Color.holoToolTextSecondary.opacity(0.5))
                    .frame(height: 11)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                // 深色下 4% 白洗底不可见：选中日用嵌套卡底（两模式均有底、浅色观感不变）
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.holoNestedCardBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText(day, count: count, isSelected: isSelected, isToday: isToday))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func dayNumberColor(isSelected: Bool, inMonth: Bool) -> Color {
        if isSelected { return .white }
        return inMonth ? .holoTextPrimary : .holoTextSecondary.opacity(0.55)
    }

    private func accessibilityText(_ day: Date, count: Int, isSelected: Bool, isToday: Bool) -> String {
        var parts = [String(format: "%d月%d日", calendar.component(.month, from: day), calendar.component(.day, from: day))]
        if count > 0 { parts.append(String(format: "%d项任务", count)) }
        if isToday { parts.append(String(localized: "今天")) }
        if isSelected { parts.append(String(localized: "已选中")) }
        return parts.joined(separator: "，")
    }
}

// MARK: - 周日期条（日程模式上方）

struct TaskCalendarWeekStrip: View {

    let selectedDay: Date
    let today: Date
    let calendar: Calendar
    let dayCounts: [Date: Int]
    let onSelectDay: (Date) -> Void

    private var weekDays: [Date] {
        TaskCalendarGridModel.weekDays(around: selectedDay, calendar: calendar)
    }

    private var weekdayNames: [String] {
        let symbols = calendar.veryShortWeekdaySymbols // 周日起
        // 周一起
        return [symbols[1], symbols[2], symbols[3], symbols[4], symbols[5], symbols[6], symbols[0]]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekDays.enumerated()), id: \.element) { index, day in
                dayCell(day, weekday: weekdayNames[index])
            }
        }
    }

    private func dayCell(_ day: Date, weekday: String) -> some View {
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let count = dayCounts[day] ?? 0
        return Button {
            onSelectDay(day)
        } label: {
            VStack(spacing: 3) {
                Text(weekday)
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundColor(isSelected ? .white : .holoTextPrimary)
                    .frame(width: 27, height: 27)
                    .background(Circle().fill(isSelected ? Color.holoPrimary : Color.clear))
                    .overlay(
                        Circle().strokeBorder(isToday && !isSelected ? Color.holoPrimary : Color.clear, lineWidth: 1)
                    )
                Text(verbatim: count > 0 ? String(format: "%d项", count) : " ")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(height: 11)
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: "%d月%d日，%d项任务", calendar.component(.month, from: day), calendar.component(.day, from: day), count))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
