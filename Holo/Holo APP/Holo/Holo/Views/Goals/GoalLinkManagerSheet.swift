//
//  GoalLinkManagerSheet.swift
//  Holo
//
//  目标关联管理：勾选任务/习惯是否关联本目标，保存时 diff 增删关联
//

import SwiftUI

struct GoalLinkManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goal: Goal

    @State private var allTasks: [TodoTask] = []
    @State private var allHabits: [Habit] = []
    @State private var selectedTaskIds: Set<UUID> = []
    @State private var selectedHabitIds: Set<UUID> = []
    @State private var isSaving = false
    @State private var saveError: String?
    let onSaved: () -> Void

    init(goal: Goal, onSaved: @escaping () -> Void = {}) {
        self.goal = goal
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(allTasks, id: \.id) { task in
                        linkRow(title: task.title, icon: "checklist", isOn: Binding(
                            get: { selectedTaskIds.contains(task.id) },
                            set: { setLinked($0, taskId: task.id) }
                        ))
                    }
                    if allTasks.isEmpty {
                        Text("暂无未删除任务")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }
                } header: {
                    Text("任务")
                }

                Section {
                    ForEach(allHabits, id: \.id) { habit in
                        linkRow(title: habit.name, icon: "checkmark.circle", isOn: Binding(
                            get: { selectedHabitIds.contains(habit.id) },
                            set: { setLinked($0, habitId: habit.id) }
                        ))
                    }
                    if allHabits.isEmpty {
                        Text("暂无活跃习惯")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }
                } header: {
                    Text("习惯")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("管理关联")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中" : "保存") { save() }
                        .disabled(isSaving)
                        .fontWeight(.semibold)
                }
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
        .onAppear { loadCurrentState() }
    }

    private func linkRow(title: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.holoPrimary)
            Image(systemName: icon)
                .foregroundColor(.holoPrimary)
            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
        }
    }

    private func loadCurrentState() {
        allTasks = TodoRepository.shared.activeTasks
        allHabits = HabitRepository.shared.activeHabits
        selectedTaskIds = Set(goal.sortedTasks.map(\.id))
        selectedHabitIds = Set(goal.sortedHabits.map(\.id))
    }

    private func setLinked(_ linked: Bool, taskId: UUID) {
        if linked { selectedTaskIds.insert(taskId) } else { selectedTaskIds.remove(taskId) }
    }

    private func setLinked(_ linked: Bool, habitId: UUID) {
        if linked { selectedHabitIds.insert(habitId) } else { selectedHabitIds.remove(habitId) }
    }

    private func save() {
        isSaving = true
        do {
            let repository = GoalRepository.shared

            for task in allTasks where selectedTaskIds.contains(task.id) {
                try repository.linkTask(task, to: goal)
            }
            for task in goal.sortedTasks where !selectedTaskIds.contains(task.id) {
                try repository.unlinkTask(task, from: goal)
            }

            for habit in allHabits where selectedHabitIds.contains(habit.id) {
                try repository.linkHabit(habit, to: goal)
            }
            for habit in goal.sortedHabits where !selectedHabitIds.contains(habit.id) {
                try repository.unlinkHabit(habit, from: goal)
            }

            GoalNotificationService.broadcastGoalDataChange()
            isSaving = false
            onSaved()
            dismiss()
        } catch {
            isSaving = false
            saveError = error.localizedDescription
        }
    }
}
