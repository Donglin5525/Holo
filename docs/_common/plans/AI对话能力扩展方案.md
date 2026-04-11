# HOLO AI 对话能力扩展方案

> 日期：2026-04-11
> 范围：首页 AI 对话支持记账、任务管理、习惯打卡、一句话记笔记

## Context

目前首页 AI 已支持：记账、收入、创建任务（仅标题）、记录心情、记录体重、习惯打卡。
用户希望通过自然对话完成**记账、创建/完成/删除任务、习惯打卡、一句话记笔记**等全部操作。

**设计原则：不支持普通闲聊，每次沟通都需要有明确的指令或任务。**

当前架构的核心瓶颈：
1. `AIIntent` 只有 9 种，缺少完成任务、记笔记、查询等意图
2. `RouteResult` 只能关联 `transactionId`，无法链接任务/习惯/想法
3. 任务创建只提取 `title`，忽略优先级、截止日期、标签
4. 意图标签只有财务类可点击，非财务操作无法跳转详情
5. 没有富卡片 UI，操作确认只是纯文本
6. 低置信度时降级为流式聊天，与"不支持闲聊"的设计原则冲突

---

## Phase 1: 数据模型层（无 UI 破坏）

### 1.1 新增 AIIntent — `AIModels.swift`

新增 6 个意图，移除 `.chat`，保留 `.unknown` 作为未识别兜底：

```swift
enum AIIntent: String, Codable, CaseIterable {
    // 记账类
    case recordExpense = "record_expense"
    case recordIncome = "record_income"
    // 任务类
    case createTask = "create_task"
    case completeTask = "complete_task"    // 新增：完成任务
    case updateTask = "update_task"        // 新增：更新任务
    case deleteTask = "delete_task"        // 新增：删除任务
    // 习惯类
    case checkIn = "check_in"
    // 笔记类
    case createNote = "create_note"        // 新增：一句话记笔记
    // 健康类
    case recordMood = "record_mood"
    case recordWeight = "record_weight"
    // 查询类
    case queryTasks = "query_tasks"        // 新增：查询任务列表
    case queryHabits = "query_habits"      // 新增：查询习惯状态
    case query = "query"                   // 分析型查询（保留流式路径）
    // 兜底
    case unknown = "unknown"               // 未识别，返回追问
}
```

移除原有 `.chat` case，共 14 个意图。

### 1.2 新增通用实体链接类型 — `AIModels.swift`

```swift
enum LinkedEntityType: String, Codable {
    case transaction, task, habit, thought
}

struct LinkedEntity: Codable {
    let type: LinkedEntityType
    let id: UUID
}
```

### 1.3 更新 RouteResult — `IntentRouter.swift`

```swift
struct RouteResult {
    let text: String
    let transactionId: UUID?       // 保留，向后兼容
    let linkedEntity: LinkedEntity? // 新增，通用实体链接
}
```

财务操作同时设置 `transactionId` 和 `linkedEntity`，其他操作只设置 `linkedEntity`。

### 1.4 ChatMessage 扩展 — `ChatMessage+CoreDataProperties.swift`

新增 `linkedEntity` 计算属性（从 extractedDataJSON 解析 entityType + entityId），保留原有 `linkedTransactionId` 向后兼容。

### 1.5 更新摘要 Struct — `AIModels.swift`

`HabitSummary` 新增 `activeHabitNames: [String]`（活跃习惯名称列表）。
`TaskSummary` 新增 `activeTaskSummaries: [String]`（前 10 条未完成任务摘要，格式："○ 任务标题"）。

---

## Phase 2: 提示词与路由层

### 2.1 重新设计 intentRecognition 提示词 — `PromptManager.swift`

关键变更：
- 意图从 9 个调整为 14 个，按类别分组（记账类/任务类/习惯类/笔记类/健康类/查询类）
- 移除 `chat` 意图，强调"只识别操作指令，不进行闲聊"
- 新增 `taskKeyword` 字段用于匹配已有任务（completeTask/updateTask/deleteTask 必填）
- 新增 `priority`（0-3）、`dueDate`、`tags`、`description` 字段（createTask 可选）
- 新增 `habitValue` 支持数值型习惯
- 新增日期解析规则（今天/明天/后天/下周一/本月X日 → yyyy-MM-dd）
- 新增意图判断规则（明确的触发词映射）
- 未匹配任何意图时返回 `unknown` + `clarificationQuestion`
- 科目体系保持不变

### 2.2 更新 systemPrompt — `PromptManager.swift`

核心变更：
- 移除"日常闲聊"能力
- 明确角色定位："你是 Holo AI 助手，专注于帮用户管理个人数据。用户每次对话都应包含明确指令。"
- 核心能力列表：记账/收入、创建/完成/更新/删除任务、习惯打卡、记笔记、查询任务/习惯状态、数据分析
- "禁止假装执行操作"规则保留（仅影响 query 流式路径）
- 新增规则："当用户输入不含明确指令时，简短提示可用的操作类型"

### 2.3 新增 IntentRouter 处理方法 — `IntentRouter.swift`

| 方法 | 数据提取 | Repository 调用 | 返回 |
|------|---------|----------------|------|
| `handleCompleteTask` | taskKeyword → `searchTasks(keyword:)` 匹配 | `todoRepo.completeTask()` | 任务 ID |
| `handleUpdateTask` | taskKeyword + 新 title/priority/dueDate | `todoRepo.updateTask()` | 任务 ID |
| `handleDeleteTask` | taskKeyword → `searchTasks(keyword:)` 匹配 | `todoRepo.deleteTask()`（软删除） | 确认文本 |
| `handleCreateNote` | content + 可选 tags | `thoughtRepo.create()` | 想法 ID |
| `handleQueryTasks` | taskKeyword + dueDate 过滤 | `todoRepo.activeTasks` | 任务列表文本 |
| `handleQueryHabits` | 无参数 | `habitRepo.activeHabits` | 习惯状态文本 |

**任务匹配错误处理（handleCompleteTask/handleUpdateTask/handleDeleteTask 共用逻辑）：**
```
1. searchTasks(keyword:) → 0 结果 → 返回 "未找到匹配的任务，请说得更具体一些"
2. searchTasks(keyword:) → 多个结果 → 返回候选列表 "找到多个任务：1) xxx 2) yyy，请确认是哪个"
3. searchTasks(keyword:) → 恰好 1 个 → 直接执行操作
```

### 2.4 增强 handleCreateTask — `IntentRouter.swift`

当前只提取 `title`，增强为：
- `priority`：从 extractedData 解析（0-3），默认 medium
- `dueDate`：yyyy-MM-dd 格式解析
- `tags`：逗号分隔，匹配已有 TodoTag
- `description`：任务描述

### 2.5 新增辅助方法 — `IntentRouter.swift`

- `parseDate(from:)` — 日期解析
- `formatDate(_:)` — 日期显示（M月d日）
- `matchTags(from:)` — 标签名匹配 TodoTag
- `parseCSVTags(_:)` — 标签字符串解析
- `matchTask(keyword:)` — 任务关键字匹配（共用逻辑，处理 0/1/N 结果）

### 2.6 UserContextBuilder 增强 — `UserContextBuilder.swift`

新增注入到 AI 上下文的信息：
- 活跃习惯名称列表（`HabitSummary.activeHabitNames`，帮助 AI 准确匹配习惯名）
- 前 10 条未完成任务摘要（`TaskSummary.activeTaskSummaries`，帮助 AI 理解任务上下文用于完成/更新/删除）

### 2.7 能量值与限流系统 — 新文件 `Services/AI/AIEnergyManager.swift`

**目标：** 将 AI 对话与"消耗"挂钩，防止无意义提问浪费 Token，鼓励用户使用核心记录功能。

#### 能量值模型

```
每日基础能量：50 点（每日 0 点重置）
能量上限：50 点（不可超过）
```

**消耗规则（每次 AI 意图识别调用）：**

| 操作类型 | 消耗 | 说明 |
|---------|------|------|
| 记账/收入/记录心情/记录体重 | 1 点 | 核心记录操作，低消耗 |
| 创建/完成/更新/删除任务 | 1 点 | 任务操作，低消耗 |
| 习惯打卡 | 1 点 | 打卡操作，低消耗 |
| 记笔记 | 1 点 | 笔记操作，低消耗 |
| 查询任务/查询习惯 | 2 点 | 查询操作，中等消耗 |
| query（分析型查询） | 5 点 | 需要 LLM 流式生成，高消耗 |
| unknown（未识别） | 2 点 | 惩罚无意义提问 |

**恢复规则（执行成功后自动回复）：**

| 触发行为 | 恢复 | 说明 |
|---------|------|------|
| 成功记账 | +3 点 | 鼓励核心记账行为 |
| 成功打卡 | +2 点 | 鼓励习惯坚持 |
| 成功完成任务 | +2 点 | 鼓励任务推进 |
| 成功记笔记/心情 | +1 点 | 鼓励记录 |
| 创建任务 | +1 点 | 鼓励规划 |

> 净效果：记账操作消耗 1 点 + 恢复 3 点 = 净赚 2 点。正常使用不会耗尽能量。

**冷却规则（连续 unknown）：**

| 连续 unknown 次数 | 处理 |
|------------------|------|
| 第 1 次 | 正常追问 |
| 第 2 次 | 追问 + 提示"请输入明确指令" |
| 第 3 次 | 锁定 30 秒 + 显示可用操作列表供点选 |
| 第 4 次及以上 | 锁定 60 秒 |

- 正常意图成功执行后，重置 unknown 计数
- 锁定期间输入框禁用，显示倒计时 + 可用操作快捷按钮

#### 技术实现

```swift
@MainActor
final class AIEnergyManager: ObservableObject {
    static let shared = AIEnergyManager()

    @Published private(set) var currentEnergy: Int
    @Published private(set) var isLocked: Bool = false

    private let maxEnergy = 50
    private var consecutiveUnknowns = 0
    private var lockedUntil: Date?

    // 检查能量是否充足
    func canPerform(intent: AIIntent) -> (canPerform: Bool, cost: Int)

    // 消耗能量（意图识别后调用）
    func consume(intent: AIIntent)

    // 恢复能量（操作成功后调用）
    func reward(for intent: AIIntent)

    // 记录 unknown 并检查冷却
    func recordUnknown() -> (shouldLock: Bool, lockDuration: TimeInterval)

    // 重置 unknown 计数（正常意图成功后）
    func resetUnknownStreak()
}
```

**存储：** UserDefaults，key `com.holo.ai.energy`（JSON: `{energy: Int, lastResetDate: String, unknownStreak: Int}`）
**重置时机：** 每次 `canPerform` 时检查 `lastResetDate`，跨日自动重置为 50。
**UI 集成：** 不在常规界面显示能量值。只在以下场景提示：
- 能量 < 10 时，输入框上方显示淡色提示"今日 AI 额度剩余 X 点"
- 能量 = 0 时，发送按钮禁用，提示"今日 AI 额度已用完，完成记账/打卡可恢复"
- 锁定期间，输入框禁用 + 倒计时 + 快捷操作按钮

---

## Phase 3: ViewModel 集成

### 3.1 路由逻辑重构 — `ChatViewModel.swift`

**旧逻辑（三路分支）：**
```swift
if parsedResult.isHighConfidence && parsedResult.intent != .chat && parsedResult.intent != .query {
    // 本地操作
} else {
    // 流式聊天
}
```

**新逻辑（带能量检查的两路分支）：**
```swift
func sendMessage() async {
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    // 0. 检查锁定状态（连续 unknown 冷却）
    if AIEnergyManager.shared.isLocked {
        errorMessage = "请稍后再试"
        return
    }

    inputText = ""
    // ... 保存用户消息、创建 AI 占位消息 ...

    // 1. 意图识别
    let parsedResult = try await provider.parseUserInput(text, context: userContext)

    // 2. 能量检查
    let (canPerform, cost) = AIEnergyManager.shared.canPerform(intent: parsedResult.intent)
    if !canPerform {
        finishWithText(aiMessage, "今日 AI 额度已用完，完成记账、打卡等操作可恢复额度")
        return
    }

    // 3. 路由
    if parsedResult.isHighConfidence {
        switch parsedResult.intent {
        case .query:
            // 分析型查询 → 流式对话（唯一的流式场景）
            AIEnergyManager.shared.consume(intent: .query)
            await handleStreamingQuery(parsedResult)
        case .unknown:
            // 兜底追问
            AIEnergyManager.shared.consume(intent: .unknown)
            let lockInfo = AIEnergyManager.shared.recordUnknown()
            finishWithClarification(aiMessage, lockInfo: lockInfo)
        default:
            // 具体操作 → 本地路由
            AIEnergyManager.shared.consume(intent: parsedResult.intent)
            let routeResult = try await IntentRouter.shared.route(parsedResult)
            AIEnergyManager.shared.reward(for: parsedResult.intent) // 成功后回复能量
            AIEnergyManager.shared.resetUnknownStreak()              // 重置 unknown 计数
            finishWithResult(aiMessage, routeResult, parsedResult)
        }
    } else {
        // 低置信度 → unknown 处理
        AIEnergyManager.shared.consume(intent: .unknown)
        let lockInfo = AIEnergyManager.shared.recordUnknown()
        finishWithClarification(aiMessage, question: parsedResult.clarificationQuestion, lockInfo: lockInfo)
    }
}
```

**追问兜底文本：**
"我没太理解，你可以试试：记一笔消费、创建任务、完成某个任务、打卡、记笔记"

### 3.2 实体合并逻辑更新 — `ChatViewModel.swift`

```swift
// 旧逻辑
if let txId = routeResult.transactionId {
    mergedData["transactionId"] = txId.uuidString
}

// 新逻辑
if let entity = routeResult.linkedEntity {
    mergedData["entityType"] = entity.type.rawValue
    mergedData["entityId"] = entity.id.uuidString
    if entity.type == .transaction {
        mergedData["transactionId"] = entity.id.uuidString  // 向后兼容
    }
}
// 同时保留 transactionId 直接设置（兼容旧代码路径）
if let txId = routeResult.transactionId {
    mergedData["transactionId"] = txId.uuidString
}
```

### 3.3 MockAIProvider 更新 — `MockAIProvider.swift`

- 为新意图添加关键词匹配：
  - "完成"/"做完了" → `.completeTask`
  - "删除任务"/"不要了" → `.deleteTask`
  - "改成"/"修改" → `.updateTask`
  - "记一下"/"笔记" → `.createNote`
  - "有什么任务"/"待办" → `.queryTasks`
  - "习惯状态"/"打卡了吗" → `.queryHabits`
- default 分支改为返回 `.unknown` + `clarificationQuestion`（不再返回 `.chat`）

---

## Phase 4: UI 更新

### 4.1 MessageBubbleView 意图标签扩展

**新增图标（已验证 SF Symbol 存在性）：**
| 意图 | 图标 | 标签 |
|------|------|------|
| complete_task | checkmark.circle | 已完成任务 |
| update_task | pencil.circle | 已更新任务 |
| delete_task | trash.circle | 已删除任务 |
| create_note | note.text | 已记录笔记 |
| query_tasks | list.bullet.circle | 任务查询 |
| query_habits | chart.circle | 习惯查询 |
| unknown | questionmark.circle | 未识别指令 |

**可点击性扩展：** 所有带 linkedEntity 的意图标签都可点击（不仅是财务类）。

### 4.2 ChatView 实体导航 — `ChatView.swift`

新增通用实体跳转逻辑：
```swift
@State private var navigatingTaskId: UUID?
@State private var showTaskDetail = false
@State private var navigatingHabitId: UUID?
@State private var showHabitDetail = false

func openEntityDetail(_ message: ChatMessage) {
    guard let entity = message.linkedEntity else {
        // 向后兼容：旧消息只有 linkedTransactionId
        if let txId = message.linkedTransactionId {
            editingTransaction = FinanceRepository.shared.findTransaction(by: txId)
        }
        return
    }
    switch entity.type {
    case .transaction:
        editingTransaction = FinanceRepository.shared.findTransaction(by: entity.id)
    case .task:
        navigatingTaskId = entity.id
        showTaskDetail = true
    case .habit:
        navigatingHabitId = entity.id
        showHabitDetail = true
    case .thought:
        break  // 笔记暂不需要详情跳转
    }
}
```

新增对应 sheet 修饰符，引用现有的任务详情和习惯详情 View。

### 4.3 QuickActionBar 扩展 — `ChatViewModel.swift`

新增 3 个快捷操作（共 8 个）：
- "记笔记" → "帮我记一条笔记"
- "今日任务" → "今天有什么待办"
- "习惯状态" → "今天习惯完成了吗"

**注意：** `QuickAction` 枚举使用 `CaseIterable`，新增 case 会自动出现在 `QuickActionBar`。横向滚动设计已支持 8+ 按钮。

### 4.4 ConfirmationCardView（新文件）— `Views/Chat/ConfirmationCardView.swift`

结构化确认卡片，替代纯文本确认。

**数据流：** 从 `ChatMessage.extractedDataJSON` 解析 `entityType` + `entityId`，从对应 Repository 实时查询最新数据渲染卡片。

**卡片类型：**
- **交易卡片**：金额 + 分类 + 备注 + 编辑按钮
- **任务卡片**：标题 + 优先级徽章 + 截止日期 + 编辑按钮
- **笔记卡片**：内容预览 + 标签
- **习惯卡片**：习惯名 + 打卡状态

集成到 MessageBubbleView 中，在文本气泡和意图标签之间显示。点击编辑按钮触发 `onIntentTagTap` → 走实体导航跳转。

---

## 关键文件清单

| 文件 | 修改类型 |
|------|---------|
| `Models/AI/AIModels.swift` | 移除 chat intent + 新增 6 cases + LinkedEntity 类型 + 更新 HabitSummary/TaskSummary |
| `Services/AI/IntentRouter.swift` | RouteResult 保留双字段 + 6 个新 handler + 增强 createTask + matchTask 共用逻辑 |
| `Services/AI/PromptManager.swift` | 重写 intentRecognition + systemPrompt（移除闲聊） |
| `Services/AI/UserContextBuilder.swift` | 注入习惯名称和任务摘要 |
| `Services/AI/AIEnergyManager.swift` | **新文件**：能量值管理 + 冷却系统 |
| `Models/ChatMessage+CoreDataProperties.swift` | 新增 linkedEntity 属性 |
| `Views/Chat/ChatViewModel.swift` | 路由两路重构 + 能量检查集成 + 实体合并 + QuickAction 扩展 |
| `Views/Chat/MessageBubbleView.swift` | 意图标签 + 确认卡片集成 |
| `Views/Chat/ChatView.swift` | 通用实体导航 + 新 sheet 修饰符 + 锁定状态 UI |
| `Views/Chat/ConfirmationCardView.swift` | **新文件** |
| `Services/AI/MockAIProvider.swift` | 新意图支持 + default 改为 unknown |

---

## 验证计划

1. **回归测试**：记账（金额+分类）、收入、创建任务（标题）、心情、体重、打卡 — 全部不走样
2. **新意图测试**：
   - "明天下午开会，优先级高" → createTask(title, priority, dueDate)
   - "完成了买牛奶" → completeTask(taskKeyword) → 匹配到唯一任务 → 完成
   - "完成了那个报告" → completeTask(taskKeyword) → 匹配到 0 个 → 返回未找到提示
   - "完成了开会" → completeTask(taskKeyword) → 匹配到 3 个 → 返回候选列表
   - "把开会改成团队会议" → updateTask(taskKeyword, title)
   - "删除买牛奶的任务" → deleteTask(taskKeyword)
   - "记一下，下周三要交报告" → createNote(content)
   - "今天有什么任务" → queryTasks → 返回 Markdown 列表
   - "习惯完成了吗" → queryHabits → 返回状态列表
3. **非指令处理**：
   - "你好" → unknown → 返回追问提示
   - "今天天气怎么样" → unknown → 返回追问提示
   - "帮我分析一下本月开销" → query → 流式对话（唯一的流式场景）
4. **实体导航**：所有意图标签可点击，跳转到正确的详情页
5. **旧消息兼容**：已有的 linkedTransactionId 消息仍正常渲染和跳转
6. **确认卡片**：操作后显示结构化卡片，点击编辑跳转对应编辑页
7. **能量值系统**：
   - 记账 → 消耗 1 点 + 恢复 3 点 = 净赚 2 点
   - 连续记账不会耗尽能量
   - 能量耗尽时发送按钮禁用 + 提示
   - 连续 3 次 unknown → 锁定 30 秒 + 显示操作列表
   - 正常操作后 unknown 计数重置
   - 跨日能量自动重置为 50
