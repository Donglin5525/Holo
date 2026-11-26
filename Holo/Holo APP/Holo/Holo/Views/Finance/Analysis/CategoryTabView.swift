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
    /// 构成卡视图档：false = 环形（当期构成），true = 趋势（近 6 月堆叠面积）
    @State private var showsCompositionTrend: Bool = false
    @State private var trendSelection: String? = nil

    // 交易明细弹窗状态
    @State private var transactionSheetData: TransactionSheetData?

    // 图表颜色（比例条和下方分类列表共享，视觉 V4「纸本调性」）：
    // 统一走 V4 分类色板（赭橙 / 墨蓝 / 麦金 / 藕紫 / 青瓷 / 砖粉，不含流入绿），
    // 「其他」或第 6 类之后退石灰色，与趋势堆叠面积图保持同一色板语言。
    private var chartColors: [Color] {
        let palette = Color.holoChartCategoryPalette
        return currentAggregations.enumerated().map { index, aggregation in
            if aggregation.category.name == "其他" && currentAggregations.count > 1 {
                return .holoChartStone
            }
            return palette.indices.contains(index) ? palette[index] : .holoChartStone
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // 合并后的清爽单行筛选：告别橙色大通栏（2026-11-26 原型 1:1）
                HStack(alignment: .center, spacing: HoloSpacing.sm) {
                    typeSwitcher
                    Spacer(minLength: HoloSpacing.sm)
                    if !state.availableFinanceProjects.isEmpty {
                        projectFilterBar
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 6)

                // 下钻导航栏
                if state.isDrillingDown {
                    drillDownHeader
                        .padding(.top, 8)
                }

                // 无卡构成区：构成（比例条）⇄ 近6月（月度堆叠柱图）
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        Text(showIncomeView ? "收入构成" : "支出构成")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.holoToolText)
                        Spacer()
                        compositionSwitch
                    }
                    if showsCompositionTrend {
                        compositionTrendPane
                            .task(id: "\(showIncomeView ? "income" : "expense")-\(state.categoryProjectFilter?.id.uuidString ?? "all")") {
                                await state.loadCategoryTrend(type: showIncomeView ? .income : .expense)
                            }
                    } else {
                        compositionBarPane
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 16)

                HoloHairlineDivider()

                // 无卡分类列表（带 3pt 极细占比进度条）
                CategoryLegendList(
                    aggregations: currentAggregations,
                    selectedCategory: selectedCategory,
                    colors: chartColors
                ) { category in
                    handleCategoryTap(category)
                }
                .padding(.top, 4)

                // 选中分类的详情
                if let category = selectedCategory,
                   let agg = currentAggregations.first(where: { $0.category.id == category.id }) {
                    selectedCategoryDetail(agg)
                        .padding(.top, HoloSpacing.md)
                }
            }
            .padding(.horizontal, HoloSpacing.page)
            .padding(.bottom, HoloSpacing.xxl)
        }
        .background(Color.holoToolBackground)
        .onChange(of: showIncomeView) { _, _ in
            // 切换类型时清除选中状态和下钻
            selectedCategory = nil
            transactionSheetData = nil
            state.exitDrillDown()
        }
        .onChange(of: currentAggregations.map { "\($0.category.id)-\($0.amount)" }) { _, _ in
            selectedCategory = nil
            transactionSheetData = nil
        }
        .onChange(of: state.timeRange) { _, _ in selectedCategory = nil }
        .onChange(of: state.customDateRange.map { DateInterval(start: $0.start, end: $0.end) }) { _, _ in selectedCategory = nil }
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
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
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

    // MARK: - 构成卡分段切换（灰轨白块 + 0.5pt 描边，无裸阴影）

    private var compositionSwitch: some View {
        HStack(spacing: 1) {
            compositionSegment(String(localized: "构成"), active: !showsCompositionTrend) {
                if !showsCompositionTrend { return }
                showsCompositionTrend = false
            }
            compositionSegment(String(localized: "近6月"), active: showsCompositionTrend) {
                if showsCompositionTrend { return }
                showsCompositionTrend = true
            }
        }
        .padding(2.5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.holoToolInset))
    }

    private func compositionSegment(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
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
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }

    /// 当期构成（2026-11-26 原型 1:1：28pt 衬线主角大数字 + 10pt 全宽交互比例条）
    @ViewBuilder private var compositionBarPane: some View {
        let positive = Array(currentAggregations.enumerated()).filter { $0.element.amount > 0 }
        if positive.isEmpty {
            Text(String(localized: "暂无数据，这就开始记一笔吧！"))
                .font(.caption)
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 100)
        } else {
            let total = positive.reduce(Decimal(0)) { $0 + $1.element.amount }
            let totalDouble = max(Double(truncating: total as NSDecimalNumber), 0.0001)
            let totalCount = positive.reduce(0) { $0 + $1.element.transactionCount }
            let focusedAgg = selectedCategory.flatMap { sel in positive.first { $0.element.category.id == sel.id }?.element }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(focusedAgg?.category.name ?? (showIncomeView ? String(localized: "本期收入") : String(localized: "本期支出")))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                    Spacer(minLength: 8)
                    if let focusedAgg {
                        Text("占 \(focusedAgg.formattedPercentage) · \(focusedAgg.transactionCount) 笔")
                            .font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(Color.holoToolTextSecondary)
                    } else if let top = positive.first?.element {
                        Text("\(top.category.name)占 \(top.formattedPercentage) · 共 \(totalCount) 笔")
                            .font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                }
                Text(NumberFormatter.currency.string(from: (focusedAgg?.amount ?? total) as NSDecimalNumber) ?? "¥0.00")
                    .font(.holoHeroNumber(size: 28)).monospacedDigit()
                    .foregroundStyle(Color.holoToolText)
                    .contentTransition(.numericText())
                GeometryReader { geo in
                    let gap: CGFloat = 2
                    let usable = max(geo.size.width - gap * CGFloat(max(positive.count - 1, 0)), 0)
                    HStack(spacing: gap) {
                        ForEach(positive, id: \.element.id) { index, agg in
                            let weight = Double(truncating: agg.amount as NSDecimalNumber)
                            let width = max(usable * CGFloat(weight / totalDouble), 3)
                            let color = chartColors.indices.contains(index) ? chartColors[index] : .holoChartStone
                            let dimmed = selectedCategory != nil && selectedCategory?.id != agg.category.id
                            Rectangle()
                                .fill(color)
                                .opacity(dimmed ? 0.28 : 1)
                                .frame(width: width, height: 10)
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        selectedCategory = (selectedCategory?.id == agg.category.id) ? nil : agg.category
                                    }
                                }
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                .padding(.top, 2)
            }
        }
    }

    /// 趋势档内容：近 6 月月度堆叠柱状图 + 2 列紧凑可点击图例
    @ViewBuilder private var compositionTrendPane: some View {
        if let trend = state.categoryTrend, !trend.series.isEmpty {
            HoloStackedAreaChart(
                buckets: trend.buckets,
                series: trend.series,
                selection: $trendSelection,
                summary: "近 6 月",
                presentation: .stackedBar,
                valueText: { NumberFormatter.compactCurrency(Decimal($0)) })
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    // MARK: - 轻量类型切换器（与项目筛选并排，告别橙色大通栏）

    private var typeSwitcher: some View {
        HStack(spacing: 1) {
            typeButton(title: String(localized: "支出"), isSelected: !showIncomeView) {
                showIncomeView = false
            }

            typeButton(title: String(localized: "收入"), isSelected: showIncomeView) {
                showIncomeView = true
            }
        }
        .padding(2.5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.holoToolInset))
    }

    private func typeButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .holoToolText : .holoToolTextSecondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.holoToolSurface : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Color.holoToolBorder : .clear, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
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
