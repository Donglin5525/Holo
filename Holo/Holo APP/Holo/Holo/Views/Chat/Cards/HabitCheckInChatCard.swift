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
        ChatRecordReceiptRow(
            title: data.habitName,
            value: data.recordedValue ?? (data.completed ? String(localized: "已打卡") : String(localized: "已取消")),
            isStatus: data.recordedValue == nil
        )
    }
}
