//
//  HoloMatterOpenLoop+CoreDataClass.swift
//  Holo
//
//  Open Loop「还没解决的问题」
//
//  Open Loop 表示"问题还存在"，Task 表示"采取什么动作"；二者可关联（linkedTaskID）但不能互相替代。
//  epistemic 区分 confirmed（用户确认）与 suggested（AI 猜测）；AI 落库永远是 suggested。
//

import Foundation
import CoreData

@objc(HoloMatterOpenLoop)
final class HoloMatterOpenLoop: NSManagedObject, Identifiable {

    @NSManaged var id: UUID
    /// 逻辑外键（不建 Core Data relationship，方案 ADR-02）。
    @NSManaged var matterID: UUID
    /// 同一 Matter 内幂等去重键。
    @NSManaged var logicalKey: String
    @NSManaged var title: String
    @NSManaged var epistemicRaw: String
    @NSManaged var stateRaw: String
    @NSManaged var priorityRaw: String
    @NSManaged var targetDate: Date?
    /// 可选关联的真实任务；与 Task 不互相替代。
    @NSManaged var linkedTaskID: UUID?
    @NSManaged var sourceTypeRaw: String?
    @NSManaged var sourceEntityID: String?
    @NSManaged var sourceRevision: Int64
    @NSManaged var resolvedAt: Date?
    @NSManaged var revision: Int64
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?

    // MARK: - 类型化访问

    var epistemic: HoloMatterOpenLoopEpistemic {
        get { decodeMatterEnum(HoloMatterOpenLoopEpistemic.self, from: epistemicRaw, fallback: .suggested) }
        set { epistemicRaw = newValue.rawValue }
    }

    var state: HoloMatterOpenLoopState {
        get { decodeMatterEnum(HoloMatterOpenLoopState.self, from: stateRaw, fallback: .open) }
        set {
            stateRaw = newValue.rawValue
            resolvedAt = (newValue == .resolved) ? (resolvedAt ?? Date()) : nil
        }
    }

    var priority: HoloMatterOpenLoopPriority {
        get { decodeMatterEnum(HoloMatterOpenLoopPriority.self, from: priorityRaw, fallback: .normal) }
        set { priorityRaw = newValue.rawValue }
    }

    var isActive: Bool {
        (state == .open || state == .waiting) && deletedAt == nil
    }
}
