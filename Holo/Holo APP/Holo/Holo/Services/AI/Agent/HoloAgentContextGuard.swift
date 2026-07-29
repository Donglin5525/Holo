//
//  HoloAgentContextGuard.swift
//  Holo
//
//  连续追问的上下文守卫（§9.5 Context Guard）。
//
//  在 Context Compiler 注入继承内容前，校验父分析的 evidence 是否仍然有效。
//  复用 V2 Verifier 的授权语义：orphaned / archived 的 evidence 视为失效，
//  其引用的 claim 不被注入 child Job 上下文。
//
//  Guard 只做「过滤」不做「重算」：它不重新执行 claim 校验（那是 V2 Verifier 的职责），
//  只确保「继承的引用在注入当下仍然指向有效证据」——冻结的是引用，不是授权。
//

import Foundation

/// 上下文守卫校验结果。
nonisolated struct HoloAgentContextGuardResult: Equatable, Sendable {
    /// 通过校验、可安全注入的 evidence id 集合。
    var authorizedEvidenceIDs: Set<String>
    /// 被过滤掉的 evidence id → 原因（orphaned / archived）。
    var rejectedEvidence: [String: String]
    /// 父快照引用了但 ledger 里找不到的 evidence（已被彻底清理）。
    var missingEvidenceIDs: [String]
}

/// 上下文守卫：纯值类型。
nonisolated enum HoloAgentContextGuard {

    /// 校验快照引用的全部 evidence，返回仍有效的 id 集合。
    /// - Parameters:
    ///   - snapshot: 父分析冻结快照。
    ///   - availableEvidence: 注入当下从 Evidence Ledger 实时读回的证据记录。
    static func authorize(
        snapshot: HoloAgentFollowUpContextSnapshot,
        availableEvidence: [HoloEvidenceRecord]
    ) -> HoloAgentContextGuardResult {
        let evidenceByID = Dictionary(availableEvidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var authorized = Set<String>()
        var rejected: [String: String] = [:]
        var missing: [String] = []

        // 快照里引用的全部 evidence id（claim 引用 + 顶层 evidenceIDs 合集）。
        let referencedIDs = Set(
            snapshot.inheritedEvidenceIDs + snapshot.inheritedClaimDigests.flatMap(\.evidenceIDs)
        )

        for id in referencedIDs {
            guard let record = evidenceByID[id] else {
                missing.append(id)
                continue
            }
            // 复用 V2 的授权语义：orphaned / archived 失效，active / partial 有效。
            switch record.status {
            case .active, .partial:
                authorized.insert(id)
            case .orphaned:
                rejected[id] = "orphaned"
            case .archived:
                rejected[id] = "archived"
            }
        }

        return HoloAgentContextGuardResult(
            authorizedEvidenceIDs: authorized,
            rejectedEvidence: rejected,
            missingEvidenceIDs: missing
        )
    }
}
