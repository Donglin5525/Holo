//
//  CoreDataStack+VisualAssetEntities.swift
//  Holo
//
//  贴纸与视觉素材三实体（纯加表，2026-11-16 方案 02 §4）：
//  - VisualAsset            像素素材内容与管理元数据（不可变像素 + 可变管理字段）
//  - VisualPlacementRevision 位置版本（不可变记录，logicalClock/writerID/mutationID 稳定排序）
//  - VisualAssetTombstone   删除墓碑（只追加，任一墓碑命中即全位置不可显示）
//  不设 unique constraints（CloudKit 不支持）；不建跨模块 relationship（业务 UUID 关联）。
//

import CoreData

extension CoreDataStack {

    /// 三实体工厂。字段约束真源：方案 02 §4.2/§4.3/§4.5。
    nonisolated static func createVisualAssetEntities() -> [NSEntityDescription] {
        [makeVisualAssetEntity(), makeVisualPlacementRevisionEntity(), makeVisualAssetTombstoneEntity()]
    }

    // MARK: - VisualAsset

    private nonisolated static func makeVisualAssetEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VisualAsset"
        entity.managedObjectClassName = "VisualAsset"

        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = true,
                  default value: Any? = nil, external: Bool = false) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            a.defaultValue = value
            a.allowsExternalBinaryDataStorage = external
            return a
        }

        var indexes: [String: NSPropertyDescription] = [:]
        var attributes: [NSAttributeDescription] = []
        for a in [
            attr("id", .UUIDAttributeType),
            attr("creationOperationID", .UUIDAttributeType),
            attr("kind", .stringAttributeType),                      // sticker / photo；未知值只读占位
            attr("sourceData", .binaryDataAttributeType, external: true),
            attr("sourceUTType", .stringAttributeType),
            attr("sourceHash", .stringAttributeType),
            attr("maskData", .binaryDataAttributeType, external: true),   // sticker 必需
            attr("maskHash", .stringAttributeType),
            attr("contentData", .binaryDataAttributeType, external: true),
            attr("contentUTType", .stringAttributeType),
            attr("contentHash", .stringAttributeType),
            attr("thumbnailData", .binaryDataAttributeType, external: true),
            attr("thumbnailHash", .stringAttributeType),
            attr("sourceWidth", .integer32AttributeType, default: 0),
            attr("sourceHeight", .integer32AttributeType, default: 0),
            attr("contentWidth", .integer32AttributeType, default: 0),
            attr("contentHeight", .integer32AttributeType, default: 0),
            attr("transformJSON", .stringAttributeType),
            attr("processingVersion", .integer32AttributeType, default: 1),
            attr("metadataVersion", .integer32AttributeType, default: 1),
            attr("displayName", .stringAttributeType),
            attr("isFavorite", .booleanAttributeType, default: false),
            attr("libraryVisibility", .stringAttributeType),         // visible / hidden / recordOnly
            attr("createdAt", .dateAttributeType),
            attr("metadataUpdatedAt", .dateAttributeType),
        ] {
            attributes.append(a)
        }
        entity.properties = attributes
        if let id = attributes.first(where: { $0.name == "id" }) { indexes["id"] = id }
        if let opID = attributes.first(where: { $0.name == "creationOperationID" }) { indexes["creationOperationID"] = opID }
        applyIndexes(to: entity, on: indexes)
        return entity
    }

    // MARK: - VisualPlacementRevision

    private nonisolated static func makeVisualPlacementRevisionEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VisualPlacementRevision"
        entity.managedObjectClassName = "VisualPlacementRevision"

        var indexes: [String: NSPropertyDescription] = [:]
        var attributes: [NSAttributeDescription] = []
        for (name, type, def) in [
            ("id", NSAttributeType.UUIDAttributeType, nil as Any?),
            ("operationID", NSAttributeType.UUIDAttributeType, nil),
            ("mutationID", NSAttributeType.UUIDAttributeType, nil),
            ("ownerKind", NSAttributeType.stringAttributeType, nil),
            ("ownerKey", NSAttributeType.stringAttributeType, nil),      // UUID 小写标准串
            ("slot", NSAttributeType.stringAttributeType, nil),
            ("placementKey", NSAttributeType.stringAttributeType, nil),  // [ownerKind, ownerKey, slot] 规范编码
            ("logicalClock", NSAttributeType.integer64AttributeType, 0),
            ("writerID", NSAttributeType.stringAttributeType, nil),      // 安装级稳定 UUID 串
            ("payloadJSON", NSAttributeType.stringAttributeType, nil),
            ("payloadHash", NSAttributeType.stringAttributeType, nil),
            ("changedAt", NSAttributeType.dateAttributeType, nil),       // 仅展示/诊断，不参与胜出
        ] {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = def == nil
            a.defaultValue = def
            attributes.append(a)
        }
        entity.properties = attributes
        for name in ["placementKey", "operationID", "ownerKind", "ownerKey"] {
            if let a = attributes.first(where: { $0.name == name }) { indexes[name] = a }
        }
        applyIndexes(to: entity, on: indexes)
        return entity
    }

    // MARK: - VisualAssetTombstone

    private nonisolated static func makeVisualAssetTombstoneEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "VisualAssetTombstone"
        entity.managedObjectClassName = "VisualAssetTombstone"

        var indexes: [String: NSPropertyDescription] = [:]
        var attributes: [NSAttributeDescription] = []
        for (name, type, def) in [
            ("id", NSAttributeType.UUIDAttributeType, nil as Any?),
            ("operationID", NSAttributeType.UUIDAttributeType, nil),
            ("assetID", NSAttributeType.UUIDAttributeType, nil),
            ("deletedAt", NSAttributeType.dateAttributeType, nil),
            ("schemaVersion", NSAttributeType.integer32AttributeType, 1),
        ] {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = def == nil
            a.defaultValue = def
            attributes.append(a)
        }
        entity.properties = attributes
        if let a = attributes.first(where: { $0.name == "assetID" }) { indexes["assetID"] = a }
        applyIndexes(to: entity, on: indexes)
        return entity
    }
}
