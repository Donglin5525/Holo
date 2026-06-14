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

    // MARK: - 测试数据构造助手

    private func makeEvidence(id: String, redacted: String, excerpt: String) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: id, sourceModule: .habit, sourceID: nil, sourceKind: "kind",
            timeRange: nil, occurredAt: nil, metricKey: "k", metricValue: 1, unit: "次",
            baselineValue: nil, comparison: nil, excerpt: excerpt, redactedExcerpt: redacted,
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
