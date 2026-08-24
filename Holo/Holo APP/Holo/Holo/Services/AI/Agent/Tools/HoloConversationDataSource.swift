//
//  HoloConversationDataSource.swift
//  Holo
//
//  后台只读 role / intent / timestamp，不读取 content。
//

import CoreData
import Foundation

struct HoloDefaultConversationDataSource: HoloConversationDataSource {

    func recentRecords(limit: Int) async -> [HoloConversationRecord] {
        await CoreDataStack.shared.waitUntilReady()

        do {
            return try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                    request.resultType = .dictionaryResultType
                    request.propertiesToFetch = ["role", "intent", "timestamp"]
                    request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        NSPredicate(
                            format: "role IN %@ AND isStreaming == NO",
                            ["user", "assistant"]
                        ),
                        NSPredicate(format: "deletedAt == nil")
                    ])
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                    request.fetchLimit = max(1, min(limit, 50))

                    return try context.fetch(request).compactMap { row in
                        guard let role = row["role"] as? String,
                              let timestamp = row["timestamp"] as? Date else {
                            return nil
                        }
                        return HoloConversationRecord(
                            role: role,
                            intent: row["intent"] as? String,
                            timestamp: timestamp
                        )
                    }
                }
            }.value
        } catch {
            return []
        }
    }
}
