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
            HStack {
                Text(title)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                if aggregations.count > 3 {
                    Text("TOP 3")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.holoBackground)
                        .clipShape(Capsule())
                }
            }

            if aggregations.isEmpty {
                emptyState
            } else {
                categoryList
            }
        }
        .padding(HoloSpacing.md)
        .frame(height: cardHeight)
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
            HStack(spacing: HoloSpacing.md) {
                // 排名
                rankBadge

                // 分类图标
                categoryIcon

                // 分类信息
                VStack(alignment: .leading, spacing: 2) {
                    Text(aggregation.category.name)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(aggregation.formattedPercentage)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                // 金额
                Text(aggregation.formattedAmount)
                    .font(.holoBody)
                    .foregroundColor(accentColor)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, HoloSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 排名徽章

    @ViewBuilder
    private var rankBadge: some View {
        switch rank {
        case 1:
            Text("🥇")
                .font(.system(size: 18))
        case 2:
            Text("🥈")
                .font(.system(size: 18))
        case 3:
            Text("🥉")
                .font(.system(size: 18))
        default:
            Text("\(rank)")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .frame(width: 24, height: 24)
                .background(Color.holoBackground)
                .clipShape(Circle())
        }
    }

    // MARK: - 分类图标

    private var categoryIcon: some View {
        ZStack {
            Circle()
                .fill(aggregation.category.swiftUIColor.opacity(0.1))
                .frame(width: 36, height: 36)

            transactionCategoryIcon(aggregation.category, size: 18)
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
