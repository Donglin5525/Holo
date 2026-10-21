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
        [makeGoalWorkshopSessionEntity(), makeGoalPlanRevisionEntity(), makeGoalReviewLinkEntity()]
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
        // 2026-10-20 目标闭环增量（全部可选，轻量迁移/CloudKit 增量安全）：
        // planPayloadJSON = GoalPlanPayloadV2 信封；baseRevisionID 识别并发分支；
        // operationID 幂等键；effectiveFrom 生效时点
        attr("planPayloadJSON", .stringAttributeType, optional: true)
        attr("baseRevisionID", .UUIDAttributeType, optional: true)
        attr("operationID", .UUIDAttributeType, optional: true)
        attr("effectiveFrom", .dateAttributeType, optional: true)
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "goalID": goalID,
        ])
        return entity
    }

    // MARK: - GoalReviewLinkMO（目标回顾 ↔ 报告消息的轻量索引；只存索引与状态，不存正文）

    private func makeGoalReviewLinkEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "GoalReviewLinkMO"
        entity.managedObjectClassName = "GoalReviewLinkMO"

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
        attr("schemaVersion", .integer16AttributeType, optional: false, default: Int16(1))
        let goalID = attr("goalID", .UUIDAttributeType, optional: false, default: GoalWorkshopSchemaDefaults.zeroUUID)
        attr("planRevisionID", .UUIDAttributeType, optional: false, default: GoalWorkshopSchemaDefaults.zeroUUID)
        let reviewID = attr("reviewID", .UUIDAttributeType, optional: false, default: GoalWorkshopSchemaDefaults.zeroUUID)
        // 报告身份 = ChatMessage.id；生成中尚无结果时为 nil
        let reportMessageID = attr("reportMessageID", .UUIDAttributeType, optional: true)
        attr("windowStart", .dateAttributeType, optional: false, default: Date(timeIntervalSince1970: 0))
        attr("windowEndExclusive", .dateAttributeType, optional: false, default: Date(timeIntervalSince1970: 0))
        attr("snapshotCutoffAt", .dateAttributeType, optional: false, default: Date(timeIntervalSince1970: 0))
        attr("timeZoneID", .stringAttributeType, optional: false, default: "")
        attr("sourceDigest", .stringAttributeType, optional: false, default: "")
        // running / completed / failed / cancelled / stale
        attr("statusRaw", .stringAttributeType, optional: false, default: "running")
        attr("cloudTaskID", .stringAttributeType, optional: true)
        attr("failureReason", .stringAttributeType, optional: true)
        attr("createdAt", .dateAttributeType, optional: false, default: Date())
        attr("updatedAt", .dateAttributeType, optional: false, default: Date())
        attr("completedAt", .dateAttributeType, optional: true)
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "goalID": goalID,
            "reviewID": reviewID,
            "reportMessageID": reportMessageID,
        ])
        return entity
    }
}
