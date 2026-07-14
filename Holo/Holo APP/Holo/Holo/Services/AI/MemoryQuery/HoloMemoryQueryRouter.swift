//
//  HoloMemoryQueryRouter.swift
//  Holo
//
//  明细问题不让记忆代答；状态、趋势与规划按语义选择领域记忆。
//

import Foundation

enum HoloMemoryQueryRouter {
    static func route(
        _ question: String,
        semanticContext: HoloMemoryQuerySemanticContext? = nil,
        now: Date = Date()
    ) -> HoloMemoryQueryIntent {
        if let semanticContext {
            return makeIntent(from: semanticContext)
        }

        let normalized = question.lowercased()
        let domains = inferredDomains(from: normalized)
        let anchors = inferredAnchors(from: normalized)
        let timeRange = inferredTimeRange(from: normalized, now: now)
        let exactTerms = ["多少", "几次", "多少钱", "总计", "合计", "平均", "最高", "最低", "哪一笔"]
        let planningTerms = ["规划", "计划", "安排", "下周", "下一步"]
        let isExact = exactTerms.contains { normalized.contains($0) }
        let isPlanning = planningTerms.contains { normalized.contains($0) }

        if isExact {
            return HoloMemoryQueryIntent(
                route: .detail,
                requestedDomains: domains.isEmpty ? [.finance] : domains,
                requestedClaimKinds: [],
                requestedAnchors: anchors,
                timeRange: timeRange,
                includeProfile: false,
                includeCrossDomain: false,
                requiresDetailData: true,
                answerAuthority: .backgroundOnly
            )
        }
        if isPlanning {
            return HoloMemoryQueryIntent(
                route: .planningHybrid,
                requestedDomains: [.goal, .habit, .profile, .task],
                requestedClaimKinds: [.explicitPreference, .observedFact, .phaseShift, .recurringPattern],
                requestedAnchors: anchors,
                timeRange: timeRange,
                includeProfile: true,
                includeCrossDomain: true,
                requiresDetailData: true,
                answerAuthority: .answerMaterial
            )
        }
        if domains.isEmpty {
            return HoloMemoryQueryIntent(
                route: .holisticMemory,
                requestedDomains: HoloMemoryDomain.allCases.sorted(),
                requestedClaimKinds: [],
                requestedAnchors: anchors,
                timeRange: timeRange,
                includeProfile: true,
                includeCrossDomain: true,
                requiresDetailData: false,
                answerAuthority: .answerMaterial
            )
        }
        return HoloMemoryQueryIntent(
            route: .domainMemory,
            requestedDomains: domains,
            requestedClaimKinds: [],
            requestedAnchors: anchors,
            timeRange: timeRange,
            includeProfile: domains.contains(.profile),
            includeCrossDomain: false,
            requiresDetailData: false,
            answerAuthority: .answerMaterial
        )
    }

    private static func makeIntent(
        from context: HoloMemoryQuerySemanticContext
    ) -> HoloMemoryQueryIntent {
        let domains = Array(Set(context.domains)).sorted()
        let claims = Array(Set(context.claimKinds)).sorted { $0.rawValue < $1.rawValue }
        let anchors = HoloMemoryIdentity.canonicalAnchors(context.anchors)
        switch context.operation {
        case .exactDetail:
            return .init(
                route: .detail,
                requestedDomains: domains,
                requestedClaimKinds: claims,
                requestedAnchors: anchors,
                timeRange: context.timeRange,
                includeProfile: false,
                includeCrossDomain: false,
                requiresDetailData: true,
                answerAuthority: .backgroundOnly
            )
        case .summary:
            return .init(
                route: domains.isEmpty ? .holisticMemory : .domainMemory,
                requestedDomains: domains.isEmpty ? HoloMemoryDomain.allCases.sorted() : domains,
                requestedClaimKinds: claims,
                requestedAnchors: anchors,
                timeRange: context.timeRange,
                includeProfile: domains.isEmpty || domains.contains(.profile),
                includeCrossDomain: domains.isEmpty,
                requiresDetailData: false,
                answerAuthority: .answerMaterial
            )
        case .holistic:
            return .init(
                route: .holisticMemory,
                requestedDomains: domains.isEmpty ? HoloMemoryDomain.allCases.sorted() : domains,
                requestedClaimKinds: claims,
                requestedAnchors: anchors,
                timeRange: context.timeRange,
                includeProfile: true,
                includeCrossDomain: true,
                requiresDetailData: false,
                answerAuthority: .answerMaterial
            )
        case .planning:
            return .init(
                route: .planningHybrid,
                requestedDomains: domains.isEmpty ? [.goal, .habit, .profile, .task] : domains,
                requestedClaimKinds: claims,
                requestedAnchors: anchors,
                timeRange: context.timeRange,
                includeProfile: true,
                includeCrossDomain: true,
                requiresDetailData: true,
                answerAuthority: .answerMaterial
            )
        }
    }

    private static func inferredDomains(from text: String) -> [HoloMemoryDomain] {
        let terms: [(HoloMemoryDomain, [String])] = [
            (.finance, ["消费", "花销", "财务", "支出", "收入", "预算", "麦当劳"]),
            (.health, ["健康", "睡眠", "步数", "运动", "身体", "恢复"]),
            (.habit, ["习惯", "打卡", "坚持"]),
            (.task, ["任务", "待办", "完成"]),
            (.goal, ["目标", "进度"]),
            (.thought, ["观点", "想法", "思考"]),
            (.conversation, ["对话", "聊天"]),
            (.profile, ["偏好", "个人档案"]),
        ]
        return terms.compactMap { domain, keywords in
            keywords.contains(where: { text.contains($0) }) ? domain : nil
        }.sorted()
    }

    private static func inferredAnchors(from text: String) -> [HoloMemoryAnchorRef] {
        var anchors: [HoloMemoryAnchorRef] = []
        if text.contains("麦当劳"),
           let anchor = try? HoloMemoryAnchorRef(type: .merchant, value: "麦当劳") {
            anchors.append(anchor)
        }
        return anchors
    }

    private static func inferredTimeRange(
        from text: String,
        now: Date
    ) -> HoloMemoryQueryTimeRange? {
        if let range = text.range(of: #"最近\s*(\d+)\s*天"#, options: .regularExpression),
           let days = Int(text[range].filter(\.isNumber)) {
            return .init(start: now.addingTimeInterval(-Double(days) * 86_400), end: now)
        }
        if text.contains("最近") {
            return .init(start: now.addingTimeInterval(-30 * 86_400), end: now)
        }
        if text.contains("下周") {
            return .init(start: now, end: now.addingTimeInterval(7 * 86_400))
        }
        return nil
    }
}
