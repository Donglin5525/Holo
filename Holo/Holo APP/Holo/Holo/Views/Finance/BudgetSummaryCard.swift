//
//  BudgetSummaryCard.swift
//  Holo
//
//  记账首页预算总览卡片 - 显示全局预算进度 + 分类预警 chips
//

import SwiftUI

/// 预算进度颜色
func budgetProgressColor(_ progress: Double) -> Color {
    if progress >= 1.0 { return .holoError }
    else if progress >= 0.8 { return .holoPrimary }
    else if progress >= 0.6 { return .holoChart8 }
    else { return .holoSuccess }
}

/// 记账首页预算总览卡片（紧凑型）
struct BudgetSummaryCard: View {

    let summary: GlobalBudgetSummary
    let warnings: [CategoryBudgetWarning]

    var body: some View {
        HStack(spacing: HoloSpacing.md) {
            Text("月度预算")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .layoutPriority(1)

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.holoBorder.opacity(0.3))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: gradientColors(for: summary.progress),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * min(CGFloat(summary.progress), 1.0))
                }
            }
            .frame(height: 6)

            Text(NumberFormatter.compactCurrency(summary.totalBudgetAmount))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.holoTextPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Helpers

    private func gradientColors(for progress: Double) -> [Color] {
        if progress >= 1.0 { return [.holoError, Color(red: 0.97, green: 0.44, blue: 0.44)] }
        else if progress >= 0.8 { return [.holoPrimary, Color(red: 0.98, green: 0.57, blue: 0.24)] }
        else if progress >= 0.6 { return [.holoChart8, Color(red: 0.98, green: 0.8, blue: 0.08)] }
        else { return [.holoSuccess, Color(red: 0.29, green: 0.87, blue: 0.50)] }
    }

}

