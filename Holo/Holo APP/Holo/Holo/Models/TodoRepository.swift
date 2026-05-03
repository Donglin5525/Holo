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

    // MARK: - Singleton

    static let shared = TodoRepository()

    // MARK: - Published Properties

    /// 当前活跃的文件夹列表
    @Published var folders: [TodoFolder] = []

    /// 当前活跃的任务列表（未归档、未删除）
    @Published var activeTasks: [TodoTask] = []

    /// 回收站中的任务（已删除）
    @Published var trashedTasks: [TodoTask] = []

    /// 所有标签列表
    @Published var tags: [TodoTag] = []

    /// 是否已完成初始化（供 UI 判断加载状态）
    @Published private(set) var isReady: Bool = false

    /// 没有关联文件夹的清单
    var unfiledLists: [TodoList] {
        let request = TodoList.fetchRequest()
        request.predicate = NSPredicate(format: "folder == nil AND archived == NO")
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    // MARK: - Properties

    /// 主上下文（主线程）
    var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }

    // MARK: - Initialization

    /// init 不做任何 I/O 操作，避免阻塞主线程
    /// 所有数据操作延迟到 setup() 中执行
    private init() {}

    /// 延迟初始化：加载所有数据
    /// 在 Core Data store 就绪后调用（HomeView.task 中）
    func setup() {
        guard !isReady else { return }
        loadFolders()
        loadActiveTasks()
        loadTrashedTasks()
        loadTags()
        isReady = true
    }

    // MARK: - 数据加载

    /// 加载文件夹列表
    func loadFolders() {
        let request = TodoFolder.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]

        do {
            folders = try context.fetch(request)
        } catch {
            print("[TodoRepository] 加载文件夹失败：\(error)")
            folders = []
        }
    }

    /// 加载活跃任务列表
    func loadActiveTasks() {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "deletedFlag == NO AND archived == NO"
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "completed", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: false)
        ]

        do {
            activeTasks = try context.fetch(request)
        } catch {
            print("[TodoRepository] 加载任务失败：\(error)")
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
            print("[TodoRepository] 加载回收站失败：\(error)")
            trashedTasks = []
        }
    }

    /// 加载标签列表
    func loadTags() {
        let request = TodoTag.fetchRequest()
        request.predicate = NSPredicate(format: "deletedFlag == NO")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        do {
            tags = try context.fetch(request)
        } catch {
            print("[TodoRepository] 加载标签失败：\(error)")
            tags = []
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
        tags: [TodoTag] = [],
        reminders: Set<TaskReminder>? = nil
    ) throws -> TodoTask {
        let task = TodoTask.create(
            in: context,
            title: title,
            desc: description,
            list: list,
            priority: priority,
            dueDate: dueDate,
            isAllDay: isAllDay,
            reminders: reminders
        )

        // 关联标签
        for tag in tags {
            task.addToTags(tag)
        }

        // 调度提醒通知
        if let reminders = reminders, !reminders.isEmpty, dueDate != nil {
            Task {
                try? await TodoNotificationService.shared.scheduleReminder(for: task, reminders: Array(reminders))
            }
        }

        try context.save()
        loadActiveTasks()
        notifyDataChange()
        return task
    }

    /// 更新任务
    func updateTask(
        _ task: TodoTask,
        title: String? = nil,
        description: String? = nil,
        status: TaskStatus? = nil,
        priority: TaskPriority? = nil,
        dueDate: Date? = nil,
        isAllDay: Bool? = nil,
        list: TodoList? = nil,
        tags: [TodoTag]? = nil,
        reminders: Set<TaskReminder>? = nil
    ) throws {
        if let title = title { task.title = title }
        if let description = description { task.desc = description }
        if let status = status { task.taskStatus = status }
        if let priority = priority { task.taskPriority = priority }
        if let dueDate = dueDate { task.dueDate = dueDate }
        if let isAllDay = isAllDay { task.isAllDay = isAllDay }
        if let list = list { task.list = list }

        // 更新标签关联
        if let tags = tags {
            // 先移除所有现有标签
            if let existingTags = task.tags?.allObjects as? [TodoTag] {
                for tag in existingTags {
                    task.removeFromTags(tag)
                }
            }
            // 添加新标签
            for tag in tags {
                task.addToTags(tag)
            }
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
    }

    /// 切换任务完成状态
    @discardableResult
    func toggleTaskCompletion(_ task: TodoTask) throws -> Bool {
        task.completed.toggle()
        task.completed ? (task.completedAt = Date()) : (task.completedAt = nil)
        task.updatedAt = Date()

        try context.save()
        loadActiveTasks()
        notifyDataChange()
        return task.completed
    }

    /// 完成任务
    func completeTask(_ task: TodoTask) throws {
        task.completed = true
        task.completedAt = Date()
        task.updatedAt = Date()

        try context.save()
        loadActiveTasks()
        notifyDataChange()
    }

    /// 取消完成任务
    func uncompleteTask(_ task: TodoTask) throws {
        task.completed = false
        task.completedAt = nil
        task.updatedAt = Date()

        try context.save()
        loadActiveTasks()
        notifyDataChange()
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
            try context.save()
            loadActiveTasks()
            notifyDataChange()
            return false
        }

        // 计算下一个到期日期
        let fromDate = task.dueDate ?? Date()
        guard let nextDate = rule.nextDueDate(from: fromDate) else {
            // 已达到结束条件，直接完成（不再生成新任务）
            task.completed = true
            task.completedAt = Date()
            task.updatedAt = Date()
            try context.save()
            loadActiveTasks()
            notifyDataChange()
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

        // 关联相同的标签
        if let tags = task.tags?.allObjects as? [TodoTag] {
            for tag in tags {
                nextTask.addToTags(tag)
            }
        }

        // 关联相同的重复规则
        nextTask.repeatRule = rule

        // 完成当前任务
        task.completed = true
        task.completedAt = Date()
        task.updatedAt = Date()

        // 解除当前任务与重复规则的关系（保留规则给下一个任务）
        task.repeatRule = nil

        try context.save()
        loadActiveTasks()
        notifyDataChange()
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
    }

    /// 永久删除任务
    func permanentlyDeleteTask(_ task: TodoTask) throws {
        let taskId = task.id
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
    }

    /// 取消归档任务
    func unarchiveTask(_ task: TodoTask) throws {
        task.archived = false
        task.updatedAt = Date()

        try context.save()
        loadActiveTasks()
        notifyDataChange()
    }

    // MARK: - Tag CRUD

    /// 创建标签
    @discardableResult
    func createTag(name: String, color: String) throws -> TodoTag {
        let tag = TodoTag.create(in: context, name: name, color: color)
        try context.save()
        loadTags()
        notifyDataChange()
        return tag
    }

    /// 更新标签
    func updateTag(_ tag: TodoTag, name: String? = nil, color: String? = nil) throws {
        if let name = name { tag.name = name }
        if let color = color { tag.color = color }

        try context.save()
        loadTags()
        notifyDataChange()
    }

    /// 软删除标签（归档）
    func deleteTag(_ tag: TodoTag) throws {
        tag.deletedFlag = true
        try context.save()
        loadTags()
        notifyDataChange()
    }

    /// 永久删除标签
    func permanentlyDeleteTag(_ tag: TodoTag) throws {
        context.delete(tag)
        try context.save()
        loadTags()
        notifyDataChange()
    }

    /// 加载已归档标签
    func loadArchivedTags() -> [TodoTag] {
        let request = TodoTag.fetchRequest()
        request.predicate = NSPredicate(format: "deletedFlag == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        do {
            return try context.fetch(request)
        } catch {
            print("[TodoRepository] 加载已归档标签失败：\(error)")
            return []
        }
    }

    /// 恢复归档标签
    func restoreTag(_ tag: TodoTag) throws {
        tag.deletedFlag = false

        try context.save()
        loadTags()
        notifyDataChange()
    }

    /// 加载已归档清单
    func loadArchivedLists() -> [TodoList] {
        let request = TodoList.fetchRequest()
        request.predicate = NSPredicate(format: "archived == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]

        do {
            return try context.fetch(request)
        } catch {
            print("[TodoRepository] 加载已归档清单失败：\(error)")
            return []
        }
    }

    // MARK: - CheckItem CRUD

    /// 添加检查项
    @discardableResult
    func addCheckItem(title: String, to task: TodoTask, order: Int16) throws -> CheckItem {
        let item = CheckItem.create(in: context, title: title, task: task, order: order)
        try context.save()
        loadActiveTasks()
        notifyDataChange()
        return item
    }

    /// 切换检查项状态
    func toggleCheckItem(_ item: CheckItem) throws {
        item.isChecked.toggle()
        try context.save()
        loadActiveTasks()
        notifyDataChange()
    }

    /// 删除检查项
    func deleteCheckItem(_ item: CheckItem) throws {
        let task = item.task
        context.delete(item)
        try context.save()
        loadActiveTasks()
        notifyDataChange()
    }

    /// 更新检查项顺序
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
        untilDate: Date? = nil
    ) throws -> RepeatRule {
        let rule = RepeatRule.create(in: context, type: type, task: task)

        if let weekdays = weekdays {
            rule.weekdaysArray = weekdays
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
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request).first) ?? nil
    }

    /// 通过 ID 查找清单
    func findList(by id: UUID) -> TodoList? {
        let request = TodoList.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
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
            format: "list == %@ AND deletedFlag == NO AND archived == NO",
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
            format: "deletedFlag == NO AND archived == NO AND completed == NO AND dueDate >= %@ AND dueDate < %@",
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
            format: "deletedFlag == NO AND archived == NO AND completed == NO AND dueDate < %@",
            now as NSDate
        )
        return (try? context.fetch(request)) ?? []
    }

    /// 获取指定优先级的任务
    func getTasks(priority: TaskPriority) -> [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "deletedFlag == NO AND archived == NO AND priority == %@",
            NSNumber(value: priority.rawValue)
        )
        return (try? context.fetch(request)) ?? []
    }

    /// 获取指定标签的任务
    func getTasks(tag: TodoTag) -> [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "deletedFlag == NO AND archived == NO AND ANY tags == %@",
            tag as CVarArg
        )
        return (try? context.fetch(request)) ?? []
    }

    /// 搜索任务（按标题、描述、标签名、清单名）
    func searchTasks(keyword: String) -> [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "(deletedFlag == NO AND archived == NO) AND (title CONTAINS[cd] %@ OR desc CONTAINS[cd] %@ OR ANY tags.name CONTAINS[cd] %@ OR list.name CONTAINS[cd] %@)",
            keyword, keyword, keyword, keyword
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
}
