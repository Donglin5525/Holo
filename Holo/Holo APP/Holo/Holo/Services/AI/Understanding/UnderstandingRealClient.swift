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
    nonisolated static let systemPrompt = """
    你是 Holo 生活理解引擎的「提案器」。输入是关于同一个人的一组观察材料（已脱敏、程序预整理；不含金额与精确数值）。

    任务：基于材料提出【最多 2 条】值得查证的候选理解。每条输出：
    {"claimType":"role|preference|recurringBehavior|phaseState|conditionalAssociation","statement":"一句话命题（中文）","supportingRefs":["观察的oid"],"alternativeExplanations":["1-2个竞争解释"],"verificationPlan":[{"op":"retrieveRelated|checkOwnership|comparePeriods|compareConditions|alignEvents|searchCounterEvidence|checkCoverage","question":"想查什么"}],"whatWouldChangeTheAnswer":"成立后改变哪类回答","evidenceGrade":"线索|支持","action":"adopt|observe|ask"}

    硬规则：
    1. 证据不足宁可 observe/ask，不给强命题；只有购买记录禁止说使用/饮用。
    2. attribution 为 unknown 不得默认本人；proxy 是明确代办。
    3. 命题层禁止出现「患者」措辞（疾病身份只能以用户自述证据转述）；禁止医疗诊断。
    4. 禁止人格/道德标签（懒/自律差/拖延症/孤僻/社恐/成瘾/上瘾/自制力差）；禁止身份默认（如产后）。
    5. 材料里没有的信息不许编造；统计数字只支撑统计结论；材料明确原因未知时不得自行填补原因。
    6. 时间窗表述（近3个月等）是范围不是月龄；婴儿月龄不得精确化。
    7. 提不出可执行查证计划的候选不要输出；没有值得提的输出空数组。
    8. 只输出 JSON：{"candidates":[...],"noValueReason":"空数组时一句原因"}
    """

    func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let evidenceJSON = String(data: try encoder.encode(evidence), encoding: .utf8) ?? "[]"
        let messages: [ChatMessageDTO] = [
            .system(Self.systemPrompt),
            .user("观察材料（主题：\(themeKey)）：\n\(evidenceJSON)"),
        ]
        let provider = await MainActor.run { HoloBackendAIProvider() }
        let raw = try await provider.chat(messages: messages, purpose: .understandingProposal)
        let envelope = try JSONDecoder().decode(ProposalEnvelope.self, from: Data(raw.utf8))
        return envelope.candidates
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
