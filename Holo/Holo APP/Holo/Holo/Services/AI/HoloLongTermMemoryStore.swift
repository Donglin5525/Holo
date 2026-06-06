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

    // MARK: - 并发安全

    private static let queue = DispatchQueue(
        label: "com.holo.longTermMemoryStore",
        attributes: .concurrent
    )

    // MARK: - File Path

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let holoDir = appSupport.appendingPathComponent("Holo", isDirectory: true)
        return holoDir.appendingPathComponent(fileName)
    }

    private static var backupURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("HoloLongTermMemories_corrupted.json")
    }

    // MARK: - Load

    static func load() -> [HoloLongTermMemory] {
        queue.sync {
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
                let fm = FileManager.default
                let dir = storeURL.deletingLastPathComponent()

                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(memories)

                // 原子写入：临时文件 + 替换
                let tempURL = dir.appendingPathComponent("HoloLongTermMemories_temp.json")
                try data.write(to: tempURL, options: .atomic)
                _ = try fm.replaceItemAt(storeURL, withItemAt: tempURL)

                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    // MARK: - Upsert Candidate

    @discardableResult
    static func upsertCandidate(_ candidate: HoloLongTermMemory) -> Bool {
        var memories = load()

        if let index = memories.firstIndex(where: { $0.id == candidate.id }) {
            var updated = candidate
            updated.updatedAt = Date()
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

    /// 查询 Prompt 摘要，最多 limit 条，排除过期记忆
    static func queryPromptSummary(limit: Int = 5) -> HoloMemoryPromptSummary {
        let now = Date()
        let memories = load()
            .filter { mem in
                guard mem.confirmationState == .confirmed || mem.confirmationState == .silentlyAccepted else { return false }
                // 排除已过期的记忆
                if let expires = mem.expiresAt, expires < now { return false }
                return true
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        let selected = Array(memories.prefix(limit))
        let lines = selected.map { "\($0.title)：\($0.summary)" }
        let sourceIDs = selected.map(\.id)

        let coverage: HoloMemoryCoverageLevel = selected.isEmpty ? .empty : (memories.count >= 3 ? .rich : .partial)

        return HoloMemoryPromptSummary(
            lines: lines,
            sourceIDs: sourceIDs,
            coverage: coverage,
            entries: []
        )
    }

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
        let before = memories.count

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
