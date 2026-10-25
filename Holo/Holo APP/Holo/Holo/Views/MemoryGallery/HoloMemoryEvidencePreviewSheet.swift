//
//  HoloMemoryEvidencePreviewSheet.swift
//  Holo
//
//  记忆出处预览弹层（记忆长廊与记忆中心详情页共用）。
//
//  无详情页可直达（或原始记录已删除）的证据走这里：按域回查原始记录现场原文，
//  存量证据未保存摘要时由 HoloMemoryEvidenceSourceLookup.liveText 兜底。
//

import SwiftUI

struct HoloMemoryEvidencePreviewSheet: View {
    let evidence: HoloMemoryEvidenceRef
    @State private var liveEvidenceText: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    Label(
                        "\(evidence.sourceDomain.userFacingName) · \(HoloMemoryEvidencePreviewSheet.evidenceTitle(evidence.kind))",
                        systemImage: HoloMemoryEvidencePreviewSheet.evidenceIcon(evidence.kind)
                    )
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimary)

                    Text(previewBody)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("观察时间：\(evidence.observedAt.formatted(.dateTime.year().month().day()))")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)

                    Text(evidence.kind == .explicitUserStatement
                         ? "这是你在对话里明确表达过的内容，Holo 据此形成了这条记忆。"
                         : "这是 Holo 形成这条记忆时依据的原始记录。")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(HoloSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("记忆出处")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task(id: evidence.id) {
                liveEvidenceText = nil
                liveEvidenceText = await HoloMemoryEvidenceSourceLookup.liveText(for: evidence)
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 存量证据未保存摘要时按 sourceID 回查原文；查不到（已删除/不存在）才落占位文案。
    private var previewBody: String {
        if let summary = evidence.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        if let liveEvidenceText, !liveEvidenceText.isEmpty {
            return liveEvidenceText
        }
        return "原始记录已删除，无法显示当时的原文。"
    }

    // MARK: - 域文案（与记忆长廊详情页一致的口径）

    static func evidenceTitle(_ kind: HoloMemoryEvidenceKind) -> String {
        switch kind {
        case .entityRef: return "具体记录"
        case .aggregateSnapshot: return "一段时间的汇总"
        case .explicitUserStatement: return "你明确说过的内容"
        }
    }

    static func evidenceIcon(_ kind: HoloMemoryEvidenceKind) -> String {
        switch kind {
        case .entityRef: return "doc.text"
        case .aggregateSnapshot: return "chart.bar"
        case .explicitUserStatement: return "person.crop.circle.badge.checkmark"
        }
    }
}
