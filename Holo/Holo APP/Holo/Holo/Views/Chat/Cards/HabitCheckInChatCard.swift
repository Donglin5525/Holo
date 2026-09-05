//
//  HabitCheckInChatCard.swift
//  Holo
//
//  习惯打卡卡片视图
//

import SwiftUI

struct HabitCheckInChatCard: View {

    let data: HabitCheckInCardData

    var body: some View {
        ChatCardView {
            CardHeaderView(
                icon: "flame.fill",
                title: data.habitName,
                badge: data.completed
                    ? CardBadge(text: String(localized: "已完成"), color: .holoSuccess)
                    : nil,
                subtitle: String(localized: "习惯打卡")
            )

            if let streak = data.streak {
                HoloAIHeroMetric(
                    label: String(localized: "连续打卡"),
                    value: String(localized: "\(streak) 天"),
                    note: data.completed ? String(localized: "今天已完成") : nil,
                    tint: .holoSuccess
                )
            } else if data.completed {
                HoloAIFactItem(kicker: String(localized: "今日状态"), bodyText: String(localized: "已完成今天的打卡。"), tint: .holoSuccess)
            }

            CardFooterView(timeText: String(localized: "今天"), showsChevron: false)
        }
        .accessibilityLabel(String(localized: "打卡卡片：\(data.habitName)\(data.completed ? "，已完成" : "")"))
    }
}
