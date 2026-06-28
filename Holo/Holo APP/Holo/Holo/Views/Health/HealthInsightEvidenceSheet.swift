//
//  HealthInsightEvidenceSheet.swift
//  Holo
//
//  健康洞察「为什么这么说」证据详情（方案 Task 8：每条生活闭环可点开查看证据）。
//  轻量展示洞察标题、摘要、建议、caveat 与引用的同源证据。
//

import SwiftUI

struct HealthInsightEvidenceSheet: View {
    let insight: GeneratedHealthInsight
    let evidence: [HealthInsightEvidence]
    @Environment(\.dismiss) private var dismiss

    private var referencedEvidence: [HealthInsightEvidence] {
        evidence.filter { insight.evidenceIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    Text(insight.title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(insight.summary)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let action = insight.suggestedAction {
                        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                            Text("一个可以试试的小动作")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextPrimary)
                            Text(action)
                                .font(.holoLabel)
                                .foregroundColor(.holoChart1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let caveat = insight.caveat {
                        Text(caveat)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }

                    if !referencedEvidence.isEmpty {
                        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                            Text("为什么这么说")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextPrimary)

                            ForEach(referencedEvidence) { ev in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ev.title)
                                        .font(.holoLabel)
                                        .foregroundColor(.holoTextPrimary)
                                    Text(ev.detail)
                                        .font(.holoTinyLabel)
                                        .foregroundColor(.holoTextSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(HoloSpacing.sm)
                                .background(Color.holoCardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                            }
                        }
                    }
                }
                .padding(HoloSpacing.md)
            }
            .navigationTitle("为什么这么说")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
