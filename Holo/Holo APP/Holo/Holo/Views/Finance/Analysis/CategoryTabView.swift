//
//  CategoryTabView.swift
//  Holo
//
//  类别 Tab 视图
//  包含饼图 + 分类列表 + 下钻 + 交易明细弹窗
//

import SwiftUI

// MARK: - CategoryTabView

/// 类别 Tab 视图
struct CategoryTabView: View {
    @ObservedObject var state: FinanceAnalysisState

    @State private var selectedCategory: Category?
    @State private var showIncomeView: Bool = false

    // 交易明细弹窗状态
    @State private var transactionSheetData: TransactionSheetData?

    // 图表颜色（饼图和图例共享）
    // 类别统计页始终使用图表调色板区分扇区，避免导入/父子分类共享同一科目色时整图变成单色。
    private var chartColors: [Color] {
        if FinanceCategoryChartColor.shouldUseChartPaletteForCategoryAnalysis() {
            return Color.holoChartColors(count: currentAggregations.count)
        }
        return currentAggregations.map { $0.category.swiftUIColor }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                // 切换收入/支出
                typeSwitcher

                // 项目筛选（无项目时这行没有意义，不占位）
                if !state.availableFinanceProjects.isEmpty {
                    HStack {
                        projectFilterBar
                        Spacer()
                    }
                }

                // 下钻导航栏
                if state.isDrillingDown {
                    drillDownHeader
                }

                // 饼图
                PieChartView(
                    aggregations: currentAggregations,
                    selectedCategory: selectedCategory,
                    colors: chartColors,
                    onSelectCategory: { category in
                        handleCategoryTap(category)
                    }
                )
                .padding(HoloSpacing.md)
                .holoSurface()

                // 分类列表
                CategoryLegendList(
                    aggregations: currentAggregations,
                    selectedCategory: selectedCategory,
                    colors: chartColors
                ) { category in
                    handleCategoryTap(category)
                }
                .holoSurface()

                // 选中分类的详情
                if let category = selectedCategory,
                   let agg = currentAggregations.first(where: { $0.category.id == category.id }) {
                    selectedCategoryDetail(agg)
                }
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoToolBackground)
        .onChange(of: showIncomeView) { _, _ in
            // 切换类型时清除选中状态和下钻
            selectedCategory = nil
            transactionSheetData = nil
            state.exitDrillDown()
        }
        .sheet(item: $transactionSheetData) { data in
            CategoryDetailSheet(
                category: data.category,
                transactions: data.transactions
            )
        }
    }

    // MARK: - 当前聚合数据

    private var currentAggregations: [CategoryAggregation] {
        // 项目筛选态读本页签独立聚合（不污染共享聚合，总览页签不受影响）；
        // 下钻态仍走 drillDownAggregations（已在取数时带上项目范围）
        if state.categoryProjectFilter != nil {
            if state.isDrillingDown {
                return state.drillDownAggregations
            }
            return showIncomeView ? state.categoryTabIncomeAggregations : state.categoryTabExpenseAggregations
        }
        if showIncomeView {
            return state.incomeCategoryAggregations
        }
        return state.currentCategoryAggregations
    }

    // MARK: - 项目筛选器

    /// 类别页签的项目筛选（2026-10-04 东林需求：选「东京旅游」后整个分类分布只算该项目的账）
    private var projectFilterBar: some View {
        let isFiltered = state.categoryProjectFilter != nil
        return Menu {
            Button {
                state.setCategoryProjectFilter(nil)
            } label: {
                if isFiltered {
                    Label(String(localized: "全部项目"), systemImage: "checkmark")
                } else {
                    Text(String(localized: "全部项目"))
                }
            }

            ForEach(state.availableFinanceProjects, id: \.id) { project in
                Button {
                    state.setCategoryProjectFilter(project)
                } label: {
                    if state.categoryProjectFilter?.id == project.id {
                        Label("\(project.icon) \(project.name)", systemImage: "checkmark")
                    } else {
                        Text("\(project.icon) \(project.name)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "flag")
                    .font(.system(size: 10))
                Text(state.categoryProjectFilter.map { String(localized: "项目：\($0.name)") }
                     ?? String(localized: "项目：全部"))
                    .font(.system(size: 11.5, weight: isFiltered ? .semibold : .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(isFiltered ? .holoPrimary : .holoToolTextSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isFiltered ? Color.holoPrimary.opacity(0.08) : Color.holoToolSurface)
                    .overlay(
                        Capsule().strokeBorder(
                            isFiltered ? Color.holoPrimary.opacity(0.4) : Color.holoDivider.opacity(0.6)
                        )
                    )
            )
        }
    }

    // MARK: - 类型切换器

    private var typeSwitcher: some View {
        HStack(spacing: 0) {
            typeButton(title: String(localized: "支出"), isSelected: !showIncomeView) {
                showIncomeView = false
            }

            typeButton(title: String(localized: "收入"), isSelected: showIncomeView) {
                showIncomeView = true
            }
        }
        .padding(4)
        .background(Color.holoToolBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoDivider, lineWidth: 1)
        )
    }

    private func typeButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .holoText(.supporting)
                .foregroundColor(isSelected ? .white : .holoToolTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(isSelected ? Color.holoPrimary : Color.holoToolSurface)
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
                        .holoText(.body)
                }
                .foregroundColor(.holoPrimary)
            }

            Spacer()

            if let topCategory = state.selectedTopCategory {
                HStack(spacing: HoloSpacing.xs) {
                    transactionCategoryIcon(topCategory, size: 16)
                    Text(topCategory.name)
                        .holoText(.supporting)
                        .foregroundColor(.holoToolText)
                }
            }
        }
    }

    // MARK: - 处理分类点击

    private func handleCategoryTap(_ category: Category?) {
        guard let category = category else {
            withAnimation(HoloAnimation.smooth) {
                selectedCategory = nil
            }
            return
        }

        // 如果已在下钻模式，展示该二级分类的交易明细
        if state.isDrillingDown {
            withAnimation(HoloAnimation.smooth) {
                selectedCategory = category
            }
            showTransactionDetail(for: category)
            return
        }

        // 一级科目：下钻
        if category.isTopLevel {
            selectedCategory = nil
            state.drillDown(category: category)
        } else {
            withAnimation(HoloAnimation.smooth) {
                selectedCategory = category
            }
        }
    }

    // MARK: - 交易明细弹窗

    private func showTransactionDetail(for category: Category) {
        // 项目筛选态：明细弹窗同范围（只算选中项目的交易）
        let projectId = state.categoryProjectFilter?.id
        let txns: [Transaction]
        if category.isTopLevel {
            txns = state.transactions.filter {
                (projectId == nil || $0.financeProjectId == projectId)
                    && ($0.category?.id == category.id || $0.category?.parentId == category.id)
            }
        } else {
            txns = state.transactions.filter {
                (projectId == nil || $0.financeProjectId == projectId)
                    && $0.category?.id == category.id
            }
        }
        transactionSheetData = TransactionSheetData(
            category: category,
            transactions: txns
        )
    }

    // MARK: - 选中分类详情

    private func selectedCategoryDetail(_ aggregation: CategoryAggregation) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("分类详情")
                .holoText(.sectionTitle)
                .foregroundColor(.holoToolText)

            HStack {
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    HStack {
                        Text("金额")
                            .holoText(.supporting)
                            .foregroundColor(.holoToolTextSecondary)
                        Spacer()
                        Text(aggregation.formattedAmount)
                            .holoText(.body)
                            .foregroundColor(.holoToolText)
                    }

                    HStack {
                        Text("占比")
                            .holoText(.supporting)
                            .foregroundColor(.holoToolTextSecondary)
                        Spacer()
                        Text(aggregation.formattedPercentage)
                            .holoText(.body)
                            .foregroundColor(.holoToolText)
                    }

                    HStack {
                        Text("交易笔数")
                            .holoText(.supporting)
                            .foregroundColor(.holoToolTextSecondary)
                        Spacer()
                        Text("\(aggregation.transactionCount) 笔")
                            .holoText(.body)
                            .foregroundColor(.holoToolText)
                    }
                }
            }
            .padding(HoloSpacing.md)
            .background(Color.holoToolSurface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        }
    }
}

// MARK: - Preview

#Preview {
    CategoryTabView(state: FinanceAnalysisState())
}

// MARK: - Sheet Data

/// 交易明细弹窗数据（用 .sheet(item:) 确保数据完整性）
struct TransactionSheetData: Identifiable {
    let id = UUID()
    let category: Category
    let transactions: [Transaction]
}
