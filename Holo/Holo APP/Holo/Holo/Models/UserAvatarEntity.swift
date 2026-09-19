//
//  UserAvatarEntity.swift
//  Holo
//
//  用户头像实体：保存处理后的单份方形头像，并随用户私有 iCloud 同步。
//

import Foundation
import CoreData

@objc(UserAvatarEntity)
public final class UserAvatarEntity: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<UserAvatarEntity> {
        NSFetchRequest<UserAvatarEntity>(entityName: "UserAvatarEntity")
    }

    @NSManaged public var profileKey: String
    @NSManaged public var state: String
    @NSManaged public var avatarData: Data?
    @NSManaged public var revision: Int64
    @NSManaged public var updatedAt: Date
    @NSManaged public var mutationID: String
}
