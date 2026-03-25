//
//  TaskChips.swift
//  Holo
//
//  任务相关标签组件
//

import SwiftUI

/// 重复类型标签
struct RepeatTypeChip: View {
    let type: RepeatType
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(type.displayTitle)
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

/// 周几选择标签
struct WeekdayChip: View {
    let weekday: Weekday
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(weekday.shortDisplayTitle)
                .font(.holoCaption)
                .foregroundColor(isSelected ? .white : .holoTextPrimary)
                .frame(minWidth: 28)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    Circle()
                        .fill(isSelected ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.15))
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
