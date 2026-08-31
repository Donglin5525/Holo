//
//  CoreDataStack+CategoryLearningEntities.swift
//  Holo
//
//  分类学习实体（跟随 iCloud 同步）
//  学习映射与归纳规则原先只存本地 UserDefaults，卸载即丢；
//  迁入 CloudKit 同步实体后，卸载重装随 iCloud 恢复。
//  归纳样本为本地滚动原材料（200 条上限），不入同步表。
//

import CoreData

extension CoreDataStack {

    /// 精确学习映射：candidate → 用户确认分类（逐行存储，按业务键 upsert）
    nonisolated func createCategoryMappingRecordEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CategoryMappingRecordEntity"
        entity.managedObjectClassName = "CategoryMappingRecordEntity"

        var attributes: [NSAttributeDescription] = []

        let mappingKey = NSAttributeDescription()
        mappingKey.name = "mappingKey"
        mappingKey.attributeType = .stringAttributeType
        mappingKey.isOptional = false
        mappingKey.defaultValue = ""
        attributes.append(mappingKey)

        let transactionType = NSAttributeDescription()
        transactionType.name = "transactionType"
        transactionType.attributeType = .stringAttributeType
        transactionType.isOptional = false
        transactionType.defaultValue = ""
        attributes.append(transactionType)

        let primaryCategory = NSAttributeDescription()
        primaryCategory.name = "primaryCategory"
        primaryCategory.attributeType = .stringAttributeType
        primaryCategory.isOptional = false
        primaryCategory.defaultValue = ""
        attributes.append(primaryCategory)

        let candidate = NSAttributeDescription()
        candidate.name = "candidate"
        candidate.attributeType = .stringAttributeType
        candidate.isOptional = false
        candidate.defaultValue = ""
        attributes.append(candidate)

        let targetPrimary = NSAttributeDescription()
        targetPrimary.name = "targetPrimary"
        targetPrimary.attributeType = .stringAttributeType
        targetPrimary.isOptional = false
        targetPrimary.defaultValue = ""
        attributes.append(targetPrimary)

        let targetSub = NSAttributeDescription()
        targetSub.name = "targetSub"
        targetSub.attributeType = .stringAttributeType
        targetSub.isOptional = false
        targetSub.defaultValue = ""
        attributes.append(targetSub)

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        updatedAt.defaultValue = Date()
        attributes.append(updatedAt)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: ["mappingKey": mappingKey])
        return entity
    }

    /// LLM 归纳规则：模式匹配 → 分类（逐行存储，按业务键去重）
    nonisolated func createCategoryInductionRuleEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CategoryInductionRuleEntity"
        entity.managedObjectClassName = "CategoryInductionRuleEntity"

        var attributes: [NSAttributeDescription] = []

        let ruleKey = NSAttributeDescription()
        ruleKey.name = "ruleKey"
        ruleKey.attributeType = .stringAttributeType
        ruleKey.isOptional = false
        ruleKey.defaultValue = ""
        attributes.append(ruleKey)

        let pattern = NSAttributeDescription()
        pattern.name = "pattern"
        pattern.attributeType = .stringAttributeType
        pattern.isOptional = false
        pattern.defaultValue = ""
        attributes.append(pattern)

        let matchType = NSAttributeDescription()
        matchType.name = "matchType"
        matchType.attributeType = .stringAttributeType
        matchType.isOptional = false
        matchType.defaultValue = "contains"
        attributes.append(matchType)

        let transactionType = NSAttributeDescription()
        transactionType.name = "transactionType"
        transactionType.attributeType = .stringAttributeType
        transactionType.isOptional = false
        transactionType.defaultValue = ""
        attributes.append(transactionType)

        let targetPrimary = NSAttributeDescription()
        targetPrimary.name = "targetPrimary"
        targetPrimary.attributeType = .stringAttributeType
        targetPrimary.isOptional = false
        targetPrimary.defaultValue = ""
        attributes.append(targetPrimary)

        let targetSub = NSAttributeDescription()
        targetSub.name = "targetSub"
        targetSub.attributeType = .stringAttributeType
        targetSub.isOptional = false
        targetSub.defaultValue = ""
        attributes.append(targetSub)

        let sampleCount = NSAttributeDescription()
        sampleCount.name = "sampleCount"
        sampleCount.attributeType = .integer64AttributeType
        sampleCount.isOptional = false
        sampleCount.defaultValue = 0
        attributes.append(sampleCount)

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false
        createdAt.defaultValue = Date()
        attributes.append(createdAt)

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        updatedAt.defaultValue = Date()
        attributes.append(updatedAt)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: ["ruleKey": ruleKey])
        return entity
    }
}
