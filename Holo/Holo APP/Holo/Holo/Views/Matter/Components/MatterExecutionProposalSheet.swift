//
//  MatterExecutionProposalSheet.swift
//  Holo
//
//  分步推进提案预览与采纳（2026-09-25 实施规格 §4.2）
//  一次确认原子保存「结果条件 + 计划」；预览不创建任何业务对象；关掉原任务不变。
//  生成失败：「这次没拆出来，可以重试或自己写一步」，不说任务不清楚。
//  澄清（clarification）：只问一个问题，答案带入重新生成。
//

import SwiftUI

struct MatterExecutionProposalSheet: View {

    let taskID: UUID
    @ObservedObject var repository: TodoRepository
    var originMatterID: UUID? = nil
    var sourceSurface: String = "matter"
    /// 卡住面板带入的障碍语（有值 = 局部修订模式）
    var initialObstacle: String? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .generating
    @State private var outcomeSummary: String = ""
    @State private var verificationPrompt: String = ""
    @State private var stepDrafts: [StepDraft] = []
    @State private var requirements: [HoloTaskExecutionRequirement] = []
    @State private var patchMode: HoloTaskExecutionPatchMode?
    @State private var baseFingerprint: String = ""
    @State private var adoptError: String?
    @State private var clarification: HoloTaskExecutionClarification?
    @State private var cannotHelp: HoloTaskExecutionCannotHelp?
    @State private var clarificationAnswer: String = ""
    @State private var manualMode = false

    private let coordinator = HoloTaskExecutionProposalCoordinator.shared
    private let service = HoloTaskExecutionService.shared

    enum Phase: Equatable {
        case generating
        case ready
        case failed
    }

    struct StepDraft: Identifiable {
        let id = UUID()
        var action: String
        var doneWhen: String
        var role: HoloTaskExecutionStepRole
        var coversRequirementIDs: [String]
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(initialObstacle == nil ? String(localized: "帮我拆开") : String(localized: "拆小一点"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "先不用")) {
                            coordinator.cancel(taskID: taskID)
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if phase == .ready {
                            Button(String(localized: "按这个推进")) {
                                adopt()
                            }
                            .font(.body.weight(.semibold))
                            .disabled(!canAdopt)
                        }
                    }
                }
        }
        .task {
            if phase == .generating, stepDrafts.isEmpty, clarification == nil {
                await generate(userAnswer: nil)
            }
        }
    }

    private var canAdopt: Bool {
        stepDrafts.contains { !$0.action.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @ViewBuilder
    private var content: some View {
        if let clarification {
            clarificationView(clarification)
        } else {
            switch phase {
            case .generating: generatingView
            case .failed: failedView
            case .ready: readyView
            }
        }
    }

    /// 一次澄清：问题 + 候选答案 + 自由输入；选完带答案重新生成
    private func clarificationView(_ c: HoloTaskExecutionClarification) -> some View {
        Form {
            Section(String(localized: "先确认一件事")) {
                Text(verbatim: c.question)
                    .font(.subheadline)
            }
            if !c.suggestedAnswers.isEmpty {
                Section {
                    ForEach(c.suggestedAnswers, id: \.self) { answer in
                        Button {
                            clarification = nil
                            phase = .generating
                            Task { await generate(userAnswer: answer) }
                        } label: {
                            Text(verbatim: answer)
                                .font(.subheadline)
                        }
                    }
                }
            }
            Section {
                TextField(String(localized: "或者自己回答"), text: $clarificationAnswer)
                Button(String(localized: "按这个继续")) {
                    let answer = clarificationAnswer
                    clarification = nil
                    clarificationAnswer = ""
                    phase = .generating
                    Task { await generate(userAnswer: answer) }
                }
                .disabled(clarificationAnswer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: 生成中（可取消；原任务不受影响）

    private var generatingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(String(localized: "正在想怎么拆……"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(String(localized: "取消")) {
                coordinator.cancel(taskID: taskID)
                dismiss()
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 失败（可重试或手写）

    private var failedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "cloud")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(verbatim: cannotHelp?.reason ?? String(localized: "这次没拆出来，可以重试或自己写一步"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let manual = cannotHelp?.suggestedManualAction, !manual.isEmpty {
                Text(verbatim: manual)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                Button(String(localized: "重试")) {
                    phase = .generating
                    Task { await generate(userAnswer: nil) }
                }
                .buttonStyle(.borderedProminent)
                Button(String(localized: "自己写一步")) {
                    enterManualMode()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: 预览（唯一主要按钮 = 按这个推进）

    private var readyView: some View {
        List {
            if let task = HoloTaskExecutionRepository(context: repository.context).findTask(taskID) {
                Section {
                    Text(verbatim: task.title)
                        .font(.subheadline.weight(.semibold))
                }
            }

            if let adoptError {
                Section {
                    Label(adoptError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section(String(localized: "做到这里就算完成")) {
                TextField(String(localized: "一句话描述结果"), text: $outcomeSummary, axis: .vertical)
                    .font(.subheadline)
            }

            if manualMode {
                manualStepsSection
            } else {
                aiStepsSection
            }

            Section {
                Text(String(localized: "采纳后：原任务数不变，步骤不会出现在今天列表；「这步好了」可随时撤回。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var manualStepsSection: some View {
        Section(String(localized: "自己写的步骤")) {
            ForEach($stepDrafts) { $draft in
                VStack(alignment: .leading, spacing: 6) {
                    TextField(String(localized: "做什么"), text: $draft.action)
                        .font(.subheadline)
                    TextField(String(localized: "做到什么算这步完成"), text: $draft.doneWhen)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { stepDrafts.remove(atOffsets: $0) }
            Button {
                stepDrafts.append(StepDraft(action: "", doneWhen: "", role: .execution, coversRequirementIDs: []))
            } label: {
                Label(String(localized: "再加一步"), systemImage: "plus.circle")
                    .font(.subheadline)
            }
        }
    }

    private var aiStepsSection: some View {
        Section(String(localized: "步骤")) {
            ForEach(Array(stepDrafts.enumerated()), id: \.element.id) { index, draft in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if index == 0 {
                            Text(String(localized: "先做"))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.holoPrimary))
                        }
                        Text(verbatim: draft.action)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(verbatim: "做到：\(draft.doneWhen)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(index + 1)，\(draft.action)")
            }
            if initialObstacle == nil {
                // 首次拆解可微调步骤文字（规格 §4.2：结果条件与计划一起确认）
                ForEach($stepDrafts) { $draft in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(String(localized: "步骤"), text: $draft.action)
                            .font(.caption)
                        TextField(String(localized: "完成条件"), text: $draft.doneWhen)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 生成

    private func generate(userAnswer: String?) async {
        adoptError = nil
        let execRepo = HoloTaskExecutionRepository(context: repository.context)
        guard execRepo.findTask(taskID) != nil else {
            phase = .failed
            return
        }

        let candidate: HoloTaskExecutionCandidate?
        if let obstacle = initialObstacle {
            guard let view = execRepo.executionView(taskID: taskID, cursorStepID: nil),
                  let revision = view.revision,
                  let targetID = view.currentStepID else {
                phase = .failed
                return
            }
            candidate = await coordinator.generateRevision(
                taskID: taskID,
                revisionID: revision.id,
                targetStepID: targetID,
                userObstacle: answerMerged(obstacle, userAnswer),
                repository: execRepo
            )
        } else {
            candidate = await coordinator.generateInitial(
                taskID: taskID,
                originMatterID: originMatterID,
                userAnswer: userAnswer,
                repository: execRepo
            )
        }

        guard let candidate else {
            phase = .failed
            return
        }

        switch candidate.outcome {
        case .clarification(let c):
            // 一次澄清：展示问题与候选答案，选完带答案重跑（规格 §3.2）
            clarification = c
        case .cannotHelp(let c):
            cannotHelp = c
            phase = .failed
        case .proposal(let proposal):
            apply(proposal: proposal, fingerprint: candidate.fingerprint)
        }
    }

    private func answerMerged(_ obstacle: String, _ answer: String?) -> String {
        guard let answer, !answer.isEmpty else { return obstacle }
        return "\(obstacle)（用户补充：\(answer)）"
    }

    private func apply(proposal: HoloTaskExecutionProposal, fingerprint: String) {
        outcomeSummary = proposal.outcomeSummary
        verificationPrompt = proposal.verificationPrompt
        patchMode = proposal.patch.mode
        baseFingerprint = fingerprint
        requirements = proposal.requirements ?? []
        stepDrafts = proposal.patch.newSteps.map { step in
            StepDraft(
                action: step.action,
                doneWhen: step.doneWhen,
                role: step.role ?? .execution,
                coversRequirementIDs: step.coversRequirementIDs
            )
        }
        phase = .ready
    }

    private func enterManualMode() {
        manualMode = true
        patchMode = nil
        if outcomeSummary.isEmpty {
            outcomeSummary = HoloTaskExecutionRepository(context: repository.context).findTask(taskID)?.title ?? ""
        }
        if stepDrafts.isEmpty {
            stepDrafts = [StepDraft(action: "", doneWhen: "", role: .execution, coversRequirementIDs: [])]
        }
        phase = .ready
    }

    // MARK: - 采纳（原子；预览不写库，采纳才写）

    private func adopt() {
        adoptError = nil
        let execRepo = HoloTaskExecutionRepository(context: repository.context)
        guard let task = execRepo.findTask(taskID) else { return }
        let drafts = stepDrafts.filter { !$0.action.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !drafts.isEmpty else { return }

        // 局部修订采纳：沿用 AI patch 模式（refine/prepend/revise），历史版本保留
        if initialObstacle != nil, !manualMode, let mode = patchMode {
            guard let view = execRepo.executionView(taskID: taskID, cursorStepID: nil),
                  let revision = view.revision,
                  let targetID = view.currentStepID else { return }
            let patch = HoloTaskExecutionProposalPatch(
                mode: mode,
                targetStepID: targetID,
                newSteps: drafts.enumerated().map { index, draft in
                    HoloTaskExecutionNewStep(
                        ref: "s\(index + 1)",
                        action: draft.action,
                        doneWhen: draft.doneWhen,
                        roleRaw: draft.role.rawValue,
                        dependsOnRefs: [],
                        coversRequirementIDs: draft.coversRequirementIDs
                    )
                },
                retainedStepIDs: [],
                retainTarget: true,
                requirements: nil
            )
            do {
                _ = try service.revisePlan(
                    taskID: taskID,
                    proposal: HoloTaskExecutionProposal(
                        kind: "proposal",
                        outcomeSummary: outcomeSummary,
                        verificationPrompt: revision.outcomeContract?.verificationPrompt ?? "",
                        patch: patch,
                        scopeChanges: []
                    ),
                    expectedFingerprint: execRepo.currentSnapshotFingerprint(taskID: taskID) ?? baseFingerprint,
                    operationID: UUID().uuidString,
                    sourceSurface: sourceSurface,
                    in: repository
                )
                dismiss()
            } catch {
                adoptError = MatterExecutionContent.describe(error)
            }
            return
        }

        // 首次采纳：AI 步骤全部无覆盖声明时，补一个终端核验节点兜底（规格 §5.4 终端核验）
        var adopted = drafts
        if adopted.allSatisfy({ $0.coversRequirementIDs.isEmpty }) {
            adopted.append(StepDraft(
                action: String(localized: "核对：\(outcomeSummary)"),
                doneWhen: verificationPrompt.isEmpty ? String(localized: "能确认结果成立") : verificationPrompt,
                role: .verification,
                coversRequirementIDs: requirements.map(\.id)
            ))
        }

        do {
            _ = try service.adopt(
                HoloTaskExecutionService.AdoptionInput(
                    taskID: taskID,
                    expectedFingerprint: execRepo.currentSnapshotFingerprint(taskID: taskID) ?? baseFingerprint,
                    outcomeSummary: outcomeSummary.isEmpty ? task.title : outcomeSummary,
                    verificationPrompt: verificationPrompt.isEmpty ? String(localized: "结果都达成了吗？") : verificationPrompt,
                    requirements: requirements,
                    steps: adopted.map {
                        HoloTaskExecutionManualStep(
                            action: $0.action,
                            doneWhen: $0.doneWhen,
                            role: $0.role,
                            coversRequirementIDs: $0.coversRequirementIDs
                        )
                    },
                    originMatterID: originMatterID,
                    acceptedSource: manualMode ? .manual : .userAcceptedAI,
                    operationID: UUID().uuidString,
                    sourceSurface: sourceSurface
                ),
                in: repository
            )
            dismiss()
        } catch {
            adoptError = MatterExecutionContent.describe(error)
        }
    }
}
