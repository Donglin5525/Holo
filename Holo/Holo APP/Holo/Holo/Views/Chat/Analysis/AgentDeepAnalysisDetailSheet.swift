//
//  AgentDeepAnalysisDetailSheet.swift
//  Holo
//
//  Agent 深度分析详情 Sheet：核心结论 + 观察段（每条 claim）+ 数据依据段
//  复用 HoloAIFactItem / HoloAISectionLabel / MarkdownAttributedStringRenderer
//

import SwiftUI

struct AgentDeepAnalysisDetailSheet: View {

    let result: HoloRenderedAgentResult
    var onFinanceDrilldown: ((HoloRenderedFinanceDrilldown) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                coreConclusion
                factsSection
                evidenceSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 34)
        }
        .background(Color.holoBackground)
        .presentationDetents([.medium, .large])
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 38, height: 38)
                    .background(Color.holoPrimary.opacity(0.12))
                    .clipShape(Circle())
                Text("深度分析")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
            }
            Text(result.title)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - Core Conclusion

    private var coreConclusion: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("核心结论")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.holoPrimary)
                .tracking(0.6)

            Text(result.summary.isEmpty ? "本期暂无显著观察" : result.summary)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.holoPrimary.opacity(0.10), Color.holoCardBackground],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.13), lineWidth: 1)
        )
    }

    // MARK: - Facts Section（每条 claim 一项）

    @ViewBuilder
    private var factsSection: some View {
        if !result.sections.isEmpty {
            HoloAISectionLabel(text: "观察")
            VStack(spacing: 12) {
                ForEach(Array(result.sections.enumerated()), id: \.offset) { _, section in
                    HoloAIFactItem(kicker: section.title, bodyText: section.body)
                }
            }
        }
    }

    // MARK: - Evidence Section

    @ViewBuilder
    private var evidenceSection: some View {
        if !result.evidenceReferences.isEmpty {
            HoloAISectionLabel(text: "数据依据")
            VStack(spacing: 10) {
                ForEach(Array(result.evidenceReferences.enumerated()), id: \.offset) { _, ref in
                    if let drilldown = ref.financeDrilldown {
                        Button {
                            dismiss()
                            onFinanceDrilldown?(drilldown)
                        } label: {
                            HoloAIFactItem(kicker: "依据 · 点按核对", bodyText: ref.summary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        HoloAIFactItem(kicker: "依据", bodyText: ref.summary)
                    }
                }
            }
        }
    }
}
