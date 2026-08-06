# HoloAI 体验优化 · 详细实施方案

> 日期：2026-08-06 ｜ 状态：实施中 ｜ 范围：15 项整改，纯客户端为主

## 架构关键事实（实施依据）

- **消息流**：`ChatViewModel` → `ChatMessageRepository`（Core Data + snapshot）→ `$messages`（Combine）→ `ChatView`/`MessageBubbleView`
- **流式状态**：`viewModel.isStreaming` + `activeStreamingMessageID` 串联。停止 = `cancelStreaming()` → `finishStreaming(msgID, finalContent:"已停止生成")`
- **Agent 分析**：`ChatViewModel` 调 `analysisService.runAnalysis()`（阻塞 await）。runtime 内部 `progressReporter` 回调每 checkpoint 触发一次，但 Scheduler 只把它喂给了 continued 租约，**没有流回 ChatViewModel**
- **进度文案**：`HoloAgentChatStatusPresenter.detailText(for: step)` 已齐全，`updateAgentMessageProgress(msgID, status:)` 已存在，syncRecoverable 路径已用它。缺的只是「分析运行期间」的实时接线
- **重试现状**：`retryMessage()` 只认 `isError` 消息（靠 content 前缀/后缀判断），删除错误消息后重发用户消息
- **超时**：`startStreamingWatchdog` 90s，超时走 `finishStreaming`，不带 retry
- **DeepLink**：`DeepLinkState.shared.navigate(to:)` + `pendingTarget`，`DeepLinkTarget` 已有 `.ai(voiceInput:)`；缺 `.chat(prefill:)`
- **语音工厂**：`SpeechRecognitionProviderFactory.makeConfiguredProvider()` 固定返回非流式 `HoloBackendSpeechRecognitionProvider`；流式 `AliyunQwenASRRealtimeProvider` 被 `#if DEBUG` 关闭
- **UserContext**：`UserContextBuilder.shared.buildContext()` 无缓存，每次全量聚合 6+ Repository

---

# P0 批次（体验硬伤）

## P0-1 深度分析接入实时进度推送

### 现状
`ChatViewModel.swift:313-324` 发完 initialStatus 后 `await analysisService.runAnalysis(...)` 阻塞，期间无更新。runtime 内 `reportProgress(job, to: progressReporter)` 每个 checkpoint 调用，但 reporter 只服务于 continued 租约。

### ⚠️ 关键事实（红队审查已核实）
现有 `progressReporter` 类型是 `(@Sendable (HoloAgentProgressSnapshot) async -> Void)?`，而 `HoloAgentProgressSnapshot` **只有 jobID/state/totalUnitCount/completedUnitCount/generation，没有 currentStep/waitReason/errorSummary**。`HoloAgentChatStatusPresenter.status(for: HoloAgentJob)` 重度依赖 job.currentStep 和 job.waitReason 生成文案。**不能复用 progressReporter 传 snapshot**，否则文案全退化成默认值。

### 方案（采用「Scheduler 读 jobStore 拿完整 job」路径）
不复用 progressReporter，而是让 Scheduler 在 runLoop 执行 Task 内、每个 checkpoint 之后，额外从 jobStore 读取完整 `HoloAgentJob`，hop 到 MainActor 调用 Chat 注入的 onProgress。

**具体改动**：
1. `HoloAgentStartRequest` 不加闭包（它是 Sendable struct，闭包放不进去）。改为 `HoloAgentScheduler.createAndRun` / `runOrAttach` 新增独立参数：
   ```swift
   func createAndRun(_ request: HoloAgentStartRequest,
                     onProgress: (@Sendable (HoloAgentJob) async -> Void)? = nil) async throws -> HoloAgentJob
   ```
   注意 onProgress 是 `@Sendable` 非 `@MainActor`——Scheduler 是 actor，调用方在闭包内部自己 hop MainActor。这样 Scheduler 不绑定 MainActor。
2. Scheduler 内 runLoop 执行 Task 创建处（:180-216），把 onProgress 透传给一个新的「progress 包装」。但 runtime 的 runLoop 只接受 `progressReporter`——我们**不侵入 runtime**，而是在 Scheduler 执行 Task 里，runtime.runLoop 返回前无法拿中间状态。
   - **真正的接入点**：runtime.runLoop 内部已经在多处调 `reportProgress(job, to: progressReporter)`。我们传入一个**自定义 progressReporter**，它在收到 snapshot 时（snapshot 里有 jobID）去 jobStore 读完整 job，再调 onProgress。
   ```swift
   let chatReporter: (@Sendable (HoloAgentProgressSnapshot) async -> Void)? = onProgress.map { cb in
       { [runtime, jobStore] snapshot in
           // snapshot 触发时 job 已落盘（reportProgress 在 checkpoint save 之后调）
           if let job = try? await jobStore.load().first(where: { $0.id == snapshot.jobID }) {
               await cb(job)
           }
       }
   }
   ```
   传给 runLoop 的 progressReporter 合并原 continued reporter + chatReporter（若两个都存在，依次调）。
3. `HoloAgentAnalysisService.runAnalysis` 加 `onProgress` 参数，透传给 `scheduler.createAndRun(request, onProgress: onProgress)`。
4. ChatViewModel 侧（onProgress 是 @Sendable，内部 hop MainActor）：
```swift
let rendered = await self.analysisService.runAnalysis(
    question: text,
    sourceMessageID: aiMessageId,
    onProgress: { [weak self] job in
        await MainActor.run {
            guard let self else { return }
            let status = HoloAgentChatStatusPresenter.status(for: job)
            guard status.keepsMessageStreaming else { return }
            self.chatRepo?.updateAgentMessageProgress(aiMessageId, status: status)
        }
    }
)
```

### 节流
runtime checkpoint 已稀疏（每轮 LLM/工具批次后一次）。但 chatReporter 每次都读 jobStore（磁盘）——为避免频繁 IO，在 chatReporter 里加 2 秒最小间隔节流（记录 lastReportAt）。

### 边界
- snapshot.jobID 一定能从 jobStore 读到（reportProgress 在 checkpoint save 后调）。
- job 进 `.completed/.failed/.cancelled/.superseded`（全靠 `keepsMessageStreaming` guard 挡）不覆盖最终结果。`HoloAgentChatStatusPresenter` 对终态返回 keepsMessageStreaming=false。
- 取消分析后 runtime 抛 CancellationError，reportProgress 不再触发；即便 cancel 落盘与 runLoop 抛错之间再触发一次，state=.cancelled 被 guard 挡住。安全。
- onProgress 闭包在 Scheduler actor 执行 Task 内运行，jobStore.load() 是该 actor 内合法调用；cb(job) 是 @Sendable，job 是 Sendable struct，跨 actor 安全。

### 文件（4 个必须同提交）
- `Services/AI/Agent/HoloAgentAnalysisService.swift`（runAnalysis 签名）
- `Services/AI/Agent/HoloAgentScheduler.swift`（createAndRun 加参数 + chatReporter 组装 + runOrAttach 透传）
- `Views/Chat/ChatViewModel.swift`（传闭包 + hop MainActor）

### 文件
- `Services/AI/Agent/HoloAgentAnalysisService.swift`（runAnalysis 签名 + 透传）
- `Services/AI/Agent/HoloAgentScheduler.swift`（createAndRun 接 onProgress，包 progressReporter）
- `Models/AI/Agent/HoloAgentExecutionModels.swift`（HoloAgentStartRequest 加 onProgress 字段，注意 @Sendable 闭包不能直接放 Sendable struct → 改为 createAndRun 的独立参数，不放 StartRequest）
- `Views/Chat/ChatViewModel.swift`（传入闭包）

---

## P0-2 停止生成后保留内容 + 可重试

### 现状
`cancelStreaming():562-567` 清空 streamingText 后 `finishStreaming(msgID, finalContent:"已停止生成")`，丢弃已生成内容。且停止的消息无重试入口。

### 方案
```swift
func cancelStreaming() {
    let cancelledMessageID = activeStreamingMessageID
    let partial = streamingText    // 先捕获
    currentTask?.cancel()
    ...
    isStreaming = false
    streamingText = ""
    activeStreamingMessageID = nil
    if let cancelledMessageID {
        let finalContent: String
        if partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalContent = "已停止生成"
        } else {
            finalContent = partial + "\n\n_已停止生成_"
        }
        chatRepo?.finishStreaming(cancelledMessageID, finalContent: finalContent)
    }
    // Agent 取消不变
}
```

### 重试入口
让 `isError` 也覆盖停止的消息。当前 `isError` 判定（ChatMessageViewData:269-271，**注意实际代码是 `抱歉，处理时出错了`，方案早先漏了「出」字**）：
```swift
content.hasPrefix("抱歉，处理时出错了") || content.hasSuffix("处理中断") || content.hasSuffix("响应超时")
```
但更稳妥：**给 AIReadableResponseView 的 onRetry 在「停止」消息上也出现**，但不让它走 isError（红色卡片）。新增独立判定。

**更好方案**：新增一个轻量「重新生成」入口，只在「停止/超时但已有部分内容」的 AI 文本消息底部出现，复用 onRetry 闭包链路（MessageBubbleView 已有 onRetry）。判定条件扩展为一个计算属性 `isRetryableStopped`：
- `!isUser && !isStreaming && !isQuotaExhausted && !isError`
- content 包含「已停止生成」或「响应超时」
- 有 parentMessageId

渲染：在 `AIReadableResponseView` 非错误分支，若 text 含停止标记且 onRetry 存在，底部显示灰色小「重新生成」按钮（区别于红色错误重试）。

### 文件
- `Views/Chat/ChatViewModel.swift`（cancelStreaming 保留内容）
- `Models/ChatMessageViewData.swift`（加 isRetryableStopped）
- `Views/Chat/AIReadableResponseView.swift`（停止态重试按钮）
- `Views/Chat/MessageBubbleView.swift`（停止消息也传 onRetry —— 已传，只要 isError/isRetryableStopped 触发）

### 边界
- retryMessage 删除整条 AI 消息后重发用户消息。停止消息走同样路径，OK。
- **Agent 分析路径（红队审查点）**：cancelStreaming 当前 `:565-567` 无条件 finishStreaming，会把 Agent 分析消息写成文本「已停止生成」。需在 cancelStreaming 判断当前消息是否为 Agent 分析中：
  - 判定方式：检查被取消的消息 `chatRepo?.messageType(for: cancelledMessageID)` 或 `intent == "query_analysis"` 且 `isStreaming`。
  - 若是 Agent 分析：finishStreaming 写「深度分析已取消」，保留为可重试（isRetryableStopped 覆盖）。不深挖 runtime 终态一致性（cancelActiveUserQuestions 会落 cancelled 终态，与 finishStreaming 的内容可共存：消息 content 是展示文案，job 状态在 JobStore）。
- 文档字符串修正：实际代码 isError 用的是「抱歉，处理时出错了」（含「出」字），方案早先漏了，已在本节修正。

---

## P0-3 消息长按菜单：复制 / 重试 / 编辑

### 方案（分三层）

**A. 复制（最快）**：
- 用户气泡：`StreamingTextView` 给用户消息时也加 `.textSelection(.enabled)`。当前 `MessageBubbleView.bubbleContent:272-280` 用户消息走 StreamingTextView。
- contextMenu 加「复制」：用 `UIPasteboard`。对 user/assistant 文本消息都加。
```swift
.contextMenu {
    if !message.isQuotaExhausted, message.agentResult == nil, !message.isStreaming {
        Button { copy(message, displayText) } label: { Label("复制", systemImage: "doc.on.doc") }
    }
    // AI 文本消息：重新生成
    if !isUser && !message.isStreaming && (message.content 包含可重试标记) { ... 重新生成 }
    // 用户消息：编辑
    if isUser && !message.isStreaming { 编辑 }
    ...原有删除记录...
}
```

**B. 重新生成（AI 文本消息）**：
复用 retryMessage 逻辑：删 AI 消息，用其 parentMessage 的 content 重发。入口在 AI 文本消息（非卡片、非分析、非额度）的 contextMenu。

**C. 编辑后重发（用户消息）**：
- contextMenu「编辑」→ 把该用户消息 content 回填到 inputText，并标记 `editingMessageId`
- 发送时：若有 editingMessageId，删除该用户消息 + 其后所有消息（AI 回复也删），再正常 sendMessage
- 新增 `@Published var editingMessageId: UUID?`，ChatInputView 在该值非空时输入框显示「编辑中」提示

### 文件
- `Views/Chat/MessageBubbleView.swift`（contextMenu 扩展 + copy 回调）
- `Views/Chat/ChatView.swift`（注入 onCopy/onRegenerate/onEdit 回调）
- `Views/Chat/ChatViewModel.swift`（startEditing / 编辑重发逻辑 + editingMessageId）
- `Views/Chat/ChatInputView.swift`（编辑态提示）
- `Views/Chat/StreamingTextView.swift`（用户消息 textSelection）

### 边界
- 删除消息的「其后所有消息」：repo 需新增 `deleteMessages(from messageId)`。**删除范围规则（红队审查补）**：删除该用户消息 + 时间戳晚于它的所有同会话消息（含 AI 回复、卡片）。**goalPlanning / periodReplay / quotaExhausted 消息也删**（它们是对话链的一部分，编辑重发意味着重新来过）。实现：`fetchRequest` 按 `timestamp >= 该消息.timestamp` 且 `session == 当前session` 删除。
- 编辑只对普通用户消息（`messageType == .normal`）开放；goalPlanning/periodReplay 期间的 user 消息不支持编辑（避免破坏会话状态机）。
- 复制用 UIPasteboard.general.string，需在主线程。
- **拆分提交（红队审查建议）**：复制单独一提（StreamingTextView + contextMenu + UIPasteboard，可独立编译）；编辑/重试一提（依赖 repo 新方法 + VM）。

---

## P0-4 跨模块「就这条问问 Holo」入口

### ⚠️ 关键事实（红队审查发现致命缺陷）
`ChatView` 的 `prefillText` **只在 `.task{}`(153-170) 消费一次**。ChatView 是常驻视图（HomeView residentDestination），用户已在 AI tab 时，外部再设 prefillText **不会触发 .task 重跑**，prefill 注入失败。必须新增 `.onChange(of: prefillText)`。

### 方案
1. `DeepLinkTarget` 新增 `.chat(prefill: String)`（Equatable 已支持 String）
2. `HomeView`/`ContentView` 监听 pendingTarget，命中 `.chat` 时切到 AI tab + 通过 binding 把 prefill 传给常驻 ChatView
3. **ChatView 新增 `.onChange(of: prefillText) { _, new in guard let new, !new.isEmpty else { return }; viewModel.inputText = new }`**（关键修复，否则对已在 AI 页的用户无效）
4. 在三个高频详情页加「问问 Holo」入口。点击构造 prefill 文案，navigate(to: .chat(prefill:))
5. prefill 回填到输入框，**不自动发送**，让用户确认（与语音保持一致）

### 需查 HomeView 如何常驻 ChatView
（实施时读 HomeView 确认 binding 方式）

### prefill 文案模板
- 想法：「关于这条想法「{前30字}」，帮我展开想想」
- 交易：「这笔「{note} ¥{amount}」是怎么回事？这类支出最近多吗」
- 习惯：「我最近的「{habitName}」怎么样？」

### 文件
- `Services/DeepLinkState.swift`（加 .chat case）
- `Views/HomeView.swift` 或 `ContentView.swift`（路由）
- 三个详情页（实施时定位具体文件）
- `Views/Chat/ChatView.swift`（消费 prefill，已有基础）

### 边界
- 重复点击同一 prefill：DeepLinkState.navigate 已处理「相同目标先清空再异步设」。
- prefill 不自动发送，回填到输入框让用户确认/修改（与语音保持一致体验）。

---

## P0-5 缩短首字延迟（缓存 + 瘦身）

### A. UserContext 短 TTL 缓存（纯前端，立竿见影）
`UserContextBuilder` 加：
```swift
private var cachedContext: UserContext?
private var cachedAt: Date?
private let cacheTTL: TimeInterval = 20  // 秒（黑队建议降到 20s）
private let cacheDay: Date?  // Calendar.startOfDay，跨天失效

func buildContext() async -> UserContext {
    let today = Calendar.current.startOfDay(for: Date())
    if let cachedContext, let cachedAt, let cacheDay,
       cacheDay == today,
       Date().timeIntervalSince(cachedAt) < cacheTTL {
        return cachedContext
    }
    // ...原构建...
    cachedContext = context; cachedAt = Date(); cacheDay = today
    return context
}

func invalidateCache() { cachedContext = nil; cachedAt = nil; cacheDay = nil }
```

**失效钩子（黑队审查必须项）**：
1. **监听 `.profileDidChange` 通知**（HoloProfileService.saveProfile 发此通知）→ invalidateCache()。否则用户改称呼/沟通偏好后 20s 内 AI 用旧 profile，强感知回归。
2. ChatViewModel sendMessage 成功记账/打卡（executionBatch 命中 finance/task）后 → invalidateCache()（保证**下一轮**生效，本轮 LLM 已基于旧 context 答完）。
3. 跨天自动失效（cacheDay 校验）。

**UserContext Sendable**：已核实 UserContext 是纯值类型 struct（String/Int/[String]/可选值类型组合），actor 持有安全（@MainActor UserContextBuilder 本身就在主线程，无需额外 actor）。

### B. 消除记忆摘要重复拉取（红队审查修正）
**原判断有误**：buildContext 的 `.todayState` 检索（无 queryText）与 ChatViewModel chat 分支的 query 匹配检索（`purpose: nil, queryText: text, requireQueryMatch: true`）**是两个不同查询**，不是简单重复。buildContext 那份是通用 todayState 摘要，ChatViewModel 那份是基于当前问题的相关记忆检索。且 buildContext 的 memorySummary 会被 chat 分支 `contextualUserContext.memorySummary = memorySummary` 覆盖——**说明 chat 路径里 buildContext 那份确实被丢弃了**。

**但**：grep 所有 `buildContext()` 调用方（startGoalPlanning/handleGoalPlanningReply/ensureChatRepositoryReady 间接），确认它们是否依赖 memorySummary。
- 保守处理：**不删 buildContext 的 memorySummary 预拉**（避免误伤 goalPlanning 等其他路径），只在 chat 分支确认覆盖关系正确即可。重复查询的浪费留给后续优化。
- **本子项降级为「仅清理 chat 分支的冗余覆盖」**：chat 分支已正确覆盖，无需改。原 P0-5-B 撤销。

### C. 意图识别上下文瘦身
`AIUserContextMessageBuilder.buildIntentRecognitionContext` 已裁剪 task/thought/goal，但仍带交易列表、账户、习惯。意图识别只需日期 + 账户消歧（用户提到钱时）。→ 进一步裁剪：intent 识别不带 recentTransactions / habits / recentTrend，只保留 todayDate + accounts + goalContext(标题级)。chat 模式保持完整。

### 文件
- `Services/AI/UserContextBuilder.swift`（缓存 + 不预拉 memorySummary）
- `Services/AI/AIUserContextMessageBuilder.swift`（intent 识别瘦身）
- `Views/Chat/ChatViewModel.swift`（记账/打卡后 invalidate）

### 边界
- 缓存命中时 profile/todayDate 仍是当时的——用户跨天（过午夜）仍在 TTL 内会用昨天日期。修正：缓存 key 含 `Calendar.startOfDay`，跨天自动失效。
- intent 瘦身后，「今天有什么待办」这类靠 recentTasks 的查询意图识别可能变弱？不——意图识别只需判断「这是 queryTasks 意图」，不需要任务内容本身；内容在 chat 轮注入。OK。
- B 改动：buildContext 不再返回 memorySummary，其他调用 buildContext 的地方（startGoalPlanning/handleGoalPlanningReply）原本也不依赖 memorySummary。安全。

---

# P1 批次（重要提升）

## P1-6 流式期间允许中断并发新消息
ChatInputView：流式期间发送按钮变停止；现在新增——流式期间若 inputText 非空，发送按钮显示为「箭头」，点击 = `cancelStreaming() 然后立即 sendMessage()`。语音按钮仍 disabled。
```swift
if viewModel.isStreaming && !inputText.isEmpty {
    // 发送按钮（中断并发）
    Button { Task { viewModel.cancelStreaming(); await viewModel.sendMessage() } }
} else if viewModel.isStreaming {
    // 停止按钮
}
```
cancelStreaming 是同步的（不等 task 真正结束），sendMessage 会重新建 currentTask。需确保 cancelStreaming 同步释放 activeStreamingMessageID（已做）。sendMessage 开头不检查 isStreaming——加上 `guard !isStreaming else { ... }`？不，cancelStreaming 已同步置 isStreaming=false。OK。

### 文件
- `Views/Chat/ChatInputView.swift`

### 边界
- cancelStreaming 后旧 task 可能仍在跑（network 取消异步）。sendMessage 新建 activeStreamingMessageID，旧 task 的 catch 分支有 `guard self.activeStreamingMessageID == aiMessageId else { return }` 保护，不会写回。安全。

## P1-7 超时策略重做
- watchdog 90s → 45s
- 新增首字超时：`@Published var streamingSlowHint`。watchdog 分两段：15s 检查 streamingText.isEmpty → 提示；45s 终止。
- 超时消息标记可重试：走 finalizeMessage 且 content 含「响应超时」→ isError/isRetryableStopped 已覆盖重试入口。

### 文件
- `Views/Chat/ChatViewModel.swift`（watchdog 重写）

## P1-8 统一等待状态语言
- 意图理解阶段（isStreaming && streamingText.isEmpty）：typingIndicator 改文案为「正在思考…」（当前是三点无文字）。在 typingIndicator 旁加小字。
- 流式光标：`AIReadableResponseView.streamingText` 的 `HStack(alignment: .bottom)` 光标错位 → 改用 Text 拼接光标字符进同一段 AttributedString，或 alignment 改 `.firstTextBaseline`。
- StreamingTextView 同样修正。

### 文件
- `Views/Chat/AIReadableResponseView.swift`
- `Views/Chat/StreamingTextView.swift`

## P1-9 语音流式识别上生产
- 移除 `AliyunQwenASRRealtimeProvider` 的 `#if DEBUG`（改 `#if !RELEASE` 或直接去掉）
- 工厂按配置返回 streaming provider：`makeConfiguredProvider` 先尝试 streaming，失败 fallback 非流式
- **风险高**：需后端 ASR 流式接口生产可用。**本次保守处理**：保留 DEBUG 门控，但加配置开关 `HoloAIFeatureFlags.streamingASREnabled`，默认 false；并清理 pendingAudioBuffers 死代码（流式未启用时不缓冲）。生产开启待后端确认。

### 文件
- `Services/Speech/AliyunQwenASRRealtimeProvider.swift`
- `Services/Speech/SpeechRecognitionProvider.swift`（工厂）
- `Views/Chat/Voice/VoiceInputViewModel.swift`（死代码清理）

### 注：本项标注「需后端发版」，本次只做死代码清理 + 开关预留，不实际开启生产流式。

## P1-10 新手示例提问引导
ChatEmptyStateView 已有 capability 卡片。补充：输入框聚焦且为空时，在输入框上方显示一行可横滑的真实示例（"午餐花了38""这周睡得怎么样"），点击回填不发送。
- 简化：直接在 ChatEmptyStateView 的卡片后加一组「或者试试」示例气泡（已有 capabilities 已够，主要增强文案）。本次主要优化 previewPrompt 文案 + 新用户多加 2 条生活化示例。

### 文件
- `Views/Chat/ChatEmptyStateView.swift`

## P1-11 消息收藏 / 分享
- 新增轻量收藏存储：`ChatMessageRepository` 加 `toggleStar(messageId)` + starredMessages 查询；ChatMessage 模型加 `isStarred` 字段（需 Core Data 迁移）。
- **Core Data 迁移风险**：加字段需 lightweight migration。本次保守：收藏暂存 UserDefaults（messageId 列表），不改 Core Data。长期应迁 DB。
- AI 文本消息 contextMenu 加「收藏」/「分享」。分享用系统 `UIActivityViewController`。

### 文件
- 新增 `Services/ChatMessageStarStore.swift`（UserDefaults 封装）
- `Views/Chat/MessageBubbleView.swift`（菜单项）
- `Views/Chat/ChatView.swift`（分享 sheet）

## P1-12 深度分析失败加重试 + 简单查询降级
- 失败卡片（agentResult.failure == .analysisFailed）加「重试分析」按钮，复用 sourceMessageID 重发。
- 简单查询降级：`HoloAgentBudgetSelector` 已存在，本次不深入改预算选择（风险大）。仅加：失败时如果用户问题像简单查询（短、含「多少/几个/总和」），给「先用快速回答」降级提示。保守，不强改 budget。

### 文件
- `Views/Chat/Analysis/AgentDeepAnalysisCard.swift`（失败态卡片）
- `Views/Chat/ChatViewModel.swift`（retryAnalysis 方法）

---

# P2 批次（打磨）

## P2-13 数据卡片体验打磨
- 趋势卡颜色按语义（AnalysisTrendChatCard）：加 `positiveIsGood: Bool` 参数，由调用方按指标语义传入。
- 待确认卡片取消二次确认（cancelPendingTransaction 加 confirmationDialog）。
- 心情/体重/习惯卡片底部时间用消息 timestamp 相对时间。
- 额度卡片加会员图标区分错误。

### 文件
- `Views/Chat/Cards/AnalysisChatCard.swift`
- `Views/Chat/Cards/MoodChatCard.swift` / `WeightChatCard.swift` / `HabitCheckInChatCard.swift`
- `Views/Chat/Cards/TransactionChatCard.swift`
- `Views/Chat/QuotaExhaustedChatCard.swift`
- `Views/Chat/ChatViewModel.swift`（cancel 二次确认）

## P2-14 历史与草稿体验修正
- 历史加载头：接近顶部时显示「加载更多」轻提示（非透明）。改 historyLoadingHeader 默认态。
- 草稿按用户隔离：inputDraftKey 加 userId 前缀。需拿到当前用户 id。
- 空状态与 QuickActionBar 去重：空状态用示例问题，常驻栏用快捷动作——本次调文案区分。

### 文件
- `Views/Chat/ChatView.swift`（historyLoadingHeader）
- `Views/Chat/ChatViewModel.swift`（草稿 key）
- `Views/Chat/ChatEmptyStateView.swift` / `QuickActionBar.swift`

## P2-15 网络层健壮性补强
- APIClient 开启 `waitsForConnectivity = true`（配 resource timeout 兜底）。
- SSEParser 解码失败记日志。
- AgentDeepAnalysisDetailSheet LazyVStack。
- 录音启动空白态优化（权限已授予跳过 requestingPermission）。
- 后台任务与前台聊天优先级：ThoughtOrganizationQueue 加「前台聊天活跃时延迟」判断。

### 文件
- `Services/Network/APIClient.swift`
- `Services/Network/SSEParser.swift`
- `Views/Chat/Analysis/AgentDeepAnalysisDetailSheet.swift`
- `Views/Chat/Voice/VoiceInputViewModel.swift`
- `Services/AI/ThoughtOrganizationQueue.swift`

---

---

# 两轮自审结论汇总（实施时必须遵守的护栏）

**第一轮（红队·健壮性）已修正**：
- P0-1：不复用 progressReporter 传 snapshot（缺 currentStep），改为 chatReporter 内 jobStore.load() 拿完整 job
- P0-2：isError 字符串「抱歉，处理时出错了」（含「出」字）；Agent 路径 cancelStreaming 需判定分支
- P0-3：编辑重发删除范围按 timestamp+session 边界；复制/编辑拆两个提交
- P0-4：ChatView 必须加 `.onChange(of: prefillText)`（.task 只消费一次）
- P0-5-B：撤销（buildContext 的 memorySummary 预拉是另一查询，不删）

**第二轮（黑队·派生 bug）必须遵守**：
1. P0-5：UserContextBuilder 监听 `.profileDidChange` → invalidateCache（必出 bug 否则）
2. P1-6：Agent 分支 finalize 前加 `guard activeStreamingMessageID == aiMessageId`（:325 后 :347 前）
3. P0-1：chatReporter 第一行判 lastReportAt，未到 2s 直接 return，绝不先 load
4. P0-3：deleteMessages 带 session 边界（gap<4h）；删 Agent 消息时 cancel 对应 job
5. P2-13：AnalysisTrendCardData.positiveIsGood 无默认值，5 个构造点显式传

---

# 实施顺序（单批次内独立提交）

1. P0-1（分析进度）
2. P0-2（停止保留）
3. P0-3（长按菜单-复制先行，编辑后做）
4. P0-4（跨模块入口）
5. P0-5（缓存+瘦身）
6. P1-6~P1-8（中断并发/超时/等待态，同一批）
7. P1-9（语音死代码清理，不启生产）
8. P1-10~P1-12（引导/收藏/分析降级）
9. P2-13~P2-15（打磨）
10. 编译验证

每项改完即编译，避免错误堆积。
