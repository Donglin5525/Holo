//
//  MemoryInsightCardView.swift
//  Holo
//
//  单张洞察卡片视图
//  展示 title + body + evidence 列表
//

import SwiftUI
import CoreData

/// 单张 AI 洞察卡片
struct MemoryInsightCardView: View {

    let card: MemoryInsightCard
    /// anomaly 卡片的严重度，用于区分颜色。非 anomaly 卡片传 nil
    var anomalySeverity: AnomalySeverity?
    /// 所属洞察的 ID，用于反馈关联
    var insightId: UUID?
    /// 行动候选（可选，由外部生成）
    var actionCandidate: InsightActionCandidate?
    /// 反思类行动确认后跳转 HoloAI，并携带预填文本
    var onContinueInChat: ((String) -> Void)?

    @State private var isExpanded: Bool = false
    @State private var showFeedbackSheet: Bool = false
    @State private var showActionConfirmation: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 类型图标 + 标题
            HStack(alignment: .top, spacing: HoloSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(cardColor.opacity(0.12))
                        .frame(width: 34, height: 34)

                    Image(systemName: cardIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(cardColor)
                }

                Text(card.title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                // 反馈按钮（仅在 Feature Flag 开启且有 insightId 时显示）
                if InsightFeatureFlags.feedbackEnabled, insightId != nil {
                    Button {
                        showFeedbackSheet = true
                    } label: {
                        Image(systemName: "hand.thumbsup")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextPlaceholder)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if !card.evidence.isEmpty {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoTextPlaceholder)
                        .padding(.top, 7)
                }
            }

            // 正文
            Text(card.body)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(isExpanded ? nil : 2)
                .textSelection(.enabled)

            // 展开的 evidence
            if isExpanded {
                evidenceList
            }

            // 建议追问
            if let question = card.suggestedQuestion, !question.isEmpty {
                HStack(spacing: HoloSpacing.xs) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 11))
                        .foregroundColor(.holoPrimary)

                    Text(question)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                        .lineLimit(1)
                }
                .padding(.top, HoloSpacing.xs)
            }

            // 行动候选
            if let action = actionCandidate, InsightFeatureFlags.actionCandidateEnabled {
                Button {
                    showActionConfirmation = true
                } label: {
                    HStack(spacing: HoloSpacing.xs) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                        Text(action.title)
                            .font(.holoTinyLabel)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.holoPrimary))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, HoloSpacing.xs)
                .alert(action.title, isPresented: $showActionConfirmation) {
                    Button("确认") {
                        executeAction(action)
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(actionDescription(action))
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(cardBorderColor, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .onTapGesture {
            guard !card.evidence.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
        .sheet(isPresented: $showFeedbackSheet) {
            if let insightId = insightId {
                InsightFeedbackSheet(
                    insightId: insightId,
                    cardId: card.id,
                    cardType: card.type,
                    moduleHint: card.moduleHint
                )
            }
        }
    }

    // MARK: - Evidence List

    @ViewBuilder
    private var evidenceList: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            ForEach(card.evidence) { ev in
                HStack(spacing: HoloSpacing.xs) {
                    Circle()
                        .fill(Color.holoBorder)
                        .frame(width: 4, height: 4)

                    Text(ev.label)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                        .lineLimit(1)
                }
            }
        }
        .padding(.top, HoloSpacing.xs)
    }

    // MARK: - Card Style

    private var cardIcon: String {
        switch card.type {
        case .habit: return "figure.run"
        case .finance: return "yensign.circle"
        case .task: return "checkmark.circle"
        case .thought: return "bubble.left"
        case .milestone: return "flag.fill"
        case .crossDomain: return "arrow.triangle.2.circlepath"
        case .overview: return "chart.bar"
        case .anomaly:
            switch anomalySeverity {
            case .critical: return "exclamationmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            default: return "info.circle.fill"
            }
        }
    }

    private var cardColor: Color {
        switch card.type {
        case .habit: return .holoSuccess
        case .finance: return .holoPrimary
        case .task: return .holoPrimary
        case .thought: return .holoPrimary
        case .milestone: return .holoPrimary
        case .crossDomain: return .holoPrimary
        case .overview: return .holoTextSecondary
        case .anomaly:
            switch anomalySeverity {
            case .critical: return .red
            case .warning: return .orange
            default: return .holoPrimary
            }
        }
    }

    private var cardBackgroundColor: Color {
        if card.type == .anomaly {
            return cardColor.opacity(0.07)
        }
        return Color.holoCardBackground
    }

    private var cardBorderColor: Color {
        card.type == .anomaly ? cardColor.opacity(0.28) : Color.holoBorder.opacity(0.45)
    }

    // MARK: - Action Helpers

    private func actionDescription(_ action: InsightActionCandidate) -> String {
        switch action.payload {
        case .taskDraft(let title, _, _):
            return "将创建任务「\(title)」"
        case .reflectionQuestion(let question):
            return question
        case .budgetReminderDraft:
            return "将设置消费提醒"
        case .habitAdjustmentDraft:
            return "将调整习惯设置"
        case .checkInReminder:
            return "将设置提醒"
        case .noAction:
            return ""
        }
    }

    private func executeAction(_ action: InsightActionCandidate) {
        switch action.payload {
        case .taskDraft(let title, let dueDate, let priority):
            createTask(title: title, dueDate: dueDate, priority: priority)
            // P2 集成：action 执行后记录 Outcome Review（不写因果）
            HoloOutcomeReviewStore.shared.recordExecution(
                actionID: action.id,
                sourceCardID: action.cardId,
                targetMetricKey: "task.completed",
                actionExecuted: true
            )
        case .reflectionQuestion:
            if let prompt = MemoryInsightActionPromptBuilder.chatPrefill(for: action, card: card) {
                onContinueInChat?(prompt)
            }
            HoloOutcomeReviewStore.shared.recordExecution(
                actionID: action.id,
                sourceCardID: action.cardId,
                targetMetricKey: "thought.count",
                actionExecuted: true
            )
        default:
            break
        }
    }

    private func createTask(title: String, dueDate: Date?, priority: Int16?) {
        let context = CoreDataStack.shared.viewContext
        let task = TodoTask(context: context)
        task.id = UUID()
        task.title = title
        task.desc = nil
        task.status = "pending"
        task.priority = priority ?? 0
        task.dueDate = dueDate
        task.createdAt = Date()
        try? context.save()
    }
}
