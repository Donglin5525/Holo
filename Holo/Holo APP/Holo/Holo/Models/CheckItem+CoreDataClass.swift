//
//  CheckItem+CoreDataClass.swift
//  Holo
//
//  检查项实体类
//

import Foundation
import CoreData

@objc(CheckItem)
class CheckItem: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CheckItem> {
        NSFetchRequest<CheckItem>(entityName: "CheckItem")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var isChecked: Bool
    @NSManaged var order: Int16
    @NSManaged var createdAt: Date

    // MARK: - Relationships

    @NSManaged var task: TodoTask?
}
