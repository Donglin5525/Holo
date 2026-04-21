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
        RoundedRectangle(cornerRadius: 8)
            .fill(day.isInCurrentMonth ? Color.holoBackground : Color.holoBackground.opacity(0.4))
            .overlay(alignment: .topLeading) {
                if let number = day.dayNumber {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(day.isInCurrentMonth ? .holoTextPrimary : .holoTextSecondary)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if day.hasRecord {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 6, height: 6)
                        .padding(4)
                }
            }
            .aspectRatio(1, contentMode: .fit)
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
            hasRecord: day % 3 == 0
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
