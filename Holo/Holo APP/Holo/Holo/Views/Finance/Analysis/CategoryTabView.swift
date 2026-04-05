//
//  CategoryTabView.swift
//  Holo
//
//  类别 Tab 视图
//  包含饼图 + 分类列表 + 下钻功能
//

import SwiftUI

// MARK: - CategoryTabView

/// 类别 Tab 视图
struct CategoryTabView: View {
    @ObservedObject var state: FinanceAnalysisState

    @State private var selectedCategory: Category?
    @State private var showIncomeView: Bool = false
    @State private var pieTouching: Bool = false

    // 图表颜色
    private let chartColors: [Color] = [
        .holoChart1, .holoChart2, .holoChart3, .holoChart4, .holoChart5
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: HoloSpacing.lg) {
                // 切换收入/支出
                typeSwitcher

                // 下钻导航栏
                if state.isDrillingDown {
                    drillDownHeader
                }

                // 饼图
                PieChartView(
                    aggregations: currentAggregations,
                    selectedCategory: selectedCategory,
                    onSelectCategory: { category in
                        handleCategoryTap(category)
                    },
                    onTouchActive: { active in
                        pieTouching = active
                    }
                )

                // 分类列表
                CategoryLegendList(
                    aggregations: currentAggregations,
                    selectedCategory: selectedCategory,
                    colors: chartColors
                ) { category in
                    handleCategoryTap(category)
                }

                // 选中分类的详情
                if let category = selectedCategory,
                   let agg = currentAggregations.first(where: { $0.category.id == category.id }) {
                    selectedCategoryDetail(agg)
                }
            }
            .padding(HoloSpacing.lg)
        }
        .scrollDisabled(pieTouching)
        .background(Color.holoBackground)
        .onChange(of: showIncomeView) { _, _ in
            // 切换类型时清除选中状态和下钻
            selectedCategory = nil
            state.exitDrillDown()
        }
    }

    // MARK: - 当前聚合数据

    private var currentAggregations: [CategoryAggregation] {
        if showIncomeView {
            return state.incomeCategoryAggregations
        }
        return state.currentCategoryAggregations
    }

    // MARK: - 类型切换器

    private var typeSwitcher: some View {
        HStack(spacing: 0) {
            typeButton(title: "支出", isSelected: !showIncomeView) {
                showIncomeView = false
            }

            typeButton(title: "收入", isSelected: showIncomeView) {
                showIncomeView = true
            }
        }
        .padding(4)
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoDivider, lineWidth: 1)
        )
    }

    private func typeButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(isSelected ? .white : .holoTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(isSelected ? Color.holoPrimary : Color.holoCardBackground)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 下钻导航栏

    private var drillDownHeader: some View {
        HStack {
            Button {
                state.exitDrillDown()
                selectedCategory = nil
            } label: {
                HStack(spacing: HoloSpacing.xs) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                    Text("返回")
                        .font(.holoBody)
                }
                .foregroundColor(.holoPrimary)
            }

            Spacer()

            if let topCategory = state.selectedTopCategory {
                HStack(spacing: HoloSpacing.xs) {
                    transactionCategoryIcon(topCategory, size: 16)
                    Text(topCategory.name)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                }
            }
        }
    }

    // MARK: - 处理分类点击

    private func handleCategoryTap(_ category: Category?) {
        guard let category = category else {
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedCategory = nil
            }
            return
        }

        // 如果已在下钻模式，只更新选中状态（可安全动画）
        if state.isDrillingDown {
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedCategory = category
            }
            return
        }

        // 检查是否有二级分类（用于下钻）
        if category.isTopLevel {
            // 下钻会改变图表数据源，禁止动画避免 Swift Charts 崩溃
            selectedCategory = nil
            state.drillDown(category: category)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedCategory = category
            }
        }
    }

    // MARK: - 选中分类详情

    private func selectedCategoryDetail(_ aggregation: CategoryAggregation) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("分类详情")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            HStack {
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    HStack {
                        Text("金额")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                        Spacer()
                        Text(aggregation.formattedAmount)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                    }

                    HStack {
                        Text("占比")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                        Spacer()
                        Text(aggregation.formattedPercentage)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                    }

                    HStack {
                        Text("交易笔数")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                        Spacer()
                        Text("\(aggregation.transactionCount) 笔")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                    }
                }
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        }
    }
}

// MARK: - Preview

#Preview {
    CategoryTabView(state: FinanceAnalysisState())
}
