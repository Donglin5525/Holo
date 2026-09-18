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

    @State private var session: GoalWorkshopSessionV1?
    @State private var resumeCandidates: [GoalWorkshopSessionV1] = []
    @State private var isBusy = false
    @State private var errorText: String?
    /// 预算保险丝耗尽时给「重新开始」出口，别让用户对着死会话撞墙
    @State private var needsRestart = false
    /// 刚发出的回答原话（等待模型期间在问题卡回显，补「已发出、在处理」的感觉）
    @State private var sentReplyText: String?
    @State private var showConfirm = false
    @State private var correctingFact: GoalWorkshopFact?
    @State private var correctionText = ""

    private let coordinator = GoalWorkshopCoordinator(service: GoalWorkshopServiceFactory.make())

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("一起想清楚")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // 只关闭不放弃：进度保留，下次进入给「继续/放弃/另建」
                        Button("关闭") { dismiss() }
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
                                Task { await finishAfterSave(result: result) }
                            }
                        )
                    }
                }
        }
        .task { await bootstrap() }
    }

    // MARK: - 阶段分发（子树全部独立 struct，防止巨树）

    private var content: some View {
        ScrollView {
            VStack(spacing: 14) {
                if isExistingGoalAdvice {
                    Label {
                        Text("下面是针对这个目标的调整建议，不会改动你的原目标")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
                        onResume: { sessionID in Task { await resume(sessionID) } },
                        onDiscard: { sessionID in Task { await discard(sessionID) } },
                        onStartFresh: { Task { await startFresh() } }
                    )
                } else if errorText != nil {
                    // 启动失败（如未开 AI 授权）：给出路，不吊死在「正在连接…」
                    Button("重试") {
                        Task { await bootstrap() }
                    }
                    .font(.footnote)
                } else {
                    ProgressView("正在连接…")
                }

                if let errorText {
                    Label {
                        Text(errorText).font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if needsRestart {
                    Button("放弃这场，重新开始") {
                        Task { await restartFromScratch() }
                    }
                    .font(.footnote)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func phaseView(for session: GoalWorkshopSessionV1) -> some View {
        switch session.phase {
        case .understanding:
            if let question = session.currentQuestion {
                GoalWorkshopQuestionCard(
                    question: question,
                    assistantText: session.lastAssistantText,
                    userReplyText: session.lastUserReply,
                    pendingReplyText: isBusy ? sentReplyText : nil,
                    isBusy: isBusy,
                    onReply: { text in Task { await reply(text) } },
                    onSkip: { Task { await skipQuestion() } }
                )
            } else if session.questioningSkipped {
                PrimaryAction(title: "看看有哪些路径", isBusy: isBusy) {
                    Task { await requestRoutes() }
                }
            } else {
                PrimaryAction(title: isBusy ? "正在想…" : "继续", isBusy: isBusy) {
                    Task { await continueUnderstanding() }
                }
            }
            factsSection(for: session)
        case .exploring:
            GoalWorkshopOptionsCard(
                options: session.routeOptions,
                recommendedOptionID: session.recommendedRouteID,
                assistantText: session.lastAssistantText,
                isBusy: isBusy,
                onChoose: { optionID in Task { await choose(optionID) } }
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
                    Task { await generatePlan() }
                }
                if isBusy {
                    Label {
                        Text("正在按这条路径起草，通常需要半分钟，写好会自动出现")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Button("返回重新选路径") {
                    Task { await goBack() }
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
                    Task { await goBack() }
                }
                .font(.footnote)
                .disabled(isBusy)
            }
            .padding()
        case .saved:
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
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
                } header: {
                    Text("纠正")
                }
            }
            .navigationTitle("纠正这条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { correctingFact = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") {
                        let text = correctionText
                        let factID = fact.id
                        correctingFact = nil
                        Task { await correct(factID: factID, text: text) }
                    }
                    .disabled(correctionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - 动作

    private func bootstrap() async {
        switch launch {
        case .new(let seedText):
            let resumable = (try? GoalWorkshopStore.shared.listResumable()) ?? []
            if resumable.isEmpty {
                await start(seed: seedText ?? "")
            } else {
                resumeCandidates = resumable
            }
        case .existingGoalAdvice(let goalID, _):
            await start(seed: "想调整这个目标", goalID: goalID)
        case .resume(let sessionID):
            await resume(sessionID)
        }
    }

    private func start(seed: String, goalID: UUID? = nil) async {
        isBusy = true
        errorText = nil
        needsRestart = false
        defer { isBusy = false }
        do {
            let refs: [GoalWorkshopContextRef] = goalID.map { [goalRef($0)] } ?? []
            session = try await coordinator.start(seedText: seed, goalID: goalID, contextRefs: refs)
        } catch {
            present(error)
        }
    }

    private func startFresh() async {
        resumeCandidates = []
        await start(seed: "")
    }

    private func resume(_ sessionID: UUID) async {
        resumeCandidates = []
        isBusy = true
        defer { isBusy = false }
        session = try? await coordinator.loadSession(sessionID)
    }

    private func discard(_ sessionID: UUID) async {
        try? await coordinator.cancel(sessionID: sessionID)
        resumeCandidates.removeAll { $0.id == sessionID }
        if resumeCandidates.isEmpty {
            await startFresh()
        }
    }

    private func reply(_ text: String) async {
        guard let session else { return }
        isBusy = true
        sentReplyText = text
        errorText = nil
        needsRestart = false
        defer { isBusy = false; sentReplyText = nil }
        do {
            self.session = try await coordinator.reply(sessionID: session.id, text: text)
        } catch {
            present(error)
        }
    }

    private func continueUnderstanding() async {
        guard let session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            self.session = try await coordinator.reply(sessionID: session.id, text: "继续")
        } catch {
            present(error)
        }
    }

    private func skipQuestion() async {
        guard let session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let updated = try await coordinator.skip(sessionID: session.id)
            self.session = updated
            if updated.questioningSkipped {
                let next = try await coordinator.requestOptions(sessionID: updated.id)
                self.session = next
            }
        } catch {
            present(error)
        }
    }

    private func requestRoutes() async {
        guard let session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            self.session = try await coordinator.requestOptions(sessionID: session.id)
        } catch {
            present(error)
        }
    }

    private func choose(_ optionID: String) async {
        guard let session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            self.session = try await coordinator.choose(sessionID: session.id, optionID: optionID)
            errorText = nil
            needsRestart = false
        } catch {
            present(error)
        }
    }

    private func generatePlan() async {
        guard let session else { return }
        isBusy = true
        errorText = nil
        needsRestart = false
        defer { isBusy = false }
        do {
            self.session = try await coordinator.generatePlan(sessionID: session.id)
        } catch {
            present(error)
        }
    }

    private func goBack() async {
        guard let session else { return }
        // 复用状态机返回：reviewing→choosing→exploring
        var current = session
        if current.phase == .reviewing {
            try? current.goBack()
            self.session = try? storeSave(current)
        } else if current.phase == .choosing {
            try? current.goBack()
            self.session = try? storeSave(current)
        }
        errorText = nil
        needsRestart = false
    }

    /// 预算保险丝耗尽等死局的出口：放弃这场、带着空档重新开始
    private func restartFromScratch() async {
        if let session {
            try? await coordinator.cancel(sessionID: session.id)
        }
        await startFresh()
    }

    private func storeSave(_ snapshot: GoalWorkshopSessionV1) throws -> GoalWorkshopSessionV1 {
        try GoalWorkshopStore.shared.saveIfRevisionMatches(snapshot)
        return snapshot
    }

    private func correct(factID: String, text: String) async {
        guard let session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            self.session = try await coordinator.correctFact(sessionID: session.id, factID: factID, text: text)
        } catch {
            present(error)
        }
    }

    /// 确认页保存成功后的收口（任务 6 起由提交服务完成原子写入）
    private func finishAfterSave(result: GoalDraftSaveResult) async {
        if let session {
            var saved = session
            try? saved.markSaved(appliedGoalID: result.goal.id)
            try? GoalWorkshopStore.shared.saveIfRevisionMatches(saved)
            self.session = saved
        }
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

    private func goalRef(_ goalID: UUID) -> GoalWorkshopContextRef {
        let title = GoalRepository.shared.findGoal(by: goalID)?.title ?? ""
        return GoalWorkshopContextRef(sourceID: "goal-\(goalID.uuidString)", sourceRevision: 1, summary: title)
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
        case .userStated: return .blue
        case .authorizedRecord: return .indigo
        case .inference: return .orange
        case .unknown: return .gray
        }
    }

    /// 统一展示错误 + 判断是否要给「重新开始」出口
    private func present(_ error: Error) {
        errorText = describe(error)
        needsRestart = (error as? GoalWorkshopCoordinatorError) == .requestBudgetExhausted
    }

    private func describe(_ error: Error) -> String {
        if let coordinatorError = error as? GoalWorkshopCoordinatorError {
            switch coordinatorError {
            case .quotaExhaustedMidFlow:
                return "这会儿服务太忙，进度已保存，稍等几分钟再继续。"
            case .sessionUnavailable:
                return "这场会话已失效，重新开始一场就好。"
            case .duplicateInFlight:
                return "上一条还在处理，稍等一下。"
            case .invalidModelOutput:
                return "Holo 这次没把结果想明白，你的进度都在。再试一次通常就好。"
            case .requestBudgetExhausted:
                return "这场共创的思考次数用完了（保险丝保护，正常走完用不完）。点下面重新开始一场。"
            }
        }
        // 未开 AI 数据授权是本地拦截，不是网络问题，单独说人话并给去处
        if let apiError = error as? APIError,
           case .serverError(let message) = apiError,
           message == HoloAIDataProcessingConsent.requiredMessage {
            return "共创前需要先开启 AI 数据授权：在「设置 → HoloAI 数据授权」里打开，再回来继续就好。"
        }
        return "网络开小差了，进度已保存，稍后再试。"
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
        HStack(spacing: 6) {
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
                        .font(.caption2)
                }
                .foregroundStyle(index < currentIndex ? .secondary : (index == currentIndex ? Color.accentColor : Color.secondary.opacity(0.55)))
                .fontWeight(index == currentIndex ? .semibold : .regular)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground).opacity(0.6), in: Capsule())
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
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
    }
}
