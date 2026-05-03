//
//  TaskAttachment+CoreDataClass.swift
//  Holo
//
//  任务附件实体类
//

import Foundation
import CoreData

@objc(TaskAttachment)
class TaskAttachment: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<TaskAttachment> {
        NSFetchRequest<TaskAttachment>(entityName: "TaskAttachment")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var fileName: String
    @NSManaged var thumbnailFileName: String
    @NSManaged var sortOrder: Int16
    @NSManaged var sourceType: String
    @NSManaged var createdAt: Date

    // MARK: - Relationships

    @NSManaged var task: TodoTask?
}
