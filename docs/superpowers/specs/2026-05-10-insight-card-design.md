# HoloAI 数据洞察卡片化设计

> 日期：2026-05-10
> 状态：已批准

## 背景

HoloAI 的分析查询（如「帮我分析近三个月账单」）当前以长文本形式输出到 Chat 中，占用大量上下文空间，体验臃肿。本设计将分析查询的输出改为「紧凑卡片 + Sheet 弹窗」形式，以文字为主、数据卡片点缀的方式展示分析结果。

## 核心原则

- **一次性洞察**：卡片和 Sheet 不支持追问或对话
- **文字为主**：AI 生成的分析文本是主体，数据卡片作为视觉辅助
- **域可扩展**：先实现财务和习惯，架构保证 3 步接入新域

## 一、整体数据流

```
用户输入 "帮我分析近三个月账单"
  → ConversationCoordinator 识别 query_analysis 意图（不变）
  → AnalysisContextBuilder 构建结构化数据（不变）
  → LLM 生成带标记的分析文本（修改 analysisPrompt，增加标记指令）
  → 结果写入 ChatMessage（analysisContextJSON + AI 回复文本）
  → Chat 渲染：紧凑洞察卡片（从 AnalysisContext 提取摘要，不走 AI）
  → 用户点击卡片 → 弹出 Sheet
  → Sheet 解析 AI 文本中的标记，替换为对应的 SwiftUI 数据卡片
```

### 改动范围

**核心改动 3 处：**
1. `analysisPrompt` — 增加标记使用指令
2. Chat 渲染层 — `query_analysis` 意图改为渲染紧凑卡片 + Sheet
3. 新增 `InsightSheetView` — 解析标记 + 混合渲染文字和卡片

**不动的部分：** `AnalysisContextBuilder`、各域 Builder、`AnalysisPeriodResolver`、意图识别 — 全部复用。

## 二、标记系统

AI 在生成分析文本时，使用 `{{card:类型}}` 标记指示卡片插入位置。

### 标记定义

| 标记 | 含义 | 示例场景 |
|------|------|---------|
| `{{card:summary}}` | 关键指标概览 | 总支出、日均消费、趋势方向 |
| `{{card:breakdown}}` | 分类占比排行 | 支出 Top 3 + 进度条 |
| `{{card:trend}}` | 趋势走向 | 最高月/最低月 + 方向 |
| `{{card:comparison}}` | 环比对比 | 本期 vs 上期 + 变化值 |
| `{{card:highlights}}` | 亮点与提醒 | 消费突增、习惯断连 |

### Prompt 追加指令

在 `analysisPrompt` 末尾追加：

```
在分析文本中，你可以在合适的位置插入以下标记来嵌入数据可视化卡片：
- {{card:summary}} — 展示关键指标（总量、日均、趋势）
- {{card:breakdown}} — 展示分类占比排行
- {{card:trend}} — 展示趋势走向
- {{card:comparison}} — 展示环比对比
- {{card:highlights}} — 展示亮点与提醒

规则：
1. 根据可用的数据选择性使用标记，不要全部使用
2. 每种标记最多使用一次
3. 标记必须独占一行
4. 将标记放在相关的文字段落之后
```

### 解析与降级策略

- AI 文本按 `\n` 分割为行数组
- 遇到 `{{card:xxx}}` 行 → 替换为对应 SwiftUI 卡片组件
- 未知标记 → 忽略，当作普通文本渲染
- AI 没使用任何标记 → 纯文本渲染，不插入卡片
- 重复标记 → 只渲染第一次出现

## 三、Chat 紧凑卡片

`query_analysis` 意图的结果渲染为一个紧凑洞察卡片，替代原来的文字气泡 + 分析卡片。

### 卡片结构

```
┌─────────────────────────────────────┐
│ 📊  账单分析 · 近三个月              │  ← 域图标 + 查询标题
│                                     │
│ 总支出 ¥12,480 · 日均 ¥138 · ↓8.2% │  ← AnalysisContext 提取的摘要
│                                     │
│ 点击查看详细分析            ›       │  ← 引导点击
└─────────────────────────────────────┘
```

### 摘要行生成

每个分析域定义自己的摘要提取器，通过 `InsightDomainAdapter` 协议的 `summaryLine(from:)` 方法实现：

- **财务域**：`总支出 ¥X · 日均 ¥Y · 较上期 ↑/↓Z%`
- **习惯域**：`完成率 X% · 活跃习惯 N 个 · 连续打卡 M 天`
- **未来扩展**：任务域、想法域各自实现

摘要数据直接从 `AnalysisContext` 提取，不依赖 AI，速度快且 100% 准确。

### 点击行为

点击卡片弹出 `InsightSheetView`，传入 `AnalysisContext` + AI 回复文本。

## 四、InsightSheetView

用户点击紧凑卡片后弹出的自适应 Sheet。

### 整体布局

```
┌─────────────────────────────────────┐
│           ── (drag handle)           │
│                                     │
│  📊 账单分析                    ✕    │  ← 标题栏
│  2026年2月 — 4月 · 近三个月          │  ← 副标题
│─────────────────────────────────────│
│                                     │
│  [AI 文字段落 1]                     │  ← Markdown 渲染
│                                     │
│  ┌─────────────────────────────┐    │
│  │  数据卡片 (summary)          │    │  ← 标记替换的 SwiftUI 卡片
│  └─────────────────────────────┘    │
│                                     │
│  [AI 文字段落 2]                     │
│                                     │
│  ┌─────────────────────────────┐    │
│  │  数据卡片 (breakdown)        │    │
│  └─────────────────────────────┘    │
│                                     │
│  [AI 文字段落 3]                     │
│                                     │
└─────────────────────────────────────┘
```

### 渲染模型

```swift
// AI 文本解析后的渲染块
enum InsightBlock {
    case text(String)           // Markdown 文本段落
    case card(InsightCardType)  // 数据卡片
}

// 标记对应的卡片类型
enum InsightCardType: String, CaseIterable {
    case summary
    case breakdown
    case trend
    case comparison
    case highlights
}

// 卡片展示数据（各域适配器返回）
struct InsightCardData {
    let domain: AnalysisDomain
    let type: InsightCardType
    let metrics: [InsightMetric]      // 指标列表（名称 + 数值 + 趋势）
    let items: [InsightRankItem]?     // 排行项（标签 + 值 + 占比），breakdown 用
    let highlights: [String]?         // 亮点列表
    let warnings: [String]?           // 提醒列表
}

struct InsightMetric {
    let label: String
    let value: String
    let trend: TrendDirection?        // .up / .down / .flat
    let subtitle: String?             // 如 "较上期 ↓8.2%"
}

struct InsightRankItem {
    let icon: String?                 // SF Symbol 或 emoji
    let label: String
    let value: String
    let percentage: Double            // 0.0 - 1.0，用于进度条
}
```

> `InsightDomainContext` 对应已有的各域 AnalysisContext 类型（`FinanceAnalysisContext`、`HabitAnalysisContext` 等），定义在 `Models/AI/AnalysisDomainContexts.swift` 中。协议入参使用这些具体类型或通过泛型/关联类型约束。

AI 文本解析流程：
1. 按 `\n` 分割为行数组
2. 匹配 `{{card:xxx}}` 的行 → `InsightBlock.card(type)`
3. 相邻的文本行合并为一个 `InsightBlock.text(content)`
4. `ScrollView + VStack` 顺序渲染

### Sheet 高度自适应

使用 `.presentationDetents([.medium, .large])`，允许用户上滑展开。内容少时半屏，内容多时上滑至全屏。

### 5 种数据卡片组件

| 组件 | 布局 | 数据源 |
|------|------|--------|
| `InsightSummaryCard` | 双列网格，指标名 + 数值 + 趋势标签 | 各域的 total/daily/comparison |
| `InsightBreakdownCard` | 纵向列表，标签 + 金额 + 进度条 | 各域的 topN 分类数据 |
| `InsightTrendCard` | 横向对比，最高/最低 + 方向箭头 | 各域的 trend 数据 |
| `InsightComparisonCard` | 当前值 vs 上期值 + 变化百分比 | 各域的 comparison 数据 |
| `InsightHighlightsCard` | 亮点列表 + 提醒列表 | 各域的 anomaly/highlights |

每种卡片的实际内容由对应域的 `InsightDomainAdapter.cardData(for:context:)` 方法提供。

## 五、域扩展架构

### 核心协议：InsightDomainAdapter

```swift
protocol InsightDomainAdapter {
    var domain: AnalysisDomain { get }
    var icon: String { get }          // SF Symbol 名称
    var displayName: String { get }   // "账单分析"

    // 从 AnalysisContext 提取 Chat 卡片摘要行
    // context 为 AnalysisContext 对应域的子上下文（如 FinanceAnalysisContext）
    func summaryLine(from context: Any) -> String

    // 从 AnalysisContext 构建各类卡片的数据
    // 返回 nil 表示该域不支持此卡片类型
    func cardData(for cardType: InsightCardType, context: Any) -> InsightCardData?
}

// 工厂：按 AnalysisDomain 查找对应适配器
struct InsightDomainAdapterFactory {
    static func adapter(for domain: AnalysisDomain) -> InsightDomainAdapter
}
```

> 协议使用 `Any` 作为 context 类型以避免泛型约束对扩展造成阻碍。各适配器内部自行向下转型（如 `guard let ctx = context as? FinanceAnalysisContext`）。更优雅的方案可用关联类型，但会增加工厂实现复杂度，当前阶段 `Any` + 内部转型更实用。

### 首期实现

| 适配器 | 摘要行 | 支持的卡片 |
|--------|--------|-----------|
| `FinanceInsightAdapter` | `总支出 ¥X · 日均 ¥Y · ↓Z%` | summary, breakdown, trend, comparison, highlights |
| `HabitInsightAdapter` | `完成率 X% · 活跃 N 个 · 连续 M 天` | summary, breakdown, trend, highlights |

### 扩展新城 3 步

1. 创建 `XXXInsightAdapter` 实现 `InsightDomainAdapter` 协议
2. 在 `InsightDomainAdapterFactory` 中注册
3. 确认 AI prompt 标记指令中该域可用的卡片类型

### 跨模块分析预留

`CrossModuleInsightAdapter` 从已有的 `CrossModuleAnalysisContext` 提取跨域关联和异常数据，生成 `highlights` 和 `comparison` 卡片。标记系统完全通用，无需改动。

## 六、文件组织

### 新增文件

```
Views/Chat/Insight/
├── InsightCompactCard.swift          // Chat 中的紧凑卡片
├── InsightSheetView.swift            // Sheet 弹窗主视图
├── InsightBlockRenderer.swift        // 文本+卡片混合渲染器
├── Cards/
│   ├── InsightSummaryCard.swift      // 关键指标卡片
│   ├── InsightBreakdownCard.swift    // 分类排行卡片
│   ├── InsightTrendCard.swift        // 趋势卡片
│   ├── InsightComparisonCard.swift   // 环比对比卡片
│   └── InsightHighlightsCard.swift   // 亮点提醒卡片
Models/AI/
├── InsightBlock.swift                // 文本/卡片块枚举
├── InsightDomainAdapter.swift        // 域适配器协议 + 工厂
├── FinanceInsightAdapter.swift       // 财务域适配器
└── HabitInsightAdapter.swift         // 习惯域适配器
```

### 修改的现有文件

| 文件 | 改动 |
|------|------|
| `Services/AI/PromptManager.swift` | `analysisPrompt` 末尾追加标记使用指令 |
| `Views/Chat/MessageBubbleView.swift` | `query_analysis` 意图改为渲染 `InsightCompactCard` |
| `Models/AI/ChatCardData.swift` | 调整分析卡片生成逻辑 |
| `Views/Chat/ChatViewModel.swift` | 分析查询路径回调处理，触发 Sheet 弹出 |

### 不改动的部分

- `AnalysisContextBuilder` 及各域 Builder — 完全复用
- `ConversationCoordinator` — 意图识别和编排不变
- `IntentRouter` — 路由逻辑不变
- `AnalysisPeriodResolver` — 时间解析不变
- Core Data 模型 — 无数据迁移
