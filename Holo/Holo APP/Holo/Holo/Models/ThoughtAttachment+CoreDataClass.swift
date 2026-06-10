//
//  ThoughtAttachment+CoreDataClass.swift
//  Holo
//
//  想法附件实体类
//

import Foundation
import CoreData

@objc(ThoughtAttachment)
class ThoughtAttachment: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ThoughtAttachment> {
        NSFetchRequest<ThoughtAttachment>(entityName: "ThoughtAttachment")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var fileName: String
    @NSManaged var thumbnailFileName: String
    @NSManaged var sortOrder: Int16
    @NSManaged var sourceType: String
    @NSManaged var createdAt: Date
    @NSManaged var imageData: Data?
    @NSManaged var thumbnailData: Data?

    // MARK: - Relationships

    @NSManaged var thought: Thought?
}
