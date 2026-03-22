//
//  HabitOverviewCard.swift
//  Holo
//
//  习惯总览卡片组件
//  显示今日完成数、总习惯数、平均完成率
//

import SwiftUI

// MARK: - HabitOverviewCard

/// 习惯总览卡片
struct HabitOverviewCard: View {
    let stats: HabitOverviewStats

    var body: some View {
        VStack(spacing: HoloSpacing.lg) {
            // 今日完成进度
            todayProgressSection

            // 统计指标行
            statsRow
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 今日进度

    private var todayProgressSection: some View {
        VStack(spacing: HoloSpacing.sm) {
            // 进度环
            ZStack {
                Circle()
                    .stroke(Color.holoDivider, lineWidth: 8)

                Circle()
                    .trim(from: 0, to: min(stats.todayCompletionRate / 100, 1))
                    .stroke(
                        Color.holoPrimary,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: stats.todayCompletionRate)

                VStack(spacing: 2) {
                    Text("\(stats.todayCompleted)")
                        .font(.holoTitle)
                        .foregroundColor(.holoTextPrimary)

                    Text("/ \(stats.totalHabits)")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .frame(width: 100, height: 100)

            Text("今日完成")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - 统计行

    private var statsRow: some View {
        HStack(spacing: 0) {
            // 平均完成率
            statItem(
                title: "平均完成率",
                value: String(format: "%.0f%%", stats.averageCompletionRate),
                icon: "chart.pie.fill",
                color: .holoInfo
            )

            Divider()
                .frame(height: 40)

            // 总连续天数
            statItem(
                title: "总连续天数",
                value: "\(stats.totalStreak)",
                icon: "flame.fill",
                color: .holoPrimary
            )
        }
    }

    // MARK: - 统计项

    private func statItem(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: HoloSpacing.xs) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)

                Text(title)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Text(value)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview("Overview Card") {
    VStack {
        HabitOverviewCard(
            stats: HabitOverviewStats(
                todayCompleted: 3,
                totalHabits: 5,
                averageCompletionRate: 72.5,
                totalStreak: 28
            )
        )

        HabitOverviewCard(
            stats: HabitOverviewStats.empty()
        )
    }
    .padding()
    .background(Color.holoBackground)
}
