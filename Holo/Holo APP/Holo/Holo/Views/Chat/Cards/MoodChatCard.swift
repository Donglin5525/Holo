//
//  MoodChatCard.swift
//  Holo
//
//  心情记录卡片视图
//

import SwiftUI

struct MoodChatCard: View {

    let data: MoodCardData

    var body: some View {
        ChatCardView {
            CardHeaderView(
                icon: "heart.fill",
                title: data.mood ?? String(localized: "心情记录"),
                subtitle: String(localized: "刚刚记录")
            )

            HoloAIFactItem(kicker: String(localized: "记录内容"), bodyText: data.content, tint: .holoPrimary)

            CardFooterView(timeText: String(localized: "刚刚"), showsChevron: false)
        }
        .accessibilityLabel(String(localized: "心情卡片：\(data.mood ?? String(localized: "心情记录"))"))
    }
}
