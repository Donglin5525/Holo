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
    private let scheduler: HoloAgentScheduler

    init() {
        self.runtime = HoloLocalAgentRuntime.shared
        self.scheduler = HoloAgentScheduler.shared
    }

    init(runtime: HoloLocalAgentRuntime, scheduler: HoloAgentScheduler) {
        self.runtime = runtime
        self.scheduler = scheduler
    }

    /// 运行一次深度分析，返回渲染后的结果短文；失败或未完成返回 nil。
    /// 全程异步执行，ChatViewModel 负责展示状态与最终文本。
    func runAnalysis(question: String, sourceMessageID: UUID? = nil) async -> HoloRenderedAgentResult {
        logger.info("[Agent] 开始: \(question)")
        let fail = { (reason: String) -> HoloRenderedAgentResult in
            HoloRenderedAgentResult(title: "深度分析出错", summary: reason, sections: [], evidenceReferences: [])
        }
        let toolDescriptions = await runtime.toolDescriptions()
        let systemTemplate: String
        do {
            systemTemplate = try PromptManager.shared.loadPrompt(.agentLoop)
        } catch {
            return fail("[prompt加载失败] \(String(describing: error))")
        }
        logger.info("[Agent] 经 Scheduler 启动 runLoop…")
        let finalJob: HoloAgentJob
        do {
            finalJob = try await scheduler.start(
                question: question,
                systemTemplate: systemTemplate,
                toolDescriptions: toolDescriptions,
                sourceMessageID: sourceMessageID
            )
            logger.info("[Agent] runLoop 完成 state=\(finalJob.state.rawValue) rounds=\(finalJob.budget.consumedLLMRounds)")
        } catch {
            return fail("[runLoop异常] \(String(describing: error))")
        }
        guard finalJob.state == .completed else {
            let detail = "state=\(finalJob.state.rawValue) rounds=\(finalJob.budget.consumedLLMRounds)/\(finalJob.budget.maxLLMRounds) error=\(finalJob.errorSummary ?? "无")"
            return fail("[未完成] \(detail)")
        }
        guard let result = await runtime.loadLatestResult() else {
            return fail("[结果未保存] loadLatestResult nil")
        }
        logger.info("[Agent] result claims=\(result.claims.count)")
        let evidence = await runtime.loadEvidence(forIDs: result.evidenceIDs)
        return HoloAgentResultRenderer().render(
            claims: result.claims, evidence: evidence, title: result.title
        )
    }

    /// 回前台/冷启动恢复后，将已完成的 Agent job 回填到原来的 Chat streaming 消息。
    func finalizeRecoveredChatMessages(repository: ChatMessageRepository? = nil) async {
        let repository = repository ?? ChatMessageRepository.shared
        let jobs = await runtime.loadChatRecoverableTerminalJobs()
        for job in jobs {
            guard let sourceMessageID = job.sourceMessageID else { continue }
            let rendered: HoloRenderedAgentResult
            if job.state == .completed,
               let result = await runtime.loadResult(jobID: job.id) {
                let evidence = await runtime.loadEvidence(forIDs: result.evidenceIDs)
                rendered = HoloAgentResultRenderer().render(
                    claims: result.claims,
                    evidence: evidence,
                    title: result.title
                )
            } else {
                let detail = job.errorSummary ?? "Agent 在恢复后未能完成。"
                rendered = HoloRenderedAgentResult(
                    title: "深度分析出错",
                    summary: detail,
                    sections: [],
                    evidenceReferences: []
                )
            }
            repository.finalizeAgentMessage(sourceMessageID, rendered: rendered, intent: "query_analysis")
        }
    }
}
