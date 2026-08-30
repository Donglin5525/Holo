//
//  HoloCloudAnalysisService.swift
//  Holo
//
//  云端异步分析（二期 M2b）——设备侧编排：快照聚合 → 建任务 → 上传 →
//  轮询领取 → 结果落消息；任一环节失败自动回落本地轨道（用户无感）。
//  - 锁屏/离开 App：轮询随进程挂起暂停，云端继续执行；回前台恢复轮询
//    （HoloApp scenePhase 钩子调 resumePolling）。结果云端密文等 7 天。
//  - 隐私文案：首次云端分析需用户确认（ChatView sheet），确认后不再打扰；
//    分析期间状态卡持续展示「加密上传·仅本次·结束即删」口径。
//

import Foundation
import os.log

@MainActor
final class HoloCloudAnalysisService {

    static let shared = HoloCloudAnalysisService()

    private let logger = Logger(subsystem: "com.holo.app", category: "CloudAnalysis")
    private let client: HoloCloudAnalysisClient
    private let analysisService: HoloAgentAnalysisService
    private let repository: ChatMessageRepository

    /// 进行中的云端任务：taskId → (sourceMessageID, question)。回前台恢复轮询用。
    /// 同步持久化（杀 App 后冷启动恢复领取——云端结果等 7 天，但没有恢复入口就等于丢失）。
    private var activeTasks: [String: (messageID: UUID, question: String)] = [:] {
        didSet { persistActiveTasks() }
    }
    private var pollingTasks: [String: Task<Void, Never>] = [:]

    /// 首启确认标志（隐私文案 sheet 只出现一次）
    static let consentDefaultsKey = "holo.cloudAnalysis.privacyConsented"
    static let activeTasksDefaultsKey = "holo.cloudAnalysis.activeTasks"

    private static let pollInterval: TimeInterval = 5
    // 云端复合分析实测可达 6-10 分钟（多轮工具+推理）；等待云端不该比本地紧，
    // 且等待期间用户可自由锁屏/离开（resumePolling 接续）。超时兜底取 15 分钟。
    private static let pollTimeout: TimeInterval = 15 * 60

    init(
        client: HoloCloudAnalysisClient? = nil,
        analysisService: HoloAgentAnalysisService? = nil,
        repository: ChatMessageRepository = .shared
    ) {
        self.client = client ?? HoloCloudAnalysisClient()
        self.analysisService = analysisService ?? HoloAgentAnalysisService(
            runtime: HoloLocalAgentRuntime.shared,
            scheduler: HoloAgentScheduler.shared
        )
        self.repository = repository
    }

    static var privacyConsented: Bool {
        UserDefaults.standard.bool(forKey: consentDefaultsKey)
    }

    static func markPrivacyConsented() {
        UserDefaults.standard.set(true, forKey: consentDefaultsKey)
    }

    private func persistActiveTasks() {
        let payload = activeTasks.mapValues { context in
            ["messageID": context.messageID.uuidString, "question": context.question]
        }
        UserDefaults.standard.set(payload, forKey: Self.activeTasksDefaultsKey)
    }

    private func restoreActiveTasks() {
        guard activeTasks.isEmpty,
              let payload = UserDefaults.standard.dictionary(forKey: Self.activeTasksDefaultsKey)
        else { return }
        var restored: [String: (messageID: UUID, question: String)] = [:]
        for (taskId, value) in payload {
            guard let dict = value as? [String: String],
                  let messageID = UUID(uuidString: dict["messageID"] ?? ""),
                  let question = dict["question"]
            else { continue }
            restored[taskId] = (messageID, question)
        }
        activeTasks = restored
    }

    /// 冷启动恢复：杀 App 后未领取的云端任务重新轮询（结果在云端密文暂存，≤7 天）
    func recoverIfNeeded() {
        restoreActiveTasks()
        resumePolling()
    }

    /// 云端轨道入口（ChatViewModel 在本地 runAnalysis 之前调用）。
    /// - Returns: true = 云端轨道已完整接管（成功落卡或已回落本地跑完）；
    ///   false = 云端不可用/未启用/未确认，调用方走本地轨道。
    func attempt(question: String, sourceMessageID: UUID) async -> Bool {
        guard HoloAIFeatureFlags.cloudDeepAnalysisEnabled else { return false }
        guard Self.privacyConsented else { return false }
        guard activeTasks.isEmpty else {
            // 同一时间只承载一个云端任务：并发请求直接回落本地，不排队积压
            return false
        }

        repository.updateAgentMessageProgress(sourceMessageID, status: HoloAgentChatStatus(
            title: "正在加密上传本次分析数据…",
            detail: "数据仅用于这一次分析，结束即从云端删除；结果只保存在这台设备。",
            keepsMessageStreaming: true,
            showsActivityIndicator: true
        ))

        do {
            let snapshot = try await HoloCloudAnalysisSnapshotBuilder.buildJSON()
            let started = try await client.start(question: question)
            try Task.checkCancellation()
            try await client.uploadSnapshot(taskId: started.taskId, snapshotJSON: snapshot)
            logger.info("云端任务已提交 taskId=\(started.taskId, privacy: .public)")
            await poll(taskId: started.taskId, question: question, sourceMessageID: sourceMessageID)
            return true
        } catch is CancellationError {
            await cancelActiveIfNeeded()
            return false
        } catch {
            logger.error("云端轨道失败回落本地：\(String(describing: error), privacy: .public)")
            await fallbackToLocal(question: question, sourceMessageID: sourceMessageID)
            return true
        }
    }

    /// 轮询直到终态；failed/超时回落本地。
    private func poll(taskId: String, question: String, sourceMessageID: UUID) async {
        activeTasks[taskId] = (sourceMessageID, question)
        defer { activeTasks[taskId] = nil; pollingTasks[taskId]?.cancel(); pollingTasks[taskId] = nil }

        let deadline = Date().addingTimeInterval(Self.pollTimeout)
        while Date() < deadline {
            do {
                try Task.checkCancellation()
                let status = try await client.fetchStatus(taskId: taskId)
                switch status.status {
                case "completed":
                    if let result = status.result {
                        finalizeCloudResult(result, sourceMessageID: sourceMessageID)
                        // R1 确认制：结果已落地本地，回执服务端销毁密文副本。
                        // ack 失败无妨——结果留存 ≤7 天，属可接受的隐私延迟。
                        try? await client.ackResult(taskId: taskId)
                        return
                    }
                    // completed 但无结果（已领取过的重复轮询或异常态）：回落本地重跑
                    break
                case "failed", "cancelled", "expired":
                    logger.log("云端任务终态=\(status.status, privacy: .public) 回落本地")
                    await fallbackToLocal(question: question, sourceMessageID: sourceMessageID)
                    return
                default:
                    repository.updateAgentMessageProgress(sourceMessageID, status: HoloAgentChatStatus(
                        title: "云端深度分析中…",
                        detail: "分析在云端进行，锁屏或离开 App 都不影响；完成后结果自动出现在这里。",
                        keepsMessageStreaming: true,
                        showsActivityIndicator: true
                    ))
                }
            } catch let error as APIError {
                // 任务行已被 7 天过期清理（服务端整行删除返回 404）：结果不可再领取，
                // 无限重试没有意义，立即回落本地重跑
                if case .httpError(let statusCode, _) = error, statusCode == 404 {
                    logger.log("云端任务已过期清理，立即回落本地 taskId=\(taskId, privacy: .public)")
                    activeTasks[taskId] = nil
                    await fallbackToLocal(question: question, sourceMessageID: sourceMessageID)
                    return
                }
                logger.error("轮询失败（稍后重试）：\(String(describing: error), privacy: .public)")
            } catch {
                logger.error("轮询异常（稍后重试）：\(String(describing: error), privacy: .public)")
            }
            try? await Task.sleep(for: .seconds(Self.pollInterval))
        }
        logger.log("云端任务超时回落本地 taskId=\(taskId, privacy: .public)")
        try? await client.cancel(taskId: taskId)
        await fallbackToLocal(question: question, sourceMessageID: sourceMessageID)
    }

    /// 回前台恢复轮询：锁屏期间轮询随进程挂起，云端结果在等领取。
    func resumePolling() {
        for (taskId, context) in activeTasks where pollingTasks[taskId] == nil {
            pollingTasks[taskId] = Task { [weak self] in
                await self?.poll(taskId: taskId, question: context.question, sourceMessageID: context.messageID)
            }
        }
    }

    private func cancelActiveIfNeeded() async {
        for (taskId, _) in activeTasks {
            try? await client.cancel(taskId: taskId)
        }
        activeTasks.removeAll()
        for task in pollingTasks.values { task.cancel() }
        pollingTasks.removeAll()
    }

    /// 云端结果 → 结构化卡片落消息（复用 Agent 消息管道）
    private func finalizeCloudResult(
        _ result: HoloCloudAnalysisClient.StatusResponse.CloudResult,
        sourceMessageID: UUID
    ) {
        let claims = (result.claims ?? []).compactMap { claim -> String? in
            claim.displayText ?? claim.summary
        }
        let rendered = HoloRenderedAgentResult(
            title: result.title ?? "深度分析",
            summary: result.reasoning ?? "",
            sections: claims.enumerated().map { index, text in
                HoloRenderedAgentSection(
                    title: "发现 \(index + 1)",
                    body: text,
                    confidence: nil,
                    kind: nil,
                    interpretation: nil
                )
            },
            evidenceReferences: [],
            failure: nil
        )
        repository.finalizeAgentMessage(sourceMessageID, rendered: rendered, intent: "query_analysis")
        logger.info("云端结果已落地 claims=\(claims.count, privacy: .public)")
    }

    private func fallbackToLocal(question: String, sourceMessageID: UUID) async {
        repository.updateAgentMessageProgress(sourceMessageID, status: HoloAgentChatStatusPresenter.resumingStatus())
        _ = await analysisService.runAnalysis(question: question, sourceMessageID: sourceMessageID)
    }
}
