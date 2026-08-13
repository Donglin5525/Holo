//
//  GoalDetailView.swift
//  Holo
//
//  目标详情视图：状态操作、关联任务/习惯、AI 授权开关
//

import SwiftUI

struct GoalDetailView: View {
    @ObservedObject private var repository = GoalRepository.shared
    @ObservedObject var goal: Goal
    let onOpenLinkedEntity: (DeepLinkTarget) -> Void
    let onDeleteRequested: (UUID) -> Void
    @State private var showDeleteConfirm = false
    @State private var operationError: String?
    @State private var showEditForm = false

    init(
        goal: Goal,
        onOpenLinkedEntity: @escaping (DeepLinkTarget) -> Void = { _ in },
        onDeleteRequested: @escaping (UUID) -> Void = { _ in }
    ) {
        self.goal = goal
        self.onOpenLinkedEntity = onOpenLinkedEntity
        self.onDeleteRequested = onDeleteRequested
    }

    var body: some View {
        let progress = GoalProgressEvaluator.evaluate(goal: goal)

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                header(progress)
                aiContextToggle
                proactiveNudgeToggle
                taskSection
                habitSection
                actionSection
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
        .navigationTitle("目标详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除目标", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除目标", role: .destructive) {
                onDeleteRequested(goal.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除目标后，基于该目标创建的任务和习惯不会被删除，只会解除与该目标的关联。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
        .sheet(isPresented: $showEditForm) {
            GoalEditSheet(goal: goal) {
                showEditForm = false
            }
        }
    }

    private func header(_ progress: GoalProgressSummary) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(goal.title)
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)
            if let summary = goal.summary, !summary.isEmpty {
                Text(summary)
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }
            Text("\(progress.state.displayName) · \(progress.taskSummary) · \(progress.habitSummary)")
                .font(.system(size: 13))
                .foregroundColor(.holoPrimary)
            if let desiredOutcome = goal.desiredOutcome, !desiredOutcome.isEmpty {
                infoLine(icon: "checkmark.seal", label: "期望结果", value: desiredOutcome)
            }
            if let motivation = goal.motivation, !motivation.isEmpty {
                infoLine(icon: "heart", label: "动机", value: motivation)
            }
            if let deadline = goal.deadline {
                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: deadline)).day ?? 0
                infoLine(
                    icon: "calendar",
                    label: "截止日期",
                    value: days >= 0 ? "\(GoalEditForm.formatDeadline(deadline))（还剩 \(days) 天）" : "\(GoalEditForm.formatDeadline(deadline))（已逾期 \(-days) 天）"
                )
            }
        }
    }

    private func infoLine(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 16)
            Text("\(label)：")
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.holoTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiContextToggle: some View {
        Toggle("允许 HoloAI 后续参考此目标", isOn: Binding(
            get: { goal.allowAIContext },
            set: { newValue in
                perform {
                    try repository.updateAIContext(goal, allow: newValue)
                }
            }
        ))
        .font(.holoBody)
        .padding(HoloSpacing.md)
        .holoCard()
    }

    private var proactiveNudgeToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("允许 HoloAI 主动围绕此目标提醒", isOn: Binding(
                get: { goal.allowAIContext && goal.proactiveNudge },
                set: { newValue in
                    perform {
                        try repository.updateProactiveNudge(goal, enabled: newValue)
                    }
                }
            ))
            .font(.holoBody)
            .disabled(!goal.allowAIContext)

            if !goal.allowAIContext {
                Text("需先开启「允许 HoloAI 参考此目标」")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.leading, 4)
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("关联任务").font(.holoBody).fontWeight(.semibold)
            if goal.sortedTasks.isEmpty {
                Text("暂无关联任务")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            } else {
                ForEach(goal.sortedTasks, id: \.id) { task in
                    linkedEntityRow(title: task.title, icon: "checklist") {
                        onOpenLinkedEntity(.taskDetail(taskId: task.id))
                    }
                }
            }
        }
    }

    private var habitSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("关联习惯").font(.holoBody).fontWeight(.semibold)
            if goal.sortedHabits.isEmpty {
                Text("暂无关联习惯")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            } else {
                ForEach(goal.sortedHabits, id: \.id) { habit in
                    linkedEntityRow(title: habit.name, icon: "checkmark.circle") {
                        onOpenLinkedEntity(.habitDetail(habitId: habit.id))
                    }
                }
            }
        }
    }

    private var actionSection: some View {
        VStack(spacing: HoloSpacing.sm) {
            Button("编辑目标") {
                showEditForm = true
            }
            if goal.goalStatus == .active {
                Button("暂停目标") {
                    perform { try repository.updateStatus(goal, status: .paused) }
                }
            } else if goal.goalStatus == .paused {
                Button("恢复目标") {
                    perform { try repository.updateStatus(goal, status: .active) }
                }
            }
            if goal.goalStatus != .completed {
                Button("标记完成") {
                    perform { try repository.updateStatus(goal, status: .completed) }
                }
            }
            Button("删除目标", role: .destructive) { showDeleteConfirm = true }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkedEntityRow(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: icon)
                    .foregroundColor(.holoPrimary)
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.vertical, HoloSpacing.sm)
        }
        .buttonStyle(.plain)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            operationError = error.localizedDescription
        }
    }
}

// MARK: - 编辑目标 Sheet

struct GoalEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goal: Goal
    @State private var draft: GoalDraft
    @State private var isSaving = false
    @State private var saveError: String?
    let onSaved: () -> Void

    init(goal: Goal, onSaved: @escaping () -> Void) {
        self.goal = goal
        self.onSaved = onSaved
        self._draft = State(initialValue: GoalEditForm.draft(from: goal))
    }

    private var canSave: Bool {
        !isSaving && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    GoalEditForm(draft: $draft)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
            .background(Color.holoBackground)
            .navigationTitle("编辑目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中" : "保存") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    save()
                } label: {
                    Text(isSaving ? "保存中" : "保存修改")
                        .font(.holoBody)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSave ? Color.holoPrimary : Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .disabled(!canSave)
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
                .background(Color.holoCardBackground)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: -2)
            }
            .alert("保存失败", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func save() {
        isSaving = true
        DispatchQueue.main.async {
            do {
                // deadline 从 draft.deadlineText 解析；nil 表示清空
                let parsedDeadline: Date?? = {
                    guard let text = draft.deadlineText, !text.isEmpty else { return .some(nil) }
                    return .some(GoalEditForm.parseDeadlineText(text))
                }()
                try GoalRepository.shared.updateFields(
                    goal,
                    title: draft.title,
                    summary: draft.summary,
                    domain: draft.domain,
                    desiredOutcome: draft.desiredOutcome,
                    motivation: draft.motivation,
                    deadline: parsedDeadline
                )
                isSaving = false
                onSaved()
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}
