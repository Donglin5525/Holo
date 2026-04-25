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

/// 记账首页预算总览卡片
struct BudgetSummaryCard: View {

    let summary: GlobalBudgetSummary
    let warnings: [CategoryBudgetWarning]

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            // 顶部：标题 + 剩余天数
            HStack {
                Text("月度预算")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Text("剩余 \(summary.remainingDays) 天")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.holoBorder.opacity(0.3))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: gradientColors(for: summary.progress),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: geo.size.width * min(CGFloat(summary.progress), 1.0),
                            height: 8
                        )
                }
            }
            .frame(height: 8)

            // 金额行
            HStack {
                Text("\(formatAmount(summary.totalSpentAmount)) / \(formatAmount(summary.totalBudgetAmount))")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text("\(Int(summary.progress * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(budgetProgressColor(summary.progress))
            }

            // 分类预警 chips
            if !warnings.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HoloSpacing.sm) {
                        ForEach(warnings) { warning in
                            CategoryWarningChip(warning: warning)
                        }
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
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

    private func formatAmount(_ amount: Decimal) -> String {
        NumberFormatter.currency.string(from: NSDecimalNumber(decimal: amount)) ?? "¥0"
    }
}

// MARK: - 分类预警 Chip

struct CategoryWarningChip: View {

    let warning: CategoryBudgetWarning

    private var chipColor: Color {
        Color(hex: warning.categoryColor) ?? .gray
    }

    var body: some View {
        HStack(spacing: 6) {
            // 分类图标
            ZStack {
                Circle()
                    .fill(chipColor.opacity(0.15))
                    .frame(width: 20, height: 20)
                Image(systemName: warning.categoryIcon)
                    .font(.system(size: 10))
                    .foregroundColor(chipColor)
            }

            // 分类名 + 百分比
            Text("\(warning.categoryName) \(Int(warning.progress * 100))%")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(warning.isOverBudget ? .holoError : .holoPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            warning.isOverBudget
                ? Color.holoError.opacity(0.1)
                : Color.holoPrimary.opacity(0.1)
        )
        .clipShape(Capsule())
    }
}
