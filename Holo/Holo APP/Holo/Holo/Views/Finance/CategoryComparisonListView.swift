//
//  CategoryComparisonListView.swift
//  Holo
//
//  科目对比列表：按一级科目对齐展示本期/对比期支出与差额，可展开二级科目。
//  数据来自 CategoryComparisonBuilder 的本地聚合结果。
//

import SwiftUI

struct CategoryComparisonListView: View {
    let items: [CategoryComparisonItem]
    let currentTotal: Decimal
    let baselineTotal: Decimal

    @State private var expandedIDs: Set<UUID> = []
    @State private var sortOrder: CategoryComparisonBuilder.SortOrder = .diffDescending

    fileprivate enum Column {
        static let amountWidth: CGFloat = 74
        static let diffWidth: CGFloat = 70
    }

    /// 按当前排序方式重排后的一级科目（二级子项在 sorted 内同步重排）
    private var sortedItems: [CategoryComparisonItem] {
        CategoryComparisonBuilder.sorted(items, by: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("科目对比")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                sortMenu
            }

            VStack(spacing: 0) {
                totalSummaryRow
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, HoloSpacing.md)

                Divider().background(Color.holoDivider)

                if items.isEmpty {
                    emptyState
                } else {
                    columnHeader
                        .padding(.horizontal, HoloSpacing.md)
                        .padding(.top, HoloSpacing.sm)

                    ForEach(sortedItems) { item in
                        topLevelRow(item)
                        if expandedIDs.contains(item.id) {
                            ForEach(item.subItems) { sub in
                                subLevelRow(sub)
                            }
                        }
                        if item.id != sortedItems.last?.id {
                            Divider().background(Color.holoDivider)
                                .padding(.leading, HoloSpacing.md)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.bottom, HoloSpacing.sm)
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .stroke(Color.holoDivider.opacity(0.4), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.035), radius: 8, y: 3)
        }
    }

    // MARK: - 排序入口

    private var sortMenu: some View {
        Menu {
            Button {
                sortOrder = .diffDescending
            } label: {
                sortMenuLabel("按差额", isSelected: sortOrder == .diffDescending)
            }
            Button {
                sortOrder = .amountDescending
            } label: {
                sortMenuLabel("金额从高到低", isSelected: sortOrder == .amountDescending)
            }
            Button {
                sortOrder = .amountAscending
            } label: {
                sortMenuLabel("金额从低到高", isSelected: sortOrder == .amountAscending)
            }
        } label: {
            HStack(spacing: 3) {
                Text(sortMenuTitle)
                    .font(.holoTinyLabel)
                    .fontWeight(.semibold)
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.holoPrimary.opacity(0.12))
            .clipShape(Capsule())
        }
        .accessibilityLabel("切换科目排序方式")
    }

    private var sortMenuTitle: String {
        switch sortOrder {
        case .diffDescending: return "按差额"
        case .amountDescending: return "金额↓"
        case .amountAscending: return "金额↑"
        }
    }

    @ViewBuilder
    private func sortMenuLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - 总差额摘要

    private var totalSummaryRow: some View {
        let diff = currentTotal - baselineTotal
        let color = diffColor(diff)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("本期 \(currency(currentTotal))")
                    .foregroundColor(.holoTextPrimary)
                Text("·")
                    .foregroundColor(.holoTextSecondary)
                Text("对比期 \(currency(baselineTotal))")
                    .foregroundColor(.holoTextSecondary)
            }
            .font(.holoLabel)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            if diff == 0 {
                Text("两期支出持平")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            } else {
                Text(diffSummaryText(diff))
                    .font(.holoLabel)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diffSummaryText(_ diff: Decimal) -> String {
        let verb = diff > 0 ? "多支出" : "少支出"
        let percentage = baselineTotal > 0
            ? "（\(String(format: "%+.1f%%", NSDecimalNumber(decimal: diff / baselineTotal * 100).doubleValue))）"
            : ""
        return "比对比期\(verb) \(currency(abs(diff)))\(percentage)"
    }

    // MARK: - 列头

    private var columnHeader: some View {
        HStack(spacing: HoloSpacing.sm) {
            Text("科目")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("本期")
                .frame(width: Column.amountWidth, alignment: .trailing)
            Text("对比期")
                .frame(width: Column.amountWidth, alignment: .trailing)
            Text("差额")
                .frame(width: Column.diffWidth, alignment: .trailing)
        }
        .font(.holoTinyLabel)
        .foregroundColor(.holoTextSecondary)
    }

    // MARK: - 一级科目行

    private func topLevelRow(_ item: CategoryComparisonItem) -> some View {
        Button {
            guard !item.subItems.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                if expandedIDs.contains(item.id) {
                    expandedIDs.remove(item.id)
                } else {
                    expandedIDs.insert(item.id)
                }
            }
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                HStack(spacing: HoloSpacing.xs) {
                    categoryIconGlyph(item.icon, size: 14, color: Color(hex: item.color))
                        .frame(width: 28, height: 28)
                        .background(Color(hex: item.color).opacity(0.15))
                        .clipShape(Circle())

                    Text(item.name)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if !item.subItems.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                            .rotationEffect(.degrees(expandedIDs.contains(item.id) ? 180 : 0))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(currency(item.currentAmount))
                    .amountColumnStyle(color: .holoTextPrimary)
                Text(currency(item.baselineAmount))
                    .amountColumnStyle(color: .holoTextSecondary)
                diffPill(diff: item.diff, isNew: item.baselineAmount == 0 && item.currentAmount > 0)
            }
            .padding(.vertical, HoloSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 二级科目行

    private func subLevelRow(_ sub: SubCategoryComparison) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Text(sub.name)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.leading, 36)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(currency(sub.currentAmount))
                .amountColumnStyle(color: .holoTextPrimary)
            Text(currency(sub.baselineAmount))
                .amountColumnStyle(color: .holoTextSecondary)

            Text(diffText(sub.diff))
                .font(.holoTinyLabel)
                .foregroundColor(diffColor(sub.diff))
                .frame(width: Column.diffWidth, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, HoloSpacing.xs)
    }

    // MARK: - 差额展示

    private func diffPill(diff: Decimal, isNew: Bool) -> some View {
        let color = diffColor(diff)
        return Text(isNew ? "新增" : diffText(diff))
            .font(.holoTinyLabel)
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .cornerRadius(HoloRadius.sm)
            .frame(width: Column.diffWidth, alignment: .trailing)
    }

    /// 差额文案：带符号的紧凑金额（+¥1.2万 / -¥300.00）
    private func diffText(_ diff: Decimal) -> String {
        let sign = diff > 0 ? "+" : (diff < 0 ? "-" : "±")
        return "\(sign)\(NumberFormatter.compactCurrency(abs(diff)))"
    }

    /// 支出语义配色：增加红、减少绿、持平灰（与 MonthlySummaryCard 一致）
    private func diffColor(_ diff: Decimal) -> Color {
        if diff > 0 { return .holoError }
        if diff < 0 { return .holoSuccess }
        return .holoTextSecondary
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.holoTextSecondary)
            Text("暂无科目数据")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xl)
    }

    private func currency(_ amount: Decimal) -> String {
        NumberFormatter.currency.string(from: NSDecimalNumber(decimal: amount)) ?? "¥0"
    }
}

// MARK: - 金额列样式

private extension Text {
    func amountColumnStyle(color: Color) -> some View {
        self
            .font(.holoLabel)
            .foregroundColor(color)
            .frame(width: CategoryComparisonListView.Column.amountWidth, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
