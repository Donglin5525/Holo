//
//  CoreDataStack+HoloMemoryEntities.swift
//  Holo
//
//  统一记忆的程序化 Core Data 模型
//

import CoreData
import Foundation

nonisolated enum HoloMemoryManagedObjectModelFactory {
    static let entityNames = [
        "HoloMemoryRecordMO",
        "HoloMemoryEvidenceMO",
        "HoloMemoryAnchorAliasMO",
        "HoloMemoryObservationRunMO",
        "HoloMemoryTombstoneMO",
        "HoloMemoryControlStateMO",
        "HoloMemoryControlEventMO",
        "HoloMemoryKnowledgeRevisionMO",
        "HoloMemoryKnowledgeOperationMO"
    ]

    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.entities = makeEntities()
        return model
    }

    /// 迁移演练/快照测试用：按子集建「上一版模型」创建旧库，
    /// 再用 makeModel() 加载复现真实升级路径。生产代码只用 makeModel()。
    static func makeModel(excludingEntityNames excluded: Set<String>) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.entities = makeEntities().filter { entity in
            guard let name = entity.name else { return true }
            return !excluded.contains(name)
        }
        return model
    }

    static func makeEntities() -> [NSEntityDescription] {
        [
            recordEntity(),
            evidenceEntity(),
            anchorAliasEntity(),
            observationRunEntity(),
            tombstoneEntity(),
            controlStateEntity(),
            controlEventEntity(),
            knowledgeRevisionEntity(),
            knowledgeOperationEntity()
        ]
    }

    private static func recordEntity() -> NSEntityDescription {
        entity(
            name: "HoloMemoryRecordMO",
            className: NSStringFromClass(HoloMemoryRecordMO.self),
            attributes: [
                attribute("stableID", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("recordVersion", .integer64AttributeType, defaultValue: 1),
                attribute("scope", .stringAttributeType, defaultValue: "domain", indexed: true),
                attribute("state", .stringAttributeType, defaultValue: "candidate", indexed: true),
                attribute("userDecision", .stringAttributeType, defaultValue: "none", indexed: true),
                attribute("hasHealthLineage", .booleanAttributeType, defaultValue: false, indexed: true),
                attribute("lastObservationKey", .stringAttributeType, optional: true, indexed: true),
                attribute("recordData", .binaryDataAttributeType, defaultValue: Data()),
                attribute("createdAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0)),
                attribute("updatedAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0), indexed: true),
                attribute("deletedAt", .dateAttributeType, optional: true, indexed: true),
                attribute("deletedBatchId", .UUIDAttributeType, optional: true)
            ]
        )
    }

    private static func evidenceEntity() -> NSEntityDescription {
        entity(
            name: "HoloMemoryEvidenceMO",
            className: NSStringFromClass(HoloMemoryEvidenceMO.self),
            attributes: [
                attribute("id", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("recordID", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("lineageKey", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("evidenceData", .binaryDataAttributeType, defaultValue: Data()),
                attribute("observedAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0)),
                attribute("deletedAt", .dateAttributeType, optional: true),
                attribute("deletedBatchId", .UUIDAttributeType, optional: true)
            ]
        )
    }

    private static func anchorAliasEntity() -> NSEntityDescription {
        entity(
            name: "HoloMemoryAnchorAliasMO",
            className: NSStringFromClass(HoloMemoryAnchorAliasMO.self),
            attributes: [
                attribute("aliasKey", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("anchorData", .binaryDataAttributeType, defaultValue: Data()),
                attribute("verificationSource", .stringAttributeType, defaultValue: ""),
                attribute("verifiedAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0)),
                attribute("deletedAt", .dateAttributeType, optional: true),
                attribute("deletedBatchId", .UUIDAttributeType, optional: true)
            ]
        )
    }

    private static func observationRunEntity() -> NSEntityDescription {
        entity(
            name: "HoloMemoryObservationRunMO",
            className: NSStringFromClass(HoloMemoryObservationRunMO.self),
            attributes: [
                attribute("observationKey", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("domain", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("status", .stringAttributeType, defaultValue: "pending", indexed: true),
                attribute("extractorVersion", .integer64AttributeType, defaultValue: 0),
                attribute("promptVersion", .integer64AttributeType, defaultValue: 0),
                attribute("completedAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0)),
                attribute("deletedAt", .dateAttributeType, optional: true),
                attribute("deletedBatchId", .UUIDAttributeType, optional: true)
            ]
        )
    }

    private static func tombstoneEntity() -> NSEntityDescription {
        entity(
            name: "HoloMemoryTombstoneMO",
            className: NSStringFromClass(HoloMemoryTombstoneMO.self),
            attributes: [
                attribute("identityKey", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("scope", .stringAttributeType, defaultValue: "domain", indexed: true),
                attribute("claimKind", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("anchorKeysJSON", .stringAttributeType, defaultValue: "[]"),
                attribute("userDecisionVersion", .integer64AttributeType, defaultValue: 0),
                attribute("createdAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0), indexed: true),
                attribute("deletedAt", .dateAttributeType, optional: true),
                attribute("deletedBatchId", .UUIDAttributeType, optional: true)
            ]
        )
    }

    // ControlStateMO 为全局运行状态单例（非用户数据），不参与软删除；
    // 「清空所有数据」时物理重置，恢复流程不涉及，运行期按需自动重建。
    private static func controlStateEntity() -> NSEntityDescription {
        entity(
            name: "HoloMemoryControlStateMO",
            className: NSStringFromClass(HoloMemoryControlStateMO.self),
            attributes: [
                attribute("id", .stringAttributeType, defaultValue: "global", indexed: true),
                attribute("stateData", .binaryDataAttributeType, defaultValue: Data()),
                attribute("userDecisionVersion", .integer64AttributeType, defaultValue: 0),
                attribute("updatedAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0), indexed: true)
            ]
        )
    }

    // 用户控制事件（方案 §11.4）：只记录控制事实与必要差异摘要，不存记忆正文。
    // 随记录落同域容器（敏感记录的事件在敏感库，§9.3）；因果只看 priorEventIDs，
    // 时间戳仅供展示。appliedAt 为空 = 记录状态尚未体现该控制（崩溃恢复按事件重放）。
    private static func controlEventEntity() -> NSEntityDescription {
        entity(
            name: "HoloMemoryControlEventMO",
            className: NSStringFromClass(HoloMemoryControlEventMO.self),
            attributes: [
                attribute("id", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("targetRecordID", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("kind", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("priorEventIDsJSON", .stringAttributeType, defaultValue: "[]"),
                attribute("basedOnContentVersion", .integer64AttributeType, defaultValue: 0),
                attribute("resultingContentVersion", .integer64AttributeType, defaultValue: 0),
                attribute("occurredAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0), indexed: true),
                attribute("operationID", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("payloadDigest", .stringAttributeType, optional: true),
                attribute("appliedAt", .dateAttributeType, optional: true),
                attribute("schemaVersion", .integer64AttributeType, defaultValue: 1),
                attribute("deletedAt", .dateAttributeType, optional: true),
                attribute("deletedBatchId", .UUIDAttributeType, optional: true)
            ]
        )
    }

    // 通用知识修订（方案 v2.2 §7.1 新实体 1）：修订正文不可原地覆盖，每次语义修改
    // 产生新修订；普通证据刷新走 KnowledgeOperation.evidenceSnapshot，不改本行。
    // 必要物理属性带默认值/可选，符合 CloudKit 增量约束（只新增实体/字段）。
    // CloudKit 不依赖唯一约束：同步出现相同逻辑 ID 的重复行在 Repository 归并。
    private static func knowledgeRevisionEntity() -> NSEntityDescription {
        entity(
            name: "HoloMemoryKnowledgeRevisionMO",
            className: NSStringFromClass(HoloMemoryKnowledgeRevisionMO.self),
            attributes: [
                attribute("propositionID", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("semanticRevisionID", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("semanticDigest", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("topicID", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("partition", .stringAttributeType, defaultValue: "normal", indexed: true),
                attribute("revisionData", .binaryDataAttributeType, defaultValue: Data()),
                attribute("createdAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0), indexed: true),
                attribute("schemaVersion", .integer64AttributeType, defaultValue: 1),
                attribute("deletedAt", .dateAttributeType, optional: true, indexed: true),
                attribute("deletedBatchId", .UUIDAttributeType, optional: true)
            ]
        )
    }

    // 通用知识操作（方案 v2.2 §7.1 新实体 2）：幂等操作 ID、目标命题/语义、前驱控制、
    // 操作种类、证据快照/别名/迁移收据等版本化载荷。用户确认/纠正/限制在这里形成
    // 权威事件。新控制不写入旧 HoloMemoryControlEventMO（旧重放器遇新实体目标会误标完成）。
    private static func knowledgeOperationEntity() -> NSEntityDescription {
        entity(
            name: "HoloMemoryKnowledgeOperationMO",
            className: NSStringFromClass(HoloMemoryKnowledgeOperationMO.self),
            attributes: [
                attribute("operationID", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("propositionID", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("kind", .stringAttributeType, defaultValue: "", indexed: true),
                attribute("targetSemanticRevisionID", .stringAttributeType, optional: true),
                attribute("priorOperationIDsJSON", .stringAttributeType, defaultValue: "[]"),
                attribute("controlGeneration", .integer64AttributeType, defaultValue: 0),
                attribute("partition", .stringAttributeType, defaultValue: "normal", indexed: true),
                attribute("operationData", .binaryDataAttributeType, defaultValue: Data()),
                attribute("issuedAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0), indexed: true),
                attribute("appliedAt", .dateAttributeType, optional: true),
                attribute("schemaVersion", .integer64AttributeType, defaultValue: 1),
                attribute("deletedAt", .dateAttributeType, optional: true, indexed: true),
                attribute("deletedBatchId", .UUIDAttributeType, optional: true)
            ]
        )
    }

    private static func entity(
        name: String,
        className: String,
        attributes: [NSAttributeDescription]
    ) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = className
        entity.properties = attributes
        entity.indexes = attributes.compactMap { attribute in
            guard attribute.userInfo?["holoIndexed"] as? Bool == true else { return nil }
            return NSFetchIndexDescription(
                name: "\(name)_\(attribute.name)_index",
                elements: [NSFetchIndexElementDescription(
                    property: attribute,
                    collationType: .binary
                )]
            )
        }
        return entity
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = false,
        defaultValue: Any? = nil,
        indexed: Bool = false
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        attribute.defaultValue = defaultValue
        if indexed { attribute.userInfo = ["holoIndexed": true] }
        return attribute
    }
}
