//
//  CoreDataStack+UserPreferenceEntity.swift
//  Holo
//
//  用户级偏好设置实体（键值对，跟随 iCloud 同步）
//  当前承载首页问候昵称：昵称原先只存本地 UserDefaults，卸载即丢，
//  iCloud 恢复时任务、记忆都能回来唯独名字回不来。
//

import CoreData

extension CoreDataStack {

    nonisolated func createUserPreferenceEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "UserPreferenceEntity"
        entity.managedObjectClassName = "UserPreferenceEntity"

        var attributes: [NSAttributeDescription] = []

        let key = NSAttributeDescription()
        key.name = "key"
        key.attributeType = .stringAttributeType
        key.isOptional = false
        key.defaultValue = ""
        attributes.append(key)

        let value = NSAttributeDescription()
        value.name = "value"
        value.attributeType = .stringAttributeType
        value.isOptional = false
        value.defaultValue = ""
        attributes.append(value)

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        updatedAt.defaultValue = Date()
        attributes.append(updatedAt)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: ["key": key])
        return entity
    }
}
