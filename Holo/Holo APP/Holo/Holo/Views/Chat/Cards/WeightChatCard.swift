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
                subtitle: ""
            )

            HoloAIHeroMetric(
                label: "当前体重",
                value: "\(data.weight) \(data.unit)",
                tint: .holoTextPrimary
            )

            CardFooterView(timeText: "")
        }
        .accessibilityLabel("体重卡片：\(data.weight) \(data.unit)")
    }
}
