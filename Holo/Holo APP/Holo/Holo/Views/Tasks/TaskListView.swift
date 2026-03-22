//
//  TaskListView.swift
//  Holo
//
//  待办任务列表页面
//  展示所有任务，支持按状态/清单筛选
//

import SwiftUI
import CoreData
import OSLog

// MARK: - 筛选类型

/// 任务筛选类型
enum TaskFilter: String, CaseIterable {
    case all = "全部"
    case inbox = "收件箱"
    case today = "今日"
    case overdue = "已过期"

    var icon: String {
        switch self {
        case .all: return "tray.full.fill"
        case .inbox: return "tray"
        case .today: return "sun.max.fill"
        case .overdue: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - TaskListView

/// 待办任务列表页面
struct TaskListView: View {

    // MARK: - Properties

    @ObservedObject var repository: TodoRepository
    let onBack: () -> Void

    /// 任务列表（本地缓存）
    @State private var tasks: [TodoTask] = []
    /// 今日进度
    @State private var todayProgress: (completed: Int, total: Int) = (0, 0)
    /// 当前筛选
    @State private var selectedFilter: TaskFilter = .all
    /// 缓存的过滤结果
    @State private var cachedFilteredTasks: [TodoTask] = []

    /// 选中的任务（用于 sheet 展示）
    private struct TaskSelection: Identifiable, Equatable {
        let id: UUID
    }
    @State private var selectedTask: TaskSelection? = nil

    /// 是否显示归档管理页面
    @State private var showArchiveManagement = false
    /// 是否显示通知设置页面
    @State private var showNotificationSettings = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView

            // 筛选器
            filterPickerView

            ScrollView {
                LazyVStack(spacing: 12) {
                    // 待办任务
                    let activeTasks = cachedFilteredTasks.filter { !$0.completed }
                    ForEach(activeTasks, id: \.id) { task in
                        TaskCardView(task: task, repository: repository)
                            .onTapGesture {
                                selectedTask = TaskSelection(id: task.id)
                            }
                    }

                    // 已完成任务
                    let completedTasks = cachedFilteredTasks.filter { $0.completed }
                    if !completedTasks.isEmpty {
                        SectionHeaderView(title: "已完成", count: completedTasks.count)
                        ForEach(completedTasks, id: \.id) { task in
                            TaskCardView(task: task, repository: repository)
                                .onTapGesture {
                                    selectedTask = TaskSelection(id: task.id)
                                }
                        }
                    }

                    if cachedFilteredTasks.isEmpty {
                        emptyStateView
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
        }
        .onAppear {
            loadTasks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoDataDidChange)) { _ in
            loadTasks()
        }
        .onChange(of: selectedFilter) { _, _ in
            updateFilteredTasks()
        }
        .onChange(of: tasks) { _, _ in
            updateFilteredTasks()
        }
        .sheet(item: $selectedTask) { selection in
            if let task = tasks.first(where: { $0.id == selection.id }) {
                TaskDetailView(repository: repository, task: task)
            } else {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showArchiveManagement) {
            ArchiveManagementView(repository: repository)
        }
        .sheet(isPresented: $showNotificationSettings) {
            NotificationSettingsView()
        }
    }

    // MARK: - 数据加载

    private func loadTasks() {
        tasks = repository.activeTasks
        todayProgress = repository.getTodayTaskProgress()
        updateFilteredTasks()
    }

    /// 更新过滤结果（缓存）
    private func updateFilteredTasks() {
        switch selectedFilter {
        case .all:
            cachedFilteredTasks = tasks
        case .inbox:
            cachedFilteredTasks = tasks.filter { $0.list == nil }
        case .today:
            cachedFilteredTasks = tasks.filter { $0.isDueToday }
        case .overdue:
            cachedFilteredTasks = tasks.filter { $0.isOverdue && !$0.completed }
        }
    }

    // MARK: - 顶部导航栏

    private var headerView: some View {
        HStack {
            // 返回按钮
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            // 标题
            Text("任务")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 右侧按钮组
            HStack(spacing: 0) {
                // 通知设置按钮
                Button {
                    showNotificationSettings = true
                } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 32, height: 44)
                }

                // 今日进度
                Text("\(todayProgress.completed)/\(todayProgress.total)")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 筛选器

    private var filterPickerView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TaskFilter.allCases, id: \.self) { filter in
                    HoloFilterChip(
                        title: filter.rawValue,
                        icon: filter.icon,
                        isSelected: selectedFilter == filter
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedFilter = filter
                        }
                    }
                }

                // 归档入口
                Button {
                    showArchiveManagement = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 12, weight: .medium))
                        Text("归档")
                            .font(.holoCaption)
                    }
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.holoCardBackground)
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        style: StrokeStyle(lineWidth: 1, dash: [4])
                                    )
                                    .foregroundColor(.holoDivider)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)
        }
        .background(Color.holoBackground)
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checklist")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无任务")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text("点击右下角 + 创建第一个任务")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
        }
        .padding(.top, 80)
    }
}

// MARK: - Section Header View

/// 分组标题视图
private struct SectionHeaderView: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            Text("\(count)")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(.top, HoloSpacing.md)
    }
}

// MARK: - Task Card View

/// 任务卡片组件
struct TaskCardView: View {
    let task: TodoTask
    @ObservedObject var repository: TodoRepository

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskCardView")

    var body: some View {
        HStack(spacing: 12) {
            // 完成状态切换按钮
            Button(action: toggleCompletion) {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(task.completed ? .holoPrimary : .holoTextSecondary)
            }
            .buttonStyle(.plain)

            // 任务内容
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.holoBody)
                    .strikethrough(task.completed)
                    .foregroundColor(task.completed ? .holoTextSecondary : .holoTextPrimary)
                    .lineLimit(2)

                // 任务元信息
                HStack(spacing: 8) {
                    // 截止日期
                    if let dueDate = task.dueDate {
                        Label(
                            formatDueDate(dueDate),
                            systemImage: "clock"
                        )
                        .font(.holoTinyLabel)
                        .foregroundColor(dateColor)
                    }

                    // 优先级
                    if task.taskPriority == .urgent || task.taskPriority == .high {
                        Label(
                            task.taskPriority.displayTitle,
                            systemImage: task.taskPriority.iconName
                        )
                        .font(.holoTinyLabel)
                        .foregroundColor(task.taskPriority.color)
                    }

                    // 清单名称
                    if let list = task.list {
                        Label(
                            list.name,
                            systemImage: "folder"
                        )
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                    }
                }
            }

            Spacer()

            // 优先级指示点
            Circle()
                .fill(task.taskPriority.color)
                .frame(width: 6, height: 6)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Helpers

    private func formatDueDate(_ date: Date) -> String {
        if task.isDueToday {
            return "今天"
        } else if task.isDueTomorrow {
            return "明天"
        } else if task.isOverdue {
            return "已过期"
        } else {
            return date.formatted(.dateTime.month().day())
        }
    }

    private var dateColor: Color {
        if task.isOverdue {
            return .red
        } else if task.isDueToday {
            return .orange
        } else if task.isDueTomorrow {
            return .yellow
        }
        return .holoTextSecondary
    }

    private func toggleCompletion() {
        do {
            try repository.toggleTaskCompletion(task)
        } catch {
            Self.logger.error("切换任务状态失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - Preview

#Preview {
    TaskListView(repository: TodoRepository.shared, onBack: {})
}
