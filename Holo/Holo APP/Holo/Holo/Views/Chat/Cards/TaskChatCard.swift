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
    /// 「补充条目」：锚定该任务进入追加对话（仅已确认且持有 taskId 的卡片显示）
    var onFollowUp: (() -> Void)?

    var body: some View {
        ChatCardView(isDeleted: isDeleted, onTap: data.requiresConfirmation ? nil : onTap) {
            CardHeaderView(
                icon: headerIcon,
                title: headerTitle,
                badge: data.requiresConfirmation
                    ? CardBadge(text: isModifyMode ? "待修改" : "待确认", color: .holoPrimary)
                    : nil,
                subtitle: data.requiresConfirmation ? data.title : footerText
            )

            if let description = data.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(3)
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
                HStack(spacing: 10) {
                    if data.isRecurring, let summary = data.repeatSummary {
                        HStack(spacing: 4) {
                            Image(systemName: "repeat")
                                .font(.system(size: 10))
                            Text(summary)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.holoPrimary)
                    } else {
                        Text(footerText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()

                    Button {
                        onConfirm?()
                    } label: {
                        Text(isModifyMode ? "确认修改" : "确认创建")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.holoPrimary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack {
                    CardFooterView(timeText: footerText)
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

    /// 已确认（非待确认态）、有真实任务 ID、未删除的卡片才能锚定补充
    private var canFollowUp: Bool {
        !data.requiresConfirmation && data.taskId != nil && !isDeleted
    }

    private var headerIcon: String {
        if data.requiresConfirmation {
            return isModifyMode ? "square.and.pencil" : "checklist.unchecked"
        }
        return "checkmark.circle"
    }

    private var headerTitle: String {
        if data.requiresConfirmation {
            return isModifyMode ? "修改待办" : "任务待确认"
        }
        return data.title
    }
}
