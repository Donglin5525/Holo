//
//  HoloPeriodReplayCoordinator.swift
//  Holo
//
//  周期回放的唯一执行入口。
//  负责原消息续跑、网络中断重试、continued processing 到期收口与冷启动恢复。
//

import Foundation
import Network
import os.log

@MainActor
final class HoloPeriodReplayCoordinator {
    static let shared = HoloPeriodReplayCoordinator()

    private let logger = Logger(subsystem: "com.holo.app", category: "PeriodReplay")
    private let repository = ChatMessageRepository.shared
    private let maxAttempts = 3
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "com.holo.period-replay.network")

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var continuedLeases: [UUID: HoloInsightContinuedProcessingLease] = [:]

    private init() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                await CoreDataStack.shared.waitUntilReady()
                self?.resumePendingJobs(
                    reason: "network_restored",
                    onlyState: .waitingForNetwork
                )
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    var hasActiveUserReplay: Bool {
        !activeTasks.isEmpty
    }

    /// 用户主动生成回放。相同周期已有可恢复任务时复用原消息，避免重复生成。
    func start(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date
    ) async {
        await CoreDataStack.shared.waitUntilReady()

        if let existing = repository.recoverablePeriodReplayJob(
            periodType: periodType,
            start: start,
            end: end
        ) {
            logger.info("[resume] 复用同周期任务 message=\(existing.messageId.uuidString)")
            var resumedJob = existing.job
            resumedJob.resumeCount += 1
            resumedJob.updatedAt = Date()
            repository.updatePeriodReplayJob(existing.messageId, job: resumedJob)
            schedule(messageId: existing.messageId, job: resumedJob)
            return
        }

        let job = HoloPeriodReplayJob(
            periodType: periodType,
            periodStart: start,
            periodEnd: end
        )
        // 额度预检（先验票再进场）：洞察额度（memoryInsight 池，免费 1 次/周）为 0 时
        // 直接落额度卡片，不进「正在生成回放…」转圈态。余量缺失或过期时放行，
        // 由执行中的额度错误 + markFailed 额度文案兜底。
        if let remaining = HoloEntitlementState.shared.quotas["memoryInsight"]?.remaining,
           remaining <= 0 {
            let quotaMessage = HoloQuotaError.memoryInsightExhaustedMessage(
                isPlusActive: HoloEntitlementState.shared.isPlusActive
            )
            let userMessageId = repository.addMessage(
                role: "user",
                content: "生成\(job.periodLabel)回放",
                messageType: .periodReplay
            )
            let assistantMessageId = repository.addStreamingMessage(
                role: "assistant",
                parentMessageId: userMessageId,
                messageType: .periodReplay,
                extractedDataJSON: nil
            )
            repository.finishStreaming(
                assistantMessageId,
                finalContent: quotaMessage,
                messageType: .quotaExhausted
            )
            logger.info("[quota-preflight] 洞察额度为 0，直接落额度卡片 period=\(periodType.rawValue)")
            return
        }
        let userMessageId = repository.addMessage(
            role: "user",
            content: "生成\(job.periodLabel)回放",
            messageType: .periodReplay
        )
        let assistantMessageId = repository.addStreamingMessage(
            role: "assistant",
            parentMessageId: userMessageId,
            messageType: .periodReplay,
            extractedDataJSON: job.json
        )
        logger.info("[created] 周期回放 message=\(assistantMessageId.uuidString) period=\(periodType.rawValue)")
        schedule(messageId: assistantMessageId, job: job)
    }

    /// 首页胶囊 / 系统通知直达：把已生成的洞察直接落成一张完成的回放卡片。
    /// 不触发生成（generateInsight 都不进）、不受额度预检拦截——额度拦的是新生成，
    /// 不是查看已有结果；因此也不进入重试/息屏接管链路。
    func presentCachedInsight(_ insight: MemoryInsight) {
        guard let payload = insight.parsedPayload else { return }
        let job = HoloPeriodReplayJob(
            periodType: insight.insightPeriodType,
            periodStart: insight.periodStart,
            periodEnd: insight.periodEnd,
            state: .completed
        )
        let userMessageId = repository.addMessage(
            role: "user",
            content: "查看\(job.periodLabel)回放",
            messageType: .periodReplay
        )
        let assistantMessageId = repository.addStreamingMessage(
            role: "assistant",
            parentMessageId: userMessageId,
            messageType: .periodReplay,
            extractedDataJSON: job.json
        )
        let fallbackText = [payload.title, payload.summary]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        repository.finalizeMessage(
            assistantMessageId,
            finalContent: fallbackText,
            intent: nil,
            extractedDataJSON: job.json,
            parsedBatchJSON: nil,
            executionBatchJSON: nil,
            insightResultJSON: Self.encode(payload),
            messageType: .periodReplay
        )
        logger.info("[present-cached] 已生成洞察直接落卡 message=\(assistantMessageId.uuidString) period=\(insight.periodType)")
    }

    /// 用户在失败卡片上点击“继续生成”。
    func continueGeneration(messageId: UUID) {
        guard var job = repository.periodReplayJob(messageId: messageId) else { return }
        job.state = .generating
        job.attemptCount = 0
        job.lastErrorCategory = nil
        job.updatedAt = Date()
        repository.updatePeriodReplayJob(
            messageId,
            job: job,
            content: job.statusText,
            isStreaming: true
        )
        schedule(messageId: messageId, job: job)
    }

    /// 冷启动恢复。必须在 Core Data ready 后调用。
    func appDidLaunch() async {
        await CoreDataStack.shared.waitUntilReady()
        resumePendingJobs(reason: "launch")
    }

    /// App 回到前台后继续系统暂停或网络中断的任务。
    func appWillEnterForeground() {
        resumePendingJobs(reason: "foreground")
    }

    /// 孤儿 streaming 清理时必须保留的周期回放消息。
    func recoverableMessageIDs() -> Set<UUID> {
        Set(repository.recoverablePeriodReplayJobs().map(\.messageId))
    }

    private func resumePendingJobs(
        reason: String,
        onlyState: HoloPeriodReplayJobState? = nil
    ) {
        guard activeTasks.isEmpty else { return }
        for record in repository.recoverablePeriodReplayJobs() {
            if let onlyState, record.job.state != onlyState {
                continue
            }
            var resumedJob = record.job
            resumedJob.resumeCount += 1
            resumedJob.updatedAt = Date()
            repository.updatePeriodReplayJob(record.messageId, job: resumedJob)
            logger.info("[resume] reason=\(reason) message=\(record.messageId.uuidString) state=\(resumedJob.state.rawValue)")
            schedule(messageId: record.messageId, job: resumedJob)
            // MemoryInsightService 是单通道；其余任务保留在消息中，前一个结束后再恢复。
            break
        }
    }

    private func schedule(messageId: UUID, job: HoloPeriodReplayJob) {
        guard activeTasks[messageId] == nil else {
            logger.debug("[dedupe] 已有执行任务 message=\(messageId.uuidString)")
            return
        }
        guard activeTasks.isEmpty else {
            var queuedJob = job
            queuedJob.state = .waitingForForeground
            queuedJob.updatedAt = Date()
            repository.updatePeriodReplayJob(
                messageId,
                job: queuedJob,
                content: "前一份回放正在生成，这份已排队",
                isStreaming: true
            )
            logger.info("[queued] 等待上一份周期回放 message=\(messageId.uuidString)")
            return
        }

        HoloReplayDigestService.shared.beginUserReplay(messageId: messageId)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(messageId: messageId, initialJob: job)
        }
        activeTasks[messageId] = task
    }

    private func execute(messageId: UUID, initialJob: HoloPeriodReplayJob) async {
        var job = repository.periodReplayJob(messageId: messageId) ?? initialJob
        var attemptsThisExecution = 0
        var completedSuccessfully = false
        let executionStartedAt = Date()

        acquireContinuedLease(messageId: messageId)
        defer {
            activeTasks[messageId] = nil
            let finalState = repository.periodReplayJob(messageId: messageId)?.state
            let waitingForExternalResume =
                finalState == .waitingForForeground || finalState == .waitingForNetwork
            if !waitingForExternalResume {
                resumePendingJobs(reason: "previous_completed")
            }
            HoloReplayDigestService.shared.endUserReplay(
                messageId: messageId,
                resumeQueuedDigest: !waitingForExternalResume
            )
            let finalJob = repository.periodReplayJob(messageId: messageId) ?? job
            let durationMilliseconds = Int(Date().timeIntervalSince(executionStartedAt) * 1_000)
            logger.info(
                "[summary] message=\(messageId.uuidString) state=\(finalJob.state.rawValue) durationMs=\(durationMilliseconds) attempts=\(finalJob.attemptCount) networkInterruptions=\(finalJob.networkInterruptionCount) resumes=\(finalJob.resumeCount) expirations=\(finalJob.backgroundExpirationCount)"
            )
        }

        while attemptsThisExecution < maxAttempts {
            if Task.isCancelled { break }

            // 自动洞察若已先开始，不抢写同一服务；用户任务保留在原消息中等待。
            if MemoryInsightService.shared.isGenerating {
                repository.updatePeriodReplayJob(
                    messageId,
                    job: job,
                    content: "正在完成上一项洞察，随后继续回放…",
                    isStreaming: true
                )
                do {
                    try await Task.sleep(for: .seconds(2))
                    continue
                } catch {
                    handleCancellation(messageId: messageId, job: &job)
                    break
                }
            }

            job.state = .generating
            job.attemptCount += 1
            attemptsThisExecution += 1
            job.updatedAt = Date()
            repository.updatePeriodReplayJob(
                messageId,
                job: job,
                content: job.attemptCount == 1
                    ? "正在生成\(job.periodLabel)回放…"
                    : "正在继续整理\(job.periodLabel)回放…",
                isStreaming: true
            )
            logger.info("[attempt] message=\(messageId.uuidString) count=\(job.attemptCount)")

            do {
                let insight = try await MemoryInsightService.shared.generateInsight(
                    periodType: job.periodType,
                    start: job.periodStart,
                    end: job.periodEnd,
                    forceRefresh: job.attemptCount > 1
                )
                try Task.checkCancellation()
                guard let payload = insight.parsedPayload else {
                    throw MemoryInsightParseFailure.invalidSchema
                }
                finalizeSuccess(messageId: messageId, job: &job, payload: payload)
                completedSuccessfully = true
                break
            } catch is CancellationError {
                handleCancellation(messageId: messageId, job: &job)
                break
            } catch {
                if Task.isCancelled {
                    handleCancellation(messageId: messageId, job: &job)
                    break
                }

                let category = errorCategory(error)
                let quotaMessage = (error as? HoloQuotaError)?.userMessage
                if isNetworkError(error) {
                    job.networkInterruptionCount += 1
                }
                job.lastErrorCategory = category
                job.updatedAt = Date()
                logger.error(
                    "[failure] message=\(messageId.uuidString) attempt=\(job.attemptCount) category=\(category) detail=\(error.localizedDescription)"
                )

                guard isRecoverable(error) else {
                    markFailed(messageId: messageId, job: job, category: category, quotaMessage: quotaMessage)
                    break
                }

                if attemptsThisExecution >= maxAttempts {
                    if isNetworkError(error) {
                        job.state = .waitingForNetwork
                        repository.updatePeriodReplayJob(
                            messageId,
                            job: job,
                            content: "网络仍未恢复，连接恢复后会自动继续",
                            isStreaming: true
                        )
                    } else {
                        markFailed(messageId: messageId, job: job, category: category, quotaMessage: quotaMessage)
                    }
                    break
                }

                job.state = isNetworkError(error) ? .waitingForNetwork : .generating
                let waitingText = isNetworkError(error)
                    ? "网络连接中断，正在重新连接…"
                    : "生成结果不完整，正在重新整理…"
                repository.updatePeriodReplayJob(
                    messageId,
                    job: job,
                    content: waitingText,
                    isStreaming: true
                )

                do {
                    let delaySeconds = UInt64(min(job.attemptCount, 2))
                    try await Task.sleep(for: .seconds(delaySeconds))
                } catch {
                    handleCancellation(messageId: messageId, job: &job)
                    break
                }
            }
        }

        await finishContinuedLease(
            messageId: messageId,
            success: completedSuccessfully
        )
    }

    private func finalizeSuccess(
        messageId: UUID,
        job: inout HoloPeriodReplayJob,
        payload: MemoryInsightPayload
    ) {
        job.state = .completed
        job.lastErrorCategory = nil
        job.updatedAt = Date()
        let fallbackText = [payload.title, payload.summary]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let payloadJSON = Self.encode(payload)

        repository.finalizeMessage(
            messageId,
            finalContent: fallbackText,
            intent: nil,
            extractedDataJSON: job.json,
            parsedBatchJSON: nil,
            executionBatchJSON: nil,
            insightResultJSON: payloadJSON,
            messageType: .periodReplay
        )
        let completedAttemptCount = job.attemptCount
        logger.info("[completed] message=\(messageId.uuidString) attempts=\(completedAttemptCount)")
    }

    /// 额度终态的错误分类标记（errorCategory 专用），markFailed 据此切换文案。
    private static let quotaExhaustedCategory = "QUOTA_EXHAUSTED"

    private func markFailed(
        messageId: UUID,
        job originalJob: HoloPeriodReplayJob,
        category: String,
        quotaMessage: String? = nil
    ) {
        var job = originalJob
        job.state = .failed
        job.lastErrorCategory = category
        job.updatedAt = Date()
        // 额度耗尽是档位限制：如实告知，不引导「点继续生成」（重置前必再失败）。
        let content: String
        if category == Self.quotaExhaustedCategory, let quotaMessage {
            content = quotaMessage
        } else {
            content = "这次\(job.periodLabel)回放没有生成完整，点“继续生成”即可接着处理。"
        }
        repository.updatePeriodReplayJob(
            messageId,
            job: job,
            content: content,
            isStreaming: false
        )
        logger.error("[terminal] message=\(messageId.uuidString) category=\(category)")
    }

    private func handleCancellation(
        messageId: UUID,
        job: inout HoloPeriodReplayJob
    ) {
        // expiration 回调已先写 waitingForForeground；普通任务取消也统一落为可恢复状态。
        if let persisted = repository.periodReplayJob(messageId: messageId),
           persisted.state == .waitingForForeground {
            job = persisted
            return
        }
        job.state = .waitingForForeground
        job.lastErrorCategory = "EXECUTION_CANCELLED"
        job.updatedAt = Date()
        repository.updatePeriodReplayJob(
            messageId,
            job: job,
            content: job.statusText,
            isStreaming: true
        )
    }

    private func acquireContinuedLease(messageId: UUID) {
        guard #available(iOS 26.0, *),
              HoloAIFeatureFlags.aiDataProcessingConsentGranted else { return }

        let lease = HoloInsightContinuedProcessingLease(
            requestID: messageId.uuidString,
            client: HoloSystemContinuedProcessingClient()
        ) { [weak self] in
            self?.continuedLeaseDidExpire(messageId: messageId)
        }
        if lease.acquire() {
            continuedLeases[messageId] = lease
            logger.info("[continued] 已接管息屏执行 message=\(messageId.uuidString)")
        } else {
            logger.info("[continued] 系统未接纳，保持当前执行 message=\(messageId.uuidString)")
        }
    }

    private func continuedLeaseDidExpire(messageId: UUID) {
        guard var job = repository.periodReplayJob(messageId: messageId),
              job.state.isRecoverable else { return }
        job.state = .waitingForForeground
        job.backgroundExpirationCount += 1
        job.lastErrorCategory = "BACKGROUND_TIME_EXPIRED"
        job.updatedAt = Date()
        repository.updatePeriodReplayJob(
            messageId,
            job: job,
            content: job.statusText,
            isStreaming: true
        )
        continuedLeases[messageId] = nil
        activeTasks[messageId]?.cancel()
        logger.warning("[continued] 系统时间到期，已保存待恢复状态 message=\(messageId.uuidString)")
    }

    private func finishContinuedLease(messageId: UUID, success: Bool) async {
        guard let lease = continuedLeases.removeValue(forKey: messageId) else { return }
        await lease.finish(success: success)
    }

    private func isNetworkError(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            switch apiError {
            case .networkUnavailable, .timeout:
                return true
            default:
                return false
            }
        }
        if let insightError = error as? MemoryInsightError,
           case .generationTimeout = insightError {
            return true
        }
        return error is URLError
    }

    private func isRecoverable(_ error: Error) -> Bool {
        if isNetworkError(error) || error is MemoryInsightParseFailure {
            return true
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .backendError(_, let code, _, _):
                return [
                    "EMPTY_MODEL_RESPONSE",
                    "TRUNCATED_MODEL_RESPONSE",
                    "INVALID_INSIGHT_JSON",
                    "UPSTREAM_SSE_INVALID_FRAME",
                    "UPSTREAM_SSE_INCOMPLETE"
                ].contains(code ?? "") || apiError.isRetryable
            default:
                return apiError.isRetryable
            }
        }
        if let insightError = error as? MemoryInsightError {
            switch insightError {
            case .generationInProgress, .generationTimeout, .parsingFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func errorCategory(_ error: Error) -> String {
        if error is HoloQuotaError {
            return Self.quotaExhaustedCategory
        }
        if let apiError = error as? APIError {
            return apiError.diagnosticCategory
        }
        if let failure = error as? MemoryInsightParseFailure {
            switch failure {
            case .emptyResponse: return "EMPTY_RESPONSE"
            case .invalidJSON: return "INVALID_JSON"
            case .invalidSchema: return "INVALID_SCHEMA"
            }
        }
        if let insightError = error as? MemoryInsightError {
            switch insightError {
            case .aiNotConfigured: return "AI_NOT_CONFIGURED"
            case .generationInProgress: return "GENERATION_IN_PROGRESS"
            case .generationTimeout: return "GENERATION_TIMEOUT"
            case .parsingFailed: return "PARSING_FAILED"
            case .contextBuildFailed: return "CONTEXT_BUILD_FAILED"
            case .aiDataProcessingConsentRequired: return "CONSENT_REQUIRED"
            }
        }
        return String(describing: type(of: error))
    }

    private static func encode(_ payload: MemoryInsightPayload) -> String? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
