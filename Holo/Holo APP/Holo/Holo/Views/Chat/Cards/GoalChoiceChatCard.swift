//
//  GoalChoiceChatCard.swift
//  Holo
//
//  目标歧义选择卡：多候选目标 N 选 1，点选即确认执行
//

import SwiftUI

struct GoalChoiceChatCard: View {

    let data: GoalChoiceCardData
    /// 点选候选目标（确认执行）
    var onSelect: ((GoalChoiceCandidate) -> Void)?
    /// 取消（不执行动作）
    var onCancel: (() -> Void)?

    var body: some View {
        // 选择中无整卡跳转语义，不包 onTap——候选行自身是按钮，避免嵌套不可点容器
        ChatCardView {
            CardHeaderView(
                icon: headerIcon,
                title: headerTitle,
                badge: headerBadge,
                subtitle: headerSubtitle
            )

            if data.requiresConfirmation {
                VStack(alignment: .leading, spacing: 8) {
                    if data.isFailed, let error = data.confirmationError, !error.isEmpty {
                        Text(error)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.holoError)
                    }

                    ForEach(data.candidates) { candidate in
                        candidateRow(candidate)
                    }

                    HStack {
                        Spacer()

                        Button {
                            onCancel?()
                        } label: {
                            Text("取消")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.holoTextSecondary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(data.isConfirming)
                    }
                }
            }
        }
        .accessibilityLabel("目标选择卡片：\(data.actionLabel)")
    }

    // MARK: - 候选行

    private func candidateRow(_ candidate: GoalChoiceCandidate) -> some View {
        Button {
            onSelect?(candidate)
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "target")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoPrimary)
                Text(candidate.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                Spacer()
                if data.isConfirming {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.holoTextSecondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(data.isConfirming)
    }

    // MARK: - 状态样式

    private var headerIcon: String {
        if data.isCancelled { return "target" }
        if !data.requiresConfirmation { return "checkmark.circle" }
        return data.isFailed ? "exclamationmark.circle" : "target"
    }

    private var headerTitle: String {
        if data.isCancelled { return "已取消" }
        if data.isFailed { return "处理失败" }
        if !data.requiresConfirmation {
            return data.selectedGoalTitle ?? "已完成"
        }
        return "选择目标"
    }

    private var headerSubtitle: String? {
        if data.isCancelled { return nil }
        if !data.requiresConfirmation { return "已\(data.actionLabel)" }
        if let subject = data.subjectTitle, !subject.isEmpty {
            return "要\(data.actionLabel)，请为「\(subject)」选择目标"
        }
        return "请选择一个目标"
    }

    private var headerBadge: CardBadge? {
        if data.isCancelled {
            return CardBadge(text: "已取消", color: .holoTextSecondary)
        }
        if data.isConfirming {
            return CardBadge(text: "处理中", color: .holoTextSecondary)
        }
        if !data.requiresConfirmation {
            return CardBadge(text: "已完成", color: .holoSuccess)
        }
        return CardBadge(text: data.isFailed ? "待重试" : "待选择", color: data.isFailed ? .holoError : .holoPrimary)
    }
}
