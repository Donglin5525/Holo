//
//  HoloAgentContractPolicyTests.swift
//  HoloTests
//
//  Agent 成熟度演进 P0-D — Contract Policy + Version Metadata 测试
//

import Foundation

@main
struct HoloAgentContractPolicyTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test正常output_无违规()
        test空finalClaims_拒绝()
        testclaim无evidence_拒绝()
        testconfidence越界_拒绝()
        test空displayText_拒绝()
        testDebug模式_任何违规都失败()
        test生产模式_关键违规才失败()
        test指标输出_非敏感()
        testVersionMetadata_三类版本()
        testVersionMetadata_当前基线()
        print("HoloAgentContractPolicyTests passed")
    }

    // MARK: - Helpers

    private static func makeOutput(
        status: HoloAgentOutputStatus = .finalClaims,
        claims: [HoloAgentClaim] = []
    ) -> HoloAgentOutput {
        HoloAgentOutput(
            status: status,
            reasoning: "test",
            toolRequests: [],
            claims: claims,
            nextStep: nil,
            warnings: []
        )
    }

    private static func makeClaim(
        id: String = "c1", type: String = "observation", text: String = "测试结论",
        evidenceIDs: [String] = ["ev1"], confidence: Double = 0.8
    ) -> HoloAgentClaim {
        HoloAgentClaim(
            id: id, type: type, displayText: text,
            metricAssertions: [HoloMetricAssertion(metricKey: "finance.total", value: 3000, unit: "元", comparison: nil, evidenceIDs: evidenceIDs)],
            evidenceIDs: evidenceIDs, prohibitedInferences: [],
            confidence: confidence
        )
    }

    // MARK: - Contract Policy

    private static func test正常output_无违规() {
        let output = makeOutput(claims: [makeClaim()])
        let result = HoloAgentContractPolicy.validate(output: output, mode: .debug)
        expect(!result.isRejected, "正常 output 不应被拒绝")
        expect(result.violations.isEmpty, "正常 output 不应有违规")
    }

    private static func test空finalClaims_拒绝() {
        let output = makeOutput(claims: [])
        let result = HoloAgentContractPolicy.validate(output: output, mode: .production)
        expect(result.isRejected, "空 final_claims 应被拒绝")
        expect(result.violations.contains(where: { $0.severity == .emptyResult }), "应记录 emptyResult 违规")
    }

    private static func testclaim无evidence_拒绝() {
        let claim = makeClaim(evidenceIDs: [])
        let output = makeOutput(claims: [claim])
        let result = HoloAgentContractPolicy.validate(output: output, mode: .production)
        expect(result.isRejected, "事实 claim 无 evidence 应被拒绝")
    }

    private static func testconfidence越界_拒绝() {
        let claim = makeClaim(confidence: 1.5)
        let output = makeOutput(claims: [claim])
        let result = HoloAgentContractPolicy.validate(output: output, mode: .production)
        expect(result.isRejected, "confidence 越界应被拒绝")
        expect(result.violations.contains(where: { $0.severity == .invalidValue }), "应记录 invalidValue")
    }

    private static func test空displayText_拒绝() {
        let claim = makeClaim(text: "  ")
        let output = makeOutput(claims: [claim])
        let result = HoloAgentContractPolicy.validate(output: output, mode: .production)
        expect(result.isRejected, "空 displayText 应被拒绝")
    }

    private static func testDebug模式_任何违规都失败() {
        // 即使是兼容字段缺失，Debug 也应失败
        let claim = makeClaim(confidence: 1.5)
        let output = makeOutput(claims: [claim])
        let debugResult = HoloAgentContractPolicy.validate(output: output, mode: .debug)
        let prodResult = HoloAgentContractPolicy.validate(output: output, mode: .production)
        expect(debugResult.isRejected, "Debug 模式应拒绝")
        expect(prodResult.isRejected, "Production 模式也应拒绝（关键违规）")
    }

    private static func test生产模式_关键违规才失败() {
        // 生产模式对兼容字段宽容（这里测试 missingRequired 才拒绝）
        let output = makeOutput(claims: [makeClaim()])
        let result = HoloAgentContractPolicy.validate(output: output, mode: .production)
        expect(!result.isRejected, "生产模式正常 output 不应拒绝")
    }

    private static func test指标输出_非敏感() {
        let output = makeOutput(claims: []) // 空 claims
        let result = HoloAgentContractPolicy.validate(output: output, mode: .production)
        let metrics = HoloAgentContractPolicy.metrics(from: result)
        expect(metrics["agent_contract_violation_count"] != nil, "应输出违规计数")
        expect(metrics["agent_contract_rejected"] != nil, "应输出拒绝状态")
        // 确保不含原始值
        let metricsString = "\(metrics)"
        expect(!metricsString.contains("测试结论"), "指标不应包含 claim 文本")
        expect(!metricsString.contains("3000"), "指标不应包含具体数值")
    }

    // MARK: - Version Metadata

    private static func testVersionMetadata_三类版本() {
        let meta = HoloAgentVersionMetadata.current
        expect(meta.promptRevision > 0, "promptRevision 应 > 0")
        expect(meta.agentProtocolVersion > 0, "agentProtocolVersion 应 > 0")
        expect(meta.toolSchemaVersion > 0, "toolSchemaVersion 应 > 0")
    }

    private static func testVersionMetadata_当前基线() {
        let meta = HoloAgentVersionMetadata.current
        expect(meta.promptRevision == 10, "当前 promptRevision 应为 10（agent_loop v10）")
        expect(meta.agentProtocolVersion == 10, "当前 agentProtocolVersion 应为 10")
        expect(meta.toolSchemaVersion == 1, "当前 toolSchemaVersion 应为 1")
    }
}
