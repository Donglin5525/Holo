//
//  ConvergenceRejectionRepository.swift
//  Holo
//
//  主题归并「建议级拒绝」仓储（P2.5）
//  幂等键 = 主题名 + 来源词集合（语义级，不含观点 ID/hash）
//  观点集合随新增想法动态变化，用观点 hash 做键会导致「拒绝过的主题因新想法再次弹出」(spec §6.4 决策 10)
//  spec: docs/superpowers/specs/2026-06-23-thought-knowledge-tree-design.md
//

import Foundation
import CoreData
import OSLog

@MainActor
final class ConvergenceRejectionRepository {

    /// 默认抑制有效期（天）：拒绝过的建议 90 天内不再重复弹出
    nonisolated static let defaultExpiryDays = 90

    private let context: NSManagedObjectContext
    private let logger = Logger(subsystem: "com.holo.app", category: "ConvergenceRejectionRepo")

    init(context: NSManagedObjectContext = CoreDataStack.shared.viewContext) {
        self.context = context
    }

    /// 无显式清理任务，规避 iOS 26.3 Simulator 的 MainActor 兼容析构重复释放。
    nonisolated deinit {}

    // MARK: - 归一化幂等键

    /// 幂等键 = 归一化主题名 + 排序后归一化来源词集合
    /// 集合语义：无关顺序、大小写、首尾空格（避免同一建议因来源词排列不同判不同键）
    static func suggestionKey(topicTitle: String, sourceTerms: [String]) -> String {
        let normalizedTitle = topicTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTerms = sourceTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ",")
        return "\(normalizedTitle)|\(normalizedTerms)"
    }

    // MARK: - 拒绝（幂等）

    /// 记录一次建议级拒绝。同 suggestionKey 已存在则更新 rejectedAt/expiresAt（不重复创建）。
    /// - Parameters:
    ///   - topicTitle: 建议主题名
    ///   - sourceTerms: 来源词集合
    ///   - expiresInDays: 抑制有效期（天），到期后不再抑制
    func reject(topicTitle: String, sourceTerms: [String], expiresInDays: Int = defaultExpiryDays) throws {
        let key = Self.suggestionKey(topicTitle: topicTitle, sourceTerms: sourceTerms)
        let now = Date()
        let expiry = now.addingTimeInterval(TimeInterval(expiresInDays) * 24 * 3600)

        if let existing = try fetchByKey(key) {
            existing.rejectedAt = now
            existing.expiresAt = expiry
            try context.save()
            logger.info("更新建议拒绝：\(key, privacy: .public)")
            return
        }

        let rejection = ThoughtTagConvergenceRejection(context: context)
        rejection.id = UUID()
        rejection.suggestionKey = key
        rejection.topicTitle = topicTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        rejection.sourceTermsText = sourceTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        rejection.rejectedAt = now
        rejection.expiresAt = expiry
        rejection.createdAt = now
        try context.save()
        logger.info("新建建议拒绝：\(key, privacy: .public)")
    }

    // MARK: - 查询

    /// 当前是否处于被拒绝抑制期（同 key 且未过期）
    func isRejected(topicTitle: String, sourceTerms: [String]) -> Bool {
        let key = Self.suggestionKey(topicTitle: topicTitle, sourceTerms: sourceTerms)
        guard let existing = try? fetchByKey(key) else { return false }
        return existing.expiresAt > Date()
    }

    /// 所有未过期的拒绝记录（供收敛 Job 调 AI 时传「已拒绝建议」，避免重复建议）
    func fetchActiveRejections() throws -> [ThoughtTagConvergenceRejection] {
        let request = ThoughtTagConvergenceRejection.fetchRequest()
        request.predicate = NSPredicate(format: "expiresAt > %@", Date() as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "rejectedAt", ascending: false)]
        return try context.fetch(request)
    }

    /// 清理过期拒绝记录（可选维护）
    @discardableResult
    func purgeExpired() throws -> Int {
        let request = ThoughtTagConvergenceRejection.fetchRequest()
        request.predicate = NSPredicate(format: "expiresAt <= %@", Date() as CVarArg)
        let expired = try context.fetch(request)
        for r in expired {
            context.delete(r)
        }
        if !expired.isEmpty {
            try context.save()
            logger.info("清理过期建议拒绝：\(expired.count) 条")
        }
        return expired.count
    }

    // MARK: - Private

    private func fetchByKey(_ key: String) throws -> ThoughtTagConvergenceRejection? {
        let request = ThoughtTagConvergenceRejection.fetchRequest()
        request.predicate = NSPredicate(format: "suggestionKey == %@", key)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}
