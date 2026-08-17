//
//  ThoughtOrganizationPresentationPolicy.swift
//  Holo
//
//  P0 端侧建议分级策略（方案 docs/thoughts/plans/2026-08-16-想法智能标签端侧治理实施方案.md §3.1）
//  纯函数：D-06′/D-07′ 标签层按「是否复用用户认可标签」分流（对抗审查 H-2：响应无标签级置信度，
//  不引入阈值）；阈值与规则集中此处，禁止散落 View/Repository。
//

import Foundation

nonisolated enum ThoughtOrganizationPresentationPolicy {

    /// 策略版本：规则变更时 +1，反馈事件按版本区分
    static let version = 1

    /// 低置信主题待确认阈值（单一事实源：原 ThoughtRepository.topicConfirmationThreshold，
    /// 挪至此处使本策略可被 standalone swiftc 测试独立编译；Repository 侧转发保持兼容）
    static let topicConfirmationThreshold: Double = 0.75

    /// AI 归类区的展示分级
    enum AIClassPresentation: Equatable {
        /// D-06′ 全部复用认可标签：详情页标题「AI 建议」，弱提示
        case weakHint
        /// D-07′ 含新标签：详情页标题「待确认标签」，卡片「等待确认」
        case pendingConfirmation
        /// D-08′ 正常空分类：文案「暂未形成稳定标签」，不算失败
        case silent
    }

    /// 判断标签（存储路径或叶子词）对用户是否为新标签。
    /// 双匹配：叶子段 key 命中或完整路径 key 命中任一即视为复用
    /// （认可集合与建议可能一个是路径、一个是叶子词，跨形态判定）
    static func isNewTag(_ tagPathOrLeaf: String, recognizedTagKeys: Set<String>) -> Bool {
        let pathKey = ThoughtTagNormalizer.key(tagPathOrLeaf)
        if recognizedTagKeys.contains(pathKey) { return false }
        let leafKey = ThoughtTagNormalizer.key(ThoughtTagNormalizer.lastSegment(tagPathOrLeaf))
        return !recognizedTagKeys.contains(leafKey)
    }

    /// 详情页 AI 归类区三态（D-06′/D-07′/D-08′）
    /// - Parameters:
    ///   - hasAITagAssignments: 是否存在未确认（source == ai）的标签分配
    ///   - aiTagNames: 这些 ai 分配的标签名（路径或叶子词均可）
    ///   - recognizedTagKeys: 用户认可标签集合（manual/inline/confirmedAI 的归一化 key）
    static func aiTagPresentation(
        hasAITagAssignments: Bool,
        aiTagNames: [String],
        recognizedTagKeys: Set<String>
    ) -> AIClassPresentation {
        guard hasAITagAssignments, !aiTagNames.isEmpty else { return .silent }
        let hasNewTag = aiTagNames.contains { isNewTag($0, recognizedTagKeys: recognizedTagKeys) }
        return hasNewTag ? .pendingConfirmation : .weakHint
    }

    /// 卡片是否显示「等待确认」：organized 且（含新标签待确认 或 低置信主题待确认）
    static func cardShowsPendingConfirmation(
        organizedStatus: String,
        hasPendingTagConfirmation: Bool,
        topicConfidence: Double
    ) -> Bool {
        guard organizedStatus == "organized" else { return false }
        let lowConfidenceTopic = topicConfidence > 0 && topicConfidence < topicConfirmationThreshold
        return hasPendingTagConfirmation || lowConfidenceTopic
    }
}
