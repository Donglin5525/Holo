//
//  TopCategoryCard.swift
//  Holo
//
//  TOP3 分类卡片组件
//  显示支出/收入前 3 的分类
//

import SwiftUI

// MARK: - TopCategoryCard

/// TOP3 分类卡片
struct TopCategoryCard: View {
    let title: String
    let aggregations: [CategoryAggregation]
    let accentColor: Color
    var onTapCategory: ((Category) -> Void)? = nil

    // 固定高度：标题(28) + 3行(每行约52) + 内边距
    private let cardHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            Text(title)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            if aggregations.isEmpty {
                emptyState
            } else {
                categoryList
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 分类列表

    private var categoryList: some View {
        VStack(spacing: HoloSpacing.sm) {
            ForEach(Array(aggregations.prefix(3).enumerated()), id: \.element.id) { index, agg in
                CategoryRankRow(
                    rank: index + 1,
                    aggregation: agg,
                    accentColor: accentColor
                ) {
                    onTapCategory?(agg.category)
                }
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Category Rank Row

/// 分类排行行
struct CategoryRankRow: View {
    let rank: Int
    let aggregation: CategoryAggregation
    let accentColor: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // 分类图标
                categoryIcon

                // 科目名称
                Text(aggregation.category.name)
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                // 金额 - 固定宽度确保完整显示
                Text(aggregation.formattedAmount)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(accentColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分类图标

    private var categoryIcon: some View {
        ZStack {
            Circle()
                .fill(aggregation.category.swiftUIColor.opacity(0.15))
                .frame(width: 24, height: 24)

            transactionCategoryIcon(aggregation.category, size: 12)
        }
    }
}

// MARK: - Preview

#Preview("Top Category Card") {
    VStack(spacing: 20) {
        TopCategoryCard(
            title: "支出 TOP 3",
            aggregations: [],
            accentColor: .holoError
        )

        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
