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

struct HoloAgentChatStatus: Equatable {
    let title: String
    let detail: String
    let keepsMessageStreaming: Bool
    let showsActivityIndicator: Bool

    var messageContent: String {
        [title, detail]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum HoloAgentChatStatusPresenter {
    static func status(for job: HoloAgentJob) -> HoloAgentChatStatus {
        switch job.state {
        case .queued, .running:
            return active("Holo 正在深度分析中…", step: job.currentStep)
        case .waitingForLLM:
            return active("Holo 正在深度分析中…", detail: "正在调用模型继续推理。")
        case .retrying:
            return active("Holo 正在重试分析…", detail: "刚才的模型输出不完整，正在自动重试。")
        case .waitingForForeground:
            return HoloAgentChatStatus(
                title: "已暂停，回到 App 后继续",
                detail: "系统已经收回后台执行时间，Holo 会在回到前台后继续处理。",
                keepsMessageStreaming: true,
                showsActivityIndicator: false
            )
        case .paused:
            // §9.5：系统结束持续执行（systemCapacity）不自动复活，提示手动继续；
            // 其他 paused（用户/产品明确暂停）同样不自动恢复
            if job.waitReason == .systemCapacity {
                return HoloAgentChatStatus(
                    title: "系统已暂停这次分析",
                    detail: "回到 App 后可以手动继续这次深度分析。",
                    keepsMessageStreaming: false,
                    showsActivityIndicator: false
                )
            }
            return HoloAgentChatStatus(
                title: "已暂停，回到 App 后继续",
                detail: "系统已经收回后台执行时间，Holo 会在回到前台后继续处理。",
                keepsMessageStreaming: true,
                showsActivityIndicator: false
            )
        case .waitingForCondition:
            // §7.2：等待原因是可恢复条件（设备锁定/网络），不是失败，不中断消息
            return waitingForConditionStatus(for: job)
        case .completed:
            return HoloAgentChatStatus(
                title: "深度分析已完成",
                detail: "正在整理结果。",
                keepsMessageStreaming: false,
                showsActivityIndicator: false
            )
        case .failed:
            return HoloAgentChatStatus(
                title: "深度分析已中断",
                detail: job.errorSummary ?? "Agent 没能完成这次分析，请稍后重试。",
                keepsMessageStreaming: false,
                showsActivityIndicator: false
            )
        case .cancelled:
            return HoloAgentChatStatus(
                title: "深度分析已取消",
                detail: "这次 Agent 分析已经停止。",
                keepsMessageStreaming: false,
                showsActivityIndicator: false
            )
        case .superseded:
            return HoloAgentChatStatus(
                title: "已被新的分析取代",
                detail: "这次分析已被更新的问题取代，请查看最新的分析结果。",
                keepsMessageStreaming: false,
                showsActivityIndicator: false
            )
        }
    }

    /// waitingForCondition 按 waitReason 给出可解释文案（§7.2：不显示失败）。
    private static func waitingForConditionStatus(for job: HoloAgentJob) -> HoloAgentChatStatus {
        let title: String
        let detail: String
        switch job.waitReason {
        case .deviceUnlock, .protectedData:
            title = "等待设备解锁"
            detail = "设备锁定，解锁后继续读取健康数据。"
        case .network:
            title = "等待网络恢复"
            detail = "网络连接恢复后，Holo 会继续这次分析。"
        default:
            title = "等待条件满足"
            detail = "条件满足后，Holo 会继续处理这次分析。"
        }
        return HoloAgentChatStatus(
            title: title,
            detail: detail,
            keepsMessageStreaming: true,
            showsActivityIndicator: false
        )
    }

    static func display(from messageContent: String) -> HoloAgentChatStatus {
        let lines = messageContent
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let title = lines.first?.isEmpty == false ? lines[0] : "Holo 正在深度分析中…"
        let detail = lines.dropFirst().joined(separator: "\n")
        let pausedOrTerminal = title.hasPrefix("已暂停") ||
            title.hasPrefix("深度分析已中断") ||
            title.hasPrefix("深度分析已取消") ||
            title.hasPrefix("已被新的分析取代") ||
            title.hasPrefix("系统已暂停这次分析") ||
            title.hasPrefix("等待设备解锁") ||
            title.hasPrefix("等待网络恢复") ||
            title.hasPrefix("等待条件满足")
        return HoloAgentChatStatus(
            title: title,
            detail: detail.isEmpty ? "正在处理你的本地数据。" : detail,
            keepsMessageStreaming: !pausedOrTerminal,
            showsActivityIndicator: !pausedOrTerminal
        )
    }

    private static func active(_ title: String,
                               step: HoloAgentStep? = nil,
                               detail: String? = nil) -> HoloAgentChatStatus {
        HoloAgentChatStatus(
            title: title,
            detail: detail ?? detailText(for: step),
            keepsMessageStreaming: true,
            showsActivityIndicator: true
        )
    }

    private static func detailText(for step: HoloAgentStep?) -> String {
        switch step {
        case .plan:
            return "正在理解问题并规划需要查看的数据。"
        case .executeTools:
            return "正在读取本地数据并核对证据。"
        case .minePatterns:
            return "正在从数据里整理模式和变化。"
        case .integrateResults:
            return "正在整合分析结果。"
        case .verifyClaims:
            return "正在校验结论和依据。"
        case .critique:
            return "正在复核分析质量。"
        case .curateMemory:
            return "正在整理可沉淀的记忆线索。"
        case .render:
            return "正在生成可阅读的分析结果。"
        case .persistResult:
            return "正在保存分析结果。"
        case .continueOrConclude:
            return "正在判断是否还需要继续分析。"
        case nil:
            return "正在处理你的本地数据。"
        }
    }
}

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
    func runAnalysis(question: String, trigger: HoloAgentTrigger = .userQuestion,
                     sourceMessageID: UUID? = nil) async -> HoloRenderedAgentResult {
        // 只记录长度，不把用户问题原文写入系统日志（Phase 7 隐私契约）。
        logger.info("[Agent] 开始 questionLength=\(question.count, privacy: .public)")
        let fail = { (reason: String) -> HoloRenderedAgentResult in
            HoloRenderedAgentResult(title: "深度分析出错", summary: reason, sections: [], evidenceReferences: [])
        }
        let toolDescriptions = await runtime.toolDescriptions()
        let systemTemplate = ""
        logger.info("[Agent] 经 Scheduler 启动 runLoop…")
        let finalJob: HoloAgentJob
        do {
            // §6.1：入口统一走 Scheduler 唯一执行权（createAndRun）
            finalJob = try await scheduler.createAndRun(HoloAgentStartRequest(
                question: question,
                trigger: trigger,
                systemTemplate: systemTemplate,
                toolDescriptions: toolDescriptions,
                sourceMessageID: sourceMessageID
            ))
            logger.info("[Agent] runLoop 完成 state=\(finalJob.state.rawValue) rounds=\(finalJob.budget.consumedLLMRounds)")
        } catch {
            return fail("[runLoop异常] \(String(describing: error))")
        }
        guard finalJob.state == .completed else {
            let detail = "state=\(finalJob.state.rawValue) rounds=\(finalJob.budget.consumedLLMRounds)/\(finalJob.budget.maxLLMRounds) error=\(finalJob.errorSummary ?? "无")"
            return fail("[未完成] \(detail)")
        }
        let result: HoloAgentResult
        do {
            guard let loaded = try await runtime.loadResult(jobID: finalJob.id) else {
                return fail("[结果未保存] loadResult nil job=\(finalJob.id)")
            }
            result = loaded
        } catch {
            return fail("[结果读取失败] \(String(describing: error))")
        }
        if !result.memoryCandidateIDs.isEmpty {
            HoloMemoryReceiptStore.record(
                kind: .use,
                channel: .agent,
                memoryIDs: result.memoryCandidateIDs,
                message: "这次深度分析参考了 \(result.memoryCandidateIDs.count) 条长期记忆"
            )
        }
        logger.info("[Agent] result claims=\(result.claims.count)")
        do {
            let evidence = try await runtime.loadEvidence(forIDs: result.evidenceIDs)
            return HoloAgentResultRenderer().render(
                claims: result.claims,
                evidence: evidence,
                title: result.title,
                question: question,
                coverage: result.coverage
            )
        } catch {
            return fail("[证据读取失败] \(String(describing: error))")
        }
    }

    /// 回前台/冷启动/重新进入 Chat 后，用 Agent job 的真实状态校准 Chat streaming 消息。
    /// §5.5：store 读失败记录日志并中止本次同步，不当空库继续改写消息状态。
    @discardableResult
    func syncRecoverableChatMessages(repository: ChatMessageRepository? = nil) async -> Set<UUID> {
        let repository = repository ?? ChatMessageRepository.shared
        let jobs: [HoloAgentJob]
        do {
            jobs = try await runtime.loadChatLinkedJobs()
        } catch {
            logger.error("[Agent] 读取 Chat 关联 job 失败，跳过本次同步: \(String(describing: error))")
            return []
        }
        var preservedStreamingMessageIDs = Set<UUID>()
        let latestJobsByMessage = Dictionary(grouping: jobs.compactMap { job -> (UUID, HoloAgentJob)? in
            guard let sourceMessageID = job.sourceMessageID else { return nil }
            return (sourceMessageID, job)
        }, by: { $0.0 })
            .compactMap { _, pairs in
                pairs.map(\.1).max { $0.updatedAt < $1.updatedAt }
            }

        for job in latestJobsByMessage {
            guard let sourceMessageID = job.sourceMessageID else { continue }
            let status = HoloAgentChatStatusPresenter.status(for: job)
            if status.keepsMessageStreaming {
                repository.updateAgentMessageProgress(sourceMessageID, status: status)
                preservedStreamingMessageIDs.insert(sourceMessageID)
                continue
            }

            if job.state == .completed {
                do {
                    if let result = try await runtime.loadResult(jobID: job.id) {
                        let evidence = try await runtime.loadEvidence(forIDs: result.evidenceIDs)
                        let rendered = HoloAgentResultRenderer().render(
                            claims: result.claims,
                            evidence: evidence,
                            title: result.title,
                            question: job.userQuestion,
                            coverage: result.coverage
                        )
                        repository.finalizeAgentMessage(sourceMessageID, rendered: rendered, intent: "query_analysis")
                    } else {
                        repository.updateAgentMessageProgress(
                            sourceMessageID,
                            status: HoloAgentChatStatus(
                                title: "深度分析已中断",
                                detail: "Agent 已结束，但没有找到可展示的结果。",
                                keepsMessageStreaming: false,
                                showsActivityIndicator: false
                            )
                        )
                    }
                } catch {
                    // 单 job 结果读取失败：保持消息现状，不写伪状态（§5.5）
                    logger.error("[Agent] 读取 job 结果失败，跳过回填 jobID=\(job.id): \(String(describing: error))")
                    continue
                }
            } else {
                repository.updateAgentMessageProgress(
                    sourceMessageID,
                    status: status
                )
            }
        }
        return preservedStreamingMessageIDs
    }
}
