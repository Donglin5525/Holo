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
    static func status(
        for job: HoloAgentJob,
        context: HoloAgentProgressContext = HoloAgentProgressContext(extractedData: nil),
        now: Date = Date()
    ) -> HoloAgentChatStatus {
        switch job.state {
        case .queued, .running:
            let title = context.isWeeklyPlanning ? "Holo 正在为你的本周计划分析数据…" : "Holo 正在深度分析中…"
            return active(
                title,
                step: job.currentStep,
                detail: elapsedAwareDetail(for: job, now: now, tiers: [
                    (45, "这一步用时比平时长，多半在等网络或系统资源，Holo 仍在推进，没有卡住。")
                ]),
                context: context
            )
        case .waitingForLLM:
            return active(
                context.isWeeklyPlanning ? "Holo 正在为你的本周计划分析数据…" : "Holo 正在深度分析中…",
                detail: elapsedAwareDetail(for: job, now: now, tiers: [
                    (90, "仍在推进——深度分析一般需要 1~3 分钟。期间可以锁屏或离开 App，进度不会丢。"),
                    (50, "这一轮要核对的数据比较多，正在逐条比对，很快就有结果。"),
                    (25, "模型正在深入思考这一轮，Holo 没有卡住，请稍候。")
                ]) ?? stepText("正在调用模型继续推理。", context: context) { "正在继续分析\($0)。\(context.expectedDurationHint)" },
                context: context
            )
        case .retrying:
            return active("Holo 正在重试分析…", detail: "刚才的模型输出不完整，正在自动重试。")
        case .waitingForForeground:
            return HoloAgentChatStatus(
                title: "已暂停 · \(Self.progressText(for: job))未失败",
                detail: "系统暂时收回了后台执行时间，进度已保存。回到前台后会自动继续，无需重新提问。",
                keepsMessageStreaming: true,
                showsActivityIndicator: false
            )
        case .paused:
            // 兼容事故版本遗留的 systemCapacity paused；近期用户任务会在回前台时迁移恢复。
            if job.waitReason == .systemCapacity {
                return HoloAgentChatStatus(
                    title: "已暂停 · \(Self.progressText(for: job))未失败",
                    detail: "系统暂时收回后台执行时间，进度已保存。回到 Holo 后会自动接着往下分析。",
                    keepsMessageStreaming: true,
                    showsActivityIndicator: false
                )
            }
            return HoloAgentChatStatus(
                title: "已暂停 · \(Self.progressText(for: job))未失败",
                detail: "系统已经收回后台执行时间，进度已保存。回到前台后会自动继续，无需重新提问。",
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
            // 额度终态单独成文案：付费墙语义（升级入口在消息层渲染），不用「已中断」掩盖。
            if job.isQuotaExhaustedFailure {
                return HoloAgentChatStatus(
                    title: HoloAgentJob.quotaExhaustedSummaryPrefix,
                    detail: job.quotaExhaustedUserMessage ?? "额度已用完，请在额度重置后再试",
                    keepsMessageStreaming: false,
                    showsActivityIndicator: false
                )
            }
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

    /// 暂停/等待态的进度摘要：「已完成 X/Y 轮，」；无预算信息时给空串。
    private static func progressText(for job: HoloAgentJob) -> String {
        let completed = job.budget.consumedLLMRounds
        let total = job.budget.maxLLMRounds
        guard total > 0, completed > 0 else { return "" }
        return "已完成 \(completed)/\(total) 轮，"
    }

    /// 「立即继续」按钮的即时反馈状态：点击瞬间先写进消息，让卡片立刻脱离暂停样式；
    /// 恢复链拉起后由轮询/同步管道刷成真实的「分析中」进度。
    static func resumingStatus() -> HoloAgentChatStatus {
        HoloAgentChatStatus(
            title: "正在继续分析…",
            detail: "正在从上次暂停的位置接着跑，无需重新提问。",
            keepsMessageStreaming: true,
            showsActivityIndicator: true
        )
    }

    /// waitingForCondition 按 waitReason 给出可解释文案（§7.2：不显示失败）。
    /// 网络等待叠加时长轮换：让「自动重连」成为可感知的活信号，而不是静止的一句话。
    private static func waitingForConditionStatus(for job: HoloAgentJob, now: Date = Date()) -> HoloAgentChatStatus {
        let title: String
        let detail: String
        switch job.waitReason {
        case .deviceUnlock, .protectedData:
            title = "等待设备解锁"
            detail = "设备锁定，解锁后继续读取健康数据。"
        case .network:
            title = "等待网络恢复"
            detail = elapsedAwareDetail(for: job, now: now, tiers: [
                (45, "网络仍未恢复。一旦恢复 Holo 会立即自动接着分析，进度已保存，可以先去忙别的。"),
                (15, "还在等待网络恢复，Holo 会自动重连并接着分析，进度已保存。")
            ]) ?? "网络连接中断，Holo 正在自动重连，无需手动操作。"
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

    /// 长等待的「活信号」文案（锁屏高可用）：按停留在当前状态的时长取最高命中档，
    /// 未到档位返回 nil（调用方回落到既有 step 文案）。Chat 前台 2s 轮询持续调用
    /// status(for:)，文案随时长自动轮换，让用户明显感知「还在工作、没有卡住」。
    private static func elapsedAwareDetail(
        for job: HoloAgentJob,
        now: Date,
        tiers: [(threshold: TimeInterval, text: String)]
    ) -> String? {
        let elapsed = now.timeIntervalSince(job.updatedAt)
        var matched: String?
        for tier in tiers where elapsed >= tier.threshold {
            matched = tier.text
        }
        return matched
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
            title.hasPrefix("深度分析出错") ||
            title.hasPrefix("深度分析额度已用完") ||
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
                               detail: String? = nil,
                               context: HoloAgentProgressContext = HoloAgentProgressContext(extractedData: nil)) -> HoloAgentChatStatus {
        HoloAgentChatStatus(
            title: title,
            detail: detail ?? detailText(for: step, context: context),
            keepsMessageStreaming: true,
            showsActivityIndicator: true
        )
    }

    /// 步骤文案的动态骨架：有本次分析上下文时组装「正在读取你最近的睡眠数据…」式贴身文案，
    /// 无上下文退回通用文案（不阻塞、不额外调用）
    private static func stepText(_ fallback: String, context: HoloAgentProgressContext, build: (String) -> String) -> String {
        guard let phrase = context.analysisTargetPhrase else { return fallback }
        return build(phrase)
    }

    private static func detailText(for step: HoloAgentStep?, context: HoloAgentProgressContext) -> String {
        // 周计划：按步骤贴合「汇总快照」的叙事
        if context.isWeeklyPlanning {
            switch step {
            case .plan: return "正在规划要看你本周哪些数据。\(context.expectedDurationHint)"
            case .executeTools: return "正在汇总你本周的任务、习惯、记账与健康快照。\(context.expectedDurationHint)"
            case .minePatterns: return "正在从本周数据里找显著变化。"
            case .integrateResults: return "正在确定本周重点。"
            case .verifyClaims: return "正在核对每个结论的依据。"
            case .render: return "正在生成本周重点。"
            default: return context.expectedDurationHint
            }
        }
        switch step {
        case .plan:
            return stepText("正在理解问题并规划需要查看的数据。", context: context) { "正在理解你要看\($0)哪方面的变化。\(context.expectedDurationHint)" }
        case .executeTools:
            return stepText("正在读取本地数据并核对证据。", context: context) { "正在读取你\($0)的记录并核对证据。\(context.expectedDurationHint)" }
        case .minePatterns:
            return stepText("正在从数据里整理模式和变化。", context: context) { "正在从你\($0)里找模式和变化。" }
        case .integrateResults:
            return stepText("正在整合分析结果。", context: context) { "正在把你\($0)的变化整合成结论。" }
        case .verifyClaims:
            return "正在校验结论和依据。"
        case .critique:
            return "正在复核分析质量。"
        case .curateMemory:
            return "正在整理可沉淀的记忆线索。"
        case .render:
            return stepText("正在生成可阅读的分析结果。", context: context) { "正在把\($0)的分析整理成你能看的结果。" }
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

    /// 最近一次成功运行的消耗（jobID + 预算），供 LifePlan PlanRun 成本记录。
    private(set) var lastRunConsumption: (jobID: String, budget: PlanConsumedBudget)?

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
    func runAnalysis(
        question: String,
        trigger: HoloAgentTrigger = .userQuestion,
        sourceMessageID: UUID? = nil,
        continuation: HoloAgentContinuationRequest? = nil
    ) async -> HoloRenderedAgentResult {
        // 只记录长度，不把用户问题原文写入系统日志（Phase 7 隐私契约）。
        logger.info("[Agent] 开始 questionLength=\(question.count, privacy: .public)")
        // 真出错（网络/超时/内部异常）统一走 analysisFailed；额度耗尽走专属 quotaExhausted。
        // fail 不再吞掉 HoloQuotaError——额度是档位限制，不是系统错误，上层据此渲染额度卡片。
        let fail = { (reason: String) -> HoloRenderedAgentResult in
            HoloRenderedAgentResult(
                title: "深度分析出错",
                summary: reason,
                sections: [],
                evidenceReferences: [],
                failure: .analysisFailed
            )
        }
        let toolDescriptions = await runtime.toolDescriptions()
        // 接入 PromptManager.agentLoop 模板：该模板定义了 status 取值、JSON Schema、
        // evidenceID 必须逐字引用等协议约束。此前传空串导致模型无协议指令，
        // 输出的 claim 因 evidenceID 缺失/编造被 Verifier 全部 reject → "没有形成可信结论"。
        let systemTemplate = PromptManager.shared.loadRawTemplate(.agentLoop)
        logger.info("[Agent] 经 Scheduler 启动 runLoop…")
        let finalJob: HoloAgentJob
        do {
            // §6.1：入口统一走 Scheduler 唯一执行权（createAndRun）
            finalJob = try await scheduler.createAndRun(HoloAgentStartRequest(
                question: question,
                trigger: trigger,
                systemTemplate: systemTemplate,
                toolDescriptions: toolDescriptions,
                sourceMessageID: sourceMessageID,
                continuation: continuation
            ))
            logger.info("[Agent] runLoop 完成 state=\(finalJob.state.rawValue) rounds=\(finalJob.budget.consumedLLMRounds)")
        } catch let error as HoloQuotaError {
            // 额度耗尽：档位限制而非系统错误，透传额度文案，上层渲染额度卡片 + 升级入口。
            logger.info("[Agent] runLoop 因额度耗尽中止 code=\(error.userMessage, privacy: .public)")
            return HoloRenderedAgentResult(
                title: "深度分析额度已用完",
                summary: error.userMessage,
                sections: [],
                evidenceReferences: [],
                failure: .quotaExhausted(userMessage: error.userMessage)
            )
        } catch HoloAgentRuntimeError.continuationParentUnavailable(let reason) {
            let message = "上一份分析的数据依据已经不可用，请重新发起一次完整分析后再追问。"
            logger.info("[Agent] 追问父结果不可用 reason=\(reason, privacy: .public)")
            return HoloRenderedAgentResult(
                title: "需要重新分析",
                summary: message,
                sections: [],
                evidenceReferences: [],
                failure: .continuationUnavailable(userMessage: message)
            )
        } catch is CancellationError {
            // 只要同一消息已有持久化 Agent Job，最终展示权就继续属于该 Job。
            // 系统取消、用户取消、前台恢复和“恢复代次已经完成”都不得再启动普通聊天回答。
            if await persistedAgentOwnsMessage(sourceMessageID: sourceMessageID) {
                return HoloRenderedAgentResult(
                    title: "后台分析已暂停",
                    summary: "这次分析由已保存的 Agent 任务继续处理。",
                    sections: [],
                    evidenceReferences: [],
                    failure: .executionSuspended
                )
            }
            return fail("[runLoop已取消]")
        } catch {
            // URLSession 的客户端中止可能以 499/GatewayError 到达这里，而不是
            // CancellationError。此时前台恢复代次可能已在运行甚至已完成；以落盘 Job 为准，
            // 不能把相同问题再交给普通 chat，造成普通回答和 Agent 卡片互相覆盖。
            if await persistedAgentOwnsMessage(sourceMessageID: sourceMessageID) {
                logger.info("[Agent] 请求异常但持久化 Job 仍拥有消息，交由状态同步 error=\(String(describing: error), privacy: .public)")
                return HoloRenderedAgentResult(
                    title: "Agent 分析继续处理中",
                    summary: "正在同步这次分析的真实状态。",
                    sections: [],
                    evidenceReferences: [],
                    failure: .executionSuspended
                )
            }
            return fail("[runLoop异常] \(String(describing: error))")
        }
        guard finalJob.state == .completed else {
            switch finalJob.state {
            case .failed, .cancelled, .superseded:
                let detail = "state=\(finalJob.state.rawValue) rounds=\(finalJob.budget.consumedLLMRounds)/\(finalJob.budget.maxLLMRounds) error=\(finalJob.errorSummary ?? "无")"
                return fail("[未完成] \(detail)")
            default:
                // 可恢复非终态（等待网络/等待前台/暂停等）：runLoop 因等待预算耗尽正常让位，
                // 任务并未失败——消息保持活跃交恢复链与状态同步管道接管，恢复后自动续跑。
                // 在此渲染「出错」卡片就是「提示失败、点进去却能继续」的消息层假失败。
                logger.info("[Agent] runLoop 返回可恢复等待态 state=\(finalJob.state.rawValue) waitReason=\(finalJob.waitReason?.rawValue ?? "无")，交恢复链接管")
                return HoloRenderedAgentResult(
                    title: "深度分析进行中",
                    summary: "网络或系统资源暂时不可用，进度已保存；条件恢复后会自动继续，无需重新提问。",
                    sections: [],
                    evidenceReferences: [],
                    failure: .executionSuspended
                )
            }
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
        lastRunConsumption = (
            jobID: finalJob.id,
            budget: PlanConsumedBudget(
                llmRounds: finalJob.budget.consumedLLMRounds,
                toolBatches: finalJob.budget.consumedToolBatches,
                inputTokens: finalJob.budget.consumedInputTokens,
                outputTokens: finalJob.budget.consumedOutputTokens,
                activeRuntimeSeconds: finalJob.consumedActiveRuntime ?? 0
            )
        )
        do {
            let evidence = try await runtime.loadEvidence(forIDs: result.evidenceIDs)
            var rendered = HoloAgentResultRenderer().render(
                claims: result.claims,
                evidence: evidence,
                title: result.title,
                question: question,
                coverage: result.coverage,
                emptyReason: result.emptyReason,
                answerContext: HoloAgentAnswerContext(
                    primaryTimeRange: finalJob.timeRange,
                    snapshotCutoffAt: finalJob.snapshotCutoffAt ?? finalJob.createdAt,
                    timeRangeAttribution: finalJob.timeRangeAttribution
                        ?? result.timeRangeAttribution
                ),
                requestedDeliverables: result.requestedDeliverables ?? [],
                narrativeSummary: result.narrativeSummary,
                keyInsight: result.keyInsight,
                contextSources: result.contextSources ?? [],
                dataSamplePreview: Self.makeSamplePreview(from: nil),
                lineage: result.lineage,
                rootUserQuestion: finalJob.originalUserQuestion
            )
            rendered.agentJobID = finalJob.id
            rendered.agentResultID = result.id
            rendered.lineage = result.lineage
            rendered.rootUserQuestion = finalJob.originalUserQuestion ?? question
            return rendered
        } catch {
            return fail("[证据读取失败] \(String(describing: error))")
        }
    }

    /// 一条消息一份最终答案：Agent Job 一旦建立，除非它明确失败，否则该消息的展示权
    /// 不得降级给另一条普通聊天请求。completed 也返回 true，让上层从结果仓库回填卡片。
    private func persistedAgentOwnsMessage(sourceMessageID: UUID?) async -> Bool {
        guard let sourceMessageID else { return false }
        do {
            guard let latestJob = try await runtime.loadChatLinkedJobs()
                .filter({ $0.sourceMessageID == sourceMessageID })
                .max(by: { $0.updatedAt < $1.updatedAt }) else {
                return false
            }
            return latestJob.state != .failed
        } catch {
            logger.error("[Agent] 判断消息展示权失败: \(String(describing: error), privacy: .public)")
            return false
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
            // 用户已主动停止的消息（.userCancelled 持久标记）：即使后台 job 仍处于
            // waiting/retrying 等非终态（取消落盘是异步的，可能与本同步产生竞态），
            // 也绝不把它重新点亮成 streaming——这正是「退出再进来还在请求中」的根治点。
            if repository.messageType(for: sourceMessageID) == .userCancelled {
                continue
            }
            let status = HoloAgentChatStatusPresenter.status(for: job)
            if status.keepsMessageStreaming {
                repository.updateAgentMessageProgress(sourceMessageID, status: status)
                preservedStreamingMessageIDs.insert(sourceMessageID)
                continue
            }
            // 终态 job 清掉可能残留的「已暂停」对冲通知：通知与结果卡不能各说各话。
            HoloAgentPauseNotifier.clearPausedNotice(jobID: job.id)

            if job.state == .completed {
                do {
                    if let result = try await runtime.loadResult(jobID: job.id) {
                        let evidence = try await runtime.loadEvidence(forIDs: result.evidenceIDs)
                        var rendered = HoloAgentResultRenderer().render(
                            claims: result.claims,
                            evidence: evidence,
                            title: result.title,
                            question: job.userQuestion,
                            coverage: result.coverage,
                            emptyReason: result.emptyReason,
                            answerContext: HoloAgentAnswerContext(
                                primaryTimeRange: job.timeRange,
                                snapshotCutoffAt: job.snapshotCutoffAt ?? job.createdAt,
                                timeRangeAttribution: job.timeRangeAttribution
                                    ?? result.timeRangeAttribution
                            ),
                            requestedDeliverables: result.requestedDeliverables ?? [],
                            narrativeSummary: result.narrativeSummary,
                            keyInsight: result.keyInsight,
                            contextSources: result.contextSources ?? [],
                            dataSamplePreview: Self.makeSamplePreview(from: nil),
                            lineage: result.lineage,
                            rootUserQuestion: job.originalUserQuestion
                        )
                        rendered.agentJobID = job.id
                        rendered.agentResultID = result.id
                        rendered.lineage = result.lineage
                        rendered.rootUserQuestion = job.originalUserQuestion ?? job.userQuestion
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
                // 已是额度卡片的消息不被普通进度文案覆盖：额度耗尽在前台已落地为
                // messageType=.quotaExhausted，回前台恢复时 job 可能处于 .failed 终态，
                // 若直接 updateAgentMessageProgress 会把额度文案改成"已中断"，丢失升级入口。
                if repository.messageType(for: sourceMessageID) == .quotaExhausted {
                    continue
                }
                // 额度终态 job 且消息尚未落地（如后台恢复中被拒、前台渲染链中断）：
                // 就地补落地额度卡片。此前这条路径无人渲染，消息永远停在「分析中」转圈。
                if job.isQuotaExhaustedFailure {
                    repository.finalizeMessage(
                        sourceMessageID,
                        finalContent: job.quotaExhaustedUserMessage ?? "额度已用完，请在额度重置后再试",
                        intent: "query_analysis",
                        extractedDataJSON: nil,
                        parsedBatchJSON: nil,
                        executionBatchJSON: nil,
                        analysisContextJSON: nil,
                        rawLogJSON: nil,
                        agentResultJSON: nil,
                        messageType: .quotaExhausted
                    )
                    continue
                }
                repository.updateAgentMessageProgress(
                    sourceMessageID,
                    status: status
                )
            }
        }
        return preservedStreamingMessageIDs
    }

    /// 前台等待期间的单条步骤刷新（P2 步骤实时化）：按消息找最新活跃 job，
    /// 把当前步骤文案推给聊天气泡。与 syncRecoverableChatMessages 同管道、同竞态约束
    /// （userCancelled 不点亮、终态交给主路径），供 ChatViewModel 轮询调用。
    @discardableResult
    func refreshLiveProgress(sourceMessageID: UUID) async -> Bool {
        let repository = ChatMessageRepository.shared
        let jobs: [HoloAgentJob]
        do {
            jobs = try await runtime.loadChatLinkedJobs()
        } catch {
            return false
        }
        guard let job = jobs
            .filter({ $0.sourceMessageID == sourceMessageID })
            .max(by: { $0.updatedAt < $1.updatedAt }),
            job.state != .completed,
            repository.messageType(for: sourceMessageID) != .userCancelled
        else { return false }
        // 绝对截止主动兜底：等待态 job 超过截止后，只有「下一次回前台/启动」的恢复链
        // 才会检查 deadline；用户停留前台时轮询就地终结，不让转圈无限挂起。
        // 只处理等待态——running/waitingForLLM 可能有活跃执行在写，轮询侧落终态会互相覆盖。
        let waitingStates: Set<HoloAgentJobState> = [.queued, .waitingForForeground, .waitingForCondition, .paused]
        if waitingStates.contains(job.state), job.isPastAbsoluteDeadline() {
            _ = try? await runtime.failJob(
                jobID: job.id,
                reason: "任务已超过截止时限，不再继续"
            )
            repository.updateAgentMessageProgress(sourceMessageID, status: HoloAgentChatStatus(
                title: "深度分析已中断",
                detail: "任务已超过截止时限，不再继续。请重新发起分析。",
                keepsMessageStreaming: false,
                showsActivityIndicator: false
            ))
            return false
        }
        let status = HoloAgentChatStatusPresenter.status(for: job)
        guard status.keepsMessageStreaming else { return false }
        repository.updateAgentMessageProgress(sourceMessageID, status: status)
        return true
    }

    /// 从持久化的样本摘要构造渲染预览；空或缺失返回 nil。
    private static func makeSamplePreview(from excerpts: [String]?) -> HoloRenderedDataSamplePreview? {
        guard let excerpts, !excerpts.isEmpty else { return nil }
        return HoloRenderedDataSamplePreview(
            domainLabel: "账单",
            count: excerpts.count,
            excerpts: excerpts
        )
    }
}
