//
//  HoloEpisodicMemoryStore.swift
//  Holo
//
//  短期（情景）记忆 JSON Store：原子写入、损坏回退、过期清理、suppression
//

import Foundation
import OSLog

final class HoloEpisodicMemoryStore: @unchecked Sendable {
    static let shared = HoloEpisodicMemoryStore()

    private let logger = Logger(subsystem: "com.holo.app", category: "EpisodicMemoryStore")
    private let fileManager: FileManager
    private let storeURL: URL
    private let backupURL: URL
    private let suppressionURL: URL
    private let queue: DispatchQueue

    // 90 天硬上限
    static let maxLifetimeDays: Int = 90

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let directory: URL
        if let directoryURL {
            directory = directoryURL
        } else {
            directory = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Holo/Memory", isDirectory: true)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("episodicMemories.json")
        backupURL = directory.appendingPathComponent("episodicMemories.backup.json")
        suppressionURL = directory.appendingPathComponent("episodicMemorySuppressionRules.json")
        queue = DispatchQueue(
            label: "com.holo.episodicMemoryStore.\(UUID().uuidString)",
            attributes: .concurrent
        )
    }

    // MARK: - CRUD

    func load() -> [HoloEpisodicMemory] {
        queue.sync {
            do {
                return try readMemoriesUnlocked()
            } catch {
                backupCorruptedFileUnlocked()
                logger.error("情景记忆 JSON 解码失败：\(error.localizedDescription)")
                return []
            }
        }
    }

    func save(_ memories: [HoloEpisodicMemory]) {
        let result: Result<Void, Error> = queue.sync(flags: .barrier) {
            Result { try writeMemoriesUnlocked(memories) }
        }
        if case .failure(let error) = result {
            logger.error("保存情景记忆失败：\(error.localizedDescription)")
        }
    }

    func upsert(_ memory: HoloEpisodicMemory) {
        mutate { memories in
            if let index = memories.firstIndex(where: { $0.id == memory.id }) {
                var updated = memory
                updated.createdAt = memories[index].createdAt
                updated.updatedAt = Date()
                memories[index] = updated
            } else {
                memories.append(memory)
            }
        }
    }

    func updateState(id: String, to newState: HoloEpisodicMemoryState) {
        mutate { memories in
            guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
            memories[index].state = newState
            memories[index].updatedAt = Date()
        }
    }

    func delete(id: String) {
        mutate { memories in
            memories.removeAll { $0.id == id }
        }
    }

    /// 批量删除已过期、已归档、已拒绝的情景记忆
    /// - Returns: (删除数量, 释放字节数)
    @discardableResult
    func deleteExpiredArchivedRejected() -> (count: Int, bytes: Int64) {
        mutate { memories in
            let removableStates: Set<HoloEpisodicMemoryState> = [.expired, .archived, .rejected]
            let toDelete = memories.filter { removableStates.contains($0.state) }
            guard !toDelete.isEmpty else { return (0, 0) }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let freedBytes = toDelete.reduce(Int64(0)) { total, memory in
                total + Int64((try? encoder.encode(memory).count) ?? 0)
            }
            memories.removeAll { removableStates.contains($0.state) }
            return (toDelete.count, freedBytes)
        } ?? (0, 0)
    }

    @discardableResult
    func reject(id: String) -> HoloMemorySuppressionRule? {
        let result: Result<HoloMemorySuppressionRule?, Error> = queue.sync(flags: .barrier) {
            Result {
                var memories = try readMemoriesUnlocked()
                guard let index = memories.firstIndex(where: { $0.id == id }) else { return nil }
                let memory = memories[index]
                memories[index].state = .rejected
                memories[index].updatedAt = Date()

                let keywords = extractKeywords(from: memory.title + " " + memory.summary)
                let rule = keywords.isEmpty ? nil : HoloMemorySuppressionRule(
                    id: UUID().uuidString,
                    originalMemorySummary: memory.summary,
                    keywordGroups: [keywords],
                    suppressedUntil: Calendar.current.date(
                        byAdding: .day,
                        value: 30,
                        to: Date()
                    )!,
                    originalRejectedAt: Date()
                )

                try writeMemoriesUnlocked(memories)
                if let rule {
                    var rules = try readSuppressionRulesUnlocked(includeExpired: false)
                    rules.append(rule)
                    try writeSuppressionRulesUnlocked(rules)
                }
                return rule
            }
        }

        switch result {
        case .success(let rule):
            return rule
        case .failure(let error):
            logger.error("拒绝情景记忆失败：\(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func markExpired() -> [String] {
        mutate { memories in
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
            return expiredIDs
        } ?? []
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
        let result: Result<[HoloMemorySuppressionRule], Error> = queue.sync(flags: .barrier) {
            Result {
                let rules = try readSuppressionRulesUnlocked(includeExpired: true)
                let activeRules = rules.filter { $0.suppressedUntil > Date() }
                if activeRules.count != rules.count {
                    try writeSuppressionRulesUnlocked(activeRules)
                }
                return activeRules
            }
        }
        switch result {
        case .success(let rules):
            return rules
        case .failure(let error):
            logger.error("Suppression rules 解码失败：\(error.localizedDescription)")
            return []
        }
    }

    func saveSuppressionRules(_ rules: [HoloMemorySuppressionRule]) {
        let result: Result<Void, Error> = queue.sync(flags: .barrier) {
            Result { try writeSuppressionRulesUnlocked(rules) }
        }
        if case .failure(let error) = result {
            logger.error("保存 suppression rules 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Private

    /// 读取、修改、写回必须处于同一个 barrier，避免两个调用读取同一旧快照后互相覆盖。
    private func mutate<ResultValue>(
        _ mutation: (inout [HoloEpisodicMemory]) -> ResultValue
    ) -> ResultValue? {
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
            logger.error("更新情景记忆失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func readMemoriesUnlocked() throws -> [HoloEpisodicMemory] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([HoloEpisodicMemory].self, from: data)
    }

    private func writeMemoriesUnlocked(_ memories: [HoloEpisodicMemory]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(memories)
        try atomicWrite(data, to: storeURL, temporaryName: "episodicMemories_temp.json")
    }

    private func readSuppressionRulesUnlocked(
        includeExpired: Bool
    ) throws -> [HoloMemorySuppressionRule] {
        guard fileManager.fileExists(atPath: suppressionURL.path) else { return [] }
        let data = try Data(contentsOf: suppressionURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rules = try decoder.decode([HoloMemorySuppressionRule].self, from: data)
        return includeExpired ? rules : rules.filter { $0.suppressedUntil > Date() }
    }

    private func writeSuppressionRulesUnlocked(_ rules: [HoloMemorySuppressionRule]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(rules)
        try atomicWrite(
            data,
            to: suppressionURL,
            temporaryName: "episodicMemorySuppressionRules_temp.json"
        )
    }

    private func atomicWrite(_ data: Data, to destinationURL: URL, temporaryName: String) throws {
        let directory = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let temporaryURL = directory.appendingPathComponent(temporaryName)
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        try data.write(to: temporaryURL, options: .atomic)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
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

    private func extractKeywords(from text: String) -> [String] {
        let normalized = text.lowercased()
        let separators = CharacterSet(charactersIn: " ，。、！？,.!? \t\n")
        let words = normalized.components(separatedBy: separators).filter { $0.count >= 2 }
        return Array(words.prefix(5))
    }
}
