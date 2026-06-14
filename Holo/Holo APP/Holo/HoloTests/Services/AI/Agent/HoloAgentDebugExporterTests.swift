//
//  HoloAgentDebugExporterTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 0.3 Debug Export 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <HoloAgentDebugExporter.swift> <本测试> \
//    -o /tmp/holo_agent_export_test && /tmp/holo_agent_export_test
//

import Foundation

@main
struct HoloAgentDebugExporterTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        testDebugExport_空数据包含全部章节()
        testDebugExport_含实际数据被序列化()
        print("HoloAgentDebugExporterTests passed")
    }

    private static func makeJob(id: String) -> HoloAgentJob {
        HoloAgentJob(
            id: id, type: .deepAnalysis, userQuestion: "测试",
            trigger: .userQuestion, state: .completed, currentStep: .persistResult,
            createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 2000),
            lastForegroundRunAt: nil, timeRange: nil,
            budget: HoloAgentBudget.normalDeep(now: Date(timeIntervalSince1970: 1000)),
            checkpointID: nil, resultID: nil, errorSummary: nil, deviceID: nil
        )
    }

    private static func testDebugExport_空数据包含全部章节() {
        let export = HoloAgentDebugExporter.makeSnapshot(
            jobs: [], checkpoints: [], results: [], evidence: []
        )
        for key in ["generatedAt", "featureFlags", "agentJobs", "agentCheckpoints",
                    "agentResults", "evidenceLedger", "longTermMemoryCount",
                    "episodicMemoryCount", "suppressionRuleCount"] {
            expect(export.contains(key), "导出 JSON 应包含字段 \(key)")
        }
    }

    private static func testDebugExport_含实际数据被序列化() {
        let export = HoloAgentDebugExporter.makeSnapshot(
            jobs: [makeJob(id: "job-debug")],
            checkpoints: [],
            results: [],
            evidence: [],
            longTermMemoryCount: 5,
            featureFlags: ["agentRuntimeEnabled": true]
        )
        expect(export.contains("job-debug"), "应序列化 job id")
        expect(export.contains("agentRuntimeEnabled"), "应序列化 featureFlags")
    }
}
