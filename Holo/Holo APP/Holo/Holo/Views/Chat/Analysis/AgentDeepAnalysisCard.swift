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
    /// 「继续追问」按钮回调；nil 或结果缺少身份时不展示该按钮（Phase 1）。
    var onContinueFollowUp: (() -> Void)? = nil

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
                if result.sections.isEmpty && result.recommendations?.isEmpty != false {
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
                            Text(cardEmptySubtitle(for: result.emptyReason))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.holoTextSecondary)
                            if let context = result.contextSourceText {
                                Text("本次读取：\(context)")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(.holoTextSecondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
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

                            Text(badgeText(for: result))
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(badgeColor(for: result))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(badgeBackground(for: result))
                                .clipShape(Capsule())
                        }

                        // 追问变化标签：追问结果在标题下展示「做了什么改变」。
                        if let changeTag = followUpChangeTag(for: result) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(changeTag)
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundColor(.holoTextSecondary)
                        }

                        if let scope = result.scope?.displayLabel {
                            Label(scope, systemImage: "calendar")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                        }

                        if let context = result.contextSourceText {
                            Label("本次读取：\(context)", systemImage: "brain.head.profile")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(2)
                        }

                        Text(directAnswer(result))
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundColor(.holoTextPrimary.opacity(0.88))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)

                        let titles = recommendationTitles(in: result)
                        if !titles.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(Array(titles.prefix(2).enumerated()), id: \.offset) { index, title in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white)
                                            .frame(width: 19, height: 19)
                                            .background(Color.holoPrimary)
                                            .clipShape(Circle())
                                        Text(title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.holoTextPrimary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }

                        if let coverage = result.coverageText, !coverage.isEmpty {
                            Label(coverage, systemImage: "checkmark.seal.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(2)
                        }
                    }

                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Text("查看完整分析")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.holoPrimary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.holoPrimary)
                        }
                        if canContinueFollowUp {
                            Spacer(minLength: 4)
                            Text("·")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.holoTextSecondary.opacity(0.5))
                            // 嵌在整卡 Button 内：用 simultaneousGesture 让点击不被外层吞掉，
                            // .buttonStyle(.plain) 去掉默认按钮视觉，保留我们自定义的文案样式。
                            Button {
                                onContinueFollowUp?()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("继续追问")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundColor(.holoTextSecondary)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded {
                                onContinueFollowUp?()
                            })
                        }
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }

    /// 结果携带完整身份（jobID + resultID）时才允许继续追问；
    /// 旧消息 JSON 缺身份字段，不可锚定。
    private var canContinueFollowUp: Bool {
        guard onContinueFollowUp != nil,
              let result = message.agentResult,
              result.agentJobID != nil, result.agentResultID != nil else {
            return false
        }
        return true
    }

    /// 卡片角标文案：追问结果优先展示追问关系标签。
    private func badgeText(for result: HoloRenderedAgentResult) -> String {
        if let meta = result.continuationMetadata, meta.isFollowUp {
            return meta.shortLabel
        }
        return hasRecommendations(result) ? "优化建议" : "深度分析"
    }

    private func badgeColor(for result: HoloRenderedAgentResult) -> Color {
        if result.continuationMetadata?.isFollowUp == true {
            return .holoTextSecondary
        }
        return .holoPrimary.opacity(0.8)
    }

    private func badgeBackground(for result: HoloRenderedAgentResult) -> Color {
        if result.continuationMetadata?.isFollowUp == true {
            return Color.holoTextSecondary.opacity(0.08)
        }
        return Color.holoPrimary.opacity(0.075)
    }

    /// 追问变化标签：根据 relation 生成「这次做了什么改变」的一句话。
    /// 非追问结果返回 nil（不展示）。
    private func followUpChangeTag(for result: HoloRenderedAgentResult) -> String? {
        guard let meta = result.continuationMetadata, meta.isFollowUp else { return nil }
        switch meta.relation {
        case .explain:           return "承接上文，进一步解释"
        case .drillDown:         return "深挖了细节"
        case .correct:           return "按纠正后的口径重新分析"
        case .changeScope:       return "已按新范围重新分析"
        case .crossDomain:       return "补充了新领域的数据"
        case .executeFromResult: return "从建议发起了行动"
        case .newTopic, .ambiguous: return nil
        }
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

    /// 卡片空状态副标题：简短区分两种空原因（详细文案见详情页）。
    private func cardEmptySubtitle(for reason: HoloAgentEmptyReason?) -> String {
        switch reason {
        case .unverifiable?:
            return "有数据，但结论未通过核验"
        case .noData?, nil:
            return "这次没有形成可信结论"
        }
    }

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

    private func hasRecommendations(_ result: HoloRenderedAgentResult) -> Bool {
        !recommendationTitles(in: result).isEmpty
    }

    private func recommendationTitles(in result: HoloRenderedAgentResult) -> [String] {
        if let recommendations = result.recommendations, !recommendations.isEmpty {
            return recommendations.map(\.title)
        }
        return result.sections.compactMap { section in
            let kind = section.kind?.lowercased() ?? ""
            return ["suggestion", "recommendation", "action"].contains(kind)
                ? section.title
                : nil
        }
    }
}
