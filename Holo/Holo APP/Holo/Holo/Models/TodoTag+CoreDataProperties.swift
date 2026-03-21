//
//  TodoTag+CoreDataProperties.swift
//  Holo
//
//  待办标签实体属性扩展
//

import Foundation
import CoreData

extension TodoTag {

    // MARK: - 创建方法

    @nonobjc public class func create(
        in context: NSManagedObjectContext,
        name: String,
        color: String
    ) -> TodoTag {
        let tag = TodoTag(context: context)
        tag.id = UUID()
        tag.name = name
        tag.color = color
        tag.createdAt = Date()
        return tag
    }
}
