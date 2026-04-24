//
//  MonthlySummaryCard.swift
//  Holo
//
//  月度收支概览卡片 — 左右两列布局（本月数据 | 今日数据）
//  支持全宽（单卡片）和紧凑（双卡片并排）两种模式
//

import SwiftUI

struct MonthlySummaryCard: View {
    let title: String
    let amount: Decimal
    let previousAmount: Decimal?
    let iconName: String
    let iconColor: Color
    let isCompact: Bool

    /// 今日金额（nil 时不显示右列）
    var todayAmount: Decimal? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: 标题行 — 左侧图标+标题 | 右侧"今日"
            HStack(alignment: .center) {
                HStack(spacing: 4) {
                    Image(systemName: iconName)
                        .font(.system(size: 13))
                        .foregroundColor(iconColor)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer(minLength: 0)

                if todayAmount != nil {
                    Text("今日")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.holoTextPlaceholder)
                }
            }

            // Row 2: 金额行 — 本月金额(左) | 今日金额(右)，基线对齐
            HStack(alignment: .firstTextBaseline) {
                Text(formatAmount(amount))
                    .font(.system(size: isCompact ? 20 : 32, weight: .bold))
                    .foregroundColor(.holoTextPrimary)

                Spacer(minLength: 0)

                if let today = todayAmount {
                    Text(formatAmount(today))
                        .font(.system(size: isCompact ? 16 : 24, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                }
            }

            // Row 3: 环比（始终占位，保持双卡片高度一致）
            Group {
                if let prev = previousAmount, prev > 0 {
                    comparisonView(current: amount, previous: prev)
                } else {
                    Text(" ")
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Helper

    private func formatAmount(_ value: Decimal) -> String {
        NumberFormatter.currency.string(from: value as NSDecimalNumber) ?? "¥0.00"
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
                    .font(.system(size: 12, weight: .medium))
            } else {
                Text(String(format: "较上月同期%.1f%%", percentage))
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .foregroundColor(isIncrease ? .holoError : (isNeutral ? .holoTextSecondary : .holoSuccess))
    }
}
