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
        ChatRecordReceiptRow(
            title: String(localized: "体重记录"),
            value: "\(data.weight) \(data.unit)"
        )
    }
}
