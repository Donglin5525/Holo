//
//  Anniversary+CoreDataClass.swift
//  Holo
//
//  纪念日实体类
//

import Foundation
import CoreData

@objc(Anniversary)
class Anniversary: NSManagedObject, Identifiable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Anniversary> {
        NSFetchRequest<Anniversary>(entityName: "Anniversary")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var date: Date
    @NSManaged var type: String           // AnniversaryType.rawValue
    @NSManaged var icon: String            // SF Symbol 名
    @NSManaged var color: String           // hex，主题色
    @NSManaged var note: String?
    @NSManaged var isPinned: Bool
    @NSManaged var isArchived: Bool
    @NSManaged var isSoftDeleted: Bool
    @NSManaged var sortOrder: Int16

    // MARK: - 重复与提醒

    @NSManaged var repeatYearly: Bool      // 是否每年重复
    @NSManaged var isLunar: Bool           // 重复按农历推算（如农历生日）
    @NSManaged var reminderEnabled: Bool   // 是否开启提醒
    @NSManaged var reminderDaysBefore: Int16  // 提前几天（0=当天）
    @NSManaged var generateTask: Bool      // 是否自动生成任务

    // MARK: - Metadata

    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
}
