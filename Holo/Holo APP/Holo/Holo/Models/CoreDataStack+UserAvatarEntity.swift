//
//  CoreDataStack+UserAvatarEntity.swift
//  Holo
//
//  用户头像程序化 Core Data 模型。
//

import CoreData

extension CoreDataStack {

    nonisolated func createUserAvatarEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "UserAvatarEntity"
        entity.managedObjectClassName = "UserAvatarEntity"

        let profileKey = NSAttributeDescription()
        profileKey.name = "profileKey"
        profileKey.attributeType = .stringAttributeType
        profileKey.isOptional = false
        profileKey.defaultValue = "primary"

        let state = NSAttributeDescription()
        state.name = "state"
        state.attributeType = .stringAttributeType
        state.isOptional = false
        // 模型文件同时供 HoloWidgets 编译，不依赖主 App 仓库层枚举。
        state.defaultValue = "unset"

        let avatarData = NSAttributeDescription()
        avatarData.name = "avatarData"
        avatarData.attributeType = .binaryDataAttributeType
        avatarData.isOptional = true
        avatarData.allowsExternalBinaryDataStorage = true

        let revision = NSAttributeDescription()
        revision.name = "revision"
        revision.attributeType = .integer64AttributeType
        revision.isOptional = false
        revision.defaultValue = 0

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        updatedAt.defaultValue = Date()

        let mutationID = NSAttributeDescription()
        mutationID.name = "mutationID"
        mutationID.attributeType = .stringAttributeType
        mutationID.isOptional = false
        mutationID.defaultValue = ""

        entity.properties = [profileKey, state, avatarData, revision, updatedAt, mutationID]
        CoreDataStack.applyIndexes(to: entity, on: ["profileKey": profileKey])
        return entity
    }
}
