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
    var thoughtLog: [HoloThoughtEvent]? = nil
    var onTap: (() -> Void)? = nil

    /// loading 卡片是否展开思考日志（点击卡片切换；无日志时不响应）
    @State private var isThoughtExpanded = false

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
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.holoPrimary)
                                .frame(width: 30, height: 30)
                                .background(Color.holoPrimary.opacity(0.11))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 6) {
                                Text(result.headline ?? result.title)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.holoTextPrimary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)

                                Text(hasRecommendations(result) ? "优化建议" : "深度分析")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(.holoPrimary.opacity(0.8))
                                    .lineLimit(1)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(Color.holoPrimary.opacity(0.075))
                                    .clipShape(Capsule())
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
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
        let hasLog = !(thoughtLog ?? []).isEmpty
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
                    Spacer()
                    // 有思考日志时显示展开/收起箭头，提示可点查看完整调用过程
                    if hasLog {
                        Image(systemName: isThoughtExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.holoTextSecondary.opacity(0.6))
                    }
                }

                Text(status.detail)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)

                // 展开态：完整思考过程时间线
                if hasLog && isThoughtExpanded {
                    thoughtTimeline
                }
            }
        }
        // 有思考日志时放开点击用于展开/收起；无日志时维持原禁点行为（避免误触气泡）
        .allowsHitTesting(hasLog)
        .onTapGesture {
            guard hasLog else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isThoughtExpanded.toggle()
            }
        }
    }

    /// 思考过程时间线：每条 = 时间 + 动作文案
    private var thoughtTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array((thoughtLog ?? []).enumerated()), id: \.element.id) { index, event in
                HStack(alignment: .top, spacing: 8) {
                    // 时间线竖线 + 圆点
                    VStack(spacing: 0) {
                        Circle()
                            .fill(index == (thoughtLog?.count ?? 0) - 1 ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                            .padding(.top, 4)
                        if index < (thoughtLog?.count ?? 0) - 1 {
                            Rectangle()
                                .fill(Color.holoTextSecondary.opacity(0.18))
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    Text(event.title)
                        .font(.system(size: 12, weight: index == (thoughtLog?.count ?? 0) - 1 ? .medium : .regular))
                        .foregroundColor(index == (thoughtLog?.count ?? 0) - 1 ? .holoTextPrimary.opacity(0.85) : .holoTextSecondary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 4)
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
