//
//  ThoughtOrganizationPipelineScenarioTests.swift
//  Holo
//
//  P0 业务管道场景模拟（东林验收走查用）：模拟 AI 响应 → 主题校验 → 分级 → 卡片状态 → 筛选匹配
//  覆盖：D-03~D-08′ 全分支 + 卡片优先级链 + 筛选三态
//
//  Run:
//  swiftc "Holo/Holo APP/Holo/Holo/Services/Thoughts/ThoughtTagNormalizer.swift" \
//        "Holo/Holo APP/Holo/Holo/Services/AI/ThoughtThemeConstraint.swift" \
//        "Holo/Holo APP/Holo/Holo/Services/AI/ThoughtOrganizationPresentationPolicy.swift" \
//        "Holo/Holo APP/Holo/HoloTests/Services/AI/ThoughtOrganizationPipelineScenarioTests.swift" \
//        -o /tmp/holo_pipeline_scenarios && /tmp/holo_pipeline_scenarios
//

import Foundation

@main
struct ThoughtOrganizationPipelineScenarioTests {

    static var failures: [String] = []
    static var total = 0

    /// 模拟一次完整整理决策管道（等价于 parse 成功后的输入，跳过 JSON 层）
    struct ScenarioResult {
        let topicTitle: String?
        let tagPaths: [String]
        let isEmptyClassification: Bool
        let detailPresentation: ThoughtOrganizationPresentationPolicy.AIClassPresentation
        let cardShowsPending: Bool
        let unclassifiedFilterMatch: Bool
    }

    static func simulate(
        selectedTopic: String?,
        suggestedTags: [String],
        confidence: Double,
        activeTopics: [String],
        recognizedTagKeys: Set<String>
    ) -> ScenarioResult {
        // 端侧校验（与 ThoughtOrganizationService 步骤 6 相同）
        let validated = ThoughtThemeConstraint.validate(
            selectedTopic: selectedTopic,
            suggestedTags: suggestedTags,
            activeTopics: activeTopics
        )
        // D-08′：有效标签为空 = 正常空分类（不再 failed）
        let isEmpty = validated.tagPaths.isEmpty
        // 分级（详情页三态）
        let presentation = ThoughtOrganizationPresentationPolicy.aiTagPresentation(
            hasAITagAssignments: !isEmpty,
            aiTagNames: isEmpty ? [] : validated.tagPaths,
            recognizedTagKeys: recognizedTagKeys
        )
        // 卡片等待确认（无主题场景：有主题时卡片显示「已入主题」，见卡片优先级链）
        let hasPendingTag = presentation == .pendingConfirmation
        let cardPending = ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
            organizedStatus: "organized",
            hasPendingTagConfirmation: hasPendingTag,
            topicConfidence: validated.topicTitle == nil ? 0 : confidence
        )
        // 筛选「未归类」匹配（organized && 无有效主题）
        let unclassified = validated.topicTitle == nil
        return ScenarioResult(
            topicTitle: validated.topicTitle,
            tagPaths: validated.tagPaths,
            isEmptyClassification: isEmpty,
            detailPresentation: presentation,
            cardShowsPending: cardPending,
            unclassifiedFilterMatch: unclassified
        )
    }

    static func main() {
        let activeTopics = ["工作与事业", "生活与健康"]
        // 认可标签：「工作与事业/复盘」「客户沟通」（路径形态，与生产一致）
        let recognized: Set<String> = Set(
            ["工作与事业/复盘", "客户沟通"].map { ThoughtTagNormalizer.key($0) }
        )

        // ── 场景 1：高置信主题 + 全复用标签（D-03 + D-06′）──
        do {
            let r = simulate(
                selectedTopic: "工作与事业",
                suggestedTags: ["复盘", "客户沟通"],
                confidence: 0.9,
                activeTopics: activeTopics,
                recognizedTagKeys: recognized
            )
            expectEqual(r.topicTitle, "工作与事业", "S1 主题应命中白名单")
            expectTrue(r.tagPaths.contains("工作与事业/复盘"), "S1 标签应带主题前缀路径")
            expectFalse(r.isEmptyClassification, "S1 非空分类")
            expectEqual(r.detailPresentation, .weakHint, "S1 全复用应弱提示")
            expectFalse(r.cardShowsPending, "S1 无主题视角下不应等待确认（实际有主题时卡片显示已入主题）")
            expectFalse(r.unclassifiedFilterMatch, "S1 不属于未归类")
        }

        // ── 场景 2：含新标签（D-07′）──
        do {
            let r = simulate(
                selectedTopic: "工作与事业",
                suggestedTags: ["复盘", "埋点口径"],
                confidence: 0.88,
                activeTopics: activeTopics,
                recognizedTagKeys: recognized
            )
            expectEqual(r.detailPresentation, .pendingConfirmation, "S2 含新标签应待确认")
            expectTrue(r.tagPaths.contains("工作与事业/埋点口径"), "S2 新标签按主题前缀入路径")
        }

        // ── 场景 3：AI 正常返回但标签为空（D-08′ 核心）──
        do {
            let r = simulate(
                selectedTopic: "工作与事业",
                suggestedTags: [],
                confidence: 0.85,
                activeTopics: activeTopics,
                recognizedTagKeys: recognized
            )
            expectTrue(r.isEmptyClassification, "S3 应识别为空分类而非失败")
            expectEqual(r.detailPresentation, .silent, "S3 空分类应为 silent 文案")
            expectFalse(r.cardShowsPending, "S3 高置信主题+空分类不应等待确认")
            // 主题独立判定：有效主题仍写入（applyClassification 语义）
            expectEqual(r.topicTitle, "工作与事业", "S3 主题判定独立于标签")
        }

        // ── 场景 3c：空分类 + 低置信主题 → 等待确认（D-04：用户可确认主题）──
        do {
            let r = simulate(
                selectedTopic: "工作与事业",
                suggestedTags: [],
                confidence: 0.7,
                activeTopics: activeTopics,
                recognizedTagKeys: recognized
            )
            expectTrue(r.isEmptyClassification, "S3c 空分类")
            expectTrue(r.cardShowsPending, "S3c 低置信主题（0.7<0.75）应等待确认")
        }

        // ── 场景 3b：空标签 + 无有效主题（典型 D-05+D-08′ 组合）──
        do {
            let r = simulate(
                selectedTopic: nil,
                suggestedTags: [],
                confidence: 0.4,
                activeTopics: activeTopics,
                recognizedTagKeys: recognized
            )
            expectNil(r.topicTitle, "S3b 无主题保持未分类")
            expectTrue(r.unclassifiedFilterMatch, "S3b 应出现在「未归类」筛选结果中")
        }

        // ── 场景 4：模型发明未知主题 → 白名单兜底（D-05）──
        do {
            let r = simulate(
                selectedTopic: "我的发明主题",
                suggestedTags: ["复盘"],
                confidence: 0.9,
                activeTopics: activeTopics,
                recognizedTagKeys: recognized
            )
            expectNil(r.topicTitle, "S4 未知主题应降级未分类")
            expectTrue(r.tagPaths.allSatisfy { $0.hasPrefix("未分类/") }, "S4 标签前缀应回退「未分类」")
        }

        // ── 场景 5：模型输出重复主题前缀（真实高频模型行为）──
        do {
            let r = simulate(
                selectedTopic: "工作与事业",
                suggestedTags: ["工作与事业/复盘", "工作与事业/新方向"],
                confidence: 0.85,
                activeTopics: activeTopics,
                recognizedTagKeys: recognized
            )
            expectTrue(r.tagPaths.contains("工作与事业/复盘"), "S5 重复前缀应剥离")
            expectFalse(r.tagPaths.contains("工作与事业/工作与事业/复盘"), "S5 不应二次拼接")
        }

        // ── 场景 6：低置信主题（0 < c < 0.75）──
        do {
            let r = simulate(
                selectedTopic: "工作与事业",
                suggestedTags: ["复盘"],
                confidence: 0.6,
                activeTopics: activeTopics,
                recognizedTagKeys: recognized
            )
            // 主题写入但置信 0.6 < 0.75 → 进待确认队列（由知识树队列承载）
            expectEqual(r.topicTitle, "工作与事业", "S6 低置信主题仍写入（进确认队列）")
            // 卡片层：无主题视角的模拟里 lowConfidence 信号
            let cardPendingLowConf = ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
                organizedStatus: "organized",
                hasPendingTagConfirmation: false,
                topicConfidence: 0.6
            )
            expectTrue(cardPendingLowConf, "S6 低置信主题信号应支持等待确认判定（实际卡片被已入主题优先级覆盖，由队列承载）")
        }

        // ── 场景 7：failed / processing 状态不参与待确认（状态机守卫）──
        do {
            expectFalse(
                ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
                    organizedStatus: "failed", hasPendingTagConfirmation: true, topicConfidence: 0.6
                ),
                "S7 failed 不显示等待确认"
            )
            expectFalse(
                ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
                    organizedStatus: "skipped", hasPendingTagConfirmation: true, topicConfidence: 0.6
                ),
                "S7 skipped 不显示等待确认"
            )
        }

        // ── 场景 8：长标签/空串标签过滤（parse 层规则模拟）──
        do {
            let raw = ["  ", "复盘", String(repeating: "长", count: 80)]
            let filtered = raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 60 }
            expectEqual(filtered, ["复盘"], "S8 空白与超长（>60字）标签应被过滤")
        }

        // ── 汇总 ──
        if failures.isEmpty {
            print("✅ 管道场景模拟：全部 \(total) 项断言通过（8 个场景）")
        } else {
            print("❌ 失败 \(failures.count)/\(total)：")
            failures.forEach { print("  - \($0)") }
            exit(1)
        }
    }

    private static func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
        total += 1
        if lhs != rhs { failures.append("\(message)：\(lhs) != \(rhs)") }
    }

    private static func expectNil(_ value: String?, _ message: String) {
        total += 1
        if value != nil { failures.append("\(message)：实际 \(value ?? "")") }
    }

    private static func expectTrue(_ value: Bool, _ message: String) {
        total += 1
        if !value { failures.append(message) }
    }

    private static func expectFalse(_ value: Bool, _ message: String) {
        expectTrue(!value, message)
    }
}
