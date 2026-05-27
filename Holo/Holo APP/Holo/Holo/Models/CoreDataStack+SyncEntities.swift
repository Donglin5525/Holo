//
//  CoreDataStack+SyncEntities.swift
//  Holo
//
//  内部同步探针实体，用于在用户手动请求同步时产生一条轻量 Core Data 变更。
//

import CoreData

extension CoreDataStack {

    nonisolated func createSyncEntities() -> [NSEntityDescription] {
        let syncProbeEntity = NSEntityDescription()
        syncProbeEntity.name = "ICloudSyncProbe"
        syncProbeEntity.managedObjectClassName = "NSManagedObject"

        var attributes: [NSAttributeDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        id.isIndexed = true
        attributes.append(id)

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        updatedAt.defaultValue = Date()
        attributes.append(updatedAt)

        let reason = NSAttributeDescription()
        reason.name = "reason"
        reason.attributeType = .stringAttributeType
        reason.isOptional = false
        reason.defaultValue = "manual"
        attributes.append(reason)

        let nonce = NSAttributeDescription()
        nonce.name = "nonce"
        nonce.attributeType = .stringAttributeType
        nonce.isOptional = false
        nonce.defaultValue = ""
        attributes.append(nonce)

        syncProbeEntity.properties = attributes
        return [syncProbeEntity]
    }
}
