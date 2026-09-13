//
//  HoloMatter+CoreDataClass.swift
//  Holo
//
//  Matter「进行中的事」主实体
//
//  标题、日期、生命周期是用户事实的真相源；summary/attention/nextAction 是可重建投影（projectionJSON）。
//  revision 在每次 canonical mutation 时递增，是投影 stale 判定与并发控制的基石。
//

import Foundation
import CoreData

@objc(HoloMatter)
final class HoloMatter: NSManagedObject, Identifiable {

    @NSManaged var id: UUID
    @NSManaged var schemaVersion: Int16
    @NSManaged var title: String
    /// 开放展示标签（如「旅行」「搬家」），仅提示，不参与核心路由。
    @NSManaged var typeLabel: String?
    @NSManaged var lifecycleRaw: String
    @NSManaged var phaseRaw: String?
    @NSManaged var startDate: Date?
    /// 目标日期未知即 nil，禁止默认今天。
    @NSManaged var targetDate: Date?
    @NSManaged var completedAt: Date?
    @NSManaged var archivedAt: Date?
    @NSManaged var originRaw: String
    @NSManaged var originEntityID: String?
    @NSManaged var projectionJSON: String?
    @NSManaged var revision: Int64
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?

    // MARK: - 类型化访问

    var lifecycle: HoloMatterLifecycleStatus {
        get { decodeMatterEnum(HoloMatterLifecycleStatus.self, from: lifecycleRaw, fallback: .candidate) }
        set { lifecycleRaw = newValue.rawValue }
    }

    var phase: HoloMatterPhase? {
        get { phaseRaw.flatMap(HoloMatterPhase.init(rawValue:)) }
        set { phaseRaw = newValue?.rawValue }
    }

    var origin: HoloMatterOrigin {
        get { decodeMatterEnum(HoloMatterOrigin.self, from: originRaw, fallback: .manual) }
        set { originRaw = newValue.rawValue }
    }
}
