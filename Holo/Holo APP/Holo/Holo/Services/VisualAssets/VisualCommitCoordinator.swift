//
//  VisualCommitCoordinator.swift
//  Holo
//
//  纯视觉提交的事务协调（2026-11-16 方案 02 §5.1）：新素材 + 位置版本 + 业务变更
//  在同一个专用 background context 的一次 save 里落地——不能「共享 viewContext 改
//  正文、独立 save 素材」然后宣布整体成功。
//  - 基线检查：expectedSlotWinnerID 不匹配 → conflict，保留草稿不静默覆盖
//  - 幂等：同 operationID 已有 revision → 直接返回既有回执（save 后被杀的重启路径）
//  - 禁止对共享 viewContext 全量 rollback；专用 context 失败只回滚自身
//  - 成功后 merge 到 viewContext 并发 .visualAssetsDidChange（02 §6.2）
//

import CoreData
import Foundation

struct VisualCommitReceipt: Equatable {
    let operationID: UUID
    let ownerKey: String
    let assetID: UUID?
    let revisionID: UUID
}

enum VisualCommitCommand {
    /// 纯视觉应用（素材已在库：固定支出图标、已有素材设头图等）
    case applyPlacement(operationID: UUID,
                        ownerKind: String, ownerKey: String, slot: String,
                        expectedSlotWinnerRevisionID: UUID?,
                        payload: VisualPlacementPayload)
    /// 制作新素材 + 首次应用（同一事务）
    case createAssetAndApply(operationID: UUID,
                             ownerKind: String, ownerKey: String, slot: String,
                             expectedSlotWinnerRevisionID: UUID?,
                             payload: VisualPlacementPayload,
                             assignAsset: (VisualAsset) -> Void)
    /// 只创建素材（存入素材库，暂不用于任何位置）
    case createAssetOnly(operationID: UUID,
                         assignAsset: (VisualAsset) -> Void)
}

enum VisualCommitError: Error, Equatable {
    /// slot 赢家已变（他端/他处在本次编辑期间提交过）：保留草稿，加载最新后让用户重新应用
    case conflict(currentWinnerRevisionID: UUID)
    /// owner 不存在或不可编辑
    case ownerUnavailable
}

extension Notification.Name {
    /// 纯视觉变更通知：值负载 scopeGeneration/operationIDs/affectedOwnerKeys/assetIDs/changeKind（02 §6.2）
    static let visualAssetsDidChange = Notification.Name("holo.visualAssetsDidChange")
}

final class VisualCommitCoordinator {

    static let shared = VisualCommitCoordinator()

    private let repo = VisualAssetRepository.shared

    /// scopeGeneration：账号/store 切换时 +1；在途任务与草稿绑定它，迟到结果跨 scope 全部失效（02 §3.6）
    private(set) var scopeGeneration: Int = 0

    func rotateScope() {
        scopeGeneration += 1
        VisualRenderCache.removeAll()
    }

    /// 提交入口（在专用串行队列上执行；02 §4.6 末段——clock 分配与 save 同临界区）
    func commit(_ command: VisualCommitCommand,
                in container: NSPersistentContainer) async throws -> VisualCommitReceipt {
        let generation = scopeGeneration
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return try await withCheckedThrowingContinuation { cont in
            VisualAssetRepository.shared.performCommitLockedAsync {
                var receipt: VisualCommitReceipt?
                var failure: Error?
                context.performAndWait {
                    do {
                        receipt = try Self.execute(command, generation: generation, repo: self.repo, context: context)
                    } catch {
                        failure = error
                    }
                }
                if let failure {
                    cont.resume(throwing: failure)
                } else if let receipt {
                    cont.resume(returning: receipt)
                }
            }
        }
    }

    // MARK: - 事务体

    private static func execute(_ command: VisualCommitCommand,
                                generation: Int,
                                repo: VisualAssetRepository,
                                context: NSManagedObjectContext) throws -> VisualCommitReceipt {
        switch command {
        case let .createAssetOnly(operationID, assignAsset):
            // 幂等：同 operation 已有素材 → 返回其 id（不重复创建、不重复 assign）
            let existing = try repo.findAsset(byCreationOperation: operationID, in: context)
            let assetID: UUID
            if let existing {
                assetID = existing.value(forKey: "id") as! UUID
            } else {
                let asset = try repo.createAssetIfNeeded(operationID: operationID, kind: .sticker,
                                                         assign: assignAsset, in: context)
                assetID = asset.value(forKey: "id") as! UUID
            }
            if context.hasChanges { try context.save() }
            postChange(generation: generation, operationID: operationID, assetIDs: [assetID],
                       ownerKeys: [])
            return VisualCommitReceipt(operationID: operationID, ownerKey: "",
                                       assetID: assetID, revisionID: operationID)

        case let .applyPlacement(operationID, ownerKind, ownerKey, slot, expectedWinner, payload):
            let result = try applyCommon(repo: repo, generation: generation, context: context, ownerKind: ownerKind,
                                          ownerKey: ownerKey, slot: slot, expectedWinner: expectedWinner,
                                          payload: payload, makeAsset: nil, operationID: operationID)
            return VisualCommitReceipt(operationID: operationID, ownerKey: ownerKey,
                                       assetID: result.assetID, revisionID: result.revisionID)

        case let .createAssetAndApply(operationID, ownerKind, ownerKey, slot, expectedWinner, payload, assignAsset):
            let result = try applyCommon(repo: repo, generation: generation, context: context, ownerKind: ownerKind,
                                          ownerKey: ownerKey, slot: slot, expectedWinner: expectedWinner,
                                          payload: payload, makeAsset: assignAsset, operationID: operationID)
            return VisualCommitReceipt(operationID: operationID, ownerKey: ownerKey,
                                       assetID: result.assetID, revisionID: result.revisionID)
        }
    }

    /// applyPlacement / createAssetAndApply 的公共事务体
    private static func applyCommon(repo: VisualAssetRepository,
                                    generation: Int,
                                    context: NSManagedObjectContext,
                                    ownerKind: String, ownerKey: String, slot: String,
                                    expectedWinner: UUID?,
                                    payload: VisualPlacementPayload,
                                    makeAsset: ((VisualAsset) -> Void)?,
                                    operationID: UUID) throws -> (assetID: UUID?, revisionID: UUID) {
        // slot 基线检查：当前赢家与调用方所见一致才写（02 §5.1 步骤 2）
        if case .set = payload.action, payload.selection?.type == .asset {
            let current = repo.resolvePlacement(ownerKind: ownerKind, ownerKey: ownerKey, slot: slot, in: context)
            let currentWinnerID: UUID?
            switch current {
            case .assetReady(let d): currentWinnerID = d.winningRevisionID
            default: currentWinnerID = nil
            }
            if currentWinnerID != expectedWinner {
                throw VisualCommitError.conflict(currentWinnerRevisionID: currentWinnerID ?? UUID())
            }
        }
        // 建素材（createAssetAndApply 才有）+ 位置版本：同一次 save。
        // 制作页构造 payload 时素材尚未创建（带占位 assetID）——这里重映射为真实 ID，
        // 否则位置记录指向不存在的素材，读取端永远 pending（11-17 东林实报「没生效」根因）
        var assetID: UUID?
        var payload = payload
        if let makeAsset {
            let asset = try repo.createAssetIfNeeded(operationID: operationID, kind: .sticker,
                                                     assign: makeAsset, in: context)
            assetID = asset.value(forKey: "id") as? UUID
            if let realID = assetID,
               var selection = payload.selection, selection.type == .asset,
               selection.assetID != realID {
                selection.assetID = realID
                payload = VisualPlacementPayload.setAsset(selection, presentation: payload.presentation)
            }
        }
        let revision = try repo.commitRevisionLocked(operationID: operationID, ownerKind: ownerKind,
                                                     ownerKey: ownerKey, slot: slot, payload: payload,
                                                     in: context)
        let revisionID = revision.value(forKey: "id") as! UUID
        postChange(generation: generation, operationID: operationID,
                   assetIDs: assetID.map { [$0] } ?? [],
                   ownerKeys: [VisualPlacementCoding.placementKey(ownerKind: ownerKind,
                                                                  ownerKey: ownerKey, slot: slot)])
        return (assetID, revisionID)
    }

    private static func postChange(generation: Int, operationID: UUID, assetIDs: [UUID],
                                   ownerKeys: [String]) {
        let payload: [String: Any] = [
            "scopeGeneration": generation,
            "operationIDs": [operationID.uuidString],
            "affectedOwnerKeys": ownerKeys,
            "assetIDs": assetIDs.map(\.uuidString),
            "changeKind": "commit",
        ]
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .visualAssetsDidChange, object: nil, userInfo: payload)
        }
    }
}
