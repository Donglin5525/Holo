//
//  TopCategoryCard.swift
//  Holo
//
//  TOP3 分类排行卡片（支出/收入 Segment 切换，全宽展示）
//

import SwiftUI

private enum TopCategoryRankLayout {
    static let indicatorWidth: CGFloat = 58
    static let amountColumnWidth: CGFloat = 96
    static let contentGroupWidth: CGFloat = 244
    static let amountColumnLeading: CGFloat = indicatorWidth + contentGroupWidth - amountColumnWidth
}

// MARK: - TopCategoryCard

/// TOP3 分类排行卡片
struct TopCategoryCard: View {
    let expenseAggregations: [CategoryAggregation]
    let incomeAggregations: [CategoryAggregation]
    var onTapCategory: ((Category) -> Void)? = nil

    @State private var showsExpense = true

    private var currentAggregations: [CategoryAggregation] {
        showsExpense ? expenseAggregations : incomeAggregations
    }

    private var accentColor: Color {
        showsExpense ? .holoError : .holoSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题 + Segment
            ZStack(alignment: .leading) {
                Text("分类排行")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: TopCategoryRankLayout.amountColumnLeading)

                    segmentControl
                        .frame(width: TopCategoryRankLayout.amountColumnWidth, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if currentAggregations.isEmpty {
                emptyState
            } else {
                categoryList
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - Segment

    private var segmentControl: some View {
        HStack(spacing: 0) {
            segmentButton(title: "支出", isSelected: showsExpense, color: .holoError) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsExpense = true
                }
            }

            segmentButton(title: "收入", isSelected: !showsExpense, color: .holoSuccess) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsExpense = false
                }
            }
        }
        .background(Color.holoBackground)
        .clipShape(Capsule())
    }

    private func segmentButton(title: String, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .white : .holoTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? color : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分类列表

    private var categoryList: some View {
        VStack(spacing: 6) {
            ForEach(Array(currentAggregations.prefix(5).enumerated()), id: \.element.id) { index, agg in
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
        .frame(height: 120)
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
            HStack(spacing: 8) {
                // 排名
                Text("\(rank)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(accentColor.opacity(0.85))
                    .clipShape(Circle())

                // 分类图标
                categoryIcon

                HStack(spacing: 12) {
                    // 科目名称
                    Text(aggregation.category.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                    // 金额
                    Text(aggregation.formattedCompactAmount)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(accentColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .monospacedDigit()
                        .frame(width: TopCategoryRankLayout.amountColumnWidth, alignment: .leading)
                        .layoutPriority(2)
                }
                .frame(width: TopCategoryRankLayout.contentGroupWidth, alignment: .leading)

                Spacer(minLength: 0)
            }
            .frame(height: 42)
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
            expenseAggregations: [],
            incomeAggregations: []
        )

        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
