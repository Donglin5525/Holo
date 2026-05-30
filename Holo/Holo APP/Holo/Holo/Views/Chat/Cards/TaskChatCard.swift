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
            // 头部：图标 + 标题
            CardHeaderView(
                icon: data.requiresConfirmation ? "checklist.unchecked" : "checkmark.circle",
                title: data.title
            )

            if let description = data.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !data.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(data.subtasks, id: \.self) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "circle")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.holoTextSecondary)
                            Text(item)
                                .font(.system(size: 13))
                                .foregroundColor(.holoTextPrimary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 分隔线
            CardDivider()

            // 底部：时间 + 操作入口
            if data.requiresConfirmation {
                HStack(spacing: 10) {
                    Text(footerText)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)

                    Spacer()

                    Button {
                        onConfirm?()
                    } label: {
                        Text("确认创建")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.holoPrimary)
                            .cornerRadius(8)
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
