//
//  TodoRepository.swift
//  Holo
//
//  待办模块数据仓库
//  所有 Core Data 操作均在主线程 viewContext 执行，避免跨线程访问
//

import Foundation
import CoreData
import Combine
import os.log

// MARK: - 通知名称

extension Notification.Name {
    /// 待办数据变更通知（新增/编辑/删除任务、清单、文件夹时发送）
    static let todoDataDidChange = Notification.Name("todoDataDidChange")
}

// MARK: - TodoRepository

/// 待办模块数据仓库
/// 使用 @MainActor 保证所有操作在主线程执行
@MainActor
class TodoRepository: ObservableObject {

    private let logger = Logger(subsystem: "com.holo.app", category: "TodoRepository")

    // MARK: - Singleton

    static let shared = TodoRepository()

    // MARK: - Published Properties

    /// 当前活跃的文件夹列表
    @Published var folders: [TodoFolder] = []

    /// 当前活跃的任务列表（未归档、未删除）
    @Published var activeTasks: [TodoTask] = []

    /// 回收站中的任务（已删除）
    @Published var trashedTasks: [TodoTask] = []

    /// 全局任务完成撤回状态：正在完成中（3 秒撤回窗口）的任务 ID
    /// 跨界面共享——无论在列表还是看板完成，撤回 banner 都一致显示
    @Published var pendingCompletionTaskId: UUID? = nil
    private var pendingCompletionWorkItem: DispatchWorkItem? = nil

    /// 是否已完成初始化（供 UI 判断加载状态）
    @Published private(set) var isReady: Bool = false

    /// 没有关联文件夹的清单
    var unfiledLists: [TodoList] {
        let request = TodoList.fetchRequest()
        request.predicate = NSPredicate(format: "folder == nil AND archived == NO AND deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    // MARK: - Properties

    /// 测试可注入独立上下文；生产单例始终使用 CoreDataStack 的主上下文。
    private let contextOverride: NSManagedObjectContext?

    /// 主上下文（主线程）
    var context: NSManagedObjectContext {
        contextOverride ?? CoreDataStack.shared.viewContext
    }

    // MARK: - Initialization

    /// init 不做任何 I/O 操作，避免阻塞主线程
    /// 所有数据操作延迟到 setup() 中执行
    private init() {
        contextOverride = nil
    }

    /// 模块内测试入口，避免测试读写真实数据库。
    init(context: NSManagedObjectContext) {
        contextOverride = context
    }

    /// 延迟初始化：加载所有数据
    /// 在 Core Data store 就绪后调用（HomeView.task 中）
    func setup() {
        guard !isReady else { return }
        loadFolders()
        loadActiveTasks()
        loadTrashedTasks()
        isReady = true
    }

    // MARK: - 数据加载

    /// 加载文件夹列表
    func loadFolders() {
        let request = TodoFolder.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]

        do {
            folders = try context.fetch(request)
        } catch {
            logger.error("加载文件夹失败：\(error)")
            folders = []
        }
    }

    /// 加载活跃任务列表
    func loadActiveTasks() {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "deletedAt == nil AND archived == NO"
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "completed", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: false)
        ]

        do {
            activeTasks = try context.fetch(request)
        } catch {
            logger.error("加载任务失败：\(error)")
            activeTasks = []
        }
    }

    /// 加载回收站中的任务
    func loadTrashedTasks() {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "deletedFlag == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "deletedAt", ascending: false)]

        do {
            trashedTasks = try context.fetch(request)
        } catch {
            logger.error("加载回收站失败：\(error)")
            trashedTasks = []
        }
    }

    // MARK: - Folder CRUD

    /// 创建文件夹
    @discardableResult
    func createFolder(name: String) throws -> TodoFolder {
        let folder = TodoFolder.create(in: context, name: name)
        try context.save()
        loadFolders()
        notifyDataChange()
        return folder
    }

    /// 更新文件夹
    func updateFolder(_ folder: TodoFolder, name: String? = nil, isExpanded: Bool? = nil) throws {
        if let name = name { folder.name = name }
        if let isExpanded = isExpanded { folder.isExpanded = isExpanded }
        folder.updatedAt = Date()

        try context.save()
        loadFolders()
        notifyDataChange()
    }

    /// 删除文件夹（级联删除所有清单和任务）
    func deleteFolder(_ folder: TodoFolder) throws {
        let taskIds = collectTaskIdsInFolder(folder)
        context.delete(folder)
        try context.save()
        AttachmentFileManager.deleteAttachmentDirectories(for: taskIds)
        loadFolders()
        notifyDataChange()
    }

    /// 更新文件夹排序
    func updateFolderOrder(_ folders: [TodoFolder]) throws {
        for (index, folder) in folders.enumerated() {
            folder.sortOrder = Int16(index)
        }
        try context.save()
        loadFolders()
        notifyDataChange()
    }

    // MARK: - List CRUD

    /// 创建清单
    @discardableResult
    func createList(
        name: String,
        folder: TodoFolder? = nil,
        color: String? = nil
    ) throws -> TodoList {
        let list = TodoList.create(in: context, name: name, folder: folder, color: color)
        try context.save()
        loadFolders()
        notifyDataChange()
        return list
    }

    /// 更新清单
    func updateList(
        _ list: TodoList,
        name: String? = nil,
        color: String? = nil,
        folder: TodoFolder? = nil,
        shouldUpdateFolder: Bool = false
    ) throws {
        if let name = name { list.name = name }
        if let color = color { list.color = color }
        if shouldUpdateFolder { list.folder = folder }
        list.updatedAt = Date()

        try context.save()
        loadFolders()
        notifyDataChange()
    }

    /// 归档清单
    func archiveList(_ list: TodoList) throws {
        list.archived = true
        list.updatedAt = Date()

        try context.save()
        loadFolders()
        notifyDataChange()
    }

    /// 恢复归档的清单
    func unarchiveList(_ list: TodoList) throws {
        list.archived = false
        list.updatedAt = Date()

        try context.save()
        loadFolders()
        notifyDataChange()
    }

    /// 删除清单（级联删除所有任务）
    func deleteList(_ list: TodoList) throws {
        let taskIds = collectTaskIdsInList(list)
        context.delete(list)
        try context.save()
        AttachmentFileManager.deleteAttachmentDirectories(for: taskIds)
        loadFolders()
        notifyDataChange()
    }

    // MARK: - Task CRUD

    /// 创建任务
    @discardableResult
    func createTask(
        title: String,
        description: String? = nil,
        list: TodoList? = nil,
        priority: TaskPriority = .medium,
        dueDate: Date? = nil,
        isAllDay: Bool = false,
        reminders: Set<TaskReminder>? = nil,
        checkItemTitles: [String]? = nil,
        sourceThought: Thought? = nil,
        sourceTextSnippet: String? = nil,
        plannedStart: Date? = nil,
        plannedEnd: Date? = nil
    ) throws -> TodoTask {
        if plannedStart != nil || plannedEnd != nil {
            guard let start = plannedStart, let end = plannedEnd,
                  TodoTask.isValidPlannedRange(start, end) else {
                preconditionFailure("计划时间段必须成对、同一天且开始早于结束")
            }
        }
        let task = TodoTask.create(
            in: context,
            title: title,
            desc: description,
            list: list,
            priority: priority,
            dueDate: dueDate,
            isAllDay: isAllDay,
            reminders: reminders,
            plannedStart: plannedStart,
            plannedEnd: plannedEnd
        )

        // 关联来源想法（想法转任务）
        if let sourceThought = sourceThought {
            task.sourceThought = sourceThought
        }
        // 记录来源文字快照（选中文字转化时，供正文 ✅ 标记反向定位）
        task.sourceTextSnippet = sourceTextSnippet

        // 调度提醒通知（绝对提醒不需要截止日期，scheduleReminder 内部按模式分别处理）
        if let reminders = reminders, !reminders.isEmpty {
            Task {
                try? await TodoNotificationService.shared.scheduleReminder(for: task, reminders: Array(reminders))
            }
        }

        // 创建子任务（原子操作，与主任务同一次 save）
        if let checkItemTitles = checkItemTitles {
            for (index, title) in checkItemTitles.enumerated() {
                _ = CheckItem.create(in: context, title: title, task: task, order: Int16(index))
            }
        }

        try context.save()
        loadActiveTasks()
        notifyDataChange()
        return task
    }

    /// 更新任务时截止日期的保存意图。
    /// 单用 Optional 日期无法区分「没改」和「清空」（nil 二义性），必须显式声明。
    enum TaskDueDateUpdate {
        /// 设置新的截止时间
        case set(Date)
        /// 清空截止时间
        case clear
    }

    /// 更新任务时计划时间段的保存意图（与 TaskDueDateUpdate 同构，nil 二义性同理）
    enum TaskPlannedTimeUpdate {
        /// 设置计划时间段（起止同一天且开始早于结束）
        case set(start: Date, end: Date)
        /// 清空计划时间段
        case clear
    }

    /// 更新任务
    func updateTask(
        _ task: TodoTask,
        title: String? = nil,
        description: String? = nil,
        status: TaskStatus? = nil,
        priority: TaskPriority? = nil,
        dueDate: TaskDueDateUpdate? = nil,
        isAllDay: Bool? = nil,
        list: TodoList? = nil,
        reminders: Set<TaskReminder>? = nil,
        plannedTime: TaskPlannedTimeUpdate? = nil
    ) throws {
        if let title = title { task.title = title }
        if let description = description { task.desc = description }
        if let status = status { task.taskStatus = status }
        if let priority = priority { task.taskPriority = priority }
        // 截止时间被改动时，需要把已调度的本地通知挪到新时间，
        // 否则旧通知仍按原时间响、新通知不会建（通知是一次性绑死在固定时间点的）。
        let dueDateChanged = dueDate != nil
        switch dueDate {
        case .set(let date): task.dueDate = date
        case .clear: task.dueDate = nil
        case nil: break
        }
        if let isAllDay = isAllDay { task.isAllDay = isAllDay }
        if let list = list { task.list = list }
        switch plannedTime {
        case .set(let start, let end):
            guard TodoTask.isValidPlannedRange(start, end) else {
                preconditionFailure("计划时间段必须同一天且开始早于结束")
            }
            task.plannedStart = start
            task.plannedEnd = end
        case .clear:
            task.plannedStart = nil
            task.plannedEnd = nil
        case nil:
            break
        }

        // 更新提醒
        if let reminders = reminders {
            task.remindersSet = reminders
            // 更新通知
            Task {
                try? await TodoNotificationService.shared.updateReminders(for: task, reminders: Array(reminders))
            }
        }

        task.updatedAt = Date()

        try context.save()
        loadActiveTasks()
        notifyDataChange()

        // 截止时间改动后，把已调度的通知挪到新时间：先取消旧的，再按新时间重建。
        // 只改 reminders 时上面已处理；这里覆盖「只改 dueDate 没动 reminders」的情况。
        if dueDateChanged, !task.completed, task.deletedAt == nil, !task.archived, task.hasReminders {
            Task {
                await TodoNotificationService.shared.cancelReminders(for: task)
                try? await TodoNotificationService.shared.scheduleReminder(
                    for: task, reminders: task.remindersArray
                )
            }
        }
    }

    /// 主任务标记完成时，级联勾上所有未完成子任务。
    /// 「已完成任务 ⇒ 子任务全部完成」是展示与统计共同依赖的不变式；
    /// 取消完成则保留子任务勾选（重开任务时已做步骤的进度仍在）。
    private func checkOffAllItems(of task: TodoTask) {
        let items = task.checkItems?.allObjects as? [CheckItem] ?? []
        for item in items where !item.isChecked {
            item.isChecked = true
        }
    }

    /// 切换任务完成状态
    @discardableResult
    func toggleTaskCompletion(_ task: TodoTask) throws -> Bool {
        task.completed.toggle()
        if task.completed {
            task.completedAt = Date()
            checkOffAllItems(of: task)
        } else {
            task.completedAt = nil
        }
        task.updatedAt = Date()
        try context.save()
        loadActiveTasks()
        notifyDataChange()

        if task.completed {
            TodoNotificationService.shared.removeReminders(for: task)
        } else {
            rescheduleRemindersIfNeeded(for: task)
        }
        return task.completed
    }

    /// 完成任务
    func completeTask(_ task: TodoTask) throws {
        task.completed = true
        task.completedAt = Date()
        task.updatedAt = Date()
        checkOffAllItems(of: task)

        try context.save()
        loadActiveTasks()
        notifyDataChange()

        TodoNotificationService.shared.removeReminders(for: task)
    }

    /// 取消完成任务
    func uncompleteTask(_ task: TodoTask) throws {
        task.completed = false
        task.completedAt = nil
        task.updatedAt = Date()

        try context.save()
        loadActiveTasks()
        notifyDataChange()

        rescheduleRemindersIfNeeded(for: task)
    }

    /// 记录任务实际用时（分钟）：完成带时间段任务时可选确认，供计划 vs 实际对比
    func setActualDuration(_ task: TodoTask, minutes: Int?) throws {
        task.actualDurationMinutes = minutes.map { NSNumber(value: max(0, $0)) }
        task.updatedAt = Date()
        try context.save()
        notifyDataChange()
    }

    // MARK: - 全局完成撤回

    /// 开始完成撤回流程：乐观标记 UI，3 秒后真正落库，期间可撤回。
    /// 跨界面共享 pendingCompletionTaskId，任何界面都能看到撤回 banner。
    func startPendingCompletion(for task: TodoTask) {
        // 如果有上一个待确认的任务，立即确认它
        confirmPendingCompletion()

        pendingCompletionTaskId = task.id

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.confirmPendingCompletion()
        }
        pendingCompletionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    /// 确认待完成的任务（真正落库）
    func confirmPendingCompletion() {
        guard let pendingId = pendingCompletionTaskId else { return }
        pendingCompletionWorkItem?.cancel()
        pendingCompletionWorkItem = nil

        if let task = findTask(by: pendingId) {
            do {
                if task.repeatRule != nil {
                    _ = try completeRepeatingTask(task)
                } else {
                    try completeTask(task)
                }
            } catch {
                logger.error("确认完成任务失败: \(error.localizedDescription)")
            }
        }
        pendingCompletionTaskId = nil
    }

    /// 撤回待完成的任务（取消 3 秒计时，不落库）
    func undoPendingCompletion() {
        pendingCompletionWorkItem?.cancel()
        pendingCompletionWorkItem = nil
        pendingCompletionTaskId = nil
    }

    /// 完成重复任务并生成下一个实例
    /// - Parameter task: 要完成的重复任务
    /// - Returns: 是否生成了下一个任务实例
    @discardableResult
    func completeRepeatingTask(_ task: TodoTask) throws -> Bool {
        guard let rule = task.repeatRule else {
            // 非重复任务，直接完成
            task.completed = true
            task.completedAt = Date()
            task.updatedAt = Date()
            checkOffAllItems(of: task)
            try context.save()
            loadActiveTasks()
            notifyDataChange()

            TodoNotificationService.shared.removeReminders(for: task)
            return false
        }

        // 计算下一个到期日期
        let fromDate = task.dueDate ?? Date()
        guard let nextDate = rule.nextDueDate(from: fromDate) else {
            // 已达到结束条件，直接完成（不再生成新任务）
            task.completed = true
            task.completedAt = Date()
            task.updatedAt = Date()
            checkOffAllItems(of: task)
            try context.save()
            loadActiveTasks()
            notifyDataChange()

            TodoNotificationService.shared.removeReminders(for: task)
            return false
        }

        // 创建下一个任务实例
        let nextTask = TodoTask.create(
            in: context,
            title: task.title,
            list: task.list,
            priority: task.taskPriority,
            dueDate: nextDate,
            isAllDay: task.isAllDay,
            reminders: task.remindersSet
        )

        // 关联相同的重复规则
        nextTask.repeatRule = rule

        // 完成当前任务
        task.completed = true
        task.completedAt = Date()
        task.updatedAt = Date()
        checkOffAllItems(of: task)

        // 解除当前任务与重复规则的关系（保留规则给下一个任务）
        task.repeatRule = nil

        try context.save()
        loadActiveTasks()
        notifyDataChange()

        // 取消当前任务的通知，为新任务调度通知
        TodoNotificationService.shared.removeReminders(for: task)
        rescheduleRemindersIfNeeded(for: nextTask)
        return true
    }

    /// 软删除任务（进入回收站）
    func deleteTask(_ task: TodoTask) throws {
        task.deletedFlag = true
        task.deletedAt = Date()
        task.updatedAt = Date()

        try context.save()
        loadActiveTasks()
        loadTrashedTasks()
        notifyDataChange()

        TodoNotificationService.shared.removeReminders(for: task)
    }

    /// 恢复任务（从回收站）
    func restoreTask(_ task: TodoTask) throws {
        task.deletedFlag = false
        task.deletedAt = nil
        task.updatedAt = Date()

        try context.save()
        loadActiveTasks()
        loadTrashedTasks()
        notifyDataChange()

        rescheduleRemindersIfNeeded(for: task)
    }

    /// 永久删除任务
    func permanentlyDeleteTask(_ task: TodoTask) throws {
        let taskId = task.id
        TodoNotificationService.shared.removeReminders(for: task)
        deleteAllAttachmentFiles(for: task)
        context.delete(task)
        try context.save()
        loadActiveTasks()
        loadTrashedTasks()
        notifyDataChange(taskId: taskId)
    }

    /// 归档任务
    func archiveTask(_ task: TodoTask) throws {
        task.archived = true
        task.updatedAt = Date()

        try context.save()
        loadActiveTasks()
        notifyDataChange()

        TodoNotificationService.shared.removeReminders(for: task)
    }

    /// 取消归档任务
    func unarchiveTask(_ task: TodoTask) throws {
        task.archived = false
        task.updatedAt = Date()

        try context.save()
        loadActiveTasks()
        notifyDataChange()

        rescheduleRemindersIfNeeded(for: task)
    }

    // MARK: - Reminder Helpers

    /// 任务恢复活跃状态时，重新调度提醒
    /// （绝对提醒不需要截止日期；相对提醒需有截止日期才有效，scheduleReminder 内部会跳过无效项）
    func rescheduleRemindersIfNeeded(for task: TodoTask) {
        guard !task.completed, task.deletedAt == nil, !task.archived,
              task.hasReminders else { return }
        Task {
            try? await TodoNotificationService.shared.scheduleReminder(
                for: task, reminders: task.remindersArray
            )
        }
    }

    /// 加载已归档任务
    func loadArchivedTasks() -> [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "archived == YES AND deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]

        do {
            return try context.fetch(request)
        } catch {
            Logger(subsystem: "com.holo.app", category: "TodoRepository").error("加载已归档任务失败：\(error)")
            return []
        }
    }

    /// 加载已归档清单
    func loadArchivedLists() -> [TodoList] {
        let request = TodoList.fetchRequest()
        request.predicate = NSPredicate(format: "archived == YES AND deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]

        do {
            return try context.fetch(request)
        } catch {
            logger.error("加载已归档清单失败：\(error)")
            return []
        }
    }

    // MARK: - CheckItem CRUD

    /// 添加子任务
    @discardableResult
    func addCheckItem(title: String, to task: TodoTask, order: Int16) throws -> CheckItem {
        let item = CheckItem.create(in: context, title: title, task: task, order: order)
        try context.save()
        loadActiveTasks()
        notifyDataChange()
        return item
    }

    /// 切换子任务状态
    func toggleCheckItem(_ item: CheckItem) throws {
        item.isChecked.toggle()
        item.task?.updatedAt = Date()
        try context.save()
        loadActiveTasks()
        notifyDataChange()
    }

    /// 删除子任务
    func deleteCheckItem(_ item: CheckItem) throws {
        let task = item.task
        task?.removeCheckItems(item)
        task?.updatedAt = Date()
        context.delete(item)
        context.processPendingChanges()
        try context.save()
        loadActiveTasks()
        notifyDataChange()
    }

    /// 更新子任务标题
    func updateCheckItemTitle(_ item: CheckItem, newTitle: String) throws {
        item.title = newTitle
        try context.save()
        notifyDataChange()
    }

    /// 更新子任务顺序
    func updateCheckItemOrder(_ items: [CheckItem]) throws {
        for (index, item) in items.enumerated() {
            item.order = Int16(index)
        }
        try context.save()
        notifyDataChange()
    }

    // MARK: - RepeatRule CRUD

    /// 创建重复规则
    @discardableResult
    func createRepeatRule(
        type: RepeatType,
        for task: TodoTask,
        weekdays: [Weekday]? = nil,
        interval: Int = 1,
        monthDay: Int? = nil,
        untilDate: Date? = nil
    ) throws -> RepeatRule {
        let rule = RepeatRule.create(in: context, type: type, task: task)

        if let weekdays = weekdays {
            rule.weekdaysArray = weekdays
        }
        rule.repeatInterval = interval
        if let monthDay = monthDay {
            rule.monthDay = Int16(monthDay)
        }
        rule.untilDate = untilDate

        task.repeatRule = rule
        try context.save()
        notifyDataChange()
        return rule
    }

    /// 删除重复规则
    func deleteRepeatRule(_ rule: RepeatRule) throws {
        let task = rule.task
        task?.repeatRule = nil
        context.delete(rule)
        try context.save()
        notifyDataChange()
    }

    /// 更新重复规则的每月参数
    func updateRepeatRuleMonthlyParams(
        _ rule: RepeatRule,
        monthDay: Int? = nil,
        monthWeekOrdinal: Int? = nil,
        monthWeekday: Weekday? = nil,
        untilCount: Int? = nil
    ) throws {
        if let monthDay = monthDay {
            rule.monthDay = Int16(monthDay)
        }
        if let monthWeekOrdinal = monthWeekOrdinal {
            rule.monthWeekOrdinal = Int16(monthWeekOrdinal)
        }
        if let monthWeekday = monthWeekday {
            rule.monthWeekday = monthWeekday.rawValue.description
        }
        if let untilCount = untilCount {
            rule.untilCount = Int16(untilCount)
        }
        try context.save()
        notifyDataChange()
    }

    // MARK: - Query Methods

    /// 通过 ID 查找任务
    func findTask(by id: UUID) -> TodoTask? {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request).first) ?? nil
    }

    /// 标记任务的 AI 确认流程来源（对账用，与 Transaction.aiSourceMessageId 同构）
    func markTaskAISource(taskId: UUID, messageId: String?, itemId: String?) {
        guard let task = findTask(by: taskId) else { return }
        task.aiSourceMessageId = messageId
        task.aiSourceItemId = itemId
        try? context.save()
    }

    /// 按 AI 确认流程来源查找任务（对账：确认中途被杀时实体已建但消息仍停在 confirming）
    func findTaskByAISource(messageId: String, itemId: String) -> TodoTask? {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "aiSourceMessageId == %@ AND aiSourceItemId == %@",
            messageId, itemId
        )
        request.fetchLimit = 1
        return (try? context.fetch(request).first) ?? nil
    }

    /// 通过 ID 查找清单
    func findList(by id: UUID) -> TodoList? {
        let request = TodoList.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request).first) ?? nil
    }

    /// 通过 ID 查找文件夹
    func findFolder(by id: UUID) -> TodoFolder? {
        let request = TodoFolder.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request).first) ?? nil
    }

    /// 获取指定清单的任务列表
    func getTasks(for list: TodoList) -> [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "list == %@ AND deletedAt == nil AND archived == NO",
            list as CVarArg
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "completed", ascending: true),
            NSSortDescriptor(key: "priority", ascending: false)
        ]
        return (try? context.fetch(request)) ?? []
    }

    /// 获取今天的任务
    func getTodayTasks() -> [TodoTask] {
        let today = Calendar.current.startOfDay(for: Date())
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "deletedAt == nil AND archived == NO AND completed == NO AND dueDate >= %@ AND dueDate < %@",
            today as NSDate,
            tomorrow as NSDate
        )
        return (try? context.fetch(request)) ?? []
    }

    /// 获取已过期的任务
    func getOverdueTasks() -> [TodoTask] {
        let now = Date()

        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "deletedAt == nil AND archived == NO AND completed == NO AND dueDate < %@",
            now as NSDate
        )
        // Core Data 只能按存储的原始日期筛选；全天任务存的是当天 00:00，
        // 因此这里必须再按统一的有效截止时间过滤，避免今天的全天任务被误判为过期。
        return (try? context.fetch(request))?.filter {
            TodoTaskDatePolicy.isOverdue(
                dueDate: $0.dueDate,
                isAllDay: $0.isAllDay,
                completed: $0.completed,
                now: now
            )
        } ?? []
    }

    /// 获取指定优先级的任务
    func getTasks(priority: TaskPriority) -> [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "deletedAt == nil AND archived == NO AND priority == %@",
            NSNumber(value: priority.rawValue)
        )
        return (try? context.fetch(request)) ?? []
    }

    /// 搜索任务（按标题、描述、清单名）
    func searchTasks(keyword: String) -> [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "(deletedAt == nil AND archived == NO) AND (title CONTAINS[cd] %@ OR desc CONTAINS[cd] %@ OR list.name CONTAINS[cd] %@)",
            keyword, keyword, keyword
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "completed", ascending: true),
            NSSortDescriptor(key: "priority", ascending: false),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
        return (try? context.fetch(request)) ?? []
    }

    /// 获取回收站中的任务
    func getTrashedTasks() -> [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "deletedFlag == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "deletedAt", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    /// 清空回收站（永久删除所有已删除任务）
    func clearTrash() throws {
        let trashed = getTrashedTasks()
        let taskIds = trashed.map { $0.id }
        for task in trashed {
            context.delete(task)
        }
        try context.save()
        AttachmentFileManager.deleteAttachmentDirectories(for: taskIds)
        loadTrashedTasks()
        notifyDataChange()
    }


    // MARK: - Notifications

    /// 发送数据变更通知
    func notifyDataChange(taskId: UUID? = nil) {
        NotificationCenter.default.post(
            name: .todoDataDidChange,
            object: taskId
        )
    }

    // MARK: - Attachment Helpers

    /// 收集清单内所有任务的 ID（用于 deleteList 前收集附件目录）
    private func collectTaskIdsInList(_ list: TodoList) -> [UUID] {
        (list.tasks?.allObjects as? [TodoTask] ?? []).map { $0.id }
    }

    /// 收集文件夹内所有任务的 ID（用于 deleteFolder 前收集附件目录）
    private func collectTaskIdsInFolder(_ folder: TodoFolder) -> [UUID] {
        let lists = folder.lists?.allObjects as? [TodoList] ?? []
        return lists.flatMap { collectTaskIdsInList($0) }
    }
}

// MARK: - Aggregation Types

struct DailyTaskCount: Codable, Equatable {
    let date: Date
    let completedCount: Int
}

struct TaskPeriodStats: Codable, Equatable {
    let completedInPeriod: Int
    let dueInPeriod: Int
    let overdueInPeriod: Int
    let completionRate: Double
    let highPriorityCompletionRate: Double?
    let createdInPeriod: Int
    let carriedOverBacklogCount: Int
    let activeBacklogCount: Int
}
