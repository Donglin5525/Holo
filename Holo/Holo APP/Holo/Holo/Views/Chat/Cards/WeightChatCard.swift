//
//  WeightChatCard.swift
//  Holo
//
//  体重记录卡片视图
//

import SwiftUI

struct WeightChatCard: View {

    let data: WeightCardData
    var onTap: (() -> Void)?

    var body: some View {
        ChatCardView(onTap: onTap) {
            CardHeaderView(
                icon: "scalemass.fill",
                title: "体重记录",
                subtitle: "刚刚记录"
            )

            HoloAIHeroMetric(
                label: "当前体重",
                value: "\(data.weight) \(data.unit)",
                tint: .holoTextPrimary
            )

            CardFooterView(timeText: "刚刚")
        }
        .accessibilityLabel("体重卡片：\(data.weight) \(data.unit)")
    }
}
