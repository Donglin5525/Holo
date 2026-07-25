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
                RoundedRectangle(cornerRadius: 6)
                    .fill(dayBackgroundColor(day))
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
        }
    }

    private func dayBackgroundColor(_ day: HabitStatsDayCell) -> Color {
        if day.isOverLimit {
            return Color.red.opacity(0.12)
        }
        if day.hasRecord {
            return accentColor
        }
        if day.isToday {
            return accentColor.opacity(0.12)
        }
        return Color.holoBackground
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
        return .holoTextSecondary
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
