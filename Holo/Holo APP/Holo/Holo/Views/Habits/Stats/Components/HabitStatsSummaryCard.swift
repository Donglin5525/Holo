//
//  HabitStatsSummaryCard.swift
//  Holo
//
//  统计页月度总览卡片
//

import SwiftUI

struct HabitStatsSummaryCard: View {
    let totalHabits: Int
    let completionRate: Double
    let bestStreak: Int
    let statusText: String

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("月度总览")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Text(statusText)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            HStack(spacing: HoloSpacing.sm) {
                summaryPill(title: "展示中", value: "\(totalHabits)")
                summaryPill(title: "完成率", value: "\(Int(completionRate.rounded()))%")
                summaryPill(title: "最佳连续", value: "\(bestStreak)天")
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private func summaryPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
            Text(title)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
    }
}

#Preview {
    HabitStatsSummaryCard(
        totalHabits: 5,
        completionRate: 78,
        bestStreak: 12,
        statusText: "78% 保持节奏"
    )
    .padding()
    .background(Color.holoBackground)
}
