//
//  ReminderChip.swift
//  Holo
//
//  提醒时间选择标签组件
//

import SwiftUI

/// 提醒标签
struct ReminderChip: View {
    let reminder: TaskReminder
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(reminder.displayTitle)
                .font(.holoCaption)
                .foregroundColor(isSelected ? .white : .holoTextPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.15))
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
