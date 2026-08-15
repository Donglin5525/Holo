//
//  TaskChatCard.swift
//  Holo
//
//  任务卡片视图
//

import SwiftUI

struct TaskChatCard: View {

    let data: TaskCardData
    var isDeleted: Bool = false
    var onTap: (() -> Void)?
    var onConfirm: (() -> Void)?
    /// 取消（待确认/删除确认场景）：与确认按钮成对，避免「只能确认不能反悔」
    var onCancel: (() -> Void)?
    /// 「补充条目」：锚定该任务进入追加对话（仅已确认且持有 taskId 的卡片显示）
    var onFollowUp: (() -> Void)?

    var body: some View {
        ChatCardView(isDeleted: isDeleted, onTap: data.requiresConfirmation ? nil : onTap) {
            CardHeaderView(
                icon: headerIcon,
                title: headerTitle,
                badge: headerBadge,
                subtitle: data.requiresConfirmation ? data.title : footerText,
                isDeleted: isDeleted
            )

            if let description = data.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(3)
                    .strikethrough(isDeleted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isModifyMode && (!data.addItems.isEmpty || !data.removeItems.isEmpty) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(data.addItems.prefix(6).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.holoSuccess)
                                .padding(.top, 3)
                            Text(item)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoTextPrimary)
                                .lineLimit(2)
                        }
                    }
                    ForEach(Array(data.removeItems.prefix(6).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.holoError)
                                .padding(.top, 3)
                            Text(item)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoTextSecondary)
                                .strikethrough()
                                .lineLimit(2)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoTextSecondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if !data.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(data.subtasks.prefix(4).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .stroke(Color.holoTextSecondary.opacity(0.5), lineWidth: 1.3)
                                .frame(width: 10, height: 10)
                                .padding(.top, 4)
                            Text(item)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoTextPrimary)
                                .lineLimit(2)
                                .strikethrough(isDeleted)
                        }
                    }
                    if data.subtasks.count > 4 {
                        Text("还有 \(data.subtasks.count - 4) 项")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoTextSecondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if data.requiresConfirmation {
                VStack(alignment: .leading, spacing: 8) {
                    if data.isFailed, let error = data.confirmationError, !error.isEmpty {
                        Text(error)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.holoError)
                    }

                    HStack(spacing: 10) {
                        if data.isRecurring && !data.isFailed, let summary = data.repeatSummary {
                            HStack(spacing: 4) {
                                Image(systemName: "repeat")
                                    .font(.system(size: 10))
                                Text(summary)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.holoPrimary)
                        } else if !data.isFailed {
                            Text(footerText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.holoTextSecondary)
                        }

                        Spacer()

                        if !data.isFailed {
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

                        Button {
                            onConfirm?()
                        } label: {
                            Text(confirmButtonText)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(confirmButtonColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(data.isConfirming)
                    }
                }
            } else {
                HStack {
                    CardFooterView(timeText: footerText, isDeleted: isDeleted)
                    Spacer()
                    if canFollowUp {
                        Button {
                            onFollowUp?()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.bubble")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("补充条目")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.holoPrimary.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .accessibilityLabel("任务卡片：\(data.title)")
    }

    // MARK: - Formatting

    private var footerText: String {
        if let reminderDate = data.reminderDate, !reminderDate.isEmpty {
            return "提醒：\(reminderDate)"
        }
        if let dueDate = data.dueDate, !dueDate.isEmpty {
            return "日期：\(dueDate)"
        }
        return data.requiresConfirmation ? "待确认" : "今天"
    }

    // MARK: - Modify Mode Helpers

    private var isModifyMode: Bool { data.cardMode == .modify }
    private var isDeleteMode: Bool { data.cardMode == .delete }

    /// 已确认（非待确认态）、有真实任务 ID、未删除的卡片才能锚定补充
    private var canFollowUp: Bool {
        !data.requiresConfirmation && data.taskId != nil && !isDeleted
    }

    private var headerIcon: String {
        if data.requiresConfirmation {
            if isDeleteMode { return "trash.circle" }
            return isModifyMode ? "square.and.pencil" : "checklist.unchecked"
        }
        return "checkmark.circle"
    }

    private var headerTitle: String {
        if data.requiresConfirmation {
            if isDeleteMode { return "删除任务待确认" }
            if data.isFailed { return "处理失败" }
            return isModifyMode ? "修改待办" : "任务待确认"
        }
        if data.isCancelled { return "已取消" }
        return data.title
    }

    private var headerBadge: CardBadge? {
        if data.isCancelled {
            return CardBadge(text: "已取消", color: .holoTextSecondary)
        }
        if data.isConfirming {
            return CardBadge(text: "处理中", color: .holoTextSecondary)
        }
        if data.requiresConfirmation {
            if isDeleteMode { return CardBadge(text: "待删除", color: .holoError) }
            return CardBadge(text: isModifyMode ? "待修改" : "待确认", color: .holoPrimary)
        }
        return nil
    }

    private var confirmButtonText: String {
        if data.isConfirming { return "正在处理…" }
        if isDeleteMode { return "确认删除" }
        if data.isFailed { return "重试" }
        return isModifyMode ? "确认修改" : "确认创建"
    }

    private var confirmButtonColor: Color {
        if isDeleteMode { return .holoError }
        return .holoPrimary
    }
}
