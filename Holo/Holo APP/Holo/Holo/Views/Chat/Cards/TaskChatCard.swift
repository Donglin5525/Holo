//
//  TaskChatCard.swift
//  Holo
//
//  任务卡片视图
//

import SwiftUI

struct TaskChatCard: View {

    let data: TaskCardData
    var onTap: (() -> Void)?

    var body: some View {
        ChatCardView(onTap: onTap) {
            // 头部：图标 + 标题
            CardHeaderView(
                icon: "checkmark.circle",
                title: data.title
            )

            // 分隔线
            CardDivider()

            // 底部：时间 + 操作入口
            CardFooterView(timeText: formattedDueDate)
        }
        .accessibilityLabel("任务卡片：\(data.title)")
    }

    // MARK: - Formatting

    private var formattedDueDate: String {
        if let dueDate = data.dueDate, !dueDate.isEmpty {
            return dueDate
        }
        return "今天"
    }
}
