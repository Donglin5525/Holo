//
//  CategoryLegendRow.swift
//  Holo
//
//  分类图例行组件
//  用于饼图下方的分类列表
//

import SwiftUI

// MARK: - CategoryLegendRow

/// 分类图例行（2026-11-26 原型 1:1 无卡纸本：图标 + 名称/暖墨金额 + 3pt 发丝占比条 + 笔数与百分比）
struct CategoryLegendRow: View {
    let aggregation: CategoryAggregation
    let color: Color
    let isSelected: Bool
    let onTap: () -> Void

    private var progress: Double {
        min(max(aggregation.percentage / 100.0, 0), 1)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.13))
                        .frame(width: 32, height: 32)
                    transactionCategoryIcon(aggregation.category, size: 15)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(aggregation.category.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoToolText)
                                .lineLimit(1)

                            Text("\(aggregation.transactionCount) 笔")
                                .font(.system(size: 11))
                                .foregroundColor(.holoToolTextSecondary)
                        }

                        Spacer(minLength: 8)

                        Text(aggregation.formattedCompactAmount)
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(isSelected ? color : .holoToolText)
                            .lineLimit(1)
                    }

                    HStack(spacing: 10) {
                        HoloHairlineProgressTrack(progress: progress, tint: color, height: 3)

                        Text(aggregation.formattedPercentage)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(.holoToolTextSecondary)
                            .frame(minWidth: 34, alignment: .trailing)
                    }
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, isSelected ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                    .fill(isSelected ? color.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CategoryLegendList

/// 分类图例列表（无卡纸本）
struct CategoryLegendList: View {
    let aggregations: [CategoryAggregation]
    let selectedCategory: Category?
    let colors: [Color]
    let onSelectCategory: (Category?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(aggregations.enumerated()), id: \.element.id) { index, agg in
                CategoryLegendRow(
                    aggregation: agg,
                    color: colors[index % colors.count],
                    isSelected: selectedCategory?.id == agg.category.id
                ) {
                    if selectedCategory?.id == agg.category.id {
                        onSelectCategory(nil)
                    } else {
                        onSelectCategory(agg.category)
                    }
                }

                if index < aggregations.count - 1 {
                    HoloHairlineDivider(leadingInset: 44)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Category Legend") {
    VStack {
        CategoryLegendList(
            aggregations: [],
            selectedCategory: nil,
            colors: [.holoChart1, .holoChart2, .holoChart3, .holoChart4, .holoChart5]
        ) { _ in }
        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
