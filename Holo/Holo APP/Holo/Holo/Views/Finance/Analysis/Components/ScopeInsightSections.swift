//
//  ScopeInsightSections.swift
//  Holo
//
//  「项目」「账户」页签子视图的共用区段：
//  - ScopeSubHeaderView：子视图顶栏（返回 + 实体名）
//  - ScopeCategoryBars：分类构成横条区（可交互，点入下钻）
//  - ScopeCategoryDrillDownView：分类明细下钻 push 页（头卡 + 二级构成 + 按日分组流水）
//  - ScopeTxnRow：交易流水行
//
//  2026-10-16 交互改版（东林需求）：原「点分类横条 → 原位展开二级 + 页底流水联动筛选」
//  退役——看明细要滚到页底、换分类再滚回顶部，来回跋涉。现改为点分类直接 push
//  下钻页，二级构成与交易明细都在下钻页内，返回即回原位（底层子树不销毁）。
//

import SwiftUI
import Combine

// MARK: - 子视图顶栏

/// 页签内子视图顶栏：‹ 返回 + 实体名（长名整行可用，超出截尾）
struct ScopeSubHeaderView: View {
    let title: String
    var onBack: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.holoCardBackground)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "返回")))

            Spacer()

            Text(title)
                .font(.holoTitle3)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)

            Spacer()

            // 占位保持对称
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.bottom, HoloSpacing.xs)
    }
}

// MARK: - 分类下钻页数据

/// 分类下钻 push 页的数据包：目标分类 + 该分类（含二级归并）的交易明细
struct CategoryDrillDownPayload {
    let category: Category
    let transactions: [Transaction]

    /// 一级分类入口：交易含直挂一级与全部二级（口径与旧流水联动 filter 一致）
    static func top(_ category: Category, transactions: [Transaction]) -> CategoryDrillDownPayload {
        let txns = transactions.filter { tx in
            guard let c = tx.category else { return false }
            return c.id == category.id || c.parentId == category.id
        }
        return CategoryDrillDownPayload(category: category, transactions: txns)
    }
}

/// 下钻请求：payload + 统计范围（账户/项目子视图上报给分析页统一渲染 push 层；
/// push 层必须盖住整个分析页，放在子视图内会露出统计分析头部形成双返回）
struct ScopeDrillDownRequest {
    let payload: CategoryDrillDownPayload
    let scope: StatisticsScope
}

// MARK: - 分类明细下钻页

/// 点分类横条推入的明细页：头卡（金额/笔数）+ 二级科目构成 + 按日分组交易列表。
/// 二级构成走仓储统计口径（退款负冲、排除对账调整），与「分类构成」卡同源。
struct ScopeCategoryDrillDownView: View {
    let payload: CategoryDrillDownPayload
    let scope: StatisticsScope
    /// 时间范围取值闭包：跟随顶部时间档（push 期间换档不常见，但保持同源取数）
    let dateRange: () -> (start: Date, end: Date)
    let onBack: () -> Void

    @State private var editingTransaction: Transaction?
    @State private var subAggregations: [CategoryAggregation] = []

    private var category: Category { payload.category }

    /// 二级构成只在「确有细分」时展示：只有一行且是直挂一级本身（无二级科目）时无信息量
    private var showsSubBreakdown: Bool {
        if subAggregations.count == 1, let only = subAggregations.first {
            return only.category.id != category.id
        }
        return !subAggregations.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScopeSubHeaderView(title: category.name ?? "", onBack: onBack)

            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    headerCard

                    if showsSubBreakdown {
                        subBreakdownSection
                    }

                    transactionList
                }
                .padding(HoloSpacing.lg)
            }
        }
        .background(Color.holoToolBackground)
        .task {
            let range = dateRange()
            subAggregations = (try? await FinanceRepository.shared.getSubCategoryAggregations(
                parentId: category.id,
                from: range.start,
                to: range.end,
                scope: scope
            )) ?? []
        }
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) { _ in }
        }
    }

    // MARK: 头卡

    private var headerCard: some View {
        HStack(spacing: HoloSpacing.md) {
            transactionCategoryIcon(category, size: 44)

            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text(category.name ?? "-")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                HStack(spacing: HoloSpacing.md) {
                    Label {
                        Text(NumberFormatter.compactCurrency(totalAmount))
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    } icon: {
                        Image(systemName: "yensign.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Label {
                        Text(String(localized: "\(payload.transactions.count) 笔"))
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

    private var totalAmount: Decimal {
        payload.transactions.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
    }

    // MARK: 二级科目构成（静态展示）

    private var subBreakdownSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text(String(localized: "科目构成"))
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoToolText)

            let maxAmount = subAggregations.first?.amount ?? 1
            VStack(spacing: HoloSpacing.sm) {
                ForEach(subAggregations) { item in
                    subRow(item, maxAmount: maxAmount)
                }
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    /// 二级行：直挂一级的交易以「其他」名义成行（与仓储下钻口径一致）
    private func subRow(_ item: CategoryAggregation, maxAmount: Decimal) -> some View {
        let name = item.category.id == category.id
            ? String(localized: "其他")
            : (item.category.name ?? "-")

        return HStack(spacing: HoloSpacing.sm) {
            Text(name)
                .font(.system(size: 10.5))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
                .frame(width: 68, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.holoDivider.opacity(0.3))
                    Capsule()
                        .fill(Color.holoPrimary.opacity(0.45))
                        .frame(width: barWidth(total: geo.size.width, amount: item.amount, maxAmount: maxAmount))
                }
            }
            .frame(height: 4)

            Text("\(item.formattedCompactAmount) · \(item.formattedPercentage)")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundColor(.holoTextPlaceholder)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: 14)
    }

    // MARK: 交易列表（按日分组）

    private var transactionList: some View {
        Group {
            if payload.transactions.isEmpty {
                emptyState
            } else {
                groupedTransactions
            }
        }
    }

    private var groupedTransactions: some View {
        let grouped = Dictionary(grouping: payload.transactions) { tx in
            Calendar.current.startOfDay(for: tx.date)
        }

        return VStack(spacing: HoloSpacing.lg) {
            ForEach(grouped.keys.sorted(by: >), id: \.self) { date in
                let dayTxns = grouped[date] ?? []
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    dayHeader(date: date, transactions: dayTxns)

                    VStack(spacing: 0) {
                        ForEach(dayTxns) { tx in
                            TransactionRowView(
                                transaction: tx,
                                isCompact: true,
                                showsDate: false
                            ) {
                                editingTransaction = tx
                            }
                            if tx.id != dayTxns.last?.id {
                                Divider()
                                    .background(Color.holoDivider.opacity(0.55))
                                    .padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.horizontal, HoloSpacing.xs)
                    .padding(.vertical, HoloSpacing.xs)
                    .background(Color.holoToolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
            }
        }
    }

    private func dayHeader(date: Date, transactions dayTxns: [Transaction]) -> some View {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        let expense = dayTxns
            .filter { $0.statisticsType == .expense }
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }
        let income = dayTxns
            .filter { $0.statisticsType == .income }
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }

        return HStack {
            Text(df.string(from: date))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            if expense > 0 {
                Text("-\(NumberFormatter.currency.string(from: expense as NSDecimalNumber) ?? "")")
                    .font(.system(size: 12))
                    .foregroundColor(.holoError)
            }
            if income > 0 {
                Text("+\(NumberFormatter.currency.string(from: income as NSDecimalNumber) ?? "")")
                    .font(.system(size: 12))
                    .foregroundColor(.holoSuccess)
            }
        }
        .padding(.horizontal, HoloSpacing.xs)
    }

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text("暂无交易记录")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xl)
    }

    private func barWidth(total: CGFloat, amount: Decimal, maxAmount: Decimal) -> CGFloat {
        guard maxAmount > 0 else { return 4 }
        let ratio = Double(truncating: (amount / maxAmount) as NSDecimalNumber)
        return max(4, total * min(max(ratio, 0), 1))
    }
}

// MARK: - 分类构成横条区

/// 分类构成（一级口径）横条列表：名称 + 金额占比 + 比例条。
/// 传入 onSelect 时横条可点（点入该分类的明细下钻页）；不传回调则纯静态展示。
struct ScopeCategoryBars: View {
    let aggregations: [CategoryAggregation]
    var onSelect: ((CategoryAggregation) -> Void)? = nil

    var body: some View {
        if aggregations.isEmpty {
            Text(String(localized: "该时间范围内无支出"))
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.md)
        } else {
            let maxAmount = aggregations.first?.amount ?? 1
            VStack(spacing: HoloSpacing.md) {
                ForEach(aggregations) { item in
                    topRow(item, maxAmount: maxAmount)
                }
            }
        }
    }

    @ViewBuilder
    private func topRow(_ item: CategoryAggregation, maxAmount: Decimal) -> some View {
        let content = HStack(spacing: HoloSpacing.sm) {
            Text(item.category.name ?? "-")
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .frame(width: 68, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.holoDivider.opacity(0.4))
                    Capsule()
                        .fill(Color.holoPrimary.opacity(0.75))
                        .frame(width: barWidth(total: geo.size.width, amount: item.amount, maxAmount: maxAmount))
                }
            }
            .frame(height: 6)

            Text("\(item.formattedCompactAmount) · \(item.formattedPercentage)")
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: 16)
        .contentShape(Rectangle())

        if let onSelect {
            Button {
                onSelect(item)
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func barWidth(total: CGFloat, amount: Decimal, maxAmount: Decimal) -> CGFloat {
        guard maxAmount > 0 else { return 4 }
        let ratio = Double(truncating: (amount / maxAmount) as NSDecimalNumber)
        return max(4, total * min(max(ratio, 0), 1))
    }
}

// MARK: - 交易流水行

/// 维度子视图的交易流水行（icon + 备注 + 日期 + 金额）
struct ScopeTxnRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.holoBackground)
                // 分类 icon 字段存的是图标键名（cat_transport 等），必须走统一渲染器
                // 解析成资产图/emoji/兜底图形；直接当 SF Symbol 或文本渲染会露出键名截断
                if let category = transaction.category {
                    transactionCategoryIcon(category, size: 24)
                } else {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(transaction.note?.isEmpty == false ? transaction.note! : (transaction.category?.name ?? "-"))
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)

                Text(Self.dateText(transaction.date))
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextPlaceholder)
            }

            Spacer(minLength: HoloSpacing.sm)

            let isExpense = transaction.transactionType == .expense
            Text("\(isExpense ? "-" : "+")\(NumberFormatter.currency.string(from: transaction.amount.decimalValue as NSDecimalNumber) ?? "")")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(isExpense ? .holoError : .holoSuccess)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 5)
    }

    private static func dateText(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M/d HH:mm"
        return df.string(from: date)
    }
}
