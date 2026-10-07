//
//  HoloTaskExecutionReceipt+CoreDataClass.swift
//  Holo
//
//  命令回执与审计（2026-09-25 实施规格 §7.2-D）
//  用于幂等、解释和安全撤回；不充当另一份任务状态或任意正文日志。
//  最小化内容：禁止存模型原始对话、附件、隐私证件信息。
//

import Foundation
import CoreData

/// 命令参与者
nonisolated enum HoloTaskExecutionActor: String {
    case user
    case system
}

@objc(HoloTaskExecutionReceipt)
final class HoloTaskExecutionReceipt: NSManagedObject, Identifiable {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<HoloTaskExecutionReceipt> {
        NSFetchRequest<HoloTaskExecutionReceipt>(entityName: "HoloTaskExecutionReceipt")
    }

    @NSManaged var id: UUID
    @NSManaged var operationID: String
    @NSManaged var taskID: UUID
    @NSManaged var revisionID: UUID?
    @NSManaged var stepID: UUID?
    @NSManaged var commandRaw: String
    @NSManaged var actorRaw: String
    @NSManaged var sourceSurface: String
    @NSManaged var expectedStateVersion: NSNumber?
    @NSManaged var beforeStateJSON: String?
    @NSManaged var afterStateJSON: String?
    @NSManaged var outcomeAssertion: String?
    @NSManaged var revertsReceiptID: UUID?
    @NSManaged var createdAt: Date
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?

    // MARK: - 类型化访问

    var actor: HoloTaskExecutionActor {
        get { HoloTaskExecutionActor(rawValue: actorRaw) ?? .user }
        set { actorRaw = newValue.rawValue }
    }
}
