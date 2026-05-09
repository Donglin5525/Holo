# HoloAI 数据洞察卡片化设计

> 日期：2026-05-10
> 状态：三审修订完成（待确认）

## 背景

HoloAI 的分析查询当前已经支持「结构化分析卡片 + AI 文本」叠加展示：`ChatMessageViewData.analysisCards` 会从 `analysisContextJSON` 解码出的 `AnalysisContext` 生成 `ChatCardData`，`MessageBubbleView` 再优先渲染这些分析卡片和正文。

当前体验问题不是「完全没有卡片」，而是分析结果在 Chat 中一次性展开过长，占用对话空间，用户扫读成本高。本设计将分析查询改为「Chat 紧凑入口卡片 + Sheet 详细分析」：Chat 中只保留一个可点击的摘要入口，AI 文本和现有分析卡片移动到 Sheet 内混合展示。

## 核心原则

- **复用优先**：复用现有 `AnalysisContext`、`ChatCardData.fromAnalysisContext(_:)` 和 `AnalysisChatCard` 数据结构，不新增平行的 Insight 卡片体系。
- **Chat 保持轻量**：`query_analysis` 结果在消息列表中只显示一个紧凑入口卡片，不再直接铺开所有分析卡片和长文本。
- **Sheet 承载深度内容**：AI 文字是主体，数据卡片作为可视化辅助嵌入其中。
- **标记可选可降级**：LLM 标记只影响卡片插入位置，不决定卡片是否存在；没有标记时使用本地默认插入策略。
- **一次性洞察**：卡片和 Sheet 不支持追问或二次对话。

## 一、整体数据流

```
用户输入 "帮我分析近三个月账单"
  → ConversationCoordinator 识别 query_analysis 意图（不变）
  → AnalysisContextBuilder 构建 AnalysisContext（不变）
  → LLM 生成 Markdown 分析文本，可选输出 {{card:类型}} 标记
  → ChatMessage 持久化 AI 文本 + analysisContextJSON（不变）
  → Chat 渲染：AnalysisCompactChatCard（从 AnalysisContext 本地提取摘要）
  → 用户点击紧凑卡片
  → ChatView 弹出 AnalysisDetailSheet
  → Sheet 解析 AI 文本标记，并复用现有 AnalysisChatCard 组件渲染数据卡片
```

### 改动范围

**核心改动 4 处：**

1. `PromptManager.analysisPrompt`：追加可选卡片标记指令。
2. `MessageBubbleView`：当消息 `intent == .query_analysis` 时，改为渲染单个 `AnalysisCompactChatCard`（不再用 `analysisContext != nil` 判断，因为轻量加载时 `analysisContext` 为 nil）。再根据 `metadataState + analysisContext` 决定显示占位卡片、真实紧凑卡片或文本兜底。
3. `ChatView`：持有 `selectedAnalysisMessage` Sheet 状态，并在分析紧凑卡片点击时弹出详情。
4. 新增 `AnalysisDetailSheet` 和轻量解析器：把 AI 文本拆成文字块和卡片占位块。

**明确不新增：**

- 不新增 `InsightCardData`、`InsightMetric`、`InsightRankItem` 等平行模型。
- 不新增 `FinanceInsightAdapter` / `HabitInsightAdapter` 这类 `Any` 转型适配器。
- 不新增另一套 Summary / Breakdown / Trend / Comparison / Highlights 卡片 UI。

## 二、标记系统

AI 可以在 Markdown 分析文本中输出 `{{card:类型}}` 标记，用来建议数据卡片插入位置。

### 标记定义

| 标记 | 对应现有卡片 | 数据来源 |
|------|--------------|----------|
| `{{card:summary}}` | `.analysisSummary` | `ChatCardData.fromAnalysisContext(_:)` |
| `{{card:breakdown}}` | `.analysisBreakdown` | `ChatCardData.fromAnalysisContext(_:)` |
| `{{card:trend}}` | `.analysisTrend` | `ChatCardData.fromAnalysisContext(_:)` |
| `{{card:comparison}}` | `.analysisComparison` | `ChatCardData.fromAnalysisContext(_:)` |
| `{{card:highlights}}` | `.analysisHighlights` | `ChatCardData.fromAnalysisContext(_:)` |

### Prompt 追加指令

在 `analysisPrompt` 末尾追加：

```text
你可以在分析文本中插入卡片标记，用来建议数据卡片出现的位置：
- {{card:summary}}：关键指标概览
- {{card:breakdown}}：分类、分布或排行
- {{card:trend}}：趋势走向
- {{card:comparison}}：本期与上期对比
- {{card:highlights}}：亮点与提醒

规则：
1. 标记是可选的，只在相关段落后使用。
2. 每种标记最多使用一次。
3. 标记必须独占一行。
4. 不要为了使用标记而编造数据。
5. 如果不确定是否适合插入卡片，可以不输出标记。
```

### 解析与降级策略

- 解析器按行识别完全匹配 `{{card:xxx}}` 的标记。
- 未知标记作为普通文本保留，避免误删 AI 输出。
- 重复标记只使用第一次，后续重复标记直接忽略，不再作为正文显示。
- 标记对应的卡片不存在时，不渲染该卡片，文本照常显示。
- AI 没有输出任何有效标记时，Sheet 使用默认插入策略：
  - 将 AI 文本按空行 `\n\n` 分割为段落数组 `paragraphs`（N 段）。
  - `summary` 插入第 1 段之后（索引 1 处）。
  - `breakdown/trend/comparison` 按 `ChatCardData.fromAnalysisContext(_:)` 返回顺序插入第 `max(1, N / 2)` 段之后。
  - `highlights` 插入最后一段之前（索引 `N - 1` 处）。
  - 若 N < 3（段落太少），所有卡片顺序追加在全文末尾。
  - 示例：AI 输出 5 段 → summary 在第 1 段后，mid cards 在第 2 段后，highlights 在第 4 段后。
  - **稳定排序**：多个卡片落在同一插入索引时，按 `AnalysisCardSlot` 的声明顺序（summary → breakdown → trend → comparison → highlights）稳定排列，避免 UI 顺序随实现变化。实现时先生成 `[(insertIndex: Int, slotOrder: Int, card: AnalysisCardSlot)]`，按 `insertIndex` 升序、`slotOrder` 升序排序后渲染。

## 三、Chat 紧凑卡片

`query_analysis` 结果在 Chat 中渲染为单个 `AnalysisCompactChatCard`。它替代现有的「多个分析卡片 + 长文本气泡」展开式展示，但仍然依赖同一份 `AnalysisContext`。

### 卡片结构

```text
┌─────────────────────────────────────┐
│ chart.bar.xaxis  账单分析 · 近三个月 │
│ 总支出 ¥12,480 · 日均 ¥138 · 较上期 ↓8.2% │
│ 点击查看详细分析                 ›  │
└─────────────────────────────────────┘
```

### 摘要行生成

新增轻量工具 `AnalysisSummaryFormatter`，输入完整 `AnalysisContext`，输出 `AnalysisCompactSummary`：

```swift
struct AnalysisCompactSummary: Equatable {
    let icon: String
    let title: String
    let subtitle: String
    let summaryLine: String
}
```

摘要规则：

| 领域 | title | summaryLine |
|------|-------|-------------|
| 财务 | `账单分析 · {periodLabel}` | `总支出 {totalExpense} · 日均 {averageDailyExpense} · 较上期 {变化}` |
| 习惯 | `习惯分析 · {periodLabel}` | `完成率 {averageCompletionRate} · 活跃 {activeHabitCount} 个 · 最佳连续 {maxStreak} 天` |
| 任务 | `任务分析 · {periodLabel}` | `完成率 {completionRate} · 完成 {completedCount}/{totalCount} · 逾期 {overdueCount}` |
| 想法 | `想法分析 · {periodLabel}` | `想法 {totalCount} 条 · 标签 {topTags.count} 个 · 心情分布 {moodDistribution.count} 类` |
| 综合 | `综合分析 · {periodLabel}` | `亮点 {highlights.count} 条 · 提醒 {warnings.count} 条` |

财务环比变化不重新计算百分比。若只有 `previousPeriodExpense`，可以显示金额差值；若没有上期数据，则省略该片段。习惯域不使用“全局连续打卡 M 天”这种不存在的字段，改为从 `streaks.map(\.currentStreak).max()` 提取“最佳连续”。

本阶段不依赖用户原始提问生成标题或摘要。当前分析流只稳定持久化 AI 文本和 `analysisContextJSON`，因此紧凑卡片的标题、副标题、摘要都必须从 `AnalysisContext` 生成。若未来要展示用户原始提问，需要单独扩展持久化字段或在分析上下文中加入 query 信息，不混入本次卡片化改造。

> **技术债 [MEDIUM]**：用户原始提问未持久化到 `ChatMessage` 或 `AnalysisContext` 中。分析查询路径传入 `messages: []` 给 LLM，LLM 只凭 `AnalysisContext` 的 domain + periodLabel 推断分析意图。卡片标题固定为域名称（如「账单分析」），无法反映用户具体措辞（如「分析餐饮支出」→ 仍显示「账单分析」）。若未来需个性化标题，需在 `ChatMessage` 新增 `userQuery` 字段。

> **periodLabel 来源说明**：`AnalysisContext` 已有 `periodLabel` 字段，优先直接使用。若为空或不可用，回退到 `DateFormatter`（zh_CN locale）将 `startDate`/`endDate` 格式化为自然语言描述（如「2026年2月 — 4月」）。

### 元数据延迟加载处理（CRITICAL）

`ChatMessageViewData` 的轻量初始化器将 `analysisContext` 设为 nil（`metadataState == .unloaded`）。紧凑卡片依赖 `analysisContext` 生成摘要，但历史消息在元数据加载前无法获取。

**渲染策略**：

- 当 `metadataState == .loaded` 且 `analysisContext != nil`：正常渲染紧凑卡片，显示摘要数据。
- 当 `metadataState == .unloaded` 或 `.loading`：渲染占位紧凑卡片（渐变背景 + 域图标 + "分析结果加载中..."），**禁用点击**（`.allowsHitTesting(false)` 或回调中忽略）。元数据加载仍由 `ChatView.onAppear` 的 `viewModel.loadMetadataIfNeeded(...)` 统一负责，占位卡片不触发重复加载。
- 当 `metadataState == .loaded` 但 `analysisContext == nil`（数据为空）：不渲染紧凑卡片，退化为普通文本气泡（与当前行为一致）。

**备选方案**：将 `analysisContextJSON` 的解码提升为轻量字段（在首次加载时一并解码），避免延迟加载问题。但这会增加初始加载开销，本阶段暂不采用。

### 点击行为

`AnalysisCompactChatCard` 只负责展示和触发点击回调。点击行为仅在 `metadataState == .loaded && analysisContext != nil` 时生效。占位态（`.unloaded`/`.loading`）禁用点击，不弹出 Sheet。

Sheet 状态由 `ChatView` 持有：

```swift
@State private var selectedAnalysisMessage: ChatMessageViewData?
```

点击后弹出：

```swift
.sheet(item: $selectedAnalysisMessage) { message in
    AnalysisDetailSheet(message: message)
}
```

## 四、AnalysisDetailSheet

`AnalysisDetailSheet` 是分析结果的详细阅读界面。它接收完整 `ChatMessageViewData`，从中读取：

- `message.content`：AI Markdown 文本。
- `message.analysisContext`：结构化数据来源。
- `message.analysisCards`：现有分析卡片数据。

### 整体布局

```text
┌─────────────────────────────────────┐
│           ──                         │
│  chart.bar.xaxis 账单分析        xmark│
│  2026年2月 - 4月 · 近三个月          │
│─────────────────────────────────────│
│  [AI Markdown 段落 1]                │
│  [AnalysisSummaryChatCard]           │
│  [AI Markdown 段落 2]                │
│  [AnalysisBreakdownChatCard]         │
│  [AI Markdown 段落 3]                │
└─────────────────────────────────────┘
```

### 渲染模型

只新增最小渲染块，不新增卡片数据模型：

```swift
enum AnalysisDetailBlock: Equatable {
    case text(String)
    case card(AnalysisCardSlot)
}

enum AnalysisCardSlot: String, CaseIterable {
    case summary
    case breakdown
    case trend
    case comparison
    case highlights
}
```

`AnalysisCardSlot` 到 `ChatCardData` 的匹配规则：

| Slot | 匹配的 `ChatCardData` case |
|------|----------------------------|
| summary | `.analysisSummary` |
| breakdown | `.analysisBreakdown` |
| trend | `.analysisTrend` |
| comparison | `.analysisComparison` |
| highlights | `.analysisHighlights` |

渲染时继续复用 `AnalysisSummaryChatCard`、`AnalysisBreakdownChatCard`、`AnalysisTrendChatCard`、`AnalysisComparisonChatCard`、`AnalysisHighlightsChatCard`，或提取现有 `MessageBubbleView.cardView(for:)` 中的分析卡片渲染逻辑为共享组件。

### Markdown 渲染方案

`AnalysisDetailBlock.text` 始终存储原始 `String`，Markdown 解析推迟到 Sheet 渲染层。

Sheet 内的文本块渲染复用/提取现有 `StreamingTextView` 的 Markdown 解析能力（`StreamingTextView` 在流式完成后已异步解析 Markdown）。具体做法：
- 提取 `StreamingTextView` 中的 Markdown → AttributedString 解析逻辑为独立的 `MarkdownRenderer` 工具方法。
- `AnalysisDetailSheet` 的文本块调用 `MarkdownRenderer.render(String) -> AttributedString`，解析失败时降级为 `Text(rawString)`。
- `AnalysisDetailBlockParser` 只负责标记拆分和段落合并，不做 Markdown 解析。

支持的格式：**粗体**、*斜体*、`行内代码`、有序/无序列表、标题（h2-h4）。

> 不要在 `AnalysisDetailBlockParser` 中做第二套 Markdown 解析，复用 `StreamingTextView` 已有的能力。

### Sheet 高度

使用 `.presentationDetents([.medium, .large])`。内容较短时半屏足够，内容较长时允许上滑展开。Sheet 内部使用 `ScrollView`，避免影响 Chat 列表滚动状态。

## 五、现有分析卡片体系的调整

现有 `ChatCardData.fromAnalysisContext(_:)` 继续作为唯一的数据卡片生成入口。

### 保留现有能力

- 财务：summary、breakdown、trend、comparison。
- 习惯：summary、trend、highlights。
- 任务：summary、trend、comparison。
- 想法：summary、breakdown。
- 综合：highlights。

### 本阶段样式策略

本阶段不在 `AnalysisChatCard.swift` 中抽取 `AnalysisCardRenderer`。`AnalysisDetailSheet` 直接实例化现有 `AnalysisSummaryChatCard` 等组件，通过外层容器调整间距和宽度适配 Sheet 环境。如果后续验证发现 Sheet 和 Chat 气泡的样式差异确实需要独立组件，再考虑抽取共享渲染器。先跑通再优化。

如果后续验证发现 Sheet 内卡片需要更强的详情页样式，再单独增加显示模式；不要在本次卡片化改造中复制 Summary / Breakdown / Trend / Comparison / Highlights 五套组件。

## 六、文件组织

### 新增文件

```text
Views/Chat/Analysis/
├── AnalysisCompactChatCard.swift       // Chat 中的紧凑入口卡片
├── AnalysisDetailSheet.swift           // Sheet 详情主视图
├── AnalysisDetailBlockParser.swift     // AI 文本标记解析 + 默认插入策略
├── AnalysisSummaryFormatter.swift      // 从 AnalysisContext 生成紧凑摘要
└── MarkdownRenderer.swift             // 从 StreamingTextView 提取的 Markdown 解析工具
```

### 修改的现有文件

| 文件 | 改动 |
|------|------|
| `Services/AI/PromptManager.swift` | `analysisPrompt` 末尾追加可选标记指令 |
| `Views/Chat/MessageBubbleView.swift` | `intent == .query_analysis` 时渲染 `AnalysisCompactChatCard`（判断条件见上文） |
| `Views/Chat/ChatView.swift` | 新增 `selectedAnalysisMessage`，负责展示 `AnalysisDetailSheet`；Sheet dismiss 时置 nil |
| `Views/Chat/StreamingTextView.swift` | 提取 Markdown 解析逻辑为 `MarkdownRenderer` 共享方法 |
| `Models/ChatMessageViewData.swift` | 增加 `hasAnalysisContext` 便利属性；紧凑摘要由 `AnalysisSummaryFormatter` 现场生成 |

### 不改动的部分

- `AnalysisContextBuilder` 及各域 Builder。
- `ConversationCoordinator` 的意图识别和编排。
- `IntentRouter`。
- `AnalysisPeriodResolver`。
- Core Data 模型。
- `ChatCardData.fromAnalysisContext(_:)` 的唯一数据源地位。

## 七、实施顺序建议

1. 新增 `AnalysisSummaryFormatter`，先用单元级 preview 或静态样例确认财务/习惯摘要不越界。
2. 新增 `AnalysisCompactChatCard`，把 Chat 消息列表中的分析消息压缩成入口卡片。
3. 新增 `AnalysisDetailSheet`，先无标记地展示完整 AI 文本和默认顺序卡片。
4. 新增 `AnalysisDetailBlockParser`，接入 `{{card:xxx}}` 标记定位。
5. 更新 `analysisPrompt`，让新生成的分析文本开始携带可选标记。
6. 回归历史消息：旧消息没有标记也必须能通过默认插入策略正常展示。

## 八、验收标准

- Chat 中每条分析查询只显示一个紧凑入口卡片。
- 点击入口卡片能打开 Sheet，并显示完整 AI 文本。
- Sheet 能展示现有 `ChatCardData.fromAnalysisContext(_:)` 生成的分析卡片。
- 没有标记的历史分析消息仍能展示卡片。
- 标记重复、未知标记、标记对应卡片不存在时不崩溃。
- 财务和习惯摘要不使用不存在或语义不准确的字段。
- 不引入第二套分析卡片数据模型。
- 元数据未加载时，紧凑卡片显示占位状态，不闪烁为文本气泡。
- Markdown 渲染失败时降级为纯文本，不崩溃。
- Sheet dismiss 后 `selectedAnalysisMessage` 置 nil。
