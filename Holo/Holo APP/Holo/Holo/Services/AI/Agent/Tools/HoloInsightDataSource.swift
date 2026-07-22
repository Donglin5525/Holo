//
//  HoloInsightDataSource.swift
//  Holo
//
//  后台只读用户可见的洞察标题与摘要，不读取 rawResponse/cardsJSON/反馈原文。
//

import CoreData
import Foundation

struct HoloDefaultInsightDataSource: HoloInsightDataSource {

    func recentInsights(limit: Int) async -> HoloDataSourceRead<[HoloInsightToolRecord]> {
        await CoreDataStack.shared.waitUntilReady()
        let cappedLimit = max(1, min(limit, 50))

        do {
            let payload = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let predicate = NSPredicate(
                        format: "status IN %@",
                        [MemoryInsightStatus.ready.rawValue, MemoryInsightStatus.stale.rawValue]
                    )
                    let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "MemoryInsight")
                    countRequest.predicate = predicate
                    let totalCount = try context.count(for: countRequest)
                    let request = NSFetchRequest<NSDictionary>(entityName: "MemoryInsight")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = [
                        "id",
                        "periodType",
                        "periodStart",
                        "periodEnd",
                        "title",
                        "summary",
                        "generatedAt",
                        "status"
                    ]
                    request.predicate = predicate
                    request.sortDescriptors = [NSSortDescriptor(key: "generatedAt", ascending: false)]
                    request.fetchLimit = cappedLimit

                    let records = try context.fetch(request).compactMap { row in
                        guard let id = row["id"] as? UUID,
                              let periodType = row["periodType"] as? String,
                              let periodStart = row["periodStart"] as? Date,
                              let periodEnd = row["periodEnd"] as? Date,
                              let title = row["title"] as? String,
                              let summary = row["summary"] as? String,
                              let generatedAt = row["generatedAt"] as? Date,
                              let status = row["status"] as? String else {
                            return nil
                        }
                        return HoloInsightToolRecord(
                            id: id,
                            periodType: periodType,
                            periodStart: periodStart,
                            periodEnd: periodEnd,
                            title: title,
                            summary: summary,
                            generatedAt: generatedAt,
                            status: status
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
                warning: "历史观察读取失败：\(error.localizedDescription)"
            )
        }
    }
}
