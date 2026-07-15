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
            return repository
        }
        #endif

        await CoreDataStack.shared.waitUntilReady()

        let memoryDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("Holo/Memory", isDirectory: true)
        let controller = try HoloMemoryPersistenceController(
            mainContainer: CoreDataStack.shared.persistentContainer,
            sensitiveDirectoryURL: memoryDirectory
        )
        let repository = CoreDataHoloMemoryRepository(controller: controller)
        cachedRepository = repository
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
            let memoryDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
                .appendingPathComponent("Holo/Memory", isDirectory: true)
            #if DEBUG
            let allowDestructiveRerun = true
            #else
            let allowDestructiveRerun = false
            #endif
            let service = HoloMemoryMigrationService(
                repository: repository,
                stateStore: stateStore,
                journalURL: memoryDirectory.appendingPathComponent("memory-v3-migration-journal.json"),
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
        } catch {
            // 迁移失败保留旧 Store 和 journal，下次启动重试，不影响主业务。
            logger.error("统一记忆迁移失败：\(error.localizedDescription, privacy: .public)")
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
