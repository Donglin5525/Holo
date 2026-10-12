//
//  CheckItem+CoreDataClass.swift
//  Holo
//
//  子任务实体类
//

import Foundation
import CoreData

@objc(CheckItem)
class CheckItem: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CheckItem> {
        NSFetchRequest<CheckItem>(entityName: "CheckItem")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var isChecked: Bool
    @NSManaged var order: Int16
    @NSManaged var createdAt: Date
    // 等待态（2026-10-11 拆开瘦身）
    @NSManaged var isWaiting: Bool
    @NSManaged var waitNote: String?
    @NSManaged var reviewRemindAt: Date?
    @NSManaged var waitHintsJSON: String?

    // MARK: - Relationships

    @NSManaged var task: TodoTask?
}
