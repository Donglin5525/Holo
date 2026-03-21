//
//  TodoFolder+CoreDataProperties.swift
//  Holo
//
//  待办文件夹实体属性扩展
//

import Foundation
import CoreData

extension TodoFolder {

    // MARK: - 创建方法

    @nonobjc class func create(
        in context: NSManagedObjectContext,
        name: String
    ) -> TodoFolder {
        let folder = TodoFolder(context: context)
        folder.id = UUID()
        folder.name = name
        folder.sortOrder = Int16((try? context.count(for: TodoFolder.fetchRequest())) ?? 0)
        folder.isExpanded = true
        folder.createdAt = Date()
        folder.updatedAt = Date()
        return folder
    }

    // MARK: - 计算属性

    /// 清单数量
    var listCount: Int {
        lists?.allObjects.count ?? 0
    }

    /// 清单数组（类型安全的访问器）
    var listsArray: [TodoList] {
        lists?.allObjects as? [TodoList] ?? []
    }

    /// 任务总数（所有清单下的任务）
    var totalTaskCount: Int {
        let listsArray = lists?.allObjects as? [TodoList] ?? []
        return listsArray.reduce(0) { $0 + Int($1.taskCount) }
    }
}

// MARK: - 排序描述符

extension TodoFolder {

    /// 按排序顺序排序
    static func sortByOrder() -> NSSortDescriptor {
        NSSortDescriptor(key: "sortOrder", ascending: true)
    }
}
