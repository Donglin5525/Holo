//
//  HoloAgentObservabilityTests.swift
//  HoloTests
//
//  运行：swiftc -parse-as-library HoloAgentJobModels.swift HoloAgentExecutionModels.swift
//    HoloAgentExecutionLease.swift HoloAgentJSONStore.swift HoloAgentObservability.swift
//    HoloAgentObservabilityTests.swift -o /tmp/holo_agent_observability_test && /tmp/holo_agent_observability_test
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloAgentObservabilityTests.main()
    }
}
#endif
struct HoloAgentObservabilityTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await testStoreRetentionAndMetrics()
        testEventJSONDoesNotAcceptBusinessContent()
        print("HoloAgentObservabilityTests passed")
    }

    private static func testStoreRetentionAndMetrics() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-observability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HoloAgentEventStore(directory: directory, maxCount: 3, retentionDays: 14)
        let job = makeJob(id: "job-observe")

        await store.record(HoloAgentTelemetryEvent(name: .jobCreated, job: job))
        await store.record(HoloAgentTelemetryEvent(name: .resumeStarted, job: job))
        await store.record(HoloAgentTelemetryEvent(name: .executionExpired, job: job))
        await store.record(HoloAgentTelemetryEvent(name: .jobCompleted, job: job))

        let events = try await store.load()
        expect(events.count == 3, "环形仓库应只保留 maxCount 条")
        let metrics = try await store.metrics()
        expect(metrics.jobsCompleted == 1, "应统计完成 job")
        expect(metrics.resumesStarted == 1, "应统计恢复次数")
        expect(metrics.resumedJobsCompleted == 1, "应统计恢复后完成")
        expect(metrics.executionExpirations == 1, "应统计系统到期")
    }

    private static func testEventJSONDoesNotAcceptBusinessContent() {
        let event = HoloAgentTelemetryEvent(
            name: .checkpointCommitted,
            job: makeJob(id: "job-safe"),
            checkpointRevision: 3,
            requestID: "llm-2-3"
        )
        let data = try! JSONEncoder().encode(event)
        let json = String(decoding: data, as: UTF8.self)
        expect(!json.contains("用户问题"), "事件不得含用户问题字段")
        expect(!json.contains("conversation"), "事件不得含对话字段")
        expect(json.contains("llm-2-3"), "应保留非敏感 step identity")
    }

    private static func makeJob(id: String) -> HoloAgentJob {
        HoloAgentJob(
            id: id, type: .deepAnalysis, userQuestion: "用户问题不得进入事件",
            trigger: .userQuestion, state: .completed, currentStep: .persistResult,
            createdAt: Date(), updatedAt: Date(), lastForegroundRunAt: nil, timeRange: nil,
            budget: .normalDeep(), checkpointID: nil, resultID: nil,
            errorSummary: nil, deviceID: nil
        )
    }
}
