//
//  AnalysisCompactChatCard.swift
//  Holo
//
//  Chat 中的分析结果紧凑入口卡片
//

import SwiftUI

struct AnalysisCompactChatCard: View {

    let message: ChatMessageViewData
    var onTap: (() -> Void)? = nil

    var body: some View {
        if message.isStreaming {
            // 流式分析中：显示 loading 卡片
            loadingCard
        } else if message.metadataState == .loaded, let context = message.analysisContext,
                  let summary = AnalysisSummaryFormatter.format(from: context) {
            // 真实紧凑卡片
            realCard(summary: summary)
        } else if message.metadataState == .unloaded || message.metadataState == .loading {
            // 占位态
            placeholderCard
        }
        // .loaded 但 analysisContext == nil → 不渲染（退化为普通气泡，由 MessageBubbleView 处理）
    }

    // MARK: - Real Card

    private func realCard(summary: AnalysisCompactSummary) -> some View {
        Button {
            onTap?()
        } label: {
            ChatCardView {
                CardHeaderView(
                    icon: summary.icon,
                    title: summary.displayTitle,
                    subtitle: summary.subtitle
                )

                HoloAIHeroMetric(
                    label: summary.primaryLabel,
                    value: summary.primaryValue,
                    note: summary.secondarySummary,
                    tint: .holoTextPrimary
                )

                HStack(spacing: 6) {
                    Text("点击查看详细分析")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }

    // MARK: - Loading Card（流式分析中）

    private var loadingCard: some View {
        ChatCardView {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("AI 正在分析中...")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Placeholder

    private var placeholderCard: some View {
        ChatCardView {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 16))
                    .foregroundColor(.holoTextSecondary)
                Text("分析结果加载中...")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .allowsHitTesting(false)
    }
}

private extension AnalysisCompactSummary {
    var displayTitle: String {
        title.components(separatedBy: " · ").first ?? title
    }

    var primaryLabel: String {
        let parts = summaryLine.components(separatedBy: " · ")
        guard let first = parts.first else { return "摘要" }
        let tokens = first.components(separatedBy: " ")
        return tokens.first ?? "摘要"
    }

    var primaryValue: String {
        let parts = summaryLine.components(separatedBy: " · ")
        guard let first = parts.first else { return summaryLine }
        let tokens = first.components(separatedBy: " ")
        guard tokens.count > 1 else { return first }
        return tokens.dropFirst().joined(separator: " ")
    }

    var secondarySummary: String {
        let parts = summaryLine.components(separatedBy: " · ")
        return parts.dropFirst().joined(separator: " · ")
    }
}
