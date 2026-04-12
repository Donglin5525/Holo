# HOLO AI 对话能力扩展方案

> 日期：2026-04-11（修订：2026-04-12）
> 范围：首页 AI 对话支持记账、任务管理、习惯打卡、一句话记笔记

## Context

目前首页 AI 已支持：记账、收入、创建任务（仅标题）、记录心情、记录体重、习惯打卡。
用户希望通过自然对话完成**记账、创建/完成/删除任务、习惯打卡、一句话记笔记**等全部操作。

**设计原则：不支持普通闲聊，每次沟通都需要有明确的指令或任务。**

当前架构的核心瓶颈：
1. `AIIntent` 只有 9 种，缺少完成任务、记笔记、查询等意图
2. `RouteResult` 已有 `transactionId`/`taskId`/`habitId`/`thoughtId` 四个独立字段，无法统一管理实体链接
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

**迁移策略：** 保留旧字段 + 新增 `linkedEntity`，所有 handler 同时设置两者。旧字段标记 `@available(*, deprecated)`，下个版本清理。

```swift
struct RouteResult {
    let text: String
    let transactionId: UUID?       // 保留，向后兼容
    let taskId: UUID?              // 保留，向后兼容（下版本清理）
    let habitId: UUID?             // 保留，向后兼容（下版本清理）
    let thoughtId: UUID?           // 保留，向后兼容（下版本清理）
    let linkedEntity: LinkedEntity? // 新增，通用实体链接
}
```

**双写规则：**
- 财务操作：设置 `transactionId` + `linkedEntity(type: .transaction)`
- 任务操作：设置 `taskId` + `linkedEntity(type: .task)`
- 习惯操作：设置 `habitId` + `linkedEntity(type: .habit)`
- 笔记操作：设置 `thoughtId` + `linkedEntity(type: .thought)`

### 1.4 ChatMessage 扩展 — `ChatMessage+CoreDataProperties.swift`

新增 `linkedEntity` 计算属性，**同时处理新旧两种格式**：

```swift
var linkedEntity: LinkedEntity? {
    guard let dict = extractedDataDictionary else { return nil }
    // 新格式优先：entityType + entityId
    if let typeStr = dict["entityType"], let idStr = dict["entityId"],
       let type = LinkedEntityType(rawValue: typeStr), let id = UUID(uuidString: idStr) {
        return LinkedEntity(type: type, id: id)
    }
    // 旧格式兜底：按字段名推断类型
    if let idStr = dict["transactionId"], let id = UUID(uuidString: idStr) {
        return LinkedEntity(type: .transaction, id: id)
    }
    if let idStr = dict["taskId"], let id = UUID(uuidString: idStr) {
        return LinkedEntity(type: .task, id: id)
    }
    if let idStr = dict["habitId"], let id = UUID(uuidString: idStr) {
        return LinkedEntity(type: .habit, id: id)
    }
    if let idStr = dict["thoughtId"], let id = UUID(uuidString: idStr) {
        return LinkedEntity(type: .thought, id: id)
    }
    return nil
}
```

保留原有 `linkedTransactionId` 和 `linkedTaskId` 不变，继续工作。

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
- 新增 `habitValue` 支持数值型习惯（可选，Double 类型，如"跑了 5 公里"→ habitValue: 5.0，配合 `habitName` 字段指定习惯名称）
- 新增 `noteContent` 字段用于 createNote 意图（必填，字符串，笔记正文内容）
- 新增 `tags` 字段用于 createNote 意图（可选，逗号分隔字符串，如"工作,灵感"）
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

**任务匹配算法（`searchTasks(keyword:)`）：**
```
匹配优先级（从高到低）：
1. 标题完全匹配（忽略大小写）→ 精确命中
2. 标题包含关键词（忽略大小写）→ 包含命中
3. 备注/描述包含关键词 → 模糊命中

排序规则：
- 按匹配优先级排序（精确 > 包含 > 模糊）
- 同优先级内按创建时间倒序（最近的优先）

仅返回未完成（未软删除）的任务。仅搜索前 100 条活跃任务。
```

### 2.6 UserContextBuilder 增强 — `UserContextBuilder.swift`

新增注入到 AI 上下文的信息：
- 活跃习惯名称列表（`HabitSummary.activeHabitNames`，帮助 AI 准确匹配习惯名）
- 前 10 条未完成任务摘要（`TaskSummary.activeTaskSummaries`，帮助 AI 理解任务上下文用于完成/更新/删除）

### 2.7 能量值与限流系统

> **本节内容移至 Phase 5 独立实现。** Phase 1-4 的路由逻辑不包含能量检查，ChatViewModel 中预留能量检查的调用位置（注释标记 `// ENERGY:`），Phase 5 实现后取消注释即可接入。

---

## Phase 3: ViewModel 集成

### 3.1 路由逻辑重构 — `ChatViewModel.swift`

**旧逻辑（两路分支）：**
```swift
if parsedResult.isHighConfidence && parsedResult.intent != .chat && parsedResult.intent != .query {
    // 本地操作
} else {
    // 流式聊天（包含 chat / query / 低置信度）
}
```

**新逻辑（移除 chat 分支，unknown 替代闲聊）：**
```swift
func sendMessage() async {
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    // ENERGY: 锁定检查预留位

    inputText = ""
    // ... 保存用户消息、创建 AI 占位消息 ...

    // 1. 意图识别
    let parsedResult = try await provider.parseUserInput(text, context: userContext)

    // ENERGY: 能量检查预留位

    // 2. 路由
    if parsedResult.isHighConfidence {
        switch parsedResult.intent {
        case .query:
            // 分析型查询 → 流式对话（唯一的流式场景）
            await handleStreamingQuery(parsedResult)
        case .unknown:
            // 兜底追问
            finishWithClarification(aiMessage, question: parsedResult.clarificationQuestion)
        default:
            // 具体操作 → 本地路由
            let routeResult = try await IntentRouter.shared.route(parsedResult)
            finishWithResult(aiMessage, routeResult, parsedResult)
            // ENERGY: 能量恢复预留位
        }
    } else {
        // 低置信度 → unknown 处理
        finishWithClarification(aiMessage, question: parsedResult.clarificationQuestion)
    }
}
```

**追问兜底文本：**
"我没太理解，你可以试试：记一笔消费、创建任务、完成某个任务、打卡、记笔记"

### 3.2 实体合并逻辑更新 — `ChatViewModel.swift`

**双写新旧格式**，确保旧消息解析不受影响：

```swift
// 新格式（优先）
if let entity = routeResult.linkedEntity {
    mergedData["entityType"] = entity.type.rawValue
    mergedData["entityId"] = entity.id.uuidString
}
// 旧格式（向后兼容，双写）
if let txId = routeResult.transactionId {
    mergedData["transactionId"] = txId.uuidString
}
if let taskId = routeResult.taskId {
    mergedData["taskId"] = taskId.uuidString
}
if let habitId = routeResult.habitId {
    mergedData["habitId"] = habitId.uuidString
}
if let thoughtId = routeResult.thoughtId {
    mergedData["thoughtId"] = thoughtId.uuidString
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

新增通用实体跳转逻辑（新格式优先 + 旧格式兜底）：
```swift
@State private var navigatingTaskId: UUID?
@State private var showTaskDetail = false
@State private var navigatingHabitId: UUID?
@State private var showHabitDetail = false

func openEntityDetail(_ message: ChatMessage) {
    // 优先使用 linkedEntity（新格式）
    if let entity = message.linkedEntity {
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
        return
    }
    // 旧格式兜底
    if let txId = message.linkedTransactionId {
        editingTransaction = FinanceRepository.shared.findTransaction(by: txId)
    } else if let taskId = message.linkedTaskId {
        navigatingTaskId = taskId
        showTaskDetail = true
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

结构化确认卡片，替代纯文本确认。**采用快照模式：数据直接从 `extractedDataJSON` 解析，不实时查询 Repository**，避免滚动时触发大量查询。点击"编辑"按钮时才实时查询（确保数据最新）。

**数据流：** 从 `ChatMessage.extractedDataJSON` 解析关键字段渲染卡片快照，编辑操作通过 `linkedEntity` 跳转到对应 Repository 查询最新数据。

**卡片类型：**
- **交易卡片**：金额 + 分类 + 备注 + 编辑按钮
- **任务卡片**：标题 + 优先级徽章 + 截止日期 + 编辑按钮
- **笔记卡片**：内容预览 + 标签
- **习惯卡片**：习惯名 + 打卡状态

集成到 MessageBubbleView 中，在文本气泡和意图标签之间显示。点击编辑按钮触发 `onIntentTagTap` → 走实体导航跳转。

---

## Phase 5: 能量值与限流系统（独立迭代）

> **前置条件：** Phase 1-4 全部完成并上线验证后，再实施本阶段。
> **接入方式：** Phase 3 的 ChatViewModel 路由逻辑中已预留 `// ENERGY:` 注释标记，实现后取消注释即可。

### 5.1 能量值模型

**目标：** 将 AI 对话与"消耗"挂钩，防止无意义提问浪费 Token，鼓励用户使用核心记录功能。

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
| query（分析型查询） | 3 点 | 需要 LLM 流式生成，中等消耗 |
| unknown（未识别） | 1 点 | 首次 unknown 不扣点（见冷却规则） |

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

| 连续 unknown 次数 | 消耗 | 处理 |
|------------------|------|------|
| 第 1 次 | 0 点 | 正常追问，不计入消耗 |
| 第 2 次 | 1 点 | 追问 + 提示"请输入明确指令" |
| 第 3 次 | 1 点 | 锁定 30 秒 + 显示可用操作列表供点选 |
| 第 4 次及以上 | 2 点 | 锁定 60 秒 |

- 正常意图成功执行后，重置 unknown 计数
- 锁定期间输入框禁用，显示倒计时 + 可用操作快捷按钮

### 5.2 技术实现

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

### 5.3 UI 集成

不在常规界面显示能量值。只在以下场景提示：
- 能量 < 10 时，输入框上方显示淡色提示"今日 AI 额度剩余 X 点"
- 能量 = 0 时，发送按钮禁用，提示"今日 AI 额度已用完，完成记账/打卡可恢复"
- 锁定期间，输入框禁用 + 倒计时 + 快捷操作按钮

---

## 关键文件清单

### Phase 1-4（核心意图扩展）

| 文件 | 修改类型 |
|------|---------|
| `Models/AI/AIModels.swift` | 移除 chat intent + 新增 6 cases + LinkedEntity 类型 + 更新 HabitSummary/TaskSummary |
| `Services/AI/IntentRouter.swift` | RouteResult 双写旧字段 + linkedEntity + 6 个新 handler + 增强 createTask + matchTask 共用逻辑 |
| `Services/AI/PromptManager.swift` | 重写 intentRecognition + systemPrompt（移除闲聊） |
| `Services/AI/UserContextBuilder.swift` | 注入习惯名称和任务摘要 |
| `Models/ChatMessage+CoreDataProperties.swift` | 新增 linkedEntity 属性（兼容新旧格式） |
| `Views/Chat/ChatViewModel.swift` | 路由两路重构 + 实体合并双写 + QuickAction 扩展 + `// ENERGY:` 预留位 |
| `Views/Chat/MessageBubbleView.swift` | 意图标签扩展 + 确认卡片集成 |
| `Views/Chat/ChatView.swift` | 通用实体导航（新格式优先 + 旧格式兜底）+ 新 sheet 修饰符 |
| `Views/Chat/ConfirmationCardView.swift` | **新文件**：快照模式确认卡片 |
| `Services/AI/MockAIProvider.swift` | 新意图支持 + default 改为 unknown |

### Phase 5（能量值系统，独立迭代）

| 文件 | 修改类型 |
|------|---------|
| `Services/AI/AIEnergyManager.swift` | **新文件**：能量值管理 + 冷却系统 |
| `Views/Chat/ChatViewModel.swift` | 取消 `// ENERGY:` 注释，接入能量检查 |
| `Views/Chat/ChatView.swift` | 锁定状态 UI + 能量提示 |

---

## 验证计划

### Phase 1-4 验证（核心意图扩展）

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
5. **旧消息兼容**：
   - 已有 linkedTransactionId 的消息仍正常渲染和跳转
   - 已有 linkedTaskId 的消息仍正常渲染和跳转
   - 新消息同时包含新格式（entityType+entityId）和旧格式（taskId/transactionId 等）
6. **确认卡片**：操作后显示结构化卡片，点击编辑跳转对应编辑页
7. **任务匹配算法**：
   - 标题精确匹配 > 标题包含 > 备注包含
   - 多结果按创建时间倒序

### Phase 5 验证（能量值系统）

1. **基础消耗**：
   - 记账 → 消耗 1 点 + 恢复 3 点 = 净赚 2 点
   - 连续记账不会耗尽能量
2. **边界情况**：
   - 能量耗尽时发送按钮禁用 + 提示
   - 跨日能量自动重置为 50
3. **冷却机制**：
   - 第 1 次 unknown → 不扣点，正常追问
   - 连续 3 次 unknown → 锁定 30 秒 + 显示操作列表
   - 正常操作后 unknown 计数重置
4. **query 消耗**：分析型查询消耗 3 点，不会过度压制使用
