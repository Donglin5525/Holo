//
//  TaskDetailView.swift
//  Holo
//
//  任务详情视图
//

import SwiftUI
import CoreData
import OSLog

struct TaskDetailView: View {
    @ObservedObject var repository: TodoRepository
    @State var task: TodoTask
    @Environment(\.dismiss) var dismiss

    @State private var showingEditSheet = false
    @State private var showingChecklist = false
    @State private var showingRepeatRule = false
    @State private var showingDeleteAlert = false

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskDetailView")

    var body: some View {
        NavigationStack {
            Form {
                taskInfoSection
                statusSection
                timeSection
                checklistSection
                repeatRuleSection
                tagSection
                actionSection
            }
            .navigationTitle("任务详情")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") {
                        showingEditSheet = true
                    }
                }
            }
            .sheet(isPresented: $showingEditSheet) {
                AddTaskSheet(repository: repository, list: task.list, task: task)
            }
            .sheet(isPresented: $showingChecklist) {
                ChecklistView(repository: repository, task: task)
            }
            .alert("删除任务", isPresented: $showingDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    deleteTask()
                }
            } message: {
                Text("确定要删除此任务吗？任务将进入回收站，30 天后可恢复。")
            }
        }
    }

    private var taskInfoSection: some View {
        Section("任务信息") {
            HStack {
                Text("标题")
                Spacer()
                Text(task.title)
                    .foregroundColor(.secondary)
            }

            if let desc = task.desc, !desc.isEmpty {
                HStack(alignment: .top) {
                    Text("描述")
                        .foregroundColor(.secondary)
                    Text(desc)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var statusSection: some View {
        Section("状态与优先级") {
            Picker("状态", selection: taskStatusBinding) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Text(status.displayTitle).tag(status)
                }
            }

            HStack {
                Text("优先级")
                Spacer()
                HStack {
                    Image(systemName: task.taskPriority.iconName)
                        .foregroundColor(task.taskPriority.color)
                    Text(task.taskPriority.displayTitle)
                }
            }
        }
    }

    private var timeSection: some View {
        Section("时间") {
            HStack {
                Text("截止时间")
                Spacer()
                if let dueDate = task.dueDate {
                    Text(dueDate, style: .date)
                    if !task.isAllDay {
                        Text(dueDate, style: .time)
                    }
                } else {
                    Text("未设置")
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("全天任务")
                Spacer()
                Text(task.isAllDay ? "是" : "否")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var checklistSection: some View {
        Section("检查清单") {
            HStack {
                Text("检查项")
                Spacer()
                Text(task.checkItemProgress)
                    .foregroundColor(.secondary)
            }

            Button("管理检查项") {
                showingChecklist = true
            }
        }
    }

    private var repeatRuleSection: some View {
        Section("重复设置") {
            HStack {
                Text("重复规则")
                Spacer()
                if let rule = task.repeatRule {
                    Text(rule.repeatType.displayTitle)
                        .foregroundColor(.secondary)
                } else {
                    Text("不重复")
                        .foregroundColor(.secondary)
                }
            }

            Button("设置重复规则") {
                showingRepeatRule = true
            }
        }
    }

    private var tagSection: some View {
        Section("标签") {
            if let tags = task.tags?.allObjects as? [TodoTag], !tags.isEmpty {
                HStack {
                    ForEach(tags, id: \.id) { tag in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(hex: tag.color))
                                .frame(width: 8, height: 8)
                            Text(tag.name)
                                .font(.caption)
                        }
                    }
                }
            } else {
                Text("未设置标签")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var actionSection: some View {
        Section("其他操作") {
            Button(role: .destructive) {
                showingDeleteAlert = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("删除任务")
                }
            }
        }
    }

    private var taskStatusBinding: Binding<TaskStatus> {
        Binding(
            get: { task.taskStatus },
            set: { newStatus in
                do {
                    try repository.updateTask(task, status: newStatus)
                } catch {
                    Self.logger.error("更新状态失败: \(error.localizedDescription)")
                }
            }
        )
    }

    private func deleteTask() {
        do {
            try repository.deleteTask(task)
            dismiss()
        } catch {
            Self.logger.error("删除任务失败: \(error.localizedDescription)")
        }
    }
}

#Preview {
    NavigationStack {
        TaskDetailView(
            repository: TodoRepository.shared,
            task: createSampleTask()
        )
    }
}

private func createSampleTask() -> TodoTask {
    let context = CoreDataStack.shared.viewContext
    let task = TodoTask(context: context)
    task.id = UUID()
    task.title = "示例任务"
    task.priority = 2
    task.status = "todo"
    task.createdAt = Date()
    task.updatedAt = Date()
    return task
}
