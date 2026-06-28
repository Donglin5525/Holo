//
//  HealthInsightGenerationModelsTests.swift
//  HoloTests
//
//  健康洞察数据模型 Codable / 边界测试。
//

import XCTest
@testable import Holo

final class HealthInsightGenerationModelsTests: XCTestCase {

    // MARK: - Codable round-trip

    func testSnapshotRoundTripPreservesAllFields() throws {
        let original = GeneratedHealthInsightSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            period: HealthInsightPeriod(
                start: Date(timeIntervalSince1970: 1_700_000_000),
                end: Date(timeIntervalSince1970: 1_700_086_400),
                days: 14
            ),
            status: .fresh,
            coreInsight: GeneratedHealthInsight(
                id: "core-1",
                kind: .core,
                domain: .mixed,
                title: "恢复不足影响执行力",
                summary: "过去 14 天低睡眠日完成率更低。",
                suggestedAction: "拆小下午任务",
                confidence: 0.72,
                evidenceIds: ["health-sleep-20260624", "task-completion-20260624"],
                caveat: "相关性非因果"
            ),
            lifestyleLoops: [
                GeneratedHealthInsight(
                    id: "loop-1",
                    kind: .lifestyleLoop,
                    domain: .finance,
                    title: "低睡眠日咖啡更多",
                    summary: "低睡眠日咖啡支出频率更高。",
                    suggestedAction: nil,
                    confidence: 0.64,
                    evidenceIds: ["health-sleep-20260622", "finance-keyword-coffee-20260622"],
                    caveat: nil
                )
            ],
            evidence: [
                HealthInsightEvidence(
                    id: "health-sleep-20260624",
                    domain: .health,
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                    title: "6月24日睡眠 5.8 小时",
                    detail: "低于 6 小时阈值",
                    metricKey: "health.sleep.hours",
                    metricValue: 5.8,
                    unit: "小时"
                )
            ],
            fallbackReason: nil
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(GeneratedHealthInsightSnapshot.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - 边界

    func testSnapshotAllowsEmptyLifestyleLoopsAndNoCore() {
        let snapshot = GeneratedHealthInsightSnapshot(
            generatedAt: Date(),
            period: HealthInsightPeriod(start: Date(), end: Date(), days: 14),
            status: .insufficientData,
            coreInsight: nil,
            lifestyleLoops: [],
            evidence: [],
            fallbackReason: "无睡眠数据"
        )

        XCTAssertNil(snapshot.coreInsight)
        XCTAssertTrue(snapshot.lifestyleLoops.isEmpty)
        XCTAssertEqual(snapshot.status, .insufficientData)
        XCTAssertEqual(snapshot.fallbackReason, "无睡眠数据")
    }

    func testInsightAllowsMissingOptionalFields() {
        let insight = GeneratedHealthInsight(
            id: "core-1",
            kind: .core,
            domain: .health,
            title: "标题",
            summary: "摘要",
            suggestedAction: nil,
            confidence: 0.5,
            evidenceIds: [],
            caveat: nil
        )

        XCTAssertNil(insight.suggestedAction)
        XCTAssertNil(insight.caveat)
        XCTAssertTrue(insight.evidenceIds.isEmpty)
    }

    func testDomainUnknownRawValueReturnsNil() {
        // 展示模型 HealthInsightDomain 是严格枚举，未知 rawValue 返回 nil（parser 层回退 .mixed）
        XCTAssertNil(HealthInsightDomain(rawValue: "unknown_xyz"))
        XCTAssertEqual(HealthInsightDomain(rawValue: "finance"), .finance)
        XCTAssertEqual(HealthInsightDomain(rawValue: "mixed"), .mixed)
    }

    // MARK: - LLM 原始响应宽容解析

    func testLLMResponseDecodesSparseJSON() throws {
        // LLM 可能漏掉 suggestedAction / caveat，必须宽容解析不崩
        let json = """
        {
          "coreInsight": {
            "id": "core-1",
            "domain": "mixed",
            "title": "恢复不足",
            "summary": "摘要",
            "confidence": 0.7,
            "evidenceIds": ["a", "b"]
          },
          "lifestyleLoops": []
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(HealthInsightLLMResponse.self, from: json)

        XCTAssertEqual(response.coreInsight?.id, "core-1")
        XCTAssertNil(response.coreInsight?.suggestedAction)
        XCTAssertEqual(response.lifestyleLoops, [])
    }

    func testLLMResponseDecodesUnknownDomainWithoutThrowing() throws {
        // LLM 传了未知 domain 字符串：domain 是 String? 容忍，不抛错
        let json = #"{"coreInsight":{"id":"c","domain":"unknown_xyz","title":"t","summary":"s"}}"#
            .data(using: .utf8)!

        let response = try JSONDecoder().decode(HealthInsightLLMResponse.self, from: json)

        XCTAssertEqual(response.coreInsight?.domain, "unknown_xyz")
    }

    func testLLMResponseToleratesMissingLifestyleLoops() throws {
        // LLM 只返回 coreInsight，缺 lifestyleLoops 整个字段
        let json = #"{"coreInsight":{"id":"c","title":"t","summary":"s"}}"#.data(using: .utf8)!

        let response = try JSONDecoder().decode(HealthInsightLLMResponse.self, from: json)

        XCTAssertNotNil(response.coreInsight)
        XCTAssertNil(response.lifestyleLoops)
    }
}
