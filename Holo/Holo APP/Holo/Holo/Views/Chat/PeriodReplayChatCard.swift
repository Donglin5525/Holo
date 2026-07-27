//
//  PeriodReplayChatCard.swift
//  Holo
//
//  周期回放洞察在聊天消息流里的卡片（从记忆长廊迁移而来）
//  复用 MemoryInsightCardView 的卡片视觉，支持 loading / loaded / failed 三态
//

import SwiftUI

struct PeriodReplayChatCard: View {
    let message: ChatMessageViewData
    var onExpansionChanged: ((Bool) -> Void)? = nil

    @State private var isExpanded = false

    var body: some View {
        if let payload = message.insightResult {
            realCard(payload: payload)
        } else if message.isStreaming || message.periodReplayJob != nil {
            statusCard
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        let job = message.periodReplayJob
        let isFailed = job?.state == .failed

        return ChatCardView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    if isFailed {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title2)
                            .foregroundColor(.holoPrimary)
                    } else {
                        ProgressView()
                            .tint(.holoPrimary)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(isFailed ? "回放还没有生成完整" : "Holo 正在生成回放")
                            .font(.headline)
                            .foregroundColor(.holoTextPrimary)
                        Text(job?.statusText ?? "正在回顾这段时间的记录…")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                if isFailed {
                    Button {
                        HoloPeriodReplayCoordinator.shared.continueGeneration(messageId: message.id)
                    } label: {
                        Label("继续生成", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.holoPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Real Card

    private func realCard(payload: MemoryInsightPayload) -> some View {
        ChatCardView {
            VStack(alignment: .leading, spacing: 14) {
                // 标题 + 摘要
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.holoPrimary)
                            .frame(width: 28, height: 28)
                            .background(Color.holoPrimary.opacity(0.09))
                            .clipShape(Circle())
                            .padding(.top, 1)

                        Text(displayText(payload.title))
                            .font(.headline)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)
                    }

                    if !payload.summary.isEmpty {
                        Text(displayText(payload.summary))
                            .font(.body)
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(isExpanded ? nil : 5)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // 默认展示洞察目录；展开后补充正文与证据。
                if !payload.cards.isEmpty {
                    Divider()
                        .opacity(0.5)

                    VStack(alignment: .leading, spacing: isExpanded ? 16 : 11) {
                        ForEach(Array(payload.cards.enumerated()), id: \.offset) { index, card in
                            insightCardRow(card, showsDetail: isExpanded)

                            if index < payload.cards.count - 1 {
                                Divider()
                                    .opacity(isExpanded ? 0.35 : 0.22)
                            }
                        }
                    }
                }

                if isExpanded && !payload.suggestedQuestions.isEmpty {
                    Divider()
                        .opacity(0.5)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("你还可以继续问")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.holoTextSecondary)
                        ForEach(payload.suggestedQuestions.prefix(3), id: \.self) { question in
                            Text("· \(displayText(question))")
                                .font(.subheadline)
                                .foregroundColor(.holoTextPrimary)
                                .lineSpacing(3)
                        }
                    }
                }

                // 卡片外壳没有点击行为，可以安全使用 Button，避免 ScrollView 内裸手势残留命中状态。
                if !payload.cards.isEmpty {
                    Button {
                        let nextValue = !isExpanded
                        withAnimation(.easeInOut(duration: 0.22)) {
                            isExpanded = nextValue
                        }
                        onExpansionChanged?(nextValue)
                    } label: {
                        HStack(spacing: 5) {
                            Text(isExpanded ? "收起详细内容" : "展开 \(payload.cards.count) 张洞察")
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .foregroundColor(.holoPrimary)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Insight Card Row

    private func insightCardRow(_ card: MemoryInsightCard, showsDetail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: cardIcon(for: card.type))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(cardIconColor(for: card.type))
                    .frame(width: 24, height: 24)
                    .background(cardIconColor(for: card.type).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                    .padding(.top, 1)

                Text(displayText(card.title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.holoTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsDetail {
                Text(displayText(card.body))
                    .font(.subheadline)
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsDetail && !card.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(card.evidence.prefix(2).enumerated()), id: \.offset) { _, evidence in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(Color.holoTextSecondary.opacity(0.55))
                                .frame(width: 3, height: 3)
                                .padding(.top, 6)

                            Text(displayText(evidence.label))
                                .font(.caption)
                                .foregroundColor(.holoTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Card Style Helpers

    private func cardIcon(for type: MemoryInsightCardType) -> String {
        switch type {
        case .habit: return "figure.run"
        case .finance: return "yensign.circle"
        case .task: return "checkmark.circle"
        case .thought: return "bubble.left"
        case .milestone: return "flag.fill"
        case .crossDomain: return "point.3.connected.trianglepath.dotted"
        case .overview: return "circle.grid.2x2"
        case .anomaly: return "eye.fill"
        }
    }

    private func cardIconColor(for type: MemoryInsightCardType) -> Color {
        switch type {
        case .habit: return .holoPrimary
        case .finance: return .holoPrimary
        case .task: return .green
        case .thought: return .purple
        case .milestone: return .orange
        case .crossDomain: return .blue
        case .overview: return .holoTextSecondary
        case .anomaly: return .orange
        }
    }

    /// 生成结果会携带 warning/critical 等内部严重级别；用户只需要看到事实本身。
    private func displayText(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\s*[\(\[（【]?\s*(?:warning|waring|critical)\s*[\)\]）】]?"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
