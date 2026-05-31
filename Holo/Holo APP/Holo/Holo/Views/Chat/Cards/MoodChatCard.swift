//
//  MoodChatCard.swift
//  Holo
//
//  心情记录卡片视图
//

import SwiftUI

struct MoodChatCard: View {

    let data: MoodCardData
    var onTap: (() -> Void)?

    var body: some View {
        ChatCardView(onTap: onTap) {
            CardHeaderView(
                icon: "heart.fill",
                title: data.mood ?? "心情记录",
                subtitle: "刚刚记录"
            )

            HoloAIFactItem(kicker: "记录内容", bodyText: data.content, tint: .holoPrimary)

            CardFooterView(timeText: "刚刚")
        }
        .accessibilityLabel("心情卡片：\(data.mood ?? "心情记录")")
    }
}
