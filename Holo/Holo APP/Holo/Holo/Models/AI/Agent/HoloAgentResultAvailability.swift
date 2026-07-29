//
//  HoloAgentResultAvailability.swift
//  Holo
//
//  连续追问 Phase 5：历史结果的有效性状态（§10 expired reanalyze）。
//
//  历史分析结果可能因底层数据变化（evidence 被清理、时间范围已过期）而失效。
//  追问一份已失效的结果会拿到过时信息，所以需要在锚定前检查有效性。
//
//  四态（§10）：
//  - checking：正在检查
//  - available：结果有效，可安全追问
//  - reanalyzeRequired：结果已失效（evidence 被清理），应重新分析而非追问
//  - temporarilyUnavailable：检查失败（store 读错等），不阻断但提示
//

import Foundation

/// 历史结果的有效性状态。
nonisolated enum HoloAgentResultAvailability: Equatable, Sendable {
    case checking
    case available
    case reanalyzeRequired(reason: String)
    case temporarilyUnavailable(reason: String)

    /// 是否可以安全追问（只有 available 放行）。
    var canFollowUp: Bool {
        if case .available = self { return true }
        return false
    }

    /// 用户可见的简短提示文案。
    var userFacingHint: String? {
        switch self {
        case .checking:
            return "正在确认这份分析是否仍然有效…"
        case .available:
            return nil
        case .reanalyzeRequired:
            return "这份分析依据的数据已过期，建议重新发起分析后再追问。"
        case .temporarilyUnavailable:
            return "暂时无法确认这份分析的有效性，追问结果可能不准确。"
        }
    }
}

/// 有效性检查器：根据 evidence 当前状态判断一份历史结果是否仍然有效。
/// 复用 Context Guard 的授权语义——evidence 全部失效则结果 expired。
nonisolated enum HoloAgentResultAvailabilityChecker {

    /// 检查一份历史结果的有效性。
    /// - Parameters:
    ///   - result: 待检查的历史结果。
    ///   - availableEvidence: 当前 evidence ledger 里的全部有效记录。
    static func check(
        result: HoloAgentResult,
        availableEvidence: [HoloEvidenceRecord]
    ) -> HoloAgentResultAvailability {
        // 无 evidence 引用的结果（如纯文字结论）视为有效——没有数据依赖就不会过期。
        if result.evidenceIDs.isEmpty {
            return .available
        }
        let evidenceByID = Dictionary(availableEvidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 统计引用的 evidence 中有多少仍然 active/partial。
        var activeCount = 0
        var totalReferenced = 0
        for id in result.evidenceIDs {
            guard let record = evidenceByID[id] else {
                totalReferenced += 1
                continue
            }
            totalReferenced += 1
            if record.status == .active || record.status == .partial {
                activeCount += 1
            }
        }
        // 全部失效 → 需要重新分析。
        if totalReferenced > 0, activeCount == 0 {
            return .reanalyzeRequired(reason: "全部证据已失效或被清理")
        }
        // 多数失效（>50%）→ 暂时不可用，提示但不强制。
        if totalReferenced > 0, Double(activeCount) / Double(totalReferenced) < 0.5 {
            return .temporarilyUnavailable(reason: "超过半数证据已失效")
        }
        return .available
    }
}
