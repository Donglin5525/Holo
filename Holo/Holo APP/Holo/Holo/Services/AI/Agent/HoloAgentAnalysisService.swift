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
    func runAnalysis(question: String) async -> HoloRenderedAgentResult {
        logger.info("[Agent] 开始: \(question)")
        let fail = { (reason: String) -> HoloRenderedAgentResult in
            HoloRenderedAgentResult(title: "深度分析出错", summary: reason, sections: [], evidenceReferences: [])
        }
        do {
            let job: HoloAgentJob
            do {
                job = try await runtime.startAnalysisJob(question: question)
                logger.info("[Agent] ① job 已创建")
            } catch {
                return fail("[step1: job创建失败] \(String(describing: error))")
            }
            let toolDescriptions = await runtime.toolDescriptions()
            logger.info("[Agent] ② 工具描述就绪")
            let systemTemplate: String
            do {
                systemTemplate = try await PromptManager.shared.loadPrompt(.agentLoop)
                logger.info("[Agent] ③ prompt 已加载")
            } catch {
                return fail("[step3: prompt加载失败] \(String(describing: error))")
            }
            logger.info("[Agent] ④ 开始 runLoop…")
            let finalJob: HoloAgentJob
            do {
                finalJob = try await runtime.runLoop(
                    jobID: job.id, systemTemplate: systemTemplate, toolDescriptions: toolDescriptions
                )
                logger.info("[Agent] ⑤ runLoop 完成 state=\(finalJob.state.rawValue) rounds=\(finalJob.budget.consumedLLMRounds)")
            } catch {
                return fail("[step5: runLoop异常] \(String(describing: error))")
            }
            guard finalJob.state == .completed else {
                let detail = "state=\(finalJob.state.rawValue) rounds=\(finalJob.budget.consumedLLMRounds)/\(finalJob.budget.maxLLMRounds) error=\(finalJob.errorSummary ?? "无")"
                return fail("[step5: 未完成] \(detail)")
            }
            guard let result = await runtime.loadLatestResult() else {
                return fail("[step6: 结果未保存] loadLatestResult nil")
            }
            logger.info("[Agent] ⑥ result 已加载 claims=\(result.claims.count)")
            let evidence = await runtime.loadEvidence(forIDs: result.evidenceIDs)
            logger.info("[Agent] ⑦ evidence 已加载 → 渲染完成")
            return HoloAgentResultRenderer().render(
                claims: result.claims, evidence: evidence, title: result.title
            )
        }
    }
}
