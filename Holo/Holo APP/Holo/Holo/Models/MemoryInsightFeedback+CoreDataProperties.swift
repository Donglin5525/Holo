//
//  MemoryInsightFeedback+CoreDataProperties.swift
//  Holo
//
//  洞察反馈扩展 - 静态方法和工厂方法
//

import Foundation
import CoreData

extension MemoryInsightFeedback {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<MemoryInsightFeedback> {
        return NSFetchRequest<MemoryInsightFeedback>(entityName: "MemoryInsightFeedback")
    }

    // MARK: - Factory Methods

    /// 创建反馈记录
    static func create(
        in context: NSManagedObjectContext,
        insightId: UUID,
        cardId: String?,
        accuracyRating: AccuracyRating?,
        valueRating: ValueRating?,
        reasonType: FeedbackReasonType?,
        module: String?,
        patternType: String?,
        userCorrection: String?
    ) -> MemoryInsightFeedback {
        let feedback = MemoryInsightFeedback(context: context)
        feedback.id = UUID()
        feedback.insightId = insightId
        feedback.cardId = cardId
        feedback.accuracyRating = accuracyRating?.rawValue
        feedback.valueRating = valueRating?.rawValue
        feedback.reasonType = reasonType?.rawValue
        feedback.module = module
        feedback.patternType = patternType
        feedback.userCorrection = userCorrection
        feedback.createdAt = Date()
        feedback.consumedAt = nil
        return feedback
    }

    // MARK: - Query Helpers

    /// 查询未消费的反馈（聚合器使用）
    static func fetchUnconsumed(in context: NSManagedObjectContext) -> [MemoryInsightFeedback] {
        let request = MemoryInsightFeedback.fetchRequest()
        request.predicate = NSPredicate(format: "consumedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// 查询指定洞察的反馈
    static func fetchForInsight(
        insightId: UUID,
        in context: NSManagedObjectContext
    ) -> [MemoryInsightFeedback] {
        let request = MemoryInsightFeedback.fetchRequest()
        request.predicate = NSPredicate(format: "insightId == %@", insightId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    /// 查询指定卡片是否已有反馈
    static func hasFeedback(
        cardId: String,
        in context: NSManagedObjectContext
    ) -> Bool {
        let request = MemoryInsightFeedback.fetchRequest()
        request.predicate = NSPredicate(format: "cardId == %@", cardId)
        request.fetchLimit = 1
        return ((try? context.fetch(request)) ?? []).isEmpty == false
    }

    // MARK: - Update Methods

    /// 标记为已消费（聚合器使用）
    func markConsumed() {
        consumedAt = Date()
    }
}
