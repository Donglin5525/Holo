//
//  ThoughtTag+CoreDataClass.swift
//  Holo
//
//  观点模块 - 标签实体类
//

import Foundation
import CoreData

@objc(ThoughtTag)
class ThoughtTag: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ThoughtTag> {
        NSFetchRequest<ThoughtTag>(entityName: "ThoughtTag")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var color: String?
    @NSManaged var usageCount: Int16

    // MARK: - Relationships

    @NSManaged var thoughts: NSSet?
}

// MARK: - Core Data Generated Accessors

extension ThoughtTag {
    @objc(addThoughtsObject:)
    @NSManaged func addThoughts(_ value: Thought)

    @objc(removeThoughtsObject:)
    @NSManaged func removeThoughts(_ value: Thought)

    @objc(addThoughts:)
    @NSManaged func addThoughts(_ values: Set<Thought>)

    @objc(removeThoughts:)
    @NSManaged func removeThoughts(_ values: Set<Thought>)
}
