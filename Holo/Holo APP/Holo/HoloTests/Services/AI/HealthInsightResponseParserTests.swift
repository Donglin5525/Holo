//
//  HealthInsightResponseParserTests.swift
//  HoloTests
//
//  健康洞察响应解析器测试：合法解析、evidenceId 同源过滤、围栏提取、容错、丢弃无效条目。
//

import XCTest
@testable import Holo

final class HealthInsightResponseParserTests: XCTestCase {

    private let legalIds: Set<String> = [
        "health-sleep-20260622",
        "finance-keyword-coffee-20260622",
        "task-completion-20260624"
    ]
    private let parser = HealthInsightResponseParser()

    func testParseValidJSONProducesCoreAndLoops() throws {
        let raw = """
        {
          "coreInsight": {
            "id": "core-1",
            "domain": "mixed",
            "title": "恢复不足影响执行力",
            "summary": "过去 14 天低睡眠日完成率更低。",
            "suggestedAction": "拆小下午任务",
            "confidence": 0.72,
            "evidenceIds": ["health-sleep-20260622", "task-completion-20260624"],
            "caveat": "相关性非因果"
          },
          "lifestyleLoops": [
            {
              "id": "loop-1",
              "domain": "finance",
              "title": "低睡眠日咖啡更多",
              "summary": "低睡眠日咖啡支出频率更高。",
              "confidence": 0.64,
              "evidenceIds": ["health-sleep-20260622", "finance-keyword-coffee-20260622"]
            }
          ]
        }
        """
        let parsed = try parser.parse(raw, legalEvidenceIds: legalIds)

        let core = try XCTUnwrap(parsed.coreInsight)
        XCTAssertEqual(core.kind, .core)
        XCTAssertEqual(core.domain, .mixed)
        XCTAssertEqual(core.confidence, 0.72, accuracy: 0.001)
        XCTAssertEqual(core.evidenceIds.count, 2)
        XCTAssertEqual(parsed.lifestyleLoops.count, 1)
        XCTAssertEqual(parsed.lifestyleLoops[0].kind, .lifestyleLoop)
        XCTAssertEqual(parsed.lifestyleLoops[0].evidenceIds.count, 2)
    }

    func testParseFiltersFabricatedEvidenceIds() throws {
        // LLM 编造了一个不存在的 id，必须被过滤掉（审查修订 P3）
        let raw = """
        {"coreInsight":{"id":"c","domain":"health","title":"t","summary":"s","confidence":0.5,
          "evidenceIds":["health-sleep-20260622","FAKE-FABRICATED-12345"]}}
        """
        let parsed = try parser.parse(raw, legalEvidenceIds: legalIds)

        XCTAssertEqual(parsed.coreInsight?.evidenceIds, ["health-sleep-20260622"])
    }

    func testParseExtractsFromMarkdownFence() throws {
        let raw = """
        这是模型的前导说明文字。
        ```json
        {"coreInsight":{"id":"c","title":"t","summary":"s","confidence":0.5,"evidenceIds":["health-sleep-20260622"]}}
        ```
        """
        let parsed = try parser.parse(raw, legalEvidenceIds: legalIds)

        XCTAssertEqual(parsed.coreInsight?.title, "t")
    }

    func testParseThrowsOnInvalidJSON() {
        XCTAssertThrowsError(try parser.parse("这不是合法 JSON", legalEvidenceIds: legalIds)) { error in
            guard case HealthInsightParseError.invalidJSON = error else {
                XCTFail("应为 invalidJSON 错误，实际：\(error)")
                return
            }
        }
    }

    func testParseDropsItemsWithoutTitleOrSummary() throws {
        let raw = """
        {
          "coreInsight": {"id":"c","domain":"health","title":"","summary":"s","confidence":0.5},
          "lifestyleLoops": [
            {"id":"l1","title":"有标题","summary":"有摘要","confidence":0.6},
            {"id":"l2","title":"","summary":"空标题"},
            {"id":"l3","title":"空摘要","summary":""}
          ]
        }
        """
        let parsed = try parser.parse(raw, legalEvidenceIds: legalIds)

        XCTAssertNil(parsed.coreInsight)  // core title 空，整体丢弃
        XCTAssertEqual(parsed.lifestyleLoops.count, 1)  // 只剩 l1
        XCTAssertEqual(parsed.lifestyleLoops[0].id, "l1")
    }

    func testParseToleratesMissingOptionalFields() throws {
        let raw = #"{"coreInsight":{"id":"c","title":"t","summary":"s"}}"#
        let parsed = try parser.parse(raw, legalEvidenceIds: legalIds)

        let core = try XCTUnwrap(parsed.coreInsight)
        XCTAssertEqual(core.domain, .mixed)  // 缺 domain → mixed
        XCTAssertEqual(core.confidence, 0)   // 缺 confidence → 0
        XCTAssertEqual(core.evidenceIds, [])  // 缺 → 空
        XCTAssertNil(core.suggestedAction)
    }

    func testParseClampsOutOfRangeConfidence() throws {
        let raw = #"{"coreInsight":{"id":"c","title":"t","summary":"s","confidence":1.5}}"#
        let parsed = try parser.parse(raw, legalEvidenceIds: legalIds)

        XCTAssertEqual(parsed.coreInsight?.confidence, 1.0, accuracy: 0.001)
    }
}
