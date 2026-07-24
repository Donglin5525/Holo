//
//  HoloOutcomeReviewStore.swift
//  Holo
//
//  Agent 成熟度演进 P2 — Outcome Review 持久化存储
//
//  Action Candidate 执行后记录回看数据，由 Observer 或用户触发时计算指标变化。
//  效果回看只能表达相关变化，不把行动与结果自动写成因果。
//

import Foundation

/// Outcome Review 记录的轻量持久化存储。
/// 使用 UserDefaults 存储（非敏感技术元数据：action ID、card ID、metric key、时间戳）。
final class HoloOutcomeReviewStore: @unchecked Sendable {

    static let shared = HoloOutcomeReviewStore()

    private let storageKey = "holo_outcome_reviews"
    private let lock = NSLock()

    private struct PendingReview: Codable {
        var actionID: String
        var sourceCardID: String?
        var targetMetricKey: String
        var executedAt: Date
        var reviewed: Bool
    }

    private init() {}

    /// 记录 action 执行（用户确认执行时调用）。
    func recordExecution(
        actionID: String,
        sourceCardID: String?,
        targetMetricKey: String,
        actionExecuted: Bool
    ) {
        guard actionExecuted else { return }
        lock.lock()
        defer { lock.unlock() }

        var pending = loadPending()
        // 避免重复记录同一 action
        if pending.contains(where: { $0.actionID == actionID }) { return }
        pending.append(PendingReview(
            actionID: actionID,
            sourceCardID: sourceCardID,
            targetMetricKey: targetMetricKey,
            executedAt: Date(),
            reviewed: false
        ))
        // 只保留最近 50 条
        if pending.count > 50 {
            pending = Array(pending.suffix(50))
        }
        savePending(pending)
    }

    /// 获取待回看的 action 列表（观察窗口已过的）。
    func pendingReviews(olderThan days: Int = 14) -> [(actionID: String, metricKey: String, executedAt: Date)] {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = Date().addingTimeInterval(-TimeInterval(days * 86400))
        return loadPending()
            .filter { !$0.reviewed && $0.executedAt < cutoff }
            .map { ($0.actionID, $0.targetMetricKey, $0.executedAt) }
    }

    /// 标记某条 review 已完成。
    func markReviewed(actionID: String) {
        lock.lock()
        defer { lock.unlock() }

        var pending = loadPending()
        for i in pending.indices where pending[i].actionID == actionID {
            pending[i].reviewed = true
        }
        savePending(pending)
    }

    /// 为 Observer 提供回看能力：给定 before/after 值生成 Outcome Review。
    func generateReview(
        actionID: String,
        metricKey: String,
        beforeValue: Double?,
        afterValue: Double?,
        improvementDirection: HoloImprovementDirection = .higherIsBetter
    ) -> HoloOutcomeReview {
        let review = HoloOutcomeReviewEngine.review(
            actionID: actionID,
            sourceClaimID: nil,
            userDecision: .confirmed,
            targetMetricKey: metricKey,
            actionExecuted: true,
            beforeValue: beforeValue,
            afterValue: afterValue,
            improvementDirection: improvementDirection
        )
        markReviewed(actionID: actionID)
        return review
    }

    // MARK: - 持久化

    private func loadPending() -> [PendingReview] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let pending = try? JSONDecoder().decode([PendingReview].self, from: data) else {
            return []
        }
        return pending
    }

    private func savePending(_ pending: [PendingReview]) {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
