//
//  ScopeInsightSections.swift
//  Holo
//
//  「项目」「账户」页签子视图的共用区段：
//  - ScopeSubHeaderView：子视图顶栏（返回 + 实体名）
//  - ScopeCategoryFilterModel：分类筛选状态机（点一级展开二级+流水筛选）
//  - ScopeCategoryBars：分类构成横条区（可交互）
//  - ScopeTxnRow：交易流水行
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

// MARK: - 分类筛选状态机

/// 「项目/账户」子视图共用的分类筛选状态机（2026-10-04 东林需求：项目内按科目下钻）：
/// 点一级横条 → 原位展开二级科目 + 流水同步筛选；点二级 → 流水精确到二级；再点/chip 取消。
/// 逻辑集中一处，项目/账户两个子视图各挂一个实例，避免两份拷贝漂移。
@MainActor
final class ScopeCategoryFilterModel: ObservableObject {
    @Published private(set) var selectedTop: Category?
    @Published private(set) var selectedSub: Category?
    @Published private(set) var subAggregations: [CategoryAggregation] = []

    private let scope: StatisticsScope
    private let repository: FinanceRepository
    private let dateRange: () -> (start: Date, end: Date)

    init(
        scope: StatisticsScope,
        dateRange: @escaping () -> (start: Date, end: Date),
        repository: FinanceRepository = .shared
    ) {
        self.scope = scope
        self.dateRange = dateRange
        self.repository = repository
    }

    var hasFilter: Bool { selectedTop != nil }

    /// 筛选标签文案：二级选中时「餐饮 · 日料」，一级「餐饮」
    var filterLabelText: String? {
        if let sub = selectedSub, let top = selectedTop {
            return "\(top.name) · \(sub.name)"
        }
        return selectedTop?.name
    }

    func tapTop(_ item: CategoryAggregation) {
        if selectedTop?.id == item.category.id {
            selectedTop = nil
            selectedSub = nil
            subAggregations = []
            return
        }
        selectedTop = item.category
        selectedSub = nil
        loadSubAggregations(parent: item.category)
    }

    func tapSub(_ item: CategoryAggregation) {
        selectedSub = selectedSub?.id == item.category.id ? nil : item.category
    }

    /// 清空筛选（chip 的 × / 时间档变化时）
    func reset() {
        selectedTop = nil
        selectedSub = nil
        subAggregations = []
    }

    /// 流水过滤：一级含二级归并，二级精确匹配（口径与账本项目详情页 visibleTransactions 一致）
    func filter(_ transactions: [Transaction]) -> [Transaction] {
        guard let top = selectedTop else { return transactions }
        if let sub = selectedSub {
            return transactions.filter { $0.category?.id == sub.id }
        }
        return transactions.filter { tx in
            guard let category = tx.category else { return false }
            return category.id == top.id || category.parentId == top.id
        }
    }

    private func loadSubAggregations(parent: Category) {
        let range = dateRange()
        Task {
            let aggs = (try? await repository.getSubCategoryAggregations(
                parentId: parent.id,
                from: range.start,
                to: range.end,
                scope: scope
            )) ?? []
            // 快速连点两个分类时旧请求后到：只回写仍选中者的数据
            guard selectedTop?.id == parent.id else { return }
            withAnimation(HoloAnimation.quick) {
                subAggregations = aggs
            }
        }
    }
}

// MARK: - 分类构成横条区

/// 分类构成（一级口径）横条列表：名称 + 金额占比 + 比例条。
/// 传入 onSelect 时横条可点：点一级展开二级科目（subAggregations）并联动流水筛选，
/// 点二级把筛选精确到二级科目；不传回调则纯静态展示（向后兼容）。
struct ScopeCategoryBars: View {
    let aggregations: [CategoryAggregation]
    var selectedCategoryId: UUID? = nil
    var selectedSubCategoryId: UUID? = nil
    var subAggregations: [CategoryAggregation]? = nil
    var onSelect: ((CategoryAggregation) -> Void)? = nil
    var onSelectSub: ((CategoryAggregation) -> Void)? = nil

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

                    if selectedCategoryId == item.category.id,
                       let subs = subAggregations, !subs.isEmpty {
                        // 二级条基准用自身最大值，否则被一级量级压扁失去区分度
                        let subMax = subs.first?.amount ?? 1
                        ForEach(subs) { sub in
                            subRow(sub, under: item.category, maxAmount: subMax)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func topRow(_ item: CategoryAggregation, maxAmount: Decimal) -> some View {
        let isSelected = selectedCategoryId == item.category.id
        let content = HStack(spacing: HoloSpacing.sm) {
            Text(item.category.name)
                .font(.holoCaption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .holoPrimary : .holoTextPrimary)
                .lineLimit(1)
                .frame(width: 68, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.holoDivider.opacity(0.4))
                    Capsule()
                        .fill(Color.holoPrimary.opacity(isSelected ? 1.0 : 0.75))
                        .frame(width: barWidth(total: geo.size.width, amount: item.amount, maxAmount: maxAmount))
                }
            }
            .frame(height: 6)

            Text("\(item.formattedCompactAmount) · \(item.formattedPercentage)")
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
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

    /// 二级科目行：缩进 + 更细的条；直挂一级（未细分）的交易以「其他」名义成行
    @ViewBuilder
    private func subRow(_ item: CategoryAggregation, under parent: Category, maxAmount: Decimal) -> some View {
        let isSelected = selectedSubCategoryId == item.category.id
        let name = item.category.id == parent.id ? String(localized: "其他") : item.category.name
        let content = HStack(spacing: HoloSpacing.sm) {
            Text(name)
                .font(.system(size: 10.5))
                .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
                .lineLimit(1)
                .frame(width: 68, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.holoDivider.opacity(0.3))
                    Capsule()
                        .fill(Color.holoPrimary.opacity(isSelected ? 0.9 : 0.45))
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
        .padding(.leading, HoloSpacing.md)
        .contentShape(Rectangle())

        if let onSelectSub {
            Button {
                onSelectSub(item)
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
