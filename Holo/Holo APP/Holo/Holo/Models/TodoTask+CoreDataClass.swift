//
//  TodoTask+CoreDataClass.swift
//  Holo
//
//  待办任务实体类
//

import Foundation
import CoreData

@objc(TodoTask)
class TodoTask: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<TodoTask> {
        NSFetchRequest<TodoTask>(entityName: "TodoTask")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var desc: String?
    @NSManaged var status: String
    @NSManaged var priority: Int16
    @NSManaged var dueDate: Date?
    @NSManaged var isAllDay: Bool
    @NSManaged var completed: Bool
    @NSManaged var completedAt: Date?
    @NSManaged var archived: Bool
    @NSManaged var deletedFlag: Bool
    @NSManaged var deletedAt: Date?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date

    // MARK: - Relationships

    @NSManaged var list: TodoList?
    @NSManaged var tags: NSSet?
    @NSManaged var checkItems: NSSet?
    @NSManaged var repeatRule: RepeatRule?
}

// MARK: - Core Data Generated Accessors

extension TodoTask {
    @objc(addTagsObject:)
    @NSManaged func addToTags(_ value: TodoTag)

    @objc(removeTagsObject:)
    @NSManaged func removeFromTags(_ value: TodoTag)

    @objc(addTags:)
    @NSManaged func addToTags(_ values: Set<TodoTag>)

    @objc(removeTags:)
    @NSManaged func removeFromTags(_ values: Set<TodoTag>)

    @objc(addCheckItemsObject:)
    @NSManaged func addCheckItems(_ value: CheckItem)

    @objc(removeCheckItemsObject:)
    @NSManaged func removeCheckItems(_ value: CheckItem)

    @objc(addCheckItems:)
    @NSManaged func addCheckItems(_ values: Set<CheckItem>)

    @objc(removeCheckItems:)
    @NSManaged func removeCheckItems(_ values: Set<CheckItem>)
}
