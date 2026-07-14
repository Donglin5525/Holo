//
//  CoreDataStack+HoloMemoryEntities.swift
//  Holo
//
//  统一记忆的程序化 Core Data 模型
//

import CoreData
import Foundation

enum HoloMemoryManagedObjectModelFactory {
    static let entityNames = [
        "HoloMemoryRecordMO",
        "HoloMemoryEvidenceMO",
        "HoloMemoryAnchorAliasMO",
        "HoloMemoryObservationRunMO",
        "HoloMemoryTombstoneMO",
        "HoloMemoryControlStateMO"
    ]

    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.entities = makeEntities()
        return model
    }

    static func makeEntities() -> [NSEntityDescription] {
        [
            recordEntity(),
            evidenceEntity(),
            anchorAliasEntity(),
            observationRunEntity(),
            tombstoneEntity(),
            controlStateEntity()
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
                attribute("updatedAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0), indexed: true)
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
                attribute("observedAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0))
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
                attribute("verifiedAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0))
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
                attribute("completedAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0))
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
                attribute("createdAt", .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0), indexed: true)
            ]
        )
    }

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
