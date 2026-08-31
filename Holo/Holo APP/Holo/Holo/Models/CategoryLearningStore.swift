//
//  CategoryLearningStore.swift
//  Holo
//
//  分类学习存储层：内存缓存 + CloudKit 同步实体
//  对外保持 CategoryLearnedMapping 同步 API 不变；
//  写路径「先更新缓存、再异步落库」，读路径永远走缓存（启动时全量 hydrate 一次）。
//  云端变更（重装恢复/多设备）落地后自动回流缓存。
//

import Foundation
import CoreData
import os.log

/// 分类学习存储仓库
/// 线程安全：NSLock 保护内存缓存；CoreData 读写走独占 background context。
nonisolated final class CategoryLearningStore {

    static let shared = CategoryLearningStore()

    private let logger = Logger(subsystem: "com.holo.app", category: "CategoryLearningStore")

    private let lock = NSLock()
    /// 精确映射缓存：与历史 UserDefaults 结构一致（key: type|primary|candidate → value: primary|sub）
    nonisolated(unsafe) private var mappingsCache: [String: String] = [:]
    /// 归纳规则缓存
    nonisolated(unsafe) private var rulesCache: [CategoryLearnedMapping.InductionRule] = []

    nonisolated(unsafe) private let context: NSManagedObjectContext

    private var remoteChangeObserver: NSObjectProtocol?
    /// UserDefaults → 同步实体的迁移标记（迁移成功后落 UserDefaults，防止重复搬运）
    private static let legacyMigrationDoneKey = "categoryLearningCloudMigrationDone"

    private init() {
        let ctx = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context = ctx
    }

    // MARK: - 启动装配

    /// 启动装配：hydrate 缓存 + 存量 UserDefaults 迁移 + 云端变更监听（均幂等，可重复调用）
    func bootstrap() async {
        await CoreDataStack.shared.waitUntilReady()
        hydrateFromStore()
        migrateLegacyUserDefaults()
        observeRemoteChanges()
    }

    /// 全量拉取同步实体覆盖缓存。
    /// 写路径总是「先落库再 hydrate 覆盖」或「先改缓存再落库」，fetch 结果即最新真相，直接覆盖安全。
    private func hydrateFromStore() {
        context.perform { [weak self] in
            guard let self else { return }
            let mappingRows = (try? self.context.fetch(CategoryMappingRecordEntity.fetchRequest())) ?? []
            let ruleRows = (try? self.context.fetch(CategoryInductionRuleEntity.fetchRequest())) ?? []

            var mappings: [String: String] = [:]
            mappings.reserveCapacity(mappingRows.count)
            for row in mappingRows where !row.mappingKey.isEmpty {
                mappings[row.mappingKey] = "\(row.targetPrimary)|\(row.targetSub)"
            }
            let rules = ruleRows.compactMap { CategoryLearningStore.rule(from: $0) }

            self.lock.lock()
            self.mappingsCache = mappings
            self.rulesCache = rules
            self.lock.unlock()
        }
    }

    /// 监听持久层远端变更（iCloud 恢复/多设备同步落地），防抖后回流缓存
    private func observeRemoteChanges() {
        guard remoteChangeObserver == nil else { return }
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: CoreDataStack.shared.persistentContainer.persistentStoreCoordinator,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.rehydrateDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.hydrateFromStore()
            }
            self.rehydrateDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }

    nonisolated(unsafe) private var rehydrateDebounce: DispatchWorkItem?

    // MARK: - 缓存读取

    func cachedMappings() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return mappingsCache
    }

    func cachedRules() -> [CategoryLearnedMapping.InductionRule] {
        lock.lock()
        defer { lock.unlock() }
        return rulesCache
    }

    // MARK: - 精确映射写入

    /// upsert 一批精确映射（key/value 为历史 UserDefaults 原始格式）
    func upsertMappings(_ entries: [String: String]) {
        guard !entries.isEmpty else { return }

        lock.lock()
        for (key, value) in entries {
            mappingsCache[key] = value
        }
        lock.unlock()

        let keys = Array(entries.keys)
        context.perform { [weak self] in
            guard let self else { return }
            let request = CategoryMappingRecordEntity.fetchRequest()
            request.predicate = NSPredicate(format: "mappingKey IN %@", keys)
            let existing = (try? self.context.fetch(request)) ?? []
            let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.mappingKey, $0) })

            let now = Date()
            var changed = false
            for (key, value) in entries {
                // 解析字段仅用于展示；原始 key/value 保持历史格式
                let keyParts = key.components(separatedBy: "|")
                let valueParts = value.components(separatedBy: "|")
                guard keyParts.count == 3, valueParts.count == 2 else { continue }

                if let row = existingByKey[key] {
                    guard row.targetPrimary != valueParts[0] || row.targetSub != valueParts[1] else { continue }
                    row.targetPrimary = valueParts[0]
                    row.targetSub = valueParts[1]
                    row.updatedAt = now
                } else {
                    let row = CategoryMappingRecordEntity(context: self.context)
                    row.mappingKey = key
                    row.transactionType = keyParts[0]
                    row.primaryCategory = keyParts[1]
                    row.candidate = keyParts[2]
                    row.targetPrimary = valueParts[0]
                    row.targetSub = valueParts[1]
                    row.updatedAt = now
                }
                changed = true
            }
            if changed {
                try? self.context.save()
            }
        }
    }

    func removeMapping(key: String) {
        lock.lock()
        mappingsCache.removeValue(forKey: key)
        lock.unlock()

        context.perform { [weak self] in
            guard let self else { return }
            let request = CategoryMappingRecordEntity.fetchRequest()
            request.predicate = NSPredicate(format: "mappingKey == %@", key)
            for row in (try? self.context.fetch(request)) ?? [] {
                self.context.delete(row)
            }
            if self.context.hasChanges {
                try? self.context.save()
            }
        }
    }

    func removeAllMappings() {
        lock.lock()
        mappingsCache.removeAll()
        lock.unlock()

        context.perform { [weak self] in
            guard let self else { return }
            for row in (try? self.context.fetch(CategoryMappingRecordEntity.fetchRequest())) ?? [] {
                self.context.delete(row)
            }
            if self.context.hasChanges {
                try? self.context.save()
            }
        }
    }

    // MARK: - 归纳规则写入

    func upsertRule(_ rule: CategoryLearnedMapping.InductionRule) {
        let ruleKey = Self.ruleKey(for: rule)

        lock.lock()
        if let index = rulesCache.firstIndex(where: { Self.ruleKey(for: $0) == ruleKey }) {
            rulesCache[index] = rule
        } else {
            rulesCache.append(rule)
        }
        lock.unlock()

        context.perform { [weak self] in
            guard let self else { return }
            let request = CategoryInductionRuleEntity.fetchRequest()
            request.predicate = NSPredicate(format: "ruleKey == %@", ruleKey)
            let existing = (try? self.context.fetch(request))?.first

            let row = existing ?? CategoryInductionRuleEntity(context: self.context)
            if existing == nil {
                row.ruleKey = ruleKey
                row.createdAt = rule.createdAt
            }
            row.pattern = rule.pattern
            row.matchType = rule.matchType.rawValue
            row.transactionType = rule.transactionType
            row.targetPrimary = rule.targetPrimary
            row.targetSub = rule.targetSub
            row.sampleCount = Int64(rule.sampleCount)
            row.updatedAt = Date()
            try? self.context.save()
        }
    }

    func removeAllRules() {
        lock.lock()
        rulesCache.removeAll()
        lock.unlock()

        context.perform { [weak self] in
            guard let self else { return }
            for row in (try? self.context.fetch(CategoryInductionRuleEntity.fetchRequest())) ?? [] {
                self.context.delete(row)
            }
            if self.context.hasChanges {
                try? self.context.save()
            }
        }
    }

    /// 删除一条归纳规则（按规则内容定位，替代历史按索引删除——同步场景索引会漂移）
    func removeRule(matching rule: CategoryLearnedMapping.InductionRule) {
        let ruleKey = Self.ruleKey(for: rule)

        lock.lock()
        rulesCache.removeAll { Self.ruleKey(for: $0) == ruleKey }
        lock.unlock()

        context.perform { [weak self] in
            guard let self else { return }
            let request = CategoryInductionRuleEntity.fetchRequest()
            request.predicate = NSPredicate(format: "ruleKey == %@", ruleKey)
            for row in (try? self.context.fetch(request)) ?? [] {
                self.context.delete(row)
            }
            if self.context.hasChanges {
                try? self.context.save()
            }
        }
    }

    // MARK: - 存量迁移（UserDefaults → 同步实体）

    /// 把 UserDefaults 里的历史学习数据搬进同步实体，搬运成功后删除旧 key。
    /// upsert 幂等，迁移标记防重复搬运。
    private func migrateLegacyUserDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.legacyMigrationDoneKey) else { return }

        var entries: [String: String] = [:]
        if let data = defaults.data(forKey: "categoryLearnedMappings"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            entries.merge(decoded) { _, new in new }
        }

        var rules: [CategoryLearnedMapping.InductionRule] = []
        if let data = defaults.data(forKey: "categoryInductionRules"),
           let decoded = try? JSONDecoder().decode([CategoryLearnedMapping.InductionRule].self, from: data) {
            rules = decoded
        }

        guard !entries.isEmpty || !rules.isEmpty else {
            defaults.set(true, forKey: Self.legacyMigrationDoneKey)
            return
        }

        context.perform { [weak self] in
            guard let self else { return }

            // 映射：查已有行，仅补缺（云端可能已恢复出部分数据）
            let keys = Array(entries.keys)
            let mappingRequest = CategoryMappingRecordEntity.fetchRequest()
            mappingRequest.predicate = NSPredicate(format: "mappingKey IN %@", keys)
            let existingMappings = (try? self.context.fetch(mappingRequest)) ?? []
            let existingKeys = Set(existingMappings.map(\.mappingKey))

            let now = Date()
            var inserted = 0
            for (key, value) in entries where !existingKeys.contains(key) {
                let keyParts = key.components(separatedBy: "|")
                let valueParts = value.components(separatedBy: "|")
                guard keyParts.count == 3, valueParts.count == 2 else { continue }

                let row = CategoryMappingRecordEntity(context: self.context)
                row.mappingKey = key
                row.transactionType = keyParts[0]
                row.primaryCategory = keyParts[1]
                row.candidate = keyParts[2]
                row.targetPrimary = valueParts[0]
                row.targetSub = valueParts[1]
                row.updatedAt = now
                inserted += 1
            }

            // 规则：按 ruleKey 去重补缺
            let ruleRequest = CategoryInductionRuleEntity.fetchRequest()
            let existingRuleKeys = Set(((try? self.context.fetch(ruleRequest)) ?? []).map(\.ruleKey))
            var insertedRules = 0
            for rule in rules {
                let ruleKey = Self.ruleKey(for: rule)
                guard !existingRuleKeys.contains(ruleKey) else { continue }

                let row = CategoryInductionRuleEntity(context: self.context)
                row.ruleKey = ruleKey
                row.pattern = rule.pattern
                row.matchType = rule.matchType.rawValue
                row.transactionType = rule.transactionType
                row.targetPrimary = rule.targetPrimary
                row.targetSub = rule.targetSub
                row.sampleCount = Int64(rule.sampleCount)
                row.createdAt = rule.createdAt
                row.updatedAt = now
                insertedRules += 1
            }

            do {
                try self.context.save()

                self.lock.lock()
                for (key, value) in entries {
                    self.mappingsCache[key] = value
                }
                let knownRuleKeys = Set(self.rulesCache.map { Self.ruleKey(for: $0) })
                self.rulesCache.append(contentsOf: rules.filter { !knownRuleKeys.contains(Self.ruleKey(for: $0)) })
                self.lock.unlock()

                // 搬运成功：清理 UserDefaults 旧数据（归纳样本/交易候选暂存保留本地）
                defaults.removeObject(forKey: "categoryLearnedMappings")
                defaults.removeObject(forKey: "categoryInductionRules")
                defaults.set(true, forKey: Self.legacyMigrationDoneKey)
                self.logger.info("学习映射迁移完成：\(inserted) 条映射 + \(insertedRules) 条规则入同步表")
            } catch {
                self.logger.error("学习映射迁移失败，保留 UserDefaults 待重试：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 从交易历史重建（恢复工具）

    /// 扫描 AI 创建的交易（isAICreated + aiCandidate 随交易走 iCloud 恢复），
    /// 以「AI 原始候选 → 用户最终分类」重放学习映射。
    /// AI 猜对的不学（下次照样能猜对，学成映射只会虚胖表）。
    /// - Returns: 本次重建实际写入的映射条数（排除缓存中已有的）
    @discardableResult
    func rebuildFromTransactions() async -> Int {
        await CoreDataStack.shared.waitUntilReady()

        let existing = cachedMappings()

        let entries: [String: String] = await withCheckedContinuation { continuation in
            context.perform { [weak self] in
                guard let self else {
                    continuation.resume(returning: [:])
                    return
                }

                let request = Transaction.fetchRequest()
                request.predicate = NSPredicate(
                    format: "isAICreated == YES AND aiCandidate != nil AND deletedAt == nil"
                )
                let transactions = (try? self.context.fetch(request)) ?? []

                var entries: [String: String] = [:]
                for tx in transactions {
                    guard let candidate = tx.aiCandidate?
                              .trimmingCharacters(in: .whitespaces), !candidate.isEmpty,
                          let category = tx.category,
                          let names = self.resolveCategoryNames(in: self.context, category: category)
                    else { continue }

                    let subName = names.sub ?? names.primary
                    let normalized = candidate.trimmingCharacters(in: .whitespaces).lowercased()
                    guard normalized != category.name.lowercased(),
                          normalized != subName.lowercased()
                    else { continue }

                    // primary 维度留空（重建拿不到 AI 当时的原始一级），运行时查找两级匹配可兜住
                    let key = "\(tx.transactionType.rawValue)||\(normalized)"
                    entries[key] = "\(names.primary)|\(subName)"
                }
                continuation.resume(returning: entries)
            }
        }

        let fresh = entries.filter { existing[$0.key] == nil }
        if !fresh.isEmpty {
            upsertMappings(fresh)
        }
        return fresh.count
    }

    /// 在指定上下文内解析分类层级名（一级返回 primary；二级查父级补 primary）
    private func resolveCategoryNames(
        in context: NSManagedObjectContext,
        category: Category
    ) -> (primary: String, sub: String?)? {
        guard let parent = category.parentId else {
            return (category.name, nil)
        }
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", parent as CVarArg)
        let parentName = (try? context.fetch(request))?.first?.name ?? ""
        guard !parentName.isEmpty else { return nil }
        return (parentName, category.name)
    }

    // MARK: - 转换

    private static func ruleKey(for rule: CategoryLearnedMapping.InductionRule) -> String {
        [
            rule.pattern,
            rule.matchType.rawValue,
            rule.transactionType,
            rule.targetPrimary,
            rule.targetSub
        ].joined(separator: "\u{1F}")
    }

    private static func rule(from row: CategoryInductionRuleEntity) -> CategoryLearnedMapping.InductionRule? {
        guard let matchType = CategoryLearnedMapping.MatchType(rawValue: row.matchType),
              let type = TransactionType(rawValue: row.transactionType) else { return nil }
        return CategoryLearnedMapping.InductionRule(
            pattern: row.pattern,
            matchType: matchType,
            targetPrimary: row.targetPrimary,
            targetSub: row.targetSub,
            transactionType: type.rawValue,
            sampleCount: Int(row.sampleCount),
            createdAt: row.createdAt
        )
    }
}
