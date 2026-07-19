//
//  HoloAgentDebugExporter.swift
//  Holo
//
//  HoloAI Agent — Phase 7 Debug 快照导出
//  只导出技术元数据，禁止包含用户问题、对话、工具结果、结论与证据原文。
//

import Foundation

enum HoloAgentDebugExporter {

    /// 生成 Agent 子系统的调试快照 JSON。
    /// - Parameters:
    ///   - jobs/checkpoints/results/evidence: 各仓库当前内容；导出时会收敛为脱敏技术摘要。
    ///   - longTermMemoryCount/episodicMemoryCount/suppressionRuleCount: 记忆与抑制规则计数
    ///     （Phase 1 由调用方注入，真实来源在 Phase 2 记忆系统接入后填充）。
    ///   - featureFlags: 当前 Agent feature flag 开关（调用方从 `HoloAIFeatureFlags` 注入）。
    ///   - now: 快照时间，便于测试注入。
    /// - Returns: JSON 字符串；序列化失败回退 `{}`。
    static func makeSnapshot(
        jobs: [HoloAgentJob],
        checkpoints: [HoloAgentCheckpoint],
        results: [HoloAgentResult],
        evidence: [HoloEvidenceRecord],
        longTermMemoryCount: Int = 0,
        episodicMemoryCount: Int = 0,
        suppressionRuleCount: Int = 0,
        featureFlags: [String: Bool] = [:],
        activeLeases: [String: HoloAgentExecutionLeaseKind] = [:],
        events: [HoloAgentTelemetryEvent] = [],
        now: Date = Date()
    ) -> String {
        let metrics = HoloAgentReliabilityMetrics.make(from: events)
        let snapshot: [String: Any] = [
            "schemaVersion": 2,
            "generatedAt": Self.isoString(now),
            "privacyMode": "technical_metadata_only",
            "featureFlags": featureFlags,
            "agentJobs": jobs.map(Self.sanitizedJob),
            "agentCheckpoints": checkpoints.map(Self.sanitizedCheckpoint),
            "agentResults": results.map(Self.sanitizedResult),
            "evidenceLedger": Self.evidenceSummary(evidence),
            "activeLeases": activeLeases.mapValues(\.rawValue),
            "structuredEvents": Self.encodeBox(events),
            "reliabilityMetrics": Self.encodeBox(metrics),
            "longTermMemoryCount": longTermMemoryCount,
            "episodicMemoryCount": episodicMemoryCount,
            "suppressionRuleCount": suppressionRuleCount
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: snapshot,
            options: [.sortedKeys, .prettyPrinted]
        ),
            let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Date → iso8601 字符串（JSONSerialization 不直接处理 Date，需手动转）。
    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Encodable 数组 → JSON 可序列化对象（经 encode → jsonObject 二次转换，保证嵌套结构合法）。
    private static func encodeBox<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        return json
    }

    private static func sanitizedJob(_ job: HoloAgentJob) -> [String: Any] {
        var value: [String: Any] = [
            "jobID": job.id,
            "jobType": job.type.rawValue,
            "trigger": job.trigger.rawValue,
            "state": job.state.rawValue,
            "currentStep": job.currentStep.rawValue,
            "generation": job.executionGeneration ?? 0,
            "consumedLLMRounds": job.budget.consumedLLMRounds,
            "consumedToolBatches": job.budget.consumedToolBatches,
            "createdAt": isoString(job.createdAt),
            "updatedAt": isoString(job.updatedAt)
        ]
        value["checkpointID"] = job.checkpointID
        value["resultID"] = job.resultID
        value["waitReason"] = job.waitReason?.rawValue
        value["lastResumeReason"] = job.lastResumeReason?.rawValue
        value["errorCode"] = sanitizedErrorCode(job.errorSummary)
        return value
    }

    private static func sanitizedCheckpoint(_ checkpoint: HoloAgentCheckpoint) -> [String: Any] {
        var value: [String: Any] = [
            "checkpointID": checkpoint.id,
            "jobID": checkpoint.jobID,
            "step": checkpoint.step.rawValue,
            "completedStepCount": checkpoint.completedSteps.count,
            "toolResultCount": checkpoint.completedToolResults.count,
            "evidenceRecordCount": checkpoint.evidenceRecordIDs.count,
            "checkpointRevision": checkpoint.revision ?? 0,
            "executionGeneration": checkpoint.executionGeneration ?? 0,
            "updatedAt": isoString(checkpoint.updatedAt)
        ]
        if let request = checkpoint.pendingLLMRequest {
            value["pendingRequest"] = [
                "stepID": request.stepID,
                "status": request.status.rawValue,
                "hasResponseHash": request.responseHash != nil
            ]
        }
        return value
    }

    private static func sanitizedResult(_ result: HoloAgentResult) -> [String: Any] {
        [
            "resultID": result.id,
            "jobID": result.jobID,
            "status": result.status,
            "claimCount": result.claims.count,
            "evidenceCount": result.evidenceIDs.count,
            "memoryCandidateCount": result.memoryCandidateIDs.count,
            "generatedAt": isoString(result.generatedAt),
            "updatedAt": isoString(result.updatedAt)
        ]
    }

    private static func evidenceSummary(_ evidence: [HoloEvidenceRecord]) -> [String: Any] {
        func counts<T: Hashable>(_ values: [T], key: (T) -> String) -> [String: Int] {
            Dictionary(grouping: values, by: key).mapValues(\.count)
        }
        return [
            "count": evidence.count,
            "bySourceModule": counts(evidence.map(\.sourceModule), key: { $0.rawValue }),
            "bySensitivity": counts(evidence.map(\.sensitivity), key: { $0.rawValue }),
            "byStatus": counts(evidence.map(\.status), key: { $0.rawValue })
        ]
    }

    /// 失败详情可能带模型原文或用户数据，导出只保留有限错误类别。
    private static func sanitizedErrorCode(_ summary: String?) -> String? {
        guard let summary else { return nil }
        if summary.contains("STEP_ID_CONFLICT") { return "STEP_ID_CONFLICT" }
        if summary.contains("解析失败") { return "INVALID_AGENT_RESPONSE" }
        if summary.contains("截止") { return "ABSOLUTE_DEADLINE_EXCEEDED" }
        if summary.contains("预算耗尽") { return "AGENT_BUDGET_EXHAUSTED" }
        if summary.contains("系统结束") { return "SYSTEM_CAPACITY" }
        if summary.contains("恢复执行失败") { return "RESUME_FAILED" }
        return "AGENT_JOB_ERROR"
    }
}
