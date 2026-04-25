//
//  MemoryInsight+CoreDataProperties.swift
//  Holo
//
//  记忆洞察扩展 - 静态方法和工厂方法
//

import Foundation
import CoreData

extension MemoryInsight {

    /// 创建 fetch request
    @nonobjc public class func fetchRequest() -> NSFetchRequest<MemoryInsight> {
        return NSFetchRequest<MemoryInsight>(entityName: "MemoryInsight")
    }

    // MARK: - Factory Methods

    /// 创建生成中状态的洞察记录
    static func createGenerating(
        in context: NSManagedObjectContext,
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date,
        snapshotHash: String
    ) -> MemoryInsight {
        let insight = MemoryInsight(context: context)
        insight.id = UUID()
        insight.periodType = periodType.rawValue
        insight.periodStart = start
        insight.periodEnd = end
        insight.title = ""
        insight.summary = ""
        insight.cardsJSON = "[]"
        insight.rawResponse = nil
        insight.sourceSnapshotHash = snapshotHash
        insight.generatedAt = Date()
        insight.status = MemoryInsightStatus.generating.rawValue
        insight.errorMessage = nil
        insight.promptVersion = 0
        insight.providerName = nil
        return insight
    }

    // MARK: - Query Helpers

    /// 查询指定周期的可用洞察（只返回 ready 或 stale）
    static func fetchAvailable(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date,
        in context: NSManagedObjectContext
    ) -> MemoryInsight? {
        let request = MemoryInsight.fetchRequest()
        request.predicate = NSPredicate(
            format: "periodType == %@ AND periodStart == %@ AND status IN %@",
            periodType.rawValue,
            start as CVarArg,
            [MemoryInsightStatus.ready.rawValue, MemoryInsightStatus.stale.rawValue]
        )
        request.sortDescriptors = [NSSortDescriptor(key: "generatedAt", ascending: false)]
        request.fetchLimit = 1

        return (try? context.fetch(request))?.first
    }

    /// 清理同周期同类型的 failed 记录
    static func cleanupFailed(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date,
        in context: NSManagedObjectContext
    ) {
        let request = MemoryInsight.fetchRequest()
        request.predicate = NSPredicate(
            format: "periodType == %@ AND periodStart == %@ AND status == %@",
            periodType.rawValue,
            start as CVarArg,
            MemoryInsightStatus.failed.rawValue
        )

        guard let failed = try? context.fetch(request) else { return }
        for record in failed {
            context.delete(record)
        }
    }

    // MARK: - Update Methods

    /// 标记为 ready 状态并填充 AI 结果
    func markReady(
        payload: MemoryInsightPayload,
        rawResponse: String,
        providerName: String?,
        promptVersion: Int16
    ) {
        title = payload.title
        summary = payload.summary
        if let data = try? JSONEncoder().encode(payload),
           let json = String(data: data, encoding: .utf8) {
            cardsJSON = json
        }
        self.rawResponse = rawResponse
        status = MemoryInsightStatus.ready.rawValue
        self.providerName = providerName
        self.promptVersion = promptVersion
        generatedAt = Date()
    }

    /// 标记为 failed 状态
    func markFailed(errorMessage: String) {
        status = MemoryInsightStatus.failed.rawValue
        self.errorMessage = String(errorMessage.prefix(200))
    }

    /// 标记为 stale 状态
    func markStale() {
        if status == MemoryInsightStatus.ready.rawValue {
            status = MemoryInsightStatus.stale.rawValue
        }
    }
}
