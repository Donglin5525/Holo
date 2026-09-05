//
//  WeightChatCard.swift
//  Holo
//
//  体重记录卡片视图
//

import SwiftUI

struct WeightChatCard: View {

    let data: WeightCardData

    var body: some View {
        ChatCardView {
            CardHeaderView(
                icon: "scalemass.fill",
                title: String(localized: "体重记录"),
                subtitle: String(localized: "刚刚记录")
            )

            HoloAIHeroMetric(
                label: String(localized: "当前体重"),
                value: "\(data.weight) \(data.unit)",
                tint: .holoTextPrimary
            )

            CardFooterView(timeText: String(localized: "刚刚"), showsChevron: false)
        }
        .accessibilityLabel(String(localized: "体重卡片：\(data.weight) \(data.unit)"))
    }
}
