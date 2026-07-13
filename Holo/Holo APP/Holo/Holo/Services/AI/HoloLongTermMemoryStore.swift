//
//  HoloLongTermMemoryStore.swift
//  Holo
//
//  长期记忆 JSON Store：原子写入、损坏回退、并发安全、过期清理
//

import Foundation
import os.log

enum HoloLongTermMemoryStore {

    private static let logger = Logger(subsystem: "com.holo.app", category: "LongTermMemoryStore")
    private static let fileName = "HoloLongTermMemories.json"
    private static let semanticV2MigrationKey = "holo_memory_semantic_v2_migrated"

    // MARK: - 并发安全

    private static let queue = DispatchQueue(
        label: "com.holo.longTermMemoryStore",
        attributes: .concurrent
    )

    // MARK: - File Path

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let holoDir = appSupport.appendingPathComponent("Holo", isDirectory: true)
        return holoDir.appendingPathComponent(fileName)
    }

    private static var backupURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("HoloLongTermMemories_corrupted.json")
    }

    // MARK: - Load

    static func load() -> [HoloLongTermMemory] {
        if !UserDefaults.standard.bool(forKey: semanticV2MigrationKey) {
            _ = performSemanticV2MigrationIfNeeded()
        }
        return queue.sync {
            let fm = FileManager.default

            guard fm.fileExists(atPath: storeURL.path) else {
                return []
            }

            do {
                let data = try Data(contentsOf: storeURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode([HoloLongTermMemory].self, from: data)
            } catch {
                logger.error("长期记忆 JSON 解码失败：\(error.localizedDescription)")

                // 备份损坏文件
                if fm.fileExists(atPath: backupURL.path) {
                    try? fm.removeItem(at: backupURL)
                }
                try? fm.copyItem(at: storeURL, to: backupURL)
                logger.info("已备份损坏文件到 \(backupURL.lastPathComponent)")

                return []
            }
        }
    }

    // MARK: - Save

    static func save(_ memories: [HoloLongTermMemory]) throws {
        let result: Result<Void, Error> = queue.sync(flags: .barrier) {
            do {
                try writeMemories(memories)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    // MARK: - Semantic V2 Migration

    /// 删除全部旧格式记录，只在新文件成功落盘后写完成标记。
    @discardableResult
    static func performSemanticV2MigrationIfNeeded(
        defaults: UserDefaults = .standard
    ) -> HoloLongTermMemoryMigrationResult? {
        guard !defaults.bool(forKey: semanticV2MigrationKey) else { return nil }

        let result: Result<HoloLongTermMemoryMigrationResult, Error> = queue.sync(flags: .barrier) {
            do {
                let fm = FileManager.default
                guard fm.fileExists(atPath: storeURL.path) else {
                    return .success(HoloLongTermMemoryMigrationResult(
                        memories: [],
                        removedLegacyCount: 0,
                        removedInvalidCount: 0
                    ))
                }

                let data = try Data(contentsOf: storeURL)
                let migration = try HoloLongTermMemoryMigration.decodeAndFilter(data)
                try writeMemories(migration.memories)
                return .success(migration)
            } catch {
                return .failure(error)
            }
        }

        switch result {
        case .success(let migration):
            defaults.set(true, forKey: semanticV2MigrationKey)
            logger.info("长期记忆 V2 迁移完成：删除旧格式 \(migration.removedLegacyCount) 条，无效新格式 \(migration.removedInvalidCount) 条")
            return migration
        case .failure(let error):
            logger.error("长期记忆 V2 迁移失败，将在下次启动重试：\(error.localizedDescription)")
            return nil
        }
    }

    private static func writeMemories(_ memories: [HoloLongTermMemory]) throws {
        let fm = FileManager.default
        let dir = storeURL.deletingLastPathComponent()

        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(memories)

        let tempURL = dir.appendingPathComponent("HoloLongTermMemories_temp.json")
        try data.write(to: tempURL, options: .atomic)
        if fm.fileExists(atPath: storeURL.path) {
            _ = try fm.replaceItemAt(storeURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: storeURL)
        }
    }

    // MARK: - Upsert Candidate

    @discardableResult
    static func upsertCandidate(_ candidate: HoloLongTermMemory) -> Bool {
        var memories = load()

        if let index = memories.firstIndex(where: { $0.id == candidate.id }) {
            let existing = memories[index]
            var updated = candidate
            updated.createdAt = existing.createdAt
            updated.updatedAt = Date()
            updated.evidence = HoloLongTermMemoryEvidenceMerger.merge(existing.evidence, candidate.evidence)
            updated.confidence = MemoryCandidateSemanticMapper.resolveConfidence(
                llmValue: nil,
                evidenceCount: updated.evidence.count
            )

            switch existing.confirmationState {
            case .confirmed, .silentlyAccepted:
                updated.confirmationState = existing.confirmationState
                updated.title = existing.title
                updated.displaySummary = existing.displaySummary
                updated.aiUseSummary = existing.aiUseSummary
                updated.prohibitedInferences = existing.prohibitedInferences
            case .rejected, .archived:
                updated.confirmationState = existing.confirmationState
            case .candidate:
                break
            }
            memories[index] = updated
        } else {
            memories.append(candidate)
        }

        do {
            try save(memories)
            return true
        } catch {
            logger.error("保存长期记忆失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Confirm

    static func confirm(id: String) -> Bool {
        var memories = load()

        guard let index = memories.firstIndex(where: { $0.id == id }) else { return false }
        memories[index].confirmationState = .confirmed
        memories[index].updatedAt = Date()

        do {
            try save(memories)
            return true
        } catch {
            logger.error("确认长期记忆失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Reject

    static func reject(id: String) -> Bool {
        var memories = load()

        guard let index = memories.firstIndex(where: { $0.id == id }) else { return false }
        memories[index].confirmationState = .rejected
        memories[index].updatedAt = Date()

        do {
            try save(memories)
            return true
        } catch {
            logger.error("拒绝长期记忆失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Delete

    static func delete(id: String) -> Bool {
        var memories = load()
        memories.removeAll { $0.id == id }

        do {
            try save(memories)
            return true
        } catch {
            logger.error("删除长期记忆失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Query

    /// 查询候选记忆（排除过期）
    static func queryCandidates() -> [HoloLongTermMemory] {
        let now = Date()
        return load().filter { mem in
            guard mem.confirmationState == .candidate else { return false }
            if let expires = mem.expiresAt, expires < now { return false }
            return true
        }
    }

    /// 查询已确认记忆（排除过期）
    static func queryConfirmed() -> [HoloLongTermMemory] {
        let now = Date()
        return load().filter { mem in
            guard mem.confirmationState == .confirmed || mem.confirmationState == .silentlyAccepted else { return false }
            if let expires = mem.expiresAt, expires < now { return false }
            return true
        }
    }

    // MARK: - 过期清理

    /// 归档已过期的记忆（不硬删），返回归档数量
    @discardableResult
    static func cleanupExpired(now: Date = Date()) -> Int {
        var memories = load()
        var archivedCount = 0
        for index in memories.indices {
            guard let expires = memories[index].expiresAt, expires < now else { continue }
            guard memories[index].confirmationState != .archived else { continue }
            memories[index].confirmationState = .archived
            memories[index].updatedAt = now
            archivedCount += 1
        }

        guard archivedCount > 0 else { return 0 }

        do {
            try save(memories)
            logger.info("归档了 \(archivedCount) 条过期长期记忆")
            return archivedCount
        } catch {
            logger.error("过期清理保存失败：\(error.localizedDescription)")
            return 0
        }
    }
}
