//
//  CategoryLegendRow.swift
//  Holo
//
//  分类图例行组件
//  用于饼图下方的分类列表
//

import SwiftUI

// MARK: - CategoryLegendRow

/// 分类图例行
struct CategoryLegendRow: View {
    let aggregation: CategoryAggregation
    let color: Color
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HoloSpacing.md) {
                // 颜色标识
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)

                // 分类图标
                ZStack {
                    Circle()
                        .fill(aggregation.category.swiftUIColor.opacity(0.1))
                        .frame(width: 32, height: 32)

                    transactionCategoryIcon(aggregation.category, size: 16)
                }

                // 分类名称
                VStack(alignment: .leading, spacing: 2) {
                    Text(aggregation.category.name)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    Text("\(aggregation.transactionCount) 笔")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                // 金额和占比
                VStack(alignment: .trailing, spacing: 2) {
                    Text(aggregation.formattedCompactAmount)
                        .font(.holoBody)
                        .foregroundColor(isSelected ? color : .holoTextPrimary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)

                    Text(aggregation.formattedPercentage)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .padding(.vertical, HoloSpacing.sm)
            .padding(.horizontal, HoloSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .fill(isSelected ? color.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CategoryLegendList

/// 分类图例列表
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
                    Divider()
                        .padding(.leading, 56)
                }
            }
        }
        .padding(.horizontal, HoloSpacing.sm)
        .padding(.vertical, HoloSpacing.xs)
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
