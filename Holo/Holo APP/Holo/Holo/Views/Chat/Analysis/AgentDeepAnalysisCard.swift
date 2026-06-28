//
//  AgentDeepAnalysisCard.swift
//  Holo
//
//  Agent 深度分析结果的紧凑入口卡片（四态：loading / loaded / unloaded / degrade）
//  复用 ChatCardView / CardHeaderView / HoloAIHeroMetric / CardButtonStyle
//

import SwiftUI

struct AgentDeepAnalysisCard: View {

    let message: ChatMessageViewData
    var onTap: (() -> Void)? = nil

    var body: some View {
        if message.isStreaming {
            // 分析中：loading 卡片
            loadingCard
        } else if message.metadataState == .loaded, let result = message.agentResult {
            // 已加载且有结果：真实卡片
            realCard(result: result)
        } else if message.metadataState == .unloaded || message.metadataState == .loading {
            // 元数据加载中：占位
            placeholderCard
        }
        // .loaded 但 agentResult == nil → 不渲染（退化文本气泡，由 MessageBubbleView 处理）
    }

    // MARK: - Real Card

    private func realCard(result: HoloRenderedAgentResult) -> some View {
        Button {
            onTap?()
        } label: {
            ChatCardView {
                CardHeaderView(
                    icon: "sparkles",
                    title: result.title,
                    subtitle: primarySummary(result)
                )

                if let first = result.sections.first {
                    HoloAIHeroMetric(
                        label: "核心观察",
                        value: first.title,
                        note: first.body,
                        tint: .holoTextPrimary
                    )
                }

                HStack(spacing: 6) {
                    Text("查看深度分析")
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

    // MARK: - Loading Card

    private var loadingCard: some View {
        ChatCardView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Holo 正在深度分析中…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                }

                Text("建议先停留在当前界面；切到后台后 Holo 会短时间继续尝试，系统收回后台时间时可能暂停，回到 App 后会继续。")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Placeholder

    private var placeholderCard: some View {
        ChatCardView {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundColor(.holoTextSecondary)
                Text("分析结果加载中…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Helpers

    private func primarySummary(_ result: HoloRenderedAgentResult) -> String {
        let count = result.sections.count
        if result.summary.isEmpty {
            return count > 0 ? "共 \(count) 条观察" : "本期暂无显著观察"
        }
        return result.summary
    }
}
