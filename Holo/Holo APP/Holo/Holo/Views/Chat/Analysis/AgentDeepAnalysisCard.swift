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
                if result.sections.isEmpty {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.holoPrimary.opacity(0.10))
                                .frame(width: 48, height: 48)
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.holoPrimary.opacity(0.72))
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text(result.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.holoTextPrimary)
                            Text("这次没有形成可信结论")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack(spacing: 9) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.holoPrimary)
                                .frame(width: 30, height: 30)
                                .background(Color.holoPrimary.opacity(0.11))
                                .clipShape(Circle())

                            Text(result.headline ?? result.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.holoTextPrimary)
                                .lineLimit(2)

                            Spacer(minLength: 8)

                            Text("深度分析")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(.holoPrimary.opacity(0.8))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Color.holoPrimary.opacity(0.075))
                                .clipShape(Capsule())
                        }

                        Text(directAnswer(result))
                            .font(.system(size: 21, weight: .heavy))
                            .foregroundColor(.holoTextPrimary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)

                        if let coverage = result.coverageText, !coverage.isEmpty {
                            Label(coverage, systemImage: "checkmark.seal.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(2)
                        }
                    }

                    HStack(spacing: 6) {
                        Text("查看完整分析")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }

    // MARK: - Loading Card

    private var loadingCard: some View {
        let status = HoloAgentChatStatusPresenter.display(from: message.content)
        return ChatCardView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if status.showsActivityIndicator {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "pause.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                    }
                    Text(status.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                }

                Text(status.detail)
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
            return count > 0 ? "共 \(count) 条观察" : "这次没有形成可信结论"
        }
        return result.summary
    }

    private func directAnswer(_ result: HoloRenderedAgentResult) -> String {
        if let answer = result.directAnswer?.trimmingCharacters(in: .whitespacesAndNewlines),
           !answer.isEmpty {
            return answer
        }
        if let first = result.sections.first?.body.trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            return first
        }
        return primarySummary(result)
    }
}
