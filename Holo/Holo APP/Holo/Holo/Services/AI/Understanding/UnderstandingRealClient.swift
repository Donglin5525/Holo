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

    /// 解析提案输出：委托 ProposalEnvelopeParser（轻量独立类型，standalone 可测）。
    static func parseEnvelope(from raw: String) throws -> ProposalEnvelope {
        try ProposalEnvelopeParser.parse(from: raw)
    }
}

// MARK: - 真数据源装配（授权门 + 近90天，见 UnderstandingDataSource）

@MainActor
enum UnderstandingRealEntry {
    /// 影子理解入口装配：真数据 + 真模型通道 + 本机影子目录。
    /// M3.1（2026-11-15）：轮终态后接晋升——adoptable 且 explicitBackground 的候选
    /// 翻译进正式记忆（applyObservationBatch 正门，灰度 DEBUG 开/Release 关）。
    static func runShadowOnce(now: Date = Date()) async -> ShadowRunReport {
        let report = await UnderstandingShadowRunner.runOnce(
            now: now,
            maxTopics: 3,
            loadInputs: {
                async let finance = UnderstandingDataSource.financeInputs(now: now)
                async let thought = UnderstandingDataSource.thoughtInputs(now: now)
                async let habit = UnderstandingDataSource.habitInputs(now: now)
                return await (finance, thought, habit)
            },
            proposeClient: RealUnderstandingProposeClient()
        )
        guard UnderstandingPromotion.isEnabled else { return report }
        let storage = UnderstandingShadowRunner.storageDirectory()
        let ledger = ShadowLedger.load(directory: storage)
        let index = ObservationIndex.load(directory: storage)
        let themes = UnderstandingShadowRunner.loadThemeSnapshot(directory: storage)
        let promotion = await UnderstandingPromotion.promoteEligible(
            ledger: ledger,
            resolveEvidence: { candidate in
                guard let theme = themes.first(where: { $0.key == candidate.themeKey }) else { return [] }
                return theme.memberIDs.compactMap { index.observations[$0] }
            },
            now: now)
        var finalReport = report
        finalReport.promotionSummary = "晋升\(promotion.promoted)条/跳过\(promotion.skipped)条"
            + (promotion.failures.isEmpty ? "" : "｜失败: " + promotion.failures.joined(separator: "；"))
        return finalReport
    }
}
