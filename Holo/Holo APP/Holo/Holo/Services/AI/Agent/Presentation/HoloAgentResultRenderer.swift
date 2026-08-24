//
//  HoloAgentResultRenderer.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 4.4 Agent Result Renderer
//  把校验后的 claim + evidence 渲染成手机可读短文。
//  证据引用只使用 redactedExcerpt（脱敏），不暴露完整敏感原文；不输出 Markdown 表格/代码块。
//

import Foundation

nonisolated struct HoloRenderedAgentSection: Codable, Equatable, Sendable {
    var title: String
    var body: String
    /// claim 置信度，可选；旧 JSON 缺失该字段解码为 nil（向后兼容）
    var confidence: Double?
    /// 原始 claim 类型，用于 UI 区分“建议 / 观察 / 能力边界”，旧结果缺失时按观察展示。
    var kind: String? = nil
    /// v21：这条数据在用户生活里意味着什么的低置信解读；旧 JSON 缺失解码为 nil 不展示。
    var interpretation: String? = nil
}

nonisolated struct HoloRenderedFinanceDrilldown: Codable, Equatable, Sendable {
    var sourceEvidenceID: String
    var label: String
    var keyword: String?
    var start: Date
    var end: Date
    var baselineStart: Date?
    var baselineEnd: Date?
}

nonisolated struct HoloRenderedEvidenceReference: Codable, Equatable, Sendable {
    var id: String
    var summary: String
    var financeDrilldown: HoloRenderedFinanceDrilldown?
    var sourceModule: HoloEvidenceSourceModule? = nil
    /// 计算口径（证据记录的确定性公式，如 pearson(left,right)）；旧结果缺失时为 nil。
    var formula: String? = nil
    /// 对比基线的可读描述（基线值 + 基线窗口 + 对比方向）；无基线时为 nil。
    var baselineText: String? = nil
}

/// 证据公式的用户可读翻译。证据计算全部发生在本地工具层（HoloDataTool 等），
/// 公式词表封闭、由本目录跟进——不在后端做，也不做开放式机器翻译。
nonisolated enum HoloEvidenceFormulaPresentation {
    /// 已知分析方法公式的完整人话；未命中时尝试聚合模式，仍不中则原样返回。
    static func text(_ formula: String) -> String {
        let trimmed = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "pearson(left,right)":
            return "皮尔逊相关：两侧指标按日对齐后计算相关系数（只说明关联，不说明因果）"
        case "average(right where left < threshold)":
            return "阈值筛选：取左侧指标低于阈值的天，算右侧指标均值，与全期均值对比"
        case "average(high)-average(low)",
             "average(right|left>=threshold)-average(right|left<threshold)":
            return "分组对比：按左侧指标高低分两组，比较右侧均值之差（只说明差异，不说明因果）"
        case "opening_balance + posted_income - posted_expense":
            return "期初余额 + 已入账收入 − 已入账支出"
        default:
            return aggregationText(trimmed) ?? trimmed
        }
    }

    /// 聚合模式 `op(field)`：sum(amount) → 按「amount」字段合计。
    private static func aggregationText(_ formula: String) -> String? {
        guard let open = formula.firstIndex(of: "("),
              let close = formula.lastIndex(of: ")"),
              open < close else { return nil }
        let op = String(formula[formula.startIndex..<open])
        let field = String(formula[formula.index(after: open)..<close])
        let operations = [
            "sum": "合计", "average": "均值", "count": "计数",
            "max": "最大值", "min": "最小值", "median": "中位数"
        ]
        guard let operation = operations[op], !field.isEmpty else { return nil }
        return "按「\(field)」字段计算\(operation)"
    }
}

/// Job 在开始执行时冻结的权威答案上下文。
/// 时间口径只能从这里进入展示层，Renderer 不再重复解析用户原话。
nonisolated struct HoloAgentAnswerContext: Equatable, Sendable {
    var primaryTimeRange: HoloAgentTimeRange?
    var snapshotCutoffAt: Date?
    /// 查询窗口来源（词表/规则/模型/用户点选/默认）；nil 按旧数据格式展示。
    var timeRangeAttribution: HoloAgentTimeRangeAttribution? = nil
}

/// 可持久化的主分析范围，供摘要卡与详情页共同展示。
nonisolated struct HoloRenderedAnswerScope: Codable, Equatable, Sendable {
    var label: String
    var start: Date?
    var end: Date?
    var snapshotCutoffAt: Date?
    /// 查询窗口来源；旧消息 JSON 缺失时为 nil，退回旧格式。
    var attribution: HoloAgentTimeRangeAttribution? = nil

    var displayLabel: String {
        var trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = "本期" }
        let provenance = attribution?.provenance
        // 带原文依据时优先展示用户的话（「近半年」），比内部 label 更贴近用户心智
        if let matched = attribution?.matchedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !matched.isEmpty,
           !trimmed.contains(matched) {
            trimmed = matched
        }
        if provenance == .unspecified {
            trimmed = "默认范围"
        }
        // 滚动窗口（近半年/模型解析/用户点选）的起止是算出来的，用户不知道具体日期，必须晒出来；
        // 词表命中的自然周期（本月/上月/今年）边界不言自明，不加冗余。
        let needsDateSpan = provenance != nil && provenance != .lexical
        if needsDateSpan, let start, let end {
            trimmed += "（\(Self.shortDate(start))–\(Self.shortDate(end))）"
        }
        if let end, let snapshotCutoffAt, end > snapshotCutoffAt {
            trimmed += " · 截至\(Self.shortDate(snapshotCutoffAt))"
        }
        if provenance == .unspecified {
            trimmed += " · 未指定时间，按默认范围"
        }
        return trimmed
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

/// 建议是一级展示实体，不再伪装成普通 section，也不再把第一条提升成开场正文。
nonisolated struct HoloRenderedRecommendation: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var body: String
    var priorityLabel: String?
    var confidence: Double?
    var evidenceIDs: [String]
    /// 与主分析范围不同的建议必须显式标注自己的证据范围。
    var scopeLabel: String?
}

/// Agent 分析失败的原因。nil 表示成功完成（含"数据不足、没有可信结论"这种正常空结果）。
/// 非 nil 时上层应据此走对应卡片，而非渲染普通分析结果。
nonisolated enum HoloRenderedAgentFailure: Codable, Sendable, Equatable {
    /// 额度耗尽（档位限制，非系统错误）——走额度卡片 + 升级入口
    case quotaExhausted(userMessage: String)
    /// 分析出错（网络/超时/内部异常）——提示重试
    case analysisFailed
    /// 系统收回后台执行时间；同一 Job 已保存进度，回前台恢复，不触发普通聊天降级。
    case executionSuspended
    /// 父结果已失效或被清理，不能伪装成已承接的追问。
    case continuationUnavailable(userMessage: String)
}

nonisolated struct HoloRenderedAgentResult: Codable, Equatable, Sendable {
    var title: String
    var summary: String
    var sections: [HoloRenderedAgentSection]
    var evidenceReferences: [HoloRenderedEvidenceReference]
    /// 本次分析失败的原因；nil 表示成功。旧消息 JSON 解码为 nil，向后兼容。
    var failure: HoloRenderedAgentFailure? = nil
    var question: String? = nil
    var headline: String? = nil
    var directAnswer: String? = nil
    var coverageText: String? = nil
    var limitations: [String]? = nil
    /// 空结论原因（claims 为空时）。用于 UI 区分"确实没数据"与"有数据但未通过校验"。
    var emptyReason: HoloAgentEmptyReason? = nil
    /// 新答案契约字段；optional 保证旧消息 JSON 可继续解码。
    var scope: HoloRenderedAnswerScope? = nil
    var recommendations: [HoloRenderedRecommendation]? = nil
    /// v17：LLM 产出的有人味儿自然摘要，供 UI 开场使用。旧消息 JSON 解码为 nil。
    var narrativeSummary: String? = nil
    /// v21：跨维度核心发现，卡片首屏主展示位。旧消息 JSON 解码为 nil，不展示该槽位。
    var keyInsight: String? = nil
    /// 本轮实际读取进 Agent 的个人档案与分层记忆来源；旧消息缺失时不展示。
    var contextSources: [HoloAgentContextSourceSummary]? = nil
    /// 本次分析查看的数据样本摘要（最多10条），用于向用户透明展示读取了哪些数据。
    /// 仅在 dynamic_query 附带样本时填充；旧消息 JSON 解码为 nil。
    var dataSamplePreview: HoloRenderedDataSamplePreview? = nil
    /// 连续追问展示与下一轮锚定所需的最小身份；旧消息缺失时不展示追问入口。
    var continuationMetadata: HoloRenderedContinuationMetadata? = nil
    var agentJobID: String? = nil
    var agentResultID: String? = nil
    var lineage: HoloAgentLineage? = nil
    var rootUserQuestion: String? = nil

    var contextSourceText: String? {
        let labels = (contextSources ?? []).compactMap(\.displayLabel)
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }
}

/// 向用户展示的数据样本摘要：简述查看了哪些数据，附最多10条脱敏样例。
nonisolated struct HoloRenderedDataSamplePreview: Codable, Equatable, Sendable {
    var domainLabel: String       // 如"账单"、"习惯"
    var count: Int                // 样本条数
    var excerpts: [String]        // 每条样本的简短描述（脱敏后）
}

private nonisolated extension HoloAgentContextSourceSummary {
    var displayLabel: String? {
        guard itemCount > 0 else { return nil }
        switch kind {
        case .profile:
            return "个人档案"
        case .currentStateMemory:
            return "近期观察 \(itemCount) 条"
        case .phaseMemory:
            return "当前阶段 \(itemCount) 条"
        case .durableMemory:
            return "长期规律 \(itemCount) 条"
        case .permanentFactMemory:
            return "长期事实 \(itemCount) 条"
        case .legacyMemory:
            return "长期记忆 \(itemCount) 条"
        }
    }
}

/// 覆盖度唯一展示策略。调用方只能消费这里的结果，禁止再按 ratio 自行决定文案或可信度。
nonisolated enum HoloCoveragePresentationPolicy {
    static func text(_ coverage: HoloDataCoverage?, rangeLabel: String) -> String? {
        guard let coverage, coverage.semantics == .dailyObservations else { return nil }
        return "\(rangeLabel)共 \(coverage.totalDays) 天，其中 \(coverage.coveredDays)/\(coverage.totalDays) 天有有效观测"
    }

    static func limitations(_ coverage: HoloDataCoverage?) -> [String] {
        guard isCompletenessRelevant(coverage), let ratio = ratio(coverage) else { return [] }
        return ratio < 0.6 ? ["日度观测覆盖较少，趋势结论仅供参考"] : []
    }

    static func requiresDisclosure(_ coverage: HoloDataCoverage?) -> Bool {
        guard isCompletenessRelevant(coverage), let ratio = ratio(coverage) else { return false }
        return ratio < 0.9
    }

    private static func isCompletenessRelevant(_ coverage: HoloDataCoverage?) -> Bool {
        coverage?.semantics == .dailyObservations
    }

    private static func ratio(_ coverage: HoloDataCoverage?) -> Double? {
        guard let coverage else { return nil }
        if let ratio = coverage.coverageRatio { return ratio }
        guard coverage.totalDays > 0 else { return nil }
        return Double(coverage.coveredDays) / Double(coverage.totalDays)
    }
}

nonisolated struct HoloAgentResultRenderer {

    /// 渲染校验后的 claims 与证据为手机可读结构。
    func render(
        claims: [HoloAgentClaim],
        evidence: [HoloEvidenceRecord],
        title: String = "本期观察",
        question: String? = nil,
        coverage: HoloDataCoverage? = nil,
        emptyReason: HoloAgentEmptyReason? = nil,
        answerContext: HoloAgentAnswerContext? = nil,
        requestedDeliverables: Set<HoloAgentRequestedDeliverable> = [],
        narrativeSummary: String? = nil,
        keyInsight: String? = nil,
        contextSources: [HoloAgentContextSourceSummary] = [],
        dataSamplePreview: HoloRenderedDataSamplePreview? = nil,
        lineage: HoloAgentLineage? = nil,
        rootUserQuestion: String? = nil
    ) -> HoloRenderedAgentResult {
        let evidenceByID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let assertions = claims.flatMap(\.metricAssertions)
        let primaryAssertion = Self.primaryAssertion(for: question, assertions: assertions)
        let scope = Self.answerScope(context: answerContext, evidence: evidence)
        let rangeLabel = scope?.label ?? "本期"
        let headline = Self.headline(
            question: question,
            rangeLabel: rangeLabel,
            assertions: assertions,
            fallbackTitle: title
        )
        let legacyAnswer = Self.directAnswer(
            question: question,
            rangeLabel: rangeLabel,
            primaryAssertion: primaryAssertion,
            claims: claims,
            evidenceByID: evidenceByID
        )
        let directAnswer = legacyAnswer.text
        let sections = Self.sections(
            claims: claims,
            primaryMetricKey: primaryAssertion?.metricKey,
            directAnswer: directAnswer,
            evidenceByID: evidenceByID
        )

        // 证据引用：去重，只用 redactedExcerpt。
        // 优先用 metricAssertions 里已校验有效的 evidenceIDs（Verifier 保证其存在），
        // 顶层 claim.evidenceIDs 仅作补充。canonical evidence ID 是 UUID 拼接的长串，
        // LLM 在顶层常写错，找不到 record 的直接跳过，不再显示「证据缺失」。
        var seen = Set<String>()
        var references: [HoloRenderedEvidenceReference] = []
        for claim in claims {
            let candidateIDs = claim.metricAssertions.flatMap(\.evidenceIDs) + claim.evidenceIDs
            for evidenceID in candidateIDs where !seen.contains(evidenceID) {
                seen.insert(evidenceID)
                guard let record = evidenceByID[evidenceID] else { continue }
                references.append(HoloRenderedEvidenceReference(
                    id: evidenceID,
                    summary: Self.readableEvidenceSummary(record),
                    financeDrilldown: Self.financeDrilldown(for: record),
                    sourceModule: record.sourceModule,
                    formula: Self.cleanOptional(record.formula),
                    baselineText: Self.baselineText(for: record)
                ))
            }
        }

        let summary = claims.isEmpty
            ? "本期暂无显著观察"
            : directAnswer ?? sections.map(\.body).joined(separator: "；")

        var result = HoloRenderedAgentResult(
            title: title,
            summary: summary,
            sections: sections,
            evidenceReferences: references,
            question: question,
            headline: headline,
            directAnswer: directAnswer,
            coverageText: HoloCoveragePresentationPolicy.text(coverage, rangeLabel: rangeLabel),
            limitations: HoloCoveragePresentationPolicy.limitations(coverage),
            emptyReason: emptyReason,
            scope: scope,
            recommendations: nil,
            narrativeSummary: narrativeSummary,
            keyInsight: keyInsight,
            contextSources: contextSources.isEmpty ? nil : contextSources,
            dataSamplePreview: dataSamplePreview
        )

        // MARK: P4 可观测：语义缺失/旧目录兜底
        // 有证据但全无 semantic → 走了兼容目录；旧目录产出过 catalog 句子 → 兼容适配成功。
        if HoloAgentResultSemanticsFlags.typedSemanticsEnabled,
           !evidence.isEmpty,
           !evidence.contains(where: { $0.semantic != nil }) {
            let legacyContext = evidence.first?.sourceModule.rawValue
            HoloAgentAnswerMetricCounter.shared.increment(.semanticMissing, context: legacyContext)
            if legacyAnswer.usedCatalog {
                HoloAgentAnswerMetricCounter.shared.increment(.semanticLegacyFallback, context: legacyContext)
            }
        }

        // MARK: P2 确定性合成与展示前验证
        // 证据带类型化语义时，直接结论改由本地合成器产出（P3 已删除 financeComparisonAnswer
        // 等领域特判，比较/排名/拆解/趋势统一走合成器），模型文案降为解释层；
        // 无 semantic 的旧证据完全走上方旧逻辑（HoloMetricSemanticCatalog 兼容层）。
        //
        // 诊断类问题（requestedDeliverables 含 .diagnosis）例外：用户要的是"为什么/归因"，
        // 确定性合成器只能给数值事实句（可靠但不会归因），LLM 的诊断解读句才是用户真正要的答案。
        // 因此诊断类改"拼接"而非"覆盖"：合成器事实句在前（数字可靠），LLM 解读句在后（自然归因），
        // 解读句仍经 deliverVerified 清洗内部 token / 未知分组 / 方向冲突，只是不再整段丢弃。
        let isDiagnosisRequest = requestedDeliverables.contains(.diagnosis)
        var composed: HoloComposedAnswer?
        if HoloAgentResultSemanticsFlags.typedSemanticsEnabled,
           HoloAgentResultSemanticsFlags.deterministicComposerEnabled,
           var task = HoloAnswerTaskDeriver.derive(question: question, evidence: evidence) {
            // Answer Task 负责“回答什么”，Job Context 负责“回答哪个时间”。
            // 即使 evidence 携带旧 label，也必须由权威主范围覆盖。
            task.primaryRangeLabel = rangeLabel
            if let answer = HoloDeterministicAnswerComposer.compose(
                task: task,
                evidence: evidence,
                coverage: coverage
            ) {
                composed = answer
                HoloAgentAnswerMetricCounter.shared.increment(.composerUsed, context: task.domain?.rawValue)
                if isDiagnosisRequest {
                    // 诊断类：headline 用合成器点题（数字可靠），directAnswer 用 LLM 归因叙述（自然）。
                    // LLM 的诊断 claim displayText 本身已含量化归因（"主要来自餐饮，贡献65%"），
                    // 不再硬拼合成器事实句，避免"两套话"割裂感。
                    // 归因叙述优先用诊断类 claim 串联；LLM 未产出诊断 claim 时退回合成器事实句。
                    result.headline = answer.headline
                    let diagnosisNarrative = claims
                        .filter { HoloAgentAnswerRequestPolicy.isDiagnosticClaim($0) }
                        .map { $0.displayText.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if !diagnosisNarrative.isEmpty {
                        result.directAnswer = diagnosisNarrative
                    } else {
                        result.directAnswer = answer.directAnswer
                    }
                    result.summary = result.directAnswer ?? ""
                } else {
                    // 非诊断类：headline 用合成器点题（数字可靠），但 directAnswer 优先保留 LLM 写的人话。
                    // 只有当 directAnswer 为空或含机器格式（不干净）时，才用合成器事实句兜底。
                    // 这样既保留人味儿（LLM 叙事），又保证 headline 的数字可靠。
                    // 注：legacyAnswer.usedCatalog 意味着 LLM 人话缺失、directAnswer 是降级模板单句，
                    // 它只服务无类型化语义的旧证据兼容层；有 semantic 时合成器句（总量+分项+占比）
                    // 信息量更高，让位给合成器。
                    result.headline = answer.headline
                    let currentDirect = result.directAnswer ?? ""
                    let directIsClean = !currentDirect.isEmpty
                        && !HoloMetricSemanticCatalog.containsInternalToken(currentDirect)
                        && !legacyAnswer.usedCatalog
                    if !directIsClean {
                        result.directAnswer = answer.directAnswer
                    }
                    result.summary = result.directAnswer ?? answer.directAnswer
                }
                if let composedCoverage = answer.coverageText {
                    result.coverageText = composedCoverage
                }
                if !answer.limitations.isEmpty {
                    result.limitations = answer.limitations
                }
                // 解释层 section：命中内部 token 的用合成明细顶替，没有可顶替的丢弃。
                var spareItems = answer.items
                result.sections = result.sections.compactMap { section in
                    guard HoloAnswerCoverageVerifier.containsInternalToken(section.body)
                            || HoloAnswerCoverageVerifier.containsInternalToken(section.title) else {
                        return section
                    }
                    HoloAgentAnswerMetricCounter.shared.increment(.internalTokenBlocked, context: "section")
                    HoloAgentAnswerMetricCounter.shared.increment(.modelTextDiscarded, context: "section")
                    guard !spareItems.isEmpty else { return nil }
                    let replacement = spareItems.removeFirst()
                    return HoloRenderedAgentSection(
                        title: "数据明细",
                        body: replacement,
                        confidence: section.confidence,
                        kind: section.kind
                    )
                }
            }
        }

        result = Self.applyingRecommendationHierarchy(
            to: result,
            question: question,
            claims: claims,
            rangeLabel: rangeLabel,
            evidenceByID: evidenceByID
        )
        // 诊断归因串联（无类型化语义兜底）：P2 合成器路径的诊断拼接只在证据带 semantic 时生效，
        // 无语义证据时 legacy directAnswer 只承载第一条干净 claim，其余归因结论会随下方
        // sections 去重一起丢失（如"预算已用120%超限"只剩证据引用可见）。
        // 这里把全部诊断 claim 的结论完整拼进开篇正文，保证归因不丢。
        if requestedDeliverables.contains(.diagnosis) {
            let diagnosisNarrative = claims
                .filter { HoloAgentAnswerRequestPolicy.isDiagnosticClaim($0) }
                .map { $0.displayText.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !diagnosisNarrative.isEmpty {
                result.directAnswer = diagnosisNarrative
                result.summary = diagnosisNarrative
            }
        }
        // 诊断层级：归因结论由 directAnswer 承载，这里清掉 sections 里与归因重复的诊断 claim，
        // 避免"开篇讲一遍 → 卡片再讲一遍"。判定依据是 claim 产物类型而非问法关键词，
        // 因此用户无论问"为什么超支"还是"钱花哪了"，只要 LLM 产出诊断 claim 即介入。
        result = Self.applyingDiagnosisHierarchy(
            to: result,
            claims: claims,
            rangeLabel: rangeLabel,
            evidenceByID: evidenceByID
        )
        if let lineage {
            result.continuationMetadata = HoloRenderedContinuationMetadata(
                relationRawValue: lineage.relationRawValue,
                shortLabel: lineage.relation.shortLabel,
                rootUserQuestion: rootUserQuestion,
                isFollowUp: lineage.lineageDepth > 0
            )
            result.lineage = lineage
            result.rootUserQuestion = rootUserQuestion
        }
        return Self.deliverVerified(result, evidence: evidence, coverage: coverage, composed: composed)
    }

    /// 诊断/归因类问题的信息层级：归因结论由 directAnswer（开篇正文）承载，
    /// sections 只保留支撑数据，清掉与 directAnswer 重复的诊断 claim section，避免同一句归因反复出现。
    ///
    /// 设计原则：归因结论只在开篇出现一次。诊断类 claim（observation/diagnosis/insight/comparison）
    /// 的 displayText 已经在覆盖块里拼进了 directAnswer，如果再作为 section 展示，用户会看到
    /// "开篇讲一遍 → N 个同名卡片再讲一遍"的重复。因此这里把这些 section 清掉，
    /// 只留下非诊断类 claim 产生的纯数据 section（如果有）。
    ///
    /// 触发依据是 claim 产物类型（isDiagnosticClaim），不依赖问法关键词。
    private static func applyingDiagnosisHierarchy(
        to input: HoloRenderedAgentResult,
        claims: [HoloAgentClaim],
        rangeLabel: String,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> HoloRenderedAgentResult {
        // 没有诊断类 claim 时不介入，避免误伤纯查数场景。
        let hasDiagnosisClaim = claims.contains { HoloAgentAnswerRequestPolicy.isDiagnosticClaim($0) }
        guard hasDiagnosisClaim else { return input }

        var result = input
        // 收集所有诊断 claim 的正文（已拼进 directAnswer），用于从 sections 里剔除重复。
        let diagnosisBodies = Set(claims
            .filter { HoloAgentAnswerRequestPolicy.isDiagnosticClaim($0) }
            .map { Self.normalize($0.displayText.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty })

        // 清掉与归因结论重复的 section（body 归一化后命中诊断 claim 正文的）。
        // 前提是开篇确实承载了该结论：归一化后的 directAnswer 包含该正文才删卡，
        // 否则无语义证据路径下 directAnswer 只含第一条 claim，其余观察/样例明细
        // 会既不进开篇又丢卡片。保留：建议类（被 recommendations 接管）和未重复的纯数据 section。
        let directKey = Self.normalize((result.directAnswer ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        result.sections = result.sections.filter { section in
            let kind = section.kind?.lowercased() ?? ""
            if ["suggestion", "recommendation", "action"].contains(kind) { return true }
            let bodyKey = Self.normalize(section.body.trimmingCharacters(in: .whitespacesAndNewlines))
            return !diagnosisBodies.contains(bodyKey) || !directKey.contains(bodyKey)
        }
        return result
    }

    /// 展示前验证 + 自动恢复：recoverable 先修复再验一次，仍不过或 failed 一律给边界说明，
    /// 绝不交付含内部 token 的半成品。
    private static func deliverVerified(
        _ result: HoloRenderedAgentResult,
        evidence: [HoloEvidenceRecord],
        coverage: HoloDataCoverage?,
        composed: HoloComposedAnswer?
    ) -> HoloRenderedAgentResult {
        switch HoloAnswerCoverageVerifier.verify(result: result, evidence: evidence, coverage: coverage) {
        case .pass:
            return result
        case .recoverable(let codes):
            if codes.contains(HoloAnswerCoverageVerifier.codeInternalToken) {
                HoloAgentAnswerMetricCounter.shared.increment(.internalTokenBlocked, context: "verifier")
            }
            let repair = Self.repaired(result, evidence: evidence, coverage: coverage, composed: composed)
            if repair.discardedModelText {
                HoloAgentAnswerMetricCounter.shared.increment(.modelTextDiscarded, context: "verifier_repair")
            }
            let verdict = HoloAnswerCoverageVerifier.verify(result: repair.result, evidence: evidence, coverage: coverage)
            if case .pass = verdict { return repair.result }
            return Self.boundaryResult(from: repair.result, evidence: evidence, composed: composed)
        case .failed(let codes):
            HoloAgentAnswerMetricCounter.shared.increment(.coverageFailed, context: codes.first ?? "UNKNOWN")
            return Self.boundaryResult(from: result, evidence: evidence, composed: composed)
        }
    }

    /// 本地修复：丢弃违规的模型事实文案；违规的 summary/directAnswer 用合成结论或兜底句替换。
    /// 返回修复后的结果与是否丢弃过模型文案（供 P4 指标计数）。
    private static func repaired(
        _ result: HoloRenderedAgentResult,
        evidence: [HoloEvidenceRecord],
        coverage: HoloDataCoverage?,
        composed: HoloComposedAnswer?
    ) -> (result: HoloRenderedAgentResult, discardedModelText: Bool) {
        // 与 Verifier 一致：已知分组用合成器清洗后的形态，避免合法分组被误判编造。
        let knownLabels = Set(evidence.compactMap {
            HoloDeterministicAnswerComposer.sanitizedGroupLabel($0.semantic?.groupLabel)
        })
        func violates(_ text: String) -> Bool {
            HoloAnswerCoverageVerifier.containsInternalToken(text)
                || HoloAnswerCoverageVerifier.hasDirectionConflict(text, knownLabels: knownLabels)
                || !HoloAnswerCoverageVerifier.unknownGroupMentions(in: text, knownLabels: knownLabels).isEmpty
        }

        var repaired = result
        var discarded = false
        if HoloAnswerCoverageVerifier.containsInternalToken(repaired.title) {
            repaired.title = "本期观察"
            discarded = true
        }
        if let headline = repaired.headline, violates(headline) {
            repaired.headline = composed?.headline
            discarded = true
        }
        if let answer = repaired.directAnswer, violates(answer) {
            repaired.directAnswer = composed?.directAnswer
            discarded = true
        }
        if violates(repaired.summary) {
            repaired.summary = composed?.directAnswer ?? "本期数据结果如下"
            discarded = true
        }
        if let text = repaired.coverageText, violates(text) {
            repaired.coverageText = composed?.coverageText
            discarded = true
        }
        // 只有日度观测覆盖不足才需要披露；事件记录禁止套用日历天数完整度。
        if HoloCoveragePresentationPolicy.requiresDisclosure(coverage),
           !HoloAnswerCoverageVerifier.coverageDisclosed(repaired.coverageText) {
            repaired.coverageText = composed?.coverageText
                ?? HoloCoveragePresentationPolicy.text(
                    coverage,
                    rangeLabel: repaired.scope?.label ?? "本期"
                )
        }
        let keptSections = repaired.sections.filter { !violates($0.title) && !violates($0.body) }
        if keptSections.count != repaired.sections.count { discarded = true }
        repaired.sections = keptSections
        return (repaired, discarded)
    }

    /// 失败边界：可理解的说明 + 保留可核对的数据明细，不展示半成品结论。
    /// 即使确定性合成器（composed）未产出，只要有 evidence，就用 evidence 直接拼事实句，
    /// 让用户看到"有用的数字"而不是一句空话。文案与实际保留的内容保持一致。
    private static func boundaryResult(
        from result: HoloRenderedAgentResult,
        evidence: [HoloEvidenceRecord],
        composed: HoloComposedAnswer?
    ) -> HoloRenderedAgentResult {
        var sections: [HoloRenderedAgentSection] = []
        if let composed {
            sections.append(HoloRenderedAgentSection(
                title: "已核对的数据",
                body: composed.directAnswer,
                confidence: nil,
                kind: "observation"
            ))
        } else if !evidence.isEmpty {
            // composed 未产出但 evidence 非空：取前 5 条可读事实句，换行分隔（避免长串被 UI 截断）。
            let factLines = evidence.prefix(5).compactMap { record -> String? in
                let summary = Self.readableEvidenceSummary(record)
                return summary.isEmpty ? nil : summary
            }
            if !factLines.isEmpty {
                sections.append(HoloRenderedAgentSection(
                    title: "已核对的数据",
                    body: factLines.joined(separator: "\n"),
                    confidence: nil,
                    kind: "observation"
                ))
            }
        }
        let hasDataDetail = !sections.isEmpty
        let boundary: String
        if hasDataDetail, !evidence.isEmpty {
            // 有数据明细时，承认结论未成形 + 简短引导看明细。
            // 不堆长文案（避免和 sections 数据重复/截断），只给一句诚实的话。
            boundary = "数据都核对过了，放在下面，但这次还不够稳定到能下明确结论。"
        } else if hasDataDetail {
            boundary = "这次没能形成完整结论，但已为你保留可核对的数据明细。"
        } else {
            boundary = "这次没有形成可信结论，可能是因为这段时间的可用数据不足。"
        }
        let coverageText = result.coverageText.flatMap {
            HoloAnswerCoverageVerifier.containsInternalToken($0) ? nil : $0
        }
        return HoloRenderedAgentResult(
            title: HoloAnswerCoverageVerifier.containsInternalToken(result.title) ? "本期观察" : result.title,
            summary: boundary,
            sections: sections,
            evidenceReferences: result.evidenceReferences,
            question: result.question,
            headline: nil,
            directAnswer: boundary,
            coverageText: coverageText,
            limitations: result.limitations,
            emptyReason: result.emptyReason,
            scope: result.scope,
            recommendations: nil,
            narrativeSummary: result.narrativeSummary,
            contextSources: result.contextSources
        )
    }

    /// 从 evidence 的 comparison/baseline 粗略推断整体趋势方向，供兜底文案使用。
    /// 无法判断时返回 .stable（兜底文案对 stable 的处理是安全的）。
    private static func inferredTrend(from evidence: [HoloEvidenceRecord]) -> Trend {
        var ups = 0
        var downs = 0
        for record in evidence {
            let comparison = (record.comparison ?? "").lowercased()
            if comparison.contains("up") || comparison.contains("increase")
                || comparison.contains("rise") || comparison.contains("grow") {
                ups += 1
            } else if comparison.contains("down") || comparison.contains("decrease")
                || comparison.contains("fall") || comparison.contains("decline") {
                downs += 1
            }
            // 有 baseline 时用数值比较补充判断
            if let current = record.metricValue, let baseline = record.baselineValue,
               baseline != 0 {
                if current > baseline { ups += 1 }
                else if current < baseline { downs += 1 }
            }
        }
        if ups > downs { return .up }
        if downs > ups { return .down }
        return .stable
    }

    private static func primaryAssertion(
        for question: String?,
        assertions: [HoloMetricAssertion]
    ) -> HoloMetricAssertion? {
        guard !assertions.isEmpty else { return nil }
        let normalized = question?.lowercased() ?? ""

        let preferredKey: String?
        if normalized.contains("步数") || normalized.contains("走路") {
            preferredKey = normalized.contains("平均") || normalized.contains("日均")
                ? "health.steps.average"
                : nil
        } else if normalized.contains("睡眠") {
            preferredKey = "health.sleep.average_hours"
        } else if normalized.contains("站立") || normalized.contains("久坐") {
            preferredKey = "health.stand.average_hours"
        } else if normalized.contains("活动") {
            preferredKey = "health.activity.average_minutes"
        } else if normalized.contains("花") || normalized.contains("支出") || normalized.contains("消费") {
            preferredKey = normalized.contains("次数") || normalized.contains("几次")
                ? "finance.keyword.count"
                : "finance.total.amount"
        } else {
            preferredKey = nil
        }

        if let preferredKey,
           let exact = assertions.first(where: { $0.metricKey == preferredKey }) {
            return exact
        }
        if normalized.contains("平均") || normalized.contains("日均") {
            return assertions.first {
                let key = $0.metricKey.lowercased()
                return key.contains("average") || key.contains("mean") || key.contains("per_day")
            } ?? assertions.first
        }
        if normalized.contains("总") || normalized.contains("合计") {
            return assertions.first {
                let key = $0.metricKey.lowercased()
                return key.contains("total") || key.contains("sum")
            } ?? assertions.first
        }
        return assertions.first
    }

    private static func answerScope(
        context: HoloAgentAnswerContext?,
        evidence: [HoloEvidenceRecord]
    ) -> HoloRenderedAnswerScope? {
        // unspecified（无解析结果、按数据源默认窗口）也要生成 scope：静默降级从此在卡片上可见
        if let range = context?.primaryTimeRange {
            return HoloRenderedAnswerScope(
                label: nonEmpty(range.label) ?? "本期",
                start: range.start,
                end: range.end,
                snapshotCutoffAt: context?.snapshotCutoffAt,
                attribution: context?.timeRangeAttribution
            )
        }
        guard let range = evidence.compactMap(\.timeRange).first else { return nil }
        return HoloRenderedAnswerScope(
            label: nonEmpty(range.label) ?? "本期",
            start: range.start,
            end: range.end,
            snapshotCutoffAt: context?.snapshotCutoffAt,
            attribution: context?.timeRangeAttribution
        )
    }

    private static func headline(
        question: String?,
        rangeLabel: String,
        assertions: [HoloMetricAssertion],
        fallbackTitle: String
    ) -> String {
        let text = question ?? ""
        var topics: [String] = []
        if text.contains("步数") || text.contains("走路") { topics.append("步数") }
        if text.contains("睡眠") { topics.append("睡眠") }
        if text.contains("站立") || text.contains("久坐") { topics.append("站立") }
        if text.contains("活动") { topics.append("活动") }
        if text.contains("运动") || text.contains("锻炼") { topics.append("运动") }
        if text.contains("支出") || text.contains("消费") || text.contains("花钱") || text.contains("花哪") { topics.append("支出") }
        if text.contains("习惯") { topics.append("习惯") }
        if text.contains("任务") || text.contains("待办") { topics.append("任务") }
        if text.contains("目标") { topics.append("目标") }
        if text.contains("想法") || text.contains("观点") { topics.append("想法") }

        if topics.isEmpty {
            topics = assertions.map { HoloMetricSemanticCatalog.topic(for: $0.metricKey) }
                .filter { $0 != "数据" }
        }
        topics = topics.reduce(into: []) { result, topic in
            if !result.contains(topic) { result.append(topic) }
        }

        if topics.count > 1 {
            return "\(rangeLabel)的\(topics.joined(separator: "与"))变化"
        }
        switch topics.first {
        case "步数": return "\(rangeLabel)的步数"
        case "睡眠": return "\(rangeLabel)的睡眠情况"
        case "站立": return "\(rangeLabel)的站立情况"
        case "活动": return "\(rangeLabel)的活动情况"
        case "运动": return "\(rangeLabel)的运动情况"
        case "支出": return text.contains("哪") || text.contains("结构") ? "\(rangeLabel)的支出去向" : "\(rangeLabel)的支出"
        case "习惯": return "\(rangeLabel)的习惯进展"
        case "任务": return "\(rangeLabel)的任务进展"
        case "目标": return "\(rangeLabel)的目标进展"
        case "想法": return "\(rangeLabel)的想法脉络"
        case let topic?: return "\(rangeLabel)的\(topic)"
        case nil:
            let cleaned = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty || cleaned == "深度分析" || cleaned == "本期观察"
                ? "\(rangeLabel)的数据结果"
                : cleaned
        }
    }

    /// 旧逻辑直接结论。`usedCatalog` 表示结论是否由兼容目录（HoloMetricSemanticCatalog）
    /// 的句子产出（P4 指标区分「旧目录可识别适配」与「纯模型文案兜底」）。
    private static func directAnswer(
        question: String?,
        rangeLabel: String,
        primaryAssertion: HoloMetricAssertion?,
        claims: [HoloAgentClaim],
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> (text: String?, usedCatalog: Bool) {
        // 优先使用 LLM 写的自然语言 displayText（人味儿来源）。
        // 数字可靠性已由 Claim 核验器保障（unsupportedNumbers 在 verify 阶段拦截无证据数字），
        // 这里只做格式清洗：含机器标识（metricKey/公式/下划线）的 displayText 不可直接展示，跳过。
        // 仅当所有 displayText 都不干净时，才降级到确定性模板句子（数字可靠但无人味儿）。
        let humanText = claims.map(\.displayText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !HoloMetricSemanticCatalog.containsInternalToken($0) }
        if let humanText {
            return (humanText, false)
        }
        // 降级路径：用结构化 assertion 拼确定性事实句。
        if let assertion = primaryAssertion,
           let sentence = HoloMetricSemanticCatalog.sentence(
               metricKey: assertion.metricKey,
               value: resolvedValue(for: assertion, evidenceByID: evidenceByID),
               unit: resolvedUnit(for: assertion, evidenceByID: evidenceByID),
               comparison: resolvedComparison(for: assertion, evidenceByID: evidenceByID)
           ) {
            if assertion.metricKey == "health.steps.average", let value = assertion.value {
                let number = HoloMetricSemanticCatalog.formattedNumber(
                    value,
                    metricKey: assertion.metricKey,
                    unit: assertion.unit
                )
                return ("\(rangeLabel)，日均 \(number) 步", true)
            }
            return ("\(rangeLabel)，\(sentence)", true)
        }
        return (nil, false)
    }

    private static func sections(
        claims: [HoloAgentClaim],
        primaryMetricKey: String?,
        directAnswer: String?,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> [HoloRenderedAgentSection] {
        var output: [HoloRenderedAgentSection] = []
        var seenBodies = Set<String>()

        for claim in claims {
            let rawBody = claim.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            let mustRebuild = HoloMetricSemanticCatalog.containsInternalToken(rawBody)

            if mustRebuild {
                for assertion in claim.metricAssertions where assertion.metricKey != primaryMetricKey {
                    let comparison = resolvedComparison(for: assertion, evidenceByID: evidenceByID)
                    guard let body = HoloMetricSemanticCatalog.sentence(
                        metricKey: assertion.metricKey,
                        value: resolvedValue(for: assertion, evidenceByID: evidenceByID),
                        unit: resolvedUnit(for: assertion, evidenceByID: evidenceByID),
                        comparison: comparison
                    ) else { continue }
                    appendSection(
                        title: HoloMetricSemanticCatalog.title(
                            for: assertion.metricKey,
                            comparison: comparison
                        ),
                        body: body,
                        confidence: claim.confidence,
                        kind: claim.type,
                        interpretation: claim.interpretation,
                        directAnswer: directAnswer,
                        seenBodies: &seenBodies,
                        output: &output
                    )
                }
                continue
            }

            guard !rawBody.isEmpty else { continue }
            let metricTitle = claim.metricAssertions.first.map {
                HoloMetricSemanticCatalog.title(
                    for: $0.metricKey,
                    comparison: resolvedComparison(for: $0, evidenceByID: evidenceByID)
                )
            }
            let resolvedTitle = metricTitle == nil || metricTitle == "计算结果"
                ? shortTitle(from: rawBody)
                : metricTitle!
            appendSection(
                title: resolvedTitle,
                body: rawBody,
                confidence: claim.confidence,
                kind: claim.type,
                interpretation: claim.interpretation,
                directAnswer: directAnswer,
                seenBodies: &seenBodies,
                output: &output
            )
        }
        return output
    }

    private static func resolvedValue(
        for assertion: HoloMetricAssertion,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> Double? {
        if assertion.metricKey.hasPrefix("dynamic."),
           let evidenceValue = matchingEvidence(for: assertion, evidenceByID: evidenceByID)?.metricValue {
            return evidenceValue
        }
        return assertion.value ?? matchingEvidence(for: assertion, evidenceByID: evidenceByID)?.metricValue
    }

    private static func resolvedUnit(
        for assertion: HoloMetricAssertion,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> String? {
        if assertion.metricKey.hasPrefix("dynamic."),
           let evidenceUnit = matchingEvidence(for: assertion, evidenceByID: evidenceByID)?.unit {
            return evidenceUnit
        }
        return assertion.unit ?? matchingEvidence(for: assertion, evidenceByID: evidenceByID)?.unit
    }

    private static func resolvedComparison(
        for assertion: HoloMetricAssertion,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> String? {
        if assertion.metricKey.hasPrefix("dynamic."),
           let evidenceComparison = matchingEvidence(
               for: assertion,
               evidenceByID: evidenceByID
           )?.comparison?.trimmingCharacters(in: .whitespacesAndNewlines),
           !evidenceComparison.isEmpty {
            return evidenceComparison
        }
        let comparison = assertion.comparison?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comparison, !comparison.isEmpty { return comparison }
        return matchingEvidence(for: assertion, evidenceByID: evidenceByID)?.comparison
    }

    private static func matchingEvidence(
        for assertion: HoloMetricAssertion,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> HoloEvidenceRecord? {
        assertion.evidenceIDs
            .compactMap { evidenceByID[$0] }
            .first { $0.metricKey == assertion.metricKey }
    }

    private static func appendSection(
        title: String,
        body: String,
        confidence: Double,
        kind: String,
        interpretation: String? = nil,
        directAnswer: String?,
        seenBodies: inout Set<String>,
        output: inout [HoloRenderedAgentSection]
    ) {
        let normalized = normalize(body)
        guard !normalized.isEmpty,
              !seenBodies.contains(normalized),
              normalize(directAnswer ?? "") != normalized else { return }
        seenBodies.insert(normalized)
        var uniqueTitle = title
        if output.contains(where: { $0.title == uniqueTitle }) {
            uniqueTitle = shortTitle(from: body)
        }
        if uniqueTitle == body || uniqueTitle.isEmpty { uniqueTitle = "数据解读" }
        output.append(HoloRenderedAgentSection(
            title: uniqueTitle,
            body: body,
            confidence: confidence,
            kind: kind,
            interpretation: interpretation
        ))
    }

    /// 优化/建议类问题采用“行动优先、事实支撑、证据折叠”的信息层级。
    /// 确定性合成器仍负责数值事实，但不再覆盖用户真正要求的行动答案。
    private static func applyingRecommendationHierarchy(
        to input: HoloRenderedAgentResult,
        question: String?,
        claims: [HoloAgentClaim],
        rangeLabel: String,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> HoloRenderedAgentResult {
        guard HoloAgentAnswerRequestPolicy.requestsRecommendations(question) else {
            return input
        }
        let typedRecommendations = claims.compactMap {
            renderedRecommendation(
                from: $0,
                primaryRangeLabel: rangeLabel,
                evidenceByID: evidenceByID
            )
        }
        guard !typedRecommendations.isEmpty else { return input }

        var result = input
        let factualAnswer = result.directAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
        result.recommendations = typedRecommendations
        result.headline = {
            let current = result.headline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if current.contains("优化") || current.contains("建议") { return current }
            if !current.isEmpty { return "\(current)优化建议" }
            return "\(rangeLabel)优化建议"
        }()
        let actionTitles = typedRecommendations.prefix(2).map(\.title)
        if actionTitles.count == 1 {
            result.directAnswer = "优先优化：\(actionTitles[0])。"
        } else if actionTitles.count >= 2 {
            result.directAnswer = "优先处理\(actionTitles[0])；其次处理\(actionTitles[1])。"
        }
        result.summary = result.directAnswer ?? factualAnswer ?? result.summary

        var facts = result.sections.filter {
            let kind = $0.kind?.lowercased() ?? ""
            return !["suggestion", "recommendation", "action"].contains(kind)
        }

        if let factualAnswer,
           !factualAnswer.isEmpty,
           !facts.contains(where: { normalize($0.body) == normalize(factualAnswer) }) {
            facts.insert(HoloRenderedAgentSection(
                title: "关键依据",
                body: factualAnswer,
                confidence: nil,
                kind: "observation"
            ), at: 0)
        }

        // 新 UI 只消费 recommendations；sections 保留事实层和旧消息兼容，不再承担建议排序。
        result.sections = Array(facts.prefix(4))
        return result
    }

    private static func renderedRecommendation(
        from claim: HoloAgentClaim,
        primaryRangeLabel: String,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> HoloRenderedRecommendation? {
        guard HoloAgentAnswerRequestPolicy.isRecommendationClaim(claim) else { return nil }
        let raw = claim.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let parsed = recommendationCopy(from: raw)
        let evidenceIDs = Array(Set(
            claim.metricAssertions.flatMap(\.evidenceIDs) + claim.evidenceIDs
        )).sorted()
        let itemRangeLabel = evidenceIDs
            .compactMap { evidenceByID[$0]?.timeRange?.label }
            .compactMap(nonEmpty)
            .first
        let scopeLabel = itemRangeLabel.flatMap {
            normalize($0) == normalize(primaryRangeLabel) ? nil : $0
        }
        return HoloRenderedRecommendation(
            id: claim.id,
            title: parsed.title,
            body: parsed.body,
            priorityLabel: parsed.priorityLabel,
            confidence: claim.confidence,
            evidenceIDs: evidenceIDs,
            scopeLabel: scopeLabel
        )
    }

    /// 旧模型把“建议序号/优先级/正文”塞在一个字符串里。这里是唯一兼容边界；
    /// 新 UI 从此只接收结构化 Recommendation，不再自行解析或重排。
    private static func recommendationCopy(
        from raw: String
    ) -> (title: String, body: String, priorityLabel: String?) {
        let priorityLabel: String? = {
            if raw.contains("高优先级") { return "高优先级" }
            if raw.contains("中优先级") { return "中优先级" }
            if raw.contains("低优先级") { return "低优先级" }
            return nil
        }()
        let prefixPattern = #"^\s*建议\s*\d*\s*(?:[（(]\s*(?:高|中|低)?优先级\s*[）)])?\s*[：:]?\s*"#
        let cleaned = raw.replacingOccurrences(
            of: prefixPattern,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSentenceEnd = cleaned.firstIndex { "。！？!?\n".contains($0) }
        let titleSource: String
        let remainder: String
        if let firstSentenceEnd {
            titleSource = String(cleaned[..<firstSentenceEnd])
            let after = cleaned.index(after: firstSentenceEnd)
            remainder = String(cleaned[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            titleSource = cleaned
            remainder = ""
        }
        let title = shortTitle(from: titleSource)
        let body = remainder.isEmpty ? cleaned : remainder
        return (title, body, priorityLabel)
    }

    private static func shortTitle(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["观察", "本期"] where cleaned.hasPrefix(prefix) {
            cleaned.removeFirst(prefix.count)
        }
        let separators = Set("，,；;。.!！?？：:\n")
        let first = cleaned.split { separators.contains($0) }.first.map(String.init) ?? cleaned
        let title = String(first.prefix(14)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "数据解读" : title
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { !$0.isWhitespace && !"，,；;。.!！?？：:".contains($0) }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readableEvidenceSummary(_ record: HoloEvidenceRecord) -> String {
        let summary = record.redactedExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        // 第一道：含已知内部 token（metricKey 前缀/公式/下划线）→ 走语义重写
        if HoloMetricSemanticCatalog.containsInternalToken(summary) {
            return HoloMetricSemanticCatalog.sentence(
                metricKey: record.metricKey,
                value: record.metricValue,
                unit: record.unit,
                comparison: record.comparison
            ) ?? "该数据已完成核对"
        }
        // 第二道（纵深防御）：excerpt 里混进了裸英文工具词（steps/sleep/stand 等），
        // 这些不含内部 token 前缀骗不过第一道，但用户看不懂。命中时也走语义重写。
        if Self.containsRawToolWord(summary) {
            return HoloMetricSemanticCatalog.sentence(
                metricKey: record.metricKey,
                value: record.metricValue,
                unit: record.unit,
                comparison: record.comparison
            ) ?? "该数据已完成核对"
        }
        return summary
    }

    /// 检测文本是否混入了裸英文工具标识词（健康指标 rawValue 等）。
    /// 仅检测已知会泄漏的英文单词，避免误伤用户备注里合法的英文内容。
    private static func containsRawToolWord(_ text: String) -> Bool {
        let rawWords = ["steps", "sleep", "stand", "activity", "workout"]
        let lower = text.lowercased()
        return rawWords.contains { word in
            lower.contains(word)
        }
    }

    private static func cleanOptional(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 证据的对比基线描述：值 + 窗口 + 方向，能拼多全拼多全，缺哪段跳哪段。
    private static func baselineText(for record: HoloEvidenceRecord) -> String? {
        guard record.baselineValue != nil || record.baselineTimeRange != nil else { return nil }
        var parts: [String] = []
        if let baseline = record.baselineValue {
            let unit = record.unit ?? ""
            let comparison = record.comparison.map { "（\($0)）" } ?? ""
            let valueText = baseline == baseline.rounded()
                ? String(Int(baseline))
                : String(format: "%.2f", baseline)
            parts.append("基线 \(valueText)\(unit)\(comparison)")
        }
        if let range = record.baselineTimeRange {
            let rangeLabel = range.label.isEmpty ? Self.shortRangeLabel(range) : range.label
            parts.append("基线窗口 \(rangeLabel)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func shortRangeLabel(_ range: HoloAgentTimeRange) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        switch (range.start, range.end) {
        case let (start?, end?):
            return "\(formatter.string(from: start))–\(formatter.string(from: end))"
        case let (start?, nil):
            return "\(formatter.string(from: start)) 起"
        case let (nil, end?):
            return "至 \(formatter.string(from: end))"
        default:
            return "全期"
        }
    }

    private static func financeDrilldown(for record: HoloEvidenceRecord) -> HoloRenderedFinanceDrilldown? {
        guard record.sourceModule == .finance,
              let range = record.timeRange,
              let start = range.start,
              let end = range.end else {
            return nil
        }
        return HoloRenderedFinanceDrilldown(
            sourceEvidenceID: record.id,
            label: range.label,
            keyword: keyword(from: record),
            start: start,
            end: end,
            baselineStart: record.baselineTimeRange?.start,
            baselineEnd: record.baselineTimeRange?.end
        )
    }

    private static func keyword(from record: HoloEvidenceRecord) -> String? {
        guard record.metricKey.hasPrefix("finance.keyword.") else { return nil }
        return quotedKeyword(in: record.redactedExcerpt) ?? quotedKeyword(in: record.excerpt)
    }

    private static func quotedKeyword(in text: String) -> String? {
        guard let start = text.firstIndex(of: "「") else { return nil }
        let afterStart = text.index(after: start)
        guard let end = text[afterStart...].firstIndex(of: "」") else { return nil }
        let keyword = String(text[afterStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return keyword.isEmpty ? nil : keyword
    }
}
