//
//  HoloLongTermMemoryStore.swift
//  Holo
//
//  长期记忆 JSON Store：原子写入、损坏回退、并发安全、过期清理
//

import Foundation
import os.log

/// 旧长期记忆文件的实例化实现。实例隔离让迁移和并发回归测试不会触碰用户真实数据。
final class HoloLongTermMemoryFileStore: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.holo.app", category: "LongTermMemoryStore")
    private let fileManager: FileManager
    private let storeURL: URL
    private let backupURL: URL
    private let defaults: UserDefaults
    private let migrationKey: String
    private let queue: DispatchQueue

    init(
        directoryURL: URL? = nil,
        defaults: UserDefaults = .standard,
        migrationKey: String = "holo_memory_semantic_v2_migrated",
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.migrationKey = migrationKey
        let directory = directoryURL ?? Self.defaultDirectory(fileManager: fileManager)
        storeURL = directory.appendingPathComponent("HoloLongTermMemories.json")
        backupURL = directory.appendingPathComponent("HoloLongTermMemories_corrupted.json")
        queue = DispatchQueue(
            label: "com.holo.longTermMemoryStore.\(UUID().uuidString)",
            attributes: .concurrent
        )
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return appSupport.appendingPathComponent("Holo", isDirectory: true)
    }

    func load() -> [HoloLongTermMemory] {
        ensureMigration()
        return queue.sync {
            do {
                return try readMemoriesUnlocked()
            } catch {
                backupCorruptedFileUnlocked()
                logger.error("长期记忆 JSON 解码失败：\(error.localizedDescription)")
                return []
            }
        }
    }

    func save(_ memories: [HoloLongTermMemory]) throws {
        ensureMigration()
        let result: Result<Void, Error> = queue.sync(flags: .barrier) {
            Result { try writeMemoriesUnlocked(memories) }
        }
        try result.get()
    }

    @discardableResult
    func performSemanticV2MigrationIfNeeded() -> HoloLongTermMemoryMigrationResult? {
        guard !defaults.bool(forKey: migrationKey) else { return nil }

        let result: Result<HoloLongTermMemoryMigrationResult, Error> = queue.sync(flags: .barrier) {
            Result {
                guard fileManager.fileExists(atPath: storeURL.path) else {
                    return HoloLongTermMemoryMigrationResult(
                        memories: [],
                        removedLegacyCount: 0,
                        removedInvalidCount: 0
                    )
                }

                let data = try Data(contentsOf: storeURL)
                let migration = try HoloLongTermMemoryMigration.decodeAndFilter(data)
                try writeMemoriesUnlocked(migration.memories)
                return migration
            }
        }

        switch result {
        case .success(let migration):
            defaults.set(true, forKey: migrationKey)
            logger.info("长期记忆 V2 迁移完成：删除旧格式 \(migration.removedLegacyCount) 条，无效新格式 \(migration.removedInvalidCount) 条")
            return migration
        case .failure(let error):
            logger.error("长期记忆 V2 迁移失败，将在下次启动重试：\(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func upsertCandidate(_ candidate: HoloLongTermMemory) -> Bool {
        mutate { memories in
            if let index = memories.firstIndex(where: { $0.id == candidate.id }) {
                let existing = memories[index]
                var updated = candidate
                updated.createdAt = existing.createdAt
                updated.updatedAt = Date()
                updated.evidence = HoloLongTermMemoryEvidenceMerger.merge(
                    existing.evidence,
                    candidate.evidence
                )
                updated.confidence = Self.confidence(evidenceCount: updated.evidence.count)

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
            return true
        } ?? false
    }

    func confirm(id: String) -> Bool {
        mutate { memories in
            guard let index = memories.firstIndex(where: { $0.id == id }) else { return false }
            memories[index].confirmationState = .confirmed
            memories[index].updatedAt = Date()
            return true
        } ?? false
    }

    func reject(id: String) -> Bool {
        mutate { memories in
            guard let index = memories.firstIndex(where: { $0.id == id }) else { return false }
            memories[index].confirmationState = .rejected
            memories[index].updatedAt = Date()
            return true
        } ?? false
    }

    func delete(id: String) -> Bool {
        mutate { memories in
            let originalCount = memories.count
            memories.removeAll { $0.id == id }
            return memories.count != originalCount
        } ?? false
    }

    func queryCandidates() -> [HoloLongTermMemory] {
        let now = Date()
        return load().filter { memory in
            guard memory.confirmationState == .candidate else { return false }
            if let expiresAt = memory.expiresAt, expiresAt < now { return false }
            return true
        }
    }

    func queryConfirmed() -> [HoloLongTermMemory] {
        let now = Date()
        return load().filter { memory in
            guard memory.confirmationState == .confirmed ||
                    memory.confirmationState == .silentlyAccepted else { return false }
            if let expiresAt = memory.expiresAt, expiresAt < now { return false }
            return true
        }
    }

    @discardableResult
    func cleanupExpired(now: Date = Date()) -> Int {
        mutate { memories in
            var archivedCount = 0
            for index in memories.indices {
                guard let expiresAt = memories[index].expiresAt, expiresAt < now else { continue }
                guard memories[index].confirmationState != .archived else { continue }
                memories[index].confirmationState = .archived
                memories[index].updatedAt = now
                archivedCount += 1
            }
            return archivedCount
        } ?? 0
    }

    private func ensureMigration() {
        if !defaults.bool(forKey: migrationKey) {
            _ = performSemanticV2MigrationIfNeeded()
        }
    }

    /// 读取、修改、写回必须处于同一个 barrier，避免两个调用读取同一旧快照后互相覆盖。
    private func mutate<ResultValue>(
        _ mutation: (inout [HoloLongTermMemory]) -> ResultValue
    ) -> ResultValue? {
        ensureMigration()
        let result: Result<ResultValue, Error> = queue.sync(flags: .barrier) {
            Result {
                var memories = try readMemoriesUnlocked()
                let value = mutation(&memories)
                try writeMemoriesUnlocked(memories)
                return value
            }
        }

        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            logger.error("更新长期记忆失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func readMemoriesUnlocked() throws -> [HoloLongTermMemory] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([HoloLongTermMemory].self, from: data)
    }

    private func writeMemoriesUnlocked(_ memories: [HoloLongTermMemory]) throws {
        let directory = storeURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(memories)
        let temporaryURL = directory.appendingPathComponent("HoloLongTermMemories_temp.json")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        try data.write(to: temporaryURL, options: .atomic)

        do {
            if fileManager.fileExists(atPath: storeURL.path) {
                _ = try fileManager.replaceItemAt(storeURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: storeURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func backupCorruptedFileUnlocked() {
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        if fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
        }
        try? fileManager.copyItem(at: storeURL, to: backupURL)
    }

    private static func confidence(evidenceCount: Int) -> HoloMemoryConfidence {
        if evidenceCount >= 3 { return .high }
        if evidenceCount >= 2 { return .medium }
        return .low
    }
}

/// 保留原有静态 API，业务调用方无须感知旧 Store 的并发修复。
enum HoloLongTermMemoryStore {
    private static let backend = HoloLongTermMemoryFileStore()

    static func load() -> [HoloLongTermMemory] { backend.load() }
    static func save(_ memories: [HoloLongTermMemory]) throws { try backend.save(memories) }

    @discardableResult
    static func performSemanticV2MigrationIfNeeded(
        defaults: UserDefaults = .standard
    ) -> HoloLongTermMemoryMigrationResult? {
        if defaults === UserDefaults.standard {
            return backend.performSemanticV2MigrationIfNeeded()
        }
        return HoloLongTermMemoryFileStore(defaults: defaults)
            .performSemanticV2MigrationIfNeeded()
    }

    @discardableResult
    static func upsertCandidate(_ candidate: HoloLongTermMemory) -> Bool {
        backend.upsertCandidate(candidate)
    }

    static func confirm(id: String) -> Bool { backend.confirm(id: id) }
    static func reject(id: String) -> Bool { backend.reject(id: id) }
    static func delete(id: String) -> Bool { backend.delete(id: id) }
    static func queryCandidates() -> [HoloLongTermMemory] { backend.queryCandidates() }
    static func queryConfirmed() -> [HoloLongTermMemory] { backend.queryConfirmed() }

    @discardableResult
    static func cleanupExpired(now: Date = Date()) -> Int {
        backend.cleanupExpired(now: now)
    }
}
