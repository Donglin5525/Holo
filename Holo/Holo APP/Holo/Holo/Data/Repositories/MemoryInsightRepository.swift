//
//  MemoryInsightRepository.swift
//  Holo
//
//  记忆洞察数据仓储层
//  负责洞察记录的查询、保存、状态更新
//

import Foundation
import CoreData
import os.log

/// 记忆洞察数据仓储
final class MemoryInsightRepository {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryInsightRepository")

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext = CoreDataStack.shared.viewContext) {
        self.context = context
    }

    // MARK: - Fetch

    /// 查询指定周期的可用洞察（只返回 ready 或 stale）
    /// 按 generatedAt 降序取最新一条
    func fetchInsight(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date
    ) throws -> MemoryInsight? {
        MemoryInsight.fetchAvailable(
            periodType: periodType,
            start: start,
            end: end,
            in: context
        )
    }

    /// 查询任意状态的洞察（包含 generating/failed）
    func fetchAnyInsight(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date
    ) throws -> MemoryInsight? {
        let request = MemoryInsight.fetchRequest()
        request.predicate = NSPredicate(
            format: "periodType == %@ AND periodStart == %@",
            periodType.rawValue,
            start as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(key: "generatedAt", ascending: false)]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    // MARK: - Save Generating

    /// 生成前保存 generating 状态，同时清理同周期旧的 failed 记录
    func saveGenerating(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date,
        snapshotHash: String
    ) throws -> MemoryInsight {
        // 清理旧的 failed 记录
        MemoryInsight.cleanupFailed(
            periodType: periodType,
            start: start,
            end: end,
            in: context
        )

        let insight = MemoryInsight.createGenerating(
            in: context,
            periodType: periodType,
            start: start,
            end: end,
            snapshotHash: snapshotHash
        )
        try context.save()
        return insight
    }

    // MARK: - Save Ready

    /// AI 生成成功后更新为 ready 状态
    func saveReady(
        insight: MemoryInsight,
        payload: MemoryInsightPayload,
        rawResponse: String,
        providerName: String?,
        promptVersion: Int16
    ) throws {
        insight.markReady(
            payload: payload,
            rawResponse: rawResponse,
            providerName: providerName,
            promptVersion: promptVersion
        )
        try context.save()
    }

    // MARK: - Save Failed

    /// AI 生成失败后更新为 failed 状态
    func saveFailed(
        insight: MemoryInsight,
        errorMessage: String
    ) throws {
        insight.markFailed(errorMessage: errorMessage)
        try context.save()
    }

    // MARK: - Mark Stale

    /// 快照 hash 变化时将 ready 标记为 stale
    func markStaleIfNeeded(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date,
        newSnapshotHash: String
    ) throws {
        guard let insight = try fetchInsight(periodType: periodType, start: start, end: end) else {
            return
        }

        if insight.sourceSnapshotHash != newSnapshotHash && insight.status == MemoryInsightStatus.ready.rawValue {
            insight.markStale()
            try context.save()
            Self.logger.info("洞察已标记 stale：\(periodType.rawValue)")
        }
    }
}
