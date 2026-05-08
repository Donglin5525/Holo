# Holo AI 深度财务分析增强计划

## Context

用户希望 Holo AI 能基于历史账单做深度分析并给出建议（如"减少宵夜开销"）。当前架构已经支持方案 B（预计算注入），管道完整：

```
ConversationCoordinator → queryAnalysis 拦截
  → AnalysisPeriodResolver（解析时间范围）
  → FinanceAnalysisContextBuilder（计算聚合数据）
  → 序列化为 JSON 作为 systemContextOverride
  → analysisPrompt 模板 + 数据 一起发给 LLM
```

问题在于 `FinanceAnalysisContextBuilder` 计算的数据维度不够丰富——只有 Top 5 一级分类、月度汇总、上期对比和异常检测，缺少子分类明细、分类趋势变化、消费模式等维度，AI 无法据此给出"减少宵夜开销"这类精准建议。

## 修改范围

### 1. 增强 `FinanceAnalysisContext` 数据模型

**文件**: `Models/AI/AnalysisDomainContexts.swift`

在 `FinanceAnalysisContext` 中新增字段。**全部声明为 Optional 以兼容已持久化的旧 JSON 数据**（`analysisContextJSON` 存在 Core Data 中，旧数据不含新字段，非 Optional 会导致解码失败）：

```swift
// 新增：一级分类下的子分类明细（最多 Top 3 一级分类，每个最多 5 个子分类）
let subCategoryDetails: [SubCategoryDetail]?

// 新增：各分类的环比变化（当前期 vs 上一期，依赖对比期存在）
let categoryTrends: [CategoryTrendItem]?

// 新增：消费模式（星期几消费最高、工作日vs周末等）
let spendingPatterns: SpendingPatterns?
```

`isDataFree` 逻辑不变——新字段全部派生自同一份交易数据，当基础指标（totalExpense/totalIncome/transactionCount）为零时新字段必然为 nil，无需额外判断。

新增辅助模型：

```swift
struct SubCategoryDetail: Codable, Equatable, Sendable {
    let parentCategoryName: String
    let subCategories: [FinanceCategoryItem]  // 复用已有类型
}

struct CategoryTrendItem: Codable, Equatable, Sendable {
    let categoryName: String
    let currentAmount: Decimal
    let previousAmount: Decimal?
    let changePercent: Double?  // 正数=增长，负数=减少
}

struct SpendingPatterns: Codable, Equatable, Sendable {
    let highestSpendingDayOfWeek: DayOfWeekSpending?
    let weekdayVsWeekend: WeekdayWeekendComparison?  // Optional：仅当工作日和周末都有数据时生成
    let topFrequentCategories: [FrequentCategory]
}

struct DayOfWeekSpending: Codable, Equatable, Sendable {
    let dayName: String     // "周一", "周二"...
    let averageAmount: Decimal
}

struct WeekdayWeekendComparison: Codable, Equatable, Sendable {
    let weekdayAverage: Decimal
    let weekendAverage: Decimal
}

struct FrequentCategory: Codable, Equatable, Sendable {
    let categoryName: String
    let transactionCount: Int
    let totalAmount: Decimal
}
```

### 2. 增强 `FinanceAnalysisContextBuilder` 计算逻辑

**文件**: `Services/AI/FinanceAnalysisContextBuilder.swift`

在现有 `build()` 方法中，`return` 之前新增三个计算步骤。

**关键原则：复用已加载的 `transactions` 数组做内存聚合，不重复查 Core Data。** 现有 `build()` 第 41 行已一次性加载全部交易到内存，新步骤应基于这个数组计算，避免对同一日期范围重复执行 `getTransactions` 或 `getTopLevelCategoryAggregations`。

#### 2a. 子分类明细

从已有的 `transactions` 数组中，按 `categoryAggregations`（第 57 行返回的 `[CategoryAggregation]` 原始数组）的 Top 3 一级分类 ID 过滤交易，再按子分类聚合：

```swift
// 注意：必须在第 62 行映射为 FinanceCategoryItem 之前保存 categoryAggregations 原始引用
// CategoryAggregation.category.id 是后续按 parentId 过滤子分类交易的关键
// 对 Top 3 的每个一级分类，从 expenses 中按 parentId 过滤，按子分类 ID 聚合
// 每个一级分类最多取 Top 5 子分类
// → [SubCategoryDetail]
```

新增私有方法 `buildSubCategoryDetails(expenses:topCategoryAggregations:from:)`，接收 `[CategoryAggregation]` 而非 `[FinanceCategoryItem]`，模式参照现有的 `buildMonthlyBreakdown`。

#### 2b. 分类趋势

**仅在对比期存在时计算**。从 `request.comparisonStart` / `request.comparisonEnd` 取对比期日期范围，查一次 `getTransactions`，然后从内存中按一级分类聚合（复用 `topLevelCategories` 缓存，参照 `getTopLevelCategoryAggregations` 的内存逻辑），与当前期的 `categoryAggregations` 逐分类对比：

```swift
guard let compStart = request.comparisonStart, let compEnd = request.comparisonEnd else {
    // 对比期不存在，categoryTrends 保持 nil
}
// 查询对比期交易（一次额外的 getTransactions，不可避免）
// 查询一级分类列表 getTopLevelCategories(by: .expense)（轻量，只查分类表）
// 内存聚合对比期 → 按分类名匹配当前期 → 计算 changePercent
// 除零保护：previousAmount 为 0 时 changePercent 返回 nil
// → [CategoryTrendItem]
```

> 注：对比期交易查询不可避免（现有代码第 84 行也做了一次）。一级分类缓存无法复用 `getTopLevelCategoryAggregations` 内部的局部变量，需单独查一次 `getTopLevelCategories`，但只查分类表，很轻量。

#### 2c. 消费模式

从已有的 `expenses` 数组中计算（纯内存操作，零额外查询）：

- 按星期几分组求均值 → 最高的那天
- 工作日 vs 周末的消费均值对比（仅当两边都有数据时生成）
- 按交易笔数排序的高频消费分类（最多 Top 5）

```swift
// 按 calendar.component(.weekday, from: tx.date) 分组
// weekday = 2-6 (周一至周五), weekend = 1,7 (周日、周六)
// weekdayAvg = weekdayExpenses.sum / weekdayDayCount（按去重天数算均值）
// weekendAvg = weekendExpenses.sum / weekendDayCount
```

新增私有方法 `buildSpendingPatterns(expenses:start:end:calendar:)`。

### 3. 强化 `analysisPrompt` 提示词

**文件**: `Services/AI/PromptManager.swift`

不新增独立章节（避免与现有规则重复），而是在现有第 2 条规则的基础上强化：

```
现有：
  "2. 数字必须和 JSON 上下文中的数据完全一致，不要重新计算或估算。"

改为：
  "2. 数字必须和 JSON 上下文中的数据完全一致，不要重新计算、估算、四舍五入或用分数近似。例如数据写 35.2% 就不能写成「约35%」或「三分之一」。增减幅度直接使用 JSON 中的 changePercent 字段值。"
```

在"财务"分析侧重中增加子分类和趋势维度：

```
现有：
  "- **财务**：消费趋势、分类占比、异常消费、预算执行情况、节省建议。"

改为：
  "- **财务**：消费趋势、分类及子分类占比、分类环比变化、消费模式（工作日/周末、高频分类）、异常消费、预算执行、节省建议。建议必须具体到分类名称和金额。"
```

### 4. ~~可选：AI 回复数字校验~~ → MVP 不实现

对抗性审查结论：`NumberValidator` 的实现难度被低估。AI 回复中的数字格式多样（"2340元"、"2,340"、"两千三百四十"），且无法可靠地将回复中的数字映射回上下文字段。简单正则会误匹配日期、序号等。

**决策**：MVP 阶段依赖 prompt 约束（步骤 3 的强化规则）即可。如果上线后确实出现数字失真问题，再设计更可靠的校验方案（比如让 AI 在回复中标注数据来源字段）。

~~**文件**: `Views/Chat/ChatViewModel.swift`~~ — 不修改
~~**新建文件**: `Services/AI/NumberValidator.swift`~~ — 不创建

## 不修改的部分

- `ConversationCoordinator` — 拦截逻辑不变
- `AnalysisPeriodResolver` — 日期解析逻辑不变
- `AnalysisContextBuilder` — 分发逻辑不变
- `ChatViewModel` — 分析路径的消息发送逻辑不变
- `FinanceRepository+Aggregation` — 不新增查询方法，仅复用现有方法
- `NumberValidator` — MVP 不实现

## 实施顺序

| 步骤 | 文件 | 改动 |
|------|------|------|
| 1 | `AnalysisDomainContexts.swift` | 新增 5 个数据模型 + 扩展 `FinanceAnalysisContext`（Optional 字段） |
| 2 | `FinanceAnalysisContextBuilder.swift` | 新增 3 个私有方法 + 在 `build()` 中调用 |
| 3 | `PromptManager.swift` | 强化 `analysisPrompt` 第 2 条规则和财务侧重描述 |

## 验证方式

1. 编译通过
2. 在 AI 对话中输入："分析一下我最近三个月的消费习惯"
3. 验证返回的分析包含：子分类明细（如"餐饮"下的"外卖"、"宵夜"等）、各分类环比变化、消费模式
4. 抽查回复中的数字是否与实际数据一致
5. 打开一条旧的分析聊天记录，验证不会因解码失败而崩溃
