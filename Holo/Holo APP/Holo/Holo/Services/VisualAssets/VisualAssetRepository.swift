//
//  VisualAssetRepository.swift
//  Holo
//
//  贴纸素材统一仓库：位置解析（02 §4.6 六步算法，禁止简化）、幂等创建、
//  删除墓碑、logicalClock 串行分配。所有模块共用这一个实现，不许各自兜底。
//
//  解析语义（与 fixtures/contract-cases.json 的 V01–V14 逐条对齐）：
//  - 同 operationID 的物理副本包络必须一致，不一致 = corrupt
//  - 包络缺必需字段（尚不完整）→ 不参与赢家排序，slot 返回 pending 只读
//  - 赢家按 (logicalClock, writerID, mutationID) 字节序取最大；changedAt 不参与
//  - 选完赢家再解码 payload：高版本 → unsupported 只读（不回退旧版）；
//    解码失败/数值越界 → corrupt
//  - clear → none；asset set 先查墓碑（deleted）再查素材（未到 = pending）；
//    record set → 日代表策略消费
//

import CoreData
import Foundation

// MARK: - 解析结果

/// 位置解析的七态（02 §4.6 第 5 步）
enum ResolvedPlacement: Equatable {
    case none
    case assetReady(VisualDescriptor)
    case recordSelected(module: String, recordID: UUID)
    /// 包络不完整（同步未到）或素材未到：只读占位，不自动写 clear
    case pending
    /// 素材被彻底删除（墓碑命中）：所有位置不可显示
    case deleted
    /// 赢家负载版本高于当前客户端：只读，禁止本 slot 编辑，防旧客户端覆盖新功能
    case unsupported(schemaVersion: Int)
    /// 数据完整性错误（同 op 包络不一致 / payload 非法）：明确诊断
    case corrupt(reason: String)
}

/// 素材值快照（02 §6.1）：不含 Data 与托管对象，供渲染层跨层传递
struct VisualDescriptor: Equatable {
    let assetID: UUID
    let winningRevisionID: UUID
    let kind: VisualAssetKind
    let presentation: VisualPlacementPayload.Presentation?
    /// 像素尺寸（照片通栏的高度由它决定；同步未到全时为 0）
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    /// 头图取自哪条正文附件（01 §6.3-6；列表不与它重复显示）
    var sourceAttachmentID: UUID? = nil
}

// MARK: - 仓库

final class VisualAssetRepository {

    static let shared = VisualAssetRepository()

    /// 本机所有 writer 的串行提交队列：读取最大 clock、创建版本、save 在同一临界区
    /// （02 §4.6 末段）。读取（resolve）不走此队列，由调用方 context 保证一致性。
    private let commitQueue = DispatchQueue(label: "holo.visual.commit")

    /// 安装级稳定 writerID（重装生成新值；不是人名/设备名）
    static let writerID: String = {
        let key = "holo.visual.writerID"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    // MARK: - 位置解析（02 §4.6）

    func resolvePlacement(ownerKind: String,
                          ownerKey rawOwnerKey: String,
                          slot: String,
                          in context: NSManagedObjectContext) -> ResolvedPlacement {
        // 实体预检：context 的模型若不含贴纸实体（如 SwiftUI 环境默认的空模型临时
        // context——2026-11-17 真机闪退实锤，entityForName 抛 ObjC 异常 try? 拦不住），
        // 语义上就是「无贴纸数据」，安静返回 none，不让渲染路径崩整个 App
        guard let entities = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName,
              entities["VisualPlacementRevision"] != nil else {
            return .none
        }
        let ownerKey = VisualPlacementCoding.normalizedOwnerKey(rawOwnerKey)
        let placementKey = VisualPlacementCoding.placementKey(ownerKind: ownerKind, ownerKey: ownerKey, slot: slot)

        let request = NSFetchRequest<VisualPlacementRevision>(entityName: "VisualPlacementRevision")
        request.predicate = NSPredicate(format: "placementKey == %@", placementKey)
        request.affectedStores = nil
        let rows: [VisualPlacementRevision]
        do { rows = try context.fetch(request) }
        catch { return .corrupt(reason: "fetch失败:\(error.localizedDescription)") }

        guard !rows.isEmpty else { return .none }

        // 1. 按 operationID 去重；同 ID 包络必须一致
        struct Envelope {
            let operationID: UUID
            let logicalClock: Int64
            let writerID: String
            let mutationID: UUID
            let payloadHash: String
            let payloadJSON: String
            let revisionObjectID: NSManagedObjectID
        }
        var byOperation: [UUID: Envelope] = [:]
        var sawIncomplete = false
        for row in rows {
            guard let opID = row.value(forKey: "operationID") as? UUID else {
                sawIncomplete = true
                continue
            }
            // 包络必需字段：任一缺失 = 尚不完整，不参与赢家排序
            guard let clock = row.value(forKey: "logicalClock") as? Int64, clock > 0,
                  let writer = row.value(forKey: "writerID") as? String, !writer.isEmpty,
                  let mutationID = row.value(forKey: "mutationID") as? UUID,
                  let payloadJSON = row.value(forKey: "payloadJSON") as? String,
                  let payloadHash = row.value(forKey: "payloadHash") as? String,
                  let revisionID = row.value(forKey: "id") as? UUID else {
                sawIncomplete = true
                continue
            }
            let envelope = Envelope(operationID: opID, logicalClock: clock, writerID: writer,
                                    mutationID: mutationID, payloadHash: payloadHash,
                                    payloadJSON: payloadJSON, revisionObjectID: row.objectID)
            if let existing = byOperation[opID] {
                // 同 op 物理副本：包络四元组必须一致；仅 changedAt 不同不影响
                if existing.logicalClock != clock || existing.writerID != writer
                    || existing.mutationID != mutationID || existing.payloadHash != payloadHash {
                    return .corrupt(reason: "同operation \(opID.uuidString) 包络不一致")
                }
                if existing.payloadJSON != payloadJSON {
                    return .corrupt(reason: "同operation \(opID.uuidString) payload内容不一致")
                }
            } else {
                byOperation[opID] = envelope
            }
        }

        // 2. 存在不完整包络 → pending 只读（不拿旧版当确定赢家开放编辑）
        if sawIncomplete { return .pending }

        guard !byOperation.isEmpty else { return .pending }

        // 3. 赢家 = (logicalClock, writerID, mutationID) 字节序最大；changedAt 不参与
        let winner = byOperation.values.max { a, b in
            if a.logicalClock != b.logicalClock { return a.logicalClock < b.logicalClock }
            if a.writerID != b.writerID { return a.writerID.utf8.lexicographicallyPrecedes(b.writerID.utf8) }
            return a.mutationID.uuidString.utf8.lexicographicallyPrecedes(b.mutationID.uuidString.utf8)
        }!

        // 4. 选完赢家再解码：高版本 unsupported（不回退）；解码失败 corrupt
        guard let payload = try? VisualPlacementCoding.decode(from: winner.payloadJSON) else {
            return .corrupt(reason: "赢家payload解码失败 op=\(winner.operationID.uuidString)")
        }
        guard payload.isSupportedByCurrentVersion else {
            return .unsupported(schemaVersion: payload.schemaVersion)
        }

        switch payload.action {
        case .clear:
            return .none
        case .set:
            guard let selection = payload.selection else {
                return .corrupt(reason: "set负载缺selection op=\(winner.operationID.uuidString)")
            }
            switch selection.type {
            case .record:
                guard let module = selection.module, let recordID = selection.recordID else {
                    return .corrupt(reason: "record选择缺module/recordID")
                }
                return .recordSelected(module: module, recordID: recordID)
            case .asset:
                guard let assetID = selection.assetID else {
                    return .corrupt(reason: "asset选择缺assetID")
                }
                // 5. asset set 先查墓碑，再查素材
                if hasTombstone(assetID: assetID, in: context) { return .deleted }
                guard let asset = fetchAsset(id: assetID, in: context) else { return .pending }
                // 6. payload 数值校验（sticker 约束等）结合素材 kind
                let kind = VisualAssetKind.from(raw: asset.value(forKey: "kind") as? String) ?? .sticker
                do {
                    try payload.validate(kind: kind)
                } catch {
                    return .corrupt(reason: "payload越界:\(error)")
                }
                guard let revisionID = try? context.existingObject(with: winner.revisionObjectID).value(forKey: "id") as? UUID else {
                    return .corrupt(reason: "赢家revision不可达")
                }
                return .assetReady(VisualDescriptor(
                    assetID: assetID,
                    winningRevisionID: revisionID,
                    kind: kind,
                    presentation: payload.presentation,
                    pixelWidth: asset.value(forKey: "sourceWidth") as? Int ?? 0,
                    pixelHeight: asset.value(forKey: "sourceHeight") as? Int ?? 0,
                    sourceAttachmentID: selection.sourceAttachmentID))
            }
        }
    }

    // MARK: - 幂等创建（02 §4.2：重复 operationID 返回原 asset）

    /// 创建（或复用已有 operationID 的）素材。物理副本 id 相同且 hash 一致可去重；
    /// id 相同 hash 不同 = 完整性错误。
    func createAssetIfNeeded(operationID: UUID,
                             kind: VisualAssetKind,
                             assign: (VisualAsset) -> Void,
                             in context: NSManagedObjectContext) throws -> VisualAsset {
        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "creationOperationID == %@", operationID as CVarArg)
        request.fetchLimit = 2
        let existing = try context.fetch(request)
        if let first = existing.first {
            if existing.count > 1 {
                // 物理副本：id 与 hash 必须一致
                let id0 = first.value(forKey: "id") as? UUID
                let hash0 = first.value(forKey: "contentHash") as? String
                for dup in existing.dropFirst() {
                    if dup.value(forKey: "id") as? UUID != id0 || dup.value(forKey: "contentHash") as? String != hash0 {
                        throw VisualRepositoryError.duplicateOperationInconsistent
                    }
                }
            }
            return first
        }
        let asset = VisualAsset(context: context)
        asset.setValue(UUID(), forKey: "id")
        asset.setValue(operationID, forKey: "creationOperationID")
        asset.setValue(kind.rawValue, forKey: "kind")
        asset.setValue(Date(), forKey: "createdAt")
        asset.setValue(Date(), forKey: "metadataUpdatedAt")
        asset.setValue("visible", forKey: "libraryVisibility")
        assign(asset)
        return asset
    }

    /// 写一条位置版本（在 commitQueue 临界区内分配 clock + save）
    func commitRevision(operationID: UUID,
                        ownerKind: String,
                        ownerKey rawOwnerKey: String,
                        slot: String,
                        payload: VisualPlacementPayload,
                        in context: NSManagedObjectContext) throws -> VisualPlacementRevision {
        var thrown: Error?
        var created: VisualPlacementRevision?
        performCommitLocked {
            do {
                created = try commitRevisionLocked(operationID: operationID, ownerKind: ownerKind,
                                                   ownerKey: rawOwnerKey, slot: slot,
                                                   payload: payload, in: context)
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
        return created!
    }

    /// 供协调器把「建素材 + 版本 + save」整体包进同一把串行锁（sync 不可重入，内部版不加锁）
    func performCommitLocked<T>(_ body: () throws -> T) rethrows -> T {
        try commitQueue.sync(execute: body)
    }

    /// 异步版串行锁（commitQueue.async），避免在 @MainActor 上同步阻塞主线程
    func performCommitLockedAsync(_ body: @escaping () -> Void) {
        commitQueue.async { body() }
    }

    /// 按素材 id 精确查询（导入端复用判定）
    func findAsset(byID id: UUID, in context: NSManagedObjectContext) -> VisualAsset? {
        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// findAsset(byCreationOperation:)：幂等创建的查询面
    func findAsset(byCreationOperation operationID: UUID, in context: NSManagedObjectContext) throws -> VisualAsset? {
        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "creationOperationID == %@", operationID as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// 无锁版：调用方必须已持有 commitQueue（协调器路径）
    func commitRevisionLocked(operationID: UUID,
                                      ownerKind: String,
                                      ownerKey rawOwnerKey: String,
                                      slot: String,
                                      payload: VisualPlacementPayload,
                                      in context: NSManagedObjectContext) throws -> VisualPlacementRevision {
        let revision = try stageRevisionLocked(operationID: operationID, ownerKind: ownerKind, ownerKey: rawOwnerKey,
                                               slot: slot, payload: payload, in: context)
        if context.hasChanges { try context.save() }
        return revision
    }

    /// 在提交锁内暂存位置版本，供绑定对象与贴纸位置一次保存。
    @discardableResult
    func stageRevisionLocked(operationID: UUID,
                             ownerKind: String,
                             ownerKey rawOwnerKey: String,
                             slot: String,
                             payload: VisualPlacementPayload,
                             in context: NSManagedObjectContext) throws -> VisualPlacementRevision {
        let ownerKey = VisualPlacementCoding.normalizedOwnerKey(rawOwnerKey)
        let placementKey = VisualPlacementCoding.placementKey(ownerKind: ownerKind, ownerKey: ownerKey, slot: slot)
        let canonical = try VisualPlacementCoding.canonicalData(payload)
        let hash = try VisualPlacementCoding.hash(of: payload)

        let next = maxClock(placementKey: placementKey, in: context) + 1
        let revision = VisualPlacementRevision(context: context)
        revision.setValue(UUID(), forKey: "id")
        revision.setValue(operationID, forKey: "operationID")
        revision.setValue(operationID, forKey: "mutationID")
        revision.setValue(ownerKind, forKey: "ownerKind")
        revision.setValue(ownerKey, forKey: "ownerKey")
        revision.setValue(slot, forKey: "slot")
        revision.setValue(placementKey, forKey: "placementKey")
        revision.setValue(next, forKey: "logicalClock")
        revision.setValue(Self.writerID, forKey: "writerID")
        revision.setValue(String(data: canonical, encoding: .utf8), forKey: "payloadJSON")
        revision.setValue(hash, forKey: "payloadHash")
        revision.setValue(Date(), forKey: "changedAt")
        return revision
    }

    /// 写入删除墓碑（只追加；二段删除的第一段：墓碑 + 清 Binary 由调用方同事务完成）
    @discardableResult
    func writeTombstone(operationID: UUID, assetID: UUID,
                        in context: NSManagedObjectContext) throws -> VisualAssetTombstone {
        let tomb = VisualAssetTombstone(context: context)
        tomb.setValue(UUID(), forKey: "id")
        tomb.setValue(operationID, forKey: "operationID")
        tomb.setValue(assetID, forKey: "assetID")
        tomb.setValue(Date(), forKey: "deletedAt")
        tomb.setValue(1, forKey: "schemaVersion")
        return tomb
    }

    func hasTombstone(assetID: UUID, in context: NSManagedObjectContext) -> Bool {
        let request = NSFetchRequest<VisualAssetTombstone>(entityName: "VisualAssetTombstone")
        request.predicate = NSPredicate(format: "assetID == %@", assetID as CVarArg)
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    // MARK: - 私有

    private func fetchAsset(id: UUID, in context: NSManagedObjectContext) -> VisualAsset? {
        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func maxClock(placementKey: String, in context: NSManagedObjectContext) -> Int64 {
        let request = NSFetchRequest<VisualPlacementRevision>(entityName: "VisualPlacementRevision")
        request.predicate = NSPredicate(format: "placementKey == %@", placementKey)
        var max: Int64 = 0
        if let rows = try? context.fetch(request) {
            for row in rows {
                if let clock = row.value(forKey: "logicalClock") as? Int64, clock > max { max = clock }
            }
        }
        return max
    }
}

enum VisualRepositoryError: Error, Equatable {
    /// 同 operationID 的物理副本 id/hash 不一致：完整性错误，不能按顺序任取
    case duplicateOperationInconsistent
}
