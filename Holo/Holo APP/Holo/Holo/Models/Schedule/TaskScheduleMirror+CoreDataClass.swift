//
//  TaskScheduleMirror+CoreDataClass.swift
//  Holo
//
//  任务↔日历镜像事件映射（经 CloudKit 同步，多设备一致性基础）
//

import Foundation
import CoreData

@objc(TaskScheduleMirror)
public final class TaskScheduleMirror: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var taskId: UUID
    /// EKEvent.eventIdentifier（加速索引，会漂移，认领最终依据是事件 url 埋的任务 ID）
    @NSManaged public var eventIdentifier: String?
    @NSManaged public var calendarIdentifier: String?
    @NSManaged public var lastSyncedStart: Date?
    @NSManaged public var lastSyncedEnd: Date?
    @NSManaged public var lastSyncedTitle: String?
    @NSManaged public var lastSyncedAt: Date
    /// 认领宽限判定基准；每轮认领成功即刷新
    @NSManaged public var lastConfirmedAt: Date
    /// active / disconnected
    @NSManaged public var state: String
    @NSManaged public var createdAt: Date
}

extension TaskScheduleMirror {
    var isActive: Bool { state == "active" }
}
