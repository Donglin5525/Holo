//
//  RepeatRule+CoreDataClass.swift
//  Holo
//
//  重复规则实体类
//

import Foundation
import CoreData

@objc(RepeatRule)
class RepeatRule: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<RepeatRule> {
        NSFetchRequest<RepeatRule>(entityName: "RepeatRule")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var type: String
    @NSManaged var weekdays: String?
    @NSManaged var monthDay: Int16
    @NSManaged var monthWeekOrdinal: Int16
    @NSManaged var monthWeekday: String?
    @NSManaged var untilCount: Int16
    @NSManaged var untilDate: Date?
    @NSManaged var skipHolidays: Bool
    @NSManaged var skipWeekends: Bool
    @NSManaged var createdAt: Date

    // MARK: - Relationships

    @NSManaged var task: TodoTask?
}
