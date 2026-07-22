//
//  HoloThoughtReferenceDataSource.swift
//  Holo
//
//  生产 DataSource：从后台 CoreData context 直接 fetch ThoughtReference，
//  遍历 sourceThought / targetThought 关系构建引用快照。
//
//  线程安全：ThoughtRepository 是 @MainActor，agent 工具不能阻塞主线程，
//  所以这里用 newBackgroundContext + Task.detached，与 HoloDefaultInsightDataSource 一致。
//

import CoreData
import Foundation

struct HoloDefaultThoughtReferenceDataSource: HoloThoughtReferenceDataSource {

    func snapshot() async -> HoloDataSourceRead<HoloThoughtReferenceSnapshot> {
        await CoreDataStack.shared.waitUntilReady()
        do {
            let payload = try await Task.detached(priority: .utility) {
                let context = CoreDataStack.shared.newBackgroundContext()
                return try await context.perform {
                    let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "ThoughtReference")
                    let totalCount = try context.count(for: countRequest)
                    let request = NSFetchRequest<ThoughtReference>(entityName: "ThoughtReference")
                    request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                    request.fetchLimit = 500
                    let refs = try context.fetch(request)
                    let links: [HoloThoughtLinkRecord] = refs.compactMap { ref in
                        guard let source = ref.sourceThought,
                              let target = ref.targetThought,
                              source.isSoftDeleted == false,
                              target.isSoftDeleted == false,
                              source.isArchived == false,
                              target.isArchived == false else {
                            return nil
                        }
                        return HoloThoughtLinkRecord(
                            sourceId: source.id,
                            targetId: target.id,
                            sourceFirstLine: source.firstLine,
                            targetFirstLine: target.firstLine,
                            displayText: ref.displayText,
                            createdAt: ref.createdAt
                        )
                    }
                    return (HoloThoughtReferenceSnapshot(links: links), totalCount, refs.count)
                }
            }.value
            return HoloDataSourceRead(
                value: payload.0,
                status: payload.0.links.isEmpty ? .empty : (payload.1 > payload.2 ? .partial : .success),
                requestedCount: 500,
                returnedCount: payload.0.links.count,
                totalCount: payload.1,
                isTruncated: payload.1 > payload.2,
                warning: payload.1 > payload.2 ? "引用关系超过 500 条，仅分析最近记录" : nil
            )
        } catch {
            return HoloDataSourceRead(
                value: HoloThoughtReferenceSnapshot(links: []), status: .unavailable,
                requestedCount: 500, returnedCount: 0, totalCount: nil, isTruncated: false,
                warning: "想法引用关系读取失败：\(error.localizedDescription)"
            )
        }
    }
}
