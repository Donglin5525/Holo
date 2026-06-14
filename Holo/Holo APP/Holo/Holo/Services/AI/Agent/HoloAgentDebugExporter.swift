//
//  HoloAgentDebugExporter.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 0.3 Debug 快照导出
//  汇聚 Agent 各仓库状态为 JSON 字符串，供「设置 → 调试」面板导出排查。
//

import Foundation

enum HoloAgentDebugExporter {

    /// 生成 Agent 子系统的调试快照 JSON。
    /// - Parameters:
    ///   - jobs/checkpoints/results/evidence: 各仓库当前内容。
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
        now: Date = Date()
    ) -> String {
        let snapshot: [String: Any] = [
            "generatedAt": Self.isoString(now),
            "featureFlags": featureFlags,
            "agentJobs": Self.encodeBox(jobs),
            "agentCheckpoints": Self.encodeBox(checkpoints),
            "agentResults": Self.encodeBox(results),
            "evidenceLedger": Self.encodeBox(evidence),
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
}
