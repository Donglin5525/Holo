//
//  ChatViewModel.swift
//  Holo
//
//  对话核心 ViewModel
//  管理消息收发、意图识别、流式对话
//

import Foundation
import Combine
import CoreData
import os.log

@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published var messages: [ChatMessageViewData] = []
    @Published var inputText: String = "" {
        didSet {
            UserDefaults.standard.set(inputText, forKey: Self.inputDraftKey)
        }
    }
    @Published var isStreaming: Bool = false

    /// 云端分析首次启用前的隐私说明 sheet（只出现一次，确认后下次发起生效）
    @Published var showCloudPrivacySheet = false
    /// 是否存在仍在等待/执行中的 AI 消息（消息级 streaming）。
    /// Agent 深度分析等待网络/系统资源期间，全局输入锁（isStreaming）已解锁、
    /// 但停止键必须保持可见（cancelStreaming 取消等待任务并定稿消息）。
    var hasActiveStreamingMessage: Bool {
        messages.contains { $0.isStreaming }
    }
    /// 流式超 90s 未完成时的「AI 还在工作」提示（watchdog 第一段写入，结束/取消时清空）
    @Published var streamingStatusHint: String?
    /// AI 数据处理授权未开启时，点发送触发此提示（替代静默失败）
    @Published var showConsentPrompt: Bool = false
    @Published var streamingText: String = ""
    @Published var errorMessage: String?
    @Published var memoryNotice: String?
    @Published var isConfigured: Bool = false
    @Published var isLoadingConfig: Bool = false
    @Published private(set) var hasFinishedSetup: Bool = false
    @Published var hasLoadedMessages: Bool = false
    @Published private(set) var didTimeoutLoadingConfig: Bool = false
    @Published var hasEarlierSessions: Bool = false
    @Published var isLoadingEarlierSession: Bool = false
    @Published var earlierHistoryLoadFailed: Bool = false
    /// 用户从某份 Agent Result 发起的短时追问锚点；发送、取消或离开页面后清空。
    @Published var continuationDraft: HoloAgentContinuationDraft?

    // MARK: - Private

    private let logger = Logger(subsystem: HoloLog.subsystem, category: "ChatViewModel")
    /// 首屏只装载足够覆盖约 3～5 屏的内容，降低复杂卡片首次布局的尖峰。
    let initialHistoryLimit = 24
    /// 输入草稿持久化 key（退出界面再回来恢复未发送的文字）
    private static let inputDraftKey = "holo_chat_inputDraft"
    var chatRepo: ChatMessageRepository?
    private var currentTask: Task<Void, Never>?
    /// 当前请求对应的占位消息；用于停止时立即关闭持久化 streaming 状态，
    /// 并防止已经取消的旧 Task 晚返回后覆盖下一次请求的 UI。
    private var activeStreamingMessageID: UUID?
    var provider: AIProvider
    private let coordinator: ConversationCoordinator
    /// 本地深度 Agent 分析服务（Phase 6.2 灰度，agentRuntimeEnabled 把关）
    let analysisService = HoloAgentAnalysisService()
    var repositoryBootstrapTask: Task<Void, Never>?
    var confirmingItemIds: Set<String> = []
    var repoMessagesCancellable: AnyCancellable?
    var metadataLoadPendingIds: Set<UUID> = []
    var metadataLoadTask: Task<Void, Never>?
    var cancellables = Set<AnyCancellable>()
    private var streamingWatchdogTask: Task<Void, Never>?
    private let usesInjectedProvider: Bool
    private var coreDataObserver: NSObjectProtocol?

    // MARK: - Capability Launchpad

    /// 空状态卡片使用的能力入口（含 onboarding 引导等，按用户状态动态生成）。
    @Published private(set) var emptyStateCapabilities: [HoloAICapability] = []

    /// 输入框上方常驻能力行使用的能力入口（今日状态/最近分析/规划目标等常驻项）。
    @Published private(set) var persistentCapabilities: [HoloAICapability] = HoloAICapabilityProvider.persistentCapabilities()

    /// 是否处于真正的空会话（历史消息加载完成且无消息）。
    /// 用于区分「加载中的假空」与「加载完成的真空」，避免空状态 UI 闪烁出现又消失。
    var isTrulyEmptyConversation: Bool {
        hasLoadedMessages && messages.isEmpty
    }

    /// 根据当前用户状态刷新能力入口（onboarding、数据充足度、记忆状态等）。
    /// 在 setup 完成、消息加载完成后调用，让 Provider 的动态分支真正生效。
    func refreshCapabilities() {
        let context = HoloAICapabilityProviderContext(
            hasSufficientData: hasSufficientDataForCapabilities,
            hasLongTermMemories: hasLongTermMemoriesForCapabilities,
            hasLongTermCandidates: hasLongTermCandidatesForCapabilities,
            onboardingCompleted: LightweightOnboardingSettings.isCompleted
        )
        emptyStateCapabilities = HoloAICapabilityProvider.emptyStateCapabilities(context: context)
        persistentCapabilities = HoloAICapabilityProvider.persistentCapabilities(context: context)
    }

    /// 数据/记忆状态判定（目前保守返回 false，后续可接入记忆仓库细化）。
    private var hasSufficientDataForCapabilities: Bool { false }
    private var hasLongTermMemoriesForCapabilities: Bool { false }
    private var hasLongTermCandidatesForCapabilities: Bool { false }

    // MARK: - Goal Planning

    @Published var activeGoalPlanningSession: GoalPlanningSession?
    @Published var goalDraftForReview: GoalDraft?
    @Published var showGoalDraftReview = false
    /// 周期回放选择 Sheet（从记忆长廊迁移而来）
    @Published var showPeriodReplayPicker = false

    // MARK: - 分析场景面板（甲方案：深度分析胶囊点开场景目录）

    /// 「深度分析」胶囊展开的场景面板。点胶囊切换，选场景即预填问句（不发送）。
    @Published var showAnalysisScenarioPanel = false
    /// 最近一次场景预填（用于输入框上方的来源提示；用户改动问句后提示自然消失）
    private(set) var lastScenarioPrefill: (title: String, question: String)?

    /// 预填来源提示：仅当输入框内容仍是预填原句时显示——
    /// 用户改写、清空或发送后自动消失，无需手动清理。
    var activeScenarioPrefillTitle: String? {
        guard let prefill = lastScenarioPrefill,
              inputText == prefill.question,
              !inputText.isEmpty else { return nil }
        return prefill.title
    }

    func selectAnalysisScenario(_ scenario: AnalysisScenario) {
        inputText = scenario.question
        showAnalysisScenarioPanel = false
        lastScenarioPrefill = (title: scenario.title, question: scenario.question)
    }

    let goalPlanningCoordinator = GoalPlanningCoordinator()

    // MARK: - Init

    /// init 不做任何 I/O 操作，避免 Core Data / Keychain 阻塞主线程
    deinit {
        if let observer = coreDataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        analysisReconcileTask?.cancel()
    }
    init(provider: AIProvider? = nil, coordinator: ConversationCoordinator? = nil) {
        self.usesInjectedProvider = provider != nil
        self.provider = provider ?? HoloBackendEnvironment.makeDefaultProvider()
        self.coordinator = coordinator ?? ConversationCoordinator()
        checkConfiguration()
        if KeychainService.hasCachedAIConfig {
            isConfigured = true
        }
        // 恢复未发送的输入草稿
        inputText = UserDefaults.standard.string(forKey: Self.inputDraftKey) ?? ""
    }

    /// 在 .task 中调用，延迟初始化仓库和加载配置
    /// 流程：先读取 Keychain 配置，再在后台补加载消息仓库
    func setup() async {
        if hasFinishedSetup { return }
        bootstrapChatRepositoryIfNeeded()
        startAnalysisReconcileLoop()

        if !usesInjectedProvider {
            provider = HoloBackendEnvironment.makeDefaultProvider()
        }
        isConfigured = true
        isLoadingConfig = false
        didTimeoutLoadingConfig = false
        hasFinishedSetup = true
        // 初始化时按当前 onboarding 状态生成空状态卡片内容（消息加载后再刷新一次）
        refreshCapabilities()
        logger.info("AI 已配置为 Holo 后端网关")
    }

    // MARK: - Analysis Reconcile Loop（P0：悬挂「分析中」兜底）

    /// 页面驻留期间的低频对账：无悬挂分析消息时单次轻量查询即返回，
    /// 有则交 analysisService 处理三类悬挂（超截止终结 / 进度刷新 / 无 job 落地中断）。
    /// 一次性孤儿清理（bootstrap 时跑一次 + 180s 宽限）接不住「强杀后短时间内
    /// 重进并停留在聊天页」的场景——用户会看着「分析中」永远转圈。
    private var analysisReconcileTask: Task<Void, Never>?

    private func startAnalysisReconcileLoop() {
        guard analysisReconcileTask == nil else { return }
        analysisReconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self else { return }
                await self.analysisService.reconcileStalledAnalysisMessages()
            }
        }
    }

    // MARK: - Send Message

    func sendMessage() async {
        // 一条流式回复进行中时禁止再发：并发发送会互相覆盖 currentTask/activeStreamingMessageID，
        // 两条气泡还会显示同一段交叉串流内容（发送按钮已切换为停止键，这里挡住键盘回车等旁路入口）
        guard !isStreaming else { return }
        await retryConfigurationLoadIfNeeded()
        await ensureChatRepositoryReady()
        guard let chatRepo = chatRepo else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard HoloAIFeatureFlags.aiDataProcessingConsentGranted else {
            showConsentPrompt = true
            return
        }

        inputText = ""
        errorMessage = nil

        // 目标规划分流
        if let session = activeGoalPlanningSession, session.status == .collecting {
            await handleGoalPlanningReply(text, session: session)
            return
        }

        if let session = activeGoalPlanningSession, session.status == .draftReady {
            errorMessage = String(localized: "目标草案正在等待确认，请先处理当前草案。")
            inputText = text
            return
        }

        // 1. 保存用户消息
        let userMessageId = chatRepo.addMessage(role: "user", content: text)

        // 2. 创建 AI 占位消息
        let aiMessageId = chatRepo.addStreamingMessage(role: "assistant", parentMessageId: userMessageId)

        // 3. 处理用户输入
        isStreaming = true
        streamingText = ""
        activeStreamingMessageID = aiMessageId

        startStreamingWatchdog(aiMessageId: aiMessageId)

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            var keepsAgentMessageActive = false

            do {
                // 构建上下文，并注入「最近对话关联的任务」（modify_task_items 意图识别 + taskId 补全）
                var userContext = await UserContextBuilder.shared.buildContext()
                userContext.recentLinkedTask = self.resolveRecentLinkedTask()

                // 活跃规划会话检测：过滤流式占位，只看已定稿的历史消息
                let activePlanningRunID = self.latestUnresolvedContextPlanRunID()

                // ENERGY: 锁定检查预留位

                // 用户明确从 Result 发起或当前会话存在高置信承接词时，
                // 直接进 Agent，不再让一次意图识别失败切断追问链。
                let resolvedContinuation = self.resolvedContinuationDraft(for: text)
                if resolvedContinuation != nil {
                    self.continuationDraft = nil
                }
                let continuation = resolvedContinuation?.relation == .executeFromResult
                    ? nil
                    : resolvedContinuation
                let processResult: ConversationProcessResult
                if continuation != nil {
                    processResult = ConversationProcessResult(
                        finalText: "",
                        parsedBatch: nil,
                        executionBatch: nil,
                        firstIntent: .queryAnalysis,
                        firstExtractedData: nil,
                        shouldStreamChat: false,
                        analysisContext: nil,
                        flexibleQueryResult: nil,
                        shouldRouteToAgent: true
                    )
                } else if let actionDraft = resolvedContinuation,
                          actionDraft.relation == .executeFromResult {
                    if let actionCommand = self.recommendationActionCommand(
                        for: actionDraft,
                        userText: text
                    ) {
                        let handoff = try await self.coordinator.process(
                            text: actionCommand,
                            userContext: userContext,
                            provider: self.provider
                        )
                        // 结果建议的执行面只允许“单个创建待办”进入现有确认卡。
                        // 如果模型把建议正文误识别成删除、记账、多动作或查询，一律拒绝交付。
                        let isSingleTaskDraft = handoff.parsedBatch?.items.count == 1
                            && handoff.firstIntent == .createTask
                            && !handoff.shouldRouteToAgent
                            && !handoff.shouldStreamChat
                        processResult = isSingleTaskDraft
                            ? handoff
                            : self.safeActionHandoffFailure()
                    } else {
                        processResult = self.recommendationSelectionClarification(for: actionDraft)
                    }
                } else {
                    // 通过 Coordinator 处理（支持多动作）
                    processResult = try await self.coordinator.process(
                        text: text,
                        userContext: userContext,
                        provider: self.provider,
                        activePlanningRunID: activePlanningRunID
                    )
                }
                try Task.checkCancellation()

                // 个人情境规划产出：草案卡消息（只读，不写业务事项；保存走卡片按钮）
                if let planOutcome = processResult.contextPlanOutcome {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    let draftJSON = (try? encoder.encode(planOutcome.draft))
                        .flatMap { String(data: $0, encoding: .utf8) }
                    self.chatRepo?.finalizeMessage(
                        aiMessageId,
                        finalContent: planOutcome.draft.answerText,
                        intent: AIIntent.contextualPlanning.rawValue,
                        extractedDataJSON: nil,
                        parsedBatchJSON: nil,
                        executionBatchJSON: nil,
                        analysisContextJSON: nil,
                        rawLogJSON: nil,
                        contextPlanJSON: draftJSON,
                        messageType: .contextPlan
                    )
                    self.concludeStreamingSession(aiMessageId: aiMessageId)
                    return
                }

                // ENERGY: 能量检查预留位

                // 深度 Agent 分流（Phase 6.2）：命中则启动本地 Agent，不走流式分析
                if processResult.shouldRouteToAgent {
                    // 额度预检（先验票再进场）：deepAnalysis 池余量为 0 时直接落地付费墙卡片，
                    // 不进「分析中」转圈态。余量在每次 AI 请求成功后自动刷新，一般准确；
                    // 数据缺失（nil）或刚好过期时放行，由后端拦截 + 终态额度卡片兜底。
                    if let remaining = HoloEntitlementState.shared.quotas["deepAnalysis"]?.remaining,
                       remaining <= 0 {
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: HoloQuotaError.deepAnalysisExhaustedMessage(
                                isPlusActive: HoloEntitlementState.shared.isPlusActive
                            ),
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: nil,
                            parsedBatchJSON: nil,
                            executionBatchJSON: nil,
                            analysisContextJSON: nil,
                            rawLogJSON: nil,
                            agentResultJSON: nil,
                            messageType: .quotaExhausted
                        )
                        self.concludeStreamingSession(aiMessageId: aiMessageId)
                        return
                    }
                    // 周计划：数据充分度前置（不足时不烧 Agent，诚实提示缺什么）
                    let isWeeklyPlanning = processResult.firstIntent == .weeklyPlanning
                    if isWeeklyPlanning {
                        let check = LifePlanGenerationService.checkDataSufficiency()
                        guard check.sufficient else {
                            let missing = check.missing.joined(separator: "、")
                            self.chatRepo?.finalizeMessage(
                                aiMessageId,
                                finalContent: String(localized: "这周你的记录还不够，我先不装懂。\n\n近 7 天还缺：\(missing)。再记几天，我就能给出有依据的本周重点，而不是一份谁都能用的通用计划。"),
                                intent: processResult.firstIntent?.rawValue,
                                extractedDataJSON: nil,
                                parsedBatchJSON: nil,
                                executionBatchJSON: nil,
                                analysisContextJSON: nil,
                                rawLogJSON: nil
                            )
                            self.concludeStreamingSession(aiMessageId: aiMessageId)
                            return
                        }
                    }
                    self.streamingWatchdogTask?.cancel()
                    self.streamingWatchdogTask = nil
                    self.chatRepo?.setAnalysisLoadingState(
                        aiMessageId,
                        intent: processResult.firstIntent?.rawValue ?? "query_analysis",
                        analysisContext: nil
                    )
                    let initialStatus = HoloAgentChatStatus(
                    title: isWeeklyPlanning ? String(localized: "Holo 正在为你的本周计划分析数据…") : String(localized: "Holo 正在深度分析中…"),
                    detail: String(localized: "可以离开当前页面；系统支持时会继续处理，中止后会保留进度并在回到 App 后恢复。"),
                        keepsMessageStreaming: true,
                        showsActivityIndicator: true
                    )
                    self.chatRepo?.updateAgentMessageProgress(aiMessageId, status: initialStatus)
                    self.streamingText = initialStatus.messageContent
                    // P2 步骤实时化：等待期间低频轮询当前步骤文案，前台卡片不再静止
                    // （2s 间隔本地读，成本可忽略；终态由下方主路径落地，轮询天然停止）
                    let progressPoller = Task { [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(2))
                            guard let self else { return }
                            await self.analysisService.refreshLiveProgress(sourceMessageID: aiMessageId)
                        }
                    }
                    // 云端异步轨道（二期 M2b）：flag 开启且已确认隐私文案时优先上云，
                    // 失败自动回落本地（attempt 内闭环）；周计划快照仍走本地轨道。
                    // 首次（未确认）只弹说明 sheet，本次仍走本地，下次生效。
                    if !isWeeklyPlanning, continuation == nil,
                       HoloAIFeatureFlags.cloudDeepAnalysisEnabled {
                        if !HoloCloudAnalysisService.privacyConsented {
                            self.showCloudPrivacySheet = true
                        } else {
                            // 云端轨道启动即请求通知授权+注册 APNs（「分析完成」推送）；
                            // 权限拒绝/注册失败不影响分析本身（打开 App 照常领取结果）
                            HoloCloudPushTokenService.shared.requestAuthorizationAndRegister()
                            let cloudHandled = await HoloCloudAnalysisService.shared.attempt(
                                question: text,
                                sourceMessageID: aiMessageId
                            )
                            if cloudHandled {
                                progressPoller.cancel()
                                self.concludeStreamingSession(aiMessageId: aiMessageId)
                                return
                            }
                            // 云端轨道因用户点「停止」而退出（attempt 返回 false）：
                            // 取消语义到此为止，不得再启动本地全量分析（结果不展示但额度照烧）
                            try Task.checkCancellation()
                        }
                    }
                    let rendered = await self.analysisService.runAnalysis(
                        question: isWeeklyPlanning
                            ? "汇总我最近一周的生活数据快照：任务完成与逾期、习惯打卡、支出结构、睡眠与活动、想法主题；列出其中显著的变化与异常（附数据依据）。不需要深挖单个域，快照汇总即可，供制定本周生活计划使用"
                            : text,
                        trigger: isWeeklyPlanning ? .weeklyPlanning : .userQuestion,
                        sourceMessageID: aiMessageId,
                        continuation: isWeeklyPlanning ? nil : continuation?.request
                    )
                    progressPoller.cancel()
                    try Task.checkCancellation()
                    // 额度耗尽走专属卡片（与普通聊天路径一致）：档位限制不是系统错误，
                    // 渲染 QuotaExhaustedChatCard + "了解 Holo Plus"入口，不写 agentResultJSON。
                    if case .quotaExhausted(let userMessage)? = rendered.failure {
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: userMessage,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: nil,
                            parsedBatchJSON: nil,
                            executionBatchJSON: nil,
                            analysisContextJSON: nil,
                            rawLogJSON: nil,
                            agentResultJSON: nil,
                            messageType: .quotaExhausted
                        )
                    } else if case .continuationUnavailable(let userMessage)? = rendered.failure {
                        // 父结果不可用时不能降级成普通聊天后声称已经承接；
                        // 诚实告知用户需要重新分析。
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: userMessage,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: nil,
                            parsedBatchJSON: nil,
                            executionBatchJSON: nil,
                            analysisContextJSON: nil,
                            rawLogJSON: nil,
                            agentResultJSON: nil
                        )
                    } else if case .executionSuspended = rendered.failure {
                        // 系统结束的是后台执行租约，不是用户任务本身。保留同一条 Agent 消息和
                        // 停止入口，等待前台恢复链从 checkpoint 继续；不得额外发普通 chat。
                        let preserved = await self.analysisService.syncRecoverableChatMessages(repository: self.chatRepo)
                        // 恢复代次可能已在原请求返回前完成。只有同步后仍是活跃态才继续转圈；
                        // completed 已回填为卡片时必须立即结束 streaming，避免 UI 假性卡住。
                        keepsAgentMessageActive = preserved.contains(aiMessageId)
                    } else if case .analysisFailed = rendered.failure {
                        // 深度分析失败必须诚实落为可重试的 Agent 卡片。普通 chat 没有同一套
                        // 数据读取与证据校验能力，拿它兜底会制造“看似回答、实际无依据”的双答案。
                        let fallbackText = [rendered.title, rendered.summary]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: fallbackText,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: nil,
                            parsedBatchJSON: nil,
                            executionBatchJSON: nil,
                            analysisContextJSON: nil,
                            rawLogJSON: nil,
                            agentResultJSON: Self.encodeAgentResult(rendered)
                        )
                    } else if isWeeklyPlanning {
                        // 周计划：Agent 分析完成 → 生成服务组装结构化计划 → 计划卡消息
                        await self.finalizeWeeklyPlanning(
                            aiMessageId: aiMessageId,
                            rendered: rendered,
                            intent: processResult.firstIntent?.rawValue,
                            userContext: userContext
                        )
                    } else {
                        // 不再拍扁成单段文本：结构化存 agentResultJSON，由 AgentDeepAnalysisCard 渲染
                        // fallback 文本用于历史回看/解码失败时退化展示（标题 + 摘要）
                        let fallbackText = [rendered.title, rendered.summary]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: fallbackText,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: nil,
                            parsedBatchJSON: nil,
                            executionBatchJSON: nil,
                            analysisContextJSON: nil,
                            rawLogJSON: nil,
                            agentResultJSON: Self.encodeAgentResult(rendered)
                        )
                    }
                } else if processResult.shouldStreamChat {
                    // 发前预检：chat 池余量为 0 时不再发起流式请求（省一次必败的
                    // 网络往返和转圈等待），直接落额度卡片。余量缺失（nil）放行，
                    // 由后端拦截 + 934 行额度终态卡片兜底。
                    if let remaining = HoloEntitlementState.shared.quotas["chat"]?.remaining,
                       remaining <= 0 {
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: HoloQuotaError.chatExhaustedMessage(
                                isPlusActive: HoloEntitlementState.shared.isPlusActive
                            ),
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: nil,
                            parsedBatchJSON: nil,
                            executionBatchJSON: nil,
                            analysisContextJSON: nil,
                            rawLogJSON: nil,
                            messageType: .quotaExhausted
                        )
                        self.concludeStreamingSession(aiMessageId: aiMessageId)
                        return
                    }
                    if let analysisContext = processResult.analysisContext {
                        // 立即设置 intent + analysisContext → 渲染 loading 卡片
                        self.chatRepo?.setAnalysisLoadingState(
                            aiMessageId,
                            intent: processResult.firstIntent?.rawValue,
                            analysisContext: analysisContext
                        )

                        // 分析查询路径：零历史消息，独立 system context
                        let contextJSON = Self.encodeAnalysisContext(analysisContext)
                        let memorySummary = await HoloMemorySummaryProvider.selectRelevantSummary(
                            purpose: .recentAnalysis,
                            queryText: text,
                            requireQueryMatch: true,
                            consumer: .analysis
                        )
                        let memoryEnvelope = HoloMemoryContextEnvelope.render(memorySummary)
                        let analysisSystemContext = [contextJSON, memoryEnvelope.isEmpty ? nil : memoryEnvelope]
                            .compactMap { $0 }
                            .joined(separator: "\n\n")

                        // 传递实际 userContext（含 profileSnapshot）而非 empty
                        // Provider 内部会从 userContext.profileSnapshot 读取 profile 注入
                        let stream = self.provider.chatStreaming(
                            messages: [],
                            userContext: userContext,
                            systemContextOverride: analysisSystemContext,
                            promptType: .analysisPrompt
                        )

                        var fullText = ""
                        var lastFlush = ContinuousClock.now
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            fullText += chunk
                            // 节流：合并到 ~30fps，避免每个 token 都触发整列表重绘
                            let now = ContinuousClock.now
                            if now - lastFlush > .milliseconds(33) {
                                self.streamingText = HoloMemoryUsageMarker.visibleTextWhileStreaming(fullText)
                                lastFlush = now
                            }
                        }
                        // 流式结束前补齐最终累积文本，保证 consume 前的可见内容完整
                        self.streamingText = HoloMemoryUsageMarker.visibleTextWhileStreaming(fullText)

                        let markerResult = self.consumeMemoryUsageMarker(
                            from: fullText,
                            availableMemoryIDs: memorySummary.sourceIDs,
                            memoryEntries: memorySummary.entries,
                            channel: .analysis
                        )
                        self.streamingText = markerResult.cleanText
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: markerResult.cleanText,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: Self.encodeExtractedData(
                                processResult.firstExtractedData,
                                usedMemoryIDs: markerResult.usedMemoryIDs
                            ),
                            parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
                            executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch),
                            analysisContextJSON: contextJSON,
                            rawLogJSON: nil
                        )
                    } else {
                        // 标准查询路径 → 流式对话
                        guard let chatRepo = self.chatRepo else { return }
                        let historyDTOs = await chatRepo.loadRecentDTOsAsync(limit: 20)
                        let memorySummary = await HoloMemorySummaryProvider.selectRelevantSummary(
                            purpose: nil,
                            queryText: text,
                            requireQueryMatch: true,
                            consumer: .chat
                        )
                        var contextualUserContext = userContext
                        contextualUserContext.memorySummary = memorySummary
                        let stream = self.provider.chatStreaming(
                            messages: historyDTOs,
                            userContext: contextualUserContext
                        )

                        var fullText = ""
                        var lastFlush = ContinuousClock.now
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            fullText += chunk
                            // 节流：合并到 ~30fps，避免每个 token 都触发整列表重绘
                            let now = ContinuousClock.now
                            if now - lastFlush > .milliseconds(33) {
                                self.streamingText = HoloMemoryUsageMarker.visibleTextWhileStreaming(fullText)
                                lastFlush = now
                            }
                        }
                        // 流式结束前补齐最终累积文本，保证 consume 前的可见内容完整
                        self.streamingText = HoloMemoryUsageMarker.visibleTextWhileStreaming(fullText)

                        let markerResult = self.consumeMemoryUsageMarker(
                            from: fullText,
                            availableMemoryIDs: memorySummary.sourceIDs,
                            memoryEntries: memorySummary.entries,
                            channel: .chat
                        )
                        self.streamingText = markerResult.cleanText
                        // 空流兜底：后端正常关流但零内容（上游偶发空回复）时落兜底文案，
                        // 不把空白存成消息（历史缺陷：空白正文+意图标签悬空，用户以为坏机）
                        let finalContent = markerResult.cleanText.isEmpty
                            ? String(localized: "抱歉，这次没拿到回复，请再试一次")
                            : markerResult.cleanText
                        // 原子化写入：结束流式 + 元数据，单次 save + 单次 snapshot
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: finalContent,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: Self.encodeExtractedData(
                                processResult.firstExtractedData,
                                usedMemoryIDs: markerResult.usedMemoryIDs
                            ),
                            parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
                            executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch),
                            rawLogJSON: nil
                        )
                    }
                } else {
                    // 操作结果 / 澄清 / 错误 → 原子化写入
                    self.chatRepo?.finalizeMessage(
                        aiMessageId,
                        finalContent: processResult.finalText,
                        intent: processResult.firstIntent?.rawValue,
                        extractedDataJSON: Self.encodeExtractedData(
                            processResult.firstExtractedData,
                            flexibleQueryResult: processResult.flexibleQueryResult
                        ),
                        parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
                        executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch),
                        rawLogJSON: nil
                    )
                }

                #if DEBUG || INTERNAL_DIAGNOSTICS
                let internalRequestIds = [
                    processResult.intentCallLog?.requestId,
                    self.provider.lastCallLog?.requestId
                ].compactMap { $0 }
                await HoloInternalLogService.shared.capture(
                    messageId: aiMessageId,
                    requestIds: Array(Set(internalRequestIds))
                )
                #endif

                // ENERGY: 能量恢复预留位

            } catch is CancellationError {
                // 用户点击停止时已经同步关闭这条消息；旧 Task 晚返回不得覆盖后续请求。
                if self.activeStreamingMessageID == aiMessageId {
                    self.chatRepo?.finishStreaming(aiMessageId, finalContent: self.streamingText)
                }
            } catch {
                // 这条请求已被用户停止，或已经有更新的请求接管输入栏。
                // URLSession 取消偶尔会被上游包装成普通网络错误，不能再把旧错误写回界面。
                guard self.activeStreamingMessageID == aiMessageId else { return }
                self.logger.error("AI 处理失败：\(error.localizedDescription)")

                // 配额耗尽走专属提示：档位限制不是系统错误，用 quotaExhausted 类型标记，
                // 渲染层据此展示柔和的额度卡片 + 「了解 Holo Plus」入口，而非红色错误样式。
                // 不提前 return：跳过末尾收尾会被 watchdog 300s 覆盖成「AI 响应超时」。
                if let quotaError = error as? HoloQuotaError {
                    self.errorMessage = quotaError.userMessage
                    self.chatRepo?.finalizeMessage(
                        aiMessageId,
                        finalContent: quotaError.userMessage,
                        intent: nil,
                        extractedDataJSON: nil,
                        parsedBatchJSON: nil,
                        executionBatchJSON: nil,
                        messageType: .quotaExhausted
                    )
                } else {
                    let userMessage = HoloAIUserErrorMapper.message(for: error)
                    self.errorMessage = userMessage

                    // 保留已接收的部分内容，追加错误提示而非完全覆盖
                    let partialContent = self.streamingText
                    let finalContent: String
                    if partialContent.isEmpty {
                        finalContent = userMessage
                    } else {
                        finalContent = partialContent + String(localized: "\n\n处理中断：\(userMessage)")
                    }

                    self.chatRepo?.finishStreaming(aiMessageId, finalContent: finalContent)
                }
            }

            if self.activeStreamingMessageID == aiMessageId {
                self.concludeStreamingSession(
                    aiMessageId: aiMessageId,
                    keepsAgentActive: keepsAgentMessageActive
                )
            }
        }
    }

    /// sendMessage 各退出路径的统一收尾（watchdog/任务/流式状态）。
    /// 提前 return 的分支（额度预检、周计划数据不足）若跳过收尾，
    /// watchdog 会在 300s 后把已落地的卡片覆盖成「AI 响应超时」，且 isStreaming 挂起。
    private func concludeStreamingSession(aiMessageId: UUID, keepsAgentActive: Bool = false) {
        guard activeStreamingMessageID == aiMessageId else { return }
        streamingStatusHint = nil
        streamingWatchdogTask?.cancel()
        streamingWatchdogTask = nil
        currentTask = nil
        // keepsAgentActive 只保留消息级活跃（等待/恢复卡片继续渲染、恢复链回填），
        // 全局输入框必须解锁：深度分析是可暂停的后台任务，等待网络/系统资源期间
        // 不应把用户锁在聊天框外（最长可等到 30 分钟截止）。用户此时发起新深度
        // 分析会按 P0 门控自然抢占旧任务，发普通消息则与后台恢复互不干扰。
        isStreaming = false
        if !keepsAgentActive {
            streamingText = ""
            activeStreamingMessageID = nil
        }
    }

    // MARK: - 每周生活计划（LifePlan）

    /// Agent 分析完成后的计划组装与落卡：成功 → .lifePlan 计划卡；降级 → 普通分析卡
    private func finalizeWeeklyPlanning(
        aiMessageId: UUID,
        rendered: HoloRenderedAgentResult,
        intent: String?,
        userContext: UserContext
    ) async {
        let consumption = analysisService.lastRunConsumption
        let outcome = await LifePlanGenerationService.shared.generatePlan(
            agentResult: rendered,
            jobID: consumption?.jobID ?? "unknown",
            budget: consumption?.budget,
            provider: provider,
            userContext: userContext
        )
        switch outcome {
        case .saved(let snapshot):
            refreshLifePlanSnapshots()
            chatRepo?.finalizeMessage(
                aiMessageId,
                finalContent: String(localized: "本周重点已生成（\(snapshot.priorities.count) 个重点 · \(snapshot.actions.count) 张行动卡）"),
                intent: intent,
                extractedDataJSON: Self.encodeExtractedData(["planID": snapshot.id.uuidString]),
                parsedBatchJSON: nil,
                executionBatchJSON: nil,
                analysisContextJSON: nil,
                rawLogJSON: nil,
                messageType: .lifePlan
            )
        case .degraded:
            // 降级：用户先拿到分析（计划版稍后再试），PlanRun 已记录 failedDegraded
            let fallbackText = [rendered.title, rendered.summary]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            chatRepo?.finalizeMessage(
                aiMessageId,
                finalContent: fallbackText + String(localized: "\n\n（本周计划的结构化版暂时没有生成成功，以上是分析结论，稍后可再试一次）"),
                intent: intent,
                extractedDataJSON: nil,
                parsedBatchJSON: nil,
                executionBatchJSON: nil,
                analysisContextJSON: nil,
                rawLogJSON: nil,
                agentResultJSON: Self.encodeAgentResult(rendered)
            )
        case .quotaExhausted(let userMessage):
            // 计划生成额度（lifePlan 池，免费 1 次/周）耗尽：分析结论照常交付，附注写明原因；
            // 不用「稍后再试」措辞——重试要先重烧深度分析额度，且额度重置前必失败。
            let fallbackText = [rendered.title, rendered.summary]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            chatRepo?.finalizeMessage(
                aiMessageId,
                finalContent: fallbackText + String(localized: "\n\n（\(userMessage)，本周的分析结论已在上面）"),
                intent: intent,
                extractedDataJSON: nil,
                parsedBatchJSON: nil,
                executionBatchJSON: nil,
                analysisContextJSON: nil,
                rawLogJSON: nil,
                agentResultJSON: Self.encodeAgentResult(rendered)
            )
        case .dataInsufficient:
            break // 前置检查已拦截，理论上不可达
        }
    }

    /// 计划卡实时快照缓存（planID → snapshot），避免消息流渲染逐条查库
    @Published private(set) var lifePlanSnapshots: [UUID: LifePlanSnapshot] = [:]

    private func refreshLifePlanSnapshots() {
        var snapshots: [UUID: LifePlanSnapshot] = [:]
        for message in messages where message.messageType == .lifePlan {
            if let planIDStr = message.extractedDataDictionary?["planID"],
               let planID = UUID(uuidString: planIDStr),
               let snapshot = LifePlanRepository.shared.snapshot(planID: planID) {
                snapshots[planID] = snapshot
            }
        }
        lifePlanSnapshots = snapshots
    }

    /// 计划卡快照读取入口（MessageBubbleView 经 ChatView 注入）
    func lifePlanSnapshot(for message: ChatMessageViewData) -> LifePlanSnapshot? {
        guard let planIDStr = message.extractedDataDictionary?["planID"],
              let planID = UUID(uuidString: planIDStr) else { return nil }
        if let cached = lifePlanSnapshots[planID] { return cached }
        let snapshot = LifePlanRepository.shared.snapshot(planID: planID)
        if let snapshot { lifePlanSnapshots[planID] = snapshot }
        return snapshot
    }

    /// 计划确认页状态（仿 goalDraftForReview 模式）
    @Published var lifePlanForReview: LifePlanSnapshot?
    @Published var showLifePlanReview = false
    /// 最近一次确认的撤销提示（计划卡/成功提示条提供撤销入口）
    @Published var lastPlanUndo: (planID: UUID, token: PlanUndoToken)?

    func openLifePlanReview(_ snapshot: LifePlanSnapshot) {
        lifePlanForReview = snapshot
        showLifePlanReview = true
    }

    func finishLifePlanConfirm(
        planID: UUID,
        token: PlanUndoToken,
        createdGoalTitle: String?,
        createdTaskCount: Int,
        createdHabitCount: Int
    ) {
        refreshLifePlanSnapshots()
        lastPlanUndo = (planID, token)
        var summaryParts: [String] = []
        if createdTaskCount > 0 { summaryParts.append(String(localized: "\(createdTaskCount) 个任务")) }
        if createdHabitCount > 0 { summaryParts.append(String(localized: "\(createdHabitCount) 个习惯")) }
        let summary = summaryParts.isEmpty ? String(localized: "已确认") : String(localized: "已创建 ") + summaryParts.joined(separator: " · ")
        chatRepo?.addMessage(
            role: "assistant",
            content: String(localized: "已按你的确认落库：\(summary)。可随时撤销。"),
            messageType: .lifePlan
        )
        lifePlanForReview = nil
        showLifePlanReview = false
    }

    func undoLifePlanConfirm(planID: UUID, token: PlanUndoToken) {
        do {
            try LifePlanRepository.shared.undoConfirm(planID: planID, token: token)
            GoalNotificationService.broadcastGoalDataChange()
            refreshLifePlanSnapshots()
            lastPlanUndo = nil
            chatRepo?.addMessage(
                role: "assistant",
                content: String(localized: "已撤销本次确认：创建的目标、任务、习惯已删除，行动卡恢复为待确认。"),
                messageType: .lifePlan
            )
        } catch {
            chatRepo?.addMessage(
                role: "assistant",
                content: String(localized: "撤销失败：\(error.localizedDescription)。可手动删除刚创建的内容。"),
                messageType: .lifePlan
            )
        }
    }

    // MARK: - Cancel

    func cancelStreaming() {
        let cancelledMessageID = activeStreamingMessageID
        currentTask?.cancel()
        currentTask = nil
        streamingWatchdogTask?.cancel()
        streamingWatchdogTask = nil
        // 点击后立即结束输入栏的运行态；底层任务取消和持久化落盘继续异步完成。
        // 不能让按钮是否消失取决于网络请求何时响应取消。
        isStreaming = false
        streamingText = ""
        streamingStatusHint = nil
        activeStreamingMessageID = nil
        if let cancelledMessageID {
            // 打 .userCancelled 持久标记：重新进入页面做 Agent 状态同步时，
            // 看到此标记不再把消息重新点亮成「还在分析中」，切断取消与同步的竞态。
            chatRepo?.finishStreaming(
                cancelledMessageID,
                finalContent: String(localized: "已停止生成"),
                messageType: .userCancelled
            )
        }
        // 兜底：页面重进后 currentTask/activeStreamingMessageID 已丢失（旧 VM 已销毁，
        // 其 watchdog 因 weak self 一并失效），残留 streaming 消息既停不掉也无人收尾。
        // 点停止时把它们一并定稿为「已停止」，让按钮真正生效；后台 Agent 由下方调用继续取消。
        let orphanedIDs = messages
            .filter { $0.isStreaming && $0.id != cancelledMessageID }
            .map(\.id)
        for id in orphanedIDs {
            chatRepo?.finishStreaming(id, finalContent: String(localized: "已停止生成"), messageType: .userCancelled)
        }
        // 关键修复：Agent 深度分析跑在 Scheduler 独立 Task 上（activeTasks[jobID]），
        // 与 chat 的 currentTask 是不同对象。此前只取消 currentTask 对 Agent 无效，
        // 导致点「停止」后分析继续跑到预算耗尽。这里显式取消 Scheduler 上活跃的用户任务。
        // HoloAIFeatureFlags 守卫：未启用 Agent runtime 时不触发（避免无谓的 actor 调用）。
        if HoloAIFeatureFlags.agentRuntimeEnabled {
            Task { await HoloAgentScheduler.shared.cancelActiveUserQuestions() }
        }
    }

    // MARK: - Retry

    /// 重试发送：找到该错误消息对应的用户消息，重新发送
    func retryMessage(_ errorMessage: ChatMessageViewData) async {
        guard let parentId = errorMessage.parentMessageId,
              let userMessage = messages.first(where: { $0.id == parentId }) else { return }

        // 删除旧的错误消息
        chatRepo?.deleteMessage(errorMessage.id)

        // 用原始用户消息重新发送
        inputText = userMessage.content
        await sendMessage()
    }

    // MARK: - Streaming Watchdog

    /// 流式守护分两段：90 秒未完成先提示「AI 还在工作」（不掐断，长分析回复常见超过 90s）；
    /// 累计 300 秒仍未完成才强制超时。两段都要求仍是当前活跃消息。
    private func startStreamingWatchdog(aiMessageId: UUID) {
        streamingWatchdogTask?.cancel()
        streamingWatchdogTask = Task { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: 90_000_000_000) // 90s：进入提示段
            guard !Task.isCancelled else { return }
            guard self.activeStreamingMessageID == aiMessageId else { return }
            self.streamingStatusHint = String(localized: "AI 正在处理较长的内容，仍在工作中，可随时停止")

            try? await Task.sleep(nanoseconds: 210_000_000_000) // 累计 300s：超时
            guard !Task.isCancelled else { return }
            guard self.activeStreamingMessageID == aiMessageId else { return }

            self.logger.error("Streaming watchdog 触发：300 秒超时，强制终止")

            self.currentTask?.cancel()
            self.currentTask = nil

            let partialContent = self.streamingText
            let finalContent: String
            if partialContent.isEmpty {
                finalContent = String(localized: "抱歉，AI 响应超时了，请稍后重试")
            } else {
                finalContent = partialContent + String(localized: "\n\n---\n⚠️ AI 响应超时，以上为已接收的部分内容")
            }

            self.chatRepo?.finishStreaming(aiMessageId, finalContent: finalContent)
            self.isStreaming = false
            self.streamingText = ""
            self.streamingStatusHint = nil
            self.errorMessage = String(localized: "AI 响应超时")
            self.currentTask = nil
            self.activeStreamingMessageID = nil
        }
    }

    // MARK: - Core Data Change Observation

    /// 监听 CoreData 实体变更（删除/软删除），刷新受影响的卡片
    func startObservingCoreDataChanges() {
        guard coreDataObserver == nil else { return }
        let context = CoreDataStack.shared.viewContext

        coreDataObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSManagedObjectContextObjectsDidChange,
            object: context,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleCoreDataChange(notification)
            }
        }
    }

    private func stopObservingCoreDataChanges() {
        if let observer = coreDataObserver {
            NotificationCenter.default.removeObserver(observer)
            coreDataObserver = nil
        }
    }

    private func handleCoreDataChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        var affectedIds: Set<UUID> = []          // 删除态刷新（含软删除）
        var updatedFinanceIds: Set<UUID> = []    // 交易内容刷新（账本页编辑金额/分类/日期）
        var updatedTaskIds: Set<UUID> = []       // 任务内容刷新（任务页改名/改期）

        // 硬删除：Transaction、TodoTask 永久删除
        if let deleted = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> {
            for object in deleted {
                if let transaction = object as? Transaction {
                    affectedIds.insert(transaction.id)
                }
                if let task = object as? TodoTask {
                    affectedIds.insert(task.id)
                }
            }
        }

        // 更新：TodoTask（含软删除/改名/改期）；Transaction 此前未监听，导致账本页编辑后聊天卡不刷新
        if let updated = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> {
            for object in updated {
                if let task = object as? TodoTask {
                    affectedIds.insert(task.id)
                    updatedTaskIds.insert(task.id)
                }
                if let transaction = object as? Transaction {
                    updatedFinanceIds.insert(transaction.id)
                }
            }
        }

        guard !affectedIds.isEmpty || !updatedFinanceIds.isEmpty || !updatedTaskIds.isEmpty else { return }

        // 命中受影响实体的消息：按全量实体 ID 匹配（多卡消息每张卡各一个 ID）
        var affectedMessageIDs: Set<UUID> = []
        var financeRefreshIDs: Set<UUID> = []
        var taskRefreshIDs: Set<UUID> = []
        for message in messages {
            let financeIds = message.allLinkedEntityIds(for: .finance)
            let taskIds = message.allLinkedEntityIds(for: .task)
            if affectedIds.contains(where: { financeIds.contains($0) || taskIds.contains($0) }) {
                affectedMessageIDs.insert(message.id)
            }
            if !updatedFinanceIds.isDisjoint(with: financeIds) {
                financeRefreshIDs.formUnion(updatedFinanceIds.intersection(financeIds))
            }
            if !updatedTaskIds.isDisjoint(with: taskIds) {
                taskRefreshIDs.formUnion(updatedTaskIds.intersection(taskIds))
            }
        }

        for messageID in affectedMessageIDs {
            chatRepo?.refreshDeletionState(for: messageID, affectedCategories: [.finance, .task])
        }
        for transactionId in financeRefreshIDs {
            chatRepo?.refreshTransactionCard(transactionId: transactionId)
        }
        for taskId in taskRefreshIDs {
            chatRepo?.refreshTaskCard(taskId: taskId)
        }
    }

    // MARK: - Recent Linked Task

    /// 卡片「补充条目」锚定的任务：优先于历史消息推导，一次性消费（下一条消息用后即清）。
    /// 解决多任务/间隔较久时「接着说」的指代歧义——点哪张卡就是哪个任务。
    private var anchoredTask: RecentLinkedTaskSummary?

    /// 任务卡片「补充条目」入口：锚定目标任务并预填输入框，用户补完发送即走 modify 流程
    func startTaskFollowUp(_ taskData: TaskCardData) {
        guard let taskId = taskData.taskId,
              let task = TodoRepository.shared.findTask(by: taskId),
              !task.deletedFlag else {
            errorMessage = String(localized: "该任务已不存在，无法补充条目")
            return
        }
        let itemTitles = ((task.checkItems as? Set<CheckItem>) ?? [])
            .sorted { $0.order < $1.order }
            .map(\.title)
        anchoredTask = RecentLinkedTaskSummary(taskId: taskId, title: task.title, itemTitles: itemTitles)
        inputText = String(localized: "给「\(task.title)」补充：")
    }

    /// 查「最近对话关联的任务」：锚定任务优先（卡片显式指定，零歧义）；
    /// 否则倒序遍历最近约20条消息，找第一个关联了 task 的，拉取标题 + 现有条目标题。
    /// 任务已软删或无关联任务时返回 nil。
    /// 用途：注入意图识别的「备忘单」+ modifyTaskItems 执行时补 taskId。
    private func resolveRecentLinkedTask() -> RecentLinkedTaskSummary? {
        if let anchored = anchoredTask {
            anchoredTask = nil
            return anchored
        }
        for message in messages.suffix(20).reversed() {
            guard let taskId = message.resolveLinkedEntityId(for: .task) else { continue }
            guard let task = TodoRepository.shared.findTask(by: taskId),
                  !task.deletedFlag else { return nil }
            let itemTitles = ((task.checkItems as? Set<CheckItem>) ?? [])
                .sorted { $0.order < $1.order }
                .map(\.title)
            return RecentLinkedTaskSummary(taskId: taskId, title: task.title, itemTitles: itemTitles)
        }
        return nil
    }

    // MARK: - Category Learning

    func markTransactionAsAICreated(
        _ transactionId: UUID,
        candidate: String?,
        sourceMessageId: String? = nil,
        sourceItemId: String? = nil
    ) {
        FinanceRepository.shared.markTransactionAsAICreated(
            transactionId,
            candidate: candidate,
            sourceMessageId: sourceMessageId,
            sourceItemId: sourceItemId
        )
    }

    func recordCategoryLearningIfNeeded(
        renderData: [String: String],
        routeResult: IntentRouter.RouteResult,
        intent: AIIntent
    ) {
        // 只有用户通过 Sheet 修改过分类才触发学习
        guard renderData["selectedCategoryId"] != nil else { return }
        guard let candidate = renderData["categoryCandidate"] ?? renderData["note"],
              !candidate.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let targetPrimary = routeResult.matchedPrimaryCategory,
              let targetSub = routeResult.matchedSubCategory else { return }

        let type: TransactionType = intent == .recordIncome ? .income : .expense
        CategoryLearnedMapping.record(
            candidate: candidate,
            type: type,
            primaryCategory: renderData["primaryCategory"] ?? "",
            targetPrimary: targetPrimary,
            targetSub: targetSub
        )
        logger.info("记账分类学习：\(candidate) → \(targetPrimary)/\(targetSub)")
    }

    /// 归纳学习：记录样本并尝试触发 LLM 归纳
    func recordInductionSampleIfNeeded(
        renderData: [String: String],
        routeResult: IntentRouter.RouteResult,
        intent: AIIntent
    ) {
        guard let candidate = renderData["categoryCandidate"] ?? renderData["note"],
              !candidate.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let targetPrimary = routeResult.matchedPrimaryCategory,
              let targetSub = routeResult.matchedSubCategory else { return }

        let type: TransactionType = intent == .recordIncome ? .income : .expense
        CategoryLearnedMapping.recordInductionSample(
            candidate: candidate,
            targetPrimary: targetPrimary,
            targetSub: targetSub,
            transactionType: type
        )
        CategoryLearnedMapping.tryTriggerInduction(
            targetPrimary: targetPrimary,
            targetSub: targetSub,
            transactionType: type
        )
    }

    // MARK: - Helpers

    /// 将 extractedData 字典编码为 JSON 字符串
    static func encodeExtractedData(
        _ data: [String: String]?,
        flexibleQueryResult: FlexibleQueryResult? = nil,
        usedMemoryIDs: [String] = []
    ) -> String? {
        var payload = data ?? [:]
        if let flexibleQueryResult,
           let resultData = try? JSONEncoder().encode(flexibleQueryResult),
           let resultJSON = String(data: resultData, encoding: .utf8) {
            payload["flexibleQueryResultJSON"] = resultJSON
        }
        // 记忆引用署名：本条回答实际使用的长期记忆，供气泡持久展示
        if !usedMemoryIDs.isEmpty {
            payload["memoryUsedCount"] = String(usedMemoryIDs.count)
            payload["memoryUsedIDs"] = usedMemoryIDs.joined(separator: ",")
        }
        guard !payload.isEmpty else { return nil }
        do {
            let encoded = try JSONEncoder().encode(payload)
            return String(data: encoded, encoding: .utf8)
        } catch {
            Logger(subsystem: HoloLog.subsystem, category: "ChatViewModel")
                .error("编码 extractedData 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 将 AIParseBatch 编码为 JSON 字符串
    static func encodeParseBatch(_ batch: AIParseBatch?) -> String? {
        guard let batch = batch else { return nil }
        do {
            let encoded = try JSONEncoder().encode(batch)
            return String(data: encoded, encoding: .utf8)
        } catch {
            Logger(subsystem: HoloLog.subsystem, category: "ChatViewModel")
                .error("编码 parsedBatch 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 将 AIExecutionBatch 编码为 JSON 字符串
    static func encodeExecutionBatch(_ batch: AIExecutionBatch?) -> String? {
        guard let batch = batch else { return nil }
        do {
            let encoded = try JSONEncoder().encode(batch)
            return String(data: encoded, encoding: .utf8)
        } catch {
            Logger(subsystem: HoloLog.subsystem, category: "ChatViewModel")
                .error("编码 executionBatch 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 将 AnalysisContext 编码为 JSON 字符串
    private static func encodeAgentResult(_ result: HoloRenderedAgentResult) -> String? {
        guard let data = try? JSONEncoder().encode(result) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeAnalysisContext(_ context: AnalysisContext) -> String? {
        do {
            let encoder = JSONEncoder()
            let encoded = try encoder.encode(context)
            return String(data: encoded, encoding: .utf8)
        } catch {
            Logger(subsystem: HoloLog.subsystem, category: "ChatViewModel")
                .error("编码 analysisContext 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 活跃规划会话检测：最后一条已定稿的 AI 消息是未解决的规划草案卡时，
    /// 会话处于规划续接态，非写消息由 Coordinator 走 followUp 重新生成草案。
    /// 用户点过「已安排好/本次不用」或之后又聊了别的，即退出续接态。
    private func latestUnresolvedContextPlanRunID() -> String? {
        guard let lastAIMessage = messages.last(where: { $0.role != "user" && !$0.isStreaming }) else { return nil }
        guard lastAIMessage.messageType == .contextPlan,
              let json = lastAIMessage.contextPlanJSON,
              let data = json.data(using: .utf8),
              let runID = try? JSONDecoder().decode(ContextPlanRunIDEnvelope.self, from: data).runID,
              !runID.isEmpty
        else { return nil }
        // resolve 只会落 arranged/declined；无记录 = 仍在续接态
        guard ContextPlanUserDefaultsReceipts().loadResolution(runID: runID) == nil else { return nil }
        return runID
    }

    private struct ContextPlanRunIDEnvelope: Decodable {
        let runID: String
    }

    /// 返回剥离 marker 后的正文 + 实际引用的记忆 ID（供消息持久署名）。
    private func consumeMemoryUsageMarker(
        from text: String,
        availableMemoryIDs: [String],
        memoryEntries: [HoloMemorySummaryEntry],
        channel: HoloMemoryReceiptChannel
    ) -> (cleanText: String, usedMemoryIDs: [String]) {
        let result = HoloMemoryUsageMarker.parseAndStrip(
            text,
            allowedMemoryIDs: Set(availableMemoryIDs)
        )
        var usedMemoryIDs = result.usedMemoryIDs
        if usedMemoryIDs.isEmpty, !memoryEntries.isEmpty {
            // 署名兜底：注入了记忆但模型没吐引用标记时，按内容词对账补署名，
            // 避免「用了记忆却不说来源」。
            usedMemoryIDs = HoloMemoryAttributionReconciler.matchedMemoryIDs(
                reply: result.cleanText,
                entries: memoryEntries.map {
                    HoloMemoryAttributionReconciler.Entry(id: $0.id, text: $0.title + "\n" + $0.aiUseSummary)
                }
            )
        }
        if !usedMemoryIDs.isEmpty {
            let notice = String(localized: "Holo 参考了 \(usedMemoryIDs.count) 条已记住的信息")
            HoloMemoryReceiptStore.record(
                kind: .use,
                channel: channel,
                memoryIDs: usedMemoryIDs,
                message: notice
            )
            recordMemoryUsage(usedMemoryIDs)
            memoryNotice = notice
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if self?.memoryNotice == notice {
                    self?.memoryNotice = nil
                }
            }
        }
        return (result.cleanText, usedMemoryIDs)
    }

    /// 使用统计写入：走 repository 专用通道，不进版本链、不触发萃取调度；失败静默（统计非关键数据）。
    private func recordMemoryUsage(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        Task {
            guard let repository = try? await HoloMemoryRuntime.shared.repository() else { return }
            try? await repository.recordUsage(ids: ids, now: Date())
        }
    }

    /// 目标规划追问走 chat userContext 注入（含记忆 marker 规则），历史链路没有剥标记——
    /// 统一在此剥离并把引用计入使用统计，防止 [[HOLO_MEMORY_IDS:]] 原文漏进气泡。
    func strippedGoalPlanningText(_ text: String, allowedMemoryIDs: [String]) -> String {
        let marker = HoloMemoryUsageMarker.parseAndStrip(
            text,
            allowedMemoryIDs: Set(allowedMemoryIDs)
        )
        if !marker.usedMemoryIDs.isEmpty {
            HoloMemoryReceiptStore.record(
                kind: .use,
                channel: .chat,
                memoryIDs: marker.usedMemoryIDs,
                message: String(localized: "Holo 参考了 \(marker.usedMemoryIDs.count) 条已记住的信息")
            )
            recordMemoryUsage(marker.usedMemoryIDs)
        }
        return marker.cleanText
    }

    func retryConfigurationLoadIfNeeded() async {
        // 正式能力统一由 Holo 后端提供，不读取客户端模型配置。
    }

}

// MARK: - Quick Action

enum QuickAction: String, CaseIterable {
    case recordExpense = "记一笔消费"
    case createTask = "创建任务"
    case recordMood = "记录心情"
    case checkIn = "习惯打卡"
    case weeklyReport = "本周总结"
    case createNote = "记笔记"
    case queryTasks = "今日任务"
    case queryHabits = "习惯状态"
    case planGoal = "规划目标"

    var prompt: String {
        switch self {
        case .recordExpense: return String(localized: "帮我记一笔消费")
        case .createTask: return String(localized: "帮我创建一个任务")
        case .recordMood: return String(localized: "记录我现在的心情")
        case .checkIn: return String(localized: "帮我打卡")
        case .weeklyReport: return String(localized: "生成本周总结")
        case .createNote: return String(localized: "帮我记一条笔记")
        case .queryTasks: return String(localized: "今天有什么待办")
        case .queryHabits: return String(localized: "今天习惯完成了吗")
        case .planGoal: return ""
        }
    }

    var icon: String {
        switch self {
        case .recordExpense: return "yensign.circle"
        case .createTask: return "checklist"
        case .recordMood: return "heart.circle"
        case .checkIn: return "flame.circle"
        case .weeklyReport: return "chart.bar"
        case .createNote: return "note.text"
        case .queryTasks: return "list.bullet.circle"
        case .queryHabits: return "chart.circle"
        case .planGoal: return "target"
        }
    }
}
