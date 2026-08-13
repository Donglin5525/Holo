//
//  HabitStatsCockpitCard.swift
//  Holo
//
//  统计页顶部驾驶舱卡：本月完成率 + 环比 + 今日 + 近6月趋势 + 最佳连续/习惯数
//  让用户不滚动就掌握全局与进步方向
//

import SwiftUI

struct HabitStatsCockpitCard: View {
    /// 当前查看的月份（用于推算近6月趋势的横轴标签）
    let selectedMonth: Date
    /// 本月平均完成率（0~100）
    let completionRate: Double
    /// 上月平均完成率（环比基准）
    let previousRate: Double
    /// 近6个月完成率趋势（索引0=5个月前，末位=当月）
    let monthlyTrend: [Double]
    /// 今日已打卡完成数
    let todayCompleted: Int
    /// 坚持习惯总数
    let totalHabits: Int
    /// 最佳连续
    let bestStreak: HabitStreak
    /// 是否为当前自然月（决定是否显示"今日"模块）
    let isCurrentMonth: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            topRow

            if monthlyTrend.count >= 2 {
                trendChart
            }

            Divider().foregroundStyle(Color.holoDivider)

            bottomMetrics
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    // MARK: - 顶部：完成率 + 今日

    private var topRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("本月完成率")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)

                HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.xs) {
                    Text("\(Int(completionRate.rounded()))")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                    Text("%")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                    deltaBadge
                }
            }

            Spacer()

            if isCurrentMonth {
                todayBox
            }
        }
    }

    private var todayBox: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("今日")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(todayCompleted)")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                Text("/\(totalHabits)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var deltaBadge: some View {
        if let delta = rateDelta, abs(delta) > 0.5 {
            let isUp = delta > 0
            Text("\(isUp ? "↑" : "↓") \(Int(abs(delta).rounded()))%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isUp ? .holoSuccess : .holoError)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background((isUp ? Color.holoSuccess : Color.holoError).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// 与上月的完成率差值；上月无数据则返回 nil（不显示徽章）
    private var rateDelta: Double? {
        guard previousRate > 0 else { return nil }
        return completionRate - previousRate
    }

    // MARK: - 近6月趋势柱图

    private var trendChart: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                ForEach(monthlyTrend.indices, id: \.self) { i in
                    let rate = monthlyTrend[i]
                    let isCurrent = i == monthlyTrend.count - 1
                    VStack {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isCurrent ? Color.holoPrimary : Color.holoPrimary.opacity(0.22))
                            .frame(height: barHeight(for: rate))
                    }
                }
            }
            .frame(height: 38)

            HStack(spacing: 7) {
                ForEach(monthLabels.indices, id: \.self) { i in
                    Text(monthLabels[i])
                        .font(.system(size: 9, weight: i == monthLabels.count - 1 ? .semibold : .regular))
                        .foregroundColor(i == monthLabels.count - 1 ? .holoPrimary : .holoTextSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func barHeight(for rate: Double) -> CGFloat {
        let clamped = min(max(rate, 0), 100)
        return max(4, CGFloat(clamped / 100 * 36))
    }

    private var monthLabels: [String] {
        let calendar = Calendar.current
        return (0..<6).reversed().map { offset in
            guard let m = calendar.date(byAdding: .month, value: -offset, to: selectedMonth) else { return "" }
            return "\(calendar.component(.month, from: m))月"
        }
    }

    // MARK: - 底部：最佳连续 + 习惯数

    private var bottomMetrics: some View {
        HStack(spacing: HoloSpacing.md) {
            metricCell(icon: "flame.fill", iconColor: .holoPrimary, label: "最佳连续", value: bestStreak.displayText)
            metricCell(icon: "checkmark.circle.fill", iconColor: .holoSuccess, label: "坚持习惯", value: "\(totalHabits)个")
        }
    }

    private func metricCell(icon: String, iconColor: Color, label: String, value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
                .frame(width: 30, height: 30)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundColor(.holoTextSecondary)
                Text(value)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
            }
            Spacer()
        }
    }
}

#Preview {
    HabitStatsCockpitCard(
        selectedMonth: Date(),
        completionRate: 68,
        previousRate: 56,
        monthlyTrend: [55, 62, 68, 71, 64, 68],
        todayCompleted: 3,
        totalHabits: 5,
        bestStreak: HabitStreak(value: 21, unit: .day),
        isCurrentMonth: true
    )
    .padding()
    .background(Color.holoBackground)
}
