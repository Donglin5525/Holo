//
//  CoreDataStack+RecycleBinEntities.swift
//  Holo
//
//  回收站批次实体定义
//

import CoreData

extension CoreDataStack {

    // MARK: - RecycleBin Entity

    nonisolated func createRecycleBinEntities() -> [NSEntityDescription] {
        let batchEntity = NSEntityDescription()
        batchEntity.name = "RecycleBinBatch"
        batchEntity.managedObjectClassName = "RecycleBinBatch"

        var attributes: [NSAttributeDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()
        attributes.append(id)

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false
        createdAt.defaultValue = Date()
        attributes.append(createdAt)

        let scope = NSAttributeDescription()
        scope.name = "scope"
        scope.attributeType = .stringAttributeType
        scope.isOptional = false
        scope.defaultValue = "module"
        attributes.append(scope)

        let modules = NSAttributeDescription()
        modules.name = "modules"
        modules.attributeType = .stringAttributeType
        modules.isOptional = false
        modules.defaultValue = ""
        attributes.append(modules)

        let summary = NSAttributeDescription()
        summary.name = "summary"
        summary.attributeType = .stringAttributeType
        summary.isOptional = true
        attributes.append(summary)

        batchEntity.properties = attributes
        CoreDataStack.applyIndexes(to: batchEntity, on: ["id": id, "createdAt": createdAt])

        return [batchEntity]
    }
}
