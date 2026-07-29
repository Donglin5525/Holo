//
//  HoloAgentContinuationDraft.swift
//  Holo
//
//  连续追问的输入框锚定态（§7.1）。
//
//  用户在某份已完成 Result 上点了「继续追问」后，ChatViewModel 在内存里持有这份草稿，
//  直到用户发送消息（转成 lineage 透传给 child Job）或取消（清空锚定）。
//
//  不持久化：App 重启或页面离开后锚定态清空，用户需重新点「继续追问」。
//  这是有意为之——锚定是短时操作态，不该跨会话残留成「幽灵追问」。
//

import Foundation

/// 输入框锚定草稿。纯值类型，可跨 actor 传递。
nonisolated struct HoloAgentContinuationDraft: Equatable, Sendable {
    /// 锚定的父 Result id（用户点击继续追问的那份结果）。
    var parentResultID: String
    /// 锚定的父 Job id。
    var parentJobID: String
    /// 父结果的 lineage；legacy root（旧数据无 lineage）时为 nil。
    var parentLineage: HoloAgentLineage?
    /// 根问题原文：parent 有 originalUserQuestion 取之，否则取 parent userQuestion / result title。
    /// 用途有二：锚定条展示「正在对 XX 继续追问」；child Job 的 originalUserQuestion 继承。
    var rootUserQuestion: String
    /// 父分析涉及的数据域（health/finance/…），从 evidence sourceModule 推断。
    /// 供 FollowUpRouter 判断追问是否跨域。空数组表示无法推断（Router 跳过跨域判断）。
    var parentDomains: [String]
    /// 父分析是否含建议类 claim（executeFromResult 判定用）。
    var parentHasRecommendations: Bool
    /// 父分析的建议摘要（id + 标题），供 executeFromResult 解析「第一条建议」用。
    /// 只存标题不存正文，避免锚定态过重；创建待办时标题足够表达行动意图。
    var parentRecommendations: [RecommendationRef]
    /// 本轮追问关系。锚定时占位 .explain；sendMessage 时由 FollowUpRouter 按追问文本重判。
    var relation: HoloAgentFollowUpRelation = .explain

    /// 父建议的轻量引用（只存 id + 标题，供 executeFromResult 锁定具体建议）。
    struct RecommendationRef: Equatable, Sendable {
        var id: String
        var title: String
    }

    /// 构造 child Job 的 lineage（§8.2）。
    /// 调用方应在构造后检查 needsRollingRoot / formsCycle。
    func makeChildLineage() -> HoloAgentLineage {
        HoloAgentLineage(
            parentJobID: parentJobID,
            parentResultID: parentResultID,
            relation: relation,
            parentLineage: parentLineage
        )
    }
}
