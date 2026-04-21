//
//  HabitWeekStripView.swift
//  Holo
//
//  统计页折叠态周视图（一行 7 格）
//

import SwiftUI

struct HabitWeekStripView: View {
    let week: HabitStatsWeekSlice
    let accentColor: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(week.days) { day in
                RoundedRectangle(cornerRadius: 8)
                    .fill(dayBackgroundColor(day))
                    .overlay(alignment: .topLeading) {
                        if let number = day.dayNumber {
                            Text("\(number)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(day.isToday ? .holoPrimary : .holoTextSecondary)
                                .padding(4)
                        }
                    }
                    .overlay(alignment: .center) {
                        dayCenterIcon(day)
                    }
                    .aspectRatio(1, contentMode: .fit)
            }
        }
    }

    private func dayBackgroundColor(_ day: HabitStatsDayCell) -> Color {
        if day.isOverLimit {
            return Color.red.opacity(0.12)
        }
        return day.isToday ? Color.holoPrimary.opacity(0.18) : Color.holoBackground
    }

    @ViewBuilder
    private func dayCenterIcon(_ day: HabitStatsDayCell) -> some View {
        if day.isOverLimit {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.red)
        } else if day.hasRecord {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(accentColor)
        }
    }
}

#Preview {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())

    let week = HabitStatsWeekSlice(
        weekStart: today,
        days: (0..<7).map { i in
            let date = calendar.date(byAdding: .day, value: i, to: today)!
            return HabitStatsDayCell(
                date: date,
                dayNumber: i + 1,
                isInCurrentMonth: true,
                isToday: i == 0,
                hasRecord: i % 2 == 0,
                isOverLimit: false
            )
        }
    )

    HabitWeekStripView(week: week, accentColor: .holoPrimary)
        .padding()
        .background(Color.holoCardBackground)
}
