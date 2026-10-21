//
//  HoloReportUnderstandingContract.swift
//  Holo
//
//  报告融合理解（2026-10-18 方案）：统一报告契约与发现候选模型。
//  - 两类报告（周期回放 / 对话深度分析）归一到 ReportDescriptor 进入链路；
//  - 发现候选映射到统一记忆 HoloMemoryRecord，身份/去重/合并全部复用
//    既有仓库语义（稳定 ID + lineageKey 证据合并 + observationKey 幂等），
//    本文件不另立身份规则（README §6.1/§6.6）；
//  - 字段命名冻结于 docs/_common/plans/2026-10-18-HoloAI报告融合理解升级/04-P0基线与冻结契约.md。
//

import Foundation

// MARK: - 报告来源

nonisolated enum HoloReportSourceKind: String, Codable, Sendable {
    case periodReplay
    case deepAnalysis
}

nonisolated enum HoloReportReadiness: String, Codable, Sendable {
    case ready
    /// 云端回放降级分支（只落卡不落档案）等无法回源的报告，只允许历史查阅。
    case degradedUnrecoverable
}

// MARK: - 报告描述 ReportDescriptor（§5.1）

nonisolated struct HoloReportDescriptor: Codable, Equatable, Sendable {
    var canonicalReportID: String
    var sourceKind: HoloReportSourceKind
    var sourceRecordID: String
    /// 内容摘要：只由结论正文+证据引用计算；标题/排版改动不产生新 revision（R03）。
    var reportRevisionDigest: String
    var parentReportID: String?
    var rootReportID: String?
    var sourceSnapshotHash: String?
    var generatedAt: Date
    var periodStart: Date?
    var periodEnd: Date?
    var domains: [HoloMemoryDomain]
    var truncated: Bool
    var coverageNote: String?
    var claims: [HoloReportClaim]
    /// 报告生成时引用的旧记忆（防循环 R06：仅引用记忆、无数据证据的结论不产候选）。
    var usedMemoryIDs: [String]
    var status: HoloReportReadiness

    var processingKey: String {
        "\(canonicalReportID)|\(reportRevisionDigest)|\(HoloReportFindingExtractor.extractorVersion)|\(HoloReportUnderstandingPolicy.version)"
    }
}

// MARK: - 报告结论（结构化 claim 的统一投影）

nonisolated struct HoloReportClaim: Codable, Equatable, Sendable {
    var claimID: String
    /// observation / change / pattern / correlation / suggestion
    /// （回放卡 semanticType 映射到同一词表；suggestion 不进事实库，R13）
    var claimType: String
    var displayText: String
    var aiUsableText: String
    var interpretation: String?
    /// 数据证据引用（metric/rows）；为空且 usedMemoryIDs 非空 → 不产候选（R06）。
    var evidenceIDs: [String]
    var metricAssertions: [HoloReportMetricAssertion]
    var domain: HoloMemoryDomain
    /// 实体锚提示（与日常萃取锚点同词表，R31 归并依据）。
    var anchors: [HoloReportAnchorHint]
    var sampleCount: Int?
    var conditions: [String]
}

nonisolated struct HoloReportMetricAssertion: Codable, Equatable, Sendable {
    var metricKey: String
    var value: Double?
    var baselineValue: Double?
    var unit: String?
    /// up / down / flat / nil（方向核验 R10）
    var comparison: String?
    var evidenceIDs: [String]
}

/// 锚点提示：报告证据 → 实体锚（financeCategory/habit/…）。类型+值与日常萃取
/// 的信号锚点同一词表，同命题可按稳定 ID 自然归并（R31）。
nonisolated struct HoloReportAnchorHint: Codable, Equatable, Sendable {
    var type: HoloMemoryAnchorType
    var value: String
}

// MARK: - 证据原料（报告证据池的最小投影）

nonisolated struct HoloReportEvidenceMaterial: Codable, Equatable, Sendable {
    var evidenceID: String
    var kind: String
    var metricKey: String?
    var dataset: String?
    /// 分组名（分类/习惯名等）——实体锚点的值来源。
    var group: String?
    var value: Double?
    var unit: String?
    var sourceCount: Int?
    var count: Int?
    var excerpts: [String]
}

/// 深度分析报告随消息持久化的理解信封：完整结构化 claim 与证据池的紧凑投影。
/// 挂在 HoloRenderedAgentResult 上（可选字段，旧消息解码为 nil）；云端轨道
/// 在 finalizeCloudResult 填充，本地轨道由 rendered 结果推导（§十一）。
nonisolated struct HoloReportUnderstandingEnvelope: Codable, Equatable, Sendable {
    var claims: [HoloReportClaim]
    var evidence: [HoloReportEvidenceMaterial]
    var taskRangeStart: Double?
    var taskRangeEnd: Double?
    var truncated: Bool
    var coverageNote: String?
    var usedMemoryIDs: [String]
}

// MARK: - 提取策略版本

nonisolated enum HoloReportUnderstandingPolicy {
    /// 处理策略版本：变更去重/准入/有效期规则时 +1（进处理键）。
    static let version = 1
}

// MARK: - 处理台账（§8.1）

nonisolated enum HoloReportProcessingStatus: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    /// 预算暂停/网络失败后的有限延迟重试。
    case deferred
    /// 候选不合格（非网络错误），不重试。
    case rejected
    case failed
}

nonisolated struct HoloReportProcessingEntry: Codable, Equatable, Sendable {
    var processingKey: String
    var canonicalReportID: String
    var sourceKind: HoloReportSourceKind
    var status: HoloReportProcessingStatus
    var attemptCount: Int
    var lastError: String?
    var updatedAt: Date
    /// 影子期诊断计数（P1：不写库，只记统计）。
    var shadowStats: HoloReportShadowStats?
}

nonisolated struct HoloReportShadowStats: Codable, Equatable, Sendable {
    var candidateCount: Int
    var rejectedCount: Int
    /// §6.6 五分类（影子期按既有记录预估）。
    var duplicateOnlyCount: Int
    var newEvidenceCount: Int
    var newConditionCount: Int
    var newPropositionCount: Int
    var rejectionReasons: [String]
}

// MARK: - 增量对照口径（§6.6 五分类，冻结于 P0 文档 §4）

nonisolated enum HoloReportFindingIncrement: String, Codable, Sendable {
    /// ①命题、证据、条件均无增量
    case pureDuplicate
    /// ②同命题新增独立（无重叠窗）证据
    case newIndependentEvidence
    /// ③新增适用条件/时间窗变化/反证
    case conditionOrWindowChange
    /// ④既有候选/失效记录经本次证据补足后首次可用
    case madeUsable
    /// ⑤新命题
    case newProposition
}
