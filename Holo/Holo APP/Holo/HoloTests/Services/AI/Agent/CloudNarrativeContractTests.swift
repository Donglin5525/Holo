//
//  CloudNarrativeContractTests.swift
//  Holo
//
//  温暖陪伴 P0 叙事契约（2026-09-15 方案 WARM-P0-04）：
//  云端已生成的自然叙事（narrativeSummary / keyInsight / claim interpretation）
//  必须端到端保真——JSON 解码不丢字段、编排优先自然摘要、坏字段与旧结果安全降级。
//

import XCTest
@testable import Holo

final class CloudNarrativeContractTests: XCTestCase {

    // MARK: - JSON 解码契约（服务端 result → CloudResult）

    private func decodeResult(_ json: String) throws -> HoloCloudAnalysisClient.StatusResponse.CloudResult {
        struct Wrapper: Decodable {
            let result: HoloCloudAnalysisClient.StatusResponse.CloudResult
        }
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        return wrapper.result
    }

    func test_新格式JSON_叙事字段全量解码保真() throws {
        let json = """
        {"result": {
          "title": "外卖撑起了这个月",
          "narrativeSummary": "这个月真正把餐饮拉高的是晚间外卖，其余支出平稳。",
          "keyInsight": "晚间外卖与晚睡同时变多，像是一个节奏问题",
          "claims": [{
            "summary": "本月餐饮 102 元",
            "displayText": "本月餐饮支出合计 102 元，全部来自晚间时段",
            "evidenceIDs": ["finance.transactions#0"],
            "type": "change",
            "confidence": 0.8,
            "interpretation": "像是下班后不想做饭的节奏"
          }],
          "reasoning": "", "evidence": [],
          "completedAt": "2026-09-15T00:00:00Z", "engine": "cloud-m2a"
        }}
        """
        let result = try decodeResult(json)
        XCTAssertEqual(result.narrativeSummary, "这个月真正把餐饮拉高的是晚间外卖，其余支出平稳。")
        XCTAssertEqual(result.keyInsight, "晚间外卖与晚睡同时变多，像是一个节奏问题")
        XCTAssertEqual(result.claims?.first?.type, "change")
        XCTAssertEqual(result.claims?.first?.confidence ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(result.claims?.first?.interpretation, "像是下班后不想做饭的节奏")
    }

    func test_旧格式JSON_缺失叙事字段解码为nil() throws {
        // 后端发版前领取的在途结果：JSON 无叙事字段，解码必须成功且字段为 nil
        let json = """
        {"result": {
          "title": "旧结果标题",
          "claims": [{
            "summary": "本月餐饮 102 元",
            "displayText": "本月餐饮支出合计 102 元",
            "evidenceIDs": []
          }],
          "reasoning": "", "evidence": [],
          "completedAt": "2026-09-14T00:00:00Z", "engine": "cloud-m2a"
        }}
        """
        let result = try decodeResult(json)
        XCTAssertNil(result.narrativeSummary)
        XCTAssertNil(result.keyInsight)
        XCTAssertNil(result.claims?.first?.type)
        XCTAssertNil(result.claims?.first?.confidence)
        XCTAssertNil(result.claims?.first?.interpretation)
    }

    // MARK: - 叙事编排契约（composedCloudNarrative）

    /// 传输模型按真实领取路径构造（JSON 解码），不走 memberwise init——
    /// let+默认值字段不进 memberwise 参数，且解码本身就是被锁定的契约。
    private func claimJSON(
        body: String,
        type: String? = nil,
        confidence: Double? = nil,
        interpretation: String? = nil
    ) -> String {
        var fields = [
            "\"displayText\": \"\(body)\"",
            "\"evidenceIDs\": []",
        ]
        if let type { fields.append("\"type\": \"\(type)\"") }
        if let confidence { fields.append("\"confidence\": \(confidence)") }
        if let interpretation { fields.append("\"interpretation\": \"\(interpretation)\"") }
        return "{\(fields.joined(separator: ", "))}"
    }

    private func makeResult(
        title: String? = nil,
        narrativeSummary: String? = nil,
        keyInsight: String? = nil,
        claims: [String]
    ) throws -> HoloCloudAnalysisClient.StatusResponse.CloudResult {
        var fields = [
            "\"claims\": [" + claims.joined(separator: ", ") + "]",
            "\"reasoning\": \"\"",
            "\"evidence\": []",
        ]
        if let title { fields.append("\"title\": \"\(title)\"") }
        if let narrativeSummary { fields.append("\"narrativeSummary\": \"\(narrativeSummary)\"") }
        if let keyInsight { fields.append("\"keyInsight\": \"\(keyInsight)\"") }
        let json = "{\"result\": {" + fields.joined(separator: ", ") + "}}"
        return try decodeResult(json)
    }

    func test_编排_自然摘要优先于分号拼接() throws {
        let result = try makeResult(
            title: "外卖撑起了这个月",
            narrativeSummary: "这个月餐饮上涨主要来自晚间外卖，其余支出平稳。",
            keyInsight: "晚间外卖与晚睡同时变多",
            claims: [
                claimJSON(body: "本月餐饮支出合计 102 元"),
                claimJSON(body: "外卖占餐饮支出的六成"),
            ]
        )
        let composed = HoloCloudAnalysisService.composedCloudNarrative(from: result)
        XCTAssertEqual(composed.title, "外卖撑起了这个月")
        XCTAssertEqual(composed.summary, "这个月餐饮上涨主要来自晚间外卖，其余支出平稳。")
        XCTAssertEqual(composed.narrativeSummary, "这个月餐饮上涨主要来自晚间外卖，其余支出平稳。")
        XCTAssertEqual(composed.keyInsight, "晚间外卖与晚睡同时变多")
    }

    func test_编排_无叙事字段回退分号拼接() throws {
        let result = try makeResult(claims: [
            claimJSON(body: "本月餐饮支出合计 102 元"),
            claimJSON(body: "外卖占餐饮支出的六成"),
        ])
        let composed = HoloCloudAnalysisService.composedCloudNarrative(from: result)
        XCTAssertEqual(composed.summary, "本月餐饮支出合计 102 元；外卖占餐饮支出的六成")
        XCTAssertNil(composed.narrativeSummary)
        XCTAssertNil(composed.keyInsight)
        XCTAssertEqual(composed.title, "深度分析")
    }

    func test_编排_section标题不再使用发现N_走语义短标题且claim字段透传() throws {
        let result = try makeResult(claims: [
            claimJSON(
                body: "本月餐饮支出合计 102 元，全部来自晚间时段",
                type: "change",
                confidence: 0.8,
                interpretation: "像是下班后不想做饭的节奏"
            ),
        ])
        let composed = HoloCloudAnalysisService.composedCloudNarrative(from: result)
        XCTAssertEqual(composed.sections.count, 1)
        let section = composed.sections[0]
        XCTAssertEqual(section.title, "本月餐饮支出合计 102 元")
        XCTAssertFalse(section.title.hasPrefix("发现"))
        XCTAssertEqual(section.body, "本月餐饮支出合计 102 元，全部来自晚间时段")
        XCTAssertEqual(section.kind, "change")
        XCTAssertEqual(section.confidence ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(section.interpretation, "像是下班后不想做饭的节奏")
    }

    func test_编排_同前缀claim标题重名退数据解读() throws {
        let result = try makeResult(claims: [
            claimJSON(body: "晚间外卖变多了，比上月多 8 次"),
            claimJSON(body: "晚间外卖变多了，集中在工作日"),
        ])
        let composed = HoloCloudAnalysisService.composedCloudNarrative(from: result)
        XCTAssertEqual(composed.sections[0].title, "晚间外卖变多了")
        XCTAssertEqual(composed.sections[1].title, "数据解读")
    }

    func test_编排_含内部token的叙事字段被防线拒绝并回退() throws {
        let result = try makeResult(
            narrativeSummary: "finance.total.amount 上涨 32%",
            keyInsight: "外卖_metric 泄漏",
            claims: [claimJSON(body: "本月餐饮支出合计 102 元")]
        )
        let composed = HoloCloudAnalysisService.composedCloudNarrative(from: result)
        XCTAssertNil(composed.narrativeSummary)
        XCTAssertNil(composed.keyInsight)
        XCTAssertEqual(composed.summary, "本月餐饮支出合计 102 元")
    }

    func test_编排_空claims且无摘要_保持兜底文案() throws {
        let result = try makeResult(claims: [])
        let composed = HoloCloudAnalysisService.composedCloudNarrative(from: result)
        XCTAssertEqual(composed.summary, "本期暂无显著观察")
        XCTAssertTrue(composed.sections.isEmpty)
    }
}
// MARK: - P0 交付核验字段解码契约（2026-09-19 提示词与证据链方案 任务2）

extension CloudNarrativeContractTests {

    func test_交付核验字段_警告范围与已核验指标全量解码() throws {
        let json = """
        {"result": {
          "title": "外卖撑起了这个月",
          "claims": [{
            "summary": "本月餐饮 102 元",
            "displayText": "本月餐饮支出合计 102 元",
            "evidenceIDs": ["dynamic.finance_transactions.cat_total.__"],
            "type": "change",
            "metricAssertions": [{
              "metricKey": "dynamic.finance_transactions.cat_total.__",
              "value": -102,
              "baselineValue": -88,
              "unit": "元",
              "comparison": "餐饮",
              "evidenceIDs": ["dynamic-dynamic.finance_transactions.cat_total.__"]
            }]
          }],
          "reasoning": "", "evidence": [],
          "warnings": ["METRIC_MISMATCH:dynamic.finance_transactions.total.all"],
          "snapshotCutoffAt": "2026-09-19T05:00:00Z",
          "taskRange": {"label": "最近30天", "start": 1755640000, "end": 1758253200},
          "completedAt": "2026-09-19T06:00:00Z", "engine": "cloud-m2a"
        }}
        """
        let result = try decodeResult(json)
        XCTAssertEqual(result.warnings, ["METRIC_MISMATCH:dynamic.finance_transactions.total.all"])
        XCTAssertEqual(result.snapshotCutoffAt, "2026-09-19T05:00:00Z")
        XCTAssertEqual(result.taskRange?.label, "最近30天")
        XCTAssertEqual(result.taskRange?.start ?? 0, 1_755_640_000)
        XCTAssertEqual(result.taskRange?.end ?? 0, 1_758_253_200)
        let assertion = try XCTUnwrap(result.claims?.first?.metricAssertions?.first)
        XCTAssertEqual(assertion.metricKey, "dynamic.finance_transactions.cat_total.__")
        XCTAssertEqual(assertion.value ?? 0, -102)
        XCTAssertEqual(assertion.baselineValue ?? 0, -88)
        XCTAssertEqual(assertion.unit, "元")
        XCTAssertEqual(assertion.comparison, "餐饮")
    }

    func test_旧结果无核验字段_解码全部为nil不炸() throws {
        let json = """
        {"result": {
          "title": "旧报告",
          "claims": [{"displayText": "本月餐饮支出合计 102 元"}],
          "reasoning": "", "evidence": [],
          "completedAt": "2026-08-01T00:00:00Z", "engine": "cloud-m2a"
        }}
        """
        let result = try decodeResult(json)
        XCTAssertNil(result.warnings)
        XCTAssertNil(result.snapshotCutoffAt)
        XCTAssertNil(result.taskRange)
        XCTAssertNil(result.claims?.first?.metricAssertions)
    }
}
