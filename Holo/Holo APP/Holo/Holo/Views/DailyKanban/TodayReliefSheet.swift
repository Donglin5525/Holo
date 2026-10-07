//
//  TodayReliefSheet.swift
//  Holo
//
//  「今天减负」单一审阅弹层（2026-10-03 实施方案 §4）
//
//  - 表达（文字+语音复用 VoiceInputSheet）→（AI 或手动）→ 原位逐项调整 → 一次采用；
//  - 最多一次必要追问；行操作后概括/数量/约束立即按当前候选重算；
//  - 放下今日到期任务需行内「我知道，今天先放下」确认；
//  - 采用前零业务写入；采用后回执可「撤销安排」；
//  - 手动模式在 AI 不可用时仍可完整审阅采用（G2 门槛）。
//

import SwiftUI
import EventKit

struct TodayReliefSheet: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = HoloTodayReliefViewModel()
    @State private var context: HoloTodayReliefSessionContext?
    @State private var showVoiceInput = false
    @State private var showConstraints = false
    @State private var newTaskTitleDraft = ""
    /// 追问回答输入。
    @State private var clarificationAnswer = ""

    var body: some View {
        NavigationStack {
            Group {
                if let context {
                    phaseView(context)
                } else {
                    ProgressView(String(localized: "正在读取今天的安排…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(String(localized: "帮我理一理"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        viewModel.teardown()
                        dismiss()
                    } label: {
                        Text(String(localized: "关闭"))
                    }
                    .accessibilityIdentifier("todayReliefCloseButton")
                }
            }
        }
        .holoSheetShell()
        .task { await loadContext() }
        .sheet(isPresented: $showVoiceInput) {
            VoiceInputSheet(
                readySubtitle: String(localized: "说完后自动填入"),
                submitButtonTitle: String(localized: "填入"),
                onSendTranscript: { transcript in
                    viewModel.updateSituation((viewModel.situationText.isEmpty ? "" : viewModel.situationText + " ") + transcript)
                }
            )
            .holoSheetShell()
        }
        .onDisappear {
            viewModel.teardown()
        }
    }

    // MARK: - 会话上下文冻结

    private func loadContext() async {
        guard context == nil else { return }
        context = await HoloTodayReliefSessionFactory.makeContext()
    }

    // MARK: - 各阶段视图

    @ViewBuilder
    private func phaseView(_ context: HoloTodayReliefSessionContext) -> some View {
        switch viewModel.phase {
        case .input:
            inputView(context)
        case .generating:
            generatingView
        case .clarification(let question, let answers):
            clarificationView(question: question, answers: answers, context: context)
        case .review:
            reviewView(context)
        case .adopting:
            VStack(spacing: 16) {
                ProgressView()
                Text(String(localized: "正在更新今天…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .adopted(let deferredCount, let undoable):
            adoptedView(deferredCount: deferredCount, undoable: undoable)
        case .failed(let message, let canRetry):
            failedView(message: message, canRetry: canRetry, context: context)
        }
    }

    private func inputView(_ context: HoloTodayReliefSessionContext) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "今天怎么安排更合适？"))
                    .holoText(.sectionTitle)
                    .foregroundStyle(Color.holoToolText)

                TextEditor(text: Binding(
                    get: { viewModel.situationText },
                    set: { viewModel.updateSituation($0) }
                ))
                .frame(minHeight: 88)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoToolSurface))
                .overlay(alignment: .topLeading) {
                    if viewModel.situationText.isEmpty {
                        Text(String(localized: "突然加班，今晚只剩半小时，先做什么？"))
                            .font(.subheadline)
                            .foregroundStyle(Color.holoToolTextSecondary.opacity(0.6))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("todayReliefSituationEditor")

                HStack(spacing: 8) {
                    ForEach([String(localized: "时间不够了"), String(localized: "今天想轻一点"), String(localized: "想接着上次做")], id: \.self) { phrase in
                        Button {
                            // 快捷表达仅填入可编辑文本，不自动发送（§4.2）
                            viewModel.updateSituation(phrase)
                        } label: {
                            Text(phrase)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.holoPrimary.opacity(0.08)))
                                .foregroundStyle(Color.holoPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    Button {
                        showVoiceInput = true
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.holoPrimary.opacity(0.08)))
                            .foregroundStyle(Color.holoPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("语音输入"))
                }

                if !context.tasksAvailable {
                    Label(String(localized: "任务暂时读不到，可以先手动整理，稍后再试。"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if context.currentPlanPayload?.selectionMode == .explicit {
                    Text(String(localized: "今天已有安排；重新整理会替换今天的选择，原任务截止和提醒不变。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    viewModel.submit(context: context)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text(String(localized: "开始整理"))
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoPrimary))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("todayReliefSubmitButton")

                Text(String(localized: "也可以不动 AI，下面自己挑："))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    viewModel.updateSituation(String(localized: "手动整理"))
                    viewModel.submit(context: context)
                } label: {
                    Text(String(localized: "手动挑今天要做的事"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.holoPrimary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoPrimary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("todayReliefManualButton")
            }
            .padding(16)
        }
    }

    private var generatingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text(String(localized: "正在结合你的任务和日程整理…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if viewModel.isCancellable {
                Button {
                    viewModel.cancelGeneration()
                } label: {
                    Text(String(localized: "取消"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.holoToolSurface))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("todayReliefCancelButton")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func clarificationView(question: String, answers: [String], context: HoloTodayReliefSessionContext) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(String(localized: "有一个小问题"), systemImage: "questionmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(question)
                    .font(.body)
                ForEach(answers, id: \.self) { answer in
                    Button {
                        clarificationAnswer = answer
                    } label: {
                        HStack {
                            Text(answer)
                                .font(.subheadline)
                                .foregroundStyle(clarificationAnswer == answer ? Color.holoPrimary : Color.primary)
                            Spacer()
                            if clarificationAnswer == answer {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(Color.holoPrimary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoToolSurface))
                    }
                    .buttonStyle(.plain)
                }
                TextField(String(localized: "或者直接说…"), text: $clarificationAnswer)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoToolSurface))

                Button {
                    guard !clarificationAnswer.isEmpty else { return }
                    viewModel.answerClarification(clarificationAnswer, context: context)
                } label: {
                    Text(String(localized: "就这样回答"))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(clarificationAnswer.isEmpty ? Color.holoPrimary.opacity(0.4) : Color.holoPrimary))
                }
                .buttonStyle(.plain)
                .disabled(clarificationAnswer.isEmpty)

                Button {
                    // 跳过追问直接手动（R34：一次追问后不再循环）
                    viewModel.answerClarification(String(localized: "先手动选"), context: context)
                } label: {
                    Text(String(localized: "先手动选"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
    }

    // MARK: 审阅（§4.3）

    private func reviewView(_ context: HoloTodayReliefSessionContext) -> some View {
        guard let candidate = viewModel.candidate else {
            return AnyView(EmptyView())
        }
        let scope = candidate.scope
        return AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 顶部一句话概括（本地按当前候选重算；不显示模型原句）
                    Text(viewModel.reviewSummary)
                        .font(.headline)
                        .foregroundStyle(Color.holoToolText)
                        .accessibilityIdentifier("todayReliefReviewSummary")

                    if candidate.displayFacts.truncated {
                        Text(String(localized: "任务较多，根据已读取的安排整理。"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    // 空库创建行（采用后才创建；§4.5；用户可修改标题）
                    if candidate.newTaskTitle != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(String(localized: "新建一件事（采用后才会创建）"), systemImage: "plus.circle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.holoPrimary)
                            TextField(String(localized: "要创建的任务名"), text: Binding(
                                get: { viewModel.candidate?.newTaskTitle ?? "" },
                                set: { viewModel.updateNewTaskTitle($0) }
                            ))
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoToolSurface))
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoPrimary.opacity(0.05)))
                    }

                    // 候选行：已选(有序) → 其余可调整任务
                    reviewTaskRows(candidate: candidate, scope: scope)

                    // 需要留意（默认折叠；真实约束）
                    if !candidate.displayFacts.constraints.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                withAnimation(HoloAnimation.snappy) { showConstraints.toggle() }
                            } label: {
                                HStack {
                                    Label(String(localized: "需要留意（\(candidate.displayFacts.constraints.count)）"), systemImage: "exclamationmark.book")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: showConstraints ? "chevron.up" : "chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            if showConstraints {
                                ForEach(candidate.displayFacts.constraints) { row in
                                    constraintLine(row)
                                }
                            }
                        }
                    }

                    // 次操作：再说一句（回到输入保留上下文）
                    Button {
                        viewModel.backToInput()
                    } label: {
                        Label(String(localized: "再说一句"), systemImage: "arrow.uturn.backward")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                adoptBar(candidate: candidate)
            }
        )
    }

    private func reviewTaskRows(candidate: HoloTodayReliefCandidate, scope: HoloTodayDayScope) -> some View {
        let payload = candidate.payload
        let selectedIDs = payload.entries.map(\.taskID)
        let deferredSet = Set(payload.deferredTaskIDs)
        let remaining = candidate.displayFacts.tasks.values
            .filter { !selectedIDs.contains($0.taskID) && !deferredSet.contains($0.taskID) }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }

        return VStack(alignment: .leading, spacing: 8) {
            if !payload.entries.isEmpty {
                Text(String(localized: "今天保留（\(payload.entries.count)）"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(payload.entries.enumerated()), id: \.element.taskID) { index, entry in
                        reviewRow(
                            display: candidate.displayFacts.tasks[entry.taskID],
                            entry: entry,
                            order: index,
                            scope: scope
                        )
                    }
                }
                .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoToolSurface))
            } else {
                Text(String(localized: "今天不主动推进任何任务。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoToolSurface))
            }

            if !payload.deferredTaskIDs.isEmpty {
                Text(String(localized: "今天先放下（\(payload.deferredTaskIDs.count)）· 仍在原清单，截止和提醒不变"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(payload.deferredTaskIDs, id: \.self) { taskID in
                        deferredReviewRow(
                            display: candidate.displayFacts.tasks[taskID],
                            taskID: taskID,
                            scope: scope
                        )
                    }
                }
                .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoToolSurface))
            }

            if !remaining.isEmpty {
                Text(String(localized: "其他可调整"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(remaining.enumerated()), id: \.element.taskID) { _, display in
                        unselectedReviewRow(display: display, scope: scope)
                    }
                }
                .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoToolSurface))
            }
        }
    }

    /// 已选行：顺序徽章 + 目标（整件事/只推进一步）+ 放下出口。
    private func reviewRow(
        display: HoloTodayReliefDisplayFacts.TaskDisplay?,
        entry: HoloTodaySelectionEntry,
        order: Int,
        scope: HoloTodayDayScope
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("\(order + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.holoPrimary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.holoPrimary.opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(display?.title ?? String(localized: "任务"))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if case .existingStep = entry.goal {
                            Text(String(localized: "只推进：\(display?.currentStepAction ?? "")"))
                                .font(.caption2)
                                .foregroundStyle(Color.holoPrimary)
                                .lineLimit(1)
                        }
                        if let dueTag = deadlineTag(display) {
                            Text(dueTag)
                                .font(.caption2)
                                .foregroundStyle(display?.isOverdue == true ? Color.holoError : Color.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button {
                    viewModel.deferTask(entry.taskID, scope: scope)
                } label: {
                    Text(String(localized: "放下"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.holoToolSurface.opacity(0.8)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("今天先放下 \(display?.title ?? "")"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // 已有步骤：整件事 / 只推进一步 二选一（重新选择须明确；§7.4）
            if let display, display.hasSteps, display.currentStepID != nil {
                HStack(spacing: 8) {
                    goalChip(
                        title: String(localized: "整件事"),
                        isSelected: entry.goal.isTaskResult
                    ) {
                        viewModel.setGoal(taskID: entry.taskID, goal: .taskResult)
                    }
                    goalChip(
                        title: String(localized: "只推进一步：\(display.currentStepAction ?? "")"),
                        isSelected: !entry.goal.isTaskResult
                    ) {
                        viewModel.setGoal(taskID: entry.taskID, goal: .existingStep(
                            stepID: display.currentStepID!,
                            originRevisionID: display.currentStepRevisionID ?? UUID(),
                            contentFingerprint: display.currentStepFingerprint ?? ""
                        ))
                    }
                }
                .padding(.horizontal, 44)
                .padding(.bottom, 10)
            }
        }
    }

    private func goalChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.holoPrimary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? Color.holoPrimary.opacity(0.1) : Color.holoToolSurface.opacity(0.8)))
        }
        .buttonStyle(.plain)
    }

    /// 已放下行：今日到期/逾期显示风险；确认才成为有效候选（§4.3）。
    private func deferredReviewRow(
        display: HoloTodayReliefDisplayFacts.TaskDisplay?,
        taskID: UUID,
        scope: HoloTodayDayScope
    ) -> some View {
        let needsAck = display.map {
            HoloTodayReliefPolicy.needsDeadlineAcknowledgement(dueDate: $0.dueAt, isAllDay: $0.isAllDay, scope: scope)
        } ?? false
        let acknowledged = viewModel.candidate?.payload.deadlineAcknowledgements.contains {
            $0.taskID == taskID && Self.hasValidAcknowledgement($0, display: display)
        } ?? false

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(display?.title ?? String(localized: "任务"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let dueTag = deadlineTag(display) {
                    Text(dueTag)
                        .font(.caption2)
                        .foregroundStyle(display?.isOverdue == true ? Color.holoError : Color.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    viewModel.setGoal(taskID: taskID, goal: .taskResult)
                } label: {
                    Text(String(localized: "还是放回来"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.holoPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if needsAck && !acknowledged {
                VStack(alignment: .leading, spacing: 6) {
                    Text(riskLine(display))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button {
                        viewModel.acknowledgeDeadlineRisk(taskID, scope: scope)
                    } label: {
                        Text(String(localized: "我知道，今天先放下"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.orange.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("todayReliefAckButton-\(taskID.uuidString.prefix(8))")
                }
                .padding(.horizontal, 38)
                .padding(.bottom, 10)
            }
        }
    }

    /// 未选行：加入今天。
    private func unselectedReviewRow(display: HoloTodayReliefDisplayFacts.TaskDisplay, scope: HoloTodayDayScope) -> some View {
        HStack(spacing: 10) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.4)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(display.title)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let dueTag = deadlineTag(display) {
                        Text(dueTag)
                            .font(.caption2)
                            .foregroundStyle(display.isOverdue ? Color.holoError : Color.secondary)
                    }
                    if let matter = display.matterTitle {
                        Text(matter)
                            .font(.caption2)
                            .foregroundStyle(Color.holoPrimary)
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                viewModel.setGoal(taskID: display.taskID, goal: .taskResult)
            } label: {
                Text(String(localized: "今天做"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.holoPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("把 \(display.title) 放进今天"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }

    private func constraintLine(_ row: HoloTodayPlanConstraintRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(row.title)
                .font(.caption2)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    /// 底部采用条：无变化 = 按原安排继续（不生成假回执）；
    /// 放下今日到期/逾期但未行内确认 → 禁用（服务端也会拒绝，这里提前给反馈）。
    private func adoptBar(candidate: HoloTodayReliefCandidate) -> some View {
        let unchanged: Bool = {
            if let current = context?.currentPlanPayload, current.selectionMode == .explicit {
                return current == candidate.payload
            }
            return false
        }()
        let pendingAck = pendingAcknowledgementCount(candidate)

        return VStack(spacing: 8) {
            if viewModel.phase == .review {
                if pendingAck > 0 {
                    Text(String(localized: "还有 \(pendingAck) 件今天到期的事需要先确认放下"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button {
                    if unchanged {
                        // 无变化：直接关闭，不写版本、不发成功保存回执（§4.3）
                        viewModel.teardown()
                        dismiss()
                    } else {
                        viewModel.adopt()
                    }
                } label: {
                    Text(unchanged
                         ? String(localized: "按原安排继续")
                         : String(localized: "采用这个安排"))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(pendingAck > 0 ? Color.holoPrimary.opacity(0.4) : Color.holoPrimary))
                }
                .buttonStyle(.plain)
                .disabled(pendingAck > 0)
                .accessibilityIdentifier("todayReliefAdoptButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func pendingAcknowledgementCount(_ candidate: HoloTodayReliefCandidate) -> Int {
        candidate.payload.deferredTaskIDs.filter { taskID in
            guard let display = candidate.displayFacts.tasks[taskID] else { return false }
            let needsAck = HoloTodayReliefPolicy.needsDeadlineAcknowledgement(
                dueDate: display.dueAt, isAllDay: display.isAllDay, scope: candidate.scope
            )
            let ackValid = candidate.payload.deadlineAcknowledgements.contains {
                $0.taskID == taskID
                    && $0.deadlineFingerprint == HoloTodayReliefPolicy.deadlineFingerprint(dueDate: display.dueAt, isAllDay: display.isAllDay)
            }
            return needsAck && !ackValid
        }.count
    }

    // MARK: 回执（§4.4）

    private func adoptedView(deferredCount: Int, undoable: UUID?) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.holoSuccess)
            Text(deferredCount > 0
                 ? String(localized: "已更新今天，\(deferredCount) 件事今天先放下")
                 : String(localized: "已更新今天的安排"))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(String(localized: "放下的仍在原清单，截止和提醒都保留。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if undoable != nil {
                Button {
                    viewModel.undoAdopt()
                } label: {
                    Text(String(localized: "撤销安排"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.holoToolSurface))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("todayReliefUndoButton")
            }

            Button {
                viewModel.teardown()
                dismiss()
            } label: {
                Text(String(localized: "好"))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoPrimary))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("todayReliefDoneButton")
            Spacer()
        }
        .padding(24)
    }

    private func failedView(message: String, canRetry: Bool, context: HoloTodayReliefSessionContext) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(String(localized: "你的输入和现有安排都还在。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if canRetry {
                Button {
                    viewModel.retry()
                } label: {
                    Text(String(localized: "再试一次"))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoPrimary))
                }
                .buttonStyle(.plain)
            }
            Button {
                // 手动模式兜底（R27：失败后手动可用）
                viewModel.submit(context: context)
            } label: {
                Text(String(localized: "先手动挑"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.holoPrimary)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - 文案工具

    private func deadlineTag(_ display: HoloTodayReliefDisplayFacts.TaskDisplay?) -> String? {
        guard let display, let dueAt = display.dueAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = display.isAllDay ? "M/d" : "M/d HH:mm"
        return String(localized: "截止 \(formatter.string(from: dueAt))")
    }

    private func riskLine(_ display: HoloTodayReliefDisplayFacts.TaskDisplay?) -> String {
        guard let display else { return String(localized: "这件事今天到期。") }
        if display.isOverdue {
            return String(localized: "「\(display.title)」已经过了截止时间，今天放下后明天还会提醒你。")
        }
        return String(localized: "「\(display.title)」今天到期，放下后截止和提醒仍然保留。")
    }
}

extension TodayReliefSheet {
    /// 确认指纹与当前任务期限事实一致（期限被编辑 → 原确认失效；§4.3）。
    nonisolated static func hasValidAcknowledgement(
        _ acknowledgement: HoloTodayDeadlineAcknowledgement,
        display: HoloTodayReliefDisplayFacts.TaskDisplay?
    ) -> Bool {
        guard let display else { return false }
        return acknowledgement.deadlineFingerprint
            == HoloTodayReliefPolicy.deadlineFingerprint(dueDate: display.dueAt, isAllDay: display.isAllDay)
    }
}
