# HOLO AI 通用分析查询功能实施方案

## Context

Holo AI 聊天当前只能通过 `UserContextBuilder` 访问有限的即时上下文，其中财务数据只覆盖当天交易，导致用户询问"分析我 2024 年的消费""分析我上个月的习惯打卡""看看这周任务完成情况"时，AI 缺少可靠的周期数据。

但现有系统已经具备周期级数据能力：
- `MemoryInsightContextBuilder` 已能构建 finance / habits / tasks / thoughts 的周期上下文。
- `FinanceRepository+Aggregation` 已提供财务聚合查询。
- `HabitRepository`、`TodoRepository`、`ThoughtRepository` 已提供习惯、任务、想法相关统计基础。

本方案不再做单独的"财务分析查询"，而是将能力抽象为通用的 **AI 分析查询框架**，支持财务、习惯、任务、想法和跨模块复盘。

## 核心设计决策

**结构化数据来自本地 Analysis Context Builder，分析文本来自 LLM。**

不采用让 LLM 输出 JSON 卡片数据的方案，而是：
1. Coordinator 拦截 `query_analysis` 意图。
2. 本地 resolver 解析分析领域、周期、对比周期。
3. 对应的 AnalysisContextBuilder 调用 Repository 获取真实数据。
4. Context 同时用于生成卡片数据和注入 LLM。
5. LLM 只负责基于注入数据生成 Markdown 分析文本。
6. 卡片从本地 Context 直接渲染，不依赖 LLM 输出格式。

**分析查询不携带历史消息。** 分析所需的全部数据已在 AnalysisContext JSON 中提供，历史对话只有噪声没有增益。LLM 请求固定为 `system prompt → analysis context JSON → current user question`，共三层。

### 本版硬约束

1. **分析上下文必须持久化**：`AnalysisContext` 必须随 assistant 消息写入 Core Data，保证历史消息、重启 App、重新加载后仍能渲染卡片。
2. **分析查询发送零历史消息**：LLM 请求固定为 `system prompt → analysis context JSON → current user question`。不携带任何之前的聊天记录，避免上下文污染。
3. **日期范围由本地代码兜底和归一化**：LLM 只提供候选日期，本地 resolver 负责缺失、非法、结束早于开始等情况；所有日期查询统一使用 `[start.startOfDay, end.startOfDay + 1 day)`。
4. **领域特定数据不能跨语义误用**：例如预算只在财务且区间匹配当前周/月时展示；任务逾期只用于任务分析；习惯 streak 只用于习惯分析。
5. **卡片模型必须可编译、可编码、可测试**：避免在 `Equatable` 模型中使用元组数组，使用命名 row/point 结构体。
6. **卡片与文本叠加渲染**：分析消息先渲染分析卡片列表，再渲染 Markdown 文本。不同于现有消息的互斥渲染（多卡 > 单卡 > 文本），分析消息始终显示两者。

### Token 预算约束

| 数组字段 | 上限 | 说明 |
|----------|------|------|
| `topExpenseCategories` | 5 | Top 5 分类 |
| `monthlyBreakdown` | 12 | 最多 12 个月 |
| `dailyCompletionTrend` | 31 | 最多 31 个趋势点，超过则按周聚合 |
| `dailyThoughtTrend` | 31 | 同上 |
| `topPerformingHabits` | 5 | Top 5 |
| `strugglingHabits` | 3 | 最多 3 个 |
| `streaks` | 5 | 最多 5 个 |
| `importantCompletedTasks` | 5 | 最多 5 个 |
| `recentSnippets` | 5 | 最多 5 条，每条截断 200 字 |
| `anomalyDescriptions` | 5 | 最多 5 条异常 |
| `correlationDescriptions` | 5 | 最多 5 条（跨模块模式为 highlights 替代） |
| AnalysisContext JSON 总量 | ≤ 4000 token | 约 8KB，超过则降级聚合粒度 |

---

## Phase 1：意图识别与通用数据模型

### 1.1 AIModels.swift — 新增通用分析意图

**文件**：`Models/AI/AIModels.swift`

```swift
case queryAnalysis = "query_analysis"
```

更新 `queryIntents`：

```swift
nonisolated static let queryIntents: Set<AIIntent> = [
    .query,
    .queryTasks,
    .queryHabits,
    .queryAnalysis
]
```

### 1.2 新建 AnalysisDomain.swift

**新文件**：`Models/AI/AnalysisDomain.swift`

```swift
enum AnalysisDomain: String, Codable, Equatable, Sendable {
    case finance
    case habit
    case task
    case thought
    case crossModule
}
```

意图提取字段：

```swift
analysisDomain: "finance" | "habit" | "task" | "thought" | "crossModule"
startDate: "yyyy-MM-dd"?
endDate: "yyyy-MM-dd"?
periodLabel: String?
comparisonStartDate: "yyyy-MM-dd"?
comparisonEndDate: "yyyy-MM-dd"?
```

领域判断规则：
- "消费 / 支出 / 收入 / 预算 / 账单 / 财务" → `finance`
- "习惯 / 打卡 / 连续 / 完成率" → `habit`
- "任务 / 待办 / 完成 / 逾期 / 优先级" → `task`
- "想法 / 记录 / 情绪 / 标签 / 观点" → `thought`
- "复盘 / 状态 / 综合分析 / 最近过得怎么样" → `crossModule`

如果用户只说"分析一下最近一个月"，没有明确领域，默认走 `crossModule`。

### 1.3 新建 AnalysisContext.swift

**新文件**：`Models/AI/AnalysisContext.swift`

```swift
struct AnalysisContext: Codable, Equatable, Sendable {
    let domain: AnalysisDomain
    let periodLabel: String
    let startDate: String
    let endDate: String
    let comparisonLabel: String?
    let finance: FinanceAnalysisContext?
    let habit: HabitAnalysisContext?
    let task: TaskAnalysisContext?
    let thought: ThoughtAnalysisContext?
    let crossModule: CrossModuleAnalysisContext?
}

extension AnalysisContext {
    /// 所有领域 context 都为 nil 或其数据全为零值时视为空
    var isEmpty: Bool {
        let hasFinance = finance != nil && !finance!.isDataFree
        let hasHabit = habit != nil && !habit!.isDataFree
        let hasTask = task != nil && !task!.isDataFree
        let hasThought = thought != nil && !thought!.isDataFree
        let hasCrossModule = crossModule != nil && !crossModule!.isDataFree
        return !hasFinance && !hasHabit && !hasTask && !hasThought && !hasCrossModule
    }
}
```

规则：
- 单领域分析只填对应 context。
- `crossModule` 可以填多个模块 context，并额外填 `crossModule` 的摘要数据。
- `startDate` / `endDate` 是用户可见闭区间字符串。
- 各领域 context 需实现 `isDataFree: Bool`（例如 finance 的 totalExpense == 0 && totalIncome == 0 && transactionCount == 0）。

### 1.4 领域 Context 模型

**新文件**：`Models/AI/AnalysisDomainContexts.swift`

财务：

```swift
struct FinanceAnalysisContext: Codable, Equatable, Sendable {
    let totalExpense: Decimal
    let totalIncome: Decimal
    let transactionCount: Int
    let averageDailyExpense: Decimal
    let topExpenseCategories: [FinanceCategoryItem]   // ≤ 5
    let monthlyBreakdown: [FinanceMonthlyItem]         // ≤ 12
    let previousPeriodExpense: Decimal?
    let anomalyDescriptions: [String]                  // ≤ 5
    let budgetPerformance: FinanceBudgetItem?

    var isDataFree: Bool {
        totalExpense == 0 && totalIncome == 0 && transactionCount == 0
    }
}
```

习惯：

```swift
struct HabitAnalysisContext: Codable, Equatable, Sendable {
    let activeHabitCount: Int
    let completedRecordCount: Int
    let averageCompletionRate: Double?
    let topPerformingHabits: [HabitPerformanceItem]    // ≤ 5
    let strugglingHabits: [HabitPerformanceItem]       // ≤ 3
    let streaks: [HabitStreakItem]                     // ≤ 5
    let dailyCompletionTrend: [DailyRatePoint]         // ≤ 31
    let previousPeriodCompletedRecordCount: Int?

    var isDataFree: Bool {
        activeHabitCount == 0 && completedRecordCount == 0
    }
}
```

任务：

```swift
struct TaskAnalysisContext: Codable, Equatable, Sendable {
    let totalCount: Int
    let completedCount: Int
    let overdueCount: Int
    let completionRate: Double
    let highPriorityCompletionRate: Double?
    let importantCompletedTasks: [String]              // ≤ 5
    let dailyCompletionTrend: [DailyCountPoint]        // ≤ 31
    let previousPeriodCompletedCount: Int?

    var isDataFree: Bool {
        totalCount == 0
    }
}
```

想法：

```swift
struct ThoughtAnalysisContext: Codable, Equatable, Sendable {
    let totalCount: Int
    let moodDistribution: [MoodDistributionItem]
    let topTags: [String]                              // ≤ 5
    let recentSnippets: [String]                       // ≤ 5, 每条 ≤ 200 字
    let dailyThoughtTrend: [DailyCountPoint]           // ≤ 31

    var isDataFree: Bool {
        totalCount == 0
    }
}
```

跨模块（第一版只做各模块摘要并列，不做统计关联）：

```swift
struct CrossModuleAnalysisContext: Codable, Equatable, Sendable {
    let highlights: [String]   // ≤ 5, 各模块亮点摘选
    let warnings: [String]     // ≤ 3, 各模块风险提示

    var isDataFree: Bool {
        highlights.isEmpty && warnings.isEmpty
    }
}
```

所有数组元素使用命名结构体，例如 `DailyRatePoint`、`DailyCountPoint`、`FinanceCategoryItem`，不使用元组数组。

### 1.5 新建 AnalysisPeriodResolver.swift

**新文件**：`Services/AI/AnalysisPeriodResolver.swift`

职责：
- 输入：`extractedData`、用户原文、`referenceDate = Date()`。
- 输出：

```swift
struct ResolvedAnalysisRequest: Equatable {
    let domain: AnalysisDomain
    let start: Date
    let end: Date
    let startDateString: String
    let endDateString: String
    let periodLabel: String
    let comparisonStart: Date?
    let comparisonEnd: Date?
    let comparisonLabel: String?
}
```

兜底规则：
- 日期都合法：使用 LLM 提取结果。
- 缺任一日期：
  - 包含年份：该年 1 月 1 日 ~ 12 月 31 日。
  - 包含"上个月/本月/这个月"：对应自然月。
  - 包含"本周/上周"：对应自然周。
  - 包含"今年/去年"：对应自然年。
  - 其他情况：最近 30 天。
- 如果 `end < start`，回退到最近 30 天并记录日志。
- comparison 日期缺失时，根据当前区间推导上一等长区间；如果用户明确"对比去年"，使用去年同区间。

### 1.6 PromptManager.swift — 更新意图识别 prompt

新增 `query_analysis`：

```text
- query_analysis: 周期性数据分析、趋势分析、复盘、对比总结
  提取字段：analysisDomain, startDate?, endDate?, periodLabel?, comparisonStartDate?, comparisonEndDate?
```

规则：
- "分析我2024年的消费" → `query_analysis` + `analysisDomain=finance`
- "分析我上个月的习惯打卡" → `query_analysis` + `analysisDomain=habit`
- "看看我这周任务完成情况" → `query_analysis` + `analysisDomain=task`
- "复盘一下最近一个月" → `query_analysis` + `analysisDomain=crossModule`
- 简单查询如"今天花了多少""我还有几个任务"仍走现有 `query` / `queryTasks` / `queryHabits`。

Prompt 里要明确：日期和领域是"尽量提取"，最终以本地 resolver 为准。

---

## Phase 2：Analysis Context Builder 与 Coordinator 拦截

### 2.0 前置：补齐 Repository 统计方法

TodoRepository 已有 `DailyTaskCount` 和 `TaskPeriodStats` 模型定义，但无实现方法。需先补齐：

```swift
// TodoRepository.swift 新增
func getTaskPeriodStats(from start: Date, to end: Date) async -> TaskPeriodStats
func getDailyTaskCounts(from start: Date, to end: Date) async -> [DailyTaskCount]
```

HabitRepository 和 ThoughtRepository 的现有统计方法已足够，但需确认 `getDailyAggregatedData` 等方法支持自定义日期范围（而非仅固定周期）。

### 2.1 新建 AnalysisContextBuilder.swift

**新文件**：`Services/AI/AnalysisContextBuilder.swift`

```swift
struct AnalysisContextBuilder {
    func build(request: ResolvedAnalysisRequest) async -> AnalysisContext
}
```

内部按领域分发：

```swift
switch request.domain {
case .finance:
    finance = await FinanceAnalysisContextBuilder().build(request: request)
case .habit:
    habit = await HabitAnalysisContextBuilder().build(request: request)
case .task:
    task = await TaskAnalysisContextBuilder().build(request: request)
case .thought:
    thought = await ThoughtAnalysisContextBuilder().build(request: request)
case .crossModule:
    // 并发构建各模块，不串行
    async let f = FinanceAnalysisContextBuilder().build(request: request)
    async let h = HabitAnalysisContextBuilder().build(request: request)
    async let t = TaskAnalysisContextBuilder().build(request: request)
    async let th = ThoughtAnalysisContextBuilder().build(request: request)
    (finance, habit, task, thought) = await (f, h, t, th)
    crossModule = CrossModuleAnalysisContextBuilder().build(
        finance: finance, habit: habit, task: task, thought: thought
    )
}
```

所有 builder 统一使用：

```swift
let startInclusive = request.start.startOfDay
let endExclusive = request.end.startOfDay.addingDays(1)
```

### 2.2 领域 Builder

新增：
- `FinanceAnalysisContextBuilder.swift`
- `HabitAnalysisContextBuilder.swift`
- `TaskAnalysisContextBuilder.swift`
- `ThoughtAnalysisContextBuilder.swift`
- `CrossModuleAnalysisContextBuilder.swift`

复用原则：
- 能从 `MemoryInsightContextBuilder` 抽取的逻辑，优先抽成共享 helper（如日期边界处理、分类聚合格式化），避免复制一份偏离版本。
- 如果已有 Repository 查询粒度不够，先补小范围聚合方法，不把统计逻辑塞到 ViewModel。

预算表现规则：
- 只在 `domain == .finance` 或 `crossModule` 的财务子上下文中出现。
- 只有区间等于当前自然周时使用 `.week`。
- 只有区间等于当前自然月时使用 `.month`。
- 年度、季度、自定义区间不生成预算表现。

CrossModuleAnalysisContextBuilder 规则：
- **第一版不做统计关联分析**。只从各模块 context 中提取亮点和风险：
  - highlights：每个有数据的模块取 1 条最突出的正向指标。
  - warnings：每个有数据的模块取 1 条最突出的风险指标。
- 不生成 `correlationDescriptions`，避免无统计学依据的因果暗示。

### 2.3 ConversationCoordinator.swift — 拦截通用分析意图

扩展 `ConversationProcessResult`（破坏性变更，所有构造点需更新）：

```swift
struct ConversationProcessResult {
    // ... 现有 6 个字段
    let analysisContext: AnalysisContext?  // 新增
}
```

在纯查询分支前添加：

```swift
if parseBatch.mode == .query,
   parseBatch.items.count == 1,
   parseBatch.first?.intent == .queryAnalysis {
    let request = AnalysisPeriodResolver.resolve(
        extractedData: parseBatch.first?.extractedData,
        originalText: text,
        referenceDate: Date()
    )

    let context = await AnalysisContextBuilder().build(request: request)

    if context.isEmpty {
        return ConversationProcessResult(
            finalText: "在 \(request.periodLabel) 期间没有可分析的数据。你可以换一个时间范围试试。",
            ...,
            shouldStreamChat: false,
            analysisContext: nil
        )
    }

    return ConversationProcessResult(
        finalText: "",
        ...,
        shouldStreamChat: true,
        analysisContext: context
    )
}
```

`queryAnalysis` 不允许因为 LLM 漏提日期或领域而退回普通查询路径。

---

## Phase 3：Provider 与流式对话

### 3.1 AIProvider.swift — 扩展现有协议

不新增 `analysisStreaming` 方法。扩展现有 `chatStreaming` 签名：

```swift
protocol AIProvider {
    // ... 现有方法

    // 扩展参数，默认值保持向后兼容
    func chatStreaming(
        messages: [ChatMessageDTO],
        userContext: UserContext,
        systemContextOverride: String?,
        promptType: PromptType
    ) -> AsyncThrowingStream<String, Error>
}
```

默认值让现有调用无需修改：

```swift
extension AIProvider {
    func chatStreaming(
        messages: [ChatMessageDTO],
        userContext: UserContext
    ) -> AsyncThrowingStream<String, Error> {
        chatStreaming(
            messages: messages,
            userContext: userContext,
            systemContextOverride: nil,
            promptType: .systemPrompt
        )
    }
}
```

### 3.2 OpenAICompatibleProvider.swift — 实现分析调用

分析查询时的调用方式：

```swift
// ChatViewModel 中
let contextJSON = encode(analysisContext)
let stream = self.provider.chatStreaming(
    messages: [],  // 零历史消息
    userContext: UserContext.empty,  // 不需要即时上下文
    systemContextOverride: contextJSON,
    promptType: .analysisPrompt  // 新 PromptType
)
```

Provider 内部实现：

```swift
func chatStreaming(
    messages: [ChatMessageDTO],
    userContext: UserContext,
    systemContextOverride: String?,
    promptType: PromptType
) -> AsyncThrowingStream<String, Error> {
    let systemPrompt = PromptManager.shared.prompt(for: promptType)

    var allMessages: [ChatMessageDTO] = [
        .system(systemPrompt)
    ]

    // 分析模式：注入 context JSON 作为第二条 system message
    if let contextOverride = systemContextOverride {
        allMessages.append(.system(contextOverride))
    }

    // 分析模式下 messages 为空，普通模式携带历史
    allMessages.append(contentsOf: messages)

    // 最后追加当前用户问题
    allMessages.append(.user(currentQuestion))

    let request = buildRequest(messages: allMessages, stream: true, temperature: 0.3)
    return apiClient.sendStreaming(request)
}
```

### 3.3 PromptManager.swift — 新增分析 prompt

沿用内联模板模式（与现有 prompt 一致），新增 `PromptType` case：

```swift
case analysisPrompt = "analysis_prompt"
```

Prompt 内容要点：
- 只使用提供的数据，禁止编造数字。
- 数字必须和 JSON 上下文一致。
- 不输出 JSON。
- 输出 Markdown 文本。
- 财务侧重消费趋势、分类占比、异常、预算。
- 习惯侧重完成率、连续性、掉队习惯、可持续建议。
- 任务侧重完成率、逾期、高优先级、执行节奏。
- 想法侧重情绪、标签、主题变化。
- 跨模块侧重各模块状态摘要，区分"数据支持的观察"和"建议"。

### 3.4 MockAIProvider.swift

返回基于 `analysisContext.domain` 的静态分析文本。

---

## Phase 4：持久化、ViewModel 与消息渲染

### 4.0 Core Data 与 ChatMessageRepository — 持久化分析上下文

**Core Data schema 是纯代码定义的**（非 .xcdatamodeld），修改位置：

| 文件 | 改动 |
|------|------|
| `CoreDataStack+ChatEntities.swift` | 新增 `NSAttributeDescription` for `analysisContextJSON` |
| `ChatMessage+CoreDataProperties.swift` | 新增 `@NSManaged var analysisContextJSON: String?` |

新增字段：

| 字段 | 类型 | 用途 |
|------|------|------|
| `analysisContextJSON` | String? | assistant 消息对应的 `AnalysisContext` JSON |

**Core Data 迁移**：新增可选 String 字段支持自动轻量迁移，旧消息该字段为 nil。需在验证中覆盖升级场景。

Repository 改动：
- `loadMessagesAsync(propertiesToFetch:)` 加入 `analysisContextJSON`。
- `ChatMessageViewData.init(message:)` 和 `init(dictionary:)` 读取该字段。
- `finalizeMessage(...)` 增加参数：

```swift
func finalizeMessage(
    _ messageId: UUID,
    finalContent: String,
    intent: String?,
    extractedDataJSON: String?,
    parsedBatchJSON: String?,
    executionBatchJSON: String?,
    analysisContextJSON: String?  // 新增
)
```

- snapshot 更新时同步解码 `AnalysisContext`。
- 非分析消息传 `nil`。

### 4.1 ChatViewModel.swift — 分流处理

在 `shouldStreamChat` 分支中：

```swift
if processResult.shouldStreamChat {
    if let analysisContext = processResult.analysisContext {
        // 分析路径：零历史消息，独立 system context
        let contextJSON = encode(analysisContext)

        let stream = self.provider.chatStreaming(
            messages: [],
            userContext: UserContext.empty,
            systemContextOverride: contextJSON,
            promptType: .analysisPrompt
        )

        // 同样的流式循环
        // finalizeMessage 时传入 analysisContextJSON
    } else {
        // 标准查询路径（保持现有逻辑不变）
    }
}
```

### 4.2 ChatMessageViewData.swift

```swift
var analysisContext: AnalysisContext?

var analysisCards: [ChatCardData] {
    guard let context = analysisContext else { return [] }
    return ChatCardData.fromAnalysisContext(context)
}
```

JSON 解码时机：在 `init(message:)` 和 `init(dictionary:)` 中从 `analysisContextJSON` 解码，解码失败时 `analysisContext = nil` 并记录日志（不影响消息显示）。

### 4.3 ChatCardData.swift — 新增通用分析卡片

推荐第一版只做高价值通用卡片，避免一次做太多 UI：

```swift
case analysisSummary(AnalysisSummaryCardData)
case analysisTrend(AnalysisTrendCardData)
case analysisBreakdown(AnalysisBreakdownCardData)
case analysisComparison(AnalysisComparisonCardData)
case analysisHighlights(AnalysisHighlightsCardData)
```

卡片映射：
- finance：summary / breakdown / trend / comparison。
- habit：summary / trend / highlights。
- task：summary / trend / highlights / comparison。
- thought：summary / breakdown / trend。
- crossModule：summary / highlights。

`fromAnalysisContext` 规则：
- 每个 domain 按映射表生成卡片。
- 如果对应数据为零值（如 comparison 数据为空），不生成该卡片。
- 不生成空内容的卡片。

命名 row/point 结构：

```swift
struct AnalysisBreakdownRow: Equatable, Codable {
    let label: String
    let value: String
    let percent: Double?
}

struct AnalysisTrendPoint: Equatable, Codable {
    let label: String
    let value: Double
    let displayValue: String
}
```

### 4.4 MessageBubbleView.swift — 叠加渲染

**当前渲染是互斥的（多卡 > 单卡 > 文本）。分析消息需要叠加渲染。**

新增分析卡片渲染分支：

```swift
// 分析消息：卡片 + 文本叠加
if !message.analysisCards.isEmpty {
    VStack(alignment: .leading, spacing: 8) {
        // 1. 渲染分析卡片列表
        ForEach(message.analysisCards) { card in
            cardView(for: card)
        }
        // 2. 渲染 Markdown 文本（可能还在流式）
        if !message.content.isEmpty {
            bubbleContent(text: message.content, isStreaming: message.isStreaming)
        }
    }
} else {
    // 现有渲染逻辑不变
    // multi-card > single-card > text bubble（互斥）
}
```

渲染优先级（最终三路）：
1. **analysisCards 非空**：叠加模式，先卡片后文本。executionCards 和 cardData 忽略。
2. **executionCards 非空**：现有互斥逻辑，显示批处理卡片。
3. **cardData 非空**：现有互斥逻辑，显示单卡片。
4. 否则：显示文本气泡。

### 4.5 错误处理策略

| 场景 | 处理 |
|------|------|
| Repository 查询抛异常 | Builder 捕获异常，对应 domain context 设为 nil，其他领域继续构建 |
| AnalysisContext JSON 编码失败 | 记录日志，analysisContextJSON 传 nil，消息仍以纯文本渲染（无卡片） |
| LLM 流式中途断连 | 使用已收到的 partial text 调用 finalizeMessage，卡片数据已在本地不受影响 |
| AnalysisContext JSON 解码失败（历史消息加载时） | analysisContext 设为 nil，消息以纯文本渲染，记录日志 |
| AnalysisPeriodResolver 日期不可用 | 回退到最近 30 天，记录日志 |
| 所有领域数据都为空 | Coordinator 直接返回提示文本，不调用 LLM |

---

## Phase 5：卡片 UI 视图

**新文件**：`Views/Chat/Cards/AnalysisChatCard.swift`

复用现有 `ChatCardView`、`CardHeaderView`、`CardDivider`、`CardBadge`。

| 卡片 | 用途 |
|------|------|
| `AnalysisSummaryChatCard` | 展示领域、周期、核心指标 |
| `AnalysisTrendChatCard` | 展示日/周/月趋势 |
| `AnalysisBreakdownChatCard` | 展示分类、情绪、标签等占比 |
| `AnalysisComparisonChatCard` | 展示当前周期 vs 上周期 |
| `AnalysisHighlightsChatCard` | 展示亮点、风险、建议 |

UI 第一版不做复杂交互下钻，只保证信息可靠、可读、可持久化。

---

## 文件清单

### 新建文件

| 文件 | 说明 |
|------|------|
| `Models/AI/AnalysisDomain.swift` | 分析领域枚举 |
| `Models/AI/AnalysisContext.swift` | 通用分析上下文 + isEmpty 判定 |
| `Models/AI/AnalysisDomainContexts.swift` | 各领域上下文模型 + isDataFree 判定 |
| `Services/AI/AnalysisPeriodResolver.swift` | 日期/领域兜底解析 |
| `Services/AI/AnalysisContextBuilder.swift` | 通用 builder 分发 |
| `Services/AI/FinanceAnalysisContextBuilder.swift` | 财务上下文 |
| `Services/AI/HabitAnalysisContextBuilder.swift` | 习惯上下文 |
| `Services/AI/TaskAnalysisContextBuilder.swift` | 任务上下文 |
| `Services/AI/ThoughtAnalysisContextBuilder.swift` | 想法上下文 |
| `Services/AI/CrossModuleAnalysisContextBuilder.swift` | 跨模块上下文（摘要并列，无关联分析） |
| `Views/Chat/Cards/AnalysisChatCard.swift` | 通用分析卡片 UI |

### 修改文件

| 文件 | 改动 |
|------|------|
| `Models/AI/AIModels.swift` | 新增 `queryAnalysis` |
| `Services/AI/PromptManager.swift` | 新增 `analysisPrompt` PromptType + 意图识别更新 + 内联分析 prompt |
| `Services/AI/ConversationCoordinator.swift` | 拦截 `queryAnalysis`，`ConversationProcessResult` 新增 `analysisContext`（所有构造点更新） |
| `Services/AI/AIProvider.swift` | `chatStreaming` 新增 `systemContextOverride` / `promptType` 参数（默认值保持向后兼容） |
| `Services/AI/OpenAICompatibleProvider.swift` | 实现扩展参数的分析流式对话 |
| `Services/AI/MockAIProvider.swift` | 默认实现 |
| `Views/Chat/ChatViewModel.swift` | 分析分流 + 零历史 + 持久化 JSON |
| `Models/ChatMessageViewData.swift` | `analysisContext` 字段 + JSON 解码 + `analysisCards` |
| `Data/Repositories/ChatMessageRepository.swift` | `analysisContextJSON` 读写 |
| `Models/AI/ChatCardData.swift` | 新增通用分析卡片模型 + `fromAnalysisContext()` |
| `Views/Chat/MessageBubbleView.swift` | 分析卡片叠加渲染 |
| `Models/CoreDataStack+ChatEntities.swift` | 新增 `analysisContextJSON` 字段定义 |
| `Models/ChatMessage+CoreDataProperties.swift` | 新增 `@NSManaged var analysisContextJSON: String?` |
| `Models/TodoRepository.swift` | 补齐 `getTaskPeriodStats` / `getDailyTaskCounts` |

---

## 实施顺序

| 阶段 | 内容 | 依赖 |
|------|------|------|
| Phase 1 | 意图、领域、Context 模型、Resolver、Prompt | 无 |
| Phase 2 | 补齐 TodoRepository + AnalysisContextBuilder + 各领域 Builder + Coordinator | Phase 1 |
| Phase 3 | Provider 流式分析接口（扩展现有方法） | Phase 2 |
| Phase 4 | Core Data 持久化 + ChatViewModel + Message 渲染 + 错误处理 | Phase 3 |
| Phase 5 | 通用分析卡片 UI | Phase 4 |

推荐落地切片：
1. 先实现 `finance` + `habit` + 持久化闭环。
2. 再补 `task`（需先补齐 Repository 方法）。
3. 最后补 `thought` 和 `crossModule`。

---

## 验证方式

1. **Resolver 单元测试**
   - "分析我2024年的消费" → `finance` + 2024-01-01 ~ 2024-12-31。
   - "分析上个月习惯打卡" → `habit` + 上个自然月。
   - "看看这周任务完成情况" → `task` + 本周。
   - "复盘一下最近一个月" → `crossModule` + 最近 30 天。
   - 缺日期、非法日期、`end < start` 不崩溃。
2. **日期边界测试**
   - 结束日期当天 23:59 的记录必须被统计。
   - 结束日期次日 00:00 的记录不得被统计。
3. **Builder 测试**
   - finance：总支出/收入/分类/预算语义正确。
   - habit：完成率、streak、掉队习惯正确。
   - task：完成率、逾期、高优先级完成率正确。
   - thought：情绪分布、标签、趋势正确。
   - crossModule：无数据模块不会生成虚假关联；只产生 highlights/warnings。
4. **Provider 消息顺序测试**
   - 分析模式：system prompt → context JSON → current user question（共 3 层）。
   - 普通模式：保持现有行为不变。
   - 分析模式下 messages 为空。
5. **持久化测试**
   - `analysisContextJSON` 写入 assistant 消息。
   - 重新加载消息后 `ChatMessageViewData.analysisContext` 可解码。
   - 历史消息仍能渲染分析卡片。
   - **Core Data 轻量迁移测试**：旧版本（无 `analysisContextJSON` 字段）升级后，旧消息正常显示，新消息可写入分析上下文。
6. **卡片模型测试**
   - 所有 row/point 模型可 `Equatable` / `Codable`。
   - `ChatCardData.fromAnalysisContext()` 在缺数据时不生成空卡。
7. **错误处理测试**
   - Repository 异常时对应 domain context 为 nil，其他领域继续。
   - JSON 编码/解码失败时降级为纯文本渲染。
   - LLM 流式中断时卡片数据完整保留。
8. **Token 预算测试**
   - AnalysisContext JSON 编码后 ≤ 4000 token。
   - 各数组字段不超过上限。
9. **端到端手工验证**
   - "分析我2024年的消费"：显示财务卡片 + 文本。
   - "分析我上个月习惯打卡"：显示习惯卡片 + 文本。
   - "看看这周任务完成情况"：显示任务卡片 + 文本。
   - "复盘一下最近一个月"：显示综合卡片 + 文本。
   - 杀进程重启后历史卡片仍存在。
   - 分析前聊了 20 条无关内容，分析结果不受历史影响。

---

## 关键风险与应对

| 风险 | 应对 |
|------|------|
| LLM 日期或领域提取不准确 | `AnalysisPeriodResolver` 本地兜底，领域也由关键词二次判定 |
| 日期边界少算最后一天 | 统一使用 `[start.startOfDay, end.startOfDay + 1 day)` |
| 通用化后一次性范围过大 | 第一版先落地 finance + habit，再扩展 task / thought / crossModule |
| 数据量大导致 token 膨胀 | Token 预算约束表限制数组长度，超过则降级聚合粒度 |
| 无数据期间 | Coordinator 直接返回提示文本，不调用 LLM |
| 卡片与文本不协调 | 卡片由本地 Context 渲染，LLM 只做解释 |
| 历史消息污染分析结果 | 分析查询发送零历史消息，上下文完全自包含 |
| 历史卡片丢失 | `analysisContextJSON` 持久化到 ChatMessage，snapshot 中解码 |
| 跨模块关联被模型过度解释 | 第一版不做关联分析，只做各模块摘要并列 |
| TodoRepository 统计方法缺失 | Phase 2 前置补齐，不绕过 |
| Core Data 轻量迁移失败 | 可选字段自动迁移，验证中覆盖升级场景 |
| Builder 并发竞态 | crossModule 使用 `async let` 并发构建，各 builder 无共享可变状态 |
