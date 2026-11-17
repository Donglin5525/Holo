//
//  GoalLinkManagerSheet.swift
//  Holo
//
//  目标行动入口：
//  1) GoalQuickTaskSheet：直接在本目标下新建任务并自动关联
//  2) GoalLinkManagerSheet：按「任务 / 习惯」分栏筛选 + 搜索关联已有项（HoloSheetScaffold 壳）
//

import SwiftUI

// MARK: - 直接为目标新建任务

struct GoalQuickTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goal: Goal
    let onSaved: () -> Void

    @State private var title = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var isFocused: Bool

    init(goal: Goal, onSaved: @escaping () -> Void = {}) {
        self.goal = goal
        self.onSaved = onSaved
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HoloSheetScaffold(
            title: String(localized: "新建任务"),
            onClose: { dismiss() },
            primaryTitle: isSaving ? String(localized: "保存中") : String(localized: "添加"),
            primaryAction: { save() },
            primaryDisabled: isSaving || trimmedTitle.isEmpty,
            primaryActionColor: GoalJourneyStyle.action,
            footerBackground: GoalJourneyStyle.sheetFooterCream
        ) {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                TextField(String(localized: "为「\(goal.title)」加一步"), text: $title)
                    .goalJourneyText(.body)
                    .foregroundStyle(Color.holoToolText)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        if !trimmedTitle.isEmpty { save() }
                    }
                    .padding(HoloSpacing.md)
                    .holoSurface()
            }
            .padding(.horizontal, HoloSpacing.page)
            .padding(.top, HoloSpacing.md)
        }
        .presentationDetents([.height(240)])
        .onAppear { isFocused = true }
        .alert("添加失败", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        guard !isSaving, !trimmedTitle.isEmpty else { return }
        isSaving = true
        do {
            let task = try TodoRepository.shared.createTask(title: trimmedTitle)
            try GoalRepository.shared.linkTask(task, to: goal)
            GoalNotificationService.broadcastGoalDataChange()
            HapticManager.success()
            onSaved()
            dismiss()
        } catch {
            isSaving = false
            saveError = error.localizedDescription
        }
    }
}

// MARK: - 从已有任务/习惯筛选关联

struct GoalLinkManagerSheet: View {
    private enum Tab: CaseIterable {
        case tasks, habits
        var title: String { self == .tasks ? String(localized: "任务") : String(localized: "习惯") }
    }

    @Environment(\.dismiss) private var dismiss
    let goal: Goal

    @State private var selectedTab: Tab = .tasks
    @State private var query = ""
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

    private var filteredTasks: [TodoTask] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allTasks }
        return allTasks.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var filteredHabits: [Habit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allHabits }
        return allHabits.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        HoloSheetScaffold(
            title: String(localized: "关联已有项"),
            onClose: { dismiss() },
            primaryTitle: isSaving ? String(localized: "保存中") : String(localized: "保存"),
            primaryAction: { save() },
            primaryDisabled: isSaving,
            primaryActionColor: GoalJourneyStyle.action,
            footerBackground: GoalJourneyStyle.sheetFooterCream
        ) {
            VStack(spacing: HoloSpacing.md) {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.holoToolTextSecondary)
                    TextField(String(localized: "搜索"), text: $query)
                        .goalJourneyText(.supporting)
                        .foregroundStyle(Color.holoToolText)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.holoToolTextSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 10)
                .holoSurface()
                .padding(.horizontal, HoloSpacing.page)

                HStack(spacing: HoloSpacing.sm) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        let count = tab == .tasks ? selectedTaskIds.count : selectedHabitIds.count
                        HoloFilterChip(
                            title: count > 0 ? "\(tab.title) \(count)" : tab.title,
                            iconColor: GoalJourneyStyle.action,
                            isSelected: selectedTab == tab
                        ) {
                            selectedTab = tab
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.page)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: HoloSpacing.sm) {
                        if selectedTab == .tasks {
                            if filteredTasks.isEmpty {
                                emptyRow(String(localized: "没有可选任务"))
                            } else {
                                ForEach(filteredTasks.renderable, id: \.id) { task in
                                    let isOn = selectedTaskIds.contains(task.id)
                                    selectableRow(title: task.title, icon: "checklist", isSelected: isOn) {
                                        if isOn { selectedTaskIds.remove(task.id) } else { selectedTaskIds.insert(task.id) }
                                    }
                                }
                            }
                        } else {
                            if filteredHabits.isEmpty {
                                emptyRow(String(localized: "没有可选习惯"))
                            } else {
                                ForEach(filteredHabits.renderable, id: \.id) { habit in
                                    let isOn = selectedHabitIds.contains(habit.id)
                                    selectableHabitRow(habit: habit, isSelected: isOn) {
                                        if isOn { selectedHabitIds.remove(habit.id) } else { selectedHabitIds.insert(habit.id) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, HoloSpacing.page)
                    .padding(.bottom, HoloSpacing.xl)
                }
            }
            .padding(.top, HoloSpacing.sm)
        }
        .presentationDetents([.height(520), .large])
        .onAppear { loadCurrentState() }
        .alert("保存失败", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func selectableRow(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolTextSecondary)
                    .frame(width: 24)
                Text(title)
                    .goalJourneyText(.row)
                    .foregroundStyle(Color.holoToolText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolBorder)
            }
            .padding(HoloSpacing.md)
            .holoSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
    }

    private func selectableHabitRow(habit: Habit, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                habit.iconImage(size: 16)
                    .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolTextSecondary)
                    .frame(width: 24, height: 24)
                Text(habit.name)
                    .goalJourneyText(.row)
                    .foregroundStyle(Color.holoToolText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolBorder)
            }
            .padding(HoloSpacing.md)
            .holoSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .goalJourneyText(.supporting)
            .foregroundStyle(Color.holoToolTextSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 32)
    }

    private func loadCurrentState() {
        allTasks = TodoRepository.shared.activeTasks
        allHabits = HabitRepository.shared.activeHabits
        selectedTaskIds = Set(goal.sortedTasks.map(\.id))
        selectedHabitIds = Set(goal.sortedHabits.map(\.id))
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
