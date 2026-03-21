//
//  TodoList+CoreDataClass.swift
//  Holo
//
//  待办清单实体类
//

import Foundation
import CoreData

@objc(TodoList)
class TodoList: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<TodoList> {
        NSFetchRequest<TodoList>(entityName: "TodoList")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var sortOrder: Int16
    @NSManaged var color: String?
    @NSManaged var archived: Bool
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date

    // MARK: - Relationships

    @NSManaged var folder: TodoFolder?
    @NSManaged var tasks: NSSet?
}

// MARK: - Core Data Generated Accessors

extension TodoList {
    @objc(addFolderObject:)
    @NSManaged func setFolder(_ value: TodoFolder?)

    @objc(addTasksObject:)
    @NSManaged func addTasks(_ value: TodoTask)

    @objc(removeTasksObject:)
    @NSManaged func removeTasks(_ value: TodoTask)

    @objc(addTasks:)
    @NSManaged func addTasks(_ values: Set<TodoTask>)

    @objc(removeTasks:)
    @NSManaged func removeTasks(_ values: Set<TodoTask>)
}
