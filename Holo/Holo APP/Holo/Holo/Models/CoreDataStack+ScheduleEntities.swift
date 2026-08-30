//
//  CoreDataStack+ScheduleEntities.swift
//  Holo
//
//  任务↔日历事件映射实体（二期「写回去」）
//  经 CloudKit 同步：多设备共享同一份映射，写入前先查映射实现幂等（设计稿二期第一约束）
//

import CoreData

extension CoreDataStack {

    /// 创建日程同步相关实体
    static func createScheduleEntities() -> [NSEntityDescription] {
        [makeTaskScheduleMirrorEntity()]
    }

    /// 任务与「Holo」日历内镜像事件的映射
    private static func makeTaskScheduleMirrorEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "TaskScheduleMirror"
        entity.managedObjectClassName = "TaskScheduleMirror"

        var attributes: [NSAttributeDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()
        attributes.append(id)

        let taskId = NSAttributeDescription()
        taskId.name = "taskId"
        taskId.attributeType = .UUIDAttributeType
        taskId.isOptional = false
        attributes.append(taskId)

        // EKEvent.eventIdentifier：仅加速索引，iCloud 重排会漂移（认领最终依据是事件 url 埋的任务 ID）
        let eventIdentifier = NSAttributeDescription()
        eventIdentifier.name = "eventIdentifier"
        eventIdentifier.attributeType = .stringAttributeType
        eventIdentifier.isOptional = true
        attributes.append(eventIdentifier)

        // 事件所在日历（Holo 日历被删重建后换新日历时对账仍可认领）
        let calendarIdentifier = NSAttributeDescription()
        calendarIdentifier.name = "calendarIdentifier"
        calendarIdentifier.attributeType = .stringAttributeType
        calendarIdentifier.isOptional = true
        attributes.append(calendarIdentifier)

        // 三方对账基线：上次同步时双方的值，用于判定「哪边改了」
        let lastSyncedStart = NSAttributeDescription()
        lastSyncedStart.name = "lastSyncedStart"
        lastSyncedStart.attributeType = .dateAttributeType
        lastSyncedStart.isOptional = true
        attributes.append(lastSyncedStart)

        let lastSyncedEnd = NSAttributeDescription()
        lastSyncedEnd.name = "lastSyncedEnd"
        lastSyncedEnd.attributeType = .dateAttributeType
        lastSyncedEnd.isOptional = true
        attributes.append(lastSyncedEnd)

        let lastSyncedTitle = NSAttributeDescription()
        lastSyncedTitle.name = "lastSyncedTitle"
        lastSyncedTitle.attributeType = .stringAttributeType
        lastSyncedTitle.isOptional = true
        attributes.append(lastSyncedTitle)

        let lastSyncedAt = NSAttributeDescription()
        lastSyncedAt.name = "lastSyncedAt"
        lastSyncedAt.attributeType = .dateAttributeType
        lastSyncedAt.isOptional = false
        lastSyncedAt.defaultValue = Date()
        attributes.append(lastSyncedAt)

        // 认领宽限判定：超过宽限仍认领不到事件 → 断开（区分 iCloud 同步延迟与用户删事件）
        let lastConfirmedAt = NSAttributeDescription()
        lastConfirmedAt.name = "lastConfirmedAt"
        lastConfirmedAt.attributeType = .dateAttributeType
        lastConfirmedAt.isOptional = false
        lastConfirmedAt.defaultValue = Date()
        attributes.append(lastConfirmedAt)

        let state = NSAttributeDescription()
        state.name = "state"
        state.attributeType = .stringAttributeType
        state.isOptional = false
        state.defaultValue = "active"
        attributes.append(state)

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false
        createdAt.defaultValue = Date()
        attributes.append(createdAt)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: ["taskId": taskId, "state": state])
        return entity
    }
}
