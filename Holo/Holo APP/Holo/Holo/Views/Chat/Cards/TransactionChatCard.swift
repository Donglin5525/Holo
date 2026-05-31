//
//  TransactionChatCard.swift
//  Holo
//
//  记账卡片视图（支出/收入）
//

import SwiftUI

struct TransactionChatCard: View {

    let data: TransactionCardData
    var isDeleted: Bool = false
    var onTap: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onModifyCategory: (() -> Void)?

    var body: some View {
        ChatCardView(isDeleted: isDeleted, onTap: data.requiresConfirmation ? nil : onTap) {
            CardHeaderView(
                icon: data.requiresConfirmation ? "yensign.circle" : data.categoryIcon,
                title: headerTitle,
                badge: badge,
                subtitle: headerSubtitle
            )

            // 金额
            Text(formattedAmount)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(data.isExpense ? .holoError : .holoSuccess)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .strikethrough(isDeleted || data.isCancelled)

            // 备注
            if let note = data.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }

            // 分类（始终显示）
            if let path = data.categoryPath {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(path)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.holoTextSecondary)
            }

            if data.requiresConfirmation {
                modifyCategoryLink
                pendingActions
            } else if data.isCancelled {
                cancelledInfo
            } else if data.isFailed {
                failedInfo
            } else {
                CardFooterView(timeText: "查看明细")
            }
        }
        .accessibilityLabel("记账卡片：\(data.displayTitle)，\(data.isExpense ? "支出" : "收入")\(data.amount)元")
    }

    // MARK: - Header

    private var headerTitle: String {
        if data.requiresConfirmation {
            return data.isExpense ? "支出待确认" : "收入待确认"
        }
        return data.displayTitle
    }

    private var headerSubtitle: String? {
        if data.requiresConfirmation {
            return nil
        }
        return data.categoryPath
    }

    private var badge: CardBadge? {
        if data.requiresConfirmation {
            return CardBadge(text: "待确认", color: .holoPrimary)
        }
        if data.isCancelled {
            return CardBadge(text: "已取消", color: .holoTextSecondary)
        }
        return nil
    }

    // MARK: - Modify Category Link

    private var modifyCategoryLink: some View {
        Button {
            onModifyCategory?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .medium))
                Text("分类不准？点击修改")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.holoPrimary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pending Actions

    private var pendingActions: some View {
        HStack(spacing: 12) {
            Button {
                onCancel?()
            } label: {
                Text("取消")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.holoTextSecondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                onConfirm?()
            } label: {
                Text("确认")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.holoPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Cancelled State

    private var cancelledInfo: some View {
        HStack {
            Text("已取消记账")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoTextSecondary)
            Spacer()
        }
    }

    // MARK: - Failed State

    private var failedInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = data.confirmationError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.holoError)
            }

            HStack {
                Spacer()
                Button {
                    onConfirm?()
                } label: {
                    Text("重试")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.holoPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Formatting

    private var formattedAmount: String {
        if data.isExpense {
            return "-¥\(data.amount)"
        }
        return "+¥\(data.amount)"
    }
}
