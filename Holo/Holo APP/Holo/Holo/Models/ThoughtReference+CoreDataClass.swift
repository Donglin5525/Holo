//
//  ThoughtReference+CoreDataClass.swift
//  Holo
//
//  观点模块 - 引用关系实体类
//

import Foundation
import CoreData

@objc(ThoughtReference)
class ThoughtReference: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ThoughtReference> {
        NSFetchRequest<ThoughtReference>(entityName: "ThoughtReference")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var createdAt: Date

    // MARK: - Relationships

    @NSManaged var sourceThought: Thought
    @NSManaged var targetThought: Thought
}
