//
//  CategoryLearnedMapping.swift
//  Holo
//
//  用户分类学习机制
//  记录用户确认的分类映射，下次自动匹配
//

import Foundation
import os.log

/// 用户分类学习服务
/// 当用户将「待确认」交易改为具体分类时，自动记录映射关系
enum CategoryLearnedMapping {

    private static let logger = Logger(subsystem: "com.holo.app", category: "CategoryLearnedMapping")

    /// 存储键：type|primary|candidate  →  目标: primaryCategory|subCategory
    private static let storageKey = "categoryLearnedMappings"
    /// 旧格式 key 迁移标记
    private static let migrationVersionKey = "categoryLearnedMappingSchemaVersion"

    // MARK: - Public API

    /// 记录一条学习映射
    /// - Parameters:
    ///   - candidate: 用户原始分类表达（如"家政"）
    ///   - type: 交易类型
    ///   - primaryCategory: 原始一级分类（防止同名二级分类跨一级分类串线）
    ///   - targetPrimary: 用户确认的一级分类
    ///   - targetSub: 用户确认的二级分类
    static func record(
        candidate: String,
        type: TransactionType,
        primaryCategory: String = "",
        targetPrimary: String,
        targetSub: String
    ) {
        let key = makeKey(candidate: candidate, type: type, primaryCategory: primaryCategory)
        let value = "\(targetPrimary)|\(targetSub)"

        var mappings = loadAll()
        mappings[key] = value
        saveAll(mappings)

        logger.info("学习映射：\(key) → \(value)")
    }

    /// 查找学习映射
    /// - Parameters:
    ///   - candidate: 待匹配的分类名称
    ///   - type: 交易类型
    ///   - primaryCategory: 原始一级分类
    /// - Returns: (primaryCategory, subCategory) 或 nil
    static func lookup(
        candidate: String,
        type: TransactionType,
        primaryCategory: String = ""
    ) -> (primary: String, sub: String)? {
        let key = makeKey(candidate: candidate, type: type, primaryCategory: primaryCategory)
        guard let value = loadAll()[key],
              let pipeIndex = value.firstIndex(of: "|") else {
            return nil
        }

        let primary = String(value[..<pipeIndex])
        let sub = String(value[value.index(after: pipeIndex)...])

        guard !primary.isEmpty, !sub.isEmpty else { return nil }
        return (primary, sub)
    }

    /// 删除一条学习映射
    static func remove(candidate: String, type: TransactionType, primaryCategory: String = "") {
        let key = makeKey(candidate: candidate, type: type, primaryCategory: primaryCategory)
        var mappings = loadAll()
        mappings.removeValue(forKey: key)
        saveAll(mappings)
    }

    /// 清除所有学习映射
    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        logger.info("已清除所有学习映射")
    }

    // MARK: - 交易候选暂存

    /// 暂存交易创建时的原始分类候选
    /// 用于用户后续编辑「待确认」交易时触发学习
    private static let transactionCandidateKey = "transactionCategoryCandidates"

    static func recordTransactionCandidate(transactionId: UUID, candidate: String, type: TransactionType) {
        var mappings = loadTransactionCandidates()
        mappings[transactionId.uuidString] = "\(type.rawValue)|\(candidate)"
        saveTransactionCandidates(mappings)
        logger.info("暂存交易候选：\(transactionId.uuidString.prefix(8))... → \(candidate)")
    }

    static func lookupTransactionCandidate(transactionId: UUID) -> (candidate: String, type: TransactionType)? {
        guard let value = loadTransactionCandidates()[transactionId.uuidString],
              let pipeIndex = value.firstIndex(of: "|") else {
            return nil
        }
        let typeRaw = String(value[..<pipeIndex])
        let candidate = String(value[value.index(after: pipeIndex)...])
        guard let type = TransactionType(rawValue: typeRaw), !candidate.isEmpty else { return nil }
        return (candidate, type)
    }

    static func removeTransactionCandidate(transactionId: UUID) {
        var mappings = loadTransactionCandidates()
        mappings.removeValue(forKey: transactionId.uuidString)
        saveTransactionCandidates(mappings)
    }

    // MARK: - 旧格式迁移

    /// 迁移旧格式 key（type|candidate）→ 新格式（type|primary|candidate）
    /// 旧 key 无法可靠补全 primaryCategory 维度，直接删除
    static func migrateOldFormatKeys() {
        let currentVersion = 2
        let savedVersion = UserDefaults.standard.integer(forKey: migrationVersionKey)
        guard savedVersion < currentVersion else { return }

        var mappings = loadAll()
        let oldKeys = mappings.keys.filter { key in
            // 旧格式: "type|candidate"（只有 1 个 |）
            // 新格式: "type|primary|candidate"（有 2 个 |）
            key.components(separatedBy: "|").count == 2
        }

        guard !oldKeys.isEmpty else {
            UserDefaults.standard.set(currentVersion, forKey: migrationVersionKey)
            return
        }

        for key in oldKeys {
            mappings.removeValue(forKey: key)
        }
        saveAll(mappings)

        UserDefaults.standard.set(currentVersion, forKey: migrationVersionKey)
        logger.info("迁移旧格式学习映射：删除 \(oldKeys.count) 条旧 key")
    }

    // MARK: - Private

    private static func makeKey(candidate: String, type: TransactionType, primaryCategory: String) -> String {
        let normalized = candidate.trimmingCharacters(in: .whitespaces).lowercased()
        let primary = primaryCategory.trimmingCharacters(in: .whitespaces).lowercased()
        return "\(type.rawValue)|\(primary)|\(normalized)"
    }

    private static func loadAll() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func saveAll(_ mappings: [String: String]) {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func loadTransactionCandidates() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: transactionCandidateKey) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func saveTransactionCandidates(_ mappings: [String: String]) {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        UserDefaults.standard.set(data, forKey: transactionCandidateKey)
    }
}
