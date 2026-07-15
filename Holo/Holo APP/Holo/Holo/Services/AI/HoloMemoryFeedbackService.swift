//
//  HoloMemoryFeedbackService.swift
//  Holo
//
//  用户反馈写入统一记忆仓库的唯一入口。
//

import Foundation

enum HoloMemoryFeedbackAction: String, CaseIterable, Sendable {
    case accurate
    case inaccurate
    case noLongerUse
}

enum HoloMemoryFeedbackError: Error, Equatable {
    case recordNotFound
    case emptyCorrection
}

protocol HoloMemoryFeedbackStore: HoloMemoryForgettingStore {}

#if !HOLO_MEMORY_STANDALONE
extension CoreDataHoloMemoryRepository: HoloMemoryFeedbackStore {}
#endif

struct HoloMemoryFeedbackService: Sendable {
    private let store: any HoloMemoryFeedbackStore

    init(store: any HoloMemoryFeedbackStore) {
        self.store = store
    }

    @discardableResult
    func apply(
        _ action: HoloMemoryFeedbackAction,
        to id: String,
        now: Date = Date()
    ) async throws -> Bool {
        let didApply: Bool
        switch action {
        case .accurate:
            didApply = try await store.markUserDecision(id: id, decision: .confirmed, now: now)
        case .inaccurate:
            didApply = try await store.markUserDecision(id: id, decision: .rejected, now: now)
        case .noLongerUse:
            didApply = try await HoloMemoryForgettingService(store: store).forget(id: id, now: now)
        }
        #if !HOLO_MEMORY_STANDALONE
        if didApply {
            await HoloMemoryQualityMetrics.shared.recordFeedback(
                corrected: false,
                rejected: action == .inaccurate
            )
        }
        #endif
        return didApply
    }

    /// 纠正保留可追溯证据与稳定身份，只创建一个用户确认的新版本。
    func correct(
        id: String,
        summary: String,
        now: Date = Date()
    ) async throws -> HoloMemoryRecord {
        let sanitized = sanitize(summary)
        guard !sanitized.isEmpty else { throw HoloMemoryFeedbackError.emptyCorrection }
        guard var record = try await store.fetch(id: id) else {
            throw HoloMemoryFeedbackError.recordNotFound
        }

        let predecessorVersionID = record.versionID
        record.displaySummary = sanitized
        record.aiUseSummary = sanitized
        record.userDecision = .corrected
        record.state = .active
        record.confidenceScore = max(record.confidenceScore, 0.95)
        record.freshnessScore = 1
        record.recordVersion += 1
        record.predecessorVersionID = predecessorVersionID
        record.updatedAt = now
        try record.validate()
        try await store.replaceRecordForUserControl(record)
        #if !HOLO_MEMORY_STANDALONE
        await HoloMemoryQualityMetrics.shared.recordFeedback(corrected: true, rejected: false)
        #endif
        return record
    }

    private func sanitize(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(500))
    }
}
