//
//  TodoList+CoreDataProperties.swift
//  Holo
//
//  待办清单实体属性扩展
//

import Foundation
import CoreData

extension TodoList {

    // MARK: - 创建方法

    @nonobjc public class func create(
        in context: NSManagedObjectContext,
        name: String,
        folder: TodoFolder? = nil,
        color: String? = nil,
        isEphemeral: Bool = false
    ) -> TodoList {
        let list = TodoList(context: context)
        list.id = UUID()
        list.name = name
        list.folder = folder
        list.color = color
        list.isEphemeral = isEphemeral
        list.sortOrder = Int16((folder?.lists?.allObjects as? [TodoList] ?? []).count)
        list.createdAt = Date()
        list.updatedAt = Date()
        return list
    }

    // MARK: - 计算属性

    /// 任务数量（未归档、未删除）
    var taskCount: Int {
        let tasksArray = tasks?.allObjects as? [TodoTask] ?? []
        return tasksArray.filter { !$0.deletedFlag && !$0.archived }.count
    }

    /// 是否还有未完成任务（未删除、未归档、未完成）——一次性清单退场判定，
    /// 与首页「全部未完成」范围的成员口径一致
    var hasIncompleteTasks: Bool {
        let tasksArray = tasks?.allObjects as? [TodoTask] ?? []
        return tasksArray.contains { !$0.deletedFlag && !$0.archived && !$0.completed }
    }

    /// 是否有已完成任务（未删除）——存量迁移判定「做过且做完了」用，
    /// 区别于从未用过的空清单
    var hasCompletedTasks: Bool {
        let tasksArray = tasks?.allObjects as? [TodoTask] ?? []
        return tasksArray.contains { !$0.deletedFlag && $0.completed }
    }

    /// 完成任务数量
    var completedTaskCount: Int {
        let tasksArray = tasks?.allObjects as? [TodoTask] ?? []
        return tasksArray.filter { $0.completed && !$0.deletedFlag && !$0.archived }.count
    }
}

// MARK: - 排序描述符

extension TodoList {

    /// 按排序顺序排序
    public static func sortByOrder() -> NSSortDescriptor {
        NSSortDescriptor(key: "sortOrder", ascending: true)
    }
}
