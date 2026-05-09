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
            VStack(alignment: .leading, spacing: 8) {
                // 标题行
                HStack(spacing: 6) {
                    Image(systemName: summary.icon)
                        .font(.system(size: 16))
                        .foregroundColor(.holoPrimary)
                    Text(summary.title)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                }

                // 摘要行
                Text(summary.summaryLine)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                // 提示行
                HStack(spacing: 4) {
                    Text("点击查看详细分析")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                }
            }
            .padding(HoloSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        }
        .buttonStyle(CardButtonStyle())
    }

    // MARK: - Loading Card（流式分析中）

    private var loadingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("AI 正在分析中...")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .allowsHitTesting(false)
    }

    // MARK: - Placeholder

    private var placeholderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 16))
                    .foregroundColor(.holoTextSecondary)
                Text("分析结果加载中...")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .allowsHitTesting(false)
    }
}
