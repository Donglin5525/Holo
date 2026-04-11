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
            // 头部：图标 + 心情标签
            CardHeaderView(
                icon: "heart.fill",
                title: data.mood ?? "心情记录"
            )

            // 分隔线
            CardDivider()

            // 内容摘要（2 行截断）
            Text(data.content)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(2)

            // 底部
            CardFooterView(timeText: "刚刚")
        }
        .accessibilityLabel("心情卡片：\(data.mood ?? "心情记录")")
    }
}
