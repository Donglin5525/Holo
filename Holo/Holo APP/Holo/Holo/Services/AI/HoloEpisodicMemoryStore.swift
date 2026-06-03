//
//  HoloEpisodicMemoryStore.swift
//  Holo
//
//  短期（情景）记忆 JSON Store：原子写入、损坏回退、过期清理、suppression
//

import Foundation
import OSLog

final class HoloEpisodicMemoryStore {

    static let shared = HoloEpisodicMemoryStore()

    private let logger = Logger(subsystem: "com.holo.app", category: "EpisodicMemoryStore")
    private let fileManager = FileManager.default
    private let storeURL: URL
    private let backupURL: URL
    private let suppressionURL: URL
    private let queue = DispatchQueue(label: "com.holo.episodicMemoryStore", attributes: .concurrent)

    // 90 天硬上限
    static let maxLifetimeDays: Int = 90

    private init() {
        let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo/Memory", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("episodicMemories.json")
        backupURL = dir.appendingPathComponent("episodicMemories.backup.json")
        suppressionURL = dir.appendingPathComponent("episodicMemorySuppressionRules.json")
    }

    // MARK: - CRUD

    func load() -> [HoloEpisodicMemory] {
        queue.sync {
            guard fileManager.fileExists(atPath: storeURL.path) else { return [] }

            do {
                let data = try Data(contentsOf: storeURL)
                return decode(data)
            } catch {
                logger.error("情景记忆 JSON 解码失败：\(error.localizedDescription)")
                backupCorruptedFile()
                return []
            }
        }
    }

    func save(_ memories: [HoloEpisodicMemory]) {
        queue.sync(flags: .barrier) {
            do {
                let dir = storeURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: dir.path) {
                    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                let data = try encode(memories)
                let tempURL = dir.appendingPathComponent("episodicMemories_temp.json")
                try data.write(to: tempURL, options: .atomic)
                _ = try? fileManager.replaceItemAt(storeURL, withItemAt: tempURL)
            } catch {
                logger.error("保存情景记忆失败：\(error.localizedDescription)")
            }
        }
    }

    func upsert(_ memory: HoloEpisodicMemory) {
        var memories = load()
        if let index = memories.firstIndex(where: { $0.id == memory.id }) {
            var updated = memory
            updated.updatedAt = Date()
            memories[index] = updated
        } else {
            memories.append(memory)
        }
        save(memories)
    }

    func updateState(id: String, to newState: HoloEpisodicMemoryState) {
        var memories = load()
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[index].state = newState
        memories[index].updatedAt = Date()
        save(memories)
    }

    func delete(id: String) {
        var memories = load()
        memories.removeAll { $0.id == id }
        save(memories)
    }

    @discardableResult
    func reject(id: String) -> HoloMemorySuppressionRule? {
        var memories = load()
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return nil }
        let memory = memories[index]

        memories[index].state = .rejected
        memories[index].updatedAt = Date()
        save(memories)

        // 生成 suppression rule（30 天）
        let keywords = extractKeywords(from: memory.title + " " + memory.summary)
        guard !keywords.isEmpty else { return nil }

        let rule = HoloMemorySuppressionRule(
            id: UUID().uuidString,
            originalMemorySummary: memory.summary,
            keywordGroups: [keywords],
            suppressedUntil: Calendar.current.date(byAdding: .day, value: 30, to: Date())!,
            originalRejectedAt: Date()
        )

        var rules = loadSuppressionRules()
        rules.append(rule)
        saveSuppressionRules(rules)

        return rule
    }

    @discardableResult
    func markExpired() -> [String] {
        var memories = load()
        let now = Date()
        var expiredIDs: [String] = []

        for index in memories.indices {
            if memories[index].expiresAt <= now,
               memories[index].state != .expired,
               memories[index].state != .rejected,
               memories[index].state != .promoted {
                memories[index].state = .expired
                memories[index].updatedAt = now
                expiredIDs.append(memories[index].id)
            }
        }

        if !expiredIDs.isEmpty {
            save(memories)
            logger.info("标记 \(expiredIDs.count) 条情景记忆为过期")
        }

        return expiredIDs
    }

    // MARK: - Query

    func queryActive() -> [HoloEpisodicMemory] {
        load().filter { $0.state == .active || $0.state == .suggested }
    }

    func querySuggested() -> [HoloEpisodicMemory] {
        load().filter { $0.state == .suggested }
    }

    func queryByRunID(_ runID: String) -> [HoloEpisodicMemory] {
        load().filter { $0.createdFromRunID == runID || $0.semanticHitRunIDs.contains(runID) }
    }

    // MARK: - Suppression Rules

    func loadSuppressionRules() -> [HoloMemorySuppressionRule] {
        guard fileManager.fileExists(atPath: suppressionURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: suppressionURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rules = try decoder.decode([HoloMemorySuppressionRule].self, from: data)
            // 清理已过期的规则
            let now = Date()
            let activeRules = rules.filter { $0.suppressedUntil > now }
            if activeRules.count != rules.count {
                saveSuppressionRules(activeRules)
            }
            return activeRules
        } catch {
            logger.error("Suppression rules 解码失败：\(error.localizedDescription)")
            return []
        }
    }

    func saveSuppressionRules(_ rules: [HoloMemorySuppressionRule]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(rules)
            let dir = suppressionURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try data.write(to: suppressionURL, options: .atomic)
        } catch {
            logger.error("保存 suppression rules 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func encode(_ memories: [HoloEpisodicMemory]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(memories)
    }

    private func decode(_ data: Data) -> [HoloEpisodicMemory] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HoloEpisodicMemory].self, from: data)) ?? []
    }

    private func backupCorruptedFile() {
        let backup = self.backupURL
        if fileManager.fileExists(atPath: backup.path) {
            try? fileManager.removeItem(at: backup)
        }
        try? fileManager.copyItem(at: storeURL, to: backup)
        logger.info("已备份损坏文件到 \(backup.lastPathComponent)")
    }

    private func extractKeywords(from text: String) -> [String] {
        // 简单关键词提取：按空格和标点分词，过滤短词
        let normalized = text.lowercased()
        let separators = CharacterSet(charactersIn: " ，。、！？,.!? \t\n")
        let words = normalized.components(separatedBy: separators).filter { $0.count >= 2 }
        return Array(words.prefix(5))
    }
}
