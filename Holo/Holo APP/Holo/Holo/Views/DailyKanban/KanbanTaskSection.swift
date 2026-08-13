//
//  KanbanTaskSection.swift
//  Holo
//
//  今日看板 — 待办任务列表
//

import SwiftUI
import os.log

struct KanbanTaskSection: View {

    @ObservedObject var todoRepo: TodoRepository
    @State private var showAddSheet = false
    @State private var refreshTrigger = false

    /// 撤回窗口（来自 repository 全局状态，与 TaskListView 共享）
    private var pendingCompletionTaskId: UUID? { todoRepo.pendingCompletionTaskId }

    /// 选中查看详情的任务
    private struct TaskSelection: Identifiable, Equatable {
        let id: UUID
    }
    @State private var selectedTask: TaskSelection? = nil

    private var todayTasks: [TodoTask] {
        _ = refreshTrigger
        return todoRepo.getDueTodayTasks()
    }

    private var recentTasks: [TodoTask] {
        _ = refreshTrigger
        return todoRepo.getUncompletedRecentTasks()
    }

    private var openTasks: [TodoTask] {
        _ = refreshTrigger
        return todoRepo.getUnplannedOpenTasks()
    }

    private var completedCount: Int {
        todayTasks.filter { $0.completed }.count
    }

    var body: some View {
        VStack(spacing: 8) {
            sectionHeader

            if todayTasks.isEmpty && recentTasks.isEmpty && openTasks.isEmpty {
                emptyView
            } else {
                VStack(spacing: 0) {
                    ForEach(todayTasks, id: \.id) { task in
                        taskRow(task: task)
                        if task.id != todayTasks.last?.id {
                            Divider().background(Color.holoDivider)
                        }
                    }

                    addRow
                }
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
                .shadow(color: HoloShadow.card, radius: 4, y: 1)
            }

            if !recentTasks.isEmpty || !openTasks.isEmpty {
                recentSection
            }

            // 撤回 banner（与 TaskListView 一致的 3 秒撤回体验）
            if pendingCompletionTaskId != nil {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoSuccess)
                        Text("任务已完成")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                    }

                    Spacer()

                    Button {
                        undoCompletion()
                    } label: {
                        Text("撤回")
                            .font(.holoBody)
                            .foregroundColor(.holoPrimary)
                            .fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.md)
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddTaskSheet(repository: todoRepo, list: nil)
        }
        .sheet(item: $selectedTask) { selection in
            if let task = todoRepo.findTask(by: selection.id) {
                TaskDetailView(task: task, repository: todoRepo)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoDataDidChange)) { _ in
            refreshTrigger.toggle()
        }
    }

    private var emptyView: some View {
        Text("暂无待办")
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
    }

    private var sectionHeader: some View {
        HStack {
            Label {
                HStack(spacing: 4) {
                    Text("今日待办")
                    Text("\(completedCount)/\(todayTasks.count)")
                        .font(.holoTinyLabel)
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Color.holoPrimary)
                        .clipShape(Capsule())
                }
            } icon: {
                Image(systemName: "checklist")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.holoTextPrimary)

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func taskRow(task: TodoTask) -> some View {
        HStack(spacing: 12) {
            taskCheckCircle(task: task)

            Button {
                selectedTask = TaskSelection(id: task.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(task.completed ? .holoTextSecondary : .holoTextPrimary)
                        .strikethrough(task.completed)

                    HStack(spacing: 6) {
                        if task.isDailyRitual {
                            Text("仪式")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.holoPurple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.holoPurple.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if let list = task.list {
                            Text(list.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.holoPrimaryDark)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.holoPrimaryLight)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if let goal = task.goal {
                            GoalBadge(goal: goal, compact: true)
                        }
                        if let dueDate = task.dueDate {
                            if task.isDueToday {
                                Text(formatTime(dueDate))
                                    .font(.holoTinyLabel)
                                    .foregroundColor(.holoTextSecondary)
                            } else {
                                // 逾期任务：红色提示
                                Text("已逾期 · \(formatDate(dueDate))")
                                    .font(.holoTinyLabel)
                                    .foregroundColor(.holoError)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Circle()
                    .fill(priorityColor(task.taskPriority))
                    .frame(width: 6, height: 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func taskCheckCircle(task: TodoTask) -> some View {
        Button {
            toggleTask(task)
        } label: {
            ZStack {
                Circle()
                    .fill(task.completed ? Color.holoPrimary : Color.clear)
                    .frame(width: 22, height: 22)

                Circle()
                    .stroke(task.completed ? Color.holoPrimary : Color.holoDivider, lineWidth: 2)
                    .frame(width: 22, height: 22)

                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .opacity(task.completed ? 1 : 0)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: task.completed)
        }
        .buttonStyle(.plain)
    }

    private var addRow: some View {
        Button { showAddSheet = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                Text("添加任务")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - 近期待办

    private var recentSection: some View {
        VStack(spacing: 0) {
            recentSectionHeader
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(recentTasks, id: \.id) { task in
                recentTaskRow(task: task)
                if task.id != recentTasks.last?.id {
                    Divider().background(Color.holoDivider)
                }
            }

            if !openTasks.isEmpty {
                if !recentTasks.isEmpty {
                    Divider().background(Color.holoDivider)
                }
                ForEach(openTasks, id: \.id) { task in
                    recentTaskRow(task: task)
                    if task.id != openTasks.last?.id {
                        Divider().background(Color.holoDivider)
                    }
                }
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
        .shadow(color: HoloShadow.card, radius: 4, y: 1)
    }

    private var recentSectionHeader: some View {
        HStack {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
            Text("近期待办")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoTextSecondary)
            Spacer()
        }
    }

    private func recentTaskRow(task: TodoTask) -> some View {
        HStack(spacing: 12) {
            Button {
                selectedTask = TaskSelection(id: task.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextPrimary)

                    HStack(spacing: 6) {
                        if let list = task.list {
                            Text(list.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.holoPrimaryDark)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.holoPrimaryLight)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if let goal = task.goal {
                            GoalBadge(goal: goal, compact: true)
                        }
                        if let dueDate = task.dueDate {
                            Text(formatDate(dueDate))
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoError)
                        } else {
                            Text("无截止日期")
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                addToToday(task)
            } label: {
                Text("加入今日")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.holoPrimaryLight)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func toggleTask(_ task: TodoTask) {
        if task.completed {
            // 已完成 → 直接取消完成
            do {
                try todoRepo.uncompleteTask(task)
                HapticManager.medium()
            } catch {
                Logger(subsystem: "com.holo.app", category: "UI").error("取消完成失败: \(error.localizedDescription)")
            }
        } else {
            // 未完成 → 走全局 3 秒撤回流程
            todoRepo.startPendingCompletion(for: task)
            HapticManager.taskCompletion()
        }
    }

    /// 撤回任务完成
    private func undoCompletion() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            todoRepo.undoPendingCompletion()
        }
        HapticManager.light()
    }

    private func addToToday(_ task: TodoTask) {
        do {
            try todoRepo.planTask(task, for: Date())
            HapticManager.light()
        } catch {
            Logger(subsystem: "com.holo.app", category: "UI").error("加入今日失败: \(error.localizedDescription)")
        }
    }

    private func priorityColor(_ priority: TaskPriority) -> Color {
        switch priority {
        case .urgent: return .holoError
        case .high: return .holoPrimary
        case .medium: return Color("holoAmber")
        case .low: return .holoSuccess
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d"
        return f.string(from: date)
    }
}
