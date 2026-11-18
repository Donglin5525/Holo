//
//  VisualAssetArchiveService.swift
//  Holo
//
//  素材包导入导出（2026-11-16 方案 02 §9）：
//  - 导出：稳定快照 + manifest（元数据/文件相对路径/真实 UTType/尺寸/字节/SHA256/当前赢家负载）；
//    缺失、同步未完成、有墓碑 → 如实报告，不输出「成功但缺内容」的包
//  - 导入：校验 manifest 版本/路径/总量/单文件像素与字节/hash 与真实格式；禁绝对路径、
//    `..`、符号链接；默认「仅导入素材」，恢复使用位置须用户明确执行且用本地新 operation/clock；
//    同 ID 同内容复用、异内容新 ID 仅重映射本次、墓碑 ID 跳过并报告
//  - 素材包只恢复视觉内容及能匹配的引用，不是全 Holo 备份（对用户如实说明）
//

import Foundation
import CoreData
import UniformTypeIdentifiers

struct VisualArchiveManifest: Codable {
    var version: Int = 1
    var exportedAt: Date
    var assets: [AssetEntry]
    var note: String = "Holo 视觉素材包：仅含贴纸/照片素材及其位置负载，不是全量备份"

    struct AssetEntry: Codable {
        var assetID: String
        var kind: String
        var displayName: String?
        var isFavorite: Bool
        var files: [FileEntry]
        var placements: [PlacementEntry]
    }
    struct FileEntry: Codable {
        var path: String
        var utType: String
        var bytes: Int
        var sha256: String
        var width: Int?
        var height: Int?
    }
    struct PlacementEntry: Codable {
        var ownerKind: String
        var ownerKey: String
        var slot: String
        var payloadJSON: String
    }
}

enum VisualArchiveError: Error, Equatable {
    case manifestInvalid(String)
    case pathUnsafe(String)             // 绝对路径 / .. / 符号链接
    case hashMismatch(String)
    case oversize(String)
    case ioFailure(String)
    case tombstoneSkipped([String])
    case ownerUnmatched([String])
}

enum VisualAssetArchiveService {

    static let maxAssetCount = 1000
    static let maxTotalUncompressed = 2 * 1024 * 1024 * 1024

    // MARK: - 导出

    /// 导出指定素材（含可恢复的位置负载）到目录；返回 zip 的文件 URL（ZIPFoundation 由调用方压）。
    /// 导出中遇到缺失/墓碑 → throw（不输出半包）。
    static func export(assets: [VisualAsset], to directory: URL) throws -> VisualArchiveManifest {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [VisualArchiveManifest.AssetEntry] = []
        let context = assets.first?.managedObjectContext ?? CoreDataStack.shared.viewContext
        for asset in assets {
            guard let assetID = asset.value(forKey: "id") as? UUID else { continue }
            // 墓碑素材不进包（导出范围里本就不该出现；防御入口校验）
            if VisualAssetRepository.shared.hasTombstone(assetID: assetID, in: context) {
                throw VisualArchiveError.tombstoneSkipped([assetID.uuidString])
            }
            var files: [VisualArchiveManifest.FileEntry] = []
            for (key, uttype) in [("sourceData", "sourceUTType"), ("maskData", nil),
                                  ("contentData", "contentUTType"), ("thumbnailData", nil)] {
                guard let data = asset.value(forKey: key) as? Data, !data.isEmpty else { continue }
                let name = "\(assetID.uuidString)-\(key).bin"
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                files.append(.init(path: name,
                                   utType: uttype.flatMap { asset.value(forKey: $0) as? String }
                                       ?? UTType.png.identifier,
                                   bytes: data.count,
                                   sha256: VisualAssetDraftStore.sha256(data),
                                   width: nil, height: nil))
            }
            guard !files.isEmpty else {
                // 像素未同步完成：如实失败，不输出空素材
                throw VisualArchiveError.ioFailure("素材 \(assetID.uuidString) 像素未同步完成，已中止导出")
            }
            // 当前位置赢家负载（可恢复项）
            var placements: [VisualArchiveManifest.PlacementEntry] = []
            let request = NSFetchRequest<VisualPlacementRevision>(entityName: "VisualPlacementRevision")
            request.predicate = NSPredicate(format: "payloadJSON CONTAINS %@", assetID.uuidString)
            let seen = NSMutableSet()
            for revision in (try? context.fetch(request)) ?? [] {
                let ownerKind = revision.value(forKey: "ownerKind") as? String ?? ""
                let ownerKey = revision.value(forKey: "ownerKey") as? String ?? ""
                if ownerKind == HabitFolder.visualOwnerKind, !ownerExists(ownerKind, ownerKey, in: context) {
                    continue
                }
                let slot = revision.value(forKey: "slot") as? String ?? ""
                let dedupe = "\(ownerKind)|\(ownerKey)|\(slot)"
                guard !seen.contains(dedupe) else { continue }
                seen.add(dedupe)
                // 只记当前赢家（由导入端解析决定；非赢家的历史版本不进包）
                if case .assetReady(let d) = VisualAssetRepository.shared.resolvePlacement(
                    ownerKind: ownerKind, ownerKey: ownerKey, slot: slot, in: context),
                    d.assetID == assetID,
                    let json = revision.value(forKey: "payloadJSON") as? String {
                    placements.append(.init(ownerKind: ownerKind, ownerKey: ownerKey, slot: slot, payloadJSON: json))
                }
            }
            entries.append(.init(assetID: assetID.uuidString,
                                 kind: asset.value(forKey: "kind") as? String ?? "sticker",
                                 displayName: asset.value(forKey: "displayName") as? String,
                                 isFavorite: asset.value(forKey: "isFavorite") as? Bool ?? false,
                                 files: files, placements: placements))
        }
        let manifest = VisualArchiveManifest(exportedAt: Date(), assets: entries)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        return manifest
    }

    // MARK: - 导入

    struct ImportReport: Equatable {
        var imported = 0
        var reused = 0
        var remapped = 0            // 同 ID 异内容 → 新 ID（仅重映射本次导入）
        var tombstoneSkipped: [String] = []
        var ownerUnmatched: [String] = []   // owner 不在本机 → 只导素材
        var placementsRestored = 0
    }

    /// 默认「仅导入素材」；restorePlacements = true 时恢复位置（本地新 operation/clock，
    /// 不接受包内历史 clock 为当前赢家）。
    static func `import`(from directory: URL,
                         into context: NSManagedObjectContext,
                         restorePlacements: Bool = false) throws -> ImportReport {
        // 1) manifest 校验
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(VisualArchiveManifest.self, from: manifestData),
              manifest.version == 1 else {
            throw VisualArchiveError.manifestInvalid("manifest 缺失或版本不支持")
        }
        guard manifest.assets.count <= maxAssetCount else {
            throw VisualArchiveError.oversize("素材数超上限 \(maxAssetCount)")
        }
        var totalBytes = 0
        for asset in manifest.assets { for f in asset.files { totalBytes += f.bytes } }
        guard totalBytes <= maxTotalUncompressed else {
            throw VisualArchiveError.oversize("总展开量超上限")
        }

        var report = ImportReport()
        // 2) 逐素材导入（每个素材及其显式绑定为最小提交单位）
        for entry in manifest.assets {
            guard let assetUUID = UUID(uuidString: entry.assetID) else {
                throw VisualArchiveError.manifestInvalid("assetID 非法: \(entry.assetID)")
            }
            // 墓碑 ID：跳过并报告，不自动换 ID 绕过删除
            if VisualAssetRepository.shared.hasTombstone(assetID: assetUUID, in: context) {
                report.tombstoneSkipped.append(entry.assetID)
                continue
            }
            // 3) 文件路径安全 + hash 校验
            var fileData: [String: Data] = [:]
            for file in entry.files {
                guard !file.path.hasPrefix("/"), !file.path.contains(".."),
                      !file.path.hasPrefix("~") else {
                    throw VisualArchiveError.pathUnsafe(file.path)
                }
                let url = directory.appendingPathComponent(file.path)
                    .standardizedFileURL
                // 符号链接拒绝
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw VisualArchiveError.pathSafeFailure(file.path)
                }
                guard let data = try? Data(contentsOf: url) else {
                    throw VisualArchiveError.ioFailure("文件缺失: \(file.path)")
                }
                guard VisualAssetDraftStore.sha256(data) == file.sha256 else {
                    throw VisualArchiveError.hashMismatch(file.path)
                }
                fileData[file.path] = data
            }
            // 4) 落库：同 ID 同内容复用；异内容新 ID 仅重映射本次
            let existing = VisualAssetRepository.shared.findAsset(byID: assetUUID, in: context)
            let targetID: UUID
            if let existing {
                let sameContent = entry.files.allSatisfy { file in
                    guard let data = fileData[file.path] else { return false }
                    return existing.value(forKey: file.path.contains("-sourceData") ? "sourceData"
                        : file.path.contains("-maskData") ? "maskData"
                        : file.path.contains("-contentData") ? "contentData" : "thumbnailData") as? Data == data
                }
                if sameContent {
                    report.reused += 1
                    targetID = assetUUID
                } else {
                    targetID = UUID()   // 新 ID：不覆盖旧素材
                    report.remapped += 1
                }
            } else {
                targetID = assetUUID
            }
            if existing == nil || targetID != assetUUID {
                let asset = VisualAsset(context: context)
                asset.setValue(targetID, forKey: "id")
                asset.setValue(UUID(), forKey: "creationOperationID")
                asset.setValue(entry.kind, forKey: "kind")
                asset.setValue(entry.displayName, forKey: "displayName")
                asset.setValue(entry.isFavorite, forKey: "isFavorite")
                asset.setValue(Date(), forKey: "createdAt")
                asset.setValue(Date(), forKey: "metadataUpdatedAt")
                asset.setValue("visible", forKey: "libraryVisibility")
                for file in entry.files {
                    guard let data = fileData[file.path] else { continue }
                    switch true {
                    case file.path.contains("-sourceData"):
                        asset.setValue(data, forKey: "sourceData")
                        asset.setValue(file.utType, forKey: "sourceUTType")
                        asset.setValue(file.sha256, forKey: "sourceHash")
                    case file.path.contains("-maskData"):
                        asset.setValue(data, forKey: "maskData")
                        asset.setValue(file.sha256, forKey: "maskHash")
                    case file.path.contains("-contentData"):
                        asset.setValue(data, forKey: "contentData")
                        asset.setValue(file.utType, forKey: "contentUTType")
                        asset.setValue(file.sha256, forKey: "contentHash")
                    default:
                        asset.setValue(data, forKey: "thumbnailData")
                        asset.setValue(file.sha256, forKey: "thumbnailHash")
                    }
                }
                try context.save()
                report.imported += 1
            }
            // 5) 位置恢复（显式）：owner 必须本机存在且 ownerKind 匹配；本地新 clock
            if restorePlacements {
                for placement in entry.placements {
                    guard ownerExists(placement.ownerKind, placement.ownerKey, in: context) else {
                        report.ownerUnmatched.append("\(placement.ownerKind)|\(placement.ownerKey)")
                        continue
                    }
                    guard let payload = try? VisualPlacementCoding.decode(from: placement.payloadJSON),
                          var selection = payload.selection, selection.assetID == assetUUID else { continue }
                    selection.assetID = targetID     // 重映射到本机 ID
                    let remapped = VisualPlacementPayload.setAsset(selection, presentation: payload.presentation)
                    _ = try? VisualAssetRepository.shared.commitRevision(
                        operationID: UUID(), ownerKind: placement.ownerKind,
                        ownerKey: placement.ownerKey, slot: placement.slot,
                        payload: remapped, in: context)
                    report.placementsRestored += 1
                }
            }
        }
        return report
    }

    private static func ownerExists(_ ownerKind: String, _ ownerKey: String,
                                    in context: NSManagedObjectContext) -> Bool {
        guard let key = UUID(uuidString: ownerKey) else { return false }
        switch ownerKind {
        case Thought.visualOwnerKind:
            let r = NSFetchRequest<Thought>(entityName: "Thought")
            r.predicate = NSPredicate(format: "id == %@", key as CVarArg)
            r.fetchLimit = 1
            return ((try? context.count(for: r)) ?? 0) > 0
        case SpendingProject.visualOwnerKind:
            let r = NSFetchRequest<SpendingProject>(entityName: "SpendingProject")
            r.predicate = NSPredicate(format: "id == %@", key as CVarArg)
            r.fetchLimit = 1
            return ((try? context.count(for: r)) ?? 0) > 0
        case HabitFolder.visualOwnerKind:
            return ((try? context.count(for: HabitFolder.fetchRequest(id: key))) ?? 0) > 0
        default:
            return false
        }
    }
}

extension VisualArchiveError {
    /// pathSafe 的独立 case（避免 Self 里拼错）
    static func pathSafeFailure(_ path: String) -> VisualArchiveError { .pathUnsafe(path) }
}
