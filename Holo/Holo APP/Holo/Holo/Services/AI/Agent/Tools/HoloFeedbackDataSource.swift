//
//  HoloFeedbackDataSource.swift
//  Holo
//
//  生产 DataSource：直接从 CoreData 后台 context 读 MemoryInsightFeedback。
//
//  重要约束（避免破坏 InsightFeedbackAggregator 的消费链）：
//  - 绝不调用 MemoryInsightRepository.fetchUnconsumedFeedback / markFeedbackConsumed
//  - 只做只读 fetch，不修改 consumedAt
//  - 用 newBackgroundContext 在 Task.detached 里快照读取，不持锁
//

import CoreData
import Foundation

struct HoloDefaultFeedbackDataSource: HoloFeedbackDataSource {

    func recentFeedback(limit: Int) async -> HoloDataSourceRead<[HoloFeedbackRecord]> {
        await CoreDataStack.shared.waitUntilReady()
        let cappedLimit = max(1, min(limit, 50))

        do {
            let payload = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "MemoryInsightFeedback")
                    let totalCount = try context.count(for: countRequest)
                    let request = NSFetchRequest<NSDictionary>(entityName: "MemoryInsightFeedback")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = [
                        "id",
                        "insightId",
                        "accuracyRating",
                        "valueRating",
                        "reasonType",
                        "module",
                        "patternType",
                        "userCorrection",
                        "createdAt"
                    ]
                    request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                    request.fetchLimit = cappedLimit

                    let records = try context.fetch(request).compactMap { row -> HoloFeedbackRecord? in
                        guard let id = row["id"] as? UUID,
                              let insightId = row["insightId"] as? UUID,
                              let createdAt = row["createdAt"] as? Date else {
                            return nil
                        }
                        return HoloFeedbackRecord(
                            id: id,
                            insightId: insightId,
                            accuracyRating: row["accuracyRating"] as? String,
                            valueRating: row["valueRating"] as? String,
                            reasonType: row["reasonType"] as? String,
                            module: row["module"] as? String,
                            patternType: row["patternType"] as? String,
                            userCorrection: row["userCorrection"] as? String,
                            createdAt: createdAt
                        )
                    }
                    return (records, totalCount)
                }
            }.value
            return .loaded(payload.0, requestedCount: cappedLimit, totalCount: payload.1, isTruncated: payload.1 > payload.0.count)
        } catch {
            return HoloDataSourceRead(
                value: [], status: .unavailable, requestedCount: cappedLimit,
                returnedCount: 0, totalCount: nil, isTruncated: false,
                warning: "洞察反馈读取失败：\(error.localizedDescription)"
            )
        }
    }
}
