//
//  HoloAgentResultRendererTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 4.4 Result Renderer 测试（XCTest 版本）
//

import XCTest
@testable import Holo

/// HoloAgentResultRenderer 渲染逻辑测试：claim → 短文 section，证据脱敏引用，禁止 Markdown 表格。
final class HoloAgentResultRendererTests: XCTestCase {

    // MARK: - 测试用例

    /// claim 渲染成单个短文 section，body 含 claim 正文。
    func testClaim渲染成短文sections() {
        let claim = makeClaim(text: "负向习惯发生量连续上升", evidenceIDs: ["e1"])
        let ev = makeEvidence(id: "e1", redacted: "刷手机次数上升", excerpt: "完整原文")
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])

        XCTAssertEqual(result.sections.count, 1, "应有 1 个 section")
        XCTAssertTrue(result.sections.first?.body.contains("负向习惯") ?? false, "section 应含 claim 内容")
    }

    /// 证据引用摘要使用 redactedExcerpt 文案。
    func test含证据引用摘要() {
        let claim = makeClaim(text: "晚间餐饮增加", evidenceIDs: ["e1"])
        let ev = makeEvidence(id: "e1", redacted: "晚间餐饮 4 次", excerpt: "原文")
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])

        XCTAssertTrue(
            result.evidenceReferences.contains { $0.summary.contains("晚间餐饮") },
            "应含证据引用摘要"
        )
    }

    /// 输出不应含 Markdown 表格分隔符或代码块。
    func test不含Markdown表格() {
        let claim = makeClaim(text: "开销增加", evidenceIDs: ["e1"])
        let ev = makeEvidence(id: "e1", redacted: "脱敏", excerpt: "原文")
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])

        let flat = "\(result.title)\(result.summary)\(result.sections.map { $0.title + $0.body }.joined())\(result.evidenceReferences.map { $0.summary }.joined())"
        XCTAssertFalse(flat.contains("|-"), "不应含 Markdown 表格分隔符")
        XCTAssertFalse(flat.contains("```"), "不应含代码块")
    }

    /// 敏感 Evidence 引用使用 redactedExcerpt，不暴露完整原文。
    func test敏感Evidence用脱敏摘要() {
        let claim = makeClaim(text: "观察", evidenceIDs: ["e1"])
        let ev = makeEvidence(id: "e1", redacted: "脱敏摘要", excerpt: "SECRET_FULL_TEXT")
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])

        let flat = result.evidenceReferences.map { $0.summary }.joined()
        XCTAssertTrue(flat.contains("脱敏摘要"), "证据引用应用 redactedExcerpt")
        XCTAssertFalse(flat.contains("SECRET_FULL_TEXT"), "不应暴露完整敏感原文")
    }

    // P1：修复 section.title/body 同值浪费
    /// section.title 用「观察 N」短 kicker，body 用 claim 正文，二者不应同值。
    func testSectionTitleNotEqualToBody() {
        let claim = makeClaim(text: "本月支出偏高，主要集中在餐饮")
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [])

        XCTAssertEqual(result.sections.count, 1, "应有 1 个 section")
        guard let section = result.sections.first else {
            XCTFail("section 缺失"); return
        }
        XCTAssertNotEqual(section.title, section.body, "title 不应等于 body（修复同值浪费）")
        XCTAssertEqual(section.body, "本月支出偏高，主要集中在餐饮", "body 应为 claim 正文")
        XCTAssertFalse(section.title.isEmpty, "title 不应为空")
    }

    // P1：section 透传 claim.confidence，供阶段 2 可视化
    /// section.confidence 应等于 claim.confidence。
    func testSectionCarriesConfidence() {
        let claim = makeClaim(text: "观察内容", confidence: 0.82)
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [])

        guard let section = result.sections.first else {
            XCTFail("section 缺失"); return
        }
        guard let confidence = section.confidence else {
            XCTFail("confidence 缺失"); return
        }
        XCTAssertEqual(confidence, 0.82, accuracy: 0.001, "section.confidence 应等于 claim.confidence")
    }

    /// 财务 evidence 带时间范围时，渲染结果应携带下钻路由。
    func testFinanceEvidenceCarriesDrilldownRoute() {
        let range = HoloAgentTimeRange(
            label: "近两周",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 2000)
        )
        let claim = makeClaim(text: "消费金额上升", evidenceIDs: ["e1"])
        let ev = makeEvidence(
            id: "e1",
            redacted: "消费金额 近两周：9115 元",
            excerpt: "原文",
            sourceModule: .finance,
            timeRange: range
        )

        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])

        let drilldown = result.evidenceReferences.first?.financeDrilldown
        XCTAssertEqual(drilldown?.sourceEvidenceID, "e1", "应记录来源 evidence ID")
        XCTAssertEqual(drilldown?.label, "近两周", "应保留用户口径标签")
        XCTAssertEqual(drilldown?.start, range.start, "应保留下钻开始时间")
        XCTAssertEqual(drilldown?.end, range.end, "应保留下钻结束时间")
    }

    /// 关键词消费 evidence 应把关键词透传给证据核对页。
    func testFinanceKeywordEvidenceCarriesDrilldownKeyword() {
        let range = HoloAgentTimeRange(
            label: "最近一个月",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 2000)
        )
        let baselineRange = HoloAgentTimeRange(
            label: "上一个月",
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 999)
        )
        let claim = makeClaim(text: "咖啡消费频率上升", evidenceIDs: ["e1"])
        let ev = makeEvidence(
            id: "e1",
            redacted: "账单文本命中「咖啡」 最近一个月：8 次",
            excerpt: "账单文本命中「咖啡」 最近一个月：8 次",
            sourceModule: .finance,
            timeRange: range,
            baselineTimeRange: baselineRange,
            metricKey: "finance.keyword.count"
        )

        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])

        let drilldown = result.evidenceReferences.first?.financeDrilldown
        XCTAssertEqual(drilldown?.keyword, "咖啡", "应把咖啡作为明细核对筛选词")
        XCTAssertEqual(drilldown?.baselineStart, baselineRange.start, "应保留对比期开始时间")
        XCTAssertEqual(drilldown?.baselineEnd, baselineRange.end, "应保留对比期结束时间")
    }

    /// 财务“钱花哪了”不能只渲染总额，必须保留分类去向和可核对的大额样例。
    func testFinanceSpendingBreakdownRendersCategoriesAndSamples() {
        let range = HoloAgentTimeRange(
            label: "上月",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 2000)
        )
        let claims = [
            makeClaim(
                text: "上月账单总支出约 14598.83 元。",
                evidenceIDs: ["total"],
                id: "c-total"
            ),
            makeClaim(
                text: "上月主要去向是 餐饮 3516 元、居住 3156 元、数码 1525 元，这些是优先核对的分类。",
                evidenceIDs: ["meal", "rent", "digital"],
                id: "c-categories"
            ),
            makeClaim(
                text: "上月最大几笔包括：6月29日 居住 房租 -¥3156、6月16日 数码 MacBook 分期 -¥1525。",
                evidenceIDs: ["sample-rent", "sample-digital"],
                id: "c-samples"
            )
        ]
        let evidence = [
            makeEvidence(id: "total", redacted: "上月总支出：14598.83 元", excerpt: "上月总支出：14598.83 元",
                         sourceModule: .finance, timeRange: range, metricKey: "finance.total.amount"),
            makeEvidence(id: "meal", redacted: "上月分类去向：餐饮：3516 元", excerpt: "上月分类去向：餐饮：3516 元",
                         sourceModule: .finance, timeRange: range, metricKey: "finance.category.amount"),
            makeEvidence(id: "rent", redacted: "上月分类去向：居住：3156 元", excerpt: "上月分类去向：居住：3156 元",
                         sourceModule: .finance, timeRange: range, metricKey: "finance.category.amount"),
            makeEvidence(id: "digital", redacted: "上月分类去向：数码：1525 元", excerpt: "上月分类去向：数码：1525 元",
                         sourceModule: .finance, timeRange: range, metricKey: "finance.category.amount"),
            makeEvidence(id: "sample-rent", redacted: "6月29日 居住 房租 -¥3156", excerpt: "6月29日 居住 房租 -¥3156",
                         sourceModule: .finance, timeRange: range, metricKey: "finance.transaction.sample"),
            makeEvidence(id: "sample-digital", redacted: "6月16日 数码 MacBook 分期 -¥1525", excerpt: "6月16日 数码 MacBook 分期 -¥1525",
                         sourceModule: .finance, timeRange: range, metricKey: "finance.transaction.sample")
        ]

        let result = HoloAgentResultRenderer().render(claims: claims, evidence: evidence, title: "深度分析")
        let visibleText = "\(result.summary) \(result.sections.map(\.body).joined(separator: " ")) \(result.evidenceReferences.map(\.summary).joined(separator: " "))"

        XCTAssertTrue(visibleText.contains("14598.83"), "应保留上月总额")
        XCTAssertTrue(visibleText.contains("餐饮"), "应保留 Top 分类餐饮")
        XCTAssertTrue(visibleText.contains("居住"), "应保留 Top 分类居住")
        XCTAssertTrue(visibleText.contains("数码"), "应保留 Top 分类数码")
        XCTAssertTrue(visibleText.contains("房租"), "应保留可核对大额样例")
        XCTAssertTrue(visibleText.contains("MacBook"), "应保留可核对大额样例")
        XCTAssertFalse(visibleText.contains("finance.total.amount"), "用户可见文本不能暴露内部 metricKey")
        XCTAssertEqual(result.sections.count, 3, "应有总额、分类、大额样例三段观察")
        XCTAssertEqual(result.evidenceReferences.count, 6, "应保留全部可核对账单依据")
        XCTAssertTrue(
            result.evidenceReferences.allSatisfy { $0.financeDrilldown?.label == "上月" },
            "每条财务依据都应可下钻到上月账单口径"
        )
    }

    /// 老版本 agentResultJSON 没有 financeDrilldown 字段时仍应可解码。
    func testLegacyAgentResultWithoutFinanceDrilldownDecodes() throws {
        let json = """
        {
          "title": "深度分析",
          "summary": "消费观察",
          "sections": [
            { "title": "观察 1", "body": "近一个月咖啡消费有记录", "confidence": 0.8 }
          ],
          "evidenceReferences": [
            { "id": "e1", "summary": "咖啡消费 3 次" }
          ]
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let result = try JSONDecoder().decode(HoloRenderedAgentResult.self, from: data)

        XCTAssertEqual(result.evidenceReferences.first?.id, "e1")
        XCTAssertNil(result.evidenceReferences.first?.financeDrilldown)
    }

    // P1：多条 claim 的 title 互不相同（「观察 1/2/3」）
    /// 多条 claim 渲染出的 section title 应互不相同。
    func testMultipleClaimsHaveDistinctTitles() {
        let claims = [
            makeClaim(text: "观察一的内容", id: "c1"),
            makeClaim(text: "观察二的内容", id: "c2"),
            makeClaim(text: "观察三的内容", id: "c3")
        ]
        let result = HoloAgentResultRenderer().render(claims: claims, evidence: [])

        let titles = result.sections.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "多条 claim 的 title 应互不相同")
    }

    /// 顶层 claim.evidenceIDs 被 LLM 写错（无效 ID）时，应改用 metricAssertions 里已校验的有效证据展示，不显示「证据缺失」。
    /// 回归：canonical evidence ID 是 UUID 拼接的长串，LLM 在顶层 evidenceIDs 常写错；
    /// Verifier 只校验 metricAssertions 的 ID，render 原先展示顶层 ID 导致频繁「（证据缺失）」。
    func test顶层EvidenceID无效时改用已校验证据不显示缺失() {
        let claim = HoloAgentClaim(
            id: "c1", type: "observation", displayText: "买烟频率约每两天一次",
            metricAssertions: [HoloMetricAssertion(
                metricKey: "k", value: 15, baselineValue: nil,
                unit: "次", comparison: nil, evidenceIDs: ["e1"]
            )],
            evidenceIDs: ["bad-llm-id"],  // 模拟 LLM 顶层写错的无效 ID
            prohibitedInferences: [], confidence: 0.8
        )
        let ev = makeEvidence(id: "e1", redacted: "买烟记录 近一个月 15 次", excerpt: "原文")

        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])

        let summaries = result.evidenceReferences.map(\.summary).joined()
        XCTAssertTrue(summaries.contains("买烟记录"), "应展示 metricAssertions 里已校验的有效证据")
        XCTAssertFalse(summaries.contains("证据缺失"), "顶层无效 ID 不应导致「证据缺失」")
    }

    /// 用户只问步数时，结果必须直接回答步数，且任何可见区域都不能泄漏内部字段。
    func test步数问题生成用户可读答案契约() {
        let range = HoloAgentTimeRange(
            label: "最近一个月",
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let claim = HoloAgentClaim(
            id: "steps",
            type: "observation",
            displayText: "步数汇总：health.steps.average = 6990.80 步；步数汇总：health.steps.goal_met_days = 1.00 天",
            metricAssertions: [
                HoloMetricAssertion(
                    metricKey: "health.steps.average",
                    value: 6990.8,
                    baselineValue: nil,
                    unit: "步",
                    comparison: nil,
                    evidenceIDs: ["steps-average"]
                ),
                HoloMetricAssertion(
                    metricKey: "health.steps.goal_met_days",
                    value: 1,
                    baselineValue: nil,
                    unit: "天",
                    comparison: nil,
                    evidenceIDs: ["steps-goal"]
                )
            ],
            evidenceIDs: ["steps-average", "steps-goal"],
            prohibitedInferences: [],
            confidence: 0.9
        )
        let evidence = [
            makeEvidence(
                id: "steps-average",
                redacted: "步数汇总：health.steps.average = 6990.80 步",
                excerpt: "步数汇总：health.steps.average = 6990.80 步",
                sourceModule: .health,
                timeRange: range,
                metricKey: "health.steps.average",
                metricValue: 6990.8,
                unit: "步"
            ),
            makeEvidence(
                id: "steps-goal",
                redacted: "步数汇总：health.steps.goal_met_days = 1.00 天",
                excerpt: "步数汇总：health.steps.goal_met_days = 1.00 天",
                sourceModule: .health,
                timeRange: range,
                metricKey: "health.steps.goal_met_days",
                metricValue: 1,
                unit: "天"
            )
        ]

        let result = HoloAgentResultRenderer().render(
            claims: [claim],
            evidence: evidence,
            title: "深度分析",
            question: "最近一个月平均步数是多少？",
            coverage: HoloDataCoverage(
                coveredDays: 28,
                totalDays: 30,
                coverageRatio: 28.0 / 30.0,
                missingRanges: [],
                note: "已读取 28/30 天健康数据"
            )
        )

        XCTAssertEqual(result.headline, "最近一个月的步数")
        XCTAssertEqual(result.directAnswer, "最近一个月，日均 6,991 步")
        XCTAssertTrue(result.coverageText?.contains("28/30 天") == true)
        XCTAssertFalse(result.headline?.contains("睡眠") == true)
        XCTAssertFalse(result.sections.contains { $0.title.range(of: #"观察\s*\d+"#, options: .regularExpression) != nil })

        let visibleText = [
            result.headline,
            result.directAnswer,
            result.coverageText,
            result.summary
        ].compactMap { $0 }.joined(separator: " ")
            + result.sections.map { " \($0.title) \($0.body)" }.joined()
            + result.evidenceReferences.map { " \($0.summary)" }.joined()

        XCTAssertFalse(visibleText.contains("health."))
        XCTAssertFalse(visibleText.contains("goal_met_days"))
        XCTAssertFalse(visibleText.contains("average ="))
    }

    // MARK: - 测试数据构造助手

    private func makeEvidence(
        id: String,
        redacted: String,
        excerpt: String,
        sourceModule: HoloEvidenceSourceModule = .habit,
        timeRange: HoloAgentTimeRange? = nil,
        baselineTimeRange: HoloAgentTimeRange? = nil,
        metricKey: String = "k",
        metricValue: Double = 1,
        unit: String = "次"
    ) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: id, sourceModule: sourceModule, sourceID: nil, sourceKind: "kind",
            timeRange: timeRange, occurredAt: nil,
            metricKey: metricKey, metricValue: metricValue, unit: unit,
            baselineValue: nil, baselineTimeRange: baselineTimeRange, comparison: nil,
            excerpt: excerpt, redactedExcerpt: redacted,
            sensitivity: .sensitive, confidence: 1.0, status: .active,
            generatedBy: "test", generatedAt: Date(timeIntervalSince1970: 1000),
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
    }

    private func makeClaim(
        text: String,
        evidenceIDs: [String] = [],
        id: String = "c1",
        confidence: Double = 0.9
    ) -> HoloAgentClaim {
        HoloAgentClaim(
            id: id, type: "observation", displayText: text,
            metricAssertions: [HoloMetricAssertion(metricKey: "k", value: 1, baselineValue: nil,
                                                   unit: "次", comparison: nil, evidenceIDs: evidenceIDs)],
            evidenceIDs: evidenceIDs, prohibitedInferences: [], confidence: confidence
        )
    }
}
