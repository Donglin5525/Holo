//
//  TodoFolder+CoreDataClass.swift
//  Holo
//
//  待办文件夹实体类
//

import Foundation
import CoreData

@objc(TodoFolder)
class TodoFolder: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<TodoFolder> {
        NSFetchRequest<TodoFolder>(entityName: "TodoFolder")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var sortOrder: Int16
    @NSManaged var isExpanded: Bool
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date

    // MARK: - Relationships

    @NSManaged var lists: NSSet?
}

// MARK: - Core Data Generated Accessors

extension TodoFolder {
    @objc(addListsObject:)
    @NSManaged func addLists(_ value: TodoList)

    @objc(removeListsObject:)
    @NSManaged func removeLists(_ value: TodoList)

    @objc(addLists:)
    @NSManaged func addLists(_ values: Set<TodoList>)

    @objc(removeLists:)
    @NSManaged func removeLists(_ values: Set<TodoList>)
}
