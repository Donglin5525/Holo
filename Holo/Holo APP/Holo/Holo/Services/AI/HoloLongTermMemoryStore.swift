//
//  HoloLongTermMemoryStore.swift
//  Holo
//
//  长期记忆 JSON Store：原子写入、损坏回退、查询限制
//

import Foundation
import os.log

enum HoloLongTermMemoryStore {

    private static let logger = Logger(subsystem: "com.holo.app", category: "LongTermMemoryStore")
    private static let fileName = "HoloLongTermMemories.json"

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
        let fm = FileManager.default

        guard fm.fileExists(atPath: storeURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: storeURL)
            let memories = try JSONDecoder().decode([HoloLongTermMemory].self, from: data)
            return memories
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

    // MARK: - Save

    static func save(_ memories: [HoloLongTermMemory]) throws {
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

    /// 查询 Prompt 摘要，最多 5 条
    static func queryPromptSummary(limit: Int = 5) -> HoloMemoryPromptSummary {
        let memories = load()
            .filter { $0.confirmationState == .confirmed || $0.confirmationState == .silentlyAccepted }
            .sorted { $0.updatedAt > $1.updatedAt }

        let selected = Array(memories.prefix(limit))
        let lines = selected.map { "\($0.title)：\($0.summary)" }
        let sourceIDs = selected.map(\.id)

        let coverage: HoloMemoryCoverageLevel = selected.isEmpty ? .empty : (memories.count >= 3 ? .rich : .partial)

        return HoloMemoryPromptSummary(
            lines: lines,
            sourceIDs: sourceIDs,
            coverage: coverage
        )
    }

    /// 查询候选记忆
    static func queryCandidates() -> [HoloLongTermMemory] {
        load().filter { $0.confirmationState == .candidate }
    }

    /// 查询已确认记忆
    static func queryConfirmed() -> [HoloLongTermMemory] {
        load().filter { $0.confirmationState == .confirmed || $0.confirmationState == .silentlyAccepted }
    }
}
