//
//  HoloMemoryObservationApplier.swift
//  Holo
//
//  将 Validator 校验通过的 Observer 输出应用到 Store
//  职责：状态机转换、并发锁、去重、审计日志
//

import Foundation
import OSLog

struct ApplyResult {
    var newCount: Int
    var hitCount: Int
    var expiredCount: Int
}

final class HoloMemoryObservationApplier {

    private let logger = Logger(subsystem: "com.holo.app", category: "MemoryApplier")
    private let store = HoloEpisodicMemoryStore.shared

    /// 应用一次观察结果
    /// - Returns: 实际写入/更新的记忆数量
    @discardableResult
    func apply(
        validationResult: MemoryObserverValidationResult,
        runID: String
    ) -> ApplyResult {
        // 检查 feature flag
        guard HoloAIFeatureFlags.episodicMemoryObservationEnabled else {
            logger.info("Observer 已关闭，跳过 apply")
            return ApplyResult(newCount: 0, hitCount: 0, expiredCount: 0)
        }

        var newCount = 0
        var hitCount = 0
        var expiredCount = 0

        // 1. 写入新记忆
        let existing = store.load()
        let activeTitles = Set(existing
            .filter { $0.state != .expired && $0.state != .rejected }
            .map(\.title))

        for memory in validationResult.validNewMemories {
            // 去重检查
            guard !activeTitles.contains(memory.title) else {
                logger.info("跳过重复记忆：\(memory.title)")
                continue
            }

            let episodic = HoloEpisodicMemory(
                id: UUID().uuidString,
                title: memory.title,
                summary: memory.summary,
                state: memory.visibility == .suggested ? .suggested : .active,
                visibility: memory.visibility,
                confidence: confidenceFromDouble(memory.confidence),
                sensitivity: memory.sensitivity,
                hitCount: 0,
                semanticHitRunIDs: [runID],
                evidence: memory.evidenceRefs.map { ref in
                    HoloLongTermMemoryEvidence(
                        id: UUID().uuidString,
                        source: .habits,
                        sourceID: ref,
                        excerpt: "信号证据: \(ref)",
                        observedAt: Date()
                    )
                },
                createdAt: Date(),
                updatedAt: Date(),
                lastHitAt: nil,
                expiresAt: Calendar.current.date(byAdding: .day, value: memory.expiresInDays, to: Date())!,
                sourceModules: [.habits, .goals],
                reasoningSummary: memory.reasoningSummary,
                userEditedSummary: nil,
                promotedLongTermMemoryID: nil,
                createdFromRunID: runID
            )

            store.upsert(episodic)
            newCount += 1
        }

        // 2. 处理命中（续期）
        for hit in validationResult.validHits {
            var memories = store.load()
            guard let index = memories.firstIndex(where: { $0.id == hit.episodicMemoryID }) else { continue }
            let original = memories[index]

            // 状态机检查：只有 active/suggested 可以被命中续期
            guard original.state == .active || original.state == .suggested else { continue }

            // 续期：14 天，但不超过 90 天硬上限
            let renewedExpiry = Calendar.current.date(byAdding: .day, value: 14, to: Date())!
            let maxExpiry = Calendar.current.date(byAdding: .day, value: HoloEpisodicMemoryStore.maxLifetimeDays, to: original.createdAt)!
            let finalExpiry = min(renewedExpiry, maxExpiry)

            memories[index] = HoloEpisodicMemory(
                id: original.id,
                title: original.title,
                summary: original.summary,
                state: original.state,
                visibility: original.visibility,
                confidence: original.confidence,
                sensitivity: original.sensitivity,
                hitCount: original.hitCount + 1,
                semanticHitRunIDs: original.semanticHitRunIDs + [runID],
                evidence: original.evidence,
                createdAt: original.createdAt,
                updatedAt: Date(),
                lastHitAt: Date(),
                expiresAt: finalExpiry,
                sourceModules: original.sourceModules,
                reasoningSummary: original.reasoningSummary,
                userEditedSummary: original.userEditedSummary,
                promotedLongTermMemoryID: original.promotedLongTermMemoryID,
                createdFromRunID: original.createdFromRunID,
                schemaVersion: original.schemaVersion
            )

            store.save(memories)
            hitCount += 1
        }

        // 3. 处理弱化/过期
        for weakened in validationResult.validWeakened {
            store.updateState(id: weakened.episodicMemoryID, to: .expired)
            expiredCount += 1
        }

        logger.info("Observer 应用结果: \(newCount) 新增, \(hitCount) 命中, \(expiredCount) 过期")
        return ApplyResult(newCount: newCount, hitCount: hitCount, expiredCount: expiredCount)
    }

    private func confidenceFromDouble(_ value: Double) -> HoloMemoryConfidence {
        if value >= 0.7 { return .high }
        if value >= 0.4 { return .medium }
        return .low
    }
}
