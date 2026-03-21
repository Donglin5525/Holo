//
//  TodoTask+CoreDataProperties.swift
//  Holo
//
//  待办任务实体属性扩展
//

import Foundation
import CoreData

extension TodoTask {

    // MARK: - 创建方法

    @nonobjc class func create(
        in context: NSManagedObjectContext,
        title: String,
        list: TodoList? = nil,
        priority: TaskPriority = .medium,
        dueDate: Date? = nil,
        isAllDay: Bool = false
    ) -> TodoTask {
        let task = TodoTask(context: context)
        task.id = UUID()
        task.title = title
        task.list = list
        task.priority = priority.rawValue
        task.dueDate = dueDate
        task.isAllDay = isAllDay
        task.status = TaskStatus.todo.rawValue
        task.completed = false
        task.archived = false
        task.deletedFlag = false
        task.createdAt = Date()
        task.updatedAt = Date()
        return task
    }

    // MARK: - 计算属性

    /// 任务状态枚举值
    var taskStatus: TaskStatus {
        get { TaskStatus(rawValue: status ?? "todo") ?? .todo }
        set { status = newValue.rawValue }
    }

    /// 优先级枚举值
    var taskPriority: TaskPriority {
        get { TaskPriority(rawValue: priority) ?? .medium }
        set { priority = newValue.rawValue }
    }

    /// 判断是否已过期
    var isOverdue: Bool {
        guard !completed, let dueDate = effectiveDueDate else { return false }
        return dueDate < Date()
    }

    /// 判断是否今天到期
    var isDueToday: Bool {
        guard let dueDate = dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }

    /// 判断是否明天到期
    var isDueTomorrow: Bool {
        guard let dueDate = dueDate else { return false }
        return Calendar.current.isDateInTomorrow(dueDate)
    }

    /// 有效截止时间（全天任务返回 23:59:59）
    var effectiveDueDate: Date? {
        guard let dueDate else { return nil }
        if isAllDay {
            return Calendar.current.date(
                bySettingHour: 23,
                minute: 59,
                second: 59,
                of: dueDate
            )
        }
        return dueDate
    }

    /// 检查清单完成进度
    var checkItemProgress: String {
        let checkItemsArray = checkItems?.allObjects as? [CheckItem] ?? []
        guard !checkItemsArray.isEmpty else { return "" }
        let completedCount = checkItemsArray.filter { $0.isChecked }.count
        return "已完成 \(completedCount)/\(checkItemsArray.count) 项"
    }

    /// 检查清单完成进度百分比
    var checkItemProgressPercent: Double {
        let checkItemsArray = checkItems?.allObjects as? [CheckItem] ?? []
        guard !checkItemsArray.isEmpty else { return 0 }
        let completedCount = checkItemsArray.filter { $0.isChecked }.count
        return Double(completedCount) / Double(checkItemsArray.count)
    }
}

// MARK: - 排序描述符

extension TodoTask {

    /// 按优先级降序排序
    static func sortByPriority(ascending: Bool = false) -> NSSortDescriptor {
        NSSortDescriptor(key: "priority", ascending: ascending)
    }

    /// 按截止时间升序排序
    static func sortByDueDate(ascending: Bool = true) -> NSSortDescriptor {
        NSSortDescriptor(key: "dueDate", ascending: ascending)
    }

    /// 按创建时间降序排序
    static func sortByCreatedAt(ascending: Bool = false) -> NSSortDescriptor {
        NSSortDescriptor(key: "createdAt", ascending: ascending)
    }

    /// 按状态排序（未完成在前）
    static func sortByStatus() -> NSSortDescriptor {
        NSSortDescriptor(key: "isCompleted", ascending: true)
    }
}
