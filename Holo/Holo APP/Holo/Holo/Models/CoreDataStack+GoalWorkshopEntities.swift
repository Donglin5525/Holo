//
//  CoreDataStack+GoalWorkshopEntities.swift
//  Holo
//
//  目标共创（GoalWorkshop）两实体程序化定义（2026-09-17 方案任务 2）
//
//  - GoalWorkshopSessionMO / GoalPlanRevisionMO
//  - ID 逻辑外键（goalID / sourceSessionID），不建跨域 relationship
//  - 非空属性带兼容默认值（CloudKit 要求；语义由 Store 显式赋值）
//  - payloadJSON 为版本化 Codable 信封，未知版本由 Store 隔离不覆盖
//

import CoreData

enum GoalWorkshopSchemaDefaults {
    static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    /// 当前会话/决策摘要 payload 的 schema 版本；升级时 +1 并在 Store 解码处分版
    static let payloadSchemaVersion: Int16 = 1
}

nonisolated extension CoreDataStack {

    nonisolated func createGoalWorkshopEntities() -> [NSEntityDescription] {
        [makeGoalWorkshopSessionEntity(), makeGoalPlanRevisionEntity()]
    }

    // MARK: - GoalWorkshopSessionMO

    private func makeGoalWorkshopSessionEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "GoalWorkshopSessionMO"
        entity.managedObjectClassName = "GoalWorkshopSessionMO"

        var attributes: [NSAttributeDescription] = []
        @discardableResult
        func attr(_ name: String, _ type: NSAttributeType, optional: Bool, default value: Any? = nil) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            if let value { a.defaultValue = value }
            attributes.append(a)
            return a
        }

        let id = attr("id", .UUIDAttributeType, optional: false, default: GoalWorkshopSchemaDefaults.zeroUUID)
        attr("schemaVersion", .integer16AttributeType, optional: false, default: GoalWorkshopSchemaDefaults.payloadSchemaVersion)
        attr("goalID", .UUIDAttributeType, optional: true)
        let phaseRaw = attr("phaseRaw", .stringAttributeType, optional: false, default: GoalWorkshopPhase.understanding.rawValue)
        attr("revision", .integer64AttributeType, optional: false, default: 0)
        attr("originalText", .stringAttributeType, optional: false, default: "")
        attr("payloadJSON", .stringAttributeType, optional: false, default: "")
        attr("appliedGoalID", .UUIDAttributeType, optional: true)
        attr("createdAt", .dateAttributeType, optional: false, default: Date())
        attr("updatedAt", .dateAttributeType, optional: false, default: Date())
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "phaseRaw": phaseRaw,
        ])
        return entity
    }

    // MARK: - GoalPlanRevisionMO

    private func makeGoalPlanRevisionEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "GoalPlanRevisionMO"
        entity.managedObjectClassName = "GoalPlanRevisionMO"

        var attributes: [NSAttributeDescription] = []
        @discardableResult
        func attr(_ name: String, _ type: NSAttributeType, optional: Bool, default value: Any? = nil) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            if let value { a.defaultValue = value }
            attributes.append(a)
            return a
        }

        let id = attr("id", .UUIDAttributeType, optional: false, default: GoalWorkshopSchemaDefaults.zeroUUID)
        attr("schemaVersion", .integer16AttributeType, optional: false, default: GoalWorkshopSchemaDefaults.payloadSchemaVersion)
        let goalID = attr("goalID", .UUIDAttributeType, optional: false, default: GoalWorkshopSchemaDefaults.zeroUUID)
        attr("sourceSessionID", .UUIDAttributeType, optional: false, default: GoalWorkshopSchemaDefaults.zeroUUID)
        attr("revisionNumber", .integer64AttributeType, optional: false, default: 1)
        attr("decisionSummaryJSON", .stringAttributeType, optional: false, default: "")
        attr("createdAt", .dateAttributeType, optional: false, default: Date())
        attr("updatedAt", .dateAttributeType, optional: false, default: Date())
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "goalID": goalID,
        ])
        return entity
    }
}
