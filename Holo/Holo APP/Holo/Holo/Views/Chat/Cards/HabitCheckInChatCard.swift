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
            CardHeaderView(
                icon: "flame.fill",
                title: data.habitName,
                badge: data.completed
                    ? CardBadge(text: "已完成", color: .holoSuccess)
                    : nil,
                subtitle: "习惯打卡"
            )

            if let streak = data.streak {
                HoloAIHeroMetric(
                    label: "连续打卡",
                    value: "\(streak) 天",
                    note: data.completed ? "今天已完成" : nil,
                    tint: .holoSuccess
                )
            } else if data.completed {
                HoloAIFactItem(kicker: "今日状态", bodyText: "已完成今天的打卡。", tint: .holoSuccess)
            }

            CardFooterView(timeText: "今天")
        }
        .accessibilityLabel("打卡卡片：\(data.habitName)\(data.completed ? "，已完成" : "")")
    }
}
