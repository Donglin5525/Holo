# Holo AI Agent 深度分析卡片化重构设计

**日期**：2026-06-14
**状态**：已对齐，待实施
**关联**：Agent loop 能力（`HoloAgentAnalysisService`）、账单分析卡片样板、后端 `agent_loop`

---

## 1. 背景

Holo 的 Agent 深度分析能力（多轮 agent loop）已实现，但呈现层有几个明显问题：

1. **排版丑**：Agent 结果被拍扁成一段纯文本塞进普通聊天气泡。`ChatViewModel`（约 281-293 行）用 `\n` 把 `title + summary + 所有 claims` 拼成一个大字符串，`MessageBubbleView` 走普通 `StreamingTextView`，连 markdown 都不渲染（`MarkdownAttributedStringRenderer` 要求文本含 `**`/`#`/`- ` 才升级，agent 返回纯中文，不触发）。
2. **渲染层浪费**：`HoloAgentResultRenderer.render()` 把每条 claim 的 `title` 和 `body` 都设成同一段 `claim.displayText`（`title: claim.displayText, body: claim.displayText`），title 字段完全没用，sections 之间无视觉层级。数据契约里的 `metricAssertions`（value/baseline/comparison）、`confidence`、`prohibitedInferences`、`evidenceReferences` 全部被丢弃。
3. **目标/感受断层**：新的 Agent loop 只能通过「工具」取数据，生产环境只注册了 3 个工具（记忆/习惯/财务），**没有目标工具、也没有感受工具**，所以用户在 Holo 里添加的个人目标和（`Goal`）和感受（`Thought` 的 mood/content）完全没进深度分析。旧的 `analysis_prompt` 单次调用路径已接（`GoalAnalysisContextBuilder`/`ThoughtAnalysisContextBuilder`），但 Agent loop 走的是平行路径，没接。
4. **品牌文案**：深度分析链路及全局约 55 处面向用户的「AI」字眼未统一为「Holo」。

## 2. 目标

1. **卡片化**：Agent 深度分析从纯文本气泡 → 卡片承载（loading 态 + 结果卡），点卡片进结构化详情页。触发方式不变（仍是对话意图触发，**不新增独立入口**）。
2. **排版优化**：详情页结构化（核心结论卡 + 关键指标 + viz 分段 + 证据段）。
3. **AI 驱动可视化**：由 Agent 吐的 metric 形态决定可视化——预算进度条、趋势图、对比条、数据源表格、数据源卡片标记。
4. **目标/感受关联**：给 Agent 加目标工具 + 感受工具，让深度分析能调用这两类数据。
5. **品牌文案**：深度分析链路所有「AI」字眼 → 「Holo」。

## 3. 非目标

- 不改 Agent loop 的触发方式（仍是 Chat 对话意图触发，无独立入口卡片）
- 不改 Core Data schema（`Goal` / `Thought` / `Budget` 均已存在）
- 不改后端 `agent_loop` prompt（除非阶段 2 评估确认需要引导 Agent 标记 viz）
- 全局 55 处 AI 文案替换范围「往后讨论」，本设计只覆盖深度分析链路必改项
- 不改签名 / Bundle ID

## 4. 参考样板

| 样板 | 路径 | 用途 |
|------|------|------|
| 账单分析入口卡（四态） | `Views/Chat/Analysis/AnalysisCompactChatCard.swift` | Agent 卡片的 loading/loaded/unloaded/degrade 四态分发 |
| 账单分析详情页 | `Views/Chat/Analysis/AnalysisDetailSheet.swift` | 详情页结构（核心结论卡 + 事实段 + Markdown 分段 + 嵌入卡片） |
| 卡片标记机制 | `Views/Chat/Analysis/AnalysisDetailBlockParser.swift` | `{{card:slot}}` 标记解析 + 「有标记用标记、无标记用默认策略」哲学 |
| 摘要 Formatter | `Views/Chat/Analysis/AnalysisSummaryFormatter.swift` | 纯函数摘要模式 |
| Markdown 渲染 | `Views/Chat/Analysis/MarkdownAttributedStringRenderer.swift` | 详情文本块 |
| 设计文档 | `docs/chat/plans/2026-05-10-insight-card-design.md` | 「复用优先，不另起平行卡片体系」 |
| 工具范本 | `Services/AI/Agent/Tools/HoloHabitTool.swift` | 目标/感受工具照此写 |
| 卡片底层组件 | `ChatCardView` / `CardHeaderView` / `HoloAIHeroMetric` / `CardButtonStyle` | 直接复用 |

## 5. 关键决策

### 决策①：AI 驱动可视化实现方式 → 选 C（数据驱动 + 标记微调）

| 方案 | 说明 | 结论 |
|------|------|------|
| A. 扩 Agent JSON 契约 | 让 Agent 直接吐结构化可视化字段（`{type:progress, value:0.82}`） | 否决：改动最大，要动后端 prompt + `validateAgentLoopContent` 校验，Agent 输出新字段不稳定 |
| B. 纯标记 | Agent 在文本里嵌 `{{viz:trend}}`，解析器渲染 | 否决：复用成熟机制，但标记不带数据，数据还得从 metric/evidence 另取 |
| **C. 数据驱动 + 标记微调（选定）** | 渲染器根据 Agent 已吐的 `metricAssertions` 形态自动选图；Agent 可选用标记微调布局 | **选定** |

**方案 C 细则**：
- 渲染器根据 metric 形态自动选图：
  - `baselineValue` + `comparison` 存在 → **对比条**
  - metricKey 含预算语义 → **进度条**（数据从 `BudgetRepository` 的 `BudgetStatus.progress` 取）
  - evidence events 含时间序列 → **趋势图**（Swift Charts）
  - `evidenceReferences` → **数据源表格 / 卡片标记**
- Agent 可选用 `{{viz:xxx}}` 标记微调布局，复用 `AnalysisDetailBlockParser` 的「有标记用标记、无标记用默认策略」。
- 「AI 判断」体现：**Agent 决定分析什么角度、吐什么类型的 metric**（LLM 判断），渲染层把这些数据变成最合适的图。

**理由**：最贴「AI 判断出什么图」诉求，又不强制 Agent 学全新语法，数据兜底最稳，复用现有 `metricAssertions` 契约。

### 决策②：卡片组件 → 选 B（新建 Agent 专属卡片 + 详情，复用底层组件）

| 方案 | 说明 | 结论 |
|------|------|------|
| A. 扩展现有 `AnalysisCompactChatCard` 承载 Agent 结果 | 把 Agent 结果硬适配成 `AnalysisContext` | 否决：数据本质不同（claim/evidence vs 6 域财务），强扭违反单一职责 |
| **B. 新建 Agent 专属卡片 + 详情页（选定）** | 新建 `AgentDeepAnalysisCard` + `AgentDeepAnalysisDetailSheet`，底层复用组件 | **选定** |

**复用的底层组件**：`ChatCardView` / `CardHeaderView` / `HoloAIHeroMetric` / `CardButtonStyle` / `MarkdownAttributedStringRenderer` / `AnalysisDetailBlockParser`（或新建 `AgentDetailBlockParser`）。

## 6. 整体数据流（改造后）

```
Chat 问分析类问题
 → ConversationCoordinator 识别 query_analysis + agentRuntimeEnabled
 → HoloAgentAnalysisService.runAnalysis（Agent loop，工具扩到 5 个）
 → HoloAgentResultRenderer.render（扩展：metricAssertions/evidence/confidence 不再丢弃，产出 viz 数据）
 → ChatViewModel：结构化存进 message（不再拍扁成字符串，类似 analysisContext）
 → MessageBubbleView：agent 消息走新卡片（不再走文本气泡）
 → 卡片：loading 态 → 结果卡（标题 + 核心指标 + CTA「查看详情」）
 → 点卡片 → AgentDeepAnalysisDetailSheet（核心结论卡 + viz 分段 + 证据段）
```

关键改造点：
1. `ChatViewModel`：不再 `[title,summary,*sections].joined("\n")`，结构化存储 agent 结果。
2. `MessageBubbleView`：agent 消息渲染分支走新卡片。
3. 新建 `AgentDeepAnalysisCard` + `AgentDeepAnalysisDetailSheet`。
4. 扩展 `HoloAgentResultRenderer`：利用 `metricAssertions`/`evidence`/`confidence`，产出 viz 数据结构。
5. `ChatMessage` 模型加字段存 agent 结果 JSON（照 `analysisContextJSON` 模式）。

## 7. 4 阶段拆分

### 阶段 1：卡片化 + 排版（地基）
Agent 结果从纯文本气泡 → 卡片 → 结构化详情页（暂无图表）。

| 动作 | 文件 |
|------|------|
| 改 | `Services/AI/Agent/Presentation/HoloAgentResultRenderer.swift` — 修复 title/body 同值、暴露 metric/evidence/confidence（为阶段 2 铺路） |
| 改 | `Views/Chat/ChatViewModel.swift:279-293` — 279 行占位文案（`正在为你深度分析本地数据…`）改为由卡片 loading 态承载；281-293 不再拍扁成字符串，结构化存进 message |
| 改 | `Views/Chat/MessageBubbleView.swift:105-119` — agent 消息走新卡片分支 |
| 改 | ChatMessage 模型 — 加字段存 agent 结果 JSON |
| 新建 | `Views/Chat/Analysis/AgentDeepAnalysisCard.swift` — 入口卡（四态），复用 ChatCardView 等 |
| 新建 | `Views/Chat/Analysis/AgentDeepAnalysisDetailSheet.swift` — 详情页（核心结论卡 + 事实段 + Markdown 分段 + 证据段） |

**交付**：Chat 里 Agent 分析以卡片承载，点开有结构化详情页（纯结构化文本 + 证据）。

### 阶段 2：AI 驱动可视化（核心价值）
metric 形态 → 自动选图 + Agent 标记微调。

| 动作 | 文件 |
|------|------|
| 改 | `HoloAgentResultRenderer.swift` — metric → viz 数据结构映射 |
| 新建 | `Views/Chat/Analysis/AgentViz/ProgressBarBlock.swift` — 预算进度条（`BudgetRepository.progress`） |
| 新建 | `Views/Chat/Analysis/AgentViz/TrendChartBlock.swift` — Swift Charts 趋势图 |
| 新建 | `Views/Chat/Analysis/AgentViz/ComparisonBarBlock.swift` — value/baseline 对比条 |
| 新建 | `Views/Chat/Analysis/AgentViz/EvidenceTableBlock.swift` — 数据源表格 |
| 新建 | `Views/Chat/Analysis/AgentViz/EvidenceSourceCard.swift` — 数据源卡片标记 |
| 新建 | `Views/Chat/Analysis/AgentDetailBlockParser.swift` — viz 标记 + 数据驱动默认渲染 |
| 改 | `AgentDeepAnalysisDetailSheet.swift` — 接 viz blocks |

**交付**：详情页有进度条 / 趋势图 / 对比条 / 数据源表格 / 卡片标记，由 Agent 吐的 metric 驱动。

### 阶段 3：目标/感受关联（独立增量）
Agent 能调用目标和感受数据。

| 动作 | 文件 |
|------|------|
| 新建 | `Services/AI/Agent/Tools/HoloGoalTool.swift` + `HoloGoalDataSource` — 复用 `GoalRepository.activeGoalsForAI` |
| 新建 | `Services/AI/Agent/Tools/HoloThoughtTool.swift` + `HoloThoughtDataSource` — 复用 `ThoughtRepository` |
| 改 | `Services/AI/Agent/HoloAgentRuntimeShared.swift:31-35` — 注册 2 个新工具 |
| 新建 | 2 个工具的单元测试 |

**交付**：Agent 工具 3 → 5 个，深度分析能关联目标和感受。

### 阶段 4：品牌文案 AI → Holo（收尾）

| 动作 | 文件 |
|------|------|
| 改 | `Views/Chat/Analysis/AnalysisCompactChatCard.swift:70`（`AI 正在分析中...` → `Holo 正在分析中...`） |
| 改 | `Views/MemoryGallery/Components/MemoryInsightHeroCard.swift:276`（`AI 正在阅读...` → `Holo 正在阅读...`） |
| 改 | 新建卡片（`AgentDeepAnalysisCard`）内的 loading 文案统一用 Holo |

**交付**：深度分析链路无「AI」字眼。全局 55 处范围往后讨论。

## 8. 错误处理

核心原则：**可视化是锦上添花，缺数据退化不崩**。

| 场景 | 处理 |
|------|------|
| Agent loop 失败 | 卡片显示 failed 态（承接现有「深度分析出错」），参考 MemoryInsightHeroCard 的 failed |
| 单个工具失败（阶段 3） | 照 HoloHabitTool 的 errorResult，返回 `status:.error` + recoverable，**不阻断 loop**（Agent 继续用其他工具） |
| 可视化数据缺失 | metric 不匹配任何图 → 退化结构化文本；预算/趋势点/证据为空 → 对应 viz 不渲染（availableSlots 机制） |
| viz 标记 / JSON 解析失败 | 照 AnalysisDetailBlockParser：无效标记忽略、解码失败退化文本气泡 |
| 旧消息无 agent 字段 | 可选解码 + 向后兼容，退化普通气泡 |
| 隐私 | 目标工具只取 `activeGoalsForAI`（尊重 `allowAIContext`）；感受正文走脱敏摘要，不灌完整原文（遵循 `HoloAgentPromptBuilder`「只注入 redactedExcerpt」原则） |

## 9. 测试策略

核心逻辑 TDD（80% 覆盖），UI best effort。

| 阶段 | 必测（TDD） | UI（best effort） |
|------|------------|------------------|
| 1 | `HoloAgentResultRenderer`（title/body 不再同值、metric/evidence 暴露）；ChatMessage agent 结果编解码 + 向后兼容 | 卡片四态 |
| 2 | metric → viz 映射纯函数；`AgentDetailBlockParser`（标记/默认/容错） | viz 组件渲染 |
| 3 | `HoloGoalTool` / `HoloThoughtTool`（mock DataSource，照 HoloHabitTool 模式）；工具注册（3→5） | — |
| 4 | — | — |

## 10. 风险点 & 缓解

1. **Agent loop 稳定性（中）**：加 2 工具扩测试面。→ 工具独立 + 单测 + `agentRuntimeEnabled` 灰度 flag 可控开关。
2. **可视化数据驱动边界（中）**：metric → 图的映射要覆盖各种 Agent 输出。→ fallback 到文本，宁可退化不崩。
3. **后端 prompt（低中）**：决策①C 数据驱动为主，Agent 不强制学新语法，`agent_loop` prompt **大概率不用改**；若阶段 2 要让 Agent 主动标记 viz，再评估双端同步 + Docker 重建。
4. **Core Data 线程安全（阶段 3）**：Goal/Thought 是 NSManagedObject。→ 工具 DataSource 取数后转值类型（照 HoloHabitTool 的 ToolRecord），不跨线程传托管对象。
5. **向后兼容（低）**：旧消息无 agent 字段。→ 可选解码 + 退化。
6. **趋势图数据源（中）**：`TrendChartBlock` 依赖带时间戳的 events，但部分工具（如 `HoloHabitTool`）的 `HoloEvidenceEvent.occurredAt` 为 nil（按 `dayOffset`）。→ 阶段 2 需确认哪些工具返回带 `occurredAt` 的 events（财务交易应有日期、目标有 deadline），趋势图仅对有时间序列的 metric 启用，其余退化对比条/文本。

## 11. 开放问题（待后续决策）

1. **全局 AI 文案范围**：约 55 处用户可见「AI」字样（Chat / 记忆画廊 / 设置 / 目标 / 想法等）+ 法律文档 `LegalDocumentSheet` + PromptManager 系统提示词，是否全部替换、范围如何，东林说往后讨论。
2. **阶段 2 后端 prompt**：是否需要改 `agent_loop` prompt 引导 Agent 主动输出 viz 标记（评估后定；数据驱动方案下大概率不需要）。
3. **阶段 3 prompt 关联指引**：是否在 `agent_loop` prompt 补「目标关联」口径指引（让 Agent 主动把行为数据对照目标解读），属锦上添花，非必须。

## 12. 数据契约关键文件（实施时参考）

| 用途 | 路径 |
|------|------|
| Agent 单轮 JSON 输出 | `Models/AI/Agent/HoloAgentOutputModels.swift`（`HoloAgentOutput`/`HoloAgentClaim`/`HoloMetricAssertion`） |
| Agent 任务级结果 | `Models/AI/Agent/HoloAgentResultModels.swift` |
| 渲染模型（要扩展） | `Services/AI/Agent/Presentation/HoloAgentResultRenderer.swift` |
| Agent prompt 构造 | `Services/AI/Agent/HoloAgentPromptBuilder.swift` |
| 工具注册 | `Services/AI/Agent/HoloAgentRuntimeShared.swift` |
| Goal 取数入口 | `Models/GoalRepository.swift:33`（`activeGoalsForAI`） |
| Thought 取数 | `ThoughtRepository`（`getMoodDistribution` / `getThoughtTexts` / `getTopTags`） |
| Budget 取数 | `Models/BudgetRepository.swift` / `Models/BudgetStatus.swift`（`progress` / `isOverBudget`） |
| Agent loop 分流 | `Services/AI/ConversationCoordinator.swift:42-52` |
| feature flag 默认值 | `Models/AI/HoloAICapability.swift:134`（`agentRuntimeEnabled ?? false`） |
| 后端 prompt | `HoloBackend/src/prompts/defaultPrompts.json`（`agent_loop` / `analysis_prompt`） |
