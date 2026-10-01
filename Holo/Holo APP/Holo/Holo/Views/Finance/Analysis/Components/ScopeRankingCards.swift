//
//  ScopeRankingCards.swift
//  Holo
//
//  总览 Tab 维度排行卡（账户/项目）：本期支出排行 + 点行切换统计维度筛选。
//  - 账户排行随项目筛选切片（选了项目 = 该项目内各账户），不受账户筛选影响
//  - 项目排行随账户筛选切片，不受项目筛选影响
//  - 排行口径与汇总卡一致（支出侧，退款负冲）；占比 = 占本期总支出
//

import SwiftUI

// MARK: - 账户排行卡

/// 本期各账户支出排行，点行 = 只看该账户
struct AccountRankingCard: View {
    let aggregations: [AccountAggregation]
    /// 当前筛选中的账户 id（行高亮）
    var selectedAccountId: UUID?
    var onTap: (UUID) -> Void

    /// 有支出的账户（排行语义：零支出不占行）
    private var ranked: [AccountAggregation] {
        aggregations.filter { $0.expense > 0 }
    }

    var body: some View {
        if ranked.count >= 2 {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                HStack {
                    Text(String(localized: "账户排行"))
                        .font(.holoLabel)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Text(String(localized: "按本期支出"))
                        .font(.system(size: 10))
                        .foregroundColor(.holoTextSecondary)
                }

                let maxExpense = ranked.first?.expense ?? 1

                ForEach(ranked) { item in
                    row(item, maxExpense: maxExpense)
                }
            }
            .padding(HoloSpacing.md)
            .holoCard()
        }
    }

    private func row(_ item: AccountAggregation, maxExpense: Decimal) -> some View {
        let isSelected = item.account.id == selectedAccountId
        return Button {
            onTap(item.account.id)
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(item.account.swiftUIColor.opacity(0.16))
                    Image(systemName: item.account.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(item.account.swiftUIColor)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.account.name)
                            .font(.holoCaption)
                            .fontWeight(isSelected ? .semibold : .medium)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)

                        if item.account.isArchived {
                            Text(String(localized: "已归档"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.holoBackground))
                        }

                        Spacer(minLength: 4)

                        Text(item.formattedCompactExpense)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.holoTextPrimary)
                            .fixedSize()

                        Text(item.percentage > 0 ? String(format: "%.0f%%", item.percentage) : "0%")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 34, alignment: .trailing)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.holoDivider.opacity(0.4))
                            Capsule()
                                .fill(item.account.swiftUIColor.opacity(isSelected ? 1 : 0.75))
                                .frame(width: barWidth(total: geo.size.width, item: item, maxExpense: maxExpense))
                        }
                    }
                    .frame(height: 5)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func barWidth(total: CGFloat, item: AccountAggregation, maxExpense: Decimal) -> CGFloat {
        guard maxExpense > 0 else { return 4 }
        let ratio = Double(truncating: (item.expense / maxExpense) as NSDecimalNumber)
        return max(4, total * min(max(ratio, 0), 1))
    }
}

// MARK: - 项目排行卡

/// 本期各项目支出排行，点行 = 只看该项目；无任何项目支出时整卡隐藏
struct FinanceProjectRankingCard: View {
    let aggregations: [FinanceProjectAggregation]
    var selectedProjectId: UUID?
    var onTap: (UUID) -> Void

    var body: some View {
        if !aggregations.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                HStack {
                    Text(String(localized: "项目排行"))
                        .font(.holoLabel)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Text(String(localized: "按本期支出"))
                        .font(.system(size: 10))
                        .foregroundColor(.holoTextSecondary)
                }

                let maxExpense = aggregations.first?.expense ?? 1

                ForEach(aggregations) { item in
                    row(item, maxExpense: maxExpense)
                }
            }
            .padding(HoloSpacing.md)
            .holoCard()
        }
    }

    private func row(_ item: FinanceProjectAggregation, maxExpense: Decimal) -> some View {
        let isSelected = item.project.id == selectedProjectId
        let overBudget = item.budget.map { item.expense > $0 }

        return Button {
            onTap(item.project.id)
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Text(item.project.icon)
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(hex: item.project.color).opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.project.name)
                            .font(.holoCaption)
                            .fontWeight(isSelected ? .semibold : .medium)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)

                        if let progress = item.budgetProgress {
                            Text(String(format: String(localized: "预算 %d%%"), Int(progress * 100)))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(overBudget == true ? .holoError : .holoTextSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.holoBackground))
                        }

                        Spacer(minLength: 4)

                        Text(item.formattedCompactExpense)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.holoTextPrimary)
                            .fixedSize()

                        Text(item.percentage > 0 ? String(format: "%.0f%%", item.percentage) : "0%")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 34, alignment: .trailing)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.holoDivider.opacity(0.4))
                            Capsule()
                                .fill(
                                    overBudget == true
                                        ? Color.holoError.opacity(0.8)
                                        : Color(hex: item.project.color).opacity(isSelected ? 1 : 0.75)
                                )
                                .frame(width: barWidth(total: geo.size.width, item: item, maxExpense: maxExpense))
                        }
                    }
                    .frame(height: 5)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func barWidth(total: CGFloat, item: FinanceProjectAggregation, maxExpense: Decimal) -> CGFloat {
        guard maxExpense > 0 else { return 4 }
        let ratio = Double(truncating: (item.expense / maxExpense) as NSDecimalNumber)
        return max(4, total * min(max(ratio, 0), 1))
    }
}
