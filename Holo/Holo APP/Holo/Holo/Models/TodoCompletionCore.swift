//
//  TodoCompletionCore.swift
//  Holo
//
//  待办完成语义的纯 Core Data 核心：只做数据库读写，不含通知调度等设备侧副作用。
//  App 内 TodoRepository 与桌面小组件的交互意图共用同一份语义，防止两套规则漂移。
//  副作用（提醒重排、列表刷新、变更广播）由调用方（App 侧仓库）负责。
//

import Foundation
import CoreData

enum TodoCompletionCore {

    // MARK: - 写操作

    /// 切换任务完成状态（纯数据库部分）
    /// - Returns: 切换后的完成状态
    @discardableResult
    static func toggle(
        _ task: TodoTask,
        in context: NSManagedObjectContext,
        sourceSurface: String = "unspecified"
    ) throws -> Bool {
        task.completed.toggle()
        if task.completed {
            task.completedAt = Date()
            checkOffAllItems(of: task)
        } else {
            task.completedAt = nil
        }
        task.updatedAt = Date()
        writeManagedRootReceipt(
            task: task,
            in: context,
            command: task.completed ? "toggleRoot.complete" : "toggleRoot.reopen",
            sourceSurface: sourceSurface
        )
        try context.save()
        return task.completed
    }

    /// 完成任务（纯数据库部分）
    /// - Parameters:
    ///   - saveImmediately: false = 只改状态不落库，由调用方在更大事务里统一 save
    ///     （分步推进「最终步骤+根完成」原子提交，2026-09-25 实施规格 §8.2）
    ///   - sourceSurface: 完成来源（回执审计；App/Widget/通知各自传值）
    ///   - outcomeAssertion: 用户对原结果的明确断言摘要（可空）
    static func complete(
        _ task: TodoTask,
        in context: NSManagedObjectContext,
        saveImmediately: Bool = true,
        sourceSurface: String = "unspecified",
        operationID: String? = nil,
        outcomeAssertion: String? = nil
    ) throws {
        task.completed = true
        task.completedAt = Date()
        task.updatedAt = Date()
        checkOffAllItems(of: task)
        writeManagedRootReceipt(
            task: task,
            in: context,
            command: "completeRoot",
            sourceSurface: sourceSurface,
            operationID: operationID,
            outcomeAssertion: outcomeAssertion
        )
        if saveImmediately {
            try context.save()
        }
    }

    /// 取消完成任务（纯数据库部分）
    static func uncomplete(_ task: TodoTask, in context: NSManagedObjectContext) throws {
        task.completed = false
        task.completedAt = nil
        task.updatedAt = Date()
        try context.save()
    }

    /// 完成重复任务；未达结束条件时生成下一个实例（纯数据库部分）
    /// - Returns: 生成的下一个任务实例；未生成（非重复/已达结束条件）时为 nil
    @discardableResult
    static func completeRepeating(_ task: TodoTask, in context: NSManagedObjectContext) throws -> TodoTask? {
        guard let rule = task.repeatRule else {
            try complete(task, in: context)
            return nil
        }

        // 计算下一个到期日期
        let fromDate = task.dueDate ?? Date()
        guard let nextDate = rule.nextDueDate(from: fromDate) else {
            // 已达到结束条件，直接完成（不再生成新任务）
            try complete(task, in: context)
            return nil
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
        return nextTask
    }

    /// 勾掉任务全部未勾选的子项（完成主任务时随动）
    private static func checkOffAllItems(of task: TodoTask) {
        let items = task.checkItems?.allObjects as? [CheckItem] ?? []
        for item in items where !item.isChecked {
            item.isChecked = true
        }
    }

    /// 分步接管任务（executionSchemaVersion >= 1）的根完成最小来源回执。
    /// 只写来源与命令，不存任务正文/用户内容（规格 §7.2-D）。
    /// 生成步骤不受根完成影响——完成父任务不反证每个步骤都做过（规格 §3.3-4）。
    private static func writeManagedRootReceipt(
        task: TodoTask,
        in context: NSManagedObjectContext,
        command: String,
        sourceSurface: String,
        operationID: String? = nil,
        outcomeAssertion: String? = nil
    ) {
        guard task.executionSchemaVersion >= 1 else { return }
        guard let entity = NSEntityDescription.entity(forEntityName: "HoloTaskExecutionReceipt", in: context) else { return }
        let receipt = HoloTaskExecutionReceipt(entity: entity, insertInto: context)
        receipt.id = UUID()
        receipt.operationID = operationID ?? UUID().uuidString
        receipt.taskID = task.id
        receipt.commandRaw = command
        receipt.actorRaw = HoloTaskExecutionActor.user.rawValue
        receipt.sourceSurface = sourceSurface
        receipt.outcomeAssertion = outcomeAssertion
        receipt.createdAt = Date()
    }

    // MARK: - 读操作（今日口径，自 TodoRepository 原样搬移）

    /// 获取今天的任务
    static func getTodayTasks(in context: NSManagedObjectContext) -> [TodoTask] {
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
    static func getOverdueTasks(in context: NSManagedObjectContext) -> [TodoTask] {
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

    /// 获取今日任务完成进度
    /// 注意：已完成任务必须计入分母（并计入分子），否则任务一完成就退出统计，
    /// 进度条会从 100% 跳回 0%。getTodayTasks() 只含未完成任务，不能在这里复用。
    static func getTodayTaskProgress(in context: NSManagedObjectContext) -> (completed: Int, total: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) else {
            return (0, 0)
        }

        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "deletedAt == nil AND archived == NO AND dueDate >= %@ AND dueDate < %@",
            today as NSDate,
            tomorrow as NSDate
        )
        let todayTasks = (try? context.fetch(request)) ?? []
        let completed = todayTasks.filter { $0.completed }.count
        return (completed, todayTasks.count)
    }

    /// 全量活跃任务（未删未归档；与仓库 loadActiveTasks 同口径）
    static func fetchActiveTasks(in context: NSManagedObjectContext) -> [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "deletedAt == nil AND archived == NO"
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "completed", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: false)
        ]
        return (try? context.fetch(request)) ?? []
    }
}
