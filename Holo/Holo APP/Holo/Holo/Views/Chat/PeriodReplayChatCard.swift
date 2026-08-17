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
    /// 本周期范围内的计划台账（对账区块数据源，实时读取）
    @State private var periodPlans: [LifePlanSnapshot] = []

    var body: some View {
        if let payload = message.insightResult {
            realCard(payload: payload)
        } else if message.isStreaming || message.periodReplayJob != nil {
            statusCard
        }
    }

    // MARK: - 上周对账（LifePlan）

    /// 该周期有过计划时，回放卡内追加「上周对账」区块：完成情况 + 接受/拒绝清单
    @ViewBuilder
    private var planReconciliationSection: some View {
        if let plan = periodPlans.first {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                    Text("上周对账")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Text("\(plan.acceptedActionCount)/\(plan.actions.count) 行动已接受")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }

                ForEach(plan.priorities) { priority in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: priorityDecisionIcon(priority.userDecision))
                            .font(.system(size: 11))
                            .foregroundColor(priorityDecisionColor(priority.userDecision))
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(priority.outcome)
                                .font(.system(size: 13))
                                .foregroundColor(.holoTextPrimary)
                            if priority.userDecision == "accepted", priority.goalID != nil {
                                Text("已建为目标")
                                    .font(.holoLabel)
                                    .foregroundColor(.holoSuccess)
                            } else if priority.userDecision == "rejected" {
                                Text("你未采纳这个重点")
                                    .font(.holoLabel)
                                    .foregroundColor(.holoTextSecondary)
                            }
                        }
                    }
                }

                let rejected = plan.actions.filter { $0.status == "rejected" }
                if !rejected.isEmpty {
                    Text("拒绝：\(rejected.map(\.payload.displayTitle).joined(separator: "、"))")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(Color.holoPrimary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            .task(id: message.id) {
                guard periodPlans.isEmpty,
                      let job = message.periodReplayJob else { return }
                periodPlans = LifePlanRepository.shared.fetchPlans(
                    periodStartIn: job.periodStart, job.periodEnd
                )
            }
        }
    }

    private func priorityDecisionIcon(_ decision: String?) -> String {
        switch decision {
        case "accepted", "edited": return "checkmark.circle.fill"
        case "rejected": return "xmark.circle"
        default: return "circle.dashed"
        }
    }

    private func priorityDecisionColor(_ decision: String?) -> Color {
        switch decision {
        case "accepted", "edited": return .holoSuccess
        case "rejected": return .holoTextSecondary
        default: return .holoTextSecondary
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
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.holoPrimary)
                            .frame(width: 28, height: 28)
                            .background(Color.holoPrimary.opacity(0.09))
                            .clipShape(Circle())

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

                // 上周对账（该周期有计划台账时展示；洞察=发生了什么，对账=承诺兑现如何）
                planReconciliationSection

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
                        // 高卡片折叠时不能做高度动画，否则 ScrollView 会保留动画前的
                        // contentOffset，短暂落入已经不存在的内容区域，表现为整屏空白。
                        isExpanded = nextValue
                        Task { @MainActor in
                            // 等卡片完成新一轮布局，再让外层校正滚动位置。
                            await Task.yield()
                            onExpansionChanged?(nextValue)
                        }
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
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: cardIcon(for: card.type))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(cardIconColor(for: card.type))
                    .frame(width: 24, height: 24)
                    .background(cardIconColor(for: card.type).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

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
