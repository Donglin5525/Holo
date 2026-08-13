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

    /// 获取今日看板任务（今日到期 + 已逾期未完成 + 日常仪式，去重）
    func getDailyKanbanTasks() -> [TodoTask] {
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()

        let today = Date()
        let startOfDay = Calendar.current.startOfDay(for: today)

        // 今日到期或已逾期（截止日 <= 今天 23:59:59），未完成
        let dueOrOverdue = NSPredicate(format: "dueDate != nil AND dueDate < %@", startOfDay.addingTimeInterval(86400) as NSDate)
        let dailyRitual = NSPredicate(format: "isDailyRitual == true AND completed == false")

        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            dueOrOverdue,
            dailyRitual
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "isDailyRitual", ascending: false),
            NSSortDescriptor(key: "priority", ascending: false),
            NSSortDescriptor(key: "dueDate", ascending: true),
        ]

        do {
            let tasks = try context.fetch(request)
            return tasks.filter { !$0.deletedFlag && !$0.archived }
        } catch {
            Self.kanbanLogger.error("获取今日看板任务失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 获取今日到期 / 已逾期的未完成任务（看板主体）
    func getDueTodayTasks() -> [TodoTask] {
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()

        let startOfDay = Calendar.current.startOfDay(for: Date())
        guard let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "dueDate != nil AND dueDate < %@", endOfDay as NSDate),
            NSPredicate(format: "completed == false"),
            NSPredicate(format: "deletedFlag == false"),
            NSPredicate(format: "archived == false"),
            NSPredicate(format: "isDailyRitual == false"),
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "dueDate", ascending: true),
            NSSortDescriptor(key: "priority", ascending: false),
        ]

        do {
            return try context.fetch(request)
        } catch {
            Self.kanbanLogger.error("获取今日到期任务失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 获取近期待办：未来到期（明天起 3 天内）的未完成任务
    func getUncompletedRecentTasks(limit: Int = 5) -> [TodoTask] {
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()

        let today = Date()
        let startOfDay = Calendar.current.startOfDay(for: today)
        guard let endOf3Days = Calendar.current.date(byAdding: .day, value: 4, to: startOfDay) else { return [] }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "dueDate >= %@ AND dueDate < %@", startOfDay.addingTimeInterval(86400) as NSDate, endOf3Days as NSDate),
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
            return try context.fetch(request)
        } catch {
            Self.kanbanLogger.error("获取近期待办失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 获取无截止日的未完成任务（最近创建的）
    func getUnplannedOpenTasks(limit: Int = 3) -> [TodoTask] {
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "dueDate == nil"),
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
            Self.kanbanLogger.error("获取无截止日任务失败: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 看板操作

    /// 将任务加入今日（设截止日为今天）
    func planTask(_ task: TodoTask, for date: Date) throws {
        task.dueDate = Calendar.current.startOfDay(for: date)
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

    /// 今日目标贡献：今天完成的、且关联了目标的任务数。
    /// 用于 Hero 卡"目标贡献"文案。
    func getTodayGoalContribution() -> (taskCount: Int, habitCount: Int, goalCount: Int) {
        let context = CoreDataStack.shared.viewContext
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        // 今天完成（completedAt 落在今天）且关联了目标的任务
        let taskRequest: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()
        taskRequest.predicate = NSPredicate(
            format: "completed == true AND completedAt >= %@ AND completedAt < %@ AND goal != nil",
            startOfDay as NSDate,
            tomorrow as NSDate
        )
        let goalTasks = (try? context.fetch(taskRequest))?
            .filter { !$0.deletedFlag && !$0.archived } ?? []
        let taskGoalIds = Set(goalTasks.compactMap { $0.goal?.id })

        // 习惯部分（复用 HabitRepository 的今日完成判定）
        let habitGoalCount = HabitRepository.shared.getTodayGoalHabitContribution()

        let goalCount = taskGoalIds.count + habitGoalCount.goalCount
        return (goalTasks.count, habitGoalCount.habitCount, goalCount)
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
            dueDate: Calendar.current.startOfDay(for: Date()),
            isDailyRitual: true
        )
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
            NSPredicate(format: "dueDate >= %@ AND dueDate < %@", startOfDay as NSDate, endOfDay as NSDate),
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
