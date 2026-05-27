//
//  CoreDataStack+MemoryInsightFeedbackEntity.swift
//  Holo
//
//  洞察反馈实体定义
//

import CoreData

extension CoreDataStack {

    /// 创建洞察反馈实体
    nonisolated func createMemoryInsightFeedbackEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "MemoryInsightFeedback"
        entity.managedObjectClassName = "Holo.MemoryInsightFeedback"

        var attributes: [NSAttributeDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()
        id.isIndexed = true
        attributes.append(id)

        let insightId = NSAttributeDescription()
        insightId.name = "insightId"
        insightId.attributeType = .UUIDAttributeType
        insightId.isOptional = false
        insightId.defaultValue = UUID()
        insightId.isIndexed = true
        attributes.append(insightId)

        let cardId = NSAttributeDescription()
        cardId.name = "cardId"
        cardId.attributeType = .stringAttributeType
        cardId.isOptional = true
        attributes.append(cardId)

        let accuracyRating = NSAttributeDescription()
        accuracyRating.name = "accuracyRating"
        accuracyRating.attributeType = .stringAttributeType
        accuracyRating.isOptional = true
        attributes.append(accuracyRating)

        let valueRating = NSAttributeDescription()
        valueRating.name = "valueRating"
        valueRating.attributeType = .stringAttributeType
        valueRating.isOptional = true
        attributes.append(valueRating)

        let reasonType = NSAttributeDescription()
        reasonType.name = "reasonType"
        reasonType.attributeType = .stringAttributeType
        reasonType.isOptional = true
        attributes.append(reasonType)

        let module = NSAttributeDescription()
        module.name = "module"
        module.attributeType = .stringAttributeType
        module.isOptional = true
        attributes.append(module)

        let patternType = NSAttributeDescription()
        patternType.name = "patternType"
        patternType.attributeType = .stringAttributeType
        patternType.isOptional = true
        attributes.append(patternType)

        let userCorrection = NSAttributeDescription()
        userCorrection.name = "userCorrection"
        userCorrection.attributeType = .stringAttributeType
        userCorrection.isOptional = true
        attributes.append(userCorrection)

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false
        createdAt.defaultValue = Date()
        attributes.append(createdAt)

        let consumedAt = NSAttributeDescription()
        consumedAt.name = "consumedAt"
        consumedAt.attributeType = .dateAttributeType
        consumedAt.isOptional = true
        attributes.append(consumedAt)

        entity.properties = attributes
        return entity
    }
}
