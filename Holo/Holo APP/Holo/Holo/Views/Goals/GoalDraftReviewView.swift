//
//  GoalDraftReviewView.swift
//  Holo
//
//  目标草案确认看板：编辑、选择任务/习惯、授权、保存
//  使用 Holo 设计系统风格
//

import SwiftUI

/// 目标共创确认页附加上下文（§2.3 全字段确认）：成功证据可改、假设可删、里程碑展示
struct GoalWorkshopReviewContext {
    var session: GoalWorkshopSessionV1
    var successEvidence: String
    var assumptions: [String]
}

struct GoalDraftReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GoalDraft
    @State private var allowAIContext = true
    @State private var showCancelConfirm = false
    @State private var isSaving = false
    @State private var saveErrorText: String?
    @State private var workshopSuccessEvidence: String
    @State private var workshopAssumptions: [String]
    @State private var deadlineDate: Date?

    let workshopSession: GoalWorkshopSessionV1?
    let onCancel: () -> Void
    let onSaved: (GoalDraftSaveResult) -> Void

    init(
        draft: GoalDraft,
        workshopContext: GoalWorkshopReviewContext? = nil,
        onCancel: @escaping () -> Void,
        onSaved: @escaping (GoalDraftSaveResult) -> Void
    ) {
        _draft = State(initialValue: draft)
        _workshopSuccessEvidence = State(initialValue: workshopContext?.successEvidence ?? "")
        _workshopAssumptions = State(initialValue: workshopContext?.assumptions ?? [])
        _deadlineDate = State(initialValue: GoalWorkshopValidator.strictDayFormatter.date(from: draft.deadlineText ?? ""))
        self.workshopSession = workshopContext?.session
        self.onCancel = onCancel
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    goalInfoCard
                    outcomeCard
                    if let workshopSession {
                        workshopCard(for: workshopSession)
                    }
                    if !draft.missingInfoWarnings.isEmpty { warningsCard }
                    if !draft.tasks.isEmpty { tasksCard }
                    if !draft.habits.isEmpty { habitsCard }
                    aiContextCard
                    if let saveErrorText {
                        Label {
                            Text(saveErrorText).font(.holoCaption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
            .background(Color.holoBackground)
            .navigationTitle("确认目标计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showCancelConfirm = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? String(localized: "保存中") : String(localized: "保存")) { save() }
                        .disabled(isSaving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("放弃这次目标计划？", isPresented: $showCancelConfirm, titleVisibility: .visible) {
                Button("放弃", role: .destructive) {
                    onCancel()
                    dismiss()
                }
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("未保存的目标计划会丢失。")
            }
            .safeAreaInset(edge: .bottom) {
                bottomActions
            }
        }
        .swipeBackToDismiss {
            onCancel()
            dismiss()
        }
    }

    // MARK: - Goal Info Card

    private var goalInfoCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // Section header
            sectionHeader(icon: "target", title: String(localized: "目标信息"))

            CardDivider()

            // 标题
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("标题")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("目标标题", text: $draft.title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .padding(HoloSpacing.sm)
                    .background(Color.holoBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            // 说明
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("说明")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("目标说明（可选）", text: Binding(
                    get: { draft.summary ?? "" },
                    set: { draft.summary = $0 }
                ), axis: .vertical)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2...4)
                .padding(HoloSpacing.sm)
                .background(Color.holoBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            // 领域
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("领域")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Picker("领域", selection: $draft.domain) {
                    ForEach(GoalDomain.allCases) { domain in
                        HStack(spacing: 6) {
                            Image(systemName: domain.icon)
                            Text(domain.displayName)
                        }
                        .tag(domain)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Outcome Card（期望结果/动机/期限——§1.2 缺口补齐）

    private var outcomeCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            sectionHeader(icon: "sparkles", title: String(localized: "期望结果"))

            CardDivider()

            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("期望结果")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("达成后是什么样子（可选）", text: Binding(
                    get: { draft.desiredOutcome ?? "" },
                    set: { draft.desiredOutcome = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                    .font(.holoCaption)
                    .lineLimit(1...3)
                    .padding(HoloSpacing.sm)
                    .background(Color.holoBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("动机")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("为什么现在想做这件事（可选）", text: Binding(
                    get: { draft.motivation ?? "" },
                    set: { draft.motivation = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                    .font(.holoCaption)
                    .lineLimit(1...3)
                    .padding(HoloSpacing.sm)
                    .background(Color.holoBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            Toggle(isOn: Binding(
                get: { deadlineDate != nil },
                set: { deadlineDate = $0 ? Date() : nil }
            )) {
                Text("设置期限").font(.holoCaption)
            }
            .tint(.holoPrimary)

            if let deadlineDate {
                DatePicker("期限", selection: Binding(
                    get: { deadlineDate },
                    set: { self.deadlineDate = $0 }
                ), displayedComponents: .date)
                    .font(.holoCaption)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
    }

    // MARK: - Workshop Card（成功证据/路径代价/假设/里程碑/第一步）

    private func workshopCard(for session: GoalWorkshopSessionV1) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            sectionHeader(icon: "checkmark.seal", title: String(localized: "怎么算成了"))

            CardDivider()

            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("成功证据（能观察到什么）")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("例如：连续四周在周会至少发言一次", text: $workshopSuccessEvidence, axis: .vertical)
                    .font(.holoCaption)
                    .lineLimit(1...3)
                    .padding(HoloSpacing.sm)
                    .background(Color.holoBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            if let selectedRouteID = session.selectedRouteID,
               let route = session.routeOptions.first(where: { $0.id == selectedRouteID }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("所选路径：\(route.title)")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                    Text("这条路的代价：\(route.tradeoff)")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }

            if !workshopAssumptions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("关键假设（未确认信息，可删）")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                    ForEach(workshopAssumptions.indices, id: \.self) { index in
                        HStack {
                            Label {
                                Text(workshopAssumptions[index]).font(.holoLabel)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                            }
                            Spacer()
                            Button {
                                workshopAssumptions.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                        }
                        .foregroundColor(.holoTextSecondary)
                    }
                }
            }

            if let plan = session.plan {
                if !plan.milestones.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("里程碑").font(.holoLabel).foregroundColor(.holoTextSecondary)
                        ForEach(plan.milestones) { milestone in
                            HStack {
                                Image(systemName: "flag").font(.holoLabel)
                                Text(milestone.title).font(.holoLabel)
                                Spacer()
                                if let date = milestone.dateText {
                                    Text(date).font(.holoTinyLabel).foregroundColor(.holoTextSecondary)
                                }
                            }
                        }
                    }
                }
                if let first = plan.firstActionID,
                   let title = plan.draft.tasks.first(where: { $0.id == first })?.title
                   ?? plan.draft.habits.first(where: { $0.id == first })?.name {
                    Label {
                        Text("第一步：\(title)").font(.holoCaption)
                    } icon: {
                        Image(systemName: "shoe")
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
    }

    // MARK: - Warnings Card（§1.2：missingInfoWarnings 必须展示）

    private var warningsCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(icon: "exclamationmark.triangle", title: String(localized: "待补充信息"))
            CardDivider()
            ForEach(draft.missingInfoWarnings, id: \.self) { warning in
                Label {
                    Text(warning).font(.holoCaption).foregroundColor(.holoTextSecondary)
                } icon: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
    }

    // MARK: - Tasks Card

    private var tasksCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(
                icon: "checklist",
                title: String(localized: "任务"),
                badge: "\(draft.tasks.filter(\.isSelected).count)/\(draft.tasks.count)"
            )

            CardDivider()

            ForEach($draft.tasks) { $task in
                HStack(spacing: HoloSpacing.sm) {
                    Toggle("", isOn: $task.isSelected)
                        .labelsHidden()
                        .tint(.holoPrimary)

                    TextField("任务标题", text: $task.title)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                        .strikethrough(!task.isSelected, color: .holoTextSecondary)
                }
                .padding(.vertical, HoloSpacing.xs)

                if task.id != draft.tasks.last?.id {
                    CardDivider()
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Habits Card

    private var habitsCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(
                icon: "flame",
                title: String(localized: "习惯"),
                badge: "\(draft.habits.filter(\.isSelected).count)/\(draft.habits.count)"
            )

            CardDivider()

            ForEach($draft.habits) { $habit in
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    HStack(spacing: HoloSpacing.sm) {
                        Toggle("", isOn: $habit.isSelected)
                            .labelsHidden()
                            .tint(.holoPrimary)

                        TextField("习惯名称", text: $habit.name)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextPrimary)
                            .strikethrough(!habit.isSelected, color: .holoTextSecondary)
                    }

                    if habit.isSelected {
                        HStack(spacing: HoloSpacing.md) {
                            Picker("频率", selection: $habit.frequency) {
                                ForEach(HabitFrequency.allCases) { frequency in
                                    Text(frequency.displayName).tag(frequency.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .font(.holoLabel)

                            Stepper("目标 \(habit.targetCount ?? 1) 次", value: Binding(
                                get: { habit.targetCount ?? 1 },
                                set: { habit.targetCount = $0 }
                            ), in: 1...30)
                            .font(.holoLabel)
                        }
                        .foregroundColor(.holoTextSecondary)
                    }
                }
                .padding(.vertical, HoloSpacing.xs)

                if habit.id != draft.habits.last?.id {
                    CardDivider()
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - AI Context Card

    private var aiContextCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(icon: "sparkles", title: String(localized: "AI 上下文"))

            CardDivider()

            Toggle(isOn: $allowAIContext) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许 HoloAI 参考此目标")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                    Text("HoloAI 会基于此目标给出更精准的建议")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .tint(.holoPrimary)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Bottom Actions

    private var bottomActions: some View {
        HStack(spacing: HoloSpacing.md) {
            Button {
                showCancelConfirm = true
            } label: {
                Text("取消")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .stroke(Color.holoBorder, lineWidth: 1)
                    )
            }

            Button {
                save()
            } label: {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    }
                    Text(isSaving ? String(localized: "保存中") : String(localized: "确认保存"))
                        .font(.holoBody)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    isSaving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.gray.opacity(0.3)
                        : Color.holoPrimary
                )
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .disabled(isSaving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoCardBackground)
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: -2)
    }

    // MARK: - Helpers

    private func sectionHeader(icon: String, title: String, badge: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.holoPrimary)
                .frame(width: 24, height: 24)

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            if let badge {
                Text(badge)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.holoPrimary.opacity(0.12))
                    .cornerRadius(4)
            }
        }
    }

    private func save() {
        guard !isSaving else { return }  // 双击确认防护
        // 完整校验通过才可点（标题之外，共创会话还需成功证据非空、日期可解析）
        if let workshopSession {
            guard !workshopSuccessEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                saveErrorText = "先填「成功证据」：达成后你能观察到什么。"
                return
            }
        }
        if let deadlineDate {
            draft.deadlineText = GoalWorkshopSessionV1.dayString(from: deadlineDate)
        } else {
            draft.deadlineText = nil
        }

        isSaving = true
        saveErrorText = nil
        Task { @MainActor in
            do {
                let result: GoalDraftSaveResult
                if let workshopSession {
                    let input = GoalWorkshopCommitInput(
                        session: workshopSession,
                        draft: draft,
                        successEvidence: workshopSuccessEvidence,
                        assumptions: workshopAssumptions,
                        allowAIContext: allowAIContext
                    )
                    let receipt = try await GoalWorkshopCommitService.shared.commitWorkshop(input)
                    guard let goal = GoalRepository.shared.findGoal(by: receipt.goalID) else {
                        throw GoalWorkshopCommitService.CommitError.saveFailed("保存后读取目标失败")
                    }
                    result = GoalDraftSaveResult(
                        goal: goal,
                        createdTaskCount: receipt.createdTaskCount,
                        createdHabitCount: receipt.createdHabitCount
                    )
                } else {
                    result = try GoalRepository.shared.saveDraft(draft, allowAIContext: allowAIContext)
                }
                GoalNotificationService.broadcastGoalDataChange()
                onSaved(result)
                dismiss()
            } catch {
                // 失败必须显示具体可操作错误，不静默吞掉；草案保留可重试
                isSaving = false
                saveErrorText = Self.describeSaveError(error)
            }
        }
    }

    private static func describeSaveError(_ error: Error) -> String {
        if let commitError = error as? GoalWorkshopCommitService.CommitError {
            switch commitError {
            case .validation(let reason): return "没保存成功：\(reason)"
            case .saveFailed(let reason): return "没保存成功：\(reason)。内容还在，稍后再试一次。"
            case .sessionAlreadyApplied: return "这个目标已经保存过，不用重复保存。"
            }
        }
        if let validationError = error as? GoalWorkshopValidationError {
            return "没保存成功：日期或内容不合规（\(String(describing: validationError))）。"
        }
        return "没保存成功，内容还在，稍后再试一次。"
    }
}
