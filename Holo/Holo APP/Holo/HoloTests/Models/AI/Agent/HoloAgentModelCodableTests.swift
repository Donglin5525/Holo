//
//  HoloAgentModelCodableTests.swift
//  HoloTests
//
//  Agent V3.1 基础模型 Codable round-trip 验证
//  运行：swiftcd <Models/AI/Agent/*.swift> <本测试> -o /tmp/holo_agent_models_test && /tmp/holo_agent_models_test
//

import Foundation

@main
struct HoloAgentModelCodableTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        testHoloAgentJob_CodableRoundTrip()
        testHoloAgentCheckpoint_CodableRoundTrip()
        testHoloDataToolResult_Empty_CodableRoundTrip()
        testHoloEvidenceRecord_CodableRoundTrip()
        testHoloAgentOutput_NeedTools_CodableRoundTrip()
        testHoloPatternSignal_CodableRoundTrip()
        testHoloAgentBudget_NormalDeep_可用()
        print("HoloAgentModelCodableTests passed")
    }

    // MARK: - Helper

    /// iso8601 round-trip（与 Store 使用的编解码策略一致）
    private static func roundTrip<T: Codable & Equatable>(_ value: T) -> T? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    // MARK: - Round-trip

    private static func testHoloAgentJob_CodableRoundTrip() {
        let job = HoloAgentJob(
            id: "job-1",
            type: .deepAnalysis,
            userQuestion: "我最近状态如何？",
            trigger: .userQuestion,
            state: .running,
            currentStep: .executeTools,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            lastForegroundRunAt: nil,
            timeRange: HoloAgentTimeRange(label: "近7天", start: Date(timeIntervalSince1970: 500), end: Date(timeIntervalSince1970: 1000)),
            budget: HoloAgentBudget.normalDeep(now: Date(timeIntervalSince1970: 1000)),
            checkpointID: "cp-1",
            resultID: nil,
            errorSummary: nil,
            deviceID: nil
        )
        guard let decoded = roundTrip(job) else {
            expect(false, "HoloAgentJob 编解码失败")
            return
        }
        expect(decoded == job, "HoloAgentJob round-trip 不一致")
    }

    private static func testHoloAgentCheckpoint_CodableRoundTrip() {
        let checkpoint = HoloAgentCheckpoint(
            id: "cp-1",
            jobID: "job-1",
            step: .executeTools,
            completedSteps: [.plan],
            conversationState: [
                HoloAgentMessage(
                    role: .user,
                    content: "我最近是不是状态不太对？",
                    toolRequestID: nil,
                    toolName: nil,
                    timestamp: Date(timeIntervalSince1970: 1000),
                    tokenEstimate: 20
                )
            ],
            pendingToolRequests: [],
            completedToolResults: [],
            patternSignals: [],
            evidenceRecordIDs: ["ev-1"],
            validatedClaimIDs: [],
            memoryCandidateIDs: [],
            retryCountByStep: ["executeTools": 1],
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
        guard let decoded = roundTrip(checkpoint) else {
            expect(false, "HoloAgentCheckpoint 编解码失败")
            return
        }
        expect(decoded == checkpoint, "HoloAgentCheckpoint round-trip 不一致")
    }

    private static func testHoloDataToolResult_Empty_CodableRoundTrip() {
        let result = HoloDataToolResult(
            toolRequestID: "tr-1",
            tool: "memory",
            status: .empty,
            coverage: nil,
            metrics: [],
            events: [],
            warnings: [],
            error: nil
        )
        guard let decoded = roundTrip(result) else {
            expect(false, "HoloDataToolResult 编解码失败")
            return
        }
        expect(decoded == result, "HoloDataToolResult round-trip 不一致")
    }

    private static func testHoloEvidenceRecord_CodableRoundTrip() {
        let record = HoloEvidenceRecord(
            id: "ev-1",
            dedupeKey: "habit:negative:2026-06",
            sourceModule: .habit,
            sourceID: "habit-1",
            sourceKind: "habitCheckIn",
            timeRange: nil,
            occurredAt: Date(timeIntervalSince1970: 1000),
            metricKey: "habit.negative.count",
            metricValue: 12,
            unit: "次",
            baselineValue: 8,
            comparison: "increasing",
            excerpt: "6月3日发生 20 次",
            redactedExcerpt: "6月3日发生多次",
            sensitivity: .normal,
            confidence: 0.9,
            status: .active,
            generatedBy: "HoloHabitTool",
            generatedAt: Date(timeIntervalSince1970: 2000),
            referencedByJobIDs: ["job-1"],
            referencedByMemoryIDs: [],
            deviceID: nil
        )
        guard let decoded = roundTrip(record) else {
            expect(false, "HoloEvidenceRecord 编解码失败")
            return
        }
        expect(decoded == record, "HoloEvidenceRecord round-trip 不一致")
    }

    private static func testHoloAgentOutput_NeedTools_CodableRoundTrip() {
        let output = HoloAgentOutput(
            status: .needTools,
            reasoning: "需要查习惯趋势",
            toolRequests: [
                HoloToolRequest(
                    id: "tr-1",
                    tool: "habit",
                    query: "negative_habit_control",
                    timeRange: nil,
                    baseline: nil,
                    requiredMetrics: ["habit.negative.frequency_change"],
                    parameters: [:]
                )
            ],
            claims: [],
            nextStep: "executeTools",
            warnings: []
        )
        guard let decoded = roundTrip(output) else {
            expect(false, "HoloAgentOutput 编解码失败")
            return
        }
        expect(decoded == output, "HoloAgentOutput round-trip 不一致")
    }

    private static func testHoloPatternSignal_CodableRoundTrip() {
        let signal = HoloPatternSignal(
            id: "pat-1",
            type: .frequencyChange,
            title: "负向习惯发生量上升",
            metricKey: "habit.negative.frequency_change",
            value: 20,
            baselineValue: 8,
            severity: .high,
            evidenceIDs: ["ev-1", "ev-2", "ev-3"],
            reason: "连续3天 8→12→20",
            generatedAt: Date(timeIntervalSince1970: 3000)
        )
        guard let decoded = roundTrip(signal) else {
            expect(false, "HoloPatternSignal 编解码失败")
            return
        }
        expect(decoded == signal, "HoloPatternSignal round-trip 不一致")
    }

    private static func testHoloAgentBudget_NormalDeep_可用() {
        let budget = HoloAgentBudget.normalDeep()
        expect(budget.maxLLMRounds == 3, "normalDeep maxLLMRounds 应为 3")
        expect(budget.maxToolBatches == 3, "normalDeep maxToolBatches 应为 3")
        expect(!budget.isExhausted, "全新 budget 不应耗尽")
    }
}
