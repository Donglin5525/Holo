//
//  ScopeInsightSections.swift
//  Holo
//
//  「项目」「账户」页签子视图的共用区段：
//  - ScopeSubHeaderView：子视图顶栏（返回 + 实体名）
//  - ScopeCategoryBars：分类构成横条区
//  - ScopeTxnRow：交易流水行
//

import SwiftUI

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

// MARK: - 分类构成横条区

/// 分类构成（一级口径）横条列表：名称 + 金额占比 + 比例条
struct ScopeCategoryBars: View {
    let aggregations: [CategoryAggregation]

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
                    HStack(spacing: HoloSpacing.sm) {
                        Text(item.category.name)
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
                }
            }
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
