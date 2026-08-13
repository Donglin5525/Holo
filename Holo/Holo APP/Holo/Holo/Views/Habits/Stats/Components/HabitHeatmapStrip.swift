//
//  HabitHeatmapStrip.swift
//  Holo
//
//  习惯全貌列表的整月色块条（折叠态使用）
//  统一使用品牌暖橙热力图色阶：完成=最深档、未完成=空档、坏习惯超标=红
//  所有习惯一致语义，并排时视觉统一，不随习惯自身颜色变化
//

import SwiftUI

struct HabitHeatmapStrip: View {
    /// 本月逐日格子（调用方需过滤 isInCurrentMonth，按日期顺序排列）
    let days: [HabitStatsDayCell]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(days) { day in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(fillColor(day))
                    .frame(maxWidth: .infinity)
                    .frame(height: 15)
            }
        }
    }

    /// 二值语义：有记录=品牌橙(热力图最深档)、超标=红、其余=空档
    private func fillColor(_ day: HabitStatsDayCell) -> Color {
        if day.isOverLimit {
            return Color.holoError.opacity(0.55)
        }
        if day.hasRecord {
            return Color.holoHeatmapColor(level: 5, palette: .warm, colorScheme: colorScheme)
        }
        return Color.holoHeatmapColor(level: 0, palette: .warm, colorScheme: colorScheme)
    }
}

#Preview {
    let calendar = Calendar.current
    let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
    let days: [HabitStatsDayCell] = (0..<31).map { i in
        HabitStatsDayCell(
            date: calendar.date(byAdding: .day, value: i, to: monthStart)!,
            dayNumber: i + 1,
            isInCurrentMonth: true,
            isToday: i == 10,
            hasRecord: Bool.random() || i % 3 == 0,
            isOverLimit: i == 15
        )
    }

    HabitHeatmapStrip(days: days)
        .padding()
        .background(Color.holoCardBackground)
}
