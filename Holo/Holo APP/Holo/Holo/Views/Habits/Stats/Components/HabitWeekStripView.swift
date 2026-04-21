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
                    .fill(day.isToday ? Color.holoPrimary.opacity(0.18) : Color.holoBackground)
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
                hasRecord: i % 2 == 0
            )
        }
    )

    HabitWeekStripView(week: week, accentColor: .holoPrimary)
        .padding()
        .background(Color.holoCardBackground)
}
