//
//  CheckItem+CoreDataProperties.swift
//  Holo
//
//  检查项实体属性扩展
//

import Foundation
import CoreData

extension CheckItem {

    // MARK: - 创建方法

    @nonobjc public class func create(
        in context: NSManagedObjectContext,
        title: String,
        task: TodoTask,
        order: Int16 = 0
    ) -> CheckItem {
        let item = CheckItem(context: context)
        item.id = UUID()
        item.title = title
        item.task = task
        item.order = order
        item.isChecked = false
        item.createdAt = Date()
        return item
    }
}
