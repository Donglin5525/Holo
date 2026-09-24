//
//  MatterExecutionContent.swift
//  Holo
//
//  分步推进共用内容组件（2026-09-25 实施规格 §4.1–4.6）
//  嵌入原 Matter「下一步」灰卡 / TaskDetail，不新增第二张专注卡。
//  一次呈现一个动作；完成步骤零 AI 调用；等待/恢复/停留记录本地即时保存。
//

import SwiftUI
import os.log

struct MatterExecutionContent: View {

    let taskID: UUID
    @ObservedObject var repository: TodoRepository
    /// 来源 Matter（仅溯源记录用；步骤不进 Matter 分母）
    var originMatterID: UUID? = nil
    /// 回执溯源（matter / taskDetail / today …）
    var sourceSurface: String = "matter"
    /// 「不知道怎么做」→ 带上下文进 Matter 讨论
    var onDiscuss: (() -> Void)? = nil

    @State private var reloadToken = 0
    @State private var showProposalSheet = false
    @State private var proposalObstacle: String? = nil
    @State private var showStuckPanel = false
    @State private var showStepsSheet = false
    @State private var showWaitingSheet = false
    /// 轻量文字回执（已完成：X + 撤回），不弹庆祝
    @State private var lastReceipt: ExecutionReceipt?
    @State private var errorMessage: String?

    struct ExecutionReceipt: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let stepID: UUID
        let stateVersion: Int64
    }

    private let service = HoloTaskExecutionService.shared
    private static let logger = Logger(subsystem: "com.holo.app", category: "MatterExecutionContent")

    var body: some View {
        Group {
            if let view = executionView {
                content(for: view)
            } else {
                EmptyView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoDataDidChange)) { _ in
            reloadToken += 1
        }
        .sheet(isPresented: $showProposalSheet) {
            MatterExecutionProposalSheet(
                taskID: taskID,
                repository: repository,
                originMatterID: originMatterID,
                sourceSurface: sourceSurface,
                initialObstacle: proposalObstacle
            )
        }
        .sheet(isPresented: $showStepsSheet) {
            MatterExecutionStepsSheet(taskID: taskID, repository: repository)
        }
        .sheet(isPresented: $showWaitingSheet) {
            MatterExecutionWaitingSheet(
                taskID: taskID,
                repository: repository,
                sourceSurface: sourceSurface
            )
        }
    }

    // MARK: - 数据

    /// 游标是 UI 偏好（本机 UserDefaults），不是业务完成事实（规格 §6.2）
    private var cursorStepID: UUID? {
        guard let raw = UserDefaults.standard.string(forKey: Self.cursorKey(taskID)) else { return nil }
        return UUID(uuidString: raw)
    }

    nonisolated private static func cursorKey(_ taskID: UUID) -> String {
        "holoExecutionCursor.\(taskID.uuidString)"
    }

    private var executionView: HoloTaskExecutionView? {
        _ = reloadToken
        _ = lastReceipt
        _ = errorMessage
        return HoloTaskExecutionRepository(context: repository.context).executionView(taskID: taskID, cursorStepID: cursorStepID)
    }

    @ViewBuilder
    private func content(for view: HoloTaskExecutionView) -> some View {
        switch view.state {
        case .absent:
            absentContent(view)
        case .ready:
            readyContent(view)
        case .waiting:
            waitingContent(view)
        case .readyToConfirm:
            confirmContent(view)
        case .needsReview:
            needsReviewContent(view)
        case .syncing:
            syncingContent
        case .rootCompleted:
            EmptyView() // 原完成态由宿主页展示
        case .unavailable:
            EmptyView()
        }
    }

    // MARK: 未采纳：帮我拆开

    @ViewBuilder
    private func absentContent(_ view: HoloTaskExecutionView) -> some View {
        if HoloTaskExecutionRolloutPolicy.entryEnabled, !view.taskCompleted {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    showProposalSheet = true
                } label: {
                    Label(String(localized: "帮我拆开"), systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("executionSplitButton")
                Text(String(localized: "把这件事拆成一步步可做的小动作，卡住了可以调整"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 就绪：一个动作 + 一次点击

    private func readyContent(_ view: HoloTaskExecutionView) -> some View {
        let currentID = view.currentStepID
        let current = currentID.flatMap { view.step($0) }
        let node = currentID.flatMap { view.topology?.node(id: $0) }
        let isFinal = currentID.map { view.isFinalRequiredStep($0) } ?? false

        return VStack(alignment: .leading, spacing: 10) {
            if let receipt = lastReceipt {
                receiptRow(receipt)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let current, let node {
                // 当前动作 + 短完成条件（不暴露节点类型/依赖/模型版本）
                if let note = current.userResumeNote, !note.isEmpty {
                    Label(note, systemImage: "bookmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: current.actionText ?? "")
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let doneWhen = current.doneWhen, !doneWhen.isEmpty {
                    Text(verbatim: "做到：\(doneWhen)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    if isFinal, let contract = view.contract {
                        // 最后一步本身能核验结果 → 合并按钮，只点一次（规格 §3.3-4）
                        Button {
                            confirmOutcome(view, finalStepID: currentID, assertionText: contract.verificationPrompt)
                        } label: {
                            Text(verbatim: "\(contract.outcomeSummary)，完成任务")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    } else {
                        Button {
                            completeCurrentStep(view, stepID: currentID)
                        } label: {
                            Text(String(localized: "这步好了"))
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .accessibilityIdentifier("executionStepDoneButton")
                    }
                    Button {
                        showStuckPanel = true
                    } label: {
                        Text(String(localized: "卡住了"))
                            .font(.subheadline.weight(.semibold))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }

            // 查看步骤 ···
            HStack {
                Button {
                    showStepsSheet = true
                } label: {
                    Label(String(localized: "查看步骤"), systemImage: "list.bullet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button {
                        showWaitingSheet = true
                    } label: {
                        Label(String(localized: "现在做不了，记一下等待"), systemImage: "hourglass")
                    }
                    if let contract = view.contract {
                        Button {
                            confirmOutcome(view, finalStepID: nil, assertionText: contract.verificationPrompt)
                        } label: {
                            Label(String(localized: "已经办完，直接完成任务"), systemImage: "checkmark.seal")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(String(localized: "更多操作"))
            }
        }
        .confirmationDialog(
            String(localized: "卡住了？"),
            isPresented: $showStuckPanel,
            titleVisibility: .visible
        ) {
            Button(String(localized: "这步还是太大，帮我拆小")) {
                proposalObstacle = String(localized: "这步还是太大")
                showProposalSheet = true
            }
            Button(String(localized: "现在做不了，等一会再继续")) {
                showWaitingSheet = true
            }
            if let onDiscuss {
                Button(String(localized: "不知道怎么做，和 Holo 讨论")) {
                    onDiscuss()
                }
            }
            Button(String(localized: "这步不需要了"), role: .destructive) {
                proposalObstacle = String(localized: "这步不需要了，请按调整范围给提案")
                showProposalSheet = true
            }
            Button(String(localized: "先继续做着"), role: .cancel) {}
        } message: {
            Text(String(localized: "卡住很正常。可以先绕开，也可以把当前这步拆小一点。"))
        }
    }

    // MARK: 等待

    private func waitingContent(_ view: HoloTaskExecutionView) -> some View {
        let waitStep = view.waitingSteps.first
        return VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(verbatim: waitStep?.waitReason ?? String(localized: "这件事目前在等"))
                    .font(.body.weight(.medium))
            } icon: {
                Image(systemName: "hourglass")
                    .foregroundStyle(.orange)
            }
            if let reviewAfter = waitStep?.reviewAfter {
                Text(verbatim: "到点提醒你检查一下，不代表事情已完成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                + Text(verbatim: " · \(reviewAfter.formatted(.dateTime.month().day().hour().minute()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if let step = waitStep {
                    Button {
                        resume(step)
                    } label: {
                        Text(String(localized: "继续做"))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                Button {
                    showStepsSheet = true
                } label: {
                    Text(String(localized: "查看步骤"))
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    // MARK: 可确认结果

    private func confirmContent(_ view: HoloTaskExecutionView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let contract = view.contract {
                Text(verbatim: contract.outcomeSummary)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "步骤都做完了，确认一下结果就算完成"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    confirmOutcome(view, finalStepID: nil, assertionText: contract.verificationPrompt)
                } label: {
                    Text(verbatim: "结果已达成，完成任务")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                Text(verbatim: contract.verificationPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 需复核

    private func needsReviewContent(_ view: HoloTaskExecutionView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "任务内容有变化，这条计划需要复核"), systemImage: "exclamationmark.arrow.circlepath")
                .font(.subheadline.weight(.medium))
            Text(String(localized: "你可以继续做没受影响的步骤，或按当前内容重新拆解；也可以直接完成任务。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    showProposalSheet = true
                } label: {
                    Text(String(localized: "重新拆解"))
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.bordered)
                if let contract = view.contract {
                    Button {
                        confirmOutcome(view, finalStepID: nil, assertionText: contract.verificationPrompt)
                    } label: {
                        Text(String(localized: "结果已达成，完成任务"))
                            .font(.subheadline.weight(.semibold))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var syncingContent: some View {
        Label(String(localized: "计划正在同步，稍等一下就能继续"), systemImage: "tray.and.arrow.down")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: 轻量回执行

    private func receiptRow(_ receipt: ExecutionReceipt) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Text(verbatim: receipt.text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "撤回")) {
                undoReceipt(receipt)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.holoPrimary)
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 动作

    private func completeCurrentStep(_ view: HoloTaskExecutionView, stepID: UUID?) {
        guard let stepID, let revision = view.revision, let step = view.step(stepID) else { return }
        do {
            try service.completeStep(
                stepID: stepID,
                revisionID: revision.id,
                expectedStateVersion: step.stateVersion,
                operationID: UUID().uuidString,
                sourceSurface: sourceSurface,
                in: repository
            )
            let text = String(localized: "已完成：\(step.actionText ?? "")")
            lastReceipt = ExecutionReceipt(text: text, stepID: stepID, stateVersion: step.stateVersion + 1)
            Self.setCursor(stepID: nil, taskID: taskID) // 完成后游标让位给下一个可做步骤
        } catch {
            errorMessage = Self.describe(error)
            Self.logger.error("完成步骤失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func confirmOutcome(_ view: HoloTaskExecutionView, finalStepID: UUID?, assertionText: String) {
        guard let revision = view.revision else { return }
        let finalVersion: Int64? = finalStepID.flatMap { view.step($0)?.stateVersion }
        // 三秒撤回窗口由 HoloTaskCompletionCoordinator 统一承载（规格 §8.2）：
        // 窗口内只是 pending UI，到期才原子提交「最终步骤 + 根任务」
        HoloTaskCompletionCoordinator.shared.requestExecutionCompletion(
            taskID: taskID,
            revisionID: revision.id,
            finalStepID: finalStepID,
            finalStepExpectedStateVersion: finalVersion,
            userAssertion: assertionText,
            source: .matterExecution,
            sourceSurface: sourceSurface,
            in: repository
        )
        lastReceipt = nil
    }

    private func resume(_ step: HoloTaskExecutionStep) {
        guard let view = executionView, let revision = view.revision else { return }
        do {
            try service.resumeStep(
                stepID: step.id,
                revisionID: revision.id,
                expectedStateVersion: step.stateVersion,
                operationID: UUID().uuidString,
                sourceSurface: sourceSurface,
                in: repository
            )
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func undoReceipt(_ receipt: ExecutionReceipt) {
        guard let view = executionView, let revision = view.revision else { return }
        do {
            try service.reopenStep(
                stepID: receipt.stepID,
                revisionID: revision.id,
                expectedStateVersion: receipt.stateVersion,
                operationID: UUID().uuidString,
                sourceSurface: sourceSurface,
                in: repository
            )
            lastReceipt = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    nonisolated static func setCursor(stepID: UUID?, taskID: UUID) {
        UserDefaults.standard.set(stepID?.uuidString, forKey: cursorKey(taskID))
    }

    nonisolated static func describe(_ error: Error) -> String {
        (error as? HoloTaskExecutionError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 步骤总览 sheet

struct MatterExecutionStepsSheet: View {
    let taskID: UUID
    @ObservedObject var repository: TodoRepository
    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            Group {
                if let view = HoloTaskExecutionRepository(context: repository.context).executionView(taskID: taskID, cursorStepID: nil) {
                    List {
                        if let contract = view.contract {
                            Section(String(localized: "做到这里就算完成")) {
                                Text(verbatim: contract.outcomeSummary)
                                    .font(.subheadline)
                            }
                        }
                        Section(String(localized: "步骤")) {
                            ForEach(Array(view.steps.enumerated()), id: \.element.id) { index, step in
                                let state = view.resolution?.states[step.id]
                                HStack(alignment: .top, spacing: 10) {
                                    stepIcon(step, state: state)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: step.actionText ?? "")
                                            .font(.subheadline)
                                            .strikethrough(state == .done)
                                            .foregroundStyle(state == .done ? .secondary : .primary)
                                        if let doneWhen = step.doneWhen, !doneWhen.isEmpty {
                                            Text(verbatim: "做到：\(doneWhen)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let note = step.userResumeNote, !note.isEmpty {
                                            Text(verbatim: "停在这里：\(note)")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(index + 1)，\(step.actionText ?? "")")
                            }
                        }
                    }
                } else {
                    Text(String(localized: "计划不存在"))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "推进步骤"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ step: HoloTaskExecutionStep, state: HoloTaskExecutionPolicy.EffectiveState?) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .waiting:
            Image(systemName: "hourglass").foregroundStyle(.orange)
        default:
            if step.kind == .sourceCheckItemReference {
                Image(systemName: "square").foregroundStyle(.secondary)
            } else {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 等待 sheet（原因 + 可选明天提醒，规格 §4.5）

struct MatterExecutionWaitingSheet: View {
    let taskID: UUID
    @ObservedObject var repository: TodoRepository
    var sourceSurface: String = "matter"
    @Environment(\.dismiss) private var dismiss
    @State private var reason: String = ""
    @State private var remindTomorrow = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "在等什么？比如：等同事发票"), text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text(String(localized: "等待不会被记成完成。到提醒时间只会提示你检查一下。"))
                }
                Section {
                    Toggle(String(localized: "明天提醒我看一眼"), isOn: $remindTomorrow)
                }
            }
            .navigationTitle(String(localized: "先等一下"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "记下等待")) {
                        saveWaiting()
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
    }

    private func saveWaiting() {
        guard let view = HoloTaskExecutionRepository(context: repository.context).executionView(taskID: taskID, cursorStepID: nil),
              let revision = view.revision,
              let stepID = view.currentStepID,
              let step = view.step(stepID) else { return }
        let reviewAfter: Date? = remindTomorrow
            ? Calendar.current.date(byAdding: .day, value: 1, to: Date())
            : nil
        try? HoloTaskExecutionService.shared.setWaiting(
            stepID: stepID,
            revisionID: revision.id,
            expectedStateVersion: step.stateVersion,
            reason: reason.isEmpty ? nil : reason,
            reviewAfter: reviewAfter,
            operationID: UUID().uuidString,
            sourceSurface: sourceSurface,
            in: repository
        )
        if reviewAfter != nil {
            Task {
                await TodoNotificationService.shared.scheduleExecutionReviewReminder(
                    taskID: taskID, stepID: stepID, fireAt: reviewAfter!, reason: reason
                )
            }
        }
    }
}
