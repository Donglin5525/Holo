//
//  MonthlySummaryCard.swift
//  Holo
//
//  月度收支概览卡片 — 含环比对比 + 今日支出
//  支持全宽（单卡片）和紧凑（双卡片并排）两种模式
//

import SwiftUI

struct MonthlySummaryCard: View {
    let title: String
    let amount: Decimal
    let previousAmount: Decimal?
    let iconName: String
    let iconColor: Color
    let gradientStart: Color
    let gradientEnd: Color
    let strokeColor: Color
    let isCompact: Bool

    /// 今日支出金额（nil 时不显示）
    var todayAmount: Decimal? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: 标签行 — 图标+标题(左) | 今日(右)
            HStack(alignment: .center) {
                HStack(spacing: HoloSpacing.sm) {
                    ZStack {
                        Circle()
                            .fill(iconColor.opacity(0.08))
                            .frame(width: 24, height: 24)
                        Image(systemName: iconName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(iconColor)
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer(minLength: 0)

                if todayAmount != nil {
                    Text("今日")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextPlaceholder)
                }
            }

            // Row 2: 金额行 — 本月金额(左) | 今日金额(右)
            HStack(alignment: .firstTextBaseline) {
                Text(NumberFormatter.currency.string(from: amount as NSDecimalNumber) ?? "¥0.00")
                    .font(isCompact ? .system(size: 17, weight: .bold) : .system(size: 22, weight: .bold))
                    .foregroundColor(.holoTextPrimary)

                Spacer(minLength: 0)

                if let today = todayAmount {
                    Text(NumberFormatter.currency.string(from: today as NSDecimalNumber) ?? "¥0.00")
                        .font(isCompact ? .system(size: 17, weight: .bold) : .system(size: 22, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                }
            }

            // Row 3: 环比（始终占位，保持双卡片高度一致）
            Group {
                if let prev = previousAmount, prev > 0 {
                    comparisonView(current: amount, previous: prev)
                } else {
                    Text(" ")
                        .font(.system(size: 11, weight: .medium))
                }
            }
        }
        .padding(HoloSpacing.md)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [gradientStart, gradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(0.6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.xl)
                .stroke(strokeColor, lineWidth: 0.5)
        )
    }

    // MARK: - 环比视图

    @ViewBuilder
    private func comparisonView(current: Decimal, previous: Decimal) -> some View {
        let change = current - previous
        let percentage = Double(truncating: (abs(change) / previous * 100) as NSDecimalNumber)
        let isIncrease = change > 0
        let isNeutral = change == 0

        Group {
            if isNeutral {
                Text("与上月同期持平")
                    .font(.system(size: 11, weight: .medium))
            } else {
                Text(String(format: "较上月同期%.1f%%", percentage))
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .foregroundColor(isIncrease ? .holoError : (isNeutral ? .holoTextSecondary : .holoSuccess))
    }
}
