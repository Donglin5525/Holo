//
//  HoloMemoryRuntime.swift
//  Holo
//
//  App 运行时共享的统一记忆 Repository 与一次性迁移入口
//

import Foundation
import OSLog

@MainActor
final class HoloMemoryRuntime {
    static let shared = HoloMemoryRuntime()

    private let logger = Logger(subsystem: "com.holo.app", category: "MemoryRuntime")
    private var cachedRepository: CoreDataHoloMemoryRepository?
    private var cachedController: HoloMemoryPersistenceController?

    /// 仓库背后的持久化控制器（控制事件账本等需直连容器的组件共用同一实例）。
    func persistenceController() async throws -> HoloMemoryPersistenceController {
        _ = try await repository()
        return cachedController!
    }

    /// 敏感字段目录（加密实体正文等）的统一落点
    private static var memoryDirectoryURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Holo/Memory", isDirectory: true)
    }

    func repository() async throws -> CoreDataHoloMemoryRepository {
        if let cachedRepository { return cachedRepository }

        #if DEBUG
        if let validation = HoloMemorySimulatorValidationEnvironment.current {
            try validation.prepareDirectories()
            let controller = try HoloMemoryPersistenceController(
                directoryURL: validation.storeDirectoryURL
            )
            let repository = CoreDataHoloMemoryRepository(controller: controller)
            cachedRepository = repository
            cachedController = controller
            return repository
        }
        #endif

        await CoreDataStack.shared.waitUntilReady()

        let controller = try HoloMemoryPersistenceController(
            mainContainer: CoreDataStack.shared.persistentContainer,
            sensitiveDirectoryURL: Self.memoryDirectoryURL
        )
        let repository = CoreDataHoloMemoryRepository(controller: controller)
        cachedRepository = repository
        cachedController = controller
        return repository
    }

    func migrateLegacyMemoryIfNeeded() async {
        #if DEBUG
        guard HoloMemorySimulatorValidationEnvironment.current == nil else { return }
        #endif
        let stateStore = UserDefaultsHoloMemoryMigrationStateStore()
        guard stateStore.completedVersion < HoloMemoryMigrationService.currentVersion else { return }

        do {
            let repository = try await repository()
            let memoryDirectory = Self.memoryDirectoryURL
            #if DEBUG
            let allowDestructiveRerun = true
            #else
            let allowDestructiveRerun = false
            #endif
            let service = HoloMemoryMigrationService(
                repository: repository,
                stateStore: stateStore,
                journalURL: memoryDirectory.appendingPathComponent("memory-v4-migration-journal.json"),
                allowDestructiveRerun: allowDestructiveRerun
            )
            let snapshot = HoloLegacyMemorySnapshot(
                longTermMemories: HoloLongTermMemoryStore.load(),
                episodicMemories: HoloEpisodicMemoryStore.shared.load(),
                suppressionRules: HoloEpisodicMemoryStore.shared.loadSuppressionRules()
            )
            let preview = try service.dryRun(snapshot: snapshot)
            let result = try await service.commit(preview)
            logger.info("统一记忆迁移完成：\(String(describing: result), privacy: .public)")
            if case .committed = result {
                let historicalIDs = try await repository.query(.all).filter {
                    $0.adoptionMetadata?.disposition == .historicalMigration
                }.map(\.id)
                if !historicalIDs.isEmpty {
                    HoloMemoryReceiptStore.record(
                        kind: .write,
                        channel: .insight,
                        memoryIDs: historicalIDs,
                        message: "已按新的记忆方式整理原有内容",
                        adoptionKind: .historicalMigration,
                        batchKey: "memory-migration-v\(HoloMemoryMigrationService.currentVersion)"
                    )
                }
            }
        } catch {
            // 迁移失败保留旧 Store 和 journal，下次启动重试，不影响主业务。
            logger.error("统一记忆迁移失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 激活策略升级后重评估存量待确认记忆（每个策略版本执行一次）。
    func reconcilePendingCandidatesIfNeeded() async {
        #if DEBUG
        guard HoloMemorySimulatorValidationEnvironment.current == nil else { return }
        #endif
        do {
            let repository = try await repository()
            // 存量重建迁移（2026-10-09 修复批）：先于重评估执行，一次性退役
            // 域归属缺陷时代的个人情境/跨域记忆并清空萃取游标，触发全量重萃取。
            let cursorKeys = HoloLifeSourceObservation.domains.map {
                HoloPersonalContextRuntimeWriter.cursorKey(domain: $0)
            }
            let rebuildResult = try await HoloPersonalContextRebuildMigration.rebuildIfNeeded(
                repository: repository,
                defaults: .standard,
                cursorKeys: cursorKeys,
                schedulingKeys: [HoloPersonalContextExtractionJob.roundRobinKey]
            )
            if let rebuildResult {
                logger.info("个人情境存量重建迁移：归档 \(rebuildResult.archivedRecordCount) 条，保留用户已表态 \(rebuildResult.preservedUserDecidedCount) 条，游标已重置")
            }
            _ = try await HoloMemoryCandidateReconciler.reconcileIfNeeded(repository: repository)
        } catch {
            // 重评估失败不影响主业务，下次启动重试。
            logger.error("待确认记忆重评估失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 通用知识（v2.2）

    private var knowledgeInvalidationStarted = false

    /// 存量分流迁移（§7.3）：幂等收据/断点续跑；失败下次启动重试，不阻断主业务。
    /// 迁移引擎在统一写入开放前就位——收据在知识操作表中，换设备/晚到旧写入按收据对账。
    func migrateKnowledgeIfNeeded() async {
        #if DEBUG
        guard HoloMemorySimulatorValidationEnvironment.current == nil else { return }
        #endif
        do {
            let repository = try await repository()
            // 单批 400：大存量设备（数千条）一批迁不完，旧实现每次启动只跑一批且忽略
            // hasMore——期间统一门闸把未迁移记录挡在所有 active 查询外，用户看着像
            // 「记忆变少了」。hasMore 时本轮继续吃批，上限 20 批（8000 条/启动）
            // 防极端存量无限占用启动窗口；仍未吃完下次启动续跑（收据/断点幂等）
            let engine = HoloKnowledgeMigrationEngine(repository: repository)
            var batches = 0
            while true {
                let report = try await engine.run()
                batches += 1
                logger.info(
                    "知识迁移批次\(batches)：扫描 \(report.scanned) 提交 \(report.committed) 受限 \(report.restricted) 退出 \(report.exited) 阻断 \(report.blocked) 已处理 \(report.alreadyProcessed) 续跑 \(report.hasMore)"
                )
                if !report.hasMore || batches >= 20 { break }
            }
            // 遗忘清除补跑（09-R08）：forget 操作已落库但清除中断的命题在此续清。
            let pendingPurge = try await repository.pendingForgetPurgePropositionIDs()
            for propositionID in pendingPurge {
                do {
                    try await repository.purgeKnowledgeProposition(propositionID: propositionID, now: Date())
                } catch {
                    logger.error("遗忘清除补跑失败（下次启动重试）\(propositionID, privacy: .public)：\(error.localizedDescription, privacy: .public)")
                }
            }
            if !pendingPurge.isEmpty {
                logger.info("遗忘清除补跑：\(pendingPurge.count) 个命题正文已清除")
            }
            // 存量大扫除（2026-10-29 东林拍板）：错误激活的单次流水收进历史；
            // 幂等（归档后不再命中），保护边界在 HoloLegacySweepPolicy。
            // 启动即扫一轮；CloudKit 同步晚到的记录由 120 秒后的补扫收敛
            // （新设备/重装场景首轮可能扫不全，实测模拟器晚到 5 条）。
            let swept = try await repository.archiveLegacyFlowRecords(now: Date())
            if swept > 0 {
                logger.info("存量大扫除：\(swept) 条流水记忆已收进历史")
            }
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard let self else { return }
                do {
                    let repository = try await self.repository()
                    let reswept = try await repository.archiveLegacyFlowRecords(now: Date())
                    if reswept > 0 {
                        self.logger.info("存量大扫除补扫：\(reswept) 条晚到记录已收进历史")
                    }
                } catch {
                    self.logger.error("存量大扫除补跑失败（下次启动重试）：\(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            logger.error("知识迁移失败（下次启动重试）：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 来源失效扇出（业务保存/远端变更/授权变更 → sourceInvalidation 操作）。
    /// 幂等；与发现侧失效服务挂同一批信号、分别更新两侧投影。
    func startKnowledgeInvalidationFanout() {
        guard !knowledgeInvalidationStarted else { return }
        knowledgeInvalidationStarted = true
        Task { @MainActor in
            do {
                let repository = try await self.repository()
                let service = HoloKnowledgeInvalidationService(repository: repository)
                service.start()
                // 启动时把保守失效收敛为真实来源状态（只复核仍失效命题，增量）。
                let verifier = HoloKnowledgeCoreDataSourceVerifier(
                    businessContainer: CoreDataStack.shared.persistentContainer
                )
                let reconciler = HoloKnowledgeSourceReconciler(repository: repository, verifier: verifier)
                let result = try await reconciler.reconcileInvalidated()
                if result.reconciled > 0 {
                    self.logger.info("来源复核：\(result.reconciled) 项（恢复 \(result.clearedToVerified) 失效 \(result.confirmedInvalid)）")
                }
            } catch {
                self.logger.error("知识失效扇出启动失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func loadUserControlState() async -> HoloMemoryControlState? {
        do {
            return try await repository().loadControlState()
        } catch {
            logger.error("读取记忆控制状态失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func saveUserControlState(_ proposedState: HoloMemoryControlState) async {
        do {
            let repository = try await repository()
            let current = try await repository.loadControlState()
            guard proposedState.userDecisionVersion >= current.userDecisionVersion else { return }
            var merged = proposedState
            merged.learningBaselineAt = current.learningBaselineAt
            try await repository.saveControlState(merged)
        } catch {
            logger.error("保存记忆控制状态失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
