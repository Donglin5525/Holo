//
//  HoloAgentImplicitFollowUpResolver.swift
//  Holo
//
//  连续追问 Phase 4：自然相邻追问的隐式解析（§13）。
//
//  用户没点「继续追问」按钮，直接在输入框接着问（如「那步数呢」「换成今年」）。
//  本解析器判断这条输入是否是对「最近一份已完成分析」的隐式追问。
//
//  安全约束（§13，宁可漏判也不乱判）：
//  - 纯确定性规则，不调用模型、不用模型 confidence。
//  - 唯一性门槛：只有当能唯一确定 parent + relation + target 时才放行。
//  - 确认态：跨会话或超过确认窗口（默认 4 小时）时，不放行而是产出确认请求（可恢复、可幂等点击）。
//  - wrong-anchor circuit breaker：由 ChatViewModel 在发现误判后关闭（调 disableUntil）。
//

import Foundation

/// 隐式追问解析结果。
nonisolated enum HoloAgentImplicitFollowUpResolution: Equatable, Sendable {
    /// 确定是隐式追问，且在确认窗口内，可直接放行。
    case resolved(parentResultID: String, parentJobID: String, relation: HoloAgentFollowUpRelation)
    /// 可能是对最近分析的追问，但超出确认窗口或跨会话，需要用户确认。
    /// confirmationToken 用于幂等：同一条输入多次解析产出相同 token，避免重复弹确认。
    case needsConfirmation(parentResultID: String, parentJobID: String, relation: HoloAgentFollowUpRelation, confirmationToken: String)
    /// 不是隐式追问（无追问标记、或无法唯一确定 parent/relation）。
    case notAFollowUp
}

/// 隐式追问解析器：纯值类型。
nonisolated enum HoloAgentImplicitFollowUpResolver {

    /// 确认窗口：最近分析完成后超过此时长，隐式追问需要用户确认才放行。
    static let confirmationWindow: TimeInterval = 4 * 3600 // 4 小时

    /// 解析一条输入是否是对最近分析的隐式追问。
    /// - Parameters:
    ///   - text: 用户输入文本。
    ///   - recentResult: 最近一份已完成分析的渲染结果（含身份字段）。
    ///   - lastInteractionAt: 最近一次用户交互时间，用于判断是否超确认窗口。
    ///   - isSameSession: 是否同一会话（跨会话默认需要确认）。
    ///   - disabledUntil: circuit breaker 关闭时间戳；非 nil 且未过期的视为关闭态。
    static func resolve(
        text: String,
        recentResult: HoloRenderedAgentResult?,
        lastInteractionAt: Date,
        isSameSession: Bool,
        now: Date,
        disabledUntil: Date?
    ) -> HoloAgentImplicitFollowUpResolution {
        // circuit breaker 开启时不做隐式解析。
        if let disabledUntil, now < disabledUntil {
            return .notAFollowUp
        }
        // 没有最近分析，或最近分析缺身份字段，无法隐式锚定。
        guard let recent = recentResult,
              let jobID = recent.agentJobID,
              let resultID = recent.agentResultID else {
            return .notAFollowUp
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .notAFollowUp }

        // 必须命中追问标记词：没有承接标记的不当隐式追问（避免把新问题误判为追问）。
        guard hasFollowUpMarker(normalized) else { return .notAFollowUp }

        // 用 Router 判定关系；ambiguous 不放行（无法唯一确定 relation）。
        let parent = HoloAgentFollowUpParentContext(
            parentDomains: inferredDomains(from: recent),
            hasRecommendations: !(recent.recommendations ?? []).isEmpty,
            parentQuestion: recent.rootUserQuestion ?? recent.question
        )
        let relation = HoloAgentFollowUpRouter.classify(followUpText: normalized, parent: parent)
        guard relation != .ambiguous else { return .notAFollowUp }
        // newTopic 不是追问。
        guard relation.isFollowUp else { return .notAFollowUp }

        // 确认窗口判断：同会话且在窗口内 → 直接放行；否则需要确认。
        let withinWindow = isSameSession && now.timeIntervalSince(lastInteractionAt) <= confirmationWindow
        if withinWindow {
            return .resolved(parentResultID: resultID, parentJobID: jobID, relation: relation)
        }
        // 幂等 token：用文本哈希 + parentID 组成，避免同一条输入重复弹确认。
        let token = "\(resultID)::\(normalized.hashValue)"
        return .needsConfirmation(
            parentResultID: resultID, parentJobID: jobID,
            relation: relation, confirmationToken: token
        )
    }

    /// 追问标记词：有这些词说明用户在承接上文。
    /// 这是隐式追问的必要条件——没有承接标记的输入默认是新话题。
    private static func hasFollowUpMarker(_ text: String) -> Bool {
        let markers = [
            "那", "另外", "还有", "继续", "接着", "然后", "换成", "改成",
            "呢", "它", "这个", "那个", "其中", "具体", "为什么"
        ]
        return markers.contains { text.contains($0) }
    }

    /// 从渲染结果的 evidence sourceModule 推断域（与 ChatViewModel.inferredDomains 对齐）。
    private static func inferredDomains(from result: HoloRenderedAgentResult) -> [String] {
        var found = Set<String>()
        for ref in result.evidenceReferences {
            if let module = ref.sourceModule {
                found.insert(module.rawValue)
            }
        }
        return found.sorted()
    }
}
