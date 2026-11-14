//
//  UnderstandingRealClient.swift
//  Holo
//
//  影子引擎真入口件：真提案客户端（understanding_proposal 通道）+ 真数据源装配。
//  与 Runner 分文件：Runner 保持零 App 依赖（standalone 可测），真件由实验室入口装配。
//

import Foundation

// MARK: - 真提案客户端（qwen3.7-flash via understanding_proposal）
// 不标 @MainActor：协议见证会抹掉方法隔离（async-closure-injection-segv 同族坑），
// provider 的 MainActor 调用在方法体内用 MainActor.run 显式跳岛。

struct RealUnderstandingProposeClient: UnderstandingProposeClient {
    func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let evidenceJSON = String(data: try encoder.encode(evidence), encoding: .utf8) ?? "[]"
        // prompt 真源在服务端（serverPromptPolicy 注入 understanding_proposal 模板），
        // 客户端只发材料——2026-11-14 修复：客户端自带 system 与服务端注入并存时
        // 出现双 system，且通道注册初期漏服务端映射导致 PROMPT_NOT_FOUND。
        let messages: [ChatMessageDTO] = [
            .user("观察材料（主题：\(themeKey)）：\n\(evidenceJSON)"),
        ]
        let provider = await MainActor.run { HoloBackendAIProvider() }
        let raw = try await provider.chat(messages: messages, purpose: .understandingProposal)
        return try Self.parseEnvelope(from: raw).candidates
    }

    /// 解析提案输出：容忍 ```json 围栏与前后噪声（对齐生产口径
    /// HoloPersonalContextValidator.extractJSON——生产网关返回可能带前缀/围栏）。
    static func parseEnvelope(from raw: String) throws -> ProposalEnvelope {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "^```[a-zA-Z]*\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "```\\s*$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 首个 { 到最后一个 } 的包围（提案对象无尾随内容场景的最简平衡提取）。
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            text = String(text[first...last])
        }
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ProposalEnvelope.self, from: data) else {
            throw APIError.serverError("提案输出无法解析为 JSON（前 80 字：\(text.prefix(80))）")
        }
        return envelope
    }
}

nonisolated struct ProposalEnvelope: Codable, Equatable, Sendable {
    var candidates: [ProposalCandidate] = []
    var noValueReason: String?
}

// MARK: - 真数据源装配（授权门 + 近90天，见 UnderstandingDataSource）

@MainActor
enum UnderstandingRealEntry {
    /// 实验室「跑一轮影子理解」入口装配：真数据 + 真模型通道 + 本机影子目录。
    static func runShadowOnce(now: Date = Date()) async -> ShadowRunReport {
        await UnderstandingShadowRunner.runOnce(
            now: now,
            maxTopics: 3,
            loadInputs: {
                let finance = await UnderstandingDataSource.financeInputs(now: now)
                let thought = await UnderstandingDataSource.thoughtInputs(now: now)
                return (finance, thought)
            },
            proposeClient: RealUnderstandingProposeClient()
        )
    }
}
