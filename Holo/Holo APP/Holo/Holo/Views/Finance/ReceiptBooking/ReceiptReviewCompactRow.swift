//
//  ReceiptReviewCompactRow.swift
//  Holo
//
//  复核确认页 · 多笔紧凑摘要行（2026-11-11 重设计，原型画板②）：
//  勾选圆 + 金额 + 方向胶囊 + 名称 + 「科目 · 账户」尾注，52pt 高。
//  点行展开细改（手风琴，一次一笔），点勾选圆剔除这笔（独立 a11y 元素，不与行展开合并）。
//

import SwiftUI

struct ReceiptReviewCompactRow: View {
    @Binding var state: ReceiptReviewItemEditState
    var accounts: [Account]
    var projects: [FinanceProject]
    var expenseCategories: [HoloFinanceCategory]
    var incomeCategories: [HoloFinanceCategory]
    var isExpanded: Bool
    var onToggleIncluded: () -> Void
    var onToggleExpanded: () -> Void

    var body: some View {
        Button(action: onToggleExpanded) {
            HStack(spacing: 9) {
                checkCircle
                Text(verbatim: "¥\(state.amountText)")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(2)
                directionPill
                Text(state.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailingNote
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.vertical, 10)
            .frame(minHeight: 52)
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

    // MARK: 尾注「科目 · 账户」（上限行宽 40%、下限 96pt 保「科目 · 账户」可读，尾部截断）

    private var trailingNote: some View {
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
        // 名称是弹性宽先让位；尾注保底 96pt（判读修复：原先可被挤到账户名全省略）
        .frame(minWidth: 96, maxWidth: summaryMaxWidth, alignment: .trailing)
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

    /// 尾注上限=行宽 40%：行宽=屏宽-页边距(2×24)-卡内边距(2×16)
    private var summaryMaxWidth: CGFloat {
        (holoScreenWidth() - 80) * 0.4
    }
}
