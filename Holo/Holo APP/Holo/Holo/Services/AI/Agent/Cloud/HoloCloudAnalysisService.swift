//
//  HoloCloudAnalysisService.swift
//  Holo
//
//  云端异步分析（二期 M2b）——设备侧编排：快照聚合 → 建任务 → 上传 →
//  轮询领取 → 结果落消息。云端独占语义（2026-09-11 拍板）：深度分析
//  不再回落本地——云端失败/超时/不可用一律落诚实失败卡，由用户决定重试。
//  - 锁屏/离开 App：轮询随进程挂起暂停，云端继续执行；回前台恢复轮询
//    （HoloApp scenePhase 钩子调 resumePolling）。结果云端密文等 7 天。
//  - 隐私文案：首次云端分析需用户确认（ChatView sheet），确认后不再打扰；
//    分析期间状态卡持续展示「加密上传·仅本次·结束即删」口径。
//

import Foundation
import os.log

/// 云端轨道尝试结果（云端独占语义）：失败不回落本地，成功与失败都由云端轨道终局落卡。
nonisolated enum HoloCloudAttemptOutcome: Equatable, Sendable {
    /// 已终局：成功落分析卡，或失败落诚实失败卡
    case handled
    /// 用户点了停止
    case userCancelled
    /// 云端不可用：调用方落不可用说明卡
    case unavailable(HoloCloudUnavailableReason)
}

nonisolated enum HoloCloudUnavailableReason: Equatable, Sendable {
    /// 功能开关关闭（调试覆盖项，默认开启）
    case featureDisabled
    /// 未完成 v2 隐私确认
    case needsConsent
    /// 已有云端任务在途（单任务位）
    case busy
}

@MainActor
final class HoloCloudAnalysisService {

    static let shared = HoloCloudAnalysisService()

    private let logger = Logger(subsystem: "com.holo.app", category: "CloudAnalysis")
    private let client: HoloCloudAnalysisClient
    private let repository: ChatMessageRepository

    /// 云端任务上下文：消息、问题、任务类型（deep_analysis=多轮分析 /
    /// period_replay=周期回放单轮生成）。轮询终态按类型分流落卡。
    /// snapshotHash：回放素材指纹，period_replay 专用——云端结果落洞察档案时
    /// 作为 sourceSnapshotHash（后续复用判断「数据是否变化」的依据）。
    struct TaskContext {
        let messageID: UUID
        let question: String
        let taskType: String
        var snapshotHash: String? = nil
    }

    /// 进行中的云端任务。回前台恢复轮询用；同步持久化（杀 App 后冷启动恢复领取
    /// ——云端结果等 7 天，但没有恢复入口就等于丢失）。
    private var activeTasks: [String: TaskContext] = [:] {
        didSet { persistActiveTasks() }
    }
    private var pollingTasks: [String: Task<Void, Never>] = [:]

    /// 周期回放任务的进度/终态回调（HoloPeriodReplayCoordinator 启动时注册）：
    /// 云端轮询的进度文案与结果落卡由回放侧接管（job 状态机制与深度分析的消息
    /// 进度机制不同；恢复场景据此重建处理路径）。
    var periodReplayProgressHandler: ((UUID, _ title: String, _ detail: String) -> Void)?
    var periodReplayFinalizer: ((_ messageID: UUID, _ result: HoloCloudAnalysisClient.StatusResponse.CloudResult, _ snapshotHash: String?) -> Void)?
    /// 云端失败/超时后的本地回落入口（Coordinator 提供本地生成路径）
    var periodReplayFallbackHandler: ((_ messageID: UUID) -> Void)?
    /// 云端任务位释放（poll 结束、任务位清空）后触发：Coordinator 唤醒因
    /// 单飞排队等待的回放——云端终态不走本地 execute 的 defer 唤醒链，必须补这一枪。
    var cloudTaskSlotReleasedHandler: (() -> Void)?

    /// 隐私同意版本化：v1 = 仅分析数据上云；v2 = 周期回放素材含健康与活动摘要
    /// （2026-09-01 东林拍板方案 C）。云端轨道统一要求 v2；v1 老用户重弹一次升级确认。
    static let consentVersionDefaultsKey = "holo.cloudAnalysis.consentVersion"
    static let activeTasksDefaultsKey = "holo.cloudAnalysis.activeTasks"
    /// 旧布尔标志（v1）——迁移读取用
    private static let legacyConsentDefaultsKey = "holo.cloudAnalysis.privacyConsented"

    private static let pollInterval: TimeInterval = 5
    // 云端复合分析实测可达 6-10 分钟（多轮工具+推理）；等待云端不该比本地紧，
    // 且等待期间用户可自由锁屏/离开（resumePolling 接续）。超时兜底取 15 分钟。
    private static let pollTimeout: TimeInterval = 15 * 60

    init(
        client: HoloCloudAnalysisClient? = nil,
        repository: ChatMessageRepository = .shared
    ) {
        self.client = client ?? HoloCloudAnalysisClient()
        self.repository = repository
    }

    static var consentVersion: Int {
        if UserDefaults.standard.object(forKey: consentVersionDefaultsKey) != nil {
            return UserDefaults.standard.integer(forKey: consentVersionDefaultsKey)
        }
        // v1 布尔迁移：已同意过分析上云的用户视为 v1（需再确认一次健康扩展）
        return UserDefaults.standard.bool(forKey: legacyConsentDefaultsKey) ? 1 : 0
    }

    static var privacyConsented: Bool { consentVersion >= 2 }

    static func markPrivacyConsented() {
        UserDefaults.standard.set(2, forKey: consentVersionDefaultsKey)
    }

    private func persistActiveTasks() {
        let payload = activeTasks.mapValues { context in
            var dict: [String: String] = [
                "messageID": context.messageID.uuidString,
                "question": context.question,
                "taskType": context.taskType,
            ]
            if let snapshotHash = context.snapshotHash {
                dict["snapshotHash"] = snapshotHash
            }
            return dict
        }
        UserDefaults.standard.set(payload, forKey: Self.activeTasksDefaultsKey)
    }

    private func restoreActiveTasks() {
        guard activeTasks.isEmpty,
              let payload = UserDefaults.standard.dictionary(forKey: Self.activeTasksDefaultsKey)
        else { return }
        var restored: [String: TaskContext] = [:]
        for (taskId, value) in payload {
            guard let dict = value as? [String: String],
                  let messageID = UUID(uuidString: dict["messageID"] ?? ""),
                  let question = dict["question"]
            else { continue }
            // 旧持久化无 taskType：按深度分析处理（v1 存量任务只有这一类）
            let taskType = dict["taskType"] ?? "deep_analysis"
            restored[taskId] = TaskContext(
                messageID: messageID,
                question: question,
                taskType: taskType,
                snapshotHash: dict["snapshotHash"]
            )
        }
        activeTasks = restored
    }

    /// 冷启动恢复：杀 App 后未领取的云端任务重新轮询（结果在云端密文暂存，≤7 天）
    func recoverIfNeeded() {
        restoreActiveTasks()
        resumePolling()
    }

    /// 云端轨道入口（ChatViewModel 在本地 runAnalysis 之前调用）。
    /// - Returns: handled = 云端轨道已终局（成功落卡或失败落诚实失败卡，不再回落本地）；
    ///   userCancelled = 用户点停止；unavailable = 云端不可用，调用方落不可用说明。
    func attempt(question: String, sourceMessageID: UUID) async -> HoloCloudAttemptOutcome {
        guard HoloAIFeatureFlags.cloudDeepAnalysisEnabled else { return .unavailable(.featureDisabled) }
        guard Self.privacyConsented else { return .unavailable(.needsConsent) }
        guard activeTasks.isEmpty else {
            // 同一时间只承载一个云端任务；云端独占语义下不排队、也不回落本地
            return .unavailable(.busy)
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
            let context = TaskContext(messageID: sourceMessageID, question: question, taskType: "deep_analysis")
            // start 成功即登记（提前于快照上传）：上传中途被杀，冷启动也能恢复轮询
            // 领取，对账兜底也能据此识别「云端在途」、不按「无 job 超 90s」误判中断
            activeTasks[started.taskId] = context
            do {
                try await client.uploadSnapshot(taskId: started.taskId, snapshotJSON: snapshot)
            } catch {
                // 上传失败不进 poll（poll 的 defer 清不到），登记须自行撤回，
                // 否则任务位被永久占住、后续云端任务全部回落本地
                activeTasks[started.taskId] = nil
                throw error
            }
            logger.info("云端任务已提交 taskId=\(started.taskId, privacy: .public) type=deep_analysis")
            await poll(taskId: started.taskId, context: context)
            return .handled
        } catch is CancellationError {
            await cancelActiveIfNeeded()
            return .userCancelled
        } catch {
            logger.error("云端轨道启动失败：\(String(describing: error), privacy: .public)")
            markDeepAnalysisFailed(
                sourceMessageID: sourceMessageID,
                summary: "云端分析启动失败，本次数据未成功上云、云端无任何留存；重新提问即可重试。"
            )
            return .handled
        }
    }

    /// 周期回放云端轨道（2026-09-01 云端化统一）：
    /// 素材 = iOS 聚合的回放上下文（含健康摘要——东林拍板方案 C），复用任务底座
    /// （密文上传/轮询/推送/即焚）；完成/失败经 periodReplay 回调交回 Coordinator。
    /// - Returns: true = 云端已接管；false = 云端不可用/未同意/并发占位，调用方走本地。
    func attemptPeriodReplay(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date,
        sourceMessageID: UUID
    ) async -> Bool {
        guard HoloAIFeatureFlags.cloudDeepAnalysisEnabled else { return false }
        guard Self.privacyConsented else { return false }
        guard activeTasks.isEmpty else { return false }

        periodReplayProgressHandler?(
            sourceMessageID,
            "正在加密上传回放素材…",
            "素材仅用于这一次生成，结束即从云端删除；结果只保存在这台设备。"
        )

        do {
            // 与本地生成共用同一份聚合器（素材口径零漂移；健康摘要随素材上云）
            let builder = MemoryInsightContextBuilder()
            let (context, snapshotHash) = try await builder.build(periodType: periodType, start: start, end: end)
            let material = try JSONEncoder().encode(context)
            let started = try await client.start(question: "period_replay", taskType: "period_replay")
            try Task.checkCancellation()
            let taskContext = TaskContext(
                messageID: sourceMessageID,
                question: "period_replay",
                taskType: "period_replay",
                snapshotHash: snapshotHash
            )
            // 与深度分析同口径：start 成功即登记，上传失败自行撤回
            activeTasks[started.taskId] = taskContext
            do {
                try await client.uploadSnapshot(taskId: started.taskId, snapshotJSON: material)
            } catch {
                activeTasks[started.taskId] = nil
                throw error
            }
            logger.info("云端回放任务已提交 taskId=\(started.taskId, privacy: .public)")
            await poll(taskId: started.taskId, context: taskContext)
            return true
        } catch is CancellationError {
            await cancelActiveIfNeeded()
            return false
        } catch {
            logger.error("云端回放轨道失败回落本地：\(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// 轮询直到终态；failed/超时回落本地（按任务类型分流）。
    private func poll(taskId: String, context: TaskContext) async {
        // attempt 已在 start 成功时提前登记；冷启动恢复路径经此幂等补登
        if activeTasks[taskId] == nil { activeTasks[taskId] = context }
        defer {
            activeTasks[taskId] = nil
            pollingTasks[taskId]?.cancel()
            pollingTasks[taskId] = nil
            cloudTaskSlotReleasedHandler?()
        }

        let deadline = Date().addingTimeInterval(Self.pollTimeout)
        while Date() < deadline {
            do {
                try Task.checkCancellation()
                let status = try await client.fetchStatus(taskId: taskId)
                switch status.status {
                case "completed":
                    if let result = status.result {
                        if context.taskType == "period_replay" {
                            periodReplayFinalizer?(context.messageID, result, context.snapshotHash)
                        } else {
                            finalizeCloudResult(result, question: context.question, taskId: taskId, sourceMessageID: context.messageID)
                        }
                        // R1 确认制：结果已落地本地，回执服务端销毁密文副本。
                        // ack 失败无妨——结果留存 ≤7 天，属可接受的隐私延迟。
                        try? await client.ackResult(taskId: taskId)
                        return
                    }
                    // completed 但无结果（结果已失效或被领取）：如实落败，不再挂到超时
                    markDeepAnalysisFailed(
                        sourceMessageID: context.messageID,
                        summary: "云端结果已失效。重新提问即可重试。"
                    )
                    return
                case "failed", "cancelled", "expired":
                    logger.log("云端任务终态=\(status.status, privacy: .public) type=\(context.taskType, privacy: .public)")
                    if context.taskType == "period_replay" {
                        // 回放失败统一回落本地执行链（Coordinator 接管）：额度类失败由本地
                        // 生成路径撞额度墙后落标准额度卡，其余按本地重试语义续跑——
                        // 云端/本地同一套终态呈现。
                        periodReplayProgressHandler?(context.messageID, "云端生成中断", "正在改在本地继续…")
                        periodReplayFallbackHandler?(context.messageID)
                        return
                    }
                    let reason = status.failureReason?.isEmpty == false
                        ? "云端分析未能完成：\(status.failureReason!)。重新提问即可重试。"
                        : "云端分析未能完成。重新提问即可重试。"
                    markDeepAnalysisFailed(sourceMessageID: context.messageID, summary: reason)
                    return
                default:
                    if context.taskType == "period_replay" {
                        periodReplayProgressHandler?(
                            context.messageID,
                            "回放云端生成中…",
                            "生成在云端进行，锁屏或离开 App 都不影响；完成后结果自动出现在这里。"
                        )
                    } else {
                        repository.updateAgentMessageProgress(context.messageID, status: HoloAgentChatStatus(
                            title: "云端深度分析中…",
                            detail: "分析在云端进行，锁屏或离开 App 都不影响；完成后结果自动出现在这里。",
                            keepsMessageStreaming: true,
                            showsActivityIndicator: true
                        ))
                    }
                }
            } catch let error as APIError {
                // 任务行已被 7 天过期清理（服务端整行删除返回 404）：结果不可再领取，
                // 无限重试没有意义，如实落败
                if case .httpError(let statusCode, _) = error, statusCode == 404 {
                    logger.log("云端任务已过期清理 taskId=\(taskId, privacy: .public)")
                    activeTasks[taskId] = nil
                    if context.taskType == "period_replay" {
                        periodReplayFallbackHandler?(context.messageID)
                    } else {
                        markDeepAnalysisFailed(
                            sourceMessageID: context.messageID,
                            summary: "云端任务已过期（结果最多保留 7 天）。重新提问即可重试。"
                        )
                    }
                    return
                }
                logger.error("轮询失败（稍后重试）：\(String(describing: error), privacy: .public)")
            } catch is CancellationError {
                // 用户已取消：立即退出轮询，不做僵尸轮询烧电烧流量（sleep 吞取消由下轮 checkCancellation 兜住）
                return
            } catch {
                logger.error("轮询异常（稍后重试）：\(String(describing: error), privacy: .public)")
            }
            try? await Task.sleep(for: .seconds(Self.pollInterval))
        }
        logger.log("云端任务等待超时 taskId=\(taskId, privacy: .public)")
        try? await client.cancel(taskId: taskId)
        if context.taskType == "period_replay" {
            periodReplayFallbackHandler?(context.messageID)
        } else {
            markDeepAnalysisFailed(
                sourceMessageID: context.messageID,
                summary: "等待云端分析超时（15 分钟）。重新提问即可重试。"
            )
        }
    }

    /// 是否有云端任务在途（深度分析或回放）。Coordinator 的本地单飞检查
    /// 必须同时覆盖它：云端回放进行中时，新回放不得绕过排队并行本地生成。
    var hasActiveTask: Bool {
        !activeTasks.isEmpty
    }

    /// 指定消息是否有在途云端任务（轮询中，或冷启动恢复后待领取）。
    /// HoloAgentAnalysisService 的对账兜底据此豁免：云端轨道刻意不落本地 job、
    /// 真实耗时可达 6-10 分钟，不能按「无 job 超 90s」误判为「没真正开始」。
    func isActiveTask(forMessageID messageID: UUID) -> Bool {
        activeTasks.values.contains { $0.messageID == messageID }
    }

    /// 云端轨道快查（不触发上云）：flag 开启 + 隐私 v2 已同意 + 无并发任务。
    /// Coordinator 据此决定回放先走云端还是本地；真正接管以 attempt 系列的完整检查为准。
    func canTakeCloudTask() -> Bool {
        HoloAIFeatureFlags.cloudDeepAnalysisEnabled && Self.privacyConsented && activeTasks.isEmpty
    }

    /// 回前台恢复轮询：锁屏期间轮询随进程挂起，云端结果在等领取。
    func resumePolling() {
        for (taskId, context) in activeTasks where pollingTasks[taskId] == nil {
            pollingTasks[taskId] = Task { [weak self] in
                await self?.poll(taskId: taskId, context: context)
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

    /// 云端结果 → 结构化卡片落消息（复用 Agent 消息管道）。
    /// 渲染规则与本地轨道对齐（2026-08-31 验收修复）：
    /// - summary 用 claims 人话拼接，不再把模型内部 reasoning（含工具名/协议术语）直接上屏；
    /// - scope 标注快照时间窗（卡片展示「近N天」口径）；
    /// - 证据引用由云端回传的 evidence 原料翻译成中文口径（metric）与行样本（rows）；
    /// - claim 文本走与本地同一条内部 token 防线（含 metricKey/工具名的整条丢弃）。
    private func finalizeCloudResult(
        _ result: HoloCloudAnalysisClient.StatusResponse.CloudResult,
        question: String,
        taskId: String,
        sourceMessageID: UUID
    ) {
        let claims = (result.claims ?? []).compactMap { claim -> String? in
            let text = (claim.displayText ?? claim.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !HoloAnswerCoverageVerifier.containsInternalToken(text) else { return nil }
            return text
        }
        let sections = claims.enumerated().map { index, text in
            HoloRenderedAgentSection(title: "发现 \(index + 1)", body: text, confidence: nil, kind: nil, interpretation: nil)
        }
        let summary = claims.isEmpty
            ? "本期暂无显著观察"
            : claims.joined(separator: "；")
        // 证据收敛：云端证据池是「查过什么就有什么」，按结论引用（claims.evidenceIDs）
        // 过滤后上屏，探索阶段带出的无关分类（问电费带出房租/红包）不再混进核对列表
        let evidencePool = result.evidence ?? []
        let citedEvidence = HoloCloudEvidencePresenter.citedEvidence(from: evidencePool, claims: result.claims ?? [])
        var rendered = HoloRenderedAgentResult(
            title: result.title ?? "深度分析",
            summary: summary,
            sections: sections,
            evidenceReferences: HoloCloudEvidencePresenter.evidenceReferences(from: citedEvidence),
            failure: nil,
            question: question,
            scope: HoloRenderedAnswerScope(
                label: "近\(HoloCloudAnalysisSnapshotBuilder.defaultHistoryDays)天",
                start: nil,
                end: nil,
                snapshotCutoffAt: nil,
                attribution: nil
            ),
            dataSamplePreview: HoloCloudEvidencePresenter.dataSamplePreview(from: citedEvidence)
        )
        // 追问血统身份（方案B）：云端结果不落本地 Job/Result 档案，用「cloud-任务ID」作本地等价编号——
        // 报告页据此显示追问入口，追问记录据此挂载血统；cloud- 前缀与本地 UUID 空间天然不冲突
        let cloudIdentity = "cloud-\(taskId)"
        rendered.agentJobID = cloudIdentity
        rendered.agentResultID = cloudIdentity
        rendered.rootUserQuestion = question
        repository.finalizeAgentMessage(sourceMessageID, rendered: rendered, intent: "query_analysis")
        logger.info("云端结果已落地 claims=\(claims.count, privacy: .public) evidence=\(citedEvidence.count, privacy: .public)/池\(evidencePool.count, privacy: .public)")
    }

    /// 云端独占语义的诚实终局：把深度分析消息落为可辨识的失败卡（与本地
    /// analysisFailed 卡同构），不再回落本地轨道（2026-09-11 拍板）。
    private func markDeepAnalysisFailed(sourceMessageID: UUID, summary: String) {
        let title = "云端深度分析未完成"
        let rendered = HoloRenderedAgentResult(
            title: title,
            summary: summary,
            sections: [],
            evidenceReferences: [],
            failure: .analysisFailed
        )
        let agentResultJSON = (try? JSONEncoder().encode(rendered))
            .flatMap { String(data: $0, encoding: .utf8) }
        repository.finalizeMessage(
            sourceMessageID,
            finalContent: [title, summary].joined(separator: "\n"),
            intent: "query_analysis",
            extractedDataJSON: nil,
            parsedBatchJSON: nil,
            executionBatchJSON: nil,
            analysisContextJSON: nil,
            rawLogJSON: nil,
            agentResultJSON: agentResultJSON
        )
    }
}
