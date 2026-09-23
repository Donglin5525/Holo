//
//  HoloMemoryDecisionBaselineSnapshot.swift
//  Holo
//
//  记忆低确认成本方案 P0 基线快照：candidate 分布统计与迁移前后对账工具。
//
//  仅记录 metadata（计数与稳定身份摘要），不记录记忆正文。
//  P0 用于锁定「adviceEligible candidate 被当作待确认」的口径现状；
//  P3 迁移前后各取一份快照做 count / stableID / recordVersion / 用户决定对账。
//  方案：§14.3「迁移后重新读取 Store 验证五路数量和用户决策未变化」、§17 P0。
//

import Foundation

nonisolated struct HoloMemoryDecisionBaselineSnapshot: Codable, Equatable, Sendable {
    var generatedAt: Date
    var recordCount: Int

    /// 全量生命周期分布（HoloMemoryState.rawValue → count）。
    var stateCounts: [String: Int]
    /// 用户决定分布（HoloMemoryUserDecision.rawValue → count）。
    var userDecisionCounts: [String: Int]
    /// 采用理由分布（adoptionMetadata?.reason.rawValue；无 adoptionMetadata 计 noAdoptionMetadata）。
    var adoptionReasonCounts: [String: Int]
    /// 采用处置分布（automatic / pendingConfirmation / userConfirmed / historicalMigration / noAdoptionMetadata）。
    var adoptionDispositionCounts: [String: Int]
    /// 敏感级别分布（HoloMemorySensitivity.rawValue → count）。
    var sensitivityCounts: [String: Int]

    // candidate 专区：确认债务口径
    var candidateTotal: Int
    /// candidate 的 personalContext admission 分布（HoloContextAdmissionLevel.rawValue；
    /// 无情境载荷的领域/跨域 candidate 计 noPersonalContext）。
    var candidateAdmissionCounts: [String: Int]
    /// 现行口径的待确认数：isVisible && state == candidate（P0 缺陷口径）。
    var candidatePendingByCurrentRule: Int
    /// P1 目标口径的待确认数：现行口径排除 adviceEligible（观察 observeOnly 尚无独立通道，P2 起换用 attentionPolicy）。
    var candidatePendingExcludingAdviceEligible: Int

    /// 排序后的「id@recordVersion」清单摘要（FNV-1a 64），迁移前后比对稳定身份与版本是否被改动。
    var stableIdentityDigest: String
    /// 仅稳定 ID 清单的摘要（版本无关）：迁移对账用——ID 集合不得增删（§16.3）。
    var stableIDListDigest: String
}

nonisolated enum HoloMemoryDecisionBaselineSnapshotBuilder {
    static func build(records: [HoloMemoryRecord], now: Date) -> HoloMemoryDecisionBaselineSnapshot {
        var stateCounts: [String: Int] = [:]
        var userDecisionCounts: [String: Int] = [:]
        var adoptionReasonCounts: [String: Int] = [:]
        var adoptionDispositionCounts: [String: Int] = [:]
        var sensitivityCounts: [String: Int] = [:]
        var candidateAdmissionCounts: [String: Int] = [:]
        var candidateTotal = 0
        var pendingByCurrentRule = 0
        var pendingExcludingAdviceEligible = 0

        for record in records {
            stateCounts[record.state.rawValue, default: 0] += 1
            userDecisionCounts[record.userDecision.rawValue, default: 0] += 1
            sensitivityCounts[record.sensitivity.rawValue, default: 0] += 1
            if let adoption = record.adoptionMetadata {
                adoptionReasonCounts[adoption.reason.rawValue, default: 0] += 1
                adoptionDispositionCounts[adoption.disposition.rawValue, default: 0] += 1
            } else {
                adoptionReasonCounts["noAdoptionMetadata", default: 0] += 1
                adoptionDispositionCounts["noAdoptionMetadata", default: 0] += 1
            }

            guard record.state == .candidate else { continue }
            candidateTotal += 1
            let admissionKey = record.personalContext?.v1?.admission.level.rawValue ?? "noPersonalContext"
            candidateAdmissionCounts[admissionKey, default: 0] += 1

            if HoloMemoryUserVisibility.isPendingConfirmation(record) {
                pendingByCurrentRule += 1
                if admissionKey != HoloContextAdmissionLevel.adviceEligible.rawValue {
                    pendingExcludingAdviceEligible += 1
                }
            }
        }

        let inventory = records
            .map { $0.versionID }
            .sorted()
            .joined(separator: "\n")

        return HoloMemoryDecisionBaselineSnapshot(
            generatedAt: now,
            recordCount: records.count,
            stateCounts: stateCounts,
            userDecisionCounts: userDecisionCounts,
            adoptionReasonCounts: adoptionReasonCounts,
            adoptionDispositionCounts: adoptionDispositionCounts,
            sensitivityCounts: sensitivityCounts,
            candidateTotal: candidateTotal,
            candidateAdmissionCounts: candidateAdmissionCounts,
            candidatePendingByCurrentRule: pendingByCurrentRule,
            candidatePendingExcludingAdviceEligible: pendingExcludingAdviceEligible,
            stableIdentityDigest: fnv1a64(inventory),
            stableIDListDigest: fnv1a64(records.map(\.id).sorted().joined(separator: "\n"))
        )
    }

    /// FNV-1a 64 位摘要：仅用于对账变更检测，不做安全用途。
    private static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
