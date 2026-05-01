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
enum TaskFilterType: Equatable {
    case all
    case inbox
    case today
    case completed
    case overdue
    case list(UUID)  // 清单筛选

    var title: String {
        switch self {
        case .all: return "全部"
        case .inbox: return "收件箱"
        case .today: return "今日"
        case .completed: return "已完成"
        case .overdue: return "已过期"
        case .list: return "清单"
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full.fill"
        case .inbox: return "tray"
        case .today: return "sun.max.fill"
        case .completed: return "checkmark.circle.fill"
        case .overdue: return "exclamationmark.triangle.fill"
        case .list: return "folder"
        }
    }

    /// 是否是预设筛选（非清单）
    var isPreset: Bool {
        switch self {
        case .all, .inbox, .today, .completed, .overdue: return true
        case .list: return false
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
    @State private var selectedFilter: TaskFilterType = .all
    /// 缓存的过滤结果
    @State private var cachedFilteredTasks: [TodoTask] = []

    /// 所有清单（包括没有文件夹的）
    private var allLists: [TodoList] {
        var lists = repository.unfiledLists
        lists.append(contentsOf: repository.folders.flatMap { $0.listsArray })
        return lists
    }

    /// 选中的任务（用于 sheet 展示）
    private struct TaskSelection: Identifiable, Equatable {
        let id: UUID
    }
    @State private var selectedTask: TaskSelection? = nil

    /// 是否显示归档管理页面
    @State private var showArchiveManagement = false
    /// 是否显示通知设置页面
    @State private var showNotificationSettings = false
    /// 是否显示搜索页面
    @State private var showSearchView = false
    /// 是否显示标签列表页面
    @State private var showTagListView = false

    /// 右滑展开的卡片 ID
    @State private var revealedTaskId: UUID? = nil

    /// 正在完成中的任务 ID（等待撤回窗口）
    @State private var pendingCompletionTaskId: UUID? = nil
    @State private var pendingCompletionWorkItem: DispatchWorkItem? = nil

    /// Deep Link 状态（通知点击跳转）
    @ObservedObject private var deepLinkState = DeepLinkState.shared

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView

            // 筛选器
            filterPickerView

            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if selectedFilter == .completed {
                            // 已完成 tab：按周分组展示
                            completedTabContent
                        } else {
                            // 其他 tab：待办任务 + 最近已完成
                            otherTabContent
                        }

                        if cachedFilteredTasks.isEmpty {
                            emptyStateView
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                    .padding(.bottom, pendingCompletionTaskId != nil ? 80 : 100)
                }

                // 撤回 banner
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
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            loadTasks()
        }
        // 监听 Deep Link：冷启动时 onAppear 读取已有值
        .onAppear { handleDeepLink() }
        // 监听 Deep Link：热启动/后台时 onChange 检测变化
        .onChange(of: deepLinkState.pendingTarget) { _, _ in
            handleDeepLink()
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
            if let task = tasks.first(where: { $0.id == selection.id }) ?? repository.findTask(by: selection.id) {
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
        .fullScreenCover(isPresented: $showSearchView) {
            TaskSearchView(repository: repository)
        }
        .sheet(isPresented: $showTagListView) {
            TagListView(repository: repository)
        }
    }

    // MARK: - 已完成 Tab 内容

    /// 已完成 tab：按周分组展示所有已完成任务
    @ViewBuilder
    private var completedTabContent: some View {
        let weekGroups = completedTasksGroupedByWeek
        ForEach(weekGroups, id: \.title) { group in
            SectionHeaderView(title: group.title, count: group.tasks.count)
            ForEach(group.tasks, id: \.id) { task in
                taskRow(task)
            }
        }
    }

    // MARK: - 其他 Tab 内容

    /// 非「已完成」tab：待办任务 + 最近已完成
    @ViewBuilder
    private var otherTabContent: some View {
        // 待办任务（撤回窗口期间排除 pending 任务，它在底部 banner 中显示）
        let activeTasks = cachedFilteredTasks.filter { !$0.completed && $0.id != pendingCompletionTaskId }
        ForEach(activeTasks, id: \.id) { task in
            taskRow(task)
        }

        // 正在完成中的任务（显示在撤回 banner 上方）
        if let pendingId = pendingCompletionTaskId,
           let pendingTask = cachedFilteredTasks.first(where: { $0.id == pendingId }) {
            taskRow(pendingTask)
        }

        // 最近已完成（仅展示最近一周完成的任务）
        let recentlyCompleted = cachedFilteredTasks.filter { $0.completed && isCompletedRecently($0) }
        if !recentlyCompleted.isEmpty {
            SectionHeaderView(title: "最近已完成", count: recentlyCompleted.count)
            ForEach(recentlyCompleted, id: \.id) { task in
                taskRow(task)
            }
        }
    }

    // MARK: - 任务行组件

    /// 可复用的任务卡片行（含滑动操作）
    private func taskRow(_ task: TodoTask) -> some View {
        SwipeActionView(
            isRevealed: Binding(
                get: { revealedTaskId == task.id },
                set: { if $0 { revealedTaskId = task.id } else { revealedTaskId = nil } }
            ),
            content: {
                TaskCardView(
                    task: task,
                    repository: repository,
                    onNavigate: {
                        if revealedTaskId == task.id {
                            revealedTaskId = nil
                        } else {
                            selectedTask = TaskSelection(id: task.id)
                        }
                    },
                    isCompleting: pendingCompletionTaskId == task.id,
                    onToggleCompletion: {
                        if task.completed {
                            // 已完成 → 直接取消完成
                            do {
                                try repository.toggleTaskCompletion(task)
                                HapticManager.medium()
                            } catch {
                                Logger(subsystem: "com.holo.app", category: "TaskListView").error("取消完成失败: \(error.localizedDescription)")
                            }
                        } else {
                            // 未完成 → 走撤回流程
                            handleTaskCompletion(task)
                        }
                    }
                )
            },
            onArchive: {
                archiveTask(task)
            },
            onDelete: {
                deleteTask(task)
            }
        )
    }

    // MARK: - 数据加载

    /// 处理 Deep Link 跳转
    /// 冷启动由 .onAppear 触发，热启动/后台由 .onChange 触发
    private func handleDeepLink() {
        guard case .taskDetail(let taskId) = deepLinkState.pendingTarget else { return }
        // 延迟确保 fullScreenCover 视图层级完全就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            selectedTask = TaskSelection(id: taskId)
            deepLinkState.pendingTarget = nil
        }
    }

    private func loadTasks() {
        tasks = repository.activeTasks
        todayProgress = repository.getTodayTaskProgress()
        updateFilteredTasks()
    }

    // MARK: - 完成任务（带撤回）

    /// 处理任务完成：延迟 3 秒执行，期间可撤回
    private func handleTaskCompletion(_ task: TodoTask) {
        // 如果有上一个待完成的任务，立即确认它
        if let previousId = pendingCompletionTaskId {
            pendingCompletionWorkItem?.cancel()
            pendingCompletionWorkItem = nil

            // 直接完成上一个任务
            if let previousTask = tasks.first(where: { $0.id == previousId }) {
                do {
                    if previousTask.repeatRule != nil {
                        _ = try repository.completeRepeatingTask(previousTask)
                    } else {
                        try repository.toggleTaskCompletion(previousTask)
                    }
                } catch {
                    Logger(subsystem: "com.holo.app", category: "TaskListView").error("完成任务失败: \(error.localizedDescription)")
                }
            }

            // 清理状态并刷新
            pendingCompletionTaskId = nil
            tasks = repository.activeTasks
            todayProgress = repository.getTodayTaskProgress()
            updateFilteredTasks()
        }

        // 乐观更新 UI
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            pendingCompletionTaskId = task.id
        }
        HapticManager.taskCompletion()

        // 3 秒后执行实际完成操作
        let workItem = DispatchWorkItem {
            do {
                if task.repeatRule != nil {
                    _ = try repository.completeRepeatingTask(task)
                } else {
                    try repository.toggleTaskCompletion(task)
                }
            } catch {
                Logger(subsystem: "com.holo.app", category: "TaskListView").error("完成任务失败: \(error.localizedDescription)")
            }

            // 直接在主线程清理（asyncAfter 已在主队列）
            pendingCompletionTaskId = nil
            pendingCompletionWorkItem = nil
            tasks = repository.activeTasks
            todayProgress = repository.getTodayTaskProgress()
            updateFilteredTasks()
        }
        pendingCompletionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    /// 撤回任务完成
    private func undoCompletion() {
        pendingCompletionWorkItem?.cancel()
        pendingCompletionWorkItem = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            pendingCompletionTaskId = nil
        }
        HapticManager.light()
    }

    // MARK: - 滑动操作

    /// 归档任务
    private func archiveTask(_ task: TodoTask) {
        do {
            try repository.archiveTask(task)
            revealedTaskId = nil
        } catch {
            Logger(subsystem: "com.holo.app", category: "TaskListView").error("归档任务失败: \(error.localizedDescription)")
        }
    }

    /// 删除任务
    private func deleteTask(_ task: TodoTask) {
        do {
            try repository.deleteTask(task)
            revealedTaskId = nil
        } catch {
            Logger(subsystem: "com.holo.app", category: "TaskListView").error("删除任务失败: \(error.localizedDescription)")
        }
    }

    /// 更新过滤结果（缓存）
    private func updateFilteredTasks() {
        let pendingId = pendingCompletionTaskId
        switch selectedFilter {
        case .all:
            cachedFilteredTasks = tasks
        case .inbox:
            cachedFilteredTasks = tasks.filter { $0.list == nil }
        case .today:
            cachedFilteredTasks = tasks.filter { $0.isDueToday }
        case .completed:
            cachedFilteredTasks = tasks.filter { $0.completed }
        case .overdue:
            // 撤回窗口期间，把 pending 任务从过期列表中排除（它在视觉上已完成）
            cachedFilteredTasks = tasks.filter { $0.isOverdue && !$0.completed && $0.id != pendingId }
        case .list(let listId):
            cachedFilteredTasks = tasks.filter { $0.list?.id == listId }
        }
    }

    // MARK: - 顶部导航栏

    private var headerView: some View {
        ZStack {
            // 居中标题
            Text("任务")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

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

                // 右侧按钮组
                HStack(spacing: 0) {
                    // 搜索按钮
                    Button {
                        showSearchView = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 32, height: 44)
                    }

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
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 筛选器

    private var filterPickerView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 预设筛选器
                ForEach([TaskFilterType.all, .inbox, .today, .completed, .overdue], id: \.title) { filter in
                    HoloFilterChip(
                        title: filter.title,
                        icon: filter.icon,
                        isSelected: selectedFilter == filter
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedFilter = filter
                        }
                    }
                }

                // 清单筛选器
                ForEach(allLists, id: \.id) { list in
                    HoloFilterChip(
                        title: list.name,
                        icon: "folder.fill",
                        iconColor: Color(hex: list.color ?? "#007AFF"),
                        isSelected: selectedFilter == .list(list.id)
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedFilter = .list(list.id)
                        }
                    }
                }

                // 标签入口
                Button {
                    showTagListView = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tag")
                            .font(.system(size: 12, weight: .medium))
                        Text("标签")
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

    // MARK: - 已完成任务按周分组

    /// 已完成任务按周分组（用于「已完成」tab）
    private var completedTasksGroupedByWeek: [(title: String, tasks: [TodoTask])] {
        let completedTasks = cachedFilteredTasks
            .filter { $0.completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }

        let calendar = Calendar.current
        var groups: [Date: [TodoTask]] = [:]

        for task in completedTasks {
            guard let completedAt = task.completedAt else {
                groups[.distantPast, default: []].append(task)
                continue
            }
            let weekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: completedAt)
            )!
            groups[weekStart, default: []].append(task)
        }

        let sortedWeeks = groups.keys.sorted(by: >)
        return sortedWeeks.map { weekStart in
            (title: weekTitle(for: weekStart), tasks: groups[weekStart]!)
        }
    }

    /// 生成周标题
    private func weekTitle(for weekStart: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let currentWeekStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        )!

        if weekStart == currentWeekStart {
            return "本周"
        }

        if let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeekStart),
           weekStart == lastWeekStart {
            return "上周"
        }

        let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: weekStart)) - \(formatter.string(from: weekEnd))"
    }

    /// 判断任务是否在最近一周内完成
    private func isCompletedRecently(_ task: TodoTask) -> Bool {
        guard let completedAt = task.completedAt else { return false }
        return completedAt >= Calendar.current.date(byAdding: .day, value: -7, to: Date())!
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
    var onNavigate: (() -> Void)?
    var isCompleting: Bool = false
    var onToggleCompletion: (() -> Void)?

    /// 是否展开检查清单
    @State private var isChecklistExpanded = false

    /// 检查清单项（排序后）
    private var checkItems: [CheckItem] {
        let items = task.checkItems?.allObjects as? [CheckItem] ?? []
        return items.sorted { $0.order < $1.order }
    }

    /// 是否有检查清单
    private var hasChecklist: Bool {
        !checkItems.isEmpty
    }

    /// 显示的检查项（最多5项，展开后显示全部）
    private var displayedCheckItems: [CheckItem] {
        if isChecklistExpanded {
            return checkItems
        } else {
            return Array(checkItems.prefix(5))
        }
    }

    /// 是否需要显示"更多"指示
    private var shouldShowMoreIndicator: Bool {
        checkItems.count > 5 && !isChecklistExpanded
    }

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskCardView")

    /// 显示完成态（task 已完成 或 正在完成中）
    private var showsCompleted: Bool {
        task.completed || isCompleting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主内容行
            HStack(spacing: 12) {
                // 完成状态切换按钮
                Button(action: toggleCompletion) {
                    Image(systemName: showsCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(showsCompleted ? .holoPrimary : .holoTextSecondary)
                }
                .buttonStyle(.plain)
                .disabled(isCompleting)

                // 任务内容（点击导航到详情页）
                Button(action: { onNavigate?() }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.holoBody)
                            .strikethrough(showsCompleted)
                            .foregroundColor(showsCompleted ? .holoTextSecondary : .holoTextPrimary)
                            .lineLimit(2)

                        // 描述（截断展示）
                        if let desc = task.desc, !desc.isEmpty {
                            Text(desc)
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(2)
                        }

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

                            // 重复任务标识
                            if task.repeatRule != nil {
                                Image(systemName: "repeat")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.holoPrimary)
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

                            // 检查清单进度
                            if hasChecklist {
                                Label(
                                    task.checkItemProgress,
                                    systemImage: "checklist"
                                )
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoTextSecondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                // 优先级指示点
                Circle()
                    .fill(task.taskPriority.color)
                    .frame(width: 6, height: 6)
            }
            .padding(HoloSpacing.md)

            // 检查清单平铺展示
            if hasChecklist {
                Divider()
                    .padding(.horizontal, HoloSpacing.md)

                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    ForEach(displayedCheckItems, id: \.id) { item in
                        HStack(spacing: 8) {
                            Button {
                                toggleCheckItem(item)
                            } label: {
                                Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(item.isChecked ? .holoSuccess : .holoTextSecondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)

                            Text(item.title)
                                .font(.holoCaption)
                                .foregroundColor(item.isChecked ? .holoTextSecondary : .holoTextPrimary)
                                .strikethrough(item.isChecked, color: .holoTextSecondary)

                            Spacer()
                        }
                    }

                    // 更多项指示 / 展开按钮
                    if checkItems.count > 5 {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isChecklistExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isChecklistExpanded ? "chevron.up" : "ellipsis")
                                    .font(.system(size: 12, weight: .medium))
                                Text(isChecklistExpanded ? "收起" : "还有 \(checkItems.count - 5) 项")
                                    .font(.holoTinyLabel)
                            }
                            .foregroundColor(.holoPrimary)
                            .padding(.top, HoloSpacing.xs)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.sm)
            }
        }
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
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M月d日"
            return f.string(from: date)
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
        guard !isCompleting else { return }

        // 优先使用回调（TaskListView 会在回调中区分完成/取消完成）
        if let onToggleCompletion = onToggleCompletion {
            onToggleCompletion()
            return
        }

        // 兼容搜索页等不使用撤回的场景
        let wasCompleted = task.completed
        do {
            if task.repeatRule != nil && !task.completed {
                _ = try repository.completeRepeatingTask(task)
            } else {
                try repository.toggleTaskCompletion(task)
            }
            if wasCompleted {
                HapticManager.medium()
            } else {
                HapticManager.taskCompletion()
            }
        } catch {
            Self.logger.error("切换任务状态失败: \(error.localizedDescription)")
        }
    }

    private func toggleCheckItem(_ item: CheckItem) {
        do {
            try repository.toggleCheckItem(item)
        } catch {
            Self.logger.error("切换检查项状态失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - Preview

#Preview {
    TaskListView(repository: TodoRepository.shared, onBack: {})
}
