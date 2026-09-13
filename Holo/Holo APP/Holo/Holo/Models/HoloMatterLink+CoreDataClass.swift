//
//  HoloMatterLink+CoreDataClass.swift
//  Holo
//
//  Matter 与外部内容的类型化链接（ID 逻辑外键，不建跨域 relationship）
//
//  Matter 不拥有 Task/Thought/Transaction 等业务对象，只保存关系；移除关系不删除原对象。
//  entityType 白名单见 HoloMatterLinkEntityType.writable。
//

import Foundation
import CoreData

@objc(HoloMatterLink)
final class HoloMatterLink: NSManagedObject, Identifiable {

    @NSManaged var id: UUID
    @NSManaged var matterID: UUID
    @NSManaged var entityTypeRaw: String
    @NSManaged var entityID: String
    @NSManaged var roleRaw: String
    @NSManaged var originRaw: String
    /// 诊断用；不能代替权限策略。
    @NSManaged var confidence: Double
    @NSManaged var statusRaw: String
    @NSManaged var sourceRevision: String?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?

    // MARK: - 类型化访问

    var entityType: HoloMatterLinkEntityType? {
        get { HoloMatterLinkEntityType(rawValue: entityTypeRaw) }
        set { entityTypeRaw = newValue?.rawValue ?? "" }
    }

    var role: HoloMatterLinkRole {
        get { decodeMatterEnum(HoloMatterLinkRole.self, from: roleRaw, fallback: .resource) }
        set { roleRaw = newValue.rawValue }
    }

    var origin: HoloMatterLinkOrigin {
        get { decodeMatterEnum(HoloMatterLinkOrigin.self, from: originRaw, fallback: .system) }
        set { originRaw = newValue.rawValue }
    }

    var status: HoloMatterLinkStatus {
        get { decodeMatterEnum(HoloMatterLinkStatus.self, from: statusRaw, fallback: .proposed) }
        set { statusRaw = newValue.rawValue }
    }

    var isLinked: Bool {
        status == .linked && deletedAt == nil
    }
}
