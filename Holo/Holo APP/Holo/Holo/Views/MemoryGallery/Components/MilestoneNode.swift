//
//  MilestoneNode.swift
//  Holo
//
//  里程碑卡片 — 重大成就
//  金色渐变背景 + 菱形标记 + 光晕
//

import SwiftUI

struct MilestoneNode: View {
    let data: MilestoneData

    /// 金色渐变起始色
    private let goldStart = Color(hex: "F59E0B")
    /// 金色渐变终止色
    private let goldEnd = Color(hex: "FDE68A")

    var body: some View {
        HStack(spacing: 12) {
            Text(data.icon)
                .font(.system(size: 28))

            VStack(alignment: .leading, spacing: 3) {
                Text(data.title)
                    .font(.holoHeading)
                    .fontWeight(.bold)
                    .foregroundColor(goldEnd)

                Text(data.description)
                    .font(.holoCaption)
                    .foregroundColor(goldEnd.opacity(0.55))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(
                    LinearGradient(
                        colors: [
                            goldStart.opacity(0.12),
                            goldStart.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(goldStart.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: goldStart.opacity(0.15), radius: 8, x: 0, y: 2)
        .padding(.leading, 8) // 菱形标记偏移
    }
}
