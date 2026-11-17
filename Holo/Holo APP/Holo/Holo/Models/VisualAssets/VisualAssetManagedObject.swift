//
//  VisualAssetManagedObject.swift
//  Holo
//
//  贴纸与视觉素材三实体的 NSManagedObject 子类绑定。
//  实体描述在 CoreDataStack+VisualAssetEntities.swift 程序化构造（纯加表）；
//  属性全 optional 或静态默认值（CloudKit 建模约束：不得把建模时生成的
//  UUID()/Date() 当默认值），必需值由仓库层显式赋值并在读取时验证。
//

import CoreData

@objc(VisualAsset)
final class VisualAsset: NSManagedObject {}
extension VisualAsset: Identifiable {}

@objc(VisualPlacementRevision)
final class VisualPlacementRevision: NSManagedObject {}

@objc(VisualAssetTombstone)
final class VisualAssetTombstone: NSManagedObject {}
