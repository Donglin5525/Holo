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
        testDebugExport_含实际数据只导出技术元数据()
        print("HoloAgentDebugExporterTests passed")
    }

    private static func makeJob(id: String) -> HoloAgentJob {
        HoloAgentJob(
            id: id, type: .deepAnalysis, userQuestion: "敏感问题原文-不可导出",
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
                    "agentResults", "evidenceLedger", "activeLeases", "structuredEvents",
                    "reliabilityMetrics", "privacyMode", "longTermMemoryCount",
                    "episodicMemoryCount", "suppressionRuleCount"] {
            expect(export.contains(key), "导出 JSON 应包含字段 \(key)")
        }
    }

    private static func testDebugExport_含实际数据只导出技术元数据() {
        var job = makeJob(id: "job-debug")
        job.executionGeneration = 4
        job.waitReason = .network
        job.lastResumeReason = .foregroundReturn
        let export = HoloAgentDebugExporter.makeSnapshot(
            jobs: [job],
            checkpoints: [],
            results: [],
            evidence: [],
            longTermMemoryCount: 5,
            featureFlags: ["agentRuntimeEnabled": true],
            activeLeases: ["job-debug": .continuedProcessing],
            events: [HoloAgentTelemetryEvent(name: .resumeStarted, job: job)]
        )
        expect(export.contains("job-debug"), "应序列化 job id")
        expect(export.contains("agentRuntimeEnabled"), "应序列化 featureFlags")
        expect(export.contains("continuedProcessing"), "应序列化 lease")
        expect(export.contains("foregroundReturn"), "应序列化恢复原因")
        expect(export.contains("agent_resume_started"), "应序列化结构化事件")
        expect(!export.contains("敏感问题原文-不可导出"), "不得导出用户问题")
        expect(!export.contains("conversationState"), "不得导出对话内容")
    }
}
