//
//  HoloConversationDataSource.swift
//  Holo
//
//  后台只读 role / intent / timestamp，不读取 content。
//

import CoreData
import Foundation

struct HoloDefaultConversationDataSource: HoloConversationDataSource {

    func recentRecords(limit: Int) async -> HoloDataSourceRead<[HoloConversationRecord]> {
        await CoreDataStack.shared.waitUntilReady()
        let cappedLimit = max(1, min(limit, 200))

        do {
            let context = CoreDataStack.shared.newBackgroundContext()
            let payload = try await context.perform {
                    let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "ChatMessage")
                    countRequest.predicate = NSPredicate(
                        format: "role IN %@ AND isStreaming == NO",
                        ["user", "assistant"]
                    )
                    let totalCount = try context.count(for: countRequest)
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = ["id", "role", "intent", "timestamp"]
                    request.predicate = NSPredicate(
                        format: "role IN %@ AND isStreaming == NO",
                        ["user", "assistant"]
                    )
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = cappedLimit

                    let records = try context.fetch(request).compactMap { row in
                        guard let id = row["id"] as? UUID,
                              let role = row["role"] as? String,
                              let timestamp = row["timestamp"] as? Date else {
                            return nil
                        }
                        return HoloConversationRecord(
                            id: id,
                            role: role,
                            intent: row["intent"] as? String,
                            timestamp: timestamp
                        )
                    }
                    return (records, totalCount)
            }
            return .loaded(
                payload.0,
                requestedCount: cappedLimit,
                totalCount: payload.1,
                isTruncated: payload.1 > payload.0.count
            )
        } catch {
            return HoloDataSourceRead(
                value: [],
                status: .unavailable,
                requestedCount: cappedLimit,
                returnedCount: 0,
                totalCount: nil,
                isTruncated: false,
                warning: "对话元数据读取失败：\(error.localizedDescription)"
            )
        }
    }
}
