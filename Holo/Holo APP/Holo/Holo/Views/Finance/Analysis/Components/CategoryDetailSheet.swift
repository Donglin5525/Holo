//
//  CategoryDetailSheet.swift
//  Holo
//
//  科目详情弹窗：展示一级科目的子分类列表
//

import SwiftUI

// MARK: - CategoryDetailSheet

/// 科目详情弹窗
struct CategoryDetailSheet: View {
    let category: Category
    let aggregations: [CategoryAggregation]

    @Environment(\.dismiss) private var dismiss

    private let colors: [Color]

    init(category: Category, aggregations: [CategoryAggregation]) {
        self.category = category
        self.aggregations = aggregations
        self.colors = Color.holoChartColors(count: aggregations.count)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    headerCard
                    subCategoryList
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: HoloSpacing.md) {
            transactionCategoryIcon(category, size: 48)

            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text(category.name)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                HStack(spacing: HoloSpacing.md) {
                    Label {
                        Text(totalFormattedAmount)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    } icon: {
                        Image(systemName: "yensign.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Label {
                        Text("\(totalTransactionCount) 笔")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    } icon: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }

            Spacer()
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - Sub-category List

    private var subCategoryList: some View {
        VStack(spacing: 0) {
            if aggregations.isEmpty {
                emptyState
            } else {
                ForEach(Array(aggregations.enumerated()), id: \.element.id) { index, agg in
                    subCategoryRow(agg: agg, color: colors[index])
                    if index < aggregations.count - 1 {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private func subCategoryRow(agg: CategoryAggregation, color: Color) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            // 颜色条
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4, height: 32)

            // 科目图标
            transactionCategoryIcon(agg.category, size: 36)

            // 名称 + 占比条
            VStack(alignment: .leading, spacing: 4) {
                Text(agg.category.name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)

                GeometryReader { geo in
                    let barWidth = geo.size.width * CGFloat(agg.percentage / 100)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.3))
                        .frame(width: geo.size.width, height: 4)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color)
                                .frame(width: barWidth, height: 4)
                        }
                }
                .frame(height: 4)
            }

            // 金额 + 占比
            VStack(alignment: .trailing, spacing: 2) {
                Text(agg.formattedCompactAmount)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                Text(agg.formattedPercentage)
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text("暂无子分类数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xl)
    }

    // MARK: - Computed

    private var totalFormattedAmount: String {
        let total = aggregations.reduce(Decimal(0)) { $0 + $1.amount }
        return NumberFormatter.compactCurrency(total)
    }

    private var totalTransactionCount: Int {
        aggregations.reduce(0) { $0 + $1.transactionCount }
    }
}

// MARK: - Preview

#Preview {
    Text("CategoryDetailSheet Preview")
}
