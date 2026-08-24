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

    /// b2a87931 信息层级：单条 claim 的正文由开篇（directAnswer）承载，不再重复成卡。
    func testClaim渲染成短文sections() {
        let claim = makeClaim(text: "负向习惯发生量连续上升", evidenceIDs: ["e1"])
        let ev = makeEvidence(id: "e1", redacted: "刷手机次数上升", excerpt: "完整原文")
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])

        XCTAssertTrue(result.directAnswer?.contains("负向习惯") ?? false, "claim 正文应进入开篇")
        XCTAssertFalse(
            result.sections.contains { $0.body.contains("负向习惯") },
            "开篇已讲过的正文不再重复成卡"
        )
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

    func test持久展示本轮读取的档案与分层记忆来源() throws {
        let result = HoloAgentResultRenderer().render(
            claims: [],
            evidence: [],
            contextSources: [
                HoloAgentContextSourceSummary(kind: .profile, itemCount: 4),
                HoloAgentContextSourceSummary(kind: .currentStateMemory, itemCount: 2),
                HoloAgentContextSourceSummary(kind: .durableMemory, itemCount: 1)
            ]
        )

        XCTAssertEqual(result.contextSourceText, "个人档案 · 近期观察 2 条 · 长期规律 1 条")

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(HoloRenderedAgentResult.self, from: encoded)
        XCTAssertEqual(decoded.contextSources, result.contextSources, "来源披露应随 Agent 结果持久化")
    }

    /// 用户问“哪些地方需要优化”时，建议必须成为首要答案，事实退到支撑层。
    func test优化问题采用行动优先的信息层级() {
        let observation = HoloAgentClaim(
            id: "observation",
            type: "observation",
            displayText: "2026年总支出14598.83元，餐饮支出3516元",
            metricAssertions: [
                HoloMetricAssertion(
                    metricKey: "finance.total.amount",
                    value: 14598.83,
                    baselineValue: nil,
                    unit: "元",
                    comparison: nil,
                    evidenceIDs: ["total"]
                )
            ],
            evidenceIDs: ["total"],
            prohibitedInferences: [],
            confidence: 0.9
        )
        let suggestion = HoloAgentClaim(
            id: "suggestion",
            type: "suggestion",
            displayText: "优先复核餐饮支出，并为下个月设置可执行的餐饮上限",
            metricAssertions: [
                HoloMetricAssertion(
                    metricKey: "finance.category.amount",
                    value: 3516,
                    baselineValue: nil,
                    unit: "元",
                    comparison: "餐饮",
                    evidenceIDs: ["meal"]
                )
            ],
            evidenceIDs: ["meal"],
            prohibitedInferences: [],
            confidence: 0.84
        )
        let evidence = [
            makeEvidence(
                id: "total",
                redacted: "2026年截至当前总支出14598.83元",
                excerpt: "总支出",
                sourceModule: .finance,
                metricKey: "finance.total.amount",
                metricValue: 14598.83,
                unit: "元"
            ),
            makeEvidence(
                id: "meal",
                redacted: "餐饮支出3516元",
                excerpt: "餐饮",
                sourceModule: .finance,
                metricKey: "finance.category.amount",
                metricValue: 3516,
                unit: "元"
            )
        ]

        let result = HoloAgentResultRenderer().render(
            claims: [observation, suggestion],
            evidence: evidence,
            question: "分析我2026年的财务数据，有哪些需要优化的地方？",
            answerContext: HoloAgentAnswerContext(
                primaryTimeRange: HoloAgentTimeRange(
                    label: "2026年",
                    start: Date(timeIntervalSince1970: 1_767_225_600),
                    end: Date(timeIntervalSince1970: 1_798_761_600)
                ),
                snapshotCutoffAt: Date(timeIntervalSince1970: 1_774_540_800)
            )
        )

        XCTAssertTrue(result.directAnswer?.contains("优先优化") == true, "首屏应概括行动，不复制整段建议")
        XCTAssertFalse(result.directAnswer == suggestion.displayText, "第一条建议不得被提升成不同字号的开场正文")
        XCTAssertTrue(result.headline?.contains("优化建议") == true)
        XCTAssertEqual(result.recommendations?.count, 1, "建议必须进入类型化建议列表")
        XCTAssertEqual(result.recommendations?.first?.title, "优先复核餐饮支出")
        XCTAssertTrue(result.sections.contains { $0.kind == "observation" }, "仍要保留核验事实作为建议依据")
    }

    /// 真实事故回归：年度问题不得被 evidence 旧标签改回近 30 天；
    /// 财务事件记录不得显示 132/365 覆盖不足；两条建议必须同层、同序展示。
    func test年度财务优化统一答案上下文() {
        let staleRange = HoloAgentTimeRange(
            label: "近30天",
            start: Date(timeIntervalSince1970: 1_772_928_000),
            end: Date(timeIntervalSince1970: 1_775_520_000)
        )
        let authoritativeRange = HoloAgentTimeRange(
            label: "2026年",
            start: Date(timeIntervalSince1970: 1_767_225_600),
            end: Date(timeIntervalSince1970: 1_798_761_600)
        )
        let claims = [
            HoloAgentClaim(
                id: "fact",
                type: "observation",
                displayText: "礼物类支出为25230.11元",
                metricAssertions: [
                    HoloMetricAssertion(
                        metricKey: "finance.category.amount",
                        value: 25230.11,
                        baselineValue: nil,
                        unit: "元",
                        comparison: "礼物",
                        evidenceIDs: ["gift"]
                    )
                ],
                evidenceIDs: ["gift"],
                prohibitedInferences: [],
                confidence: 0.94
            ),
            HoloAgentClaim(
                id: "r1",
                type: "suggestion",
                displayText: "建议1（高优先级）：审视礼物类大额支出。其中一笔25000元的MacBook Pro占礼物总支出99%。",
                metricAssertions: [
                    HoloMetricAssertion(
                        metricKey: "finance.category.amount",
                        value: 25230.11,
                        baselineValue: nil,
                        unit: "元",
                        comparison: "礼物",
                        evidenceIDs: ["gift"]
                    ),
                    HoloMetricAssertion(
                        metricKey: "finance.transaction.amount",
                        value: 25000,
                        baselineValue: nil,
                        unit: "元",
                        comparison: "MacBook Pro",
                        evidenceIDs: ["gift"]
                    )
                ],
                evidenceIDs: ["gift"],
                prohibitedInferences: [],
                confidence: 0.91
            ),
            HoloAgentClaim(
                id: "r2",
                type: "suggestion",
                displayText: "建议2（中优先级）：控制月度预算执行。本月已超支409元，可先复核礼物与餐饮分类。",
                metricAssertions: [
                    HoloMetricAssertion(
                        metricKey: "finance.budget.overrun",
                        value: 409,
                        baselineValue: nil,
                        unit: "元",
                        comparison: nil,
                        evidenceIDs: ["budget"]
                    )
                ],
                evidenceIDs: ["budget"],
                prohibitedInferences: [],
                confidence: 0.86
            )
        ]
        let evidence = [
            makeEvidence(
                id: "gift",
                redacted: "礼物25230.11元，其中MacBook Pro 25000元",
                excerpt: "礼物25230.11元，其中MacBook Pro 25000元",
                sourceModule: .finance,
                timeRange: staleRange,
                metricKey: "finance.category.amount",
                metricValue: 25230.11,
                unit: "元"
            ),
            makeEvidence(
                id: "budget",
                redacted: "本月预算超支409元",
                excerpt: "本月预算超支409元",
                sourceModule: .finance,
                timeRange: HoloAgentTimeRange(
                    label: "本月",
                    start: Date(timeIntervalSince1970: 1_772_928_000),
                    end: Date(timeIntervalSince1970: 1_775_520_000)
                ),
                metricKey: "finance.budget.overrun",
                metricValue: 409,
                unit: "元"
            )
        ]

        let result = HoloAgentResultRenderer().render(
            claims: claims,
            evidence: evidence,
            question: "分析我2026年的财务数据，有哪些需要优化的地方？",
            coverage: HoloDataCoverage(
                coveredDays: 132,
                totalDays: 365,
                coverageRatio: 132.0 / 365.0,
                missingRanges: [],
                note: "132天有交易",
                semantics: .eventRecords
            ),
            answerContext: HoloAgentAnswerContext(
                primaryTimeRange: authoritativeRange,
                snapshotCutoffAt: Date(timeIntervalSince1970: 1_774_540_800)
            )
        )

        XCTAssertEqual(result.scope?.label, "2026年")
        XCTAssertTrue(result.scope?.displayLabel.contains("截至") == true)
        XCTAssertTrue(result.headline?.contains("2026年") == true)
        XCTAssertFalse(result.headline?.contains("近30天") == true)
        XCTAssertNil(result.coverageText, "事件型财务数据不得按有交易天数判断覆盖不足")
        XCTAssertEqual(result.limitations, [])
        XCTAssertEqual(result.recommendations?.map(\.id), ["r1", "r2"])
        XCTAssertEqual(result.recommendations?.map(\.title), ["审视礼物类大额支出", "控制月度预算执行"])
        XCTAssertEqual(result.recommendations?.map(\.priorityLabel), ["高优先级", "中优先级"])
        XCTAssertFalse(result.sections.contains { $0.kind == "suggestion" }, "建议只允许一个类型化展示来源")
    }

    // P1：修复 section.title/body 同值浪费
    /// section.title 用「观察 N」短 kicker，body 用 claim 正文，二者不应同值。
    /// b2a87931 信息层级后：首条 claim 正文进开篇，其后 claim 才渲染成卡片，故用双 claim。
    func testSectionTitleNotEqualToBody() {
        let first = makeClaim(text: "本月整体支出偏高", id: "c1")
        let second = makeClaim(text: "本月支出偏高，主要集中在餐饮", id: "c2")
        let result = HoloAgentResultRenderer().render(claims: [first, second], evidence: [])

        XCTAssertEqual(result.sections.count, 1, "开篇之外的 claim 应有 1 个 section")
        guard let section = result.sections.first else {
            XCTFail("section 缺失"); return
        }
        XCTAssertNotEqual(section.title, section.body, "title 不应等于 body（修复同值浪费）")
        XCTAssertEqual(section.body, "本月支出偏高，主要集中在餐饮", "body 应为 claim 正文")
        XCTAssertFalse(section.title.isEmpty, "title 不应为空")
    }

    // P1：section 透传 claim.confidence，供阶段 2 可视化
    /// section.confidence 应等于 claim.confidence（对成卡的 claim 断言）。
    func testSectionCarriesConfidence() {
        let first = makeClaim(text: "观察内容", id: "c1")
        let second = makeClaim(text: "另一条观察", id: "c2", confidence: 0.82)
        let result = HoloAgentResultRenderer().render(claims: [first, second], evidence: [])

        guard let section = result.sections.first else {
            XCTFail("section 缺失"); return
        }
        guard let confidence = section.confidence else {
            XCTFail("confidence 缺失"); return
        }
        XCTAssertEqual(confidence, 0.82, accuracy: 0.001, "section.confidence 应等于 claim.confidence")
    }

    /// 归因诊断场景回归：多条诊断 claim 不应产生多个"归因解读"重复标题，
    /// 归因结论只在 directAnswer 出现一次，sections 不重复归因正文。
    func test诊断归因不产生重复标题且结论只在directAnswer() {
        // 两条诊断 claim（归因结论），各自带量化数据
        let claim1 = HoloAgentClaim(
            id: "diag-1",
            type: "observation",
            displayText: "本月支出比上期增加800元，主要来自餐饮，贡献了总增量的65%",
            metricAssertions: [
                HoloMetricAssertion(metricKey: "finance.amount.change", value: 800, baselineValue: nil,
                                    unit: "元", comparison: "increasing", evidenceIDs: ["e1"])
            ],
            evidenceIDs: ["e1"], prohibitedInferences: [], confidence: 0.9
        )
        let claim2 = HoloAgentClaim(
            id: "diag-2",
            type: "insight",
            displayText: "预算口径下餐饮已用120%超限，娱乐接近上限",
            metricAssertions: [
                HoloMetricAssertion(metricKey: "finance.budget.category.progress", value: 1.2, baselineValue: nil,
                                    unit: "比例", comparison: "餐饮", evidenceIDs: ["e2"])
            ],
            evidenceIDs: ["e2"], prohibitedInferences: [], confidence: 0.85
        )
        let evidence = [
            makeEvidence(id: "e1", redacted: "支出增加800元", excerpt: "原文",
                         sourceModule: .finance, metricKey: "finance.amount.change", metricValue: 800, unit: "元"),
            makeEvidence(id: "e2", redacted: "餐饮预算进度120%", excerpt: "原文",
                         sourceModule: .finance, metricKey: "finance.budget.category.progress", metricValue: 1.2, unit: "比例")
        ]

        let result = HoloAgentResultRenderer().render(
            claims: [claim1, claim2],
            evidence: evidence,
            question: "为什么本期支出超支，有哪些因素导致？",
            requestedDeliverables: [.diagnosis]
        )

        // 1. 不应出现任何"归因解读"标题（旧 bug：每条诊断 claim 一个同名标题）
        let attributionTitles = result.sections.filter { $0.title == "归因解读" }
        XCTAssertTrue(attributionTitles.isEmpty, "不应有'归因解读'重复标题，实际：\(result.sections.map(\.title))")

        // 2. 归因结论应在 directAnswer 完整出现（两条诊断 claim 串联）
        let direct = result.directAnswer ?? ""
        XCTAssertTrue(direct.contains("餐饮"), "directAnswer 应含餐饮归因")
        XCTAssertTrue(direct.contains("120%"), "directAnswer 应含预算超限归因")

        // 3. sections 不应重复归因结论的正文（避免"开篇讲一遍→卡片再讲一遍"）
        for section in result.sections {
            XCTAssertFalse(section.body.contains("贡献了总增量的65%"),
                           "sections 不应重复归因结论正文，冲突 section：\(section.title)")
        }
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
        // 总额句进开篇（directAnswer）后不再重复成卡；分类与大额样例必须保留为结构化卡片
        XCTAssertEqual(result.sections.count, 2, "分类与大额样例须各成一段观察")
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
                note: "已读取 28/30 天健康数据",
                semantics: .dailyObservations
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
