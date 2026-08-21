//
//  WeekNarrativeSheet.swift
//  Holo
//
//  周档高光/里程碑 Sheet（统一浏览方案 §8.6）：
//  周列表移除后叙事资产的承接位，复用 MilestoneNode / GentleHighlightNode 同一套渲染。
//

import SwiftUI

struct WeekNarrativeSheet: View {
    let highlights: [HighlightData]
    let milestones: [MilestoneData]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    if !milestones.isEmpty {
                        sectionTitle("本周里程碑")
                        ForEach(Array(milestones.enumerated()), id: \.offset) { _, data in
                            MilestoneNode(data: data)
                        }
                    }

                    if !highlights.isEmpty {
                        sectionTitle("本周高光")
                        ForEach(Array(highlights.enumerated()), id: \.offset) { _, data in
                            GentleHighlightNode(data: data)
                        }
                    }

                    if milestones.isEmpty && highlights.isEmpty {
                        Text("本周还没有值得标记的时刻。")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextPlaceholder)
                            .frame(maxWidth: .infinity)
                            .padding(.top, HoloSpacing.xl)
                    }
                }
                .padding(HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle("本周高光")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.holoTinyLabel)
            .foregroundColor(.holoTextSecondary)
    }
}
