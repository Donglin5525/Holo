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
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns),
                spacing: 4
            ) {
                ForEach(sortedDates, id: \.self) { date in
                    calendarCell(for: date)
                }
            }

            // 图例
            legend
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

        RoundedRectangle(cornerRadius: 3)
            .fill(cellColor(isCompleted: isCompleted, isToday: isToday))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(
                        cellBorderColor(isCompleted: isCompleted, isToday: isToday),
                        lineWidth: isToday && !isCompleted ? 1 : 0.5
                    )
            }
            .overlay {
                Text("\(day)")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(numberColor(isCompleted: isCompleted, isToday: isToday))
            }
    }

    // MARK: - 单元格颜色

    private func cellColor(isCompleted: Bool, isToday: Bool) -> Color {
        if isCompleted {
            return .holoSuccess
        } else if isToday {
            return .holoPrimary.opacity(0.15)
        } else {
            return .holoBackground
        }
    }

    private func cellBorderColor(isCompleted: Bool, isToday: Bool) -> Color {
        if isCompleted {
            return .clear
        } else if isToday {
            return .holoPrimary
        } else {
            return .holoDivider.opacity(0.4)
        }
    }

    private func numberColor(isCompleted: Bool, isToday: Bool) -> Color {
        if isCompleted {
            return .white
        } else if isToday {
            return .holoPrimary
        } else {
            return .holoTextSecondary.opacity(0.5)
        }
    }

    // MARK: - 图例

    private var legend: some View {
        HStack(spacing: HoloSpacing.md) {
            Spacer()

            legendItem(color: .holoSuccess, label: "已完成")
            legendItem(color: .holoBackground, border: .holoDivider.opacity(0.4), label: "未完成")
            legendItem(color: .holoPrimary.opacity(0.15), border: .holoPrimary, label: "今天")
        }
    }

    private func legendItem(color: Color, border: Color = .clear, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(border, lineWidth: 0.5)
                }

            Text(label)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }
}
