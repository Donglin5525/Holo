//
//  TaskDetailView.swift
//  Holo
//
//  任务详情视图
//  统一 Holo 设计风格：卡片布局、中文日期、Holo 颜色系统
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
    @State private var showingDeleteAlert = false

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskDetailView")

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: HoloSpacing.lg) {
                    // 任务信息卡片
                    taskInfoCard

                    // 状态与优先级卡片
                    statusCard

                    // 时间卡片
                    timeCard

                    // 检查清单卡片
                    checklistCard

                    // 标签卡片
                    tagCard

                    // 删除操作
                    deleteButton
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingEditSheet = true
                    } label: {
                        Text("编辑")
                            .font(.holoBody)
                            .foregroundColor(.holoPrimary)
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
            .swipeBackToDismiss { dismiss() }
        }
    }

    // MARK: - 任务信息卡片

    private var taskInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            Text(task.title)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            // 描述
            if let desc = task.desc, !desc.isEmpty {
                Text(desc)
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    // MARK: - 状态与优先级卡片

    private var statusCard: some View {
        VStack(spacing: 0) {
            // 状态选择
            HStack {
                Text("状态")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Menu {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Button {
                            updateStatus(status)
                        } label: {
                            HStack {
                                Text(status.displayTitle)
                                if task.taskStatus == status {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(task.taskStatus.color)
                            .frame(width: 8, height: 8)
                        Text(task.taskStatus.displayTitle)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .padding()

            Divider()
                .padding(.horizontal)

            // 优先级显示
            HStack {
                Text("优先级")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: task.taskPriority.iconName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(task.taskPriority.color)
                    Text(task.taskPriority.displayTitle)
                        .font(.holoBody)
                        .foregroundColor(task.taskPriority.color)
                }
            }
            .padding()
        }
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    // MARK: - 时间卡片

    private var timeCard: some View {
        VStack(spacing: 0) {
            // 截止时间
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("截止时间")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text(formattedDueDate)
                    .font(.holoBody)
                    .foregroundColor(task.dueDate != nil ? .holoTextPrimary : .holoTextSecondary)
            }
            .padding()

            if task.dueDate != nil {
                Divider()
                    .padding(.horizontal)

                // 全天任务
                HStack {
                    Image(systemName: "sun.max")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text("全天任务")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Text(task.isAllDay ? "是" : "否")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                }
                .padding()

                // 提醒显示
                if task.hasReminders {
                    Divider()
                        .padding(.horizontal)

                    HStack {
                        Image(systemName: "bell")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)

                        Text("提醒")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Spacer()

                        Text(formattedReminders)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding()
                }
            }
        }
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    // MARK: - 检查清单卡片

    private var checklistCard: some View {
        Button {
            showingChecklist = true
        } label: {
            HStack {
                Image(systemName: "checklist")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("检查清单")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text(task.checkItemProgress)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding()
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.lg)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 标签卡片

    private var tagCard: some View {
        HStack {
            Image(systemName: "tag")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoTextSecondary)

            Text("标签")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            if let tags = task.tags?.allObjects as? [TodoTag], !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.id) { tag in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(hex: tag.color))
                                .frame(width: 8, height: 8)
                            Text(tag.name)
                                .font(.holoCaption)
                                .foregroundColor(.holoTextPrimary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(hex: tag.color).opacity(0.1))
                        .clipShape(Capsule())
                    }
                }
            } else {
                Text("未设置")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding()
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    // MARK: - 删除按钮

    private var deleteButton: some View {
        Button {
            showingDeleteAlert = true
        } label: {
            HStack {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoError)

                Text("删除任务")
                    .font(.holoBody)
                    .foregroundColor(.holoError)

                Spacer()
            }
            .padding()
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.lg)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 格式化方法

    /// 格式化截止日期（中文格式）
    private var formattedDueDate: String {
        guard let dueDate = task.dueDate else {
            return "未设置"
        }

        let calendar = Calendar.current

        if task.isAllDay {
            if calendar.isDateInToday(dueDate) { return "今天" }
            if calendar.isDateInTomorrow(dueDate) { return "明天" }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 E"
            return formatter.string(from: dueDate)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")

            if calendar.isDateInToday(dueDate) {
                formatter.dateFormat = "HH:mm"
                return "今天 " + formatter.string(from: dueDate)
            }

            formatter.dateFormat = "M月d日 HH:mm"
            return formatter.string(from: dueDate)
        }
    }

    /// 格式化提醒列表
    private var formattedReminders: String {
        let reminders = task.remindersArray
        if reminders.isEmpty { return "" }
        return reminders.map { $0.displayTitle }.joined(separator: "、")
    }

    // MARK: - 操作方法

    private func updateStatus(_ status: TaskStatus) {
        do {
            try repository.updateTask(task, status: status)
        } catch {
            Self.logger.error("更新状态失败: \(error.localizedDescription)")
        }
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

// MARK: - TaskStatus 扩展（颜色）

extension TaskStatus {
    /// 状态对应的颜色
    var color: Color {
        switch self {
        case .todo: return .holoTextSecondary
        case .inProgress: return .holoPrimary
        case .completed: return .holoSuccess
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
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
    task.desc = "这是一个示例任务的描述内容"
    task.priority = 2
    task.status = "inProgress"
    task.createdAt = Date()
    task.updatedAt = Date()
    task.dueDate = Calendar.current.date(byAdding: .day, value: 2, to: Date())
    return task
}
