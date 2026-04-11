//
//  HabitCheckInChatCard.swift
//  Holo
//
//  习惯打卡卡片视图
//

import SwiftUI

struct HabitCheckInChatCard: View {

    let data: HabitCheckInCardData
    var onTap: (() -> Void)?

    var body: some View {
        ChatCardView(onTap: onTap) {
            // 头部：图标 + 习惯名 + 打卡勾
            CardHeaderView(
                icon: "flame.fill",
                title: data.habitName,
                badge: data.completed
                    ? CardBadge(text: "已完成", color: .holoSuccess)
                    : nil
            )

            // 分隔线
            CardDivider()

            // 连续天数
            if let streak = data.streak {
                Text("连续打卡 \(streak) 天")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            // 底部
            CardFooterView(timeText: "今天")
        }
        .accessibilityLabel("打卡卡片：\(data.habitName)\(data.completed ? "，已完成" : "")")
    }
}
