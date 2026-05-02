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

    private var plannedTasks: [TodoTask] {
        _ = refreshTrigger
        return todoRepo.getPlannedTodayTasks()
    }

    private var dueTodayTasks: [TodoTask] {
        _ = refreshTrigger
        return todoRepo.getDueTodayUnplannedTasks()
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
        plannedTasks.filter { $0.completed }.count
    }

    var body: some View {
        VStack(spacing: 8) {
            sectionHeader

            if plannedTasks.isEmpty && dueTodayTasks.isEmpty && recentTasks.isEmpty && openTasks.isEmpty {
                emptyView
            } else {
                VStack(spacing: 0) {
                    ForEach(plannedTasks, id: \.id) { task in
                        taskRow(task: task)
                        if task.id != plannedTasks.last?.id || !dueTodayTasks.isEmpty {
                            Divider().background(Color.holoDivider)
                        }
                    }

                    ForEach(dueTodayTasks, id: \.id) { task in
                        taskRow(task: task)
                        if task.id != dueTodayTasks.last?.id {
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

            if !dueTodayTasks.isEmpty {
                dueBanner
            }

            if !recentTasks.isEmpty || !openTasks.isEmpty {
                recentSection
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddTaskSheet(repository: todoRepo, list: nil)
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
                    Text("\(completedCount)/\(plannedTasks.count)")
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
                    if let dueDate = task.dueDate {
                        Text(formatTime(dueDate))
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }

            Spacer()

            Circle()
                .fill(priorityColor(task.taskPriority))
                .frame(width: 6, height: 6)
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

    private var dueBanner: some View {
        HStack(spacing: 10) {
            Text("⚠️")
            Text("还有 \(dueTodayTasks.count) 项今日到期，点击添加")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoError)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
        }
        .padding(12)
        .background(Color.holoErrorLight)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoError.opacity(0.15), lineWidth: 1))
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

            Spacer()

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
        do {
            if task.completed {
                try todoRepo.uncompleteTask(task)
            } else {
                try todoRepo.completeTask(task)
                HapticManager.taskCompletion()
            }
        } catch {
            Logger(subsystem: "com.holo.app", category: "UI").error("切换任务状态失败: \(error.localizedDescription)")
        }
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
