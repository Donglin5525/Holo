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
            // 头部
            CardHeaderView(
                icon: "scalemass.fill",
                title: "体重记录"
            )

            // 分隔线
            CardDivider()

            // 体重数值
            Text("\(data.weight) \(data.unit)")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            // 底部
            CardFooterView(timeText: "刚刚")
        }
        .accessibilityLabel("体重卡片：\(data.weight) \(data.unit)")
    }
}
