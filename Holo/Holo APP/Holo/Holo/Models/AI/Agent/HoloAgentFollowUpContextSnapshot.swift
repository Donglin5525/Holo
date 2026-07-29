//
//  HoloAgentFollowUpContextSnapshot.swift
//  Holo
//
//  连续追问的上下文快照（§9.5）。
//
//  child Job 启动时，从 parent Result 冻结一份自包含的「继承事实包」：
//  - 父分析的结论（claims）与证据（evidenceIDs）
//  - 父分析的时间范围与快照截止
//  - 一段摘要（digest），供 prompt 注入时作为不可信数据隔离
//
//  快照是「冻结的」：一旦构造，不受 parent Result 后续变化（被清理、被纠正）影响。
//  这保证 child Job 在执行期间看到的继承事实稳定。
//  但 Context Guard 会在注入前重新校验 evidence 有效性——冻结的是引用，不是授权。
//

import Foundation

/// 连续追问的上下文快照。随 child Job 的 initial Checkpoint 持久化。
nonisolated struct HoloAgentFollowUpContextSnapshot: Codable, Equatable, Sendable {
    /// 快照结构版本。未来字段演进时递增，解码方按版本兼容。
    var schemaVersion: Int
    /// parent Result id（快照来源）。
    var parentResultID: String
    /// parent Job id。
    var parentJobID: String
    /// 继承的 claim 摘要列表。只保留展示与重算所需的最小字段，不携带模型置信度（防漂移）。
    var inheritedClaimDigests: [ClaimDigest]
    /// 继承的 evidence id 列表。注入前由 Context Guard 重新校验有效性。
    var inheritedEvidenceIDs: [String]
    /// parent 分析的时间范围标签（如「本周」「近 14 天」），供 child 对齐口径。
    var parentScopeLabel: String?
    /// parent 分析的快照截止时间，child 默认沿用同一截止口径。
    var parentSnapshotCutoffAt: Date?
    /// 一段自然语言摘要，描述 parent 分析的核心结论。注入 prompt 时作为不可信数据。
    var digest: String?

    /// claim 摘要：只冻结「这条结论说了什么 + 引用了哪些证据」，
    /// 不带模型置信度（child 不应继承 parent 的模型置信度）。
    nonisolated struct ClaimDigest: Codable, Equatable, Sendable {
        var claimID: String
        var displayText: String
        var evidenceIDs: [String]
        var claimType: String?
    }

    /// 从 parent Result + 关联 evidence 构造快照。
    /// 只冻结已通过校验的 claim（parent Result.claims 已经是 accepted 集合）。
    init(
        parentResultID: String,
        parentJobID: String,
        claims: [HoloAgentClaim],
        evidenceIDs: [String],
        scopeLabel: String?,
        snapshotCutoffAt: Date?,
        digest: String?
    ) {
        self.schemaVersion = 1
        self.parentResultID = parentResultID
        self.parentJobID = parentJobID
        self.inheritedClaimDigests = claims.map { claim in
            ClaimDigest(
                claimID: claim.id,
                displayText: claim.displayText,
                evidenceIDs: claim.evidenceIDs + claim.metricAssertions.flatMap(\.evidenceIDs),
                claimType: claim.type
            )
        }
        self.inheritedEvidenceIDs = Array(Set(evidenceIDs)).sorted()
        self.parentScopeLabel = scopeLabel
        self.parentSnapshotCutoffAt = snapshotCutoffAt
        self.digest = digest
    }

    /// 直接构造（解码或测试用）。
    init(
        schemaVersion: Int = 1,
        parentResultID: String,
        parentJobID: String,
        inheritedClaimDigests: [ClaimDigest],
        inheritedEvidenceIDs: [String],
        parentScopeLabel: String?,
        parentSnapshotCutoffAt: Date?,
        digest: String?
    ) {
        self.schemaVersion = schemaVersion
        self.parentResultID = parentResultID
        self.parentJobID = parentJobID
        self.inheritedClaimDigests = inheritedClaimDigests
        self.inheritedEvidenceIDs = inheritedEvidenceIDs
        self.parentScopeLabel = parentScopeLabel
        self.parentSnapshotCutoffAt = parentSnapshotCutoffAt
        self.digest = digest
    }
}
