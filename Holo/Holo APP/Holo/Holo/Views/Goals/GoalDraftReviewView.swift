//
//  GoalDraftReviewView.swift
//  Holo
//
//  目标草案确认看板：编辑、选择任务/习惯、授权、保存
//

import SwiftUI

struct GoalDraftReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GoalDraft
    @State private var allowAIContext = true
    @State private var showCancelConfirm = false
    @State private var isSaving = false

    let onCancel: () -> Void
    let onSaved: (GoalDraftSaveResult) -> Void

    init(
        draft: GoalDraft,
        onCancel: @escaping () -> Void,
        onSaved: @escaping (GoalDraftSaveResult) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.onCancel = onCancel
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                goalSection
                tasksSection
                habitsSection
                authorizationSection
            }
            .navigationTitle("确认目标计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showCancelConfirm = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中" : "保存") { save() }
                        .disabled(isSaving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        }
    }

    private var goalSection: some View {
        Section("目标") {
            TextField("标题", text: $draft.title)
            TextField("说明", text: Binding(
                get: { draft.summary ?? "" },
                set: { draft.summary = $0 }
            ), axis: .vertical)
            Picker("领域", selection: $draft.domain) {
                ForEach(GoalDomain.allCases) { domain in
                    Text(domain.displayName).tag(domain)
                }
            }
        }
    }

    private var tasksSection: some View {
        Section("任务") {
            ForEach($draft.tasks) { $task in
                Toggle(isOn: $task.isSelected) {
                    TextField("任务标题", text: $task.title)
                }
            }
        }
    }

    private var habitsSection: some View {
        Section("习惯") {
            ForEach($draft.habits) { $habit in
                VStack(alignment: .leading) {
                    Toggle(isOn: $habit.isSelected) {
                        TextField("习惯名称", text: $habit.name)
                    }
                    Picker("频率", selection: $habit.frequency) {
                        ForEach(HabitFrequency.allCases) { frequency in
                            Text(frequency.displayName).tag(frequency.rawValue)
                        }
                    }
                    Stepper("目标次数 \(habit.targetCount ?? 1)", value: Binding(
                        get: { habit.targetCount ?? 1 },
                        set: { habit.targetCount = $0 }
                    ), in: 1...30)
                }
            }
        }
    }

    private var authorizationSection: some View {
        Section("AI 上下文") {
            Toggle("允许 HoloAI 后续参考此目标", isOn: $allowAIContext)
        }
    }

    private func save() {
        isSaving = true
        do {
            let result = try GoalRepository.shared.saveDraft(draft, allowAIContext: allowAIContext)
            onSaved(result)
            dismiss()
        } catch {
            isSaving = false
        }
    }
}
