//
//  GoalWorkshopFlowView.swift
//  Holo
//
//  目标共创·流程容器（方案任务 5）
//
//  从「我的目标」新建菜单 / HoloAI 规划入口 / 已有目标详情进入的独立会话页：
//  问题 → 路径 → 定义/草案 → 确认页（GoalDraftReviewView，任务 6 扩展）。
//  复杂子树全部拆为独立 struct（Question/Options/Definition/Resume 卡），
//  本容器只做状态分发，避免巨型 body。
//

import SwiftUI

/// 流程入口载荷
enum GoalWorkshopLaunch: Identifiable, Equatable {
    case new(seedText: String?)
    /// P0：已有目标入口（只给建议不写回）
    case existingGoalAdvice(goalID: UUID, goalTitle: String)
    case resume(sessionID: UUID)

    var id: String {
        switch self {
        case .new: return "new"
        case .existingGoalAdvice(let goalID, _): return "goal-\(goalID.uuidString)"
        case .resume(let sessionID): return "resume-\(sessionID.uuidString)"
        }
    }
}

struct GoalWorkshopFlowView: View {
    @Environment(\.dismiss) private var dismiss

    let launch: GoalWorkshopLaunch

    @StateObject private var model = GoalWorkshopFlowModel()

    private var session: GoalWorkshopSessionV1? { model.session }
    private var resumeCandidates: [GoalWorkshopSessionV1] { model.resumeCandidates }
    private var isBusy: Bool { model.isBusy }
    private var errorText: String? { model.errorText }
    private var needsRestart: Bool { model.needsRestart }
    private var sentReplyText: String? { model.sentReplyText }
    @State private var showConfirm = false
    @State private var correctingFact: GoalWorkshopFact?
    @State private var correctionText = ""
    @State private var showCloseConfirm = false

    private var hasUnsentReply: Bool { !model.replyDraft.isEmpty && !isBusy }

    private func requestClose() {
        if hasUnsentReply { showCloseConfirm = true } else { dismiss() }
    }


    var body: some View {
        NavigationStack {
            content
                .navigationTitle("一起想清楚")
                .navigationBarTitleDisplayMode(.inline)
                .holoSheetShell()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // 只关闭不放弃：进度保留，下次进入给「继续/放弃/另建」
                        Button("关闭", action: requestClose)
                    }
                }
                .sheet(isPresented: $showConfirm) {
                    if let session, let plan = session.plan {
                        GoalDraftReviewView(
                            draft: plan.draft,
                            workshopContext: GoalWorkshopReviewContext(
                                session: session,
                                successEvidence: plan.successEvidence,
                                assumptions: plan.assumptions
                            ),
                            onCancel: { showConfirm = false },
                            onSaved: { result in
                                showConfirm = false
                                let goalID = result.goal.id
                                Task { await model.finishAfterSave(goalID: goalID) }
                            }
                        )
                    }
                }
        }
        .task { await model.bootstrap(launch) }
        .interactiveDismissDisabled(hasUnsentReply)
        .sheetDismissGuard(onAttempt: requestClose)
        .unsavedChangesAlert(isPresented: $showCloseConfirm,
                             message: String(localized: "尚未发送的回答会丢失，已保存的规划进度会保留。")) { dismiss() }
    }

    // MARK: - 阶段分发（子树全部独立 struct，防止巨树）

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                if isExistingGoalAdvice {
                    Label {
                        Text("下面是针对这个目标的调整建议，不会改动你的原目标")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.holoToolWarning)
                }

                if let session {
                    if session.phase != .abandoned {
                        GoalWorkshopStepHeader(phase: session.phase)
                    }
                    if session.phase == .choosing || session.phase == .reviewing || session.phase == .saved,
                       session.hasDefinitionContent {
                        GoalWorkshopDefinitionCard(session: session, isExistingGoalAdvice: isExistingGoalAdvice)
                    }
                    phaseView(for: session)
                } else if !resumeCandidates.isEmpty {
                    GoalWorkshopResumeCard(
                        candidates: resumeCandidates,
                        onResume: { sessionID in Task { await model.resume(sessionID) } },
                        onDiscard: { sessionID in Task { await model.discard(sessionID) } },
                        onStartFresh: { Task { await model.startFresh() } }
                    )
                    .disabled(isBusy)
                } else if errorText != nil {
                    // 启动失败（如未开 AI 授权）：给出路，不吊死在「正在连接…」
                    Button("重试") {
                        Task { await model.bootstrap(launch) }
                    }
                    .buttonStyle(HoloActionStyle(role: .secondary))
                    .disabled(isBusy)
                } else {
                    ProgressView("正在连接…")
                }

                if let errorText {
                    Label {
                        Text(errorText).font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(Color.holoToolError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.needsReload {
                    Button("重新读取进度") {
                        Task { await model.reloadCurrent() }
                    }
                    .buttonStyle(HoloActionStyle(role: .secondary))
                    .disabled(isBusy)
                }
                if needsRestart {
                    Button("放弃这场，重新开始") {
                        Task { await model.restartFromScratch() }
                    }
                    .buttonStyle(HoloActionStyle(role: .secondary))
                    .disabled(isBusy)
                }
            }
            .padding(HoloSpacing.page)
        }
    }

    @ViewBuilder
    private func phaseView(for session: GoalWorkshopSessionV1) -> some View {
        switch session.phase {
        case .understanding:
            if let question = session.currentQuestion {
                GoalWorkshopQuestionCard(
                    question: question,
                    draft: $model.replyDraft,
                    assistantText: session.lastAssistantText,
                    userReplyText: session.lastUserReply,
                    pendingReplyText: isBusy ? sentReplyText : nil,
                    isBusy: isBusy,
                    onReply: { text in Task { await model.reply(text) } },
                    onSkip: { Task { await model.skipQuestion() } }
                )
            } else if session.questioningSkipped {
                PrimaryAction(title: "看看有哪些路径", isBusy: isBusy) {
                    Task { await model.requestRoutes() }
                }
            } else {
                PrimaryAction(title: isBusy ? "正在想…" : "继续", isBusy: isBusy) {
                    Task { await model.continueUnderstanding() }
                }
            }
            factsSection(for: session)
        case .exploring:
            GoalWorkshopOptionsCard(
                options: session.routeOptions,
                recommendedOptionID: session.recommendedRouteID,
                assistantText: session.lastAssistantText,
                isBusy: isBusy,
                onChoose: { optionID in Task { await model.choose(optionID) } }
            )
        case .choosing:
            VStack(spacing: 10) {
                if !session.originalText.isEmpty {
                    Text("想清楚的事：\(session.originalText)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("已选「\(selectedRouteTitle ?? "路径")」")
                    .font(.subheadline)
                PrimaryAction(title: "按这条路径出草案", isBusy: isBusy) {
                    Task { await model.generatePlan() }
                }
                if isBusy {
                    Label {
                        Text("正在起草，完成后会自动显示。")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Button("返回重新选路径") {
                    Task { await model.goBack() }
                }
                .font(.footnote)
                .disabled(isBusy)
            }
            .padding()
        case .reviewing:
            VStack(spacing: 10) {
                PrimaryAction(title: "去确认这份草案", isBusy: isBusy) {
                    showConfirm = true
                }
                Button("返回换条路径") {
                    Task { await model.goBack() }
                }
                .font(.footnote)
                .disabled(isBusy)
            }
            .padding()
        case .saved:
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.holoToolSuccess)
                Text("目标已保存")
                PrimaryAction(title: "完成", isBusy: false) { dismiss() }
            }
            .padding()
        case .abandoned:
            Text("会话已结束")
                .foregroundStyle(.secondary)
        }
    }

    /// 已确认事实列表 + 纠正入口（推断必须可纠正）
    @ViewBuilder
    private func factsSection(for session: GoalWorkshopSessionV1) -> some View {
        let facts = session.activeFacts
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("已确认的事").font(.footnote).foregroundStyle(.secondary)
                ForEach(facts) { fact in
                    HStack(alignment: .top) {
                        Text(provenanceLabel(fact.provenance))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(provenanceColor(fact.provenance).opacity(0.15), in: Capsule())
                            .foregroundStyle(provenanceColor(fact.provenance))
                        Text(fact.text).font(.footnote)
                        Spacer(minLength: 0)
                        Button("纠正") {
                            correctingFact = fact
                            correctionText = ""
                        }
                        .font(.caption)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .sheet(item: $correctingFact) { fact in
                correctionSheet(fact)
            }
        }
    }

    private func correctionSheet(_ fact: GoalWorkshopFact) -> some View {
        NavigationStack {
            Form {
                Section {
                    Text(fact.text).foregroundStyle(.secondary)
                } header: {
                    Text("原来的说法")
                }
                Section {
                    TextField("更准确的说法是…", text: $correctionText, axis: .vertical)
                        .lineLimit(1...4)
                        .disabled(isBusy)
                } header: {
                    Text("纠正")
                }
                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(Color.holoToolError)
                    }
                }
            }
            .navigationTitle("纠正这条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { correctingFact = nil }
                        .disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") {
                        let text = correctionText
                        let factID = fact.id
                        Task {
                            if await model.correct(factID: factID, text: text) {
                                correctingFact = nil
                            }
                        }
                    }
                    .disabled(isBusy || correctionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .holoSheetShell()
        .interactiveDismissDisabled(isBusy)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 展示助手

    private var isExistingGoalAdvice: Bool {
        if case .existingGoalAdvice = launch { return true }
        return false
    }

    private var selectedRouteTitle: String? {
        guard let selected = session?.selectedRouteID else { return nil }
        return session?.routeOptions.first { $0.id == selected }?.title
    }

    private func provenanceLabel(_ provenance: GoalWorkshopFactProvenance) -> LocalizedStringKey {
        switch provenance {
        case .userStated: return "你说"
        case .authorizedRecord: return "记录"
        case .inference: return "推测"
        case .unknown: return "未知"
        }
    }

    private func provenanceColor(_ provenance: GoalWorkshopFactProvenance) -> Color {
        switch provenance {
        case .userStated: return .holoToolInfo
        case .authorizedRecord: return .holoToolAI
        case .inference: return .holoToolWarning
        case .unknown: return .holoToolTextSecondary
        }
    }


}

// MARK: - 四步进度条（聊清楚 → 选路径 → 定草案 → 去确认）

private struct GoalWorkshopStepHeader: View {
    let phase: GoalWorkshopPhase

    private let titles: [LocalizedStringKey] = ["聊清楚", "选路径", "定草案", "去确认"]

    /// 当前进行到第几步（0 起）；saved 视为全部完成
    private var currentIndex: Int {
        switch phase {
        case .understanding: return 0
        case .exploring: return 1
        case .choosing: return 2
        case .reviewing: return 3
        case .saved: return 4
        case .abandoned: return 0
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            stepLabels.fixedSize(horizontal: true, vertical: false)
            HStack {
                Text(currentIndex == 4 ? LocalizedStringKey("规划完成") : titles[currentIndex])
                Spacer(minLength: HoloSpacing.sm)
                Text("\(min(currentIndex + 1, 4))/4").monospacedDigit()
            }
            .holoText(.metadata)
            .foregroundStyle(Color.holoToolText)
        }
        .frame(maxWidth: .infinity)
        .padding(HoloSpacing.sm)
        .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.sm))
    }

    private var stepLabels: some View {
        HStack(spacing: HoloSpacing.xs) {
            ForEach(0..<4, id: \.self) { index in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 4) {
                    if index < currentIndex {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold))
                    }
                    Text(titles[index])
                        .holoText(.metadata)
                }
                .foregroundStyle(index == currentIndex ? Color.holoToolText : Color.holoToolTextSecondary)
                .fontWeight(index == currentIndex ? .semibold : .regular)
            }
        }
    }
}

// MARK: - 小件

private struct PrimaryAction: View {
    /// LocalizedStringKey：调用方传字面量即可进词条目录，繁/英随系统生效
    let title: LocalizedStringKey
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(HoloActionStyle(role: .primary))
        .disabled(isBusy)
    }
}
