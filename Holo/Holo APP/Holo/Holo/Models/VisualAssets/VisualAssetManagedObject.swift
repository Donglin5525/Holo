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
import Foundation

@objc(VisualAsset)
final class VisualAsset: NSManagedObject {}
extension VisualAsset: Identifiable {}

@objc(VisualPlacementRevision)
final class VisualPlacementRevision: NSManagedObject {}

@objc(VisualAssetTombstone)
final class VisualAssetTombstone: NSManagedObject {}

// MARK: - 资产级扩展元数据（存 transformJSON，零 Core Data Schema 改动、CloudKit 自动同步）

struct VisualAssetMetadata: Codable, Equatable {
    var groupName: String? = nil
    var defaultBorderStyle: String? = nil
    var defaultBorderWeight: String? = nil

    var resolvedBorderStyle: VisualPlacementPayload.Presentation.BorderStyle? {
        defaultBorderStyle.flatMap(VisualPlacementPayload.Presentation.BorderStyle.init(rawValue:))
    }

    var resolvedBorderWeight: VisualPlacementPayload.Presentation.BorderWeight? {
        defaultBorderWeight.flatMap(VisualPlacementPayload.Presentation.BorderWeight.init(rawValue:))
    }

    static func decode(from json: String?) -> VisualAssetMetadata {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(VisualAssetMetadata.self, from: data) else {
            return VisualAssetMetadata()
        }
        return decoded
    }

    func encodeToJSON() -> String? {
        guard groupName != nil || defaultBorderStyle != nil || defaultBorderWeight != nil else { return nil }
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension VisualAsset {
    var visualMetadata: VisualAssetMetadata {
        get { VisualAssetMetadata.decode(from: value(forKey: "transformJSON") as? String) }
        set { setValue(newValue.encodeToJSON(), forKey: "transformJSON") }
    }

    var groupName: String? {
        get {
            let raw = visualMetadata.groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
        }
        set {
            var meta = visualMetadata
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            meta.groupName = (trimmed?.isEmpty == false) ? trimmed : nil
            visualMetadata = meta
        }
    }

    /// 资产级默认纸边设置（无自定义时返回 nil，走渲染默认）
    var defaultPresentation: VisualPlacementPayload.Presentation? {
        let meta = visualMetadata
        guard meta.resolvedBorderStyle != nil || meta.resolvedBorderWeight != nil else { return nil }
        return VisualPlacementPayload.Presentation(
            borderStyle: meta.resolvedBorderStyle ?? .adaptivePaper,
            borderWeight: meta.resolvedBorderWeight ?? .standard)
    }

    /// 统一默认命名：displayName 优先；空则「贴纸 MMdd」
    var resolvedDisplayName: String {
        if let name = value(forKey: "displayName") as? String, !name.isEmpty {
            return name
        }
        if let created = value(forKey: "createdAt") as? Date {
            return "贴纸 \(Self.defaultNameFormatter.string(from: created))"
        }
        return String(localized: "贴纸")
    }

    private static let defaultNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMdd"
        return f
    }()
}
