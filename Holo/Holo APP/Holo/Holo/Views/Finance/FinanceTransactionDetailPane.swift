//
//  FinanceTransactionDetailPane.swift
//  Holo
//
//  iPad 财务工作台右栏（2026-09-16 可用性改造方案 2A）：
//  宽屏双栏下左侧账本保持原位，右侧显示所选记录的完整信息与处理入口；
//  无选中时给出本日摘要与「选择一笔查看」引导，不出空白马赛克。
//

import SwiftUI

struct FinanceTransactionDetailPane: View {

    /// 所选记录（nil = 无选中；删除后从列表找不到会自动回到无选中态）
    let transaction: Transaction?

    /// 无选中时的本日摘要（支出 / 收入 / 笔数）
    let daySummary: DaySummary

    struct DaySummary {
        var expense: Decimal
        var income: Decimal
        var count: Int

        init(expense: Decimal, income: Decimal, count: Int) {
            self.expense = expense
            self.income = income
            self.count = count
        }
    }

    let onEdit: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Group {
            if let tx = transaction {
                recordDetail(tx)
            } else {
                emptyGuidance
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.holoBackground)
    }

    // MARK: - 无选中：本日摘要 + 引导

    private var emptyGuidance: some View {
        VStack(spacing: HoloSpacing.lg) {
            Spacer()

            VStack(spacing: HoloSpacing.md) {
                summaryTile(
                    title: String(localized: "本日支出"),
                    amount: daySummary.expense,
                    color: .holoError
                )
                summaryTile(
                    title: String(localized: "本日收入"),
                    amount: daySummary.income,
                    color: .holoSuccess
                )
            }
            .padding(.horizontal, HoloSpacing.xl)

            Text(String(localized: "轻点左侧一笔交易，在这里核对金额、分类与账户"))
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, HoloSpacing.xl)

            Spacer()
            Spacer()
        }
    }

    private func summaryTile(title: String, amount: Decimal, color: Color) -> some View {
        HStack {
            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Text(NumberFormatter.currency.string(from: amount as NSDecimalNumber) ?? "¥0.00")
                .font(.holoHeading)
                .foregroundColor(color)
        }
        .padding(HoloSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
    }

    // MARK: - 选中：完整信息 + 处理入口

    private func recordDetail(_ tx: Transaction) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                // 金额头
                VStack(alignment: .leading, spacing: 6) {
                    Text(tx.transactionType == .income
                         ? String(localized: "收入")
                         : String(localized: "支出"))
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)

                    Text((tx.transactionType == .income ? "+" : "-") + tx.formattedAmount)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(tx.transactionType == .income ? .holoSuccess : .holoError)

                    if let label = tx.installmentLabel {
                        CardBadge(text: label, color: .holoPrimary)
                            .fixedSize()
                    }
                }
                .padding(.top, HoloSpacing.xl)

                // 属性区
                VStack(spacing: 0) {
                    attributeRow(String(localized: "分类"),
                                 value: tx.category?.name ?? String(localized: "未分类"))
                    attributeRow(String(localized: "账户"),
                                 value: tx.account?.name ?? String(localized: "未指定"))
                    attributeRow(String(localized: "日期"), value: fullDateText(tx.date))

                    if let note = tx.note, !note.isEmpty {
                        attributeRow(String(localized: "名称"), value: note)
                    }
                    if let remark = tx.remark, !remark.isEmptyForDisplay {
                        attributeRow(String(localized: "备注"), value: remark)
                    }
                    if let tags = tx.tags, !tags.isEmpty {
                        attributeRow(String(localized: "标签"), value: tags.joined(separator: " · "))
                    }
                    if tx.isAICreated {
                        attributeRow(String(localized: "来源"), value: String(localized: "HoloAI 记录"))
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.lg)
                        .fill(Color.holoCardBackground)
                )

                // 操作入口
                HStack(spacing: HoloSpacing.md) {
                    paneAction(String(localized: "编辑"), icon: "pencil") { onEdit() }
                    paneAction(String(localized: "复制"), icon: "doc.on.doc") { onCopy() }
                    paneAction(String(localized: "删除"), icon: "trash", role: .destructive) { onDelete() }
                }
            }
            .padding(.horizontal, HoloSpacing.xl)
            .padding(.bottom, HoloSpacing.xl)
        }
    }

    private func attributeRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, 12)
    }

    private func paneAction(_ title: String, icon: String,
                            role: ButtonRole? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(.holoLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color.holoCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .strokeBorder(role == .destructive ? Color.holoError.opacity(0.35) : Color.holoBorder,
                                  lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .holoHover()
        .foregroundColor(role == .destructive ? .holoError : .holoTextPrimary)
    }

    // MARK: - 格式化

    private func fullDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEE HH:mm"
        return formatter.string(from: date)
    }
}

private extension String {
    /// 备注展示判空（避免显示纯空白备注）
    var isEmptyForDisplay: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
