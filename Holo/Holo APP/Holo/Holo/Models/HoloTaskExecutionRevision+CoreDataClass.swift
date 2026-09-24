//
//  HoloTaskExecutionRevision+CoreDataClass.swift
//  Holo
//
//  已采纳的不可变计划版本（2026-09-25 实施规格 §7.2-B）
//  历史版本不覆盖：解释「为什么变了」与恢复的依据。
//

import Foundation
import CoreData

/// 计划来源（acceptedSourceRaw）
nonisolated enum HoloTaskExecutionPlanSource: String {
    case userAcceptedAI
    case manual
    case conflictResolution
}

@objc(HoloTaskExecutionRevision)
final class HoloTaskExecutionRevision: NSManagedObject, Identifiable {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<HoloTaskExecutionRevision> {
        NSFetchRequest<HoloTaskExecutionRevision>(entityName: "HoloTaskExecutionRevision")
    }

    @NSManaged var id: UUID
    @NSManaged var taskID: UUID
    @NSManaged var originMatterID: UUID?
    @NSManaged var parentRevisionIDsJSON: String?
    @NSManaged var operationID: String
    @NSManaged var schemaVersion: Int16
    @NSManaged var sourceFingerprint: String
    @NSManaged var outcomeContractJSON: String?
    @NSManaged var topologyJSON: String?
    @NSManaged var acceptedSourceRaw: String
    @NSManaged var createdAt: Date
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?

    // MARK: - 类型化访问

    var acceptedSource: HoloTaskExecutionPlanSource {
        get { HoloTaskExecutionPlanSource(rawValue: acceptedSourceRaw) ?? .userAcceptedAI }
        set { acceptedSourceRaw = newValue.rawValue }
    }

    /// 父版本 ID 集合（正常一个；并发分叉解决版本可有多个）
    var parentRevisionIDs: [UUID] {
        get {
            guard let data = parentRevisionIDsJSON?.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
        }
        set {
            parentRevisionIDsJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? nil
        }
    }

    /// 结果契约（解码失败返回 nil，由调用方按 needsReview 处理，不崩溃）
    var outcomeContract: HoloTaskExecutionOutcomeContract? {
        get {
            guard let data = outcomeContractJSON?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(HoloTaskExecutionOutcomeContract.self, from: data)
        }
        set {
            outcomeContractJSON = newValue.flatMap { value in
                try? String(data: JSONEncoder().encode(value), encoding: .utf8)
            }
        }
    }

    /// 拓扑（节点 ID、分组、顺序、必要/可选、依赖、覆盖关系）
    var topology: HoloTaskExecutionTopology? {
        get {
            guard let data = topologyJSON?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(HoloTaskExecutionTopology.self, from: data)
        }
        set {
            topologyJSON = newValue.flatMap { value in
                try? String(data: JSONEncoder().encode(value), encoding: .utf8)
            }
        }
    }
}
