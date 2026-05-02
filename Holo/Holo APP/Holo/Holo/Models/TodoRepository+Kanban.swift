//
//  TodoRepository+Kanban.swift
//  Holo
//
//  看板相关查询方法扩展
//

import CoreData
import os.log

extension TodoRepository {

    private static let kanbanLogger = Logger(subsystem: "com.holo.app", category: "TodoRepository+Kanban")

    // MARK: - 看板查询

    /// 获取今日看板任务（规划到今天 + 今日到期，去重）
    func getDailyKanbanTasks() -> [TodoTask] {
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()

        let today = Date()
        let startOfDay = Calendar.current.startOfDay(for: today)
        guard let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }

        let plannedToday = NSPredicate(format: "plannedDate >= %@ AND plannedDate < %@", startOfDay as NSDate, endOfDay as NSDate)
        let dueToday = NSPredicate(format: "dueDate >= %@ AND dueDate < %@", startOfDay as NSDate, endOfDay as NSDate)

        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            plannedToday,
            dueToday,
            NSPredicate(format: "isDailyRitual == true AND completed == false")
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "isDailyRitual", ascending: false),
            NSSortDescriptor(key: "priority", ascending: false),
            NSSortDescriptor(key: "plannedDate", ascending: true),
        ]

        do {
            let tasks = try context.fetch(request)
            return tasks.filter { !$0.deletedFlag && !$0.archived }
        } catch {
            Self.kanbanLogger.error("获取今日看板任务失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 获取今日规划的任务（仅 plannedDate = today）
    func getPlannedTodayTasks() -> [TodoTask] {
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()

        let startOfDay = Calendar.current.startOfDay(for: Date())
        guard let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "plannedDate >= %@ AND plannedDate < %@", startOfDay as NSDate, endOfDay as NSDate),
            NSPredicate(format: "deletedFlag == false"),
            NSPredicate(format: "archived == false"),
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "isDailyRitual", ascending: false),
            NSSortDescriptor(key: "priority", ascending: false),
        ]

        do {
            return try context.fetch(request)
        } catch {
            Self.kanbanLogger.error("获取今日规划任务失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 获取今日到期的任务（仅 dueDate = today，未完成的）
    func getDueTodayUnplannedTasks() -> [TodoTask] {
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()

        let startOfDay = Calendar.current.startOfDay(for: Date())
        guard let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "dueDate >= %@ AND dueDate < %@", startOfDay as NSDate, endOfDay as NSDate),
            NSPredicate(format: "plannedDate == nil"),
            NSPredicate(format: "completed == false"),
            NSPredicate(format: "deletedFlag == false"),
            NSPredicate(format: "archived == false"),
            NSPredicate(format: "isDailyRitual == false"),
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "priority", ascending: false),
        ]

        do {
            return try context.fetch(request)
        } catch {
            Self.kanbanLogger.error("获取今日到期未规划任务失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 获取近期待办：未来 3 天内到期的未完成任务（排除已规划到今日和今日到期的）
    func getUncompletedRecentTasks(limit: Int = 5) -> [TodoTask] {
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()

        let today = Date()
        let startOfDay = Calendar.current.startOfDay(for: today)
        guard let endOf3Days = Calendar.current.date(byAdding: .day, value: 4, to: startOfDay) else { return [] }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "dueDate >= %@ AND dueDate < %@", startOfDay as NSDate, endOf3Days as NSDate),
            NSPredicate(format: "completed == false"),
            NSPredicate(format: "deletedFlag == false"),
            NSPredicate(format: "archived == false"),
            NSPredicate(format: "isDailyRitual == false"),
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "dueDate", ascending: true),
            NSSortDescriptor(key: "priority", ascending: false),
        ]
        request.fetchLimit = limit

        do {
            let tasks = try context.fetch(request)
            let plannedIds = Set(getPlannedTodayTasks().map { $0.objectID })
            let dueTodayIds = Set(getDueTodayUnplannedTasks().map { $0.objectID })
            let excludeIds = plannedIds.union(dueTodayIds)
            return tasks.filter { !excludeIds.contains($0.objectID) }
        } catch {
            Self.kanbanLogger.error("获取近期待办失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 获取无到期日的未完成任务（最近创建的）
    func getUnplannedOpenTasks(limit: Int = 3) -> [TodoTask] {
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "dueDate == nil"),
            NSPredicate(format: "plannedDate == nil"),
            NSPredicate(format: "completed == false"),
            NSPredicate(format: "deletedFlag == false"),
            NSPredicate(format: "archived == false"),
            NSPredicate(format: "isDailyRitual == false"),
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: false),
        ]
        request.fetchLimit = limit

        do {
            return try context.fetch(request)
        } catch {
            Self.kanbanLogger.error("获取未规划任务失败: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 看板操作

    /// 将任务规划到指定日期
    func planTask(_ task: TodoTask, for date: Date) throws {
        task.plannedDate = Calendar.current.startOfDay(for: date)
        task.updatedAt = Date()
        try context.save()
        NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
    }

    /// 从看板取消规划（不删除任务）
    func unplanTask(_ task: TodoTask) throws {
        task.plannedDate = nil
        task.updatedAt = Date()
        try context.save()
        NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
    }

    /// 获取今日看板进度
    func getDailyKanbanProgress() -> (completed: Int, total: Int) {
        let tasks = getDailyKanbanTasks()
        let completed = tasks.filter { $0.completed }.count
        return (completed, tasks.count)
    }

    /// 创建每日仪式任务
    @discardableResult
    func createDailyRitual(
        title: String,
        list: TodoList? = nil,
        priority: TaskPriority = .medium
    ) throws -> TodoTask {
        let task = TodoTask.create(
            in: context,
            title: title,
            list: list,
            priority: priority,
            isDailyRitual: true
        )
        task.plannedDate = Calendar.current.startOfDay(for: Date())
        try context.save()
        NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
        return task
    }

    /// 为今日生成仪式任务实例（如果今日还没有的话）
    func seedDailyRitualsForToday() {
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()

        let startOfDay = Calendar.current.startOfDay(for: Date())
        guard let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) else { return }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "isDailyRitual == true"),
            NSPredicate(format: "completed == false"),
            NSPredicate(format: "deletedFlag == false"),
            NSPredicate(format: "plannedDate >= %@ AND plannedDate < %@", startOfDay as NSDate, endOfDay as NSDate),
        ])

        do {
            let existingRituals = try context.fetch(request)
            guard existingRituals.isEmpty else { return }
        } catch {
            Self.kanbanLogger.error("检查今日仪式任务失败: \(error.localizedDescription)")
            return
        }
    }
}
