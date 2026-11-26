//
//  TopCategoryCard.swift
//  Holo
//
//  分类排行区块（2026-11-26 原型 1:1 无卡纸本重构：
//  去掉白卡外壳、系统原生分段器与双圆圈排名数字，改用极细占比条 + 暖墨等宽金额）
//

import SwiftUI

// MARK: - TopCategoryCard

/// 分类排行区块（无卡纸本）
struct TopCategoryCard: View {
    let expenseAggregations: [CategoryAggregation]
    let incomeAggregations: [CategoryAggregation]
    var onTapCategory: ((Category) -> Void)? = nil

    @State private var showsExpense = true

    private var currentAggregations: [CategoryAggregation] {
        showsExpense ? expenseAggregations : incomeAggregations
    }

    private var barColors: [Color] {
        if !showsExpense {
            return Array(repeating: .holoChartInflow, count: max(currentAggregations.count, 1))
        }
        let palette = Color.holoChartCategoryPalette
        return currentAggregations.enumerated().map { index, agg in
            if agg.category.name == "其他" && currentAggregations.count > 1 {
                return .holoChartStone
            }
            return palette.indices.contains(index) ? palette[index] : .holoChartStone
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: HoloSpacing.md) {
                Text(showsExpense ? "支出排行" : "收入排行")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)

                Spacer(minLength: HoloSpacing.sm)

                typeSwitch
            }

            if currentAggregations.isEmpty {
                emptyState
            } else {
                categoryList
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var typeSwitch: some View {
        HStack(spacing: 1) {
            switchButton(String(localized: "支出"), active: showsExpense) {
                showsExpense = true
            }
            switchButton(String(localized: "收入"), active: !showsExpense) {
                showsExpense = false
            }
        }
        .padding(2.5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.holoToolInset))
    }

    private func switchButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                .foregroundColor(active ? .holoToolText : .holoToolTextSecondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.holoToolSurface : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(active ? Color.holoToolBorder : .clear, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分类列表

    private var categoryList: some View {
        let items = Array(currentAggregations.prefix(5))
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, agg in
                CategoryRankRow(
                    aggregation: agg,
                    tintColor: barColors.indices.contains(index) ? barColors[index] : .holoChartStone
                ) {
                    onTapCategory?(agg.category)
                }

                if index < items.count - 1 {
                    HoloHairlineDivider(leadingInset: 44)
                }
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        Text("暂无数据")
            .font(.holoCaption)
            .foregroundColor(.holoToolTextSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 88)
    }
}

// MARK: - Category Rank Row

/// 分类排行行（无卡极简：图标 + 名称/暖墨金额 + 3pt 发丝占比条 + 百分比）
struct CategoryRankRow: View {
    let aggregation: CategoryAggregation
    let tintColor: Color
    let onTap: () -> Void

    private var progress: Double {
        min(max(aggregation.percentage / 100.0, 0), 1)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tintColor.opacity(0.13))
                        .frame(width: 32, height: 32)
                    transactionCategoryIcon(aggregation.category, size: 15)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(aggregation.category.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolText)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(aggregation.formattedCompactAmount)
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(.holoToolText)
                            .lineLimit(1)
                    }

                    HStack(spacing: 10) {
                        HoloHairlineProgressTrack(progress: progress, tint: tintColor, height: 3)

                        Text(aggregation.formattedPercentage)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(.holoToolTextSecondary)
                            .frame(minWidth: 34, alignment: .trailing)
                    }
                }
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview("Top Category Card") {
    VStack(spacing: 20) {
        TopCategoryCard(
            expenseAggregations: [],
            incomeAggregations: []
        )

        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
