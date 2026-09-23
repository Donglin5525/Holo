//
//  CoreDataStack+MatterEntities.swift
//  Holo
//
//  Matter「进行中的事」四实体程序化定义
//
//  - HoloMatter / HoloMatterOpenLoop / HoloMatterLink / HoloMatterEvent
//  - 全部 ID 逻辑外键，无跨域 relationship（ADR-02）
//  - 非空属性带兼容默认值（CloudKit 要求；语义上由 HoloMatterRepository 显式赋值）
//  - 未知 enum raw / 损坏 JSON 由类型化访问器兜底，不启动崩溃（§15.4）
//

import CoreData

nonisolated extension CoreDataStack {

    nonisolated func createMatterEntities() -> [NSEntityDescription] {
        let matter = makeMatterEntity()
        let openLoop = makeMatterOpenLoopEntity()
        let link = makeMatterLinkEntity()
        let event = makeMatterEventEntity()
        return [matter, openLoop, link, event]
    }

    // MARK: - HoloMatter

    private func makeMatterEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "HoloMatter"
        entity.managedObjectClassName = "HoloMatter"

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

        let id = attr("id", .UUIDAttributeType, optional: false, default: MatterSchemaDefaults.zeroUUID)
        attr("schemaVersion", .integer16AttributeType, optional: false, default: 1)
        attr("title", .stringAttributeType, optional: false, default: "")
        attr("typeLabel", .stringAttributeType, optional: true)
        let lifecycleRaw = attr("lifecycleRaw", .stringAttributeType, optional: false, default: HoloMatterLifecycleStatus.candidate.rawValue)
        attr("phaseRaw", .stringAttributeType, optional: true)
        attr("startDate", .dateAttributeType, optional: true)
        let targetDate = attr("targetDate", .dateAttributeType, optional: true)
        attr("completedAt", .dateAttributeType, optional: true)
        attr("archivedAt", .dateAttributeType, optional: true)
        attr("originRaw", .stringAttributeType, optional: false, default: HoloMatterOrigin.contextPlan.rawValue)
        attr("originEntityID", .stringAttributeType, optional: true)
        attr("projectionJSON", .stringAttributeType, optional: true)
        attr("revision", .integer64AttributeType, optional: false, default: 1)
        attr("createdAt", .dateAttributeType, optional: false, default: Date())
        attr("updatedAt", .dateAttributeType, optional: false, default: Date())
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "lifecycleRaw": lifecycleRaw,
            "targetDate": targetDate,
        ])
        return entity
    }

    // MARK: - HoloMatterOpenLoop

    private func makeMatterOpenLoopEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "HoloMatterOpenLoop"
        entity.managedObjectClassName = "HoloMatterOpenLoop"

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

        let id = attr("id", .UUIDAttributeType, optional: false, default: MatterSchemaDefaults.zeroUUID)
        let matterID = attr("matterID", .UUIDAttributeType, optional: false, default: MatterSchemaDefaults.zeroUUID)
        attr("logicalKey", .stringAttributeType, optional: false, default: "")
        attr("title", .stringAttributeType, optional: false, default: "")
        attr("epistemicRaw", .stringAttributeType, optional: false, default: HoloMatterOpenLoopEpistemic.suggested.rawValue)
        attr("stateRaw", .stringAttributeType, optional: false, default: HoloMatterOpenLoopState.open.rawValue)
        attr("priorityRaw", .stringAttributeType, optional: false, default: HoloMatterOpenLoopPriority.normal.rawValue)
        attr("targetDate", .dateAttributeType, optional: true)
        attr("linkedTaskID", .UUIDAttributeType, optional: true)
        attr("sourceTypeRaw", .stringAttributeType, optional: true)
        attr("sourceEntityID", .stringAttributeType, optional: true)
        attr("sourceRevision", .integer64AttributeType, optional: false, default: 0)
        attr("resolvedAt", .dateAttributeType, optional: true)
        attr("revision", .integer64AttributeType, optional: false, default: 1)
        attr("createdAt", .dateAttributeType, optional: false, default: Date())
        attr("updatedAt", .dateAttributeType, optional: false, default: Date())
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "matterID": matterID,
        ])
        return entity
    }

    // MARK: - HoloMatterLink

    private func makeMatterLinkEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "HoloMatterLink"
        entity.managedObjectClassName = "HoloMatterLink"

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

        let id = attr("id", .UUIDAttributeType, optional: false, default: MatterSchemaDefaults.zeroUUID)
        let matterID = attr("matterID", .UUIDAttributeType, optional: false, default: MatterSchemaDefaults.zeroUUID)
        let entityTypeRaw = attr("entityTypeRaw", .stringAttributeType, optional: false, default: "")
        let entityIDAttr = attr("entityID", .stringAttributeType, optional: false, default: "")
        attr("roleRaw", .stringAttributeType, optional: false, default: HoloMatterLinkRole.resource.rawValue)
        attr("originRaw", .stringAttributeType, optional: false, default: HoloMatterLinkOrigin.system.rawValue)
        attr("confidence", .doubleAttributeType, optional: false, default: 0)
        let statusRaw = attr("statusRaw", .stringAttributeType, optional: false, default: HoloMatterLinkStatus.proposed.rawValue)
        attr("sourceRevision", .stringAttributeType, optional: true)
        // V2 计划顺序：仅 todoTask+action 的 link 使用 0...N-1；其余恒 -1（旧数据/CloudKit 轻量迁移兼容）。
        attr("planOrder", .integer16AttributeType, optional: false, default: -1)
        attr("createdAt", .dateAttributeType, optional: false, default: Date())
        attr("updatedAt", .dateAttributeType, optional: false, default: Date())
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "matterID": matterID,
            "entityTypeRaw": entityTypeRaw,
            "entityID": entityIDAttr,
            "statusRaw": statusRaw,
        ])
        return entity
    }

    // MARK: - HoloMatterEvent

    private func makeMatterEventEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "HoloMatterEvent"
        entity.managedObjectClassName = "HoloMatterEvent"

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

        let id = attr("id", .UUIDAttributeType, optional: false, default: MatterSchemaDefaults.zeroUUID)
        let matterID = attr("matterID", .UUIDAttributeType, optional: false, default: MatterSchemaDefaults.zeroUUID)
        let idempotencyKey = attr("idempotencyKey", .stringAttributeType, optional: false, default: "")
        attr("kindRaw", .stringAttributeType, optional: false, default: HoloMatterEventKind.activated.rawValue)
        attr("actorRaw", .stringAttributeType, optional: false, default: HoloMatterActor.system.rawValue)
        attr("payloadJSON", .stringAttributeType, optional: true)
        attr("sourceTypeRaw", .stringAttributeType, optional: true)
        attr("sourceEntityID", .stringAttributeType, optional: true)
        attr("revertsEventID", .UUIDAttributeType, optional: true)
        attr("createdAt", .dateAttributeType, optional: false, default: Date())
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "matterID": matterID,
            "idempotencyKey": idempotencyKey,
        ])
        return entity
    }
}
