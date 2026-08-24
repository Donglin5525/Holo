//
//  AnniversaryChatCard.swift
//  Holo
//
//  纪念日创建卡片视图（名称/日期经确认后创建，点击已创建卡跳纪念日详情）
//

import SwiftUI

struct AnniversaryChatCard: View {

    let data: AnniversaryChatCardData
    var isDeleted: Bool = false
    var onTap: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        ChatCardView(isDeleted: isDeleted, onTap: data.requiresConfirmation || data.isCancelled ? nil : onTap) {
            CardHeaderView(
                icon: data.icon,
                title: headerTitle,
                badge: badge,
                subtitle: data.typeDisplayName,
                isDeleted: isDeleted
            )

            // 日期
            if let date = data.displayDate {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11))
                    Text(date)
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.holoTextPrimary)
                .strikethrough(isDeleted)
            }

            if data.requiresConfirmation {
                pendingActions
            } else if data.isCancelled {
                cancelledInfo
            } else if data.isFailed {
                failedInfo
            } else {
                CardFooterView(timeText: "查看纪念日", isDeleted: isDeleted)
            }
        }
        .accessibilityLabel("纪念日卡片：\(data.title)，\(data.displayDate ?? "")")
    }

    // MARK: - Header

    private var headerTitle: String {
        if data.requiresConfirmation {
            return "纪念日待确认"
        }
        return data.title
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
                Text(data.isConfirming ? "正在创建…" : "确认")
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
            Text("已取消，未创建")
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
