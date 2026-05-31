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

    var body: some View {
        ChatCardView(isDeleted: isDeleted, onTap: data.requiresConfirmation ? nil : onTap) {
            CardHeaderView(
                icon: data.requiresConfirmation ? "checklist.unchecked" : "checkmark.circle",
                title: data.requiresConfirmation ? "任务待确认" : data.title,
                badge: data.requiresConfirmation ? CardBadge(text: "待确认", color: .holoPrimary) : nil,
                subtitle: data.requiresConfirmation ? data.title : footerText
            )

            if let description = data.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !data.subtasks.isEmpty {
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
                    Text(footerText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Spacer()

                    Button {
                        onConfirm?()
                    } label: {
                        Text("确认创建")
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
                CardFooterView(timeText: footerText)
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
}
