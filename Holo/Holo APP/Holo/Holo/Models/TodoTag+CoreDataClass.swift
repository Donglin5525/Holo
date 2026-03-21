//
//  TodoTag+CoreDataClass.swift
//  Holo
//
//  待办标签实体类
//

import Foundation
import CoreData

@objc(TodoTag)
class TodoTag: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<TodoTag> {
        NSFetchRequest<TodoTag>(entityName: "TodoTag")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var color: String
    @NSManaged var deletedFlag: Bool
    @NSManaged var createdAt: Date

    // MARK: - Relationships

    @NSManaged var tasks: NSSet?
}

// MARK: - Core Data Generated Accessors

extension TodoTag {
    @objc(addTasksObject:)
    @NSManaged func addTasks(_ value: TodoTask)

    @objc(removeTasksObject:)
    @NSManaged func removeTasks(_ value: TodoTask)

    @objc(addTasks:)
    @NSManaged func addTasks(_ values: Set<TodoTask>)

    @objc(removeTasks:)
    @NSManaged func removeTasks(_ values: Set<TodoTask>)
}
