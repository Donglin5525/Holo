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

    private let accent = Color.holoPrimary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .fill(accent.opacity(0.12))
                    .frame(width: 42, height: 42)

                Image(systemName: data.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(accent)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(data.title)
                    .font(.holoHeading)
                    .fontWeight(.bold)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Text(data.description)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.10),
                            Color.holoCardBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(accent.opacity(0.20), lineWidth: 1)
        )
    }
}
