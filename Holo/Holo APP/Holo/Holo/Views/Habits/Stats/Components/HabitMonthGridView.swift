//
//  HabitMonthGridView.swift
//  Holo
//
//  统计页展开态月视图（完整月历矩阵）
//

import SwiftUI

struct HabitMonthGridView: View {
    let month: HabitStatsMonthSection
    let accentColor: Color

    var body: some View {
        VStack(spacing: 6) {
            weekdayHeader
            ForEach(Array(month.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row) { day in
                        dayCell(day)
                    }
                }
            }
        }
    }

    private var weekdayHeader: some View {
        HStack {
            ForEach(month.weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ day: HabitStatsDayCell) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(dayCellBackground(day))
            .overlay {
                // 今天未打卡：描边环提示
                if day.isToday && !day.hasRecord && !day.isOverLimit {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(accentColor, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topLeading) {
                if let number = day.dayNumber {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(dayNumberColor(day))
                        .padding(4)
                }
            }
            .aspectRatio(1, contentMode: .fit)
    }

    private func dayCellBackground(_ day: HabitStatsDayCell) -> Color {
        if day.isOverLimit {
            return Color.red.opacity(0.12)
        }
        if day.hasRecord {
            return accentColor
        }
        if day.isToday {
            return accentColor.opacity(0.12)
        }
        return day.isInCurrentMonth ? Color.holoBackground : Color.holoBackground.opacity(0.4)
    }

    private func dayNumberColor(_ day: HabitStatsDayCell) -> Color {
        if day.isOverLimit {
            return .red
        }
        if day.hasRecord {
            return .white
        }
        if day.isToday {
            return accentColor
        }
        return day.isInCurrentMonth ? .holoTextPrimary : .holoTextSecondary
    }
}

#Preview {
    let calendar = Calendar.current
    let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!

    let symbols = calendar.shortWeekdaySymbols
    let sampleRow: [HabitStatsDayCell] = (1..<8).map { day in
        HabitStatsDayCell(
            date: calendar.date(byAdding: .day, value: day, to: monthStart)!,
            dayNumber: day,
            isInCurrentMonth: true,
            isToday: day == 15,
            hasRecord: day % 3 == 0,
            isOverLimit: false
        )
    }

    HabitMonthGridView(
        month: HabitStatsMonthSection(
            monthStart: monthStart,
            weekdaySymbols: symbols,
            rows: [sampleRow, sampleRow]
        ),
        accentColor: .holoPrimary
    )
    .padding()
    .background(Color.holoCardBackground)
}
