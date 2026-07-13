//
//  CategoryLearnedMapping.swift
//  Holo
//
//  用户分类学习机制
//  记录用户确认的分类映射，下次自动匹配
//  支持精确匹配 + LLM 归纳模式匹配
//

import Foundation
import os.log

/// 用户分类学习服务
/// 当用户将「待分类」交易改为具体分类时，自动记录映射关系
/// 支持两级匹配：精确匹配 → 归纳模式匹配
enum CategoryLearnedMapping {

    private static let logger = Logger(subsystem: "com.holo.app", category: "CategoryLearnedMapping")

    /// 存储键：type|primary|candidate  →  目标: primaryCategory|subCategory
    private static let storageKey = "categoryLearnedMappings"
    /// 旧格式 key 迁移标记
    private static let migrationVersionKey = "categoryLearnedMappingSchemaVersion"

    // MARK: - Display Model

    /// 单条学习映射的展示模型
    struct LearnedMappingEntry: Identifiable {
        /// 原始 UserDefaults key（用于删除定位）
        let id: String
        /// 交易类型
        let type: TransactionType
        /// 原始一级分类（可能为空字符串）
        let primaryCategory: String
        /// 用户原始分类表达
        let candidate: String
        /// 映射目标一级分类
        let targetPrimary: String
        /// 映射目标二级分类
        let targetSub: String
    }

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
    /// 两级匹配：精确匹配 → 归纳模式匹配
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
        // 第一级：精确匹配
        if let exact = exactLookup(candidate: candidate, type: type, primaryCategory: primaryCategory) {
            return exact
        }

        // 第二级：归纳模式匹配
        let rules = loadInductionRules().filter { $0.transactionType == type.rawValue }
        let normalized = candidate.trimmingCharacters(in: .whitespaces).lowercased()
        for rule in rules {
            if matchPattern(candidate: normalized, rule: rule) {
                return (rule.targetPrimary, rule.targetSub)
            }
        }

        return nil
    }

    /// 精确匹配（原 lookup 逻辑）
    private static func exactLookup(
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

    /// 获取所有学习映射（解析后的展示数据）
    static func listAll() -> [LearnedMappingEntry] {
        let raw = loadAll()
        return raw.compactMap { (key, value) -> LearnedMappingEntry? in
            let keyParts = key.components(separatedBy: "|")
            guard keyParts.count == 3,
                  let type = TransactionType(rawValue: keyParts[0]) else {
                return nil
            }

            let valueParts = value.components(separatedBy: "|")
            guard valueParts.count == 2,
                  !valueParts[0].isEmpty, !valueParts[1].isEmpty else {
                return nil
            }

            return LearnedMappingEntry(
                id: key,
                type: type,
                primaryCategory: keyParts[1],
                candidate: keyParts[2],
                targetPrimary: valueParts[0],
                targetSub: valueParts[1]
            )
        }
        .sorted { lhs, rhs in
            if lhs.type != rhs.type {
                return lhs.type == .expense
            }
            return lhs.candidate < rhs.candidate
        }
    }

    /// 按原始 key 删除一条学习映射
    static func removeByKey(_ key: String) {
        var mappings = loadAll()
        mappings.removeValue(forKey: key)
        saveAll(mappings)
        logger.info("删除学习映射：\(key)")
    }

    // MARK: - 交易候选暂存

    /// 暂存交易创建时的原始分类候选
    /// 用于用户后续编辑「待分类」交易时触发学习
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

    // MARK: - 归纳学习

    /// 归纳学习触发阈值：累积多少个不同样本才触发 LLM 归纳
    private static let inductionThreshold = 3

    /// 归纳样本存储 key
    private static let inductionSamplesKey = "categoryInductionSamples"
    /// 归纳规则存储 key
    private static let inductionRulesKey = "categoryInductionRules"

    // MARK: 归纳数据模型

    /// 归纳样本
    struct InductionSample: Codable, Equatable {
        let candidate: String
        let targetPrimary: String
        let targetSub: String
        let transactionType: String
        let timestamp: Date
    }

    /// 归纳规则（LLM 归纳出的模式）
    struct InductionRule: Codable, Equatable {
        let pattern: String           // 匹配模式（小写），如 "软件"
        let matchType: MatchType      // 匹配方式
        let targetPrimary: String     // 目标一级分类
        let targetSub: String         // 目标二级分类
        let transactionType: String   // 交易类型
        let sampleCount: Int          // 基于多少样本归纳
        let createdAt: Date

        var transactionTypeEnum: TransactionType? {
            TransactionType(rawValue: transactionType)
        }
    }

    /// 模式匹配方式
    enum MatchType: String, Codable, CaseIterable {
        case contains     // 包含关键词
        case startsWith   // 以关键词开头
        case endsWith     // 以关键词结尾

        var displayName: String {
            switch self {
            case .contains: return "包含"
            case .startsWith: return "开头"
            case .endsWith: return "结尾"
            }
        }
    }

    // MARK: 样本记录

    /// 记录一条归纳样本
    static func recordInductionSample(
        candidate: String,
        targetPrimary: String,
        targetSub: String,
        transactionType: TransactionType
    ) {
        let sample = InductionSample(
            candidate: candidate.trimmingCharacters(in: .whitespaces).lowercased(),
            targetPrimary: targetPrimary,
            targetSub: targetSub,
            transactionType: transactionType.rawValue,
            timestamp: Date()
        )

        var samples = loadInductionSamples()

        // 去重：同一 candidate 不重复记录
        if samples.contains(sample) { return }

        samples.append(sample)
        // 限制样本总量，保留最近 200 条
        if samples.count > 200 {
            samples = Array(samples.suffix(200))
        }
        saveInductionSamples(samples)

        logger.info("归纳样本记录：\"\(candidate)\" → \(targetPrimary)/\(targetSub)")
    }

    // MARK: 归纳触发

    /// 检查并触发归纳
    /// 当某个 (targetSub, transactionType) 组合的样本数 ≥ 阈值时触发
    /// 返回 true 表示触发了归纳
    @discardableResult
    static func tryTriggerInduction(
        targetPrimary: String,
        targetSub: String,
        transactionType: TransactionType
    ) -> Bool {
        // 跳过时间敏感分类的归纳——餐段应由时间动态推断，不应归纳为固定规则
        guard !CategoryCandidateResolver.timeSensitivePrimaries.contains(targetPrimary) else {
            logger.info("跳过时间敏感分类归纳：\(targetPrimary)")
            return false
        }

        let samples = loadInductionSamples()
        let matchingSamples = samples.filter {
            $0.targetPrimary == targetPrimary &&
            $0.targetSub == targetSub &&
            $0.transactionType == transactionType.rawValue
        }

        guard matchingSamples.count >= inductionThreshold else { return false }

        // 检查是否已有该目标的规则，避免重复归纳
        let existingRules = loadInductionRules()
        let hasRule = existingRules.contains { rule in
            rule.targetPrimary == targetPrimary &&
            rule.targetSub == targetSub &&
            rule.transactionType == transactionType.rawValue
        }
        if hasRule { return false }

        logger.info("触发归纳：\(matchingSamples.count) 个样本 → \(targetPrimary)/\(targetSub)")

        // 异步触发 LLM 归纳
        Task {
            await performInduction(
                samples: matchingSamples,
                targetPrimary: targetPrimary,
                targetSub: targetSub,
                transactionType: transactionType
            )
        }

        return true
    }

    /// 执行 LLM 归纳
    private static func performInduction(
        samples: [InductionSample],
        targetPrimary: String,
        targetSub: String,
        transactionType: TransactionType
    ) async {
        let prompt = buildInductionPrompt(
            samples: samples,
            targetPrimary: targetPrimary,
            targetSub: targetSub
        )

        do {
            let provider = HoloBackendAIProvider(baseURL: HoloBackendEnvironment.baseURL)
            let messages = [ChatMessageDTO(role: "user", content: prompt)]
            let response = try await provider.chat(
                messages: messages,
                purpose: .categoryPatternInduction
            )

            try parseAndSaveInductionRule(
                response: response,
                targetPrimary: targetPrimary,
                targetSub: targetSub,
                transactionType: transactionType,
                sampleCount: samples.count
            )
        } catch {
            logger.error("归纳学习失败：\(error.localizedDescription)")
        }
    }

    /// 构建归纳 Prompt
    private static func buildInductionPrompt(
        samples: [InductionSample],
        targetPrimary: String,
        targetSub: String
    ) -> String {
        let sampleList = samples.enumerated().map { index, sample in
            "\(index + 1). \"\(sample.candidate)\" → \"\(sample.targetSub)\""
        }.joined(separator: "\n")

        return """
        目标分类：\(targetPrimary) · \(targetSub)

        用户分类修正样本：
        \(sampleList)

        请分析这些样本的共性规律，输出匹配模式。
        """
    }

    /// 解析 LLM 响应并保存归纳规则
    private static func parseAndSaveInductionRule(
        response: String,
        targetPrimary: String,
        targetSub: String,
        transactionType: TransactionType,
        sampleCount: Int
    ) throws {
        // 从响应中提取 JSON（找第一个 { 到最后一个 } 之间的内容）
        guard let firstBrace = response.firstIndex(of: "{"),
              let lastBrace = response.lastIndex(of: "}") else {
            logger.warning("归纳响应中未找到 JSON：\(response.prefix(200))")
            return
        }
        let jsonStr = String(response[firstBrace...lastBrace])

        // 尝试解析 JSON
        struct InductionResult: Codable {
            let pattern: String
            let matchType: String
            let confidence: Double
        }

        guard let jsonData = jsonStr.data(using: .utf8),
              let result = try? JSONDecoder().decode(InductionResult.self, from: jsonData),
              result.confidence >= 0.7 else {
            logger.warning("归纳结果解析失败或置信度不足：\(jsonStr.prefix(200))")
            return
        }

        let matchType = MatchType(rawValue: result.matchType) ?? .contains
        let rule = InductionRule(
            pattern: result.pattern.trimmingCharacters(in: .whitespaces).lowercased(),
            matchType: matchType,
            targetPrimary: targetPrimary,
            targetSub: targetSub,
            transactionType: transactionType.rawValue,
            sampleCount: sampleCount,
            createdAt: Date()
        )

        var rules = loadInductionRules()
        rules.append(rule)
        saveInductionRules(rules)

        logger.info("归纳规则已保存：\(rule.matchType.rawValue) \"\(rule.pattern)\" → \(targetPrimary)/\(targetSub)（置信度 \(result.confidence)，基于 \(sampleCount) 个样本）")
    }

    // MARK: 模式匹配

    /// 检查候选词是否匹配某条归纳规则
    private static func matchPattern(candidate: String, rule: InductionRule) -> Bool {
        let pattern = rule.pattern.lowercased()
        guard !pattern.isEmpty else { return false }

        switch rule.matchType {
        case .contains:
            return candidate.contains(pattern)
        case .startsWith:
            return candidate.hasPrefix(pattern)
        case .endsWith:
            return candidate.hasSuffix(pattern)
        }
    }

    // MARK: 归纳规则管理

    /// 获取所有归纳规则
    static func listInductionRules() -> [InductionRule] {
        loadInductionRules().sorted { $0.createdAt > $1.createdAt }
    }

    /// 删除归纳规则
    static func removeInductionRule(at index: Int) {
        var rules = loadInductionRules()
        guard index >= 0, index < rules.count else { return }
        rules.remove(at: index)
        saveInductionRules(rules)
        logger.info("删除归纳规则：索引 \(index)")
    }

    /// 清除所有归纳规则
    static func removeAllInductionRules() {
        UserDefaults.standard.removeObject(forKey: inductionRulesKey)
        logger.info("已清除所有归纳规则")
    }

    // MARK: 归纳样本管理

    /// 获取所有归纳样本
    static func listInductionSamples() -> [InductionSample] {
        loadInductionSamples().sorted { $0.timestamp > $1.timestamp }
    }

    /// 清除所有归纳样本
    static func removeAllInductionSamples() {
        UserDefaults.standard.removeObject(forKey: inductionSamplesKey)
        logger.info("已清除所有归纳样本")
    }

    // MARK: 归纳持久化

    private static func loadInductionSamples() -> [InductionSample] {
        guard let data = UserDefaults.standard.data(forKey: inductionSamplesKey) else { return [] }
        return (try? JSONDecoder().decode([InductionSample].self, from: data)) ?? []
    }

    private static func saveInductionSamples(_ samples: [InductionSample]) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        UserDefaults.standard.set(data, forKey: inductionSamplesKey)
    }

    private static func loadInductionRules() -> [InductionRule] {
        guard let data = UserDefaults.standard.data(forKey: inductionRulesKey) else { return [] }
        return (try? JSONDecoder().decode([InductionRule].self, from: data)) ?? []
    }

    private static func saveInductionRules(_ rules: [InductionRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: inductionRulesKey)
    }
}
