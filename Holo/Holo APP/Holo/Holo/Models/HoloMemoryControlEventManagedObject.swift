//
//  HoloMemoryControlEventManagedObject.swift
//  Holo
//
//  用户控制事件的 Core Data 持久化对象（实体定义见 CoreDataStack+HoloMemoryEntities）
//

import CoreData
import Foundation

@objc(HoloMemoryControlEventMO)
final class HoloMemoryControlEventMO: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var targetRecordID: String
    @NSManaged var kind: String
    /// 前序控制事件 ID 集合，JSON 编码（CloudKit 不支持原生数组属性）。
    @NSManaged var priorEventIDsJSON: String
    @NSManaged var basedOnContentVersion: Int64
    @NSManaged var resultingContentVersion: Int64
    @NSManaged var occurredAt: Date
    @NSManaged var operationID: String
    @NSManaged var payloadDigest: String?
    /// 记录状态已体现该控制的完成时刻；nil = 待重放（崩溃恢复输入）。
    @NSManaged var appliedAt: Date?
    @NSManaged var schemaVersion: Int64
}
