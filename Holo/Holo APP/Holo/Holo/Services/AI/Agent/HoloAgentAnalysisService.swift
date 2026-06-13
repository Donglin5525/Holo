//
//  HoloAgentAnalysisService.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 6.2 对话深度分析编排
//  封装「创建 job → 构建 agent_loop 提示 → 多轮 runLoop」为单一入口，
//  供 ChatViewModel 在命中深度分析分流时调用。使用 shared 生产 runtime。
//  agentRuntimeEnabled flag 已在 ConversationCoordinator 分流层把关。
//

import Foundation
import os.log

@MainActor
final class HoloAgentAnalysisService {

    private let logger = Logger(subsystem: "com.holo.app", category: "AgentAnalysis")
    private let runtime: HoloLocalAgentRuntime

    init(runtime: HoloLocalAgentRuntime = .shared) {
        self.runtime = runtime
    }

    /// 运行一次深度分析，返回渲染后的结果短文；失败或未完成返回 nil。
    /// 全程异步执行，ChatViewModel 负责展示状态与最终文本。
    func runAnalysis(question: String) async -> HoloRenderedAgentResult? {
        do {
            let job = try await runtime.startAnalysisJob(question: question)
            let toolDescriptions = await runtime.toolDescriptions()
            let systemTemplate = try await PromptManager.shared.loadPrompt(.agentLoop)
            let finalJob = try await runtime.runLoop(
                jobID: job.id,
                systemTemplate: systemTemplate,
                toolDescriptions: toolDescriptions
            )
            guard finalJob.state == .completed else { return nil }
            guard let result = await runtime.loadLatestResult() else { return nil }
            let evidence = await runtime.loadEvidence(forIDs: result.evidenceIDs)
            return HoloAgentResultRenderer().render(
                claims: result.claims, evidence: evidence, title: result.title
            )
        } catch {
            logger.error("Agent 深度分析失败: \(error.localizedDescription)")
            return nil
        }
    }
}
