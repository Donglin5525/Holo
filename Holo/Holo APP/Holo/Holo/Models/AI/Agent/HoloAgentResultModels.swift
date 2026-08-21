//
//  HoloAgentResultModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 1.3 任务产物与清理策略
//

import Foundation

/// Agent 在本轮启动时实际读取的个性化上下文类型。
/// 只保存来源层级与数量，不持久化档案或记忆正文。
nonisolated enum HoloAgentContextSourceKind: String, Codable, CaseIterable, Sendable {
    case profile
    case currentStateMemory
    case phaseMemory
    case durableMemory
    case permanentFactMemory
    case legacyMemory
}

nonisolated struct HoloAgentContextSourceSummary: Codable, Equatable, Sendable {
    var kind: HoloAgentContextSourceKind
    var itemCount: Int
    /// 其中有多少项被最终 claim 显式引用；nil 兼容早期结果。
    var referencedItemCount: Int? = nil
}

/// Agent 任务的最终产物：面向用户展示的洞察结论。
/// claims 引用已校验的 `HoloAgentClaim`，evidenceIDs 指向 Evidence Ledger。
nonisolated struct HoloAgentResult: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var jobID: String
    var title: String
    var summary: String
    var claims: [HoloAgentClaim]
    var evidenceIDs: [String]
    var memoryCandidateIDs: [String]
    var status: String
    var generatedAt: Date
    var updatedAt: Date
    /// 本轮答案实际采用的数据覆盖；旧结果缺失时为 nil。
    var coverage: HoloDataCoverage? = nil
    /// 当 claims 为空时，记录原因。用于 UI 区分"确实没数据"与"有数据但未通过校验"，
    /// 避免一律显示"数据不足"的误导文案。旧结果反序列化时为 nil。
    var emptyReason: HoloAgentEmptyReason? = nil
    /// 本轮用户问题识别出的确定性交付物（诊断/建议/对比/排名…）。
    /// 驱动表达层按交付物类型组织答案（如归因诊断不被确定性合成器整段覆盖）。
    /// 旧结果反序列化时为 nil，渲染层按"无"处理即退回旧行为。
    var requestedDeliverables: Set<HoloAgentRequestedDeliverable>? = nil
    /// v17：LLM 产出的有人味儿自然摘要（final_claims 时），用于详情页开场。
    /// 旧结果反序列化时为 nil，渲染层退回用 directAnswer/summary。
    var narrativeSummary: String? = nil
    /// v21：跨维度核心发现（final_claims 时），卡片首屏主展示位。
    /// 旧结果反序列化时为 nil，渲染层不展示该槽位。
    var keyInsight: String? = nil
    /// 本轮实际预取进 Agent 上下文的个人档案与分层记忆来源。
    /// 仅保存来源和数量，用于结果卡持久披露；旧结果缺失时不展示。
    var contextSources: [HoloAgentContextSourceSummary]? = nil
    /// 查询窗口的来源与原文依据（词表/通用规则/模型解析/用户点选/默认）。
    /// 供结果卡 scope 位生成分型披露文案；旧结果缺失时按旧格式展示。
    var timeRangeAttribution: HoloAgentTimeRangeAttribution? = nil
    /// 连续追问血统；旧结果缺失时按独立 root 处理。
    var lineage: HoloAgentLineage? = nil
}

/// 空结论的原因。区分两类失败，用于精准提示用户。
nonisolated enum HoloAgentEmptyReason: String, Codable, Sendable {
    /// 工具在所选时间范围内确实没有返回可用数据。
    case noData
    /// 工具返回了数据，但 claim 未通过 Verifier 校验（如证据不足、表达越界）。
    case unverifiable
}

/// Job 清理策略：终态 job 按保留期回收，可选级联清理关联的 checkpoint / result。
/// `preserveReferencedEvidence` 由 Persistence Manager（Task 1.4）解读，
/// 避免删掉仍被其它记忆/结论引用的证据。
nonisolated struct HoloJobCleanupPolicy: Codable, Equatable, Sendable {
    var completedRetentionDays: Int = 30
    var failedRetentionDays: Int = 7
    var cascadeCheckpoint: Bool = true
    var cascadeResult: Bool = true
    var preserveReferencedEvidence: Bool = true
}
