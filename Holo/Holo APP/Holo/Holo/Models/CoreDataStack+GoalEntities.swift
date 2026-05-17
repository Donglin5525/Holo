//
//  CoreDataStack+GoalEntities.swift
//  Holo
//
//  目标相关 Core Data 实体定义
//

import Foundation
import CoreData

extension CoreDataStack {
    nonisolated func createGoalEntity() -> NSEntityDescription {
        let goalEntity = NSEntityDescription()
        goalEntity.name = "Goal"
        goalEntity.managedObjectClassName = "Goal"

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()

        let title = NSAttributeDescription()
        title.name = "title"
        title.attributeType = .stringAttributeType
        title.isOptional = false
        title.defaultValue = ""

        let summary = NSAttributeDescription()
        summary.name = "summary"
        summary.attributeType = .stringAttributeType
        summary.isOptional = true

        let domain = NSAttributeDescription()
        domain.name = "domain"
        domain.attributeType = .stringAttributeType
        domain.isOptional = false
        domain.defaultValue = GoalDomain.other.rawValue

        let desiredOutcome = NSAttributeDescription()
        desiredOutcome.name = "desiredOutcome"
        desiredOutcome.attributeType = .stringAttributeType
        desiredOutcome.isOptional = true

        let motivation = NSAttributeDescription()
        motivation.name = "motivation"
        motivation.attributeType = .stringAttributeType
        motivation.isOptional = true

        let status = NSAttributeDescription()
        status.name = "status"
        status.attributeType = .stringAttributeType
        status.isOptional = false
        status.defaultValue = GoalStatus.active.rawValue

        let deadline = NSAttributeDescription()
        deadline.name = "deadline"
        deadline.attributeType = .dateAttributeType
        deadline.isOptional = true

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false
        createdAt.defaultValue = Date()

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        updatedAt.defaultValue = Date()

        let completedAt = NSAttributeDescription()
        completedAt.name = "completedAt"
        completedAt.attributeType = .dateAttributeType
        completedAt.isOptional = true

        let source = NSAttributeDescription()
        source.name = "source"
        source.attributeType = .stringAttributeType
        source.isOptional = false
        source.defaultValue = "holoAI"

        let allowAIContext = NSAttributeDescription()
        allowAIContext.name = "allowAIContext"
        allowAIContext.attributeType = .booleanAttributeType
        allowAIContext.isOptional = false
        allowAIContext.defaultValue = false

        let lastInsightSummary = NSAttributeDescription()
        lastInsightSummary.name = "lastInsightSummary"
        lastInsightSummary.attributeType = .stringAttributeType
        lastInsightSummary.isOptional = true

        goalEntity.properties = [
            id, title, summary, domain, desiredOutcome, motivation, status,
            deadline, createdAt, updatedAt, completedAt, source, allowAIContext,
            lastInsightSummary
        ]
        return goalEntity
    }
}
