//
//  StorageCacheService.swift
//  Holo
//
//  缓存大小计算与清理服务
//  只清理安全的缓存/衍生数据，不会删除用户的真实数据
//

import Foundation
import CoreData
import Combine
import os.log

@MainActor
final class StorageCacheService: ObservableObject {

    static let shared = StorageCacheService()

    @Published var cacheSize: Int64 = 0
    @Published var isCalculating = false
    @Published var isClearing = false

    private let logger = Logger(subsystem: "com.holo.app", category: "StorageCacheService")

    var formattedSize: String {
        Self.formatBytes(cacheSize)
    }

    // MARK: - 计算缓存大小

    func calculateCacheSize() async {
        isCalculating = true
        defer { isCalculating = false }

        var totalBytes: Int64 = 0

        // 1. ChatMessage 调试字段（rawLogJSON + analysisContextJSON）
        totalBytes += await calculateChatDebugFieldsSize()

        // 2. 过期/已归档/已拒绝的情景记忆
        totalBytes += calculateExpiredEpisodicMemorySize()

        // 3. Stale/failed MemoryInsight
        totalBytes += calculateStaleInsightSize()

        cacheSize = totalBytes
        logger.info("缓存大小计算完成：\(Self.formatBytes(totalBytes))")
    }

    // MARK: - 清理缓存

    func clearCache() async {
        isClearing = true
        defer { isClearing = false }

        logger.info("开始清理缓存")

        // 1. 清除 Prompt 缓存（内存级，几乎不占空间但一并清理）
        #if DEBUG
        HoloBackendPromptService.shared.clearCache()
        PromptManager.shared.clearCache()
        #endif

        // 2. 清除分类目录缓存
        FinanceCategoryCatalogCache.shared.clear()

        // 3. 清除 ChatMessage 调试字段
        await clearChatDebugFields()

        // 4. 删除 stale/failed MemoryInsight
        let insightRepo = MemoryInsightRepository()
        insightRepo.deleteStaleAndFailed()

        // 5. 删除过期/已归档/已拒绝的情景记忆
        HoloEpisodicMemoryStore.shared.deleteExpiredArchivedRejected()

        logger.info("缓存清理完成，重新计算大小")

        // 重新计算剩余缓存大小
        await calculateCacheSize()
    }

    // MARK: - Size Calculation Helpers

    /// 计算 ChatMessage 中 rawLogJSON + analysisContextJSON 的总字节数
    private func calculateChatDebugFieldsSize() async -> Int64 {
        await Task.detached(priority: .utility) {
            let context = CoreDataStack.shared.newBackgroundContext()
            var total: Int64 = 0

            context.performAndWait {
                let request = NSFetchRequest<NSManagedObject>(entityName: "ChatMessage")
                request.propertiesToFetch = ["rawLogJSON", "analysisContextJSON"]

                do {
                    let results = try context.fetch(request)
                    for message in results {
                        if let raw = message.value(forKey: "rawLogJSON") as? String {
                            total += Int64(raw.utf8.count)
                        }
                        if let analysis = message.value(forKey: "analysisContextJSON") as? String {
                            total += Int64(analysis.utf8.count)
                        }
                    }
                } catch {
                    Logger(subsystem: "com.holo.app", category: "StorageCacheService")
                        .error("计算调试字段大小失败: \(error.localizedDescription)")
                }
            }

            return total
        }.value
    }

    /// 计算已过期/已归档/已拒绝的情景记忆的总字节数
    private func calculateExpiredEpisodicMemorySize() -> Int64 {
        let memories = HoloEpisodicMemoryStore.shared.load()
        let removableStates: Set<HoloEpisodicMemoryState> = [.expired, .archived, .rejected]
        let toDelete = memories.filter { removableStates.contains($0.state) }

        guard !toDelete.isEmpty else { return 0 }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var total: Int64 = 0
        for memory in toDelete {
            if let data = try? encoder.encode(memory) {
                total += Int64(data.count)
            }
        }
        return total
    }

    /// 计算 stale/failed MemoryInsight 的 cardsJSON + rawResponse 总字节数
    private func calculateStaleInsightSize() -> Int64 {
        let request = MemoryInsight.fetchRequest()
        request.predicate = NSPredicate(
            format: "status IN %@",
            [MemoryInsightStatus.stale.rawValue, MemoryInsightStatus.failed.rawValue]
        )
        request.propertiesToFetch = ["cardsJSON", "rawResponse"]

        let context = CoreDataStack.shared.viewContext
        var total: Int64 = 0

        do {
            let results = try context.fetch(request)
            for insight in results {
                total += Int64(insight.cardsJSON.utf8.count)
                if let raw = insight.rawResponse {
                    total += Int64(raw.utf8.count)
                }
            }
        } catch {
            logger.error("计算过期洞察大小失败: \(error.localizedDescription)")
        }

        return total
    }

    // MARK: - Cleanup Helpers

    /// 清除所有 ChatMessage 的 rawLogJSON 和 analysisContextJSON 字段
    private func clearChatDebugFields() async {
        await Task.detached(priority: .utility) {
            let context = CoreDataStack.shared.newBackgroundContext()

            context.performAndWait {
                let request = NSFetchRequest<NSManagedObject>(entityName: "ChatMessage")
                request.propertiesToFetch = ["rawLogJSON", "analysisContextJSON"]
                request.predicate = NSPredicate(
                    format: "rawLogJSON != nil OR analysisContextJSON != nil"
                )

                do {
                    let results = try context.fetch(request)
                    for message in results {
                        message.setValue(nil, forKey: "rawLogJSON")
                        message.setValue(nil, forKey: "analysisContextJSON")
                    }
                    try context.save()
                    Logger(subsystem: "com.holo.app", category: "StorageCacheService")
                        .info("已清理 \(results.count) 条消息的调试字段")
                } catch {
                    Logger(subsystem: "com.holo.app", category: "StorageCacheService")
                        .error("清理调试字段失败: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Formatting

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }
}
