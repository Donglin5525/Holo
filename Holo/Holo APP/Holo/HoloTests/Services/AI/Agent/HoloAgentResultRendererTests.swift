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

    // MARK: - 测试数据构造助手

    private func makeEvidence(
        id: String,
        redacted: String,
        excerpt: String,
        sourceModule: HoloEvidenceSourceModule = .habit,
        timeRange: HoloAgentTimeRange? = nil,
        baselineTimeRange: HoloAgentTimeRange? = nil,
        metricKey: String = "k"
    ) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: id, sourceModule: sourceModule, sourceID: nil, sourceKind: "kind",
            timeRange: timeRange, occurredAt: nil,
            metricKey: metricKey, metricValue: 1, unit: "次",
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
