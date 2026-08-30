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
    @Published private(set) var hasLoadedMessages: Bool = false
    @Published private(set) var didTimeoutLoadingConfig: Bool = false
    @Published private(set) var hasEarlierSessions: Bool = false
    @Published private(set) var isLoadingEarlierSession: Bool = false
    @Published private(set) var earlierHistoryLoadFailed: Bool = false
    /// 用户从某份 Agent Result 发起的短时追问锚点；发送、取消或离开页面后清空。
    @Published var continuationDraft: HoloAgentContinuationDraft?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.holo.app", category: "ChatViewModel")
    /// 首屏只装载足够覆盖约 3～5 屏的内容，降低复杂卡片首次布局的尖峰。
    private let initialHistoryLimit = 24
    /// 输入草稿持久化 key（退出界面再回来恢复未发送的文字）
    private static let inputDraftKey = "holo_chat_inputDraft"
    private var chatRepo: ChatMessageRepository?
    private var currentTask: Task<Void, Never>?
    /// 当前请求对应的占位消息；用于停止时立即关闭持久化 streaming 状态，
    /// 并防止已经取消的旧 Task 晚返回后覆盖下一次请求的 UI。
    private var activeStreamingMessageID: UUID?
    private var provider: AIProvider
    private let coordinator: ConversationCoordinator
    /// 本地深度 Agent 分析服务（Phase 6.2 灰度，agentRuntimeEnabled 把关）
    private let analysisService = HoloAgentAnalysisService()
    private var repositoryBootstrapTask: Task<Void, Never>?
    private var confirmingItemIds: Set<String> = []
    private var repoMessagesCancellable: AnyCancellable?
    private var metadataLoadPendingIds: Set<UUID> = []
    private var metadataLoadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
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
    private func refreshCapabilities() {
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

    @Published private(set) var activeGoalPlanningSession: GoalPlanningSession?
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

    private let goalPlanningCoordinator = GoalPlanningCoordinator()

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

    // MARK: - Paused Agent Jobs Resume

    /// Chat 页兜底：存在暂停态（waitingForForeground/paused）的 Agent job 时拉起恢复链。
    /// 生命周期事件（回前台/解锁/冷启动）的恢复各有条件，一旦错过时机任务会一直停在
    /// 「已暂停」；页面就绪是用户注意力所在，此处兜底最可靠。
    /// Scheduler 唯一执行权 + manager 内部 cancel 旧任务，重复调用无副作用。
    func resumePausedAgentJobsIfNeeded() {
        guard !isStreaming else { return }
        HoloBackgroundContinuationManager.shared.resumePausedJobsForChatAppearance()
    }

    /// 暂停卡片「立即继续」按钮的手动入口（与自动兜底同一条恢复链）。
    /// 点击瞬间先把消息置为「正在继续分析…」——状态走消息管道立即上屏，
    /// 不等恢复链跑完才变样；之后由轮询/同步刷成真实进度。
    func resumePausedAgentJobs(sourceMessageID: UUID? = nil) {
        if let sourceMessageID, let repo = chatRepo {
            repo.updateAgentMessageProgress(
                sourceMessageID,
                status: HoloAgentChatStatusPresenter.resumingStatus()
            )
        }
        HoloBackgroundContinuationManager.shared.resumePausedJobsForChatAppearance()
    }

    private func bootstrapChatRepositoryIfNeeded() {
        guard chatRepo == nil, repositoryBootstrapTask == nil else { return }

        repositoryBootstrapTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let repo = ChatMessageRepository.shared
            self.bindRepository(repo)

            // 消息加载先行，让首屏尽早上屏；Agent 状态校准与孤儿清理并行在后台进行。
            // sync/cleanup 完成后会通过 Repository.updateSnapshot 回主线程刷新受影响消息，
            // 极端情况（崩溃恢复有孤儿 streaming）首屏可能短暂显示占位，随后自动收敛。
            await repo.loadCurrentSessionLightweightMessagesAsync(limit: self.initialHistoryLimit)
            self.hasLoadedMessages = true
            self.syncHasEarlierSessions()
            // 消息加载完成后刷新能力入口（此时 isTrulyEmptyConversation 可靠）
            self.refreshCapabilities()
            self.repositoryBootstrapTask = nil

            // 后台并行：校准 Agent job 状态 + 清理孤儿 streaming 消息（不阻塞首屏）
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 注意：syncRecoverableChatMessages 已会回填完成的 Agent 结果，
                // 这里跑一次即可拿到准确的 preserve 集合，无需重复执行。
                let preserved = await self.analysisService.syncRecoverableChatMessages(repository: repo)
                    .union(HoloPeriodReplayCoordinator.shared.recoverableMessageIDs())
                await repo.cleanupOrphanedStreamingMessagesOffMain(preserveMessageIDs: preserved)
                self.resumePausedAgentJobsIfNeeded()
            }
        }
    }

    private func ensureChatRepositoryReady() async {
        if let repositoryBootstrapTask {
            await repositoryBootstrapTask.value
            if chatRepo != nil, hasLoadedMessages {
                return
            }
        }

        let repo: ChatMessageRepository

        if let chatRepo {
            repo = chatRepo
        } else {
            repo = ChatMessageRepository.shared
            bindRepository(repo)
        }

        if !hasLoadedMessages {
            let preserved = await analysisService.syncRecoverableChatMessages(repository: repo)
                .union(HoloPeriodReplayCoordinator.shared.recoverableMessageIDs())
            await repo.cleanupOrphanedStreamingMessagesOffMain(preserveMessageIDs: preserved)
            await repo.loadCurrentSessionLightweightMessagesAsync(limit: initialHistoryLimit)
            // 上次确认流程若中途被杀，消息停在 confirming 态：对账防重复入账
            repo.reconcileInterruptedConfirmations()
            hasLoadedMessages = true
            syncHasEarlierSessions()
        }

        repositoryBootstrapTask = nil
    }

    private func bindRepository(_ repo: ChatMessageRepository) {
        guard chatRepo !== repo else { return }

        chatRepo = repo
        repoMessagesCancellable = repo.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                guard let self else { return }
                self.messages = Self.annotateTimestampSeparators(messages)
                // 全局 isStreaming（输入锁语义）只由「当前请求」的生命周期管理
                // （sendMessage 置 true / concludeStreamingSession 收尾），不得从消息级
                // streaming 重建：Agent 等待网络/前台的消息会把它反复顶回 true，
                // 把用户锁在聊天框外（最长等到 30 分钟截止）。停止键的可见性
                // 由 hasActiveStreamingMessage（消息级）覆盖等待场景。
            }

        // 同步 hasEarlierSessions
        repo.$hasEarlierSessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.hasEarlierSessions = value
            }
            .store(in: &cancellables)

        startObservingCoreDataChanges()
    }

    private func syncHasEarlierSessions() {
        hasEarlierSessions = chatRepo?.hasEarlierSessions ?? false
    }

    /// 预计算每条消息是否需要在其上方显示时间分隔条。
    /// 首条消息或距上一条 ≥ 5 分钟时显示。在数据进入列表前一次性算好，
    /// 让 ForEach 不再依赖 enumerated() 复制整个数组、也不在渲染期逐条判断时间差。
    private static func annotateTimestampSeparators(_ messages: [ChatMessageViewData]) -> [ChatMessageViewData] {
        guard !messages.isEmpty else { return messages }
        var result = messages
        for index in result.indices {
            let previous = index > 0 ? result[index - 1].timestamp : nil
            result[index].showsTimestampSeparator = ChatTimeStampSeparator.shouldShow(
                current: result[index].timestamp,
                previous: previous
            )
        }
        return result
    }

    // MARK: - Configuration

    /// 切换 AI Provider
    func updateProvider(_ newProvider: AIProvider) {
        self.provider = newProvider
        checkConfiguration()
    }

    private func checkConfiguration() {
        isConfigured = true
    }

    // MARK: - Agent Continuation

    /// 从已完成的 Result 建立输入栏锚点。只保存身份和展示摘要，
    /// 真正执行时由 Runtime 重新读取 canonical Job / Result / Evidence。
    func startContinuation(from result: HoloRenderedAgentResult) {
        guard result.failure == nil,
              let parentJobID = result.agentJobID,
              let parentResultID = result.agentResultID else {
            errorMessage = "这份历史分析缺少可追溯依据，请重新发起一次分析。"
            return
        }

        continuationDraft = HoloAgentContinuationDraft(
            parentJobID: parentJobID,
            parentResultID: parentResultID,
            rootUserQuestion: result.rootUserQuestion
                ?? result.question
                ?? result.title,
            parentDomains: Array(Set(
                result.evidenceReferences.compactMap { $0.sourceModule?.rawValue }
            )).sorted(),
            parentRecommendations: (result.recommendations ?? []).map {
                HoloAgentContinuationDraft.RecommendationRef(
                    id: $0.id,
                    title: $0.title,
                    body: $0.body
                )
            },
            relation: .explain
        )
        errorMessage = nil
    }

    func clearContinuationDraft() {
        continuationDraft = nil
    }

    /// 结果卡「换范围」：以显式窗口重跑同一分析（.changeScope 追问）。
    /// 范围由 UI 直接注入（userOverride），不经文本解析，确定性 100%；
    /// 聊天里会落一条「换成近半年再看」的用户消息，链路与手动追问完全一致。
    func changeAnalysisScope(from result: HoloRenderedAgentResult, preset: AgentScopeChangePreset) async {
        guard result.failure == nil,
              let parentJobID = result.agentJobID,
              let parentResultID = result.agentResultID else {
            errorMessage = "这份历史分析缺少可追溯依据，请重新发起一次分析。"
            return
        }
        continuationDraft = HoloAgentContinuationDraft(
            parentJobID: parentJobID,
            parentResultID: parentResultID,
            rootUserQuestion: result.rootUserQuestion
                ?? result.question
                ?? result.title,
            parentDomains: Array(Set(
                result.evidenceReferences.compactMap { $0.sourceModule?.rawValue }
            )).sorted(),
            parentRecommendations: (result.recommendations ?? []).map {
                HoloAgentContinuationDraft.RecommendationRef(
                    id: $0.id,
                    title: $0.title,
                    body: $0.body
                )
            },
            relation: .changeScope,
            overrideTimeRange: preset.timeRange()
        )
        errorMessage = nil
        inputText = preset.followUpText
        await sendMessage()
    }

    /// 显式锚定优先；没有锚定时，只在 4 小时内且包含明确承接词时自动继承最近 Result。
    /// “执行建议”交回原有动作确认链，避免分析 Agent 绕过确认直接改数据。
    private func resolvedContinuationDraft(for text: String, now: Date = Date()) -> HoloAgentContinuationDraft? {
        if var explicitDraft = continuationDraft {
            let relation = HoloAgentFollowUpRouter.classify(
                followUpText: text,
                parent: HoloAgentFollowUpParentContext(
                    parentDomains: explicitDraft.parentDomains,
                    hasRecommendations: !explicitDraft.parentRecommendations.isEmpty
                )
            )
            switch relation {
            case .newTopic:
                continuationDraft = nil
                return nil
            case .executeFromResult:
                explicitDraft.relation = .executeFromResult
            case .ambiguous:
                // 用户已主动点击“继续追问”，不要因为句子短而丢失锚点。
                explicitDraft.relation = .explain
            default:
                explicitDraft.relation = relation
            }
            return explicitDraft
        }

        // 隐式承接只允许锚定“最近一条已完成的助手回复”。如果中间已经有普通聊天，
        // 即使四小时内存在更早的 Agent Result，也不能跨过新话题回捞旧结果。
        guard let parentMessage = messages.reversed().first(where: {
            $0.role == "assistant" && !$0.isStreaming
        }), let result = parentMessage.agentResult,
              result.failure == nil,
              result.agentJobID != nil,
              result.agentResultID != nil else {
            return nil
        }

        var draft = HoloAgentContinuationDraft(
            parentJobID: result.agentJobID ?? "",
            parentResultID: result.agentResultID ?? "",
            rootUserQuestion: result.rootUserQuestion ?? result.question ?? result.title,
            parentDomains: Array(Set(
                result.evidenceReferences.compactMap { $0.sourceModule?.rawValue }
            )).sorted(),
            parentRecommendations: (result.recommendations ?? []).map {
                HoloAgentContinuationDraft.RecommendationRef(
                    id: $0.id,
                    title: $0.title,
                    body: $0.body
                )
            }
        )
        let relation = HoloAgentFollowUpRouter.implicitRelation(
            text: text,
            parent: HoloAgentFollowUpParentContext(
                parentDomains: draft.parentDomains,
                hasRecommendations: !draft.parentRecommendations.isEmpty
            ),
            parentCompletedAt: parentMessage.timestamp,
            now: now
        )
        guard let relation else { return nil }
        draft.relation = relation
        return draft
    }

    /// “执行建议”只转换成待确认的任务草案，不直接落库。
    /// 多条建议且用户未指明序号时先做确定性澄清，避免替用户猜。
    private func recommendationActionCommand(
        for draft: HoloAgentContinuationDraft,
        userText: String
    ) -> String? {
        guard let recommendation = selectedRecommendation(in: draft, userText: userText) else {
            return nil
        }
        return """
        创建一个待办草案，标题是“\(recommendation.title)”，补充说明是“\(recommendation.body)”。
        这条草案来自上一份分析建议；必须走现有确认流程，用户确认前不得写入任何数据。
        """
    }

    private func selectedRecommendation(
        in draft: HoloAgentContinuationDraft,
        userText: String
    ) -> HoloAgentContinuationDraft.RecommendationRef? {
        let recommendations = draft.parentRecommendations
        guard !recommendations.isEmpty else { return nil }
        if recommendations.count == 1 { return recommendations[0] }

        let normalized = userText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let exact = recommendations.first(where: {
            !$0.title.isEmpty && normalized.contains($0.title.lowercased())
        }) {
            return exact
        }

        let ordinalMarkers: [[String]] = [
            ["第一条", "第1条", "第 1 条", "建议1", "建议 1", "1号建议"],
            ["第二条", "第2条", "第 2 条", "建议2", "建议 2", "2号建议"],
            ["第三条", "第3条", "第 3 条", "建议3", "建议 3", "3号建议"],
            ["第四条", "第4条", "第 4 条", "建议4", "建议 4", "4号建议"],
            ["第五条", "第5条", "第 5 条", "建议5", "建议 5", "5号建议"]
        ]
        for (index, markers) in ordinalMarkers.enumerated()
            where index < recommendations.count
                && markers.contains(where: normalized.contains) {
            return recommendations[index]
        }
        return nil
    }

    private func recommendationSelectionClarification(
        for draft: HoloAgentContinuationDraft
    ) -> ConversationProcessResult {
        let titles = draft.parentRecommendations.prefix(5).enumerated().map {
            "\($0.offset + 1). \($0.element.title)"
        }.joined(separator: "\n")
        return ConversationProcessResult(
            finalText: "这份分析有多条建议，请告诉我要执行哪一条，例如“执行第 2 条”。\n\n\(titles)",
            parsedBatch: nil,
            executionBatch: nil,
            firstIntent: nil,
            firstExtractedData: nil,
            shouldStreamChat: false,
            analysisContext: nil,
            flexibleQueryResult: nil,
            shouldRouteToAgent: false
        )
    }

    private func safeActionHandoffFailure() -> ConversationProcessResult {
        ConversationProcessResult(
            finalText: "我没能把这条建议可靠地转换成可确认的操作。你可以说“把第 2 条创建成待办”。",
            parsedBatch: nil,
            executionBatch: nil,
            firstIntent: nil,
            firstExtractedData: nil,
            shouldStreamChat: false,
            analysisContext: nil,
            flexibleQueryResult: nil,
            shouldRouteToAgent: false
        )
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
            errorMessage = "目标草案正在等待确认，请先处理当前草案。"
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
                        provider: self.provider
                    )
                }
                try Task.checkCancellation()

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
                                finalContent: "这周你的记录还不够，我先不装懂。\n\n近 7 天还缺：\(missing)。再记几天，我就能给出有依据的本周重点，而不是一份谁都能用的通用计划。",
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
                        title: isWeeklyPlanning ? "Holo 正在为你的本周计划分析数据…" : "Holo 正在深度分析中…",
                        detail: "可以离开当前页面；系统支持时会继续处理，中止后会保留进度并在回到 App 后恢复。",
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
                            let cloudHandled = await HoloCloudAnalysisService.shared.attempt(
                                question: text,
                                sourceMessageID: aiMessageId
                            )
                            if cloudHandled {
                                progressPoller.cancel()
                                self.concludeStreamingSession(aiMessageId: aiMessageId)
                                return
                            }
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
                            channel: .chat
                        )
                        self.streamingText = markerResult.cleanText
                        // 原子化写入：结束流式 + 元数据，单次 save + 单次 snapshot
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
                        finalContent = partialContent + "\n\n处理中断：\(userMessage)"
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
                finalContent: "本周重点已生成（\(snapshot.priorities.count) 个重点 · \(snapshot.actions.count) 张行动卡）",
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
                finalContent: fallbackText + "\n\n（本周计划的结构化版暂时没有生成成功，以上是分析结论，稍后可再试一次）",
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
                finalContent: fallbackText + "\n\n（\(userMessage)，本周的分析结论已在上面）",
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
        if createdTaskCount > 0 { summaryParts.append("\(createdTaskCount) 个任务") }
        if createdHabitCount > 0 { summaryParts.append("\(createdHabitCount) 个习惯") }
        let summary = summaryParts.isEmpty ? "已确认" : "已创建 " + summaryParts.joined(separator: " · ")
        chatRepo?.addMessage(
            role: "assistant",
            content: "已按你的确认落库：\(summary)。可随时撤销。",
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
                content: "已撤销本次确认：创建的目标、任务、习惯已删除，行动卡恢复为待确认。",
                messageType: .lifePlan
            )
        } catch {
            chatRepo?.addMessage(
                role: "assistant",
                content: "撤销失败：\(error.localizedDescription)。可手动删除刚创建的内容。",
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
                finalContent: "已停止生成",
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
            chatRepo?.finishStreaming(id, finalContent: "已停止生成", messageType: .userCancelled)
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
            self.streamingStatusHint = "AI 正在处理较长的内容，仍在工作中，可随时停止"

            try? await Task.sleep(nanoseconds: 210_000_000_000) // 累计 300s：超时
            guard !Task.isCancelled else { return }
            guard self.activeStreamingMessageID == aiMessageId else { return }

            self.logger.error("Streaming watchdog 触发：300 秒超时，强制终止")

            self.currentTask?.cancel()
            self.currentTask = nil

            let partialContent = self.streamingText
            let finalContent: String
            if partialContent.isEmpty {
                finalContent = "抱歉，AI 响应超时了，请稍后重试"
            } else {
                finalContent = partialContent + "\n\n---\n⚠️ AI 响应超时，以上为已接收的部分内容"
            }

            self.chatRepo?.finishStreaming(aiMessageId, finalContent: finalContent)
            self.isStreaming = false
            self.streamingText = ""
            self.streamingStatusHint = nil
            self.errorMessage = "AI 响应超时"
            self.currentTask = nil
            self.activeStreamingMessageID = nil
        }
    }

    // MARK: - Core Data Change Observation

    /// 监听 CoreData 实体变更（删除/软删除），刷新受影响的卡片
    private func startObservingCoreDataChanges() {
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
            errorMessage = "该任务已不存在，无法补充条目"
            return
        }
        let itemTitles = ((task.checkItems as? Set<CheckItem>) ?? [])
            .sorted { $0.order < $1.order }
            .map(\.title)
        anchoredTask = RecentLinkedTaskSummary(taskId: taskId, title: task.title, itemTitles: itemTitles)
        inputText = "给「\(task.title)」补充："
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

    // MARK: - Pending Task Confirmation

    /// 待确认任务项谓词（createTask / modifyTaskItems / deleteTask；确认入口含 failed 重试）
    private static func isPendingTaskItem(_ item: AIExecutionItem) -> Bool {
        Self.isTaskActionItem(item)
            && item.status == .skipped
            && item.renderData?["confirmationStatus"] == "pending"
    }

    private static func isTaskActionItem(_ item: AIExecutionItem) -> Bool {
        item.intent == .createTask || item.intent == .modifyTaskItems || item.intent == .deleteTask
    }

    /// 可确认（含失败重试）的任务项
    private static func isConfirmableTaskItem(_ item: AIExecutionItem) -> Bool {
        Self.isTaskActionItem(item)
            && item.status == .skipped
            && ["pending", "failed"].contains(item.renderData?["confirmationStatus"] ?? "")
    }

    /// 待确认财务项谓词
    private static func isPendingFinanceItem(_ item: AIExecutionItem) -> Bool {
        item.intent.isFinance
            && item.status == .skipped
            && item.renderData?["confirmationStatus"] == "pending"
    }

    /// 把消息里指定 item 的确认状态持久化（基于重读的最新 batch 按 itemId 定位）。
    /// 状态机：pending → confirming（路由执行前落库）→ confirmed / failed / cancelled。
    /// confirming 中间态 + 实体上的 AI 来源标记，构成「确认中途 App 被杀」后的对账依据。
    private func persistConfirmationStatus(messageId: UUID, itemId: String, status: String) {
        guard let msg = messages.first(where: { $0.id == messageId }),
              let batch = msg.executionBatch,
              let index = batch.items.firstIndex(where: { $0.id == itemId }),
              var rd = batch.items[index].renderData else { return }
        rd["confirmationStatus"] = status
        var updatedItems = batch.items
        let item = updatedItems[index]
        updatedItems[index] = AIExecutionItem(
            id: item.id,
            parseItemId: item.parseItemId,
            intent: item.intent,
            status: item.status,
            summaryText: item.summaryText,
            renderData: rd,
            linkedEntityType: item.linkedEntityType,
            linkedEntityId: item.linkedEntityId,
            errorText: item.errorText
        )
        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: batch.finalText
        )
        chatRepo?.updateMessageMetadata(
            messageId,
            intent: msg.intent,
            extractedDataJSON: Self.encodeExtractedData(msg.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(msg.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    /// 取消息里被点击卡片的待确认财务项：多卡消息按 itemID 精确定位，
    /// 单意图旧格式（itemID 为 nil）退回第一个 pending 项；确认进行中的项不可再操作。
    func pendingFinanceItem(in message: ChatMessageViewData, itemID: String?) -> AIExecutionItem? {
        guard let batch = message.executionBatch else { return nil }
        guard let item = batch.items.first(where: {
            Self.isPendingFinanceItem($0) && (itemID == nil || $0.id == itemID)
        }) else { return nil }
        guard !confirmingItemIds.contains(item.id) else { return nil }
        return item
    }

    func confirmPendingTask(from message: ChatMessageViewData, itemID: String? = nil) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isConfirmableTaskItem($0) && (itemID == nil || $0.id == itemID)
              }),
              let renderData = batch.items[pendingIndex].renderData else {
            return
        }

        let itemId = batch.items[pendingIndex].id
        guard !confirmingItemIds.contains(itemId) else { return }
        confirmingItemIds.insert(itemId)

        Task { @MainActor [weak self] in
            guard let self, let chatRepo = self.chatRepo else {
                self?.confirmingItemIds.remove(itemId)
                return
            }

            do {
                // 重读最新消息状态，防止过期数据重复确认；failed 也放行（失败卡重试走同一入口）
                guard let currentBatch = self.latestExecutionBatch(for: message.id),
                      let currentItems = currentBatch.items.first(where: { $0.id == itemId }),
                      ["pending", "failed"].contains(currentItems.renderData?["confirmationStatus"] ?? "") else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }

                // 路由执行前先落 confirming 中间态（对账依据，与交易侧同构）
                self.persistConfirmationStatus(messageId: message.id, itemId: itemId, status: "confirming")

                // 删除确认卡：直接按 ID 删（不回头走关键词模糊匹配路由）
                if currentItems.intent == .deleteTask {
                    var deleteRouteResult: IntentRouter.RouteResult
                    if let taskIdStr = renderData["taskId"],
                       let taskId = UUID(uuidString: taskIdStr),
                       let task = TodoRepository.shared.findTask(by: taskId) {
                        try TodoRepository.shared.deleteTask(task)
                        deleteRouteResult = IntentRouter.RouteResult(
                            text: "已删除任务：\(task.title)",
                            taskId: taskId,
                            linkedEntity: LinkedEntity(type: .task, id: taskId)
                        )
                    } else {
                        deleteRouteResult = IntentRouter.RouteResult(text: "任务已不存在，可能已被删除")
                    }
                    await self.finalizeTaskConfirmation(
                        chatRepo: chatRepo, message: message, itemId: itemId,
                        currentBatch: currentBatch, renderData: renderData,
                        routeResult: deleteRouteResult
                    )
                    self.confirmingItemIds.remove(itemId)
                    return
                }

                let result = ParsedResult(
                    intent: currentItems.intent,
                    confidence: 1,
                    extractedData: renderData,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    responseText: nil
                )
                let routeResult = try await IntentRouter.shared.route(result)
                await self.finalizeTaskConfirmation(
                    chatRepo: chatRepo, message: message, itemId: itemId,
                    currentBatch: currentBatch, renderData: renderData,
                    routeResult: routeResult
                )
            } catch {
                // 错误回写：标记卡片为 failed
                var failedRenderData = renderData
                failedRenderData["confirmationStatus"] = "failed"
                failedRenderData["errorText"] = error.localizedDescription

                var updatedItems = batch.items
                let pending = updatedItems[pendingIndex]
                updatedItems[pendingIndex] = AIExecutionItem(
                    id: pending.id,
                    parseItemId: pending.parseItemId,
                    intent: pending.intent,
                    status: .failed,
                    summaryText: pending.intent == .modifyTaskItems ? "修改条目失败" : "创建任务失败",
                    renderData: failedRenderData,
                    linkedEntityType: nil,
                    linkedEntityId: nil,
                    errorText: error.localizedDescription
                )

                let failedBatch = AIExecutionBatch(
                    mode: batch.mode,
                    items: updatedItems,
                    finalText: Self.confirmedFinalText(from: updatedItems)
                )

                chatRepo.updateMessage(message.id, content: failedBatch.finalText)
                chatRepo.updateMessageMetadata(
                    message.id,
                    intent: message.intent,
                    extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
                    parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
                    executionBatchJSON: Self.encodeExecutionBatch(failedBatch)
                )
                self.errorMessage = (pending.intent == .modifyTaskItems ? "修改条目失败" : "创建任务失败") + "：\(error.localizedDescription)"
            }

            self.confirmingItemIds.remove(itemId)
        }
    }

    /// 任务确认成功后的统一回写：来源标记 + confirmed 状态 + 基于最新 batch 定位回写
    private func finalizeTaskConfirmation(
        chatRepo: ChatMessageRepository,
        message: ChatMessageViewData,
        itemId: String,
        currentBatch: AIExecutionBatch,
        renderData: [String: String],
        routeResult: IntentRouter.RouteResult
    ) async {
        // 任务侧来源标记（对账依据，与交易侧同构）
        if let taskId = routeResult.taskId {
            TodoRepository.shared.markTaskAISource(
                taskId: taskId,
                messageId: message.id.uuidString,
                itemId: itemId
            )
        }

        var confirmedRenderData = renderData
        confirmedRenderData["confirmationStatus"] = "confirmed"
        if let entity = routeResult.linkedEntity {
            confirmedRenderData["entityType"] = entity.type.rawValue
            confirmedRenderData["entityId"] = entity.id.uuidString
        }
        if let taskId = routeResult.taskId {
            confirmedRenderData["taskId"] = taskId.uuidString
        }

        // 回写基于重读的最新 batch 按 itemId 定位：
        // 同消息多张卡先后确认时，旧快照里的 pendingIndex 已过期，
        // 会把兄弟卡片刚写入的状态回滚成 pending（诱导重复确认）
        guard let currentIndex = currentBatch.items.firstIndex(where: { $0.id == itemId }) else { return }
        var updatedItems = currentBatch.items
        let pending = updatedItems[currentIndex]
        updatedItems[currentIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: .success,
            summaryText: routeResult.text,
            renderData: confirmedRenderData,
            linkedEntityType: routeResult.linkedEntity?.type.rawValue,
            linkedEntityId: routeResult.linkedEntity?.id.uuidString,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: currentBatch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    /// 取消任务类待确认卡（创建/修改/删除通用）：置 cancelled，不执行任何动作
    func cancelPendingTask(from message: ChatMessageViewData, itemID: String? = nil) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isPendingTaskItem($0) && (itemID == nil || $0.id == itemID)
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        guard !confirmingItemIds.contains(pending.id) else { return }

        var renderData = pending.renderData
        renderData?["confirmationStatus"] = "cancelled"

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: "已取消",
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    private static func confirmedFinalText(from items: [AIExecutionItem]) -> String {
        guard !items.isEmpty else { return "已处理" }
        if items.count == 1 { return items[0].summaryText }
        return "已为你处理 \(items.count) 件事：\n" + items.enumerated().map { index, item in
            "\(index + 1). \(item.summaryText)"
        }.joined(separator: "\n")
    }

    // MARK: - Pending Goal Choice Confirmation

    /// 待选择目标项谓词（goalChoice 选择卡）
    private static func isPendingGoalChoiceItem(_ item: AIExecutionItem) -> Bool {
        item.status == .skipped
            && item.renderData?["pendingKind"] == "goalChoice"
            && item.renderData?["confirmationStatus"] == "pending"
    }

    /// 可确认（含失败重试）的目标选择项
    private static func isConfirmableGoalChoiceItem(_ item: AIExecutionItem) -> Bool {
        item.status == .skipped
            && item.renderData?["pendingKind"] == "goalChoice"
            && ["pending", "failed"].contains(item.renderData?["confirmationStatus"] ?? "")
    }

    /// 目标选择卡确认：把选中的 goalId 注入 extractedData 重放路由
    /// （matchGoal 第一级就是 goalId 精确匹配，天然闭环）。
    /// 状态机与任务/交易侧同构：pending → confirming → confirmed / failed。
    func confirmPendingGoalChoice(from message: ChatMessageViewData, itemID: String? = nil, goalId: String) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isConfirmableGoalChoiceItem($0) && (itemID == nil || $0.id == itemID)
              }),
              batch.items[pendingIndex].renderData != nil else {
            return
        }

        let itemId = batch.items[pendingIndex].id
        guard !confirmingItemIds.contains(itemId) else { return }
        confirmingItemIds.insert(itemId)

        Task { @MainActor [weak self] in
            guard let self, let chatRepo = self.chatRepo else {
                self?.confirmingItemIds.remove(itemId)
                return
            }

            do {
                // 重读最新消息状态，防止过期数据重复确认；failed 也放行（失败卡重试走同一入口）
                guard let currentBatch = self.latestExecutionBatch(for: message.id),
                      let currentItems = currentBatch.items.first(where: { $0.id == itemId }),
                      let currentRenderData = currentItems.renderData,
                      ["pending", "failed"].contains(currentRenderData["confirmationStatus"] ?? "") else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }

                // 路由执行前先落 confirming 中间态（对账依据，与任务/交易侧同构）
                self.persistConfirmationStatus(messageId: message.id, itemId: itemId, status: "confirming")

                var confirmedRenderData = currentRenderData
                confirmedRenderData["goalId"] = goalId

                let result = ParsedResult(
                    intent: currentItems.intent,
                    confidence: 1,
                    extractedData: confirmedRenderData,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    responseText: nil
                )
                let routeResult = try await IntentRouter.shared.route(result)
                GoalNotificationService.broadcastGoalDataChange()

                confirmedRenderData["confirmationStatus"] = "confirmed"
                if let entity = routeResult.linkedEntity {
                    confirmedRenderData["entityType"] = entity.type.rawValue
                    confirmedRenderData["entityId"] = entity.id.uuidString
                }
                if let goalUUID = routeResult.linkedEntity?.id,
                   let goal = GoalRepository.shared.findGoal(by: goalUUID) {
                    confirmedRenderData["goalTitle"] = goal.title
                }

                guard let currentIndex = currentBatch.items.firstIndex(where: { $0.id == itemId }) else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }
                var updatedItems = currentBatch.items
                let pending = updatedItems[currentIndex]
                updatedItems[currentIndex] = AIExecutionItem(
                    id: pending.id,
                    parseItemId: pending.parseItemId,
                    intent: pending.intent,
                    status: .success,
                    summaryText: routeResult.text,
                    renderData: confirmedRenderData,
                    linkedEntityType: routeResult.linkedEntity?.type.rawValue,
                    linkedEntityId: routeResult.linkedEntity?.id.uuidString,
                    errorText: nil
                )

                let updatedBatch = AIExecutionBatch(
                    mode: currentBatch.mode,
                    items: updatedItems,
                    finalText: Self.confirmedFinalText(from: updatedItems)
                )

                chatRepo.updateMessage(message.id, content: updatedBatch.finalText)
                chatRepo.updateMessageMetadata(
                    message.id,
                    intent: message.intent,
                    extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
                    parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
                    executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
                )
            } catch {
                self.writeGoalChoiceError(message: message, itemId: itemId, error: error)
            }

            self.confirmingItemIds.remove(itemId)
        }
    }

    /// 取消目标选择卡：置 cancelled，不执行任何动作
    func cancelPendingGoalChoice(from message: ChatMessageViewData, itemID: String? = nil) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isPendingGoalChoiceItem($0) && (itemID == nil || $0.id == itemID)
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        guard !confirmingItemIds.contains(pending.id) else { return }

        var renderData = pending.renderData
        renderData?["confirmationStatus"] = "cancelled"

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: "已取消",
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    /// 目标选择确认失败回写：标记卡片为 failed，候选行可再次点选重试
    private func writeGoalChoiceError(message: ChatMessageViewData, itemId: String, error: Error) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let index = batch.items.firstIndex(where: { $0.id == itemId }) else { return }
        let item = batch.items[index]
        guard var renderData = item.renderData else { return }

        renderData["confirmationStatus"] = "failed"
        renderData["errorText"] = error.localizedDescription

        var updatedItems = batch.items
        updatedItems[index] = AIExecutionItem(
            id: item.id,
            parseItemId: item.parseItemId,
            intent: item.intent,
            status: item.status,
            summaryText: item.summaryText,
            renderData: renderData,
            linkedEntityType: item.linkedEntityType,
            linkedEntityId: item.linkedEntityId,
            errorText: error.localizedDescription
        )

        let failedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: failedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(failedBatch)
        )
        errorMessage = "目标操作失败：\(error.localizedDescription)"
    }

    // MARK: - Pending Transaction Confirmation

    func confirmPendingTransaction(from message: ChatMessageViewData, itemID: String? = nil) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isPendingFinanceItem($0) && (itemID == nil || $0.id == itemID)
              }),
              batch.items[pendingIndex].renderData != nil else {
            return
        }

        let itemId = batch.items[pendingIndex].id
        guard !confirmingItemIds.contains(itemId) else { return }

        // 分期入账为 Plus 权益：非 Plus 先弹付费墙，购买成功后自动续上本次确认
        if batch.items[pendingIndex].renderData?["installmentEnabled"] == "true",
           !HoloEntitlementState.shared.isPlusActive {
            HoloPlusActionCoordinator.shared.requirePlus(context: .financeInstallment) { [weak self] in
                self?.confirmPendingTransaction(from: message, itemID: itemID)
            }
            return
        }
        confirmingItemIds.insert(itemId)

        Task { @MainActor [weak self] in
            guard let self, let chatRepo = self.chatRepo else {
                self?.confirmingItemIds.remove(itemId)
                return
            }

            // 重读最新 batch 供校验与回写共用；route 抛错时错误回写也要基于它，
            // 避免旧快照把同消息兄弟卡片的状态回滚
            var latestBatch: AIExecutionBatch?

            do {
                // 重读最新消息状态，防止过期数据重复确认；
                // failed 也放行：失败卡上的「重试」按钮走同一入口
                guard let currentBatch = self.latestExecutionBatch(for: message.id),
                      let currentItems = currentBatch.items.first(where: { $0.id == itemId }),
                      let currentRenderData = currentItems.renderData,
                      currentRenderData["confirmationStatus"] == "pending"
                          || currentRenderData["confirmationStatus"] == "failed" else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }
                latestBatch = currentBatch

                // 路由执行前先落 confirming 中间态：路由期间 App 被杀，
                // 重启对账据此（配合实体上的 AI 来源标记）判断是否已入账，防止重复确认
                self.persistConfirmationStatus(messageId: message.id, itemId: itemId, status: "confirming")

                let intent: AIIntent = currentRenderData["pendingKind"] == "transaction"
                    ? (currentItems.intent == .recordIncome ? .recordIncome : .recordExpense)
                    : currentItems.intent

                let result = ParsedResult(
                    intent: intent,
                    confidence: 1,
                    extractedData: currentRenderData,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    responseText: nil
                )
                let routeResult = try await IntentRouter.shared.route(result)

                var confirmedRenderData = currentRenderData
                confirmedRenderData["confirmationStatus"] = "confirmed"
                if let entity = routeResult.linkedEntity {
                    confirmedRenderData["entityType"] = entity.type.rawValue
                    confirmedRenderData["entityId"] = entity.id.uuidString
                }
                if let txId = routeResult.transactionId {
                    confirmedRenderData["transactionId"] = txId.uuidString
                }
                if let primary = routeResult.matchedPrimaryCategory {
                    confirmedRenderData["primaryCategory"] = primary
                }
                if let sub = routeResult.matchedSubCategory {
                    confirmedRenderData["subCategory"] = sub
                }

                // 写入 AI 来源标记 + 确认流程来源（对账依据）
                if let txId = routeResult.transactionId {
                    self.markTransactionAsAICreated(
                        txId,
                        candidate: currentRenderData["categoryCandidate"] ?? currentRenderData["note"],
                        sourceMessageId: message.id.uuidString,
                        sourceItemId: itemId
                    )
                }

                guard let currentIndex = currentBatch.items.firstIndex(where: { $0.id == itemId }) else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }
                var updatedItems = currentBatch.items
                let pending = updatedItems[currentIndex]
                updatedItems[currentIndex] = AIExecutionItem(
                    id: pending.id,
                    parseItemId: pending.parseItemId,
                    intent: pending.intent,
                    status: .success,
                    summaryText: routeResult.text,
                    renderData: confirmedRenderData,
                    linkedEntityType: routeResult.linkedEntity?.type.rawValue,
                    linkedEntityId: routeResult.linkedEntity?.id.uuidString,
                    errorText: nil
                )

                let updatedBatch = AIExecutionBatch(
                    mode: currentBatch.mode,
                    items: updatedItems,
                    finalText: Self.confirmedFinalText(from: updatedItems)
                )

                chatRepo.updateMessage(message.id, content: updatedBatch.finalText)
                chatRepo.updateMessageMetadata(
                    message.id,
                    intent: message.intent,
                    extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
                    parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
                    executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
                )

                // 用户修改过分类时触发学习
                self.recordCategoryLearningIfNeeded(
                    renderData: currentRenderData,
                    routeResult: routeResult,
                    intent: intent
                )

                // 归纳学习：记录样本并尝试触发 LLM 归纳
                self.recordInductionSampleIfNeeded(
                    renderData: currentRenderData,
                    routeResult: routeResult,
                    intent: intent
                )
            } catch {
                self.writeTransactionError(
                    itemId: itemId,
                    batch: latestBatch ?? batch,
                    message: message,
                    error: error
                )
            }

            self.confirmingItemIds.remove(itemId)
        }
    }

    func cancelPendingTransaction(from message: ChatMessageViewData, itemID: String? = nil) {
        // 基于重读的最新 batch 取消，且确认进行中的项不允许取消：
        // 否则「确认的路由刚创建实体、取消把卡片改写、确认结果又覆盖回来」会绕过用户最后的意图
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  Self.isPendingFinanceItem($0) && (itemID == nil || $0.id == itemID)
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        guard !confirmingItemIds.contains(pending.id) else { return }

        var renderData = pending.renderData
        renderData?["confirmationStatus"] = "cancelled"

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: "已取消记账",
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    // MARK: - Pending Budget / Anniversary Confirmation

    /// 可确认（含失败重试）的预算项
    private static func isConfirmableBudgetItem(_ item: AIExecutionItem) -> Bool {
        item.intent == .setBudget
            && item.status == .skipped
            && ["pending", "failed"].contains(item.renderData?["confirmationStatus"] ?? "")
    }

    /// 可确认（含失败重试）的纪念日项
    private static func isConfirmableAnniversaryItem(_ item: AIExecutionItem) -> Bool {
        item.intent == .createAnniversary
            && item.status == .skipped
            && ["pending", "failed"].contains(item.renderData?["confirmationStatus"] ?? "")
    }

    func confirmPendingBudget(from message: ChatMessageViewData, itemID: String? = nil) {
        confirmPendingExecutionCard(from: message, itemID: itemID, matcher: Self.isConfirmableBudgetItem)
    }

    func confirmPendingAnniversary(from message: ChatMessageViewData, itemID: String? = nil) {
        confirmPendingExecutionCard(from: message, itemID: itemID, matcher: Self.isConfirmableAnniversaryItem)
    }

    /// 预算/纪念日确认卡的通用确认流程（与交易确认同构：
    /// 重读最新 batch → confirming 中间态 → route → confirmed 回写）
    private func confirmPendingExecutionCard(
        from message: ChatMessageViewData,
        itemID: String?,
        matcher: (AIExecutionItem) -> Bool
    ) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  matcher($0) && (itemID == nil || $0.id == itemID)
              }),
              batch.items[pendingIndex].renderData != nil else {
            return
        }

        let itemId = batch.items[pendingIndex].id
        guard !confirmingItemIds.contains(itemId) else { return }
        confirmingItemIds.insert(itemId)

        Task { @MainActor [weak self] in
            guard let self, let chatRepo = self.chatRepo else {
                self?.confirmingItemIds.remove(itemId)
                return
            }

            do {
                guard let currentBatch = self.latestExecutionBatch(for: message.id),
                      let currentItems = currentBatch.items.first(where: { $0.id == itemId }),
                      let currentRenderData = currentItems.renderData,
                      ["pending", "failed"].contains(currentRenderData["confirmationStatus"] ?? "") else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }

                self.persistConfirmationStatus(messageId: message.id, itemId: itemId, status: "confirming")

                let result = ParsedResult(
                    intent: currentItems.intent,
                    confidence: 1,
                    extractedData: currentRenderData,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    responseText: nil
                )
                let routeResult = try await IntentRouter.shared.route(result)

                var confirmedRenderData = currentRenderData
                confirmedRenderData["confirmationStatus"] = "confirmed"
                if let entity = routeResult.linkedEntity {
                    confirmedRenderData["entityType"] = entity.type.rawValue
                    confirmedRenderData["entityId"] = entity.id.uuidString
                    if entity.type == .anniversary {
                        confirmedRenderData["anniversaryId"] = entity.id.uuidString
                    }
                }

                guard let currentIndex = currentBatch.items.firstIndex(where: { $0.id == itemId }) else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }
                var updatedItems = currentBatch.items
                let pending = updatedItems[currentIndex]
                updatedItems[currentIndex] = AIExecutionItem(
                    id: pending.id,
                    parseItemId: pending.parseItemId,
                    intent: pending.intent,
                    status: .success,
                    summaryText: routeResult.text,
                    renderData: confirmedRenderData,
                    linkedEntityType: routeResult.linkedEntity?.type.rawValue,
                    linkedEntityId: routeResult.linkedEntity?.id.uuidString,
                    errorText: nil
                )

                let updatedBatch = AIExecutionBatch(
                    mode: currentBatch.mode,
                    items: updatedItems,
                    finalText: Self.confirmedFinalText(from: updatedItems)
                )

                chatRepo.updateMessage(message.id, content: updatedBatch.finalText)
                chatRepo.updateMessageMetadata(
                    message.id,
                    intent: message.intent,
                    extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
                    parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
                    executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
                )
            } catch {
                self.writeExecutionCardError(
                    itemId: itemId,
                    message: message,
                    error: error
                )
            }

            self.confirmingItemIds.remove(itemId)
        }
    }

    /// 确认卡 route 抛错的 failed 态回写（供重试），与交易侧 writeTransactionError 同构
    private func writeExecutionCardError(
        itemId: String,
        message: ChatMessageViewData,
        error: Error
    ) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let index = batch.items.firstIndex(where: { $0.id == itemId }) else { return }
        let item = batch.items[index]
        guard var renderData = item.renderData else { return }

        renderData["confirmationStatus"] = "failed"
        renderData["errorText"] = error.localizedDescription

        var updatedItems = batch.items
        updatedItems[index] = AIExecutionItem(
            id: item.id,
            parseItemId: item.parseItemId,
            intent: item.intent,
            status: item.status,
            summaryText: item.summaryText,
            renderData: renderData,
            linkedEntityType: item.linkedEntityType,
            linkedEntityId: item.linkedEntityId,
            errorText: error.localizedDescription
        )

        let failedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: failedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(failedBatch)
        )
        errorMessage = "操作失败：\(error.localizedDescription)"
    }

    func cancelPendingBudget(from message: ChatMessageViewData, itemID: String? = nil) {
        cancelPendingExecutionCard(
            from: message,
            itemID: itemID,
            matcher: { $0.intent == .setBudget },
            cancelledText: "已取消，预算未改动"
        )
    }

    func cancelPendingAnniversary(from message: ChatMessageViewData, itemID: String? = nil) {
        cancelPendingExecutionCard(
            from: message,
            itemID: itemID,
            matcher: { $0.intent == .createAnniversary },
            cancelledText: "已取消，未创建"
        )
    }

    /// 预算/纪念日确认卡的通用取消（基于重读的最新 batch；确认进行中的项不允许取消）
    private func cancelPendingExecutionCard(
        from message: ChatMessageViewData,
        itemID: String?,
        matcher: (AIExecutionItem) -> Bool,
        cancelledText: String
    ) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  matcher($0)
                      && $0.status == .skipped
                      && $0.renderData?["confirmationStatus"] == "pending"
                      && (itemID == nil || $0.id == itemID)
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        guard !confirmingItemIds.contains(pending.id) else { return }

        var renderData = pending.renderData
        renderData?["confirmationStatus"] = "cancelled"

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: cancelledText,
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    /// AddTransactionSheet 编辑保存后，将待确认卡片标记为"已确认"（不重复创建交易）
    func dismissPendingCardAfterEdit(
        from message: ChatMessageViewData,
        itemID: String? = nil,
        createdTransaction: Transaction? = nil
    ) {
        guard let batch = latestExecutionBatch(for: message.id) ?? message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                Self.isPendingFinanceItem($0) && (itemID == nil || $0.id == itemID)
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        var renderData = pending.renderData ?? [:]
        renderData["confirmationStatus"] = "confirmed"

        // 如果 AddTransactionSheet 创建了交易，补全分类和实体关联信息
        if let tx = createdTransaction, let category = tx.category {
            let names = FinanceRepository.shared.resolveCategoryNames(from: category)
            renderData["primaryCategory"] = names.primary
            if let sub = names.sub {
                renderData["subCategory"] = sub
            }
            renderData["entityType"] = "finance"
            renderData["entityId"] = tx.id.uuidString
            renderData["transactionId"] = tx.id.uuidString

            // 标记为 AI 创建
            markTransactionAsAICreated(tx.id, candidate: renderData["categoryCandidate"] ?? renderData["note"])

            // 分类学习：将原始候选词映射到用户选择的正确分类
            let candidate = renderData["categoryCandidate"] ?? renderData["note"]
            if let candidateText = candidate, !candidateText.trimmingCharacters(in: .whitespaces).isEmpty {
                let txType: TransactionType = tx.transactionType
                CategoryLearnedMapping.record(
                    candidate: candidateText,
                    type: txType,
                    targetPrimary: names.primary,
                    targetSub: names.sub ?? names.primary
                )

                // 归纳学习：记录样本并尝试触发 LLM 归纳
                CategoryLearnedMapping.recordInductionSample(
                    candidate: candidateText,
                    targetPrimary: names.primary,
                    targetSub: names.sub ?? names.primary,
                    transactionType: txType
                )
                CategoryLearnedMapping.tryTriggerInduction(
                    targetPrimary: names.primary,
                    targetSub: names.sub ?? names.primary,
                    transactionType: txType
                )
            }
        }

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: .success,
            summaryText: "已确认并记录",
            renderData: renderData,
            linkedEntityType: createdTransaction != nil ? "finance" : pending.linkedEntityType,
            linkedEntityId: createdTransaction?.id.uuidString ?? pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    private func writeTransactionError(
        itemId: String,
        batch: AIExecutionBatch,
        message: ChatMessageViewData,
        error: Error
    ) {
        guard let pendingIndex = batch.items.firstIndex(where: { $0.id == itemId }) else { return }
        let pending = batch.items[pendingIndex]
        var renderData = pending.renderData ?? [:]
        renderData["confirmationStatus"] = "failed"
        renderData["confirmationError"] = error.localizedDescription

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: .skipped,
            summaryText: pending.summaryText,
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: error.localizedDescription
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    private func latestExecutionBatch(for messageId: UUID) -> AIExecutionBatch? {
        guard let msg = messages.first(where: { $0.id == messageId }) else { return nil }
        return msg.executionBatch
    }

    // MARK: - Pending Transaction Category Update

    func updatePendingTransactionCategory(
        from message: ChatMessageViewData,
        category: Category
    ) {
        guard category.isSubCategory,
              let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  $0.intent.isFinance && $0.status == .skipped && $0.renderData?["confirmationStatus"] == "pending"
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        var renderData = pending.renderData ?? [:]

        // 查找父分类名称
        let parentName = FinanceRepository.shared.parentCategoryName(for: category)
        renderData["primaryCategory"] = parentName
        renderData["subCategory"] = category.name
        renderData["selectedCategoryId"] = category.id.uuidString

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: pending.summaryText,
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: pending.errorText
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: batch.finalText
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    // MARK: - Category Learning

    private func markTransactionAsAICreated(
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

    private func recordCategoryLearningIfNeeded(
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
    private func recordInductionSampleIfNeeded(
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
    private static func encodeExtractedData(
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
            Logger(subsystem: "com.holo.app", category: "ChatViewModel")
                .error("编码 extractedData 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 将 AIParseBatch 编码为 JSON 字符串
    private static func encodeParseBatch(_ batch: AIParseBatch?) -> String? {
        guard let batch = batch else { return nil }
        do {
            let encoded = try JSONEncoder().encode(batch)
            return String(data: encoded, encoding: .utf8)
        } catch {
            Logger(subsystem: "com.holo.app", category: "ChatViewModel")
                .error("编码 parsedBatch 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 将 AIExecutionBatch 编码为 JSON 字符串
    private static func encodeExecutionBatch(_ batch: AIExecutionBatch?) -> String? {
        guard let batch = batch else { return nil }
        do {
            let encoded = try JSONEncoder().encode(batch)
            return String(data: encoded, encoding: .utf8)
        } catch {
            Logger(subsystem: "com.holo.app", category: "ChatViewModel")
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
            Logger(subsystem: "com.holo.app", category: "ChatViewModel")
                .error("编码 analysisContext 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 返回剥离 marker 后的正文 + 实际引用的记忆 ID（供消息持久署名）。
    private func consumeMemoryUsageMarker(
        from text: String,
        availableMemoryIDs: [String],
        channel: HoloMemoryReceiptChannel
    ) -> (cleanText: String, usedMemoryIDs: [String]) {
        let result = HoloMemoryUsageMarker.parseAndStrip(
            text,
            allowedMemoryIDs: Set(availableMemoryIDs)
        )
        if !result.usedMemoryIDs.isEmpty {
            let notice = "Holo 参考了 \(result.usedMemoryIDs.count) 条已记住的信息"
            HoloMemoryReceiptStore.record(
                kind: .use,
                channel: channel,
                memoryIDs: result.usedMemoryIDs,
                message: notice
            )
            recordMemoryUsage(result.usedMemoryIDs)
            memoryNotice = notice
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if self?.memoryNotice == notice {
                    self?.memoryNotice = nil
                }
            }
        }
        return (result.cleanText, result.usedMemoryIDs)
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
    private func strippedGoalPlanningText(_ text: String, allowedMemoryIDs: [String]) -> String {
        let marker = HoloMemoryUsageMarker.parseAndStrip(
            text,
            allowedMemoryIDs: Set(allowedMemoryIDs)
        )
        if !marker.usedMemoryIDs.isEmpty {
            HoloMemoryReceiptStore.record(
                kind: .use,
                channel: .chat,
                memoryIDs: marker.usedMemoryIDs,
                message: "Holo 参考了 \(marker.usedMemoryIDs.count) 条已记住的信息"
            )
            recordMemoryUsage(marker.usedMemoryIDs)
        }
        return marker.cleanText
    }

    private func retryConfigurationLoadIfNeeded() async {
        // 正式能力统一由 Holo 后端提供，不读取客户端模型配置。
    }

// MARK: - Capability Tap

    func handleCapabilityTap(_ capability: HoloAICapability) {
        switch capability.id {
        case .onboarding:
            inputText = "我是新用户，能教我怎么用 Holo 吗？"
        case .todayState:
            // 确认权原则（2026-08-22 东林拍板）：预填不发送，
            // 与深度分析场景面板同一底线——用户看到并确认将发出的话再按发送。
            inputText = "帮我看看今天的整体状态"
            return
        case .recentAnalysis:
            // 甲方案（2026-08-22）：不再点击即发——点开场景面板，
            // 由用户选场景并确认发送，发起的确认权在用户。
            showAnalysisScenarioPanel.toggle()
            return
        case .longTermPatterns:
            // 与「今日状态」同类：快问快答也走预填确认
            inputText = "你了解我哪些长期偏好和模式？"
            return
        case .goalPlanning:
            startGoalPlanning(seedText: nil)
            return
        case .periodReplay:
            // 弹周期选择 Sheet，选完后走 startPeriodReplay（独立流程，不走 sendMessage）
            showPeriodReplayPicker = true
            return
        }
        Task { await sendMessage() }
    }

    // MARK: - Period Replay（周期回放，从记忆长廊迁移而来）

    /// 周期回放交给应用级协调器执行，页面销毁、息屏或冷启动都能从原消息继续。
    func startPeriodReplay(periodType: MemoryInsightPeriodType, start: Date, end: Date) async {
        await HoloPeriodReplayCoordinator.shared.start(
            periodType: periodType,
            start: start,
            end: end
        )
    }

    /// 首页胶囊 / 系统通知直达洞察：把已生成的洞察直接落成回放卡片。
    /// 卡片落地即视为「看过」（方案 §7.5），随后刷新首页候选让胶囊让位；
    /// 洞察已不可用时什么都不做——不 markRead，胶囊保留。
    func openScheduledInsight(id: UUID) async {
        let repository = MemoryInsightRepository()
        guard let insight = repository.fetchAvailableInsight(id: id),
              insight.parsedPayload != nil else { return }
        try? repository.markRead(insight: insight)
        HomeScheduleService.shared.refresh()
        HoloPeriodReplayCoordinator.shared.presentCachedInsight(insight)
    }

    // MARK: - Quick Actions（兼容旧入口）

    func sendQuickAction(_ action: QuickAction) {
        if action == .planGoal {
            startGoalPlanning(seedText: nil)
            return
        }
        inputText = action.prompt
        Task { await sendMessage() }
    }

    // MARK: - Clear

    func clearMessages() {
        if chatRepo == nil {
            bootstrapChatRepositoryIfNeeded()
        }
        chatRepo?.clearAllMessages()
    }

    // MARK: - Metadata Lazy Load

    /// 触发单条消息的元数据加载（带 debounce 合并）
    func loadMetadataIfNeeded(for messageId: UUID) {
        metadataLoadPendingIds.insert(messageId)
        metadataLoadTask?.cancel()
        metadataLoadTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms debounce
            guard !Task.isCancelled else { return }
            let ids = Array(self.metadataLoadPendingIds)
            self.metadataLoadPendingIds.removeAll()
            await self.chatRepo?.loadMetadataForMessagesIfNeeded(ids)
        }
    }

    // MARK: - Goal Planning

    func startGoalPlanning(seedText: String?) {
        Task { @MainActor in
            await retryConfigurationLoadIfNeeded()
            await ensureChatRepositoryReady()
            guard let chatRepo else { return }

            // 额度预检（先验票再进场）：目标规划与日常对话共用 chat 池，
            // 一次完整流程最多 3 轮追问 + 1 次草案生成。
            // - 余量连「一问一草案」（2 次）都撑不起 → 落付费墙卡片，不进问答流程；
            // - 余量跑不满 3 轮 → 按余量压缩追问轮数（宁可少问，不在用户认真作答后中途断）；
            // - 余量数据缺失（nil）→ 放行默认轮数，由后端拦截 + 额度卡片兜底。
            var planningMaxTurns = GoalPlanningSession.defaultMaxTurns
            if let remaining = HoloEntitlementState.shared.quotas["chat"]?.remaining {
                guard remaining > 1 else {
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: HoloQuotaError.goalPlanningExhaustedMessage(
                            isPlusActive: HoloEntitlementState.shared.isPlusActive
                        ),
                        messageType: .quotaExhausted
                    )
                    return
                }
                planningMaxTurns = max(1, min(GoalPlanningSession.defaultMaxTurns, remaining - 1))
            }

            let userMessageId: UUID?
            if let seedText, !seedText.isEmpty {
                userMessageId = chatRepo.addMessage(role: "user", content: seedText, messageType: .goalPlanning)
            } else {
                userMessageId = nil
            }

            isStreaming = true
            defer {
                isStreaming = false
                streamingText = ""
            }

            do {
                let userContext = await UserContextBuilder.shared.buildContext()
                let result = try await goalPlanningCoordinator.start(
                    seedText: seedText,
                    userContext: userContext,
                    provider: provider,
                    maxTurns: planningMaxTurns
                )
                activeGoalPlanningSession = result.session
                if let question = result.assistantText {
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: strippedGoalPlanningText(
                            question,
                            allowedMemoryIDs: userContext.memorySummary?.sourceIDs ?? []
                        ),
                        parentMessageId: userMessageId,
                        messageType: .goalPlanning
                    )
                }
                if let draft = result.draft {
                    goalDraftForReview = draft
                    let summary = "已根据你的需求生成了目标计划「\(draft.title)」\(draft.cardSummary)"
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: summary,
                        parentMessageId: userMessageId,
                        messageType: .goalPlanning
                    )
                }
            } catch {
                if let quotaError = error as? HoloQuotaError {
                    errorMessage = quotaError.userMessage
                    // 额度按天重置是确定终态：会话不能继续占用聊天入口，
                    // 否则后续普通消息仍会被路由成规划回答、反复触发额度报错。
                    activeGoalPlanningSession = nil
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: quotaError.userMessage,
                        parentMessageId: userMessageId,
                        messageType: .quotaExhausted
                    )
                } else {
                    // errorMessage 没有界面消费点，失败必须落到气泡，否则用户发消息石沉大海
                    let userMessage = HoloAIUserErrorMapper.message(for: error)
                    errorMessage = userMessage
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: "目标规划没有完成：\(userMessage) 可以再试一次，或直接用文字告诉我你的目标。",
                        parentMessageId: userMessageId,
                        messageType: .goalPlanning
                    )
                }
            }
        }
    }

    private func handleGoalPlanningReply(_ text: String, session: GoalPlanningSession) async {
        guard let chatRepo else { return }
        inputText = ""
        errorMessage = nil
        let userMessageId = chatRepo.addMessage(role: "user", content: text, messageType: .goalPlanning)
        isStreaming = true
        defer {
            isStreaming = false
            streamingText = ""
        }

        do {
            let userContext = await UserContextBuilder.shared.buildContext()
            let result = try await goalPlanningCoordinator.handleUserReply(
                text,
                session: session,
                userContext: userContext,
                provider: provider
            )
                activeGoalPlanningSession = result.session
                if let question = result.assistantText {
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: strippedGoalPlanningText(
                            question,
                            allowedMemoryIDs: userContext.memorySummary?.sourceIDs ?? []
                        ),
                        parentMessageId: userMessageId,
                        messageType: .goalPlanning
                    )
                }
                if let draft = result.draft {
                    goalDraftForReview = draft
                    let summary = "已根据你的需求生成了目标计划「\(draft.title)」\(draft.cardSummary)"
                    _ = chatRepo.addMessage(
                        role: "assistant",
                    content: summary,
                    parentMessageId: userMessageId,
                    messageType: .goalPlanning
                )
            }
        } catch {
            if let quotaError = error as? HoloQuotaError {
                errorMessage = quotaError.userMessage
                // 同 startGoalPlanning：额度终态必须释放会话，让聊天入口回到普通对话，
                // 不能让用户后续每条消息都被当成规划回答反复撞额度墙。
                activeGoalPlanningSession = nil
                _ = chatRepo.addMessage(
                    role: "assistant",
                    content: quotaError.userMessage,
                    parentMessageId: userMessageId,
                    messageType: .quotaExhausted
                )
            } else {
                // 同上：失败写气泡，避免静默失败
                let userMessage = HoloAIUserErrorMapper.message(for: error)
                errorMessage = userMessage
                _ = chatRepo.addMessage(
                    role: "assistant",
                    content: "目标规划没有完成：\(userMessage) 可以再试一次，或直接用文字告诉我你的目标。",
                    parentMessageId: userMessageId,
                    messageType: .goalPlanning
                )
            }
        }
    }

    func cancelGoalPlanning() {
        activeGoalPlanningSession?.status = .cancelled
        goalDraftForReview = nil
        showGoalDraftReview = false
        _ = chatRepo?.addMessage(
            role: "assistant",
            content: "已取消这次目标规划。",
            messageType: .goalPlanning
        )
        activeGoalPlanningSession = nil
    }

    func markGoalPlanningConfirmed() {
        activeGoalPlanningSession?.status = .confirmed
        goalDraftForReview = nil
        showGoalDraftReview = false
        activeGoalPlanningSession = nil
    }

    func finishGoalPlanningSave(_ result: GoalDraftSaveResult) {
        let extractedData: [String: String] = [
            "goalId": result.goal.id.uuidString,
            "goalTitle": result.goal.title,
            "createdTaskCount": "\(result.createdTaskCount)",
            "createdHabitCount": "\(result.createdHabitCount)"
        ]
        _ = chatRepo?.addMessage(
            role: "assistant",
            content: "已创建目标「\(result.goal.title)」，并生成 \(result.createdTaskCount) 个任务、\(result.createdHabitCount) 个习惯。",
            extractedDataJSON: Self.encodeExtractedData(extractedData),
            messageType: .goalPlanning
        )
        markGoalPlanningConfirmed()
    }

    // MARK: - Session History

    /// 小批量加载更早消息。视口保持由 ChatScrollController 负责，
    /// ViewModel 只暴露明确的成功/失败状态，便于顶部提供轻量重试。
    func loadEarlierSession() async -> ChatHistoryPageResult {
        guard !isLoadingEarlierSession else {
            return .loaded(0, hasEarlierMessages: hasEarlierSessions)
        }
        isLoadingEarlierSession = true
        earlierHistoryLoadFailed = false
        defer { isLoadingEarlierSession = false }

        guard let chatRepo else {
            earlierHistoryLoadFailed = true
            return .failed(hasEarlierMessages: hasEarlierSessions)
        }

        let result = await chatRepo.loadEarlierSessionLightweightMessagesAsync()
        earlierHistoryLoadFailed = result.didFail
        hasEarlierSessions = result.hasEarlierMessages
        return result
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
        case .recordExpense: return "帮我记一笔消费"
        case .createTask: return "帮我创建一个任务"
        case .recordMood: return "记录我现在的心情"
        case .checkIn: return "帮我打卡"
        case .weeklyReport: return "生成本周总结"
        case .createNote: return "帮我记一条笔记"
        case .queryTasks: return "今天有什么待办"
        case .queryHabits: return "今天习惯完成了吗"
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
