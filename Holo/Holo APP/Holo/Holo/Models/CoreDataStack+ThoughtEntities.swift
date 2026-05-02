//
//  CoreDataStack+ThoughtEntities.swift
//  Holo
//
//  观点相关 Core Data 实体定义
//

import CoreData

extension CoreDataStack {

    // MARK: - Thought Entities

    /// 创建观点相关实体（Thought, ThoughtTag, ThoughtReference）
    nonisolated func createThoughtEntities() -> [NSEntityDescription] {
        // MARK: - Thought Entity
        // 观点模块 - 想法实体
        let thoughtEntity = NSEntityDescription()
        thoughtEntity.name = "Thought"
        thoughtEntity.managedObjectClassName = "Thought"

        var thoughtAttributes: [NSAttributeDescription] = []

        let thoughtId = NSAttributeDescription()
        thoughtId.name = "id"
        thoughtId.attributeType = .UUIDAttributeType
        thoughtId.isOptional = false
        thoughtId.isIndexed = true
        thoughtAttributes.append(thoughtId)

        let thoughtContent = NSAttributeDescription()
        thoughtContent.name = "content"
        thoughtContent.attributeType = .stringAttributeType
        thoughtContent.isOptional = false
        thoughtAttributes.append(thoughtContent)

        let thoughtCreatedAt = NSAttributeDescription()
        thoughtCreatedAt.name = "createdAt"
        thoughtCreatedAt.attributeType = .dateAttributeType
        thoughtCreatedAt.isOptional = false
        thoughtAttributes.append(thoughtCreatedAt)

        let thoughtUpdatedAt = NSAttributeDescription()
        thoughtUpdatedAt.name = "updatedAt"
        thoughtUpdatedAt.attributeType = .dateAttributeType
        thoughtUpdatedAt.isOptional = false
        thoughtAttributes.append(thoughtUpdatedAt)

        let thoughtMood = NSAttributeDescription()
        thoughtMood.name = "mood"
        thoughtMood.attributeType = .stringAttributeType
        thoughtMood.isOptional = true
        thoughtAttributes.append(thoughtMood)

        let thoughtOrderIndex = NSAttributeDescription()
        thoughtOrderIndex.name = "orderIndex"
        thoughtOrderIndex.attributeType = .integer16AttributeType
        thoughtOrderIndex.isOptional = false
        thoughtOrderIndex.defaultValue = 0
        thoughtAttributes.append(thoughtOrderIndex)

        let thoughtImageData = NSAttributeDescription()
        thoughtImageData.name = "imageData"
        thoughtImageData.attributeType = .binaryDataAttributeType
        thoughtImageData.isOptional = true
        thoughtAttributes.append(thoughtImageData)

        let thoughtIsSoftDeleted = NSAttributeDescription()
        thoughtIsSoftDeleted.name = "isSoftDeleted"
        thoughtIsSoftDeleted.attributeType = .booleanAttributeType
        thoughtIsSoftDeleted.isOptional = false
        thoughtIsSoftDeleted.defaultValue = false
        thoughtAttributes.append(thoughtIsSoftDeleted)

        let thoughtIsArchived = NSAttributeDescription()
        thoughtIsArchived.name = "isArchived"
        thoughtIsArchived.attributeType = .booleanAttributeType
        thoughtIsArchived.isOptional = false
        thoughtIsArchived.defaultValue = false
        thoughtAttributes.append(thoughtIsArchived)

        // MARK: - ThoughtTag Entity
        // 观点模块 - 标签实体
        let thoughtTagEntity = NSEntityDescription()
        thoughtTagEntity.name = "ThoughtTag"
        thoughtTagEntity.managedObjectClassName = "ThoughtTag"

        var thoughtTagAttributes: [NSAttributeDescription] = []

        let thoughtTagId = NSAttributeDescription()
        thoughtTagId.name = "id"
        thoughtTagId.attributeType = .UUIDAttributeType
        thoughtTagId.isOptional = false
        thoughtTagId.isIndexed = true
        thoughtTagAttributes.append(thoughtTagId)

        let thoughtTagName = NSAttributeDescription()
        thoughtTagName.name = "name"
        thoughtTagName.attributeType = .stringAttributeType
        thoughtTagName.isOptional = false
        thoughtTagAttributes.append(thoughtTagName)

        let thoughtTagColor = NSAttributeDescription()
        thoughtTagColor.name = "color"
        thoughtTagColor.attributeType = .stringAttributeType
        thoughtTagColor.isOptional = true
        thoughtTagAttributes.append(thoughtTagColor)

        let thoughtTagUsageCount = NSAttributeDescription()
        thoughtTagUsageCount.name = "usageCount"
        thoughtTagUsageCount.attributeType = .integer16AttributeType
        thoughtTagUsageCount.isOptional = false
        thoughtTagUsageCount.defaultValue = 0
        thoughtTagAttributes.append(thoughtTagUsageCount)

        // MARK: - ThoughtReference Entity
        // 观点模块 - 引用关系实体
        let thoughtReferenceEntity = NSEntityDescription()
        thoughtReferenceEntity.name = "ThoughtReference"
        thoughtReferenceEntity.managedObjectClassName = "ThoughtReference"

        var thoughtReferenceAttributes: [NSAttributeDescription] = []

        let thoughtReferenceId = NSAttributeDescription()
        thoughtReferenceId.name = "id"
        thoughtReferenceId.attributeType = .UUIDAttributeType
        thoughtReferenceId.isOptional = false
        thoughtReferenceId.isIndexed = true
        thoughtReferenceAttributes.append(thoughtReferenceId)

        let thoughtReferenceCreatedAt = NSAttributeDescription()
        thoughtReferenceCreatedAt.name = "createdAt"
        thoughtReferenceCreatedAt.attributeType = .dateAttributeType
        thoughtReferenceCreatedAt.isOptional = false
        thoughtReferenceAttributes.append(thoughtReferenceCreatedAt)

        // MARK: - Thought Relationships

        // Thought ↔ ThoughtTag（多对多）
        let thoughtTagsRelation = NSRelationshipDescription()
        thoughtTagsRelation.name = "tags"
        thoughtTagsRelation.destinationEntity = thoughtTagEntity
        thoughtTagsRelation.minCount = 0
        thoughtTagsRelation.maxCount = 0
        thoughtTagsRelation.deleteRule = .nullifyDeleteRule
        thoughtTagsRelation.isOptional = true

        let tagThoughtsRelation = NSRelationshipDescription()
        tagThoughtsRelation.name = "thoughts"
        tagThoughtsRelation.destinationEntity = thoughtEntity
        tagThoughtsRelation.minCount = 0
        tagThoughtsRelation.maxCount = 0
        tagThoughtsRelation.deleteRule = .nullifyDeleteRule
        tagThoughtsRelation.isOptional = true

        thoughtTagsRelation.inverseRelationship = tagThoughtsRelation
        tagThoughtsRelation.inverseRelationship = thoughtTagsRelation

        // Thought → ThoughtReference（正向引用：该想法引用了哪些其他想法）
        let thoughtReferencesRelation = NSRelationshipDescription()
        thoughtReferencesRelation.name = "references"
        thoughtReferencesRelation.destinationEntity = thoughtReferenceEntity
        thoughtReferencesRelation.minCount = 0
        thoughtReferencesRelation.maxCount = 0
        thoughtReferencesRelation.deleteRule = .cascadeDeleteRule
        thoughtReferencesRelation.isOptional = true

        // Thought → ThoughtReference（反向引用：该想法被哪些其他想法引用）
        let thoughtReferencedByRelation = NSRelationshipDescription()
        thoughtReferencedByRelation.name = "referencedBy"
        thoughtReferencedByRelation.destinationEntity = thoughtReferenceEntity
        thoughtReferencedByRelation.minCount = 0
        thoughtReferencedByRelation.maxCount = 0
        thoughtReferencedByRelation.deleteRule = .cascadeDeleteRule
        thoughtReferencedByRelation.isOptional = true

        // ThoughtReference → Thought（引用发起方）
        let referenceSourceRelation = NSRelationshipDescription()
        referenceSourceRelation.name = "sourceThought"
        referenceSourceRelation.destinationEntity = thoughtEntity
        referenceSourceRelation.minCount = 1
        referenceSourceRelation.maxCount = 1
        referenceSourceRelation.deleteRule = .nullifyDeleteRule
        referenceSourceRelation.isOptional = false

        // ThoughtReference → Thought（被引用方）
        let referenceTargetRelation = NSRelationshipDescription()
        referenceTargetRelation.name = "targetThought"
        referenceTargetRelation.destinationEntity = thoughtEntity
        referenceTargetRelation.minCount = 1
        referenceTargetRelation.maxCount = 1
        referenceTargetRelation.deleteRule = .nullifyDeleteRule
        referenceTargetRelation.isOptional = false

        // 设置双向关系
        thoughtReferencesRelation.inverseRelationship = referenceSourceRelation
        referenceSourceRelation.inverseRelationship = thoughtReferencesRelation

        thoughtReferencedByRelation.inverseRelationship = referenceTargetRelation
        referenceTargetRelation.inverseRelationship = thoughtReferencedByRelation

        // 将属性和关系添加到实体
        thoughtEntity.properties = thoughtAttributes + [thoughtTagsRelation, thoughtReferencesRelation, thoughtReferencedByRelation]
        thoughtTagEntity.properties = thoughtTagAttributes + [tagThoughtsRelation]
        thoughtReferenceEntity.properties = thoughtReferenceAttributes + [referenceSourceRelation, referenceTargetRelation]

        return [thoughtEntity, thoughtTagEntity, thoughtReferenceEntity]
    }

}
