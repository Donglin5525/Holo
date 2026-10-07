//
//  HoloTodayPlanRevision+CoreDataClass.swift
//  Holo
//
//  「今天减负」当日计划唯一实体（2026-10-03 实施方案 §7.3）
//
//  - 一次采用/手动调整/撤销 = 一条不可变完整版本；读取按 parent 关系找 head；
//  - 全部 ID 逻辑外键，无跨域 relationship（CloudKit 兼容）；
//  - 类型化访问器兜底未知 raw；payload 解析不在本层（Repository 负责）；
//  - 软删属性复用标准集，仅用于模块清空/恢复的生命周期元数据。
//

import Foundation
import CoreData

/// 零 UUID 仅作 schema 兼容默认值；读取端不得把它视为有效记录。
nonisolated enum HoloTodayPlanSchemaDefaults {
    nonisolated static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    nonisolated static let emptyJSON = "[]"
}

@objc(HoloTodayPlanRevision)
final class HoloTodayPlanRevision: NSManagedObject, Identifiable {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<HoloTodayPlanRevision> {
        NSFetchRequest<HoloTodayPlanRevision>(entityName: "HoloTodayPlanRevision")
    }

    @NSManaged var id: UUID
    @NSManaged var schemaVersion: Int16
    @NSManaged var scopeKey: String
    @NSManaged var dateKey: String
    @NSManaged var timeZoneIdentifier: String
    @NSManaged var dayStart: Date
    @NSManaged var dayEnd: Date
    /// 父版本 ID 数组（JSON）；首次采用为 []。
    @NSManaged var parentRevisionIDsJSON: String
    /// 本次命令幂等键（禁止由模型决定）。
    @NSManaged var operationID: String
    @NSManaged var commandRaw: String
    @NSManaged var payloadJSON: String
    @NSManaged var payloadDigest: String
    @NSManaged var createdAt: Date
    @NSManaged var restoredFromRevisionID: UUID?
    /// 空库首次创建的唯一根任务回执。
    @NSManaged var createdTaskID: UUID?
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?

    // MARK: - 类型化访问

    var command: HoloTodayPlanCommand? {
        HoloTodayPlanCommand(rawValue: commandRaw)
    }

    var parentRevisionIDs: [UUID] {
        guard let data = parentRevisionIDsJSON.data(using: .utf8),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
            return []
        }
        return ids
    }

    /// 零 UUID / 空标题视为无效记录占位（schema 默认值，不允许进入业务读取）。
    var isPlaceholder: Bool {
        id == HoloTodayPlanSchemaDefaults.zeroUUID || operationID.isEmpty
    }
}
