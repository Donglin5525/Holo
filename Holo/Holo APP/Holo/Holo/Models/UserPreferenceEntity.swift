//
//  UserPreferenceEntity.swift
//  Holo
//
//  用户级偏好设置实体类（键值对，跟随 iCloud 同步）
//

import Foundation
import CoreData

/// 用户级偏好设置
/// 键值对形式，随 CloudKit 私有库同步；卸载重装后随 iCloud 恢复
@objc(UserPreferenceEntity)
public class UserPreferenceEntity: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<UserPreferenceEntity> {
        return NSFetchRequest<UserPreferenceEntity>(entityName: "UserPreferenceEntity")
    }

    @NSManaged public var key: String

    @NSManaged public var value: String

    @NSManaged public var updatedAt: Date
}
