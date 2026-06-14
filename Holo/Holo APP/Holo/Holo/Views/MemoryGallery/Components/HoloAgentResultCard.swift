//
//  HoloAgentResultCard.swift
//  Holo
//
//  HoloAI Agent V3.1 — Phase 6.3 Agent 深度分析结果卡片
//  展示 verified claims（agentMemoryGalleryEnabled 灰度，由 MemoryGalleryViewModel 填充）。
//

import SwiftUI

struct HoloAgentResultCard: View {
    let result: HoloRenderedAgentResult

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.holoPrimary)
                Text(result.title)
                    .font(.headline)
                    .foregroundStyle(Color.holoPrimary)
            }

            if !result.summary.isEmpty {
                Text(result.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(result.sections.enumerated()), id: \.offset) { _, section in
                HStack(alignment: .top, spacing: HoloSpacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.holoPrimary)
                    Text(section.body)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }
}
