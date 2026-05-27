# Holo Sense Layer 洞察闭环方案（终版）

> 经过两轮对抗性审查修订。本方案聚焦 Holo 记忆洞察体系，不直接重构普通 HoloAI 聊天体验。

## Goal

将 Holo 的 AI 洞察从"周期性生成回放报告"升级为"可感知、可校准、可行动的生活观察闭环"。

用户最终感受到的不是 Holo 写了一份更漂亮的周报，而是：

> Holo 能持续看见我的生活节奏，知道哪些判断对我有用，哪些表达不适合我，并能把洞察变成下一步行动。

## Architecture

本方案不新建一套并行 AI 系统，继续复用现有主链路：

```text
MemoryInsightContextBuilder
  -> MemoryInsightService
  -> AIProvider.generateMemoryInsight()
  -> MemoryInsightPayload
  -> MemoryInsightRepository(Core Data)
  -> Memory Gallery UI
```

在现有主链路前后补两层：

```text
生成前：Sense Context
  - 今日状态信号
  - 健康信号
  - 长期偏好摘要

生成后：Learning & Action Layer
  - 用户反馈
  - 偏好聚合
  - 卡片 rerank / filter
  - 行动候选
```

核心原则：

1. 用户反馈不直接进入 Prompt。
2. Prompt 只接收稳定、压缩、结构化后的偏好摘要。
3. 大部分"变准"发生在本地结构化学习、排序、过滤和行动建议层。
4. 健康数据只作为生活信号，不做医疗判断。
5. 跨模块关系只能表达为并发或值得留意，不做因果断言。

## Current Context

当前 Holo 已经具备较好的洞察底座：

| 能力 | 现状 |
|------|------|
| 周期洞察 | 支持 daily / weekly / monthly / quarterly / custom |
| 上下文构建 | `MemoryInsightContextBuilder` 聚合财务、习惯、待办、想法、里程碑 |
| 异常检测 | 已有消费突增、预算异常、习惯断连、任务堆积等结构化异常 |
| 跨模块关联 | `CrossModuleCorrelator` 已输出跨模块并发现象 |
| 个性化上下文 | 洞察生成已接入 `personalProfileContext` |
| 持久化 | `MemoryInsight` Core Data 已保存 title / summary / cards / rawResponse / promptVersion |
| 反馈字段 | `MemoryInsight` 已有 `userRating`、`feedbackNote`，但 UI 和学习闭环尚未接入 |
| 后台生成 | `MemoryInsightBackgroundService` 支持 best-effort 自动生成和前台补偿 |

关键代码现状（审查确认）：

| 项目 | 现状 |
|------|------|
| `MemoryInsightCard.type` | 8 case 枚举：`habit`/`finance`/`task`/`thought`/`milestone`/`crossDomain`/`overview`/`anomaly`。无 `module` 或 `patternType` 字段 |
| `mapCardTypeToModule()` | 存在 bug：`.anomaly` 和 default 都映射为 `.finance`，Phase 0 必须修复 |
| `snapshotHash` | SHA256 of 完整 `MemoryInsightContext` JSON（含 `generatedAt`），导致相同数据产生不同 hash，Phase 0 必须修复 |
| 卡片展示 | `MemoryInsightHeroCard` 硬编码 `prefix(5)` 截断 |
| 反馈数据层 | `MemoryInsightRepository.updateRating()` 已实现，零 UI 调用 |
| 健康数据 | `HealthRepository` 已有步数/睡眠/站立/运动，完全未接入洞察链路 |
| `HoloProfileService` | 存 Markdown 文件（非 JSON），8KB 上限，独立 Service |
| Feature Flag | 不存在，只有 `#if DEBUG` 编译指令 |

当前主要缺口：

| 缺口 | 影响 |
|------|------|
| 反馈没有结构化学习 | 用户点"不准"后，Holo 不知道是事实错、重点错、关联错还是语气错 |
| 缺少长期洞察偏好 | 每次洞察像重新认识用户，无法稳定减少用户不喜欢的判断方式 |
| 缺少状态雷达 | 洞察偏周期报告，日常陪伴感弱 |
| 健康未进入主洞察链路 | 睡眠、步数、站立、运动等无法参与生活节奏判断 |
| 洞察未转行动 | 卡片看完后缺少"下一步" |
| Prompt 容易被反馈污染 | 如果把用户反馈原文直接塞进 Prompt，长期会导致上下文膨胀和行为漂移 |

## Non-Goals

本轮明确不做：

| 不做 | 原因 |
|------|------|
| 不让模型自由记忆用户反馈原文 | 避免 Prompt 污染、指令注入和长期漂移 |
| 不把所有用户反馈都写入 `HoloProfile` | `HoloProfile` 是用户主动档案，洞察偏好应独立维护 |
| 不自动创建任务、习惯、预算 | 行动候选必须经用户确认 |
| 不默认推送健康/异常通知 | 通知需要单独 opt-in、冷却和打扰策略 |
| 不做医疗、心理、人格判断 | 健康和想法只作为生活信号 |
| 不一次性重构 AI Chat 全链路 | 先收敛在 Memory Insight 体系，降低风险 |

## Target System

整体闭环：

```text
用户记录数据
  -> 财务 / 习惯 / 待办 / 想法 / 健康
  -> Sense Signal 提取
  -> AI 生成洞察候选
  -> Preference Profile 本地 rerank / filter
  -> 展示洞察卡 / 每日状态 / 行动候选
  -> 用户反馈
  -> Feedback Aggregator 聚合
  -> InsightPreferenceProfile 更新
  -> 下次生成更准
```

### 1. InsightPreferenceProfile: 洞察偏好画像

新增独立画像：`InsightPreferenceProfile`。

它不是用户自我介绍，也不是聊天长期记忆，而是"洞察系统如何更适合这个用户"的结构化偏好。

```swift
struct InsightPreferenceProfile: Codable, Equatable {
    var schemaVersion: Int = 1
    var moduleWeights: [InsightModulePreference]
    var dislikedPatterns: [InsightPatternPreference]
    var preferredTone: InsightTonePreference
    var usefulSuggestionTypes: [InsightSuggestionPreference]
    var recurringThemes: [InsightRecurringTheme]
    var lastDataActivityDate: Date?
    var updatedAt: Date
}

struct InsightModulePreference: Codable, Equatable {
    let module: InsightModuleKey
    var weight: Double          // 默认 1.0，范围 0.0-2.0
    var evidenceCount: Int      // 支撑此权重的反馈次数
    var isStable: Bool          // true = 已升级为稳定偏好，不过期
}

struct InsightPatternPreference: Codable, Equatable {
    let patternType: String
    var penalty: Double         // 默认 0.0，范围 0.0-1.0
    var reason: String?
    var evidenceCount: Int
    var isStable: Bool
}

struct InsightSuggestionPreference: Codable, Equatable {
    let suggestionType: InsightActionType
    var weight: Double
    var evidenceCount: Int
    var isStable: Bool
}

struct InsightRecurringTheme: Codable, Equatable {
    let theme: String           // 如 "社交支出"、"恢复迹象"
    var frequency: Int
    var lastSeenAt: Date
}

enum InsightTonePreference: String, Codable {
    case balanced
    case direct
    case gentle
    case dataFirst
    case fewerSuggestions
}

enum InsightModuleKey: String, Codable {
    case finance, habit, task, thought, health
    case crossDomain, overview, anomaly, milestone
}
```

说明：

- `schemaVersion`：JSON schema 版本号，第一版 = 1。后续新增字段时递增，Service 加载时走对应迁移路径。
- `isStable`：区分弱信号（未达阈值，30 天过期）和稳定偏好（已达阈值，永久有效直到反向反馈）。弱信号升级为稳定偏好的条件：最近 30 天内同类反馈 ≥ 2 次。
- `InsightModuleKey` 不复用现有 `InsightModule`（只覆盖 finance/habit/task/thought），因为需要表达 health、overview、anomaly 等展示层类型。
- `InsightSuggestionPreference` 和 `InsightRecurringTheme` 第一版允许为空数组，Phase 2 补充最小字段。
- `lastDataActivityDate`：记录最后一次有新数据的日期。超过 90 天无新数据时标记画像为 stale，可在 UI 提示用户是否重置。

用途：

| 用途 | 说明 |
|------|------|
| 卡片排序 | 用户长期不关心的模块降权，长期反馈有用的模块升权 |
| 表达风格 | 控制"直接/温和/数据型/少建议" |
| 建议类型 | 优先给用户觉得有用的行动候选 |
| Prompt 摘要 | 只把稳定偏好摘要注入 Prompt，不注入原始反馈 |

持久化：

- JSON 文件存储在 `Application Support/Holo/InsightPreferenceProfile.json`。
- 使用独立 `InsightPreferenceProfileService`（单例），不复用 `HoloProfileService`。
- **必须使用原子写入**（`Data.write(to:options: .atomic)`），防止写入中途被杀导致损坏。
- 所有字段使用 `decodeIfPresent` + 默认值解码，保证旧版 JSON 总能成功加载。
- 损坏时回退默认画像，保留原始反馈记录（可从反馈重建画像）。

`MemoryInsightCardType` → `InsightModuleKey` 映射表（Phase 0 修 `mapCardTypeToModule` 后）：

| MemoryInsightCardType | InsightModuleKey | 说明 |
|----------------------|------------------|------|
| `.habit` | `.habit` | 直接映射 |
| `.finance` | `.finance` | 直接映射 |
| `.task` | `.task` | 直接映射 |
| `.thought` | `.thought` | 直接映射 |
| `.milestone` | `.milestone` | 直接映射 |
| `.crossDomain` | `.crossDomain` | 直接映射 |
| `.overview` | 由 `moduleHint` 补充 | 可涉及多模块 |
| `.anomaly` | 由 `moduleHint` 补充 | 可涉及多模块 |

健康卡片第一版复用 `.overview` type + `moduleHint = "health"`，不新增 card type（避免改 Prompt 输出 schema）。

### 2. Feedback Loop: 反馈闭环

反馈拆成两个独立维度，避免"准"和"有用"语义互相覆盖：

```text
准确性：准 / 不准
价值感：有用 / 没用
```

交互规则：

1. 用户可以只点一个维度，也可以两个都点。
2. 选择"不准"时，**必须**再选择不准原因。
3. 选择"没用"时，可选选择无用原因，不强制填写。
4. 第一版不对 `failed` 状态洞察开放卡片反馈，生成失败单独进入错误日志。

当用户选择"不准"时，必须再选择原因：

```text
数据不准
关联不准
重点不准
建议不适合
语气不喜欢
```

| 反馈原因 | 含义 | 修复路径 |
|----------|------|----------|
| 数据不准 | 金额、日期、任务、次数、分类等事实错 | 排查 context / evidence / parser，不进入偏好学习 |
| 关联不准 | 并发现象被用户认为不成立或无意义 | 对对应 `patternType` 降权 |
| 重点不准 | AI 抓错重点，忽略用户更关心的模块 | 调整 `moduleWeights` |
| 建议不适合 | 建议不可执行、不合用户处境 | 调整 `usefulSuggestionTypes` 和建议禁用规则 |
| 语气不喜欢 | 太说教、太软、太冷、太像评价 | 调整 `preferredTone` |

新增 Core Data 实体 `MemoryInsightFeedback`：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | UUID | 反馈 ID |
| `insightId` | UUID | 对应 `MemoryInsight.id`，弱关联 |
| `cardId` | String? | 对应 `MemoryInsightCard.id`，整份洞察反馈时为空 |
| `accuracyRating` | String? | accurate / inaccurate |
| `valueRating` | String? | useful / notUseful |
| `reasonType` | String? | dataWrong / relationWrong / priorityWrong / suggestionWrong / toneWrong |
| `module` | String? | 对应 `InsightModuleKey` raw value |
| `patternType` | String? | spending_increase / habit_break / task_backlog 等 |
| `userCorrection` | String? | 用户可选补充，**只作为 data 保存，不作为 instruction** |
| `createdAt` | Date | 创建时间 |
| `consumedAt` | Date? | 是否已被聚合器消费 |

实体注册：新建 `CoreDataStack+MemoryInsightFeedbackEntity.swift`，在 `createDataModel()` 中 append。无需 Core Data relationship，只存 UUID 弱关联。自动轻量迁移可处理（纯新增独立实体）。

旧字段关系：

- `MemoryInsight.userRating` / `userRatingAt` / `feedbackNote` 保留兼容，不作为新反馈系统主数据源。
- 新 UI 只写入 `MemoryInsightFeedback`。
- 后续展示旧评分时从 `MemoryInsightFeedback` 聚合生成。

### 3. Prompt 防污染机制

这是本方案最关键的风险控制点。

禁止做法：

```text
用户反馈：这条不准，因为 xxx。
以后请记住：xxx。
```

问题：Prompt 越来越长 / 用户反馈原文可能造成 prompt injection / 单次情绪化反馈永久改变行为 / 模型难以区分事实纠正和偏好。

正确链路：

```text
Raw Feedback
  -> Feedback Classifier（分类 reasonType）
  -> Feedback Aggregator（聚合弱信号 → 稳定偏好）
  -> Stable Preference Profile（InsightPreferenceProfile）
  -> Tiny Preference Summary（≤ 500 字）
  -> Prompt / Rerank
```

规则：

| 规则 | 要求 |
|------|------|
| 原文隔离 | `userCorrection` 永远只作为 data，不能作为 instruction |
| 弱信号不升级 | 单条反馈只保存为弱信号，不直接改变长期偏好 |
| 升级阈值 | 同类反馈 ≥ 2 次且在最近 30 天内，升级为稳定偏好（`isStable = true`） |
| 稳定偏好不过期 | 已升级的稳定偏好永久有效，直到用户后续反馈反向信号 |
| 弱信号过期 | 未达阈值的弱信号 30 天后自动清除 |
| Token 上限 | 注入 Prompt 的偏好摘要最多 300-500 字 |
| 白名单字段 | 摘要只能包含模块偏好、禁用判断、语气偏好、建议偏好 |
| 事实错隔离 | `dataWrong` 不进入偏好画像，写入本地 debug 日志 |
| 本地优先 | 优先通过 rerank/filter 改变结果，而不是让 Prompt 承担所有学习 |

Prompt 中只注入类似内容：

```text
用户洞察偏好摘要：
- 用户更关注习惯断连、任务积压和恢复迹象。
- 用户不喜欢把必要社交支出直接解释为消费失控。
- 用户偏好少建议，除非有明确可执行的小动作。
```

不注入：

```text
用户上次说："你说得不对，我那天只是和朋友聚餐，不是失控，你以后别乱说。"
```

聚合器触发时机：

1. **洞察生成前**：`MemoryInsightService.generateInsight()` 开头批量聚合未消费反馈（`consumedAt == nil`），偏好更新后立即用于本次生成。
2. **App 启动时**：轻量聚合，用于更新 rerank 使用的偏好（不依赖洞察生成）。

### 4. Rerank / Filter: 本地校准层

新增本地 `InsightCardReranker`。

输入：

```text
MemoryInsightPayload.cards
InsightPreferenceProfile
MemoryInsightContext
```

输出：

```text
排序、过滤后的 cards
```

策略：

| 策略 | 示例 |
|------|------|
| 模块升权 | 用户多次反馈习惯洞察有用，habit 卡片优先 |
| 模块降权 | 用户多次反馈小额财务波动不重要，finance 小波动卡降权 |
| 模式降权 | 用户不喜欢"餐饮升高=需要控制"的判断，对该 pattern 降权 |
| 异常保底 | critical anomaly 不因偏好被完全隐藏，只能改变位置 |
| 恢复优先 | 用户偏好恢复迹象时，recovering pattern 升权 |
| 低证据过滤 | evidence 为空或弱证据卡片降权 |

Rerank 第一版只影响展示顺序，不改写 AI 原文。

Rerank 作用域和限制：

- **只对当前选中周期的最新洞察做动态 rerank**。历史旧洞察保持原始顺序，避免回看体验漂移。
- 偏好变化后，当前洞察**立即 rerank**（展示顺序变），但**不重新生成**（卡片内容不变）。
- **操作空间限制**：AI 通常生成 3-5 张卡片，`MemoryInsightHeroCard` 展示前 N 张（Phase 3 同步从 `prefix(5)` 扩展为可展开，至少支持 7 张）。在卡片数 ≤ 5 的常见场景下，rerank 的实际价值主要是"降权沉底"而非"升权浮出"。方案如实承认此限制。

卡片模块归属：

- `MemoryInsightCard.type` 能直接表达 `habit`/`finance`/`task`/`thought` 时，从 type 推导 `InsightModuleKey`，不新增冗余字段。
- 对 `overview`/`anomaly`/`crossDomain`/`milestone`，新增可选字段 `moduleHint: String?` / `patternType: String?`，供 rerank 使用。
- `moduleHint` / `patternType` 由本地 post-process 填充（在 `MemoryInsightResponseParser.parse()` 后处理阶段），基于 `card.type` + `card.title`/`card.body` 关键词匹配。**第一版不改 Prompt 输出 schema**。

### 5. Action Loop: 行动闭环

洞察卡增加行动候选，所有行动需要用户确认。

```swift
struct InsightActionCandidate: Codable, Equatable, Identifiable {
    let id: String
    let cardId: String
    let type: InsightActionType
    let title: String
    let payload: InsightActionPayload
    let confidence: Double
}

enum InsightActionType: String, Codable {
    case createTask
    case adjustHabit
    case budgetReminder
    case reflectionQuestion
    case scheduleCheckIn
    case noAction
}
```

`InsightActionPayload` 使用规则生成的固定 payload，带标签关联值需手写 `Codable`：

```swift
enum InsightActionPayload: Equatable {
    case taskDraft(title: String, dueDate: Date?, priority: Int16?)
    case habitAdjustmentDraft(habitId: UUID, targetValue: Double?)
    case budgetReminderDraft(categoryId: UUID?, amount: Decimal?)
    case reflectionQuestion(String)
    case checkInReminder(Date)
    case noAction
}
// 注意：需手写 Codable 实现（带标签关联值无法自动合成）
```

第一版行动模板（硬编码 3-5 个高频场景，不搞注册机制）：

| 触发条件 | 行动类型 | Payload |
|----------|----------|---------|
| 任务逾期 ≥ 3 | `createTask` | `taskDraft(title: "20 分钟清理逾期待办", dueDate: 今天, priority: nil)` |
| 习惯断连 ≥ 3 天 | `adjustHabit` | 需要传入 habitId，从 context 中获取断连的具体习惯 |
| 消费偏离均值 > 1.5x | `budgetReminder` | `budgetReminderDraft(categoryId: 对应分类, amount: 均值)` |
| 恢复迹象 | `reflectionQuestion` | `reflectionQuestion("这次恢复是怎么发生的？")` |

匹配方式：按 `card.type` + `anomalySeverity` + `patternType` 匹配，不依赖关键词。

产品规则：

1. 默认只展示 1 个最相关行动。
2. 不自动执行。
3. 用户确认后调用现有任务、习惯、预算链路。
4. 用户拒绝行动也作为反馈，影响 `usefulSuggestionTypes`。

### 6. Health Context: 健康接入

新增 `HealthInsightContext`（带标签关联值的枚举需手写 `Codable`）：

```swift
struct HealthInsightContext: Codable, Equatable {
    let sleepDurationHours: Double?
    let stepCount: Int?
    let standHours: Int?
    let workoutMinutes: Int?
    let dataAvailability: HealthDataAvailability
    let signals: [HealthSignal]
}

struct HealthSignal: Codable, Equatable {
    let type: String        // sleepShort / stepLow / standLow / workoutRecovery
    let severity: String    // info / warning
    let title: String
    let evidence: [String]
}

enum HealthDataAvailability: Equatable {
    case fullyAvailable
    case partiallyAvailable(availableTypes: [String], missingTypes: [String])
    case notAvailable(reason: String)
}
// 注意：需手写 Codable 实现
```

权限降级规则：

- `notAvailable`：不生成健康相关状态和周期洞察。
- `partiallyAvailable`：只使用 `availableTypes` 中真实存在的指标；`missingTypes` 只能用于说明"未授权/无数据"，**不能推断异常**。
- `fullyAvailable`：仍然只表达生活并发信号，不做医疗或心理判断。

跨模块表达规则：

| 允许 | 禁止 |
|------|------|
| "睡眠偏短和任务逾期在同一天出现" | "因为你睡得少，所以任务逾期" |
| "运动恢复后，习惯完成率也回升，值得留意" | "运动证明你状态变好了" |
| "今天站立小时较少，可能适合安排一个轻量活动提醒" | "你身体不好" |

### 7. Daily Sense State: 状态雷达

第一版只开放 3 个状态，降低规则组合爆炸风险：

```swift
enum DailySenseState: String, Codable {
    case stable       // 稳定
    case atRisk       // 断连风险
    case recovering   // 恢复中
}
```

其余 `overloaded` / `drifting` / `light` 保留为后续扩展，不进入第一版 UI。

状态优先级：`atRisk` > `recovering` > `stable`。多信号冲突时取高优先级。

```swift
struct DailySenseSnapshot: Codable, Equatable {
    let date: Date
    let state: DailySenseState
    let confidence: Double
    let reasons: [String]     // 最多 3 条，可追溯到真实数据
    let suggestedAction: InsightActionCandidate?
    let generatedAt: Date
}
```

持久化：JSON 数组存在 `Application Support/Holo/DailySenseSnapshots.json`，只保留最近 7 天，超过自动清理。不做历史回看 UI。

生成策略：

1. 第一版使用规则引擎，不调用 AI。
2. 数据不足时输出 `stable` 或不展示状态，不硬凑。
3. 状态只展示一个，原因最多 3 条。
4. 展示位置：第一版放在记忆长廊顶部。

第一版信号：

| 信号 | atRisk 触发 | recovering 触发 |
|------|------------|----------------|
| 任务 | 逾期 ≥ 3 | 逾期不再增加 |
| 习惯 | 正面习惯断连 ≥ 2 天 | 断连习惯恢复打卡 |
| 消费 | 偏离均值 > 1.5x | 回归均值范围 |
| 想法 | 负面情绪占比 > 50% | 正面情绪回升 |

## Implementation Plan

### Phase 0: 基础设施与前置修正

目标：在引入反馈学习前，先修掉会影响缓存、回滚和灰度的基础问题。

修改范围：

| 文件 | 改动 |
|------|------|
| `Services/AI/MemoryInsightContextBuilder.swift` | `computeHash()` 排除 `generatedAt` 等运行时字段，保证相同数据生成稳定 hash |
| `Services/AI/MemoryInsightContextBuilder.swift` | 修复 `mapCardTypeToModule()`，按上方映射表修正；不可映射卡片返回 nil 而非硬归 finance |
| `Services/FeatureFlags/InsightFeatureFlags.swift` | 新增轻量 UserDefaults feature flag |
| `Models/MemoryInsightModels.swift` | 为 `MemoryInsightCard` 新增可选 `moduleHint: String?` / `patternType: String?` |

Feature Flag 第一版（UserDefaults Bool，Release 可关闭）：

```text
insight.feedback.enabled
insight.preferenceLearning.enabled
insight.rerank.enabled
insight.dailySense.enabled
insight.healthContext.enabled
insight.actionCandidate.enabled
```

验收：

- 相同业务数据连续构建 context，`snapshotHash` 保持一致。
- `.overview` / `.crossDomain` / `.milestone` / `.anomaly` 不再被映射为 `.finance`。
- Release build 中也可以通过 UserDefaults 关闭新能力。

### Phase 1: 反馈采集 MVP

目标：先收集结构化反馈，不影响洞察生成。

修改范围：

| 文件 | 改动 |
|------|------|
| `Models/CoreDataStack+MemoryInsightFeedbackEntity.swift` | 新增 `MemoryInsightFeedback` 实体（新建扩展文件，在 `createDataModel()` 中 append） |
| `Models/MemoryInsightModels.swift` | 新增反馈枚举 `AccuracyRating` / `ValueRating` / `FeedbackReasonType` |
| `Data/Repositories/MemoryInsightRepository.swift` | 新增保存/查询反馈方法 |
| `Views/MemoryGallery/Components/MemoryInsightCardView.swift` | 增加反馈按钮入口 |
| `Views/MemoryGallery/Components/*` | 新增"不准原因"选择 UI |
| `Services/AI/MemoryInsightDebugLogService.swift` | 本地记录 `dataWrong` 事件，保留最近 50 条 |

验收：

- 用户可对单张卡片反馈准确性（准/不准）和价值感（有用/没用）。
- 点"不准"必须选择原因。
- 反馈保存到 Core Data。
- 不改变当前洞察生成结果。
- `dataWrong` 不进入偏好画像，但在本地 debug 日志中可查。
- 反馈 UI 在后台生成、前台补偿、直接打开长廊三种场景下均可正常工作。

### Phase 2: 反馈聚合器

目标：把原始反馈变成稳定偏好信号。

新增：

| 文件 | 改动 |
|------|------|
| `Services/AI/InsightFeedbackAggregator.swift` | 聚合同类反馈，生成偏好更新 |
| `Services/AI/InsightPreferenceProfileService.swift` | 读取/写入偏好画像（JSON + 原子写入 + schemaVersion 迁移） |
| `Models/InsightPreferenceProfile.swift` | 偏好画像模型 |

聚合规则：

- `dataWrong` 不进入偏好画像，写入 debug 日志。
- `priorityWrong` → 调整 `moduleWeights`。
- `relationWrong` → 调整 `patternType` penalty。
- `suggestionWrong` → 调整建议类型偏好。
- `toneWrong` → 调整 `preferredTone`。
- **弱信号**：单次反馈产生弱信号（`isStable = false`），30 天过期。
- **稳定偏好**：最近 30 天内同类反馈 ≥ 2 次，升级为稳定偏好（`isStable = true`），永久有效直到反向反馈。

触发时机：

1. 洞察生成前（`MemoryInsightService.generateInsight()` 开头）批量聚合。
2. App 启动时轻量聚合（更新 rerank 用的偏好）。

验收：

- 连续多次反馈同一类问题后，`InsightPreferenceProfile` 发生稳定变化。
- 单次反馈不会立刻改变长期偏好。
- 用户原文不会进入 Prompt 摘要。
- 弱信号 30 天后自动过期；稳定偏好不过期。
- `schemaVersion` 正确持久化和迁移。
- 损坏 JSON 文件时回退默认画像，App 不崩溃。

### Phase 3: 本地 rerank / filter

目标：先用偏好影响展示顺序，避免过早改 Prompt。

新增：

| 文件 | 改动 |
|------|------|
| `Services/AI/InsightCardReranker.swift` | 根据偏好给卡片打分 |
| `Services/AI/MemoryInsightResponseParser.swift` | 后处理阶段填充 `moduleHint` / `patternType` |
| `Views/MemoryGallery/Components/MemoryInsightHeroCard.swift` | 从 `prefix(5)` 改为可展开（至少支持 7 张） |
| `Views/MemoryGallery/MemoryGalleryViewModel.swift` | 展示前应用 rerank |

验收：

- 用户偏好的模块卡片排序上升。
- 用户反复标记不准的 pattern 排序下降。
- critical anomaly 不被完全隐藏。
- 没有偏好画像时，展示结果与现有行为基本一致。
- 只对当前选中周期的最新洞察做动态 rerank；历史旧洞察保持原始顺序。
- 偏好变化后当前洞察展示顺序立即改变，但卡片内容不变。

### Phase 4: Daily Sense State

目标：新增每日状态雷达基础版。

新增：

| 文件 | 改动 |
|------|------|
| `Models/DailySenseSnapshot.swift` | 每日状态模型 |
| `Services/AI/DailySenseStateBuilder.swift` | 基于规则生成状态 |
| `Services/AI/DailySenseSnapshotStore.swift` | JSON 数组持久化，保留最近 7 天 |
| `Views/MemoryGallery/*` | 展示每日状态（第一版放在记忆长廊顶部） |

验收：

- 有足够数据时展示一个状态。
- 数据不足时不硬凑（`stable` 或不展示）。
- 原因可追溯到真实数据，最多 3 条。
- 状态优先级：`atRisk` > `recovering` > `stable`。
- 超过 7 天的快照自动清理。

### Phase 5: 健康接入

目标：健康指标进入每日状态和周期洞察上下文。

修改：

| 文件 | 改动 |
|------|------|
| `Services/Health/*` | 暴露洞察所需健康摘要 |
| `Models/MemoryInsightModels.swift` | `MemoryInsightContext` 新增 `health: HealthInsightContext?` |
| `Services/AI/MemoryInsightContextBuilder.swift` | 构建 `HealthInsightContext` |
| `Services/AI/DailySenseStateBuilder.swift` | 健康信号参与每日状态判断 |
| `Services/AI/PromptManager.swift` + 后端 Prompt | 增加健康信号表达边界 |

**后端发版提醒**：如果改动后端 Prompt（Phase 5 进入周期 AI Prompt 时），需同步修改 `HoloBackend/src/prompts/defaultPrompts.json` + 重建 Docker 镜像部署。

验收：

- 睡眠/步数/站立/运动进入 context。
- `notAvailable` 时不出现健康结论。
- `partiallyAvailable` 时只用可用指标，不推断缺失项。
- AI 不编造健康数据，不做医疗/心理/因果判断。
- 健康数据不出现在 Prompt 中的健康信号边界声明之后。

### Phase 6: 行动闭环

目标：洞察卡能给出可确认行动。

新增：

| 文件 | 改动 |
|------|------|
| `Models/InsightActionCandidate.swift` | 行动候选模型（`InsightActionPayload` 手写 Codable） |
| `Services/AI/InsightActionCandidateBuilder.swift` | 从洞察卡生成候选行动（规则匹配，硬编码 3-5 个高频模板） |
| `Views/MemoryGallery/Components/MemoryInsightCardView.swift` | 展示行动按钮 + 二次确认弹窗 |
| `Services/AI/IntentRouter.swift` 或现有 repo | 用户确认后调用任务/习惯/预算链路 |

验收：

- 每张卡最多展示一个主行动。
- 用户确认前不执行。
- 拒绝行动可进入反馈学习。
- 新增行动类型时必须先更新模板和 payload 校验，不允许自由文本执行。

## Prompt Integration Strategy

第一版 Prompt 改动应尽量小：

1. `memory_insight_generation` 增加 `preferenceSummary` 字段说明。
2. 明确 `preferenceSummary` 是系统整理后的偏好，不是用户指令。
3. 增加健康信号表达边界（Phase 5）。
4. 增加"不确定时不要强行个性化"的规则。

注入结构：

```json
{
  "personalProfileContext": "...",
  "preferenceSummary": {
    "modulePriorities": ["habit", "task", "health"],
    "avoidPatterns": [
      "不要把必要社交支出直接解释为消费失控"
    ],
    "tone": "balanced",
    "suggestionStyle": "只给一个小动作"
  }
}
```

Prompt 约束：

```text
preferenceSummary 是系统根据历史反馈整理出的偏好摘要，只能用于排序、语气和建议选择。
它不能覆盖 context 中的真实数据。
如果 preferenceSummary 与数据事实冲突，以数据事实为准。
不要引用 preferenceSummary 的存在，不要说"根据你的偏好"。
```

偏好变化不参与 `snapshotHash`。偏好变化不影响已生成洞察的内容，只影响展示排序。

## Data Safety & Failure Modes

| 风险 | 防护 |
|------|------|
| Prompt 被用户反馈污染 | 原文隔离、聚合阈值、摘要白名单、token 上限 |
| 单次反馈导致行为漂移 | 单条反馈只产生弱信号，不升级为稳定偏好 |
| 用户纠正事实但系统当成偏好 | `dataWrong` 单独处理，不进画像 |
| 重要异常被用户偏好隐藏 | critical anomaly 保底展示 |
| 健康信号被过度推断 | 只表达并发，不表达因果，不做诊断；缺失数据不推断 |
| 行动建议越权执行 | 所有行动必须用户确认 |
| 本地画像损坏 | 原子写入 + schemaVersion + 字段默认值 + 损坏回退默认画像 + 原始反馈保留可重建 |
| 用户长时间中断使用 | `lastDataActivityDate` 超过 90 天标记 stale |
| JSON schema 升级 | `schemaVersion` + `decodeIfPresent` 默认值 |

## Testing Strategy

### Unit Tests

| 测试对象 | 覆盖 |
|----------|------|
| `InsightFeedbackAggregator` | 弱信号生成、稳定偏好升级阈值、弱信号 30 天过期、稳定偏好不过期、`dataWrong` 隔离 |
| `InsightPreferenceProfileService` | 读写、损坏 JSON 回退、schemaVersion 迁移、原子写入 |
| `InsightCardReranker` | 模块升权/降权、pattern penalty、critical anomaly 保底、无偏好时与原始顺序一致 |
| `DailySenseStateBuilder` | stable / atRisk / recovering 三状态规则、状态优先级、数据不足降级 |
| `HealthInsightContext` 构建 | 无权限 / 无数据 / 部分数据可用 / fullyAvailable |
| `MemoryInsightResponseParser` post-process | `moduleHint` / `patternType` 填充 |
| `HealthDataAvailability` Codable | 编码/解码 round-trip |
| `InsightActionPayload` Codable | 编码/解码 round-trip |

### Integration Tests

| 场景 | 期望 |
|------|------|
| 用户反馈财务小波动不准 × 2 | 稳定偏好生效，后续财务小波动卡排序下降 |
| 用户反馈任务洞察有用 × 2 | 任务相关卡排序上升 |
| 用户反馈"数据不准" | 不改变偏好画像，只记录 debug 日志 |
| 健康无授权 | context 标记 notAvailable，AI 不输出健康结论 |
| 有 critical anomaly | 即使用户不偏好该模块，也不被完全隐藏 |
| 偏好变化后查看当前洞察 | 卡片顺序改变，内容不变 |
| 偏好变化后查看历史洞察 | 卡片顺序不变 |
| schemaVersion 1 的旧 JSON | 新版 App 正常加载，缺失字段用默认值 |

### Manual QA

- 生成周洞察后，对一张卡点"不准 -> 重点不准"，确认保存成功。
- 连续制造同类反馈，确认画像从弱信号升级为稳定偏好。
- 仅制造 1 次反馈，等 30 天，确认弱信号过期。
- 删除/损坏画像文件，确认 App 不崩溃且回退默认画像。
- 修改健康权限，确认洞察不编造健康数据。
- 点击行动候选，确认执行前有二次确认。
- 后台生成洞察后打开 App，确认反馈 UI 正常工作。

## Rollout Plan

| 阶段 | 用户可见变化 | 是否需要后端发版 | 风险 |
|------|--------------|------------------|------|
| Phase 0 | 无直接变化，修复基础设施 | 否 | 低 |
| Phase 1 | 卡片可反馈 | 否 | 低 |
| Phase 2 | 系统开始学习偏好，暂不影响展示 | 否 | 低 |
| Phase 3 | 洞察排序更贴近用户；卡片展示可展开 | 否（若同时注入 Prompt 摘要则需要） | 中 |
| Phase 4 | 记忆长廊顶部出现每日状态 | 否 | 中 |
| Phase 5 | 健康参与 Daily Sense | 否（仅 Daily Sense 规则）；进入周期 AI Prompt 时需要 | 中高 |
| Phase 6 | 洞察可转行动 | 否 | 中 |

所有新能力默认隐藏在 Feature Flag 后。Debug / TestFlight 默认开启，Release 可通过 UserDefaults 关闭。

用户可见的偏好管理：

- 设置中增加"重置洞察学习"入口，清除 `InsightPreferenceProfile` 并重置为默认值。
- 原始反馈记录保留（可从反馈重建画像）。

## Decisions（已决议）

1. `InsightPreferenceProfile` 第一版用 JSON 文件（独立 Service），降低迁移成本。
2. `MemoryInsightFeedback` 用 Core Data，只存 UUID 弱关联，不建 relationship。
3. `MemoryInsight.userRating` / `feedbackNote` 保留兼容，新 UI 只写入 `MemoryInsightFeedback`。
4. `MemoryInsightCard` 增加可选 `moduleHint` / `patternType`，post-process 填充，不改 Prompt schema。
5. `snapshotHash` 必须排除 `generatedAt`；偏好摘要不参与 snapshotHash。
6. 偏好变化不标记旧洞察 stale；当前洞察立即 rerank（顺序变），不重新生成（内容不变）。
7. Daily Sense 第一版只做 `stable` / `atRisk` / `recovering`，规则生成，放记忆长廊。
8. `DailySenseSnapshot` 持久化最近 7 天 JSON 数组。
9. 行动候选第一版用规则生成（3-5 个硬编码模板），不让 AI 输出 payload。
10. 健康第一版先进入 Daily Sense，稳定后再进入周期 AI Prompt。
11. 健康卡片复用 `.overview` type + `moduleHint = "health"`，不新增 card type。
12. Prompt 摘要严格 < 500 字，结构化 JSON 传入。
13. Phase 0 必须先落地 Feature Flag。
14. `HealthDataAvailability` 和 `InsightActionPayload` 需手写 `Codable`（带标签关联值无法自动合成）。
15. `InsightActionPayload.none` 重命名为 `.noAction`（避免与 `Optional.none` 歧义）。
16. 聚合器触发：洞察生成前批量 + App 启动轻量。
17. 弱信号 30 天过期；稳定偏好永久有效直到反向反馈。
18. `InsightPreferenceProfile` 加 `schemaVersion`，所有字段 `decodeIfPresent` + 默认值。
19. 原子写入（`.atomic`）用于 `InsightPreferenceProfileService`。
20. 数据清空或 90 天无活动时，提示用户重置偏好画像。
21. `prefix(5)` 扩展为可展开（Phase 3 同步），给 rerank 更多操作空间。
22. "不准"原因分类第一版不加"太泛泛"/"样本不足"，后续按需扩展。
23. `dataWrong` 第一版只记录本地 debug 日志，不做独立 debug 面板。
24. 设置中增加用户可见的"重置洞察学习"入口。
25. Rerank 每次展示动态计算，不持久化排序结果。

## Success Metrics

| 指标 | 目标 |
|------|------|
| 反馈完成率 | 用户能在 2 次点击内完成基础反馈 |
| 不准反馈可分类率 | 90% 以上"不准"反馈带 reasonType |
| 偏好稳定性 | 单条反馈不会改变长期画像 |
| Prompt 摘要长度 | 始终低于 500 字 |
| 洞察重排可解释性 | 每次 rerank 可输出调试原因 |
| 数据安全 | 用户反馈原文不进入 Prompt |
| 健康安全 | 无健康权限时不出现健康结论 |
| 画像鲁棒性 | 损坏 JSON 不崩溃，schema 升级不丢数据 |

## Final Summary

本方案的核心不是"让 Prompt 变聪明"，而是把 Holo 洞察系统拆成稳定可控的闭环：

```text
结构化反馈（两维：准确性 + 价值感）
  -> 弱信号 → 稳定偏好（30 天窗口 + 2 次阈值）
  -> 本地 rerank/filter（展示排序，不改内容）
  -> 少量 Prompt 摘要（< 500 字，系统整理，非用户原文）
  -> 每日状态（3 状态规则引擎，7 天持久化）
  -> 可确认行动（规则生成，用户二次确认）
```

这样 Holo 会逐步变得更准，但不会因为用户反馈原文越堆越多而 Prompt 崩溃，也不会因为一次"不准"就永久漂移。

---

## Appendix: 对抗性审查记录

本方案经过两轮对抗性审查（Claude 执行），审查结论已全部吸收到上方方案正文和 Decisions 中。以下为审查历史摘要：

### 第一轮审查（2026-05-23 02:29）

发现 5 处事实冲突（反馈字段已存在、module 字段冗余、Profile 是 Markdown 非 JSON、snapshotHash 含 generatedAt、prefix(5) 截断）、6 处架构风险（聚合阈值保守、规则引擎组合爆炸、偏好信任边界、行动生成未决、健康权限降级缺失、Feature Flag 缺失）、5 处边界遗漏（反馈语义交叉、旧洞察 rerank、生成失败无反馈、后台场景、dataWrong 排查路径）。

核心修改建议 6 项全部吸收：Phase 0 前置、Feature Flag、聚合阈值降低、Daily Sense 三状态、旧字段关系明确、后端发版标注。

### 第二轮审查（2026-05-23 13:50）

发现 2 处 Swift 技术问题（Codable 自动合成限制、`.none` 歧义）、6 处吸收修改引入的新问题（moduleHint 填充方式、两套类型系统映射、prefix(5) 未处理、聚合器触发时机、JSON schema 版本迁移、30 天窗口与中断使用冲突）、5 处深层设计风险（Daily 持久化、偏好变化与旧洞察、行动模板细节、原子写入、数据清空处理）。

核心修改建议 7 项全部吸收：手写 Codable、聚合触发时机、schemaVersion、弱信号/稳定偏好区分、prefix 扩展、post-process 填充、Daily 持久化策略。
