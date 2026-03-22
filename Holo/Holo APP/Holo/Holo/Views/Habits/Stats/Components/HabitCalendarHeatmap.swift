//
//  HabitCalendarHeatmap.swift
//  Holo
//
//  打卡习惯日历热力图组件
//  显示每日完成状态
//

import SwiftUI

// MARK: - HabitCalendarHeatmap

/// 打卡习惯日历热力图
struct HabitCalendarHeatmap: View {
    let calendarData: [Date: Bool]
    let columns: Int

    init(calendarData: [Date: Bool], columns: Int = 7) {
        self.calendarData = calendarData
        self.columns = columns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题
            Text("打卡日历")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            // 日历网格
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: columns)) {
                ForEach(sortedDates, id: \.self) { date in
                    calendarCell(for: date)
                }
            }
            .frame(height: 120)
        }
    }

    // MARK: - 排序后的日期

    private var sortedDates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 生成最近28天的日期
        return (0..<28).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
        }
    }

    // MARK: - 日历单元格

    @ViewBuilder
    private func calendarCell(for date: Date) -> some View {
        let isCompleted = calendarData[Calendar.current.startOfDay(for: date)] ?? false
        let isToday = Calendar.current.isDateInToday(date)
        let day = Calendar.current.component(.day, from: date)

        RoundedRectangle(cornerRadius: 4)
            .fill(cellColor(isCompleted: isCompleted, isToday: isToday))
            .frame(height: 16)
            .overlay(
                Text("\(day)")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(isCompleted ? .white : .holoTextSecondary.opacity(0.5))
            )
    }

    // MARK: - 单元格颜色

    private func cellColor(isCompleted: Bool, isToday: Bool) -> Color {
        if isCompleted {
            return .holoSuccess
        } else if isToday {
            return .holoPrimary.opacity(0.3)
        } else {
            return .holoBackground
        }
    }
}
