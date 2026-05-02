//
//  CoreDataStack+MemoryInsightEntity.swift
//  Holo
//
//  记忆洞察相关 Core Data 实体定义
//

import CoreData

extension CoreDataStack {

    // MARK: - MemoryInsight Entity

    /// 创建记忆洞察实体（AI 生成的周期级洞察结果）
    nonisolated func createMemoryInsightEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "MemoryInsight"
        entity.managedObjectClassName = "Holo.MemoryInsight"

        var attributes: [NSAttributeDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.isIndexed = true
        attributes.append(id)

        let periodType = NSAttributeDescription()
        periodType.name = "periodType"
        periodType.attributeType = .stringAttributeType
        periodType.isOptional = false
        periodType.isIndexed = true
        attributes.append(periodType)

        let periodStart = NSAttributeDescription()
        periodStart.name = "periodStart"
        periodStart.attributeType = .dateAttributeType
        periodStart.isOptional = false
        periodStart.isIndexed = true
        attributes.append(periodStart)

        let periodEnd = NSAttributeDescription()
        periodEnd.name = "periodEnd"
        periodEnd.attributeType = .dateAttributeType
        periodEnd.isOptional = false
        attributes.append(periodEnd)

        let title = NSAttributeDescription()
        title.name = "title"
        title.attributeType = .stringAttributeType
        title.isOptional = false
        title.defaultValue = ""
        attributes.append(title)

        let summary = NSAttributeDescription()
        summary.name = "summary"
        summary.attributeType = .stringAttributeType
        summary.isOptional = false
        summary.defaultValue = ""
        attributes.append(summary)

        let cardsJSON = NSAttributeDescription()
        cardsJSON.name = "cardsJSON"
        cardsJSON.attributeType = .stringAttributeType
        cardsJSON.isOptional = false
        cardsJSON.defaultValue = "[]"
        attributes.append(cardsJSON)

        let rawResponse = NSAttributeDescription()
        rawResponse.name = "rawResponse"
        rawResponse.attributeType = .stringAttributeType
        rawResponse.isOptional = true
        attributes.append(rawResponse)

        let sourceSnapshotHash = NSAttributeDescription()
        sourceSnapshotHash.name = "sourceSnapshotHash"
        sourceSnapshotHash.attributeType = .stringAttributeType
        sourceSnapshotHash.isOptional = false
        sourceSnapshotHash.defaultValue = ""
        attributes.append(sourceSnapshotHash)

        let generatedAt = NSAttributeDescription()
        generatedAt.name = "generatedAt"
        generatedAt.attributeType = .dateAttributeType
        generatedAt.isOptional = false
        attributes.append(generatedAt)

        let status = NSAttributeDescription()
        status.name = "status"
        status.attributeType = .stringAttributeType
        status.isOptional = false
        status.isIndexed = true
        status.defaultValue = "generating"
        attributes.append(status)

        let errorMessage = NSAttributeDescription()
        errorMessage.name = "errorMessage"
        errorMessage.attributeType = .stringAttributeType
        errorMessage.isOptional = true
        attributes.append(errorMessage)

        let promptVersion = NSAttributeDescription()
        promptVersion.name = "promptVersion"
        promptVersion.attributeType = .integer16AttributeType
        promptVersion.isOptional = false
        promptVersion.defaultValue = 0
        attributes.append(promptVersion)

        let providerName = NSAttributeDescription()
        providerName.name = "providerName"
        providerName.attributeType = .stringAttributeType
        providerName.isOptional = true
        attributes.append(providerName)

        entity.properties = attributes
        return entity
    }

}
