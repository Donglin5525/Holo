//
//  Thought+CoreDataClass.swift
//  Holo
//
//  观点模块 - 想法实体类
//

import Foundation
import CoreData

@objc(Thought)
class Thought: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Thought> {
        NSFetchRequest<Thought>(entityName: "Thought")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var content: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var mood: String?
    @NSManaged var orderIndex: Int16
    @NSManaged var imageData: Data?
    @NSManaged var isSoftDeleted: Bool

    // MARK: - Relationships

    @NSManaged var tags: NSSet?
    @NSManaged var references: NSSet?
    @NSManaged var referencedBy: NSSet?
}

// MARK: - Core Data Generated Accessors

extension Thought {
    // MARK: - Tags Accessors

    @objc(addTagsObject:)
    @NSManaged func addTags(_ value: ThoughtTag)

    @objc(removeTagsObject:)
    @NSManaged func removeTags(_ value: ThoughtTag)

    @objc(addTags:)
    @NSManaged func addTags(_ values: Set<ThoughtTag>)

    @objc(removeTags:)
    @NSManaged func removeTags(_ values: Set<ThoughtTag>)

    // MARK: - References Accessors

    @objc(addReferencesObject:)
    @NSManaged func addReferences(_ value: ThoughtReference)

    @objc(removeReferencesObject:)
    @NSManaged func removeReferences(_ value: ThoughtReference)

    @objc(addReferences:)
    @NSManaged func addReferences(_ values: Set<ThoughtReference>)

    @objc(removeReferences:)
    @NSManaged func removeReferences(_ values: Set<ThoughtReference>)

    // MARK: - ReferencedBy Accessors

    @objc(addReferencedByObject:)
    @NSManaged func addReferencedBy(_ value: ThoughtReference)

    @objc(removeReferencedByObject:)
    @NSManaged func removeReferencedBy(_ value: ThoughtReference)

    @objc(addReferencedBy:)
    @NSManaged func addReferencedBy(_ values: Set<ThoughtReference>)

    @objc(removeReferencedBy:)
    @NSManaged func removeReferencedBy(_ values: Set<ThoughtReference>)
}
