//
//  ReceiptReviewCompactRow.swift
//  Holo
//
//  复核确认页 · 多笔紧凑摘要行（2026-11-12 两行制，原型画板②）：
//  账单式两行——L1 名称（行标题）+ 金额右对齐成列，L2 方向胶囊 + 「科目 · 账户」小灰字。
//  点行展开细改（手风琴，一次一笔），点勾选圆剔除这笔（独立 a11y 元素，不与行展开合并）。
//  2026-11-14 合并态（mergeMode）：清单收成单行勾选池——只留勾选圈+名称+金额，
//  L2 副注与行尾箭头收起、点行不展开（细改集中到下方「这一笔」卡）。
//

import SwiftUI

struct ReceiptReviewCompactRow: View {
    @Binding var state: ReceiptReviewItemEditState
    var accounts: [Account]
    var projects: [FinanceProject]
    var expenseCategories: [HoloFinanceCategory]
    var incomeCategories: [HoloFinanceCategory]
    var isExpanded: Bool
    /// 合并态：单行勾选池（无副注/无箭头/点行不展开）
    var mergeMode: Bool
    var onToggleIncluded: () -> Void
    var onToggleExpanded: () -> Void

    var body: some View {
        Button(action: onToggleExpanded) {
            HStack(alignment: .center, spacing: 10) {
                checkCircle
                VStack(alignment: .leading, spacing: 4) {
                    // L1：名称（弹性宽，行标题）… 金额（固定宽右对齐，多笔自然成列）
                    HStack(alignment: .firstTextBaseline) {
                        Text(state.note)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.holoTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: "¥\(state.amountText)")
                            .font(.body.weight(.bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    // L2：方向胶囊 + 「科目 · 账户」副注（合并态收起：细改由「这一笔」卡承载）
                    if !mergeMode {
                        HStack(spacing: 6) {
                            directionPill
                            subNote
                        }
                    }
                }
                if !mergeMode {
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .opacity(state.included ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }

    // MARK: 勾选圆（视觉 24×24、命中区 44×44，独立 Button）

    private var checkCircle: some View {
        Button(action: onToggleIncluded) {
            ZStack {
                Circle()
                    .fill(state.included ? Color.holoPrimary : Color.clear)
                if !state.included {
                    Circle()
                        .strokeBorder(Color.holoTextSecondary.opacity(0.35), lineWidth: 1.5)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 24, height: 24)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("记这笔"))
    }

    // MARK: 方向胶囊（口径同 ReceiptReviewTransferLine：收入绿/支出橙）

    private var directionPill: some View {
        Text(directionText)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
            .fixedSize()
    }

    private var tint: Color { state.typeIsIncome ? .green : .orange }

    private var directionText: String {
        if let kind = state.item.transferKind {
            if state.typeIsIncome { return String(localized: "收到") }
            return kind == HoloVisionTransferInfo.redPacketKind
                ? String(localized: "发出")
                : String(localized: "转出")
        }
        return state.typeIsIncome ? String(localized: "收") : String(localized: "支")
    }

    // MARK: L2 副注「科目 · 账户」（警示有则挂前，尾部截断；两行制后与名称无挤压竞争）

    private var subNote: some View {
        HStack(spacing: 4) {
            if hasWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.orange)
            }
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var hasWarning: Bool {
        state.item.reviewNotes?.isEmpty == false
    }

    private var summaryText: String {
        let category = ReceiptReviewItemEditorBlock.categoryTitle(
            for: state, expense: expenseCategories, income: incomeCategories
        )
        let account = ReceiptReviewItemEditorBlock.accountTitle(for: state, accounts: accounts)
        return "\(category) · \(account)"
    }
}
