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

protocol HoloMemoryFeedbackStore: HoloMemoryForgettingStore {
    /// 删除当前记录（仅供记忆清理与迁移使用；「不再使用」必须走 suppression + 墓碑）。
    func deleteRecord(id: String) async throws -> Bool
}

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
            // 低确认成本方案 §8.5/§12.1：不再使用 = suppression + 语义墓碑，
            // 同锚点同命题不得因换 ID 或同义改写重生（只 deleteRecord 挡不住再萃取）。
            didApply = try await suppressWithTombstone(id: id, now: now)
        }
        #if !HOLO_MEMORY_STANDALONE
        if didApply {
            HoloMemoryReceiptStore.markHandled(memoryID: id, now: now)
            await HoloMemoryQualityMetrics.shared.recordFeedback(
                corrected: false,
                rejected: action == .inaccurate
            )
        }
        #endif
        return didApply
    }

    /// 先写语义墓碑再置 suppressed（与「忘记」同构；即使中途崩溃也不会被后台重新生成）。
    private func suppressWithTombstone(id: String, now: Date) async throws -> Bool {
        guard let record = try await store.fetch(id: id) else { return false }
        let control = try await store.loadControlState()
        let version = max(control.userDecisionVersion, Int64(now.timeIntervalSince1970 * 1_000)) + 1
        try await store.saveTombstone(
            HoloMemoryTombstone(
                identityKey: record.id,
                scope: record.scope,
                claimKind: record.claimKind,
                anchorKeys: HoloMemoryIdentity.canonicalAnchors(record.anchorRefs).map(\.stableKey),
                userDecisionVersion: version,
                createdAt: now
            )
        )
        return try await store.markUserDecision(id: id, decision: .rejected, now: now)
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
        record.adoptionMetadata = HoloMemoryAdoptionMetadata(
            policyVersion: HoloMemoryActivationPolicy.currentVersion,
            disposition: .userConfirmed,
            reason: .explicitUserConfirmation,
            evaluatedAt: now
        )
        record.confidenceScore = max(record.confidenceScore, 0.95)
        record.freshnessScore = 1
        record.recordVersion += 1
        record.predecessorVersionID = predecessorVersionID
        record.updatedAt = now
        try record.validate()
        try await store.replaceRecordForUserControl(record)
        #if !HOLO_MEMORY_STANDALONE
        HoloMemoryReceiptStore.markHandled(memoryID: id, now: now)
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
