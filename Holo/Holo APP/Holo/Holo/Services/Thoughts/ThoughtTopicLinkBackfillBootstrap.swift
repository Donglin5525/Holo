//
//  ThoughtTopicLinkBackfillBootstrap.swift
//  Holo
//
//  V3 Phase 1 启动入口：一次性回填存量想法-主题关系到 ThoughtTopicLink。
//  独立薄文件（只被 App 引用）：保持 ThoughtTopicLinkProjection 纯 context 注入式，
//  便于 standalone 测试不拖 CoreDataStack/CloudKit 依赖。
//

import CoreData
import Foundation
import OSLog

enum ThoughtTopicLinkBackfillBootstrap {

    private static let onceKey = "thoughtSemanticV3.topicLinkBackfillDone"
    private static let logger = Logger(subsystem: "com.holo.Holo", category: "ThoughtTopicLink")

    /// App 启动后台调用（幂等，per 设备一次）。失败不打标记，下次启动重试。
    static func performIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: onceKey) else { return }
        Task.detached(priority: .utility) {
            let stack = CoreDataStack.shared
            await stack.waitUntilReady()
            do {
                let report: ThoughtTopicLinkProjection.BackfillReport = try await stack.performBackgroundTask { context in
                    try ThoughtTopicLinkProjection.backfillLegacyLinks(in: context)
                }
                UserDefaults.standard.set(true, forKey: onceKey)
                // 无正文审计：只记计数（方案 §18.2）
                logger.info("V3 topicLink 回填完成 thoughts=\(report.scannedThoughts) pairs=\(report.pairsExamined) created=\(report.linksCreated) skipped=\(report.linksSkippedExisting) preservedUserDecision=\(report.linksPreservedUserDecision)")
            } catch {
                logger.error("V3 topicLink 回填失败，下次启动重试：\(error.localizedDescription)")
            }
        }
    }
}
