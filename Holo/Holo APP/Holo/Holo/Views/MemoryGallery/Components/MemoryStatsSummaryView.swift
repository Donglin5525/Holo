//
//  MemoryStatsSummaryView.swift
//  Holo
//
//  记忆长廊顶部全量统计概览
//

import SwiftUI

struct MemoryStatsSummaryView: View {
    let memoryCount: Int
    let recordedDays: Int
    let insightCount: Int

    var body: some View {
        HStack(spacing: 0) {
            statColumn(value: memoryCount, label: "记忆")
            statColumn(value: recordedDays, label: "记录")
            statColumn(value: insightCount, label: "洞察")
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.lg)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    private func statColumn(value: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text(formatCount(value))
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 10_000 {
            let compact = Double(value) / 10_000
            return String(format: "%.1f万", compact)
        }
        return "\(value)"
    }
}

#Preview {
    MemoryStatsSummaryView(memoryCount: 128, recordedDays: 45, insightCount: 0)
        .padding()
        .background(Color.holoBackground)
}
