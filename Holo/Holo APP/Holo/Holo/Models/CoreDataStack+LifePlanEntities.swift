//
//  CoreDataStack+LifePlanEntities.swift
//  Holo
//
//  LifePlan 计划台账 Core Data 实体定义（六个对象，全部 ID 外键、无跨域关系）
//

import CoreData

/// 纯实体描述构造，无状态访问；nonisolated 供启动期模型组装在任意上下文调用
nonisolated extension CoreDataStack {

    // MARK: - LifePlan Entities

    /// 创建计划台账六实体（LifePlan / PlanPriority / PlanAction / PlanSignal / PlanFeedback / PlanRun）
    nonisolated func createLifePlanEntities() -> [NSEntityDescription] {
        [
            lifePlanEntity(),
            planPriorityEntity(),
            planActionEntity(),
            planSignalEntity(),
            planFeedbackEntity(),
            planRunEntity()
        ]
    }

    private func lifePlanEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "LifePlanMO"
        entity.managedObjectClassName = "Holo.LifePlanMO"
        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("scope", .stringAttributeType, defaultValue: "week"),
            attribute("periodStart", .dateAttributeType, defaultValue: Date()),
            attribute("periodEnd", .dateAttributeType, defaultValue: Date()),
            attribute("status", .stringAttributeType, defaultValue: "active"),
            optionalAttribute("constraintSummary", .stringAttributeType),
            attribute("snapshotCutoffAt", .dateAttributeType, defaultValue: Date()),
            attribute("version", .integer16AttributeType, defaultValue: Int16(1)),
            attribute("trigger", .stringAttributeType, defaultValue: "weeklyPlanning"),
            attribute("dataSufficient", .booleanAttributeType, defaultValue: true),
            attribute("createdAt", .dateAttributeType, defaultValue: Date()),
            attribute("updatedAt", .dateAttributeType, defaultValue: Date())
        ]
        return entity
    }

    private func planPriorityEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "PlanPriorityMO"
        entity.managedObjectClassName = "Holo.PlanPriorityMO"
        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("planID", .UUIDAttributeType, defaultValue: UUID()),
            attribute("outcome", .stringAttributeType, defaultValue: ""),
            attribute("whyNow", .stringAttributeType, defaultValue: ""),
            attribute("evidenceIDsJSON", .stringAttributeType, defaultValue: "[]"),
            attribute("priorityRank", .integer16AttributeType, defaultValue: Int16(1)),
            optionalAttribute("userDecision", .stringAttributeType),
            optionalAttribute("goalID", .UUIDAttributeType),
            attribute("createdAt", .dateAttributeType, defaultValue: Date()),
            attribute("updatedAt", .dateAttributeType, defaultValue: Date())
        ]
        return entity
    }

    private func planActionEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "PlanActionMO"
        entity.managedObjectClassName = "Holo.PlanActionMO"
        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("planID", .UUIDAttributeType, defaultValue: UUID()),
            attribute("type", .stringAttributeType, defaultValue: "task"),
            attribute("draftPayloadJSON", .stringAttributeType, defaultValue: "{}"),
            optionalAttribute("expectedBenefit", .stringAttributeType),
            optionalAttribute("tradeoff", .stringAttributeType),
            attribute("evidenceIDsJSON", .stringAttributeType, defaultValue: "[]"),
            attribute("requiresConfirmation", .booleanAttributeType, defaultValue: true),
            attribute("status", .stringAttributeType, defaultValue: "proposed"),
            optionalAttribute("undoTokenJSON", .stringAttributeType),
            attribute("sortOrder", .integer16AttributeType, defaultValue: Int16(0)),
            attribute("createdAt", .dateAttributeType, defaultValue: Date()),
            attribute("updatedAt", .dateAttributeType, defaultValue: Date())
        ]
        return entity
    }

    private func planSignalEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "PlanSignalMO"
        entity.managedObjectClassName = "Holo.PlanSignalMO"
        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            optionalAttribute("planID", .UUIDAttributeType),
            attribute("domain", .stringAttributeType, defaultValue: "task"),
            attribute("severity", .doubleAttributeType, defaultValue: 0.0),
            attribute("novelty", .doubleAttributeType, defaultValue: 0.0),
            attribute("confidence", .doubleAttributeType, defaultValue: 0.0),
            attribute("actionability", .doubleAttributeType, defaultValue: 0.0),
            attribute("urgency", .doubleAttributeType, defaultValue: 0.0),
            attribute("evidenceIDsJSON", .stringAttributeType, defaultValue: "[]"),
            attribute("outcome", .stringAttributeType, defaultValue: "surfaced"),
            optionalAttribute("dismissedAt", .dateAttributeType),
            attribute("createdAt", .dateAttributeType, defaultValue: Date())
        ]
        return entity
    }

    private func planFeedbackEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "PlanFeedbackMO"
        entity.managedObjectClassName = "Holo.PlanFeedbackMO"
        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("actionID", .UUIDAttributeType, defaultValue: UUID()),
            attribute("planID", .UUIDAttributeType, defaultValue: UUID()),
            attribute("decision", .stringAttributeType, defaultValue: "rejected"),
            optionalAttribute("reasonTag", .stringAttributeType),
            optionalAttribute("freeText", .stringAttributeType),
            attribute("createdAt", .dateAttributeType, defaultValue: Date())
        ]
        return entity
    }

    private func planRunEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "PlanRunMO"
        entity.managedObjectClassName = "Holo.PlanRunMO"
        entity.properties = [
            attribute("id", .UUIDAttributeType, defaultValue: UUID()),
            attribute("planID", .UUIDAttributeType, defaultValue: UUID()),
            attribute("jobID", .stringAttributeType, defaultValue: ""),
            attribute("trigger", .stringAttributeType, defaultValue: "weeklyPlanning"),
            attribute("inputSnapshotVersion", .integer16AttributeType, defaultValue: Int16(1)),
            optionalAttribute("consumedBudgetJSON", .stringAttributeType),
            attribute("resultStatus", .stringAttributeType, defaultValue: "completed"),
            attribute("createdAt", .dateAttributeType, defaultValue: Date())
        ]
        return entity
    }

    // MARK: - Attribute Helpers

    private func attribute(
        _ name: String,
        _ type: NSAttributeType,
        defaultValue: Any
    ) -> NSAttributeDescription {
        let attr = NSAttributeDescription()
        attr.name = name
        attr.attributeType = type
        attr.isOptional = false
        attr.defaultValue = defaultValue
        return attr
    }

    private func optionalAttribute(
        _ name: String,
        _ type: NSAttributeType
    ) -> NSAttributeDescription {
        let attr = NSAttributeDescription()
        attr.name = name
        attr.attributeType = type
        attr.isOptional = true
        return attr
    }
}
