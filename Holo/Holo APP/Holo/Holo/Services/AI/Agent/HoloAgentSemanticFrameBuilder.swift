//
//  HoloAgentSemanticFrameBuilder.swift
//  Holo
//
//  Agent 成熟度演进 P0-B — 确定性 Semantic Frame 构建 + Coverage Check + Clarification 分级
//
//  纯确定性逻辑：时间解析、任务画像、歧义分级、覆盖检查。
//  不调用 LLM；模型负责拆解与表达，系统负责约束与验收。
//

import Foundation

nonisolated enum HoloAgentSemanticFrameBuilder {

    /// 构建查询语义帧（确定性）。
    static func buildFrame(
        query: String,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> HoloAgentQuerySemanticFrame {
        let normalized = query.lowercased()

        // 时间解析：先尝试扩展语义（季度/YTD），再回退原有 Resolver。
        let extended = HoloAgentTimeSemanticExtended.resolveExtended(query, referenceDate: referenceDate, calendar: calendar)
        let resolvedTime = extended
        let comparison = HoloAgentTimeSemanticResolver.resolveComparison(query, referenceDate: referenceDate, calendar: calendar)

        // 域识别
        let domains = identifyDomains(in: normalized)

        // 歧义检测
        let ambiguities = detectAmbiguities(in: normalized, domains: domains)

        // 敏感度
        let sensitivity = detectSensitivity(in: normalized)

        // 任务画像
        let profile = classifyProfile(
            query: normalized, domains: domains, hasComparison: comparison != nil, sensitivity: sensitivity
        )

        return HoloAgentQuerySemanticFrame(
            query: query,
            profile: profile,
            resolvedTime: resolvedTime,
            resolvedComparison: comparison,
            ambiguities: ambiguities,
            domains: domains,
            sensitivity: sensitivity
        )
    }

    // MARK: - 域识别

    private static func identifyDomains(in text: String) -> [String] {
        let domainKeywords: [(domain: String, keywords: [String])] = [
            ("finance", ["消费", "花", "支出", "账", "钱", "买", "餐饮", "购物", "金额"]),
            ("health", ["步数", "睡眠", "运动", "健康", "站立", "心率", "锻炼", "走路", "步"]),
            ("habit", ["习惯", "打卡", "坚持", "早起", "读书", "冥想"]),
            ("task", ["任务", "待办", "完成", "todo", "计划", "deadline"]),
            ("goal", ["目标", "达成", "进度", "计划完成"]),
            ("thought", ["笔记", "想法", "记录", "心情", "日记", "反思"]),
            ("memory", ["记忆", "记得", "之前", "上次"]),
            ("profile", ["资料", "信息", "个人", "档案"]),
            ("conversation", ["对话", "聊天", "说了"]),
        ]

        var found: Set<String> = []
        for entry in domainKeywords {
            if entry.keywords.contains(where: { text.contains($0) }) {
                found.insert(entry.domain)
            }
        }
        return found.sorted()
    }

    // MARK: - 歧义检测

    private static func detectAmbiguities(in text: String, domains: [String]) -> [HoloAgentAmbiguity] {
        var ambiguities: [HoloAgentAmbiguity] = []

        // "最近"/"近期" 歧义：默认 30 天
        if text.contains("最近") || text.contains("近期") {
            // 如果同时有"一周"/"7天" 则不算歧义
            if !text.contains("一周") && !text.contains("7天") && !text.contains("一周") {
                ambiguities.append(HoloAgentAmbiguity(
                    id: "ambig-recent",
                    description: "「最近」的时间范围不明确",
                    impact: .low,
                    defaultAssumption: "最近30天",
                    candidates: ["最近7天", "最近30天", "本月"]
                ))
            }
        }

        // 多域 + 模糊主语歧义
        if domains.count > 2 && (text.contains("怎么样") || text.contains("情况")) {
            ambiguities.append(HoloAgentAmbiguity(
                id: "ambig-multi-domain",
                description: "问题涉及多个域，主要关注点不明确",
                impact: .medium,
                defaultAssumption: nil,
                candidates: domains
            ))
        }

        // 完全无域 + 无具体词
        if domains.isEmpty && (text == "数据" || text == "帮我看看" || text.contains("那个") || text.contains("怎么样了")) {
            ambiguities.append(HoloAgentAmbiguity(
                id: "ambig-no-domain",
                description: "问题没有明确的数据域或指标",
                impact: .high,
                defaultAssumption: nil,
                candidates: []
            ))
        }

        return ambiguities
    }

    // MARK: - 敏感度

    private static func detectSensitivity(in text: String) -> HoloAgentQuerySensitivity {
        let mentalKeywords = ["焦虑", "抑郁", "压力", "情绪", "心情", "心理", "崩溃", "失眠"]
        if mentalKeywords.contains(where: { text.contains($0) }) {
            return .mentalHealth
        }
        let healthKeywords = ["睡眠", "步数", "运动", "健康", "心率", "站立"]
        if healthKeywords.contains(where: { text.contains($0) }) {
            return .healthData
        }
        let financeKeywords = ["消费", "花", "支出", "金额", "账"]
        if financeKeywords.contains(where: { text.contains($0) }) {
            return .financial
        }
        return .normal
    }

    // MARK: - 任务画像

    private static func classifyProfile(
        query: String, domains: [String], hasComparison: Bool, sensitivity: HoloAgentQuerySensitivity
    ) -> HoloAgentTaskProfile {
        // 敏感分析优先：心理敏感始终走敏感分析；健康数据在多域/比较时走敏感分析
        if sensitivity == .mentalHealth {
            return .sensitiveAnalysis
        }
        if sensitivity == .healthData && (domains.count > 1 || hasComparison) {
            return .sensitiveAnalysis
        }

        // 跨域
        if domains.count > 1 {
            return .crossDomainAnalysis
        }

        // 比较
        if hasComparison {
            return .comparisonAnalysis
        }

        // 单域但含分析意图
        let analysisKeywords = ["为什么", "分析", "趋势", "怎么样", "对比", "变化", "关联", "关系"]
        if analysisKeywords.contains(where: { query.contains($0) }) {
            return .singleDomainAnalysis
        }

        // 默认简单查数
        return .simpleLookup
    }
}

// MARK: - Coverage Check

nonisolated enum HoloAgentCoverageChecker {

    /// 检查计划覆盖情况。v10 的 metric 补齐逻辑并入此处。
    static func check(
        plan: HoloAgentPlan,
        answeredSubQuestions: [String: HoloAgentSubQuestionStatus],
        availableMetricKeys: Set<String>
    ) -> HoloAgentPlanCoverage {
        var statuses = answeredSubQuestions
        var covered: Set<String> = []
        var missing: Set<String> = []

        // 补齐未处理的子问题状态
        for sq in plan.subQuestions where statuses[sq.id] == nil {
            statuses[sq.id] = .pending
        }

        // 检查每个 requirement 是否覆盖
        for req in plan.requirements {
            if availableMetricKeys.contains(req.metricKey) {
                covered.insert(req.metricKey)
            } else if req.isRequired {
                missing.insert(req.metricKey)
            }
        }

        // 判定整体状态
        let hasPending = statuses.values.contains(.pending)
        let hasClarification = statuses.values.contains(.clarificationNeeded)
        let hasUnsupported = statuses.values.contains(.unsupported)

        let overall: HoloAgentCoverageStatus
        if hasClarification {
            overall = .needsClarification
        } else if !missing.isEmpty {
            overall = .missing
        } else if hasPending || hasUnsupported {
            overall = .partial
        } else {
            // 全部 answered 且无缺失
            let allAnswered = plan.subQuestions.allSatisfy { statuses[$0.id] == .answered }
            overall = allAnswered ? .complete : .partial
        }

        return HoloAgentPlanCoverage(
            plan: plan,
            subQuestionStatuses: statuses,
            coveredMetricKeys: covered,
            missingMetricKeys: missing,
            overallStatus: overall
        )
    }
}

// MARK: - Clarification 分级

nonisolated enum HoloAgentClarificationPolicy {

    /// 根据歧义列表决定是否需要澄清。
    /// 返回需要澄清的 ambiguity（高影响），或 nil（低/中影响由系统默认处理）。
    static func clarifiableAmbiguity(from ambiguities: [HoloAgentAmbiguity]) -> HoloAgentAmbiguity? {
        ambiguities.first(where: { $0.impact == .high })
    }

    /// 构建澄清请求。
    static func buildRequest(
        from ambiguity: HoloAgentAmbiguity,
        originalQuery: String,
        originalPlan: HoloAgentPlan?
    ) -> HoloAgentClarificationRequest {
        HoloAgentClarificationRequest(
            id: "clarify-\(ambiguity.id)",
            question: "我需要确认一下：\(ambiguity.description)。你具体想了解哪方面？",
            options: ambiguity.candidates.isEmpty ? ["数据概览", "具体指标"] : ambiguity.candidates,
            originalPlan: originalPlan,
            originalQuery: originalQuery,
            ambiguityID: ambiguity.id
        )
    }
}
