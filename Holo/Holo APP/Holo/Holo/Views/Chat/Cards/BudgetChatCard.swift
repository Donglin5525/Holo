//
//  BudgetChatCard.swift
//  Holo
//
//  预算设置卡片视图（总预算/分类预算，经确认后生效）
//

import SwiftUI

struct BudgetChatCard: View {

    let data: BudgetChatCardData
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        // 预算无独立详情页：整卡不可点，避免「可点但无动作」的假交互
        ChatCardView(isDeleted: false, onTap: nil) {
            CardHeaderView(
                icon: data.isCategoryBudget ? "folder" : "yensign.circle",
                title: headerTitle,
                badge: badge,
                subtitle: headerSubtitle
            )

            // 金额 + 周期
            VStack(alignment: .leading, spacing: 4) {
                Text("¥\(data.amount)")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.holoPrimary)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)

                Text("\(data.periodLabel)预算上限")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if data.requiresConfirmation {
                pendingActions
            } else if data.isCancelled {
                cancelledInfo
            } else if data.isFailed {
                failedInfo
            }
        }
        .accessibilityLabel("预算卡片：\(data.scopeTitle)，\(data.periodLabel)\(data.amount)元")
    }

    // MARK: - Header

    private var headerTitle: String {
        if data.requiresConfirmation {
            return data.isCategoryBudget ? "分类预算待确认" : "总预算待确认"
        }
        return data.scopeTitle
    }

    private var headerSubtitle: String? {
        if data.requiresConfirmation {
            return data.scopeTitle
        }
        return nil
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
            .disabled(data.isConfirming)

            Button {
                onConfirm?()
            } label: {
                Text(data.isConfirming ? "正在设置…" : "确认")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(data.isConfirming ? Color.holoPrimary.opacity(0.5) : Color.holoPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(data.isConfirming)
        }
    }

    // MARK: - Cancelled State

    private var cancelledInfo: some View {
        HStack {
            Text("已取消，预算未改动")
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
}
