//
//  HoloAgentResultRendererTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 4.4 Result Renderer 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Presentation/HoloAgentResultRenderer.swift> <本测试> \
//    -o /tmp/holo_result_renderer_test && /tmp/holo_result_renderer_test
//

import Foundation

@main
struct HoloAgentResultRendererTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        testClaim渲染成短文sections()
        test含证据引用摘要()
        test不含Markdown表格()
        test敏感Evidence用脱敏摘要()
        print("HoloAgentResultRendererTests passed")
    }

    private static func makeEvidence(id: String, redacted: String, excerpt: String) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: id, sourceModule: .habit, sourceID: nil, sourceKind: "kind",
            timeRange: nil, occurredAt: nil, metricKey: "k", metricValue: 1, unit: "次",
            baselineValue: nil, comparison: nil, excerpt: excerpt, redactedExcerpt: redacted,
            sensitivity: .sensitive, confidence: 1.0, status: .active,
            generatedBy: "test", generatedAt: Date(timeIntervalSince1970: 1000),
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
    }

    private static func makeClaim(text: String, evidenceIDs: [String]) -> HoloAgentClaim {
        HoloAgentClaim(
            id: "c1", type: "observation", displayText: text,
            metricAssertions: [HoloMetricAssertion(metricKey: "k", value: 1, baselineValue: nil,
                                                   unit: "次", comparison: nil, evidenceIDs: evidenceIDs)],
            evidenceIDs: evidenceIDs, prohibitedInferences: [], confidence: 0.9
        )
    }

    private static func testClaim渲染成短文sections() {
        let claim = makeClaim(text: "负向习惯发生量连续上升", evidenceIDs: ["e1"])
        let ev = makeEvidence(id: "e1", redacted: "刷手机次数上升", excerpt: "完整原文")
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])
        expect(result.sections.count == 1, "应有 1 个 section")
        expect(result.sections.first?.body.contains("负向习惯") ?? false, "section 应含 claim 内容")
    }

    private static func test含证据引用摘要() {
        let claim = makeClaim(text: "晚间餐饮增加", evidenceIDs: ["e1"])
        let ev = makeEvidence(id: "e1", redacted: "晚间餐饮 4 次", excerpt: "原文")
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])
        expect(result.evidenceReferences.contains { $0.summary.contains("晚间餐饮") }, "应含证据引用摘要")
    }

    private static func test不含Markdown表格() {
        let claim = makeClaim(text: "开销增加", evidenceIDs: ["e1"])
        let ev = makeEvidence(id: "e1", redacted: "脱敏", excerpt: "原文")
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])
        let flat = "\(result.title)\(result.summary)\(result.sections.map { $0.title + $0.body }.joined())\(result.evidenceReferences.map { $0.summary }.joined())"
        expect(!flat.contains("|-"), "不应含 Markdown 表格分隔符")
        expect(!flat.contains("```"), "不应含代码块")
    }

    private static func test敏感Evidence用脱敏摘要() {
        let claim = makeClaim(text: "观察", evidenceIDs: ["e1"])
        let ev = makeEvidence(id: "e1", redacted: "脱敏摘要", excerpt: "SECRET_FULL_TEXT")
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [ev])
        let flat = result.evidenceReferences.map { $0.summary }.joined()
        expect(flat.contains("脱敏摘要"), "证据引用应用 redactedExcerpt")
        expect(!flat.contains("SECRET_FULL_TEXT"), "不应暴露完整敏感原文")
    }
}
