//
//  CoreDataStack+TodayPlanEntities.swift
//  Holo
//
//  「今天减负」当日计划实体程序化定义（2026-10-03 实施方案 §7.3）
//
//  设计约束与 TaskExecution 三实体同构（ADR-02）：
//  - ID 逻辑外键，无跨域 relationship，不加 CloudKit 不支持的唯一约束；
//  - 非空属性带兼容默认值，真实值由 HoloTodayPlanService 写入；
//  - 本文件与实体类文件同时挂 App 与 HoloWidgets 两个 target（Widget 编译
//    CoreDataStack.swift → 必须能解析全部实体工厂符号）。
//

import CoreData

nonisolated extension CoreDataStack {

    nonisolated func createTodayPlanEntities() -> [NSEntityDescription] {
        [makeTodayPlanRevisionEntity()]
    }

    private func makeTodayPlanRevisionEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "HoloTodayPlanRevision"
        entity.managedObjectClassName = "HoloTodayPlanRevision"

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

        let id = attr("id", .UUIDAttributeType, optional: false, default: HoloTodayPlanSchemaDefaults.zeroUUID)
        attr("schemaVersion", .integer16AttributeType, optional: false, default: 1)
        let scopeKey = attr("scopeKey", .stringAttributeType, optional: false, default: "")
        attr("dateKey", .stringAttributeType, optional: false, default: "")
        attr("timeZoneIdentifier", .stringAttributeType, optional: false, default: "")
        attr("dayStart", .dateAttributeType, optional: false, default: Date())
        attr("dayEnd", .dateAttributeType, optional: false, default: Date())
        attr("parentRevisionIDsJSON", .stringAttributeType, optional: false, default: HoloTodayPlanSchemaDefaults.emptyJSON)
        // 采纳幂等键：同 operationID 重放不得生成第二份版本
        let operationID = attr("operationID", .stringAttributeType, optional: false, default: "")
        attr("commandRaw", .stringAttributeType, optional: false, default: HoloTodayPlanCommand.adopt.rawValue)
        attr("payloadJSON", .stringAttributeType, optional: false, default: "{}")
        attr("payloadDigest", .stringAttributeType, optional: false, default: "")
        // 本地明确赋值；不以设备时间戳决定分叉胜负
        attr("createdAt", .dateAttributeType, optional: false, default: Date())
        attr("restoredFromRevisionID", .UUIDAttributeType, optional: true)
        attr("createdTaskID", .UUIDAttributeType, optional: true)
        let soft = CoreDataStack.makeSoftDeleteAttributes()
        attributes.append(contentsOf: soft.attributes)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: [
            "id": id,
            "scopeKey": scopeKey,
            "operationID": operationID,
        ])
        return entity
    }
}
