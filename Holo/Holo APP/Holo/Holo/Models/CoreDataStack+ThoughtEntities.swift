//
//  CoreDataStack+ThoughtEntities.swift
//  Holo
//
//  观点相关 Core Data 实体定义
//

import CoreData

extension CoreDataStack {

    // MARK: - Thought Entities

    /// 创建观点相关实体（Thought, ThoughtTag, ThoughtReference, ThoughtTagAssignment, Topic）
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
        thoughtId.defaultValue = UUID()
        thoughtId.isIndexed = true
        thoughtAttributes.append(thoughtId)

        let thoughtContent = NSAttributeDescription()
        thoughtContent.name = "content"
        thoughtContent.attributeType = .stringAttributeType
        thoughtContent.isOptional = false
        thoughtContent.defaultValue = ""
        thoughtAttributes.append(thoughtContent)

        let thoughtCreatedAt = NSAttributeDescription()
        thoughtCreatedAt.name = "createdAt"
        thoughtCreatedAt.attributeType = .dateAttributeType
        thoughtCreatedAt.isOptional = false
        thoughtCreatedAt.defaultValue = Date()
        thoughtAttributes.append(thoughtCreatedAt)

        let thoughtUpdatedAt = NSAttributeDescription()
        thoughtUpdatedAt.name = "updatedAt"
        thoughtUpdatedAt.attributeType = .dateAttributeType
        thoughtUpdatedAt.isOptional = false
        thoughtUpdatedAt.defaultValue = Date()
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

        // AI 自动整理状态
        let thoughtOrganizedStatus = NSAttributeDescription()
        thoughtOrganizedStatus.name = "organizedStatus"
        thoughtOrganizedStatus.attributeType = .stringAttributeType
        thoughtOrganizedStatus.isOptional = false
        thoughtOrganizedStatus.defaultValue = "unprocessed"
        thoughtAttributes.append(thoughtOrganizedStatus)

        // 创建该想法的设备 ID
        let thoughtCreatedDeviceId = NSAttributeDescription()
        thoughtCreatedDeviceId.name = "createdDeviceId"
        thoughtCreatedDeviceId.attributeType = .stringAttributeType
        thoughtCreatedDeviceId.isOptional = true
        thoughtAttributes.append(thoughtCreatedDeviceId)

        // AI 整理开始时间（processing 超时恢复）
        let thoughtOrganizationStartedAt = NSAttributeDescription()
        thoughtOrganizationStartedAt.name = "organizationStartedAt"
        thoughtOrganizationStartedAt.attributeType = .dateAttributeType
        thoughtOrganizationStartedAt.isOptional = true
        thoughtAttributes.append(thoughtOrganizationStartedAt)

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
        thoughtTagId.defaultValue = UUID()
        thoughtTagId.isIndexed = true
        thoughtTagAttributes.append(thoughtTagId)

        let thoughtTagName = NSAttributeDescription()
        thoughtTagName.name = "name"
        thoughtTagName.attributeType = .stringAttributeType
        thoughtTagName.isOptional = false
        thoughtTagName.defaultValue = ""
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
        thoughtReferenceId.defaultValue = UUID()
        thoughtReferenceId.isIndexed = true
        thoughtReferenceAttributes.append(thoughtReferenceId)

        let thoughtReferenceCreatedAt = NSAttributeDescription()
        thoughtReferenceCreatedAt.name = "createdAt"
        thoughtReferenceCreatedAt.attributeType = .dateAttributeType
        thoughtReferenceCreatedAt.isOptional = false
        thoughtReferenceCreatedAt.defaultValue = Date()
        thoughtReferenceAttributes.append(thoughtReferenceCreatedAt)

        // MARK: - ThoughtTagAssignment Entity
        // AI 自动整理 - 标签分配中间实体
        let assignmentEntity = NSEntityDescription()
        assignmentEntity.name = "ThoughtTagAssignment"
        assignmentEntity.managedObjectClassName = "ThoughtTagAssignment"

        var assignmentAttributes: [NSAttributeDescription] = []

        let assignmentId = NSAttributeDescription()
        assignmentId.name = "id"
        assignmentId.attributeType = .UUIDAttributeType
        assignmentId.isOptional = false
        assignmentId.defaultValue = UUID()
        assignmentId.isIndexed = true
        assignmentAttributes.append(assignmentId)

        let assignmentSource = NSAttributeDescription()
        assignmentSource.name = "source"
        assignmentSource.attributeType = .stringAttributeType
        assignmentSource.isOptional = false
        assignmentSource.defaultValue = "ai"
        assignmentAttributes.append(assignmentSource)

        let assignmentConfidence = NSAttributeDescription()
        assignmentConfidence.name = "confidence"
        assignmentConfidence.attributeType = .doubleAttributeType
        assignmentConfidence.isOptional = false
        assignmentConfidence.defaultValue = 1.0
        assignmentAttributes.append(assignmentConfidence)

        let assignmentAssignedAt = NSAttributeDescription()
        assignmentAssignedAt.name = "assignedAt"
        assignmentAssignedAt.attributeType = .dateAttributeType
        assignmentAssignedAt.isOptional = false
        assignmentAssignedAt.defaultValue = Date()
        assignmentAttributes.append(assignmentAssignedAt)

        let assignmentRejectedAt = NSAttributeDescription()
        assignmentRejectedAt.name = "rejectedAt"
        assignmentRejectedAt.attributeType = .dateAttributeType
        assignmentRejectedAt.isOptional = true
        assignmentAttributes.append(assignmentRejectedAt)

        // MARK: - Topic Entity
        // AI 自动整理 - 主题实体
        let topicEntity = NSEntityDescription()
        topicEntity.name = "Topic"
        topicEntity.managedObjectClassName = "Topic"

        var topicAttributes: [NSAttributeDescription] = []

        let topicId = NSAttributeDescription()
        topicId.name = "id"
        topicId.attributeType = .UUIDAttributeType
        topicId.isOptional = false
        topicId.defaultValue = UUID()
        topicId.isIndexed = true
        topicAttributes.append(topicId)

        let topicTitle = NSAttributeDescription()
        topicTitle.name = "title"
        topicTitle.attributeType = .stringAttributeType
        topicTitle.isOptional = false
        topicTitle.defaultValue = ""
        topicAttributes.append(topicTitle)

        let topicSummary = NSAttributeDescription()
        topicSummary.name = "summary"
        topicSummary.attributeType = .stringAttributeType
        topicSummary.isOptional = true
        topicAttributes.append(topicSummary)

        let topicStatus = NSAttributeDescription()
        topicStatus.name = "status"
        topicStatus.attributeType = .stringAttributeType
        topicStatus.isOptional = false
        topicStatus.defaultValue = "candidate"
        topicAttributes.append(topicStatus)

        let topicConfidence = NSAttributeDescription()
        topicConfidence.name = "confidence"
        topicConfidence.attributeType = .doubleAttributeType
        topicConfidence.isOptional = false
        topicConfidence.defaultValue = 0.0
        topicAttributes.append(topicConfidence)

        let topicAssociatedTagNames = NSAttributeDescription()
        topicAssociatedTagNames.name = "associatedTagNames"
        topicAssociatedTagNames.attributeType = .stringAttributeType
        topicAssociatedTagNames.isOptional = true
        topicAttributes.append(topicAssociatedTagNames)

        let topicThoughtCount = NSAttributeDescription()
        topicThoughtCount.name = "thoughtCount"
        topicThoughtCount.attributeType = .integer16AttributeType
        topicThoughtCount.isOptional = false
        topicThoughtCount.defaultValue = 0
        topicAttributes.append(topicThoughtCount)

        let topicCreatedAt = NSAttributeDescription()
        topicCreatedAt.name = "createdAt"
        topicCreatedAt.attributeType = .dateAttributeType
        topicCreatedAt.isOptional = false
        topicCreatedAt.defaultValue = Date()
        topicAttributes.append(topicCreatedAt)

        let topicUpdatedAt = NSAttributeDescription()
        topicUpdatedAt.name = "updatedAt"
        topicUpdatedAt.attributeType = .dateAttributeType
        topicUpdatedAt.isOptional = false
        topicUpdatedAt.defaultValue = Date()
        topicAttributes.append(topicUpdatedAt)

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
        referenceSourceRelation.minCount = 0
        referenceSourceRelation.maxCount = 1
        referenceSourceRelation.deleteRule = .nullifyDeleteRule
        referenceSourceRelation.isOptional = true

        // ThoughtReference → Thought（被引用方）
        let referenceTargetRelation = NSRelationshipDescription()
        referenceTargetRelation.name = "targetThought"
        referenceTargetRelation.destinationEntity = thoughtEntity
        referenceTargetRelation.minCount = 0
        referenceTargetRelation.maxCount = 1
        referenceTargetRelation.deleteRule = .nullifyDeleteRule
        referenceTargetRelation.isOptional = true

        // 设置双向关系
        thoughtReferencesRelation.inverseRelationship = referenceSourceRelation
        referenceSourceRelation.inverseRelationship = thoughtReferencesRelation

        thoughtReferencedByRelation.inverseRelationship = referenceTargetRelation
        referenceTargetRelation.inverseRelationship = thoughtReferencedByRelation

        // Thought → ThoughtTagAssignment（一对多，cascade）
        let thoughtAssignmentsRelation = NSRelationshipDescription()
        thoughtAssignmentsRelation.name = "tagAssignments"
        thoughtAssignmentsRelation.destinationEntity = assignmentEntity
        thoughtAssignmentsRelation.minCount = 0
        thoughtAssignmentsRelation.maxCount = 0
        thoughtAssignmentsRelation.deleteRule = .cascadeDeleteRule
        thoughtAssignmentsRelation.isOptional = true

        let assignmentThoughtRelation = NSRelationshipDescription()
        assignmentThoughtRelation.name = "thought"
        assignmentThoughtRelation.destinationEntity = thoughtEntity
        assignmentThoughtRelation.minCount = 0
        assignmentThoughtRelation.maxCount = 1
        assignmentThoughtRelation.deleteRule = .nullifyDeleteRule
        assignmentThoughtRelation.isOptional = true

        thoughtAssignmentsRelation.inverseRelationship = assignmentThoughtRelation
        assignmentThoughtRelation.inverseRelationship = thoughtAssignmentsRelation

        // Thought ↔ Topic（多对多，nullify）
        let thoughtTopicsRelation = NSRelationshipDescription()
        thoughtTopicsRelation.name = "topics"
        thoughtTopicsRelation.destinationEntity = topicEntity
        thoughtTopicsRelation.minCount = 0
        thoughtTopicsRelation.maxCount = 0
        thoughtTopicsRelation.deleteRule = .nullifyDeleteRule
        thoughtTopicsRelation.isOptional = true

        let topicThoughtsRelation = NSRelationshipDescription()
        topicThoughtsRelation.name = "thoughts"
        topicThoughtsRelation.destinationEntity = thoughtEntity
        topicThoughtsRelation.minCount = 0
        topicThoughtsRelation.maxCount = 0
        topicThoughtsRelation.deleteRule = .nullifyDeleteRule
        topicThoughtsRelation.isOptional = true

        thoughtTopicsRelation.inverseRelationship = topicThoughtsRelation
        topicThoughtsRelation.inverseRelationship = thoughtTopicsRelation

        // ThoughtTag → ThoughtTagAssignment（一对多，cascade）
        let tagAssignmentsRelation = NSRelationshipDescription()
        tagAssignmentsRelation.name = "assignments"
        tagAssignmentsRelation.destinationEntity = assignmentEntity
        tagAssignmentsRelation.minCount = 0
        tagAssignmentsRelation.maxCount = 0
        tagAssignmentsRelation.deleteRule = .cascadeDeleteRule
        tagAssignmentsRelation.isOptional = true

        let assignmentTagRelation = NSRelationshipDescription()
        assignmentTagRelation.name = "tag"
        assignmentTagRelation.destinationEntity = thoughtTagEntity
        assignmentTagRelation.minCount = 0
        assignmentTagRelation.maxCount = 1
        assignmentTagRelation.deleteRule = .nullifyDeleteRule
        assignmentTagRelation.isOptional = true

        tagAssignmentsRelation.inverseRelationship = assignmentTagRelation
        assignmentTagRelation.inverseRelationship = tagAssignmentsRelation

        // ThoughtTag ↔ Topic（多对多，nullify）
        let tagAssociatedTopicsRelation = NSRelationshipDescription()
        tagAssociatedTopicsRelation.name = "associatedTopics"
        tagAssociatedTopicsRelation.destinationEntity = topicEntity
        tagAssociatedTopicsRelation.minCount = 0
        tagAssociatedTopicsRelation.maxCount = 0
        tagAssociatedTopicsRelation.deleteRule = .nullifyDeleteRule
        tagAssociatedTopicsRelation.isOptional = true

        let topicAssociatedTagsRelation = NSRelationshipDescription()
        topicAssociatedTagsRelation.name = "associatedTags"
        topicAssociatedTagsRelation.destinationEntity = thoughtTagEntity
        topicAssociatedTagsRelation.minCount = 0
        topicAssociatedTagsRelation.maxCount = 0
        topicAssociatedTagsRelation.deleteRule = .nullifyDeleteRule
        topicAssociatedTagsRelation.isOptional = true

        tagAssociatedTopicsRelation.inverseRelationship = topicAssociatedTagsRelation
        topicAssociatedTagsRelation.inverseRelationship = tagAssociatedTopicsRelation

        // Topic 自引用：mergedToTopic（多对一）/ mergedFromTopics（一对多）
        let topicMergedToRelation = NSRelationshipDescription()
        topicMergedToRelation.name = "mergedToTopic"
        topicMergedToRelation.destinationEntity = topicEntity
        topicMergedToRelation.minCount = 0
        topicMergedToRelation.maxCount = 1
        topicMergedToRelation.deleteRule = .nullifyDeleteRule
        topicMergedToRelation.isOptional = true

        let topicMergedFromRelation = NSRelationshipDescription()
        topicMergedFromRelation.name = "mergedFromTopics"
        topicMergedFromRelation.destinationEntity = topicEntity
        topicMergedFromRelation.minCount = 0
        topicMergedFromRelation.maxCount = 0
        topicMergedFromRelation.deleteRule = .nullifyDeleteRule
        topicMergedFromRelation.isOptional = true

        topicMergedToRelation.inverseRelationship = topicMergedFromRelation
        topicMergedFromRelation.inverseRelationship = topicMergedToRelation

        // 将属性和关系添加到实体
        thoughtEntity.properties = thoughtAttributes + [
            thoughtTagsRelation,
            thoughtReferencesRelation,
            thoughtReferencedByRelation,
            thoughtAssignmentsRelation,
            thoughtTopicsRelation
        ]
        thoughtTagEntity.properties = thoughtTagAttributes + [
            tagThoughtsRelation,
            tagAssignmentsRelation,
            tagAssociatedTopicsRelation
        ]
        thoughtReferenceEntity.properties = thoughtReferenceAttributes + [
            referenceSourceRelation,
            referenceTargetRelation
        ]
        assignmentEntity.properties = assignmentAttributes + [
            assignmentThoughtRelation,
            assignmentTagRelation
        ]
        topicEntity.properties = topicAttributes + [
            topicThoughtsRelation,
            topicAssociatedTagsRelation,
            topicMergedToRelation,
            topicMergedFromRelation
        ]

        return [thoughtEntity, thoughtTagEntity, thoughtReferenceEntity, assignmentEntity, topicEntity]
    }

}
