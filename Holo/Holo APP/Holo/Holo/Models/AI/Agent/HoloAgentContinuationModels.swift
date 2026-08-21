//
//  HoloAgentContinuationModels.swift
//  Holo
//
//  Agent 连续追问契约：父结果身份、追问关系与持久化 lineage。
//  UI 只负责选择父结果；Runtime 必须从本地 Store 重新读取 canonical Result，
//  不能信任界面回传的结论或证据正文。
//

import Foundation

/// 追问与父结果之间的确定性关系。
nonisolated enum HoloAgentFollowUpRelation: String, Codable, CaseIterable, Sendable {
    case explain
    case drillDown
    case correct
    case changeScope
    case crossDomain
    case executeFromResult
    case newTopic
    case ambiguous

    var isFollowUp: Bool {
        switch self {
        case .explain, .drillDown, .correct, .changeScope, .crossDomain, .executeFromResult:
            return true
        case .newTopic, .ambiguous:
            return false
        }
    }

    var reusesParentEvidence: Bool {
        self == .explain || self == .drillDown
    }

    var shortLabel: String {
        switch self {
        case .explain: return "继续解释"
        case .drillDown: return "继续深挖"
        case .correct: return "纠正口径"
        case .changeScope: return "调整范围"
        case .crossDomain: return "跨域补查"
        case .executeFromResult: return "执行建议"
        case .newTopic: return "新问题"
        case .ambiguous: return "继续追问"
        }
    }
}

/// Job/Result 共用的追问血统。旧数据缺失时按独立 root 处理。
nonisolated struct HoloAgentLineage: Codable, Equatable, Sendable {
    static let maximumDepth = 20

    var schemaVersion: Int = 1
    var rootJobID: String
    var rootResultID: String
    var parentJobID: String
    var parentResultID: String
    var relationRawValue: String
    var lineageDepth: Int

    var relation: HoloAgentFollowUpRelation {
        HoloAgentFollowUpRelation(rawValue: relationRawValue) ?? .ambiguous
    }

    static func child(
        parentJobID: String,
        parentResultID: String,
        parentLineage: HoloAgentLineage?,
        relation: HoloAgentFollowUpRelation
    ) -> HoloAgentLineage {
        let nextDepth = (parentLineage?.lineageDepth ?? 0) + 1

        // 链过深时把当前父结果滚动成新 root，避免上下文和恢复血统无限增长。
        if nextDepth >= maximumDepth {
            return HoloAgentLineage(
                rootJobID: parentJobID,
                rootResultID: parentResultID,
                parentJobID: parentJobID,
                parentResultID: parentResultID,
                relationRawValue: relation.rawValue,
                lineageDepth: 1
            )
        }

        return HoloAgentLineage(
            rootJobID: parentLineage?.rootJobID ?? parentJobID,
            rootResultID: parentLineage?.rootResultID ?? parentResultID,
            parentJobID: parentJobID,
            parentResultID: parentResultID,
            relationRawValue: relation.rawValue,
            lineageDepth: nextDepth
        )
    }

    func formsCycle(withChildJobID childJobID: String) -> Bool {
        childJobID == parentJobID || childJobID == rootJobID
    }
}

/// 交给 Runtime 的最小追问请求。只携带身份和关系，不携带父结论正文。
nonisolated struct HoloAgentContinuationRequest: Equatable, Sendable {
    var parentJobID: String
    var parentResultID: String
    var relation: HoloAgentFollowUpRelation
    /// 换范围重查（.changeScope）时由 UI 显式注入的目标窗口，绕开文本解析层，确定性 100%。
    /// 其他 relation 忽略该字段。
    var overrideTimeRange: HoloAgentTimeRange? = nil
}

/// 输入框短时锚定态。离开页面或发送后清空，不跨会话持久化。
nonisolated struct HoloAgentContinuationDraft: Equatable, Sendable {
    struct RecommendationRef: Equatable, Sendable {
        var id: String
        var title: String
        var body: String
    }

    var parentJobID: String
    var parentResultID: String
    var rootUserQuestion: String
    var parentDomains: [String]
    var parentRecommendations: [RecommendationRef]
    var relation: HoloAgentFollowUpRelation = .explain
    /// 换范围重查时由 UI 显式注入的目标窗口；仅 .changeScope 关系使用。
    var overrideTimeRange: HoloAgentTimeRange? = nil

    var request: HoloAgentContinuationRequest {
        HoloAgentContinuationRequest(
            parentJobID: parentJobID,
            parentResultID: parentResultID,
            relation: relation,
            overrideTimeRange: relation == .changeScope ? overrideTimeRange : nil
        )
    }
}

/// 写入渲染结果的最小追问元数据。
nonisolated struct HoloRenderedContinuationMetadata: Codable, Equatable, Sendable {
    var relationRawValue: String
    var shortLabel: String
    var rootUserQuestion: String?
    var isFollowUp: Bool

    var relation: HoloAgentFollowUpRelation {
        HoloAgentFollowUpRelation(rawValue: relationRawValue) ?? .ambiguous
    }
}
