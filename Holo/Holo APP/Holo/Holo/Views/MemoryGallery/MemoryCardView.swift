//
//  MemoryCardView.swift
//  Holo
//
//  记忆卡片视图（开发中）
//

import SwiftUI

/// 记忆卡片视图（占位）
struct MemoryCardView: View {
    let memory: MemoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            // 类型图标
            HStack {
                Image(systemName: memory.type.icon)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: memory.colorHex) ?? .holoPrimary)

                Text(memory.type.displayName)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                Text(memory.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            // 标题
            Text(memory.title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2)

            // 副标题（如果有）
            if let subtitle = memory.subtitle {
                Text(subtitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }
}
