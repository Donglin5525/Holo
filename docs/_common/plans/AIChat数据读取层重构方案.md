# HoloAI 聊天数据读取层重构

## Context

HoloAI 存在"双重数据路径"问题：
- **旧路径**: `extractedDataJSON` 存 LLM 原始解析数据（title, dueDate, amount 等）— **不含 entity ID**
- **新路径**: `executionBatch` 存 `AIExecutionItem`，含 `linkedEntityId` 和 `renderData`（LLM 数据 + entity ID）

多处代码只查旧路径，导致 entity ID 永远找不到。本次重构统一为"新路径优先、旧路径兜底"的单一解析层。

**额外发现**:
1. `findLinkedEntityId` 只匹配 `.recordExpense`，**收入卡片点击也会静默失败**
2. `handleIntentTagTap` 的交易分支用 `linkedTransactionId`（只查旧路径），也是死路径
3. `AIProvider.swift:44` 只检查 `.query`，遗漏 `.queryTasks`/`.queryHabits`，是现存 bug

---

## 实施步骤

### Step 1: AIIntent 类别辅助 (基础)
**文件**: `Models/AI/AIModels.swift`

在 `AIIntent` 枚举后添加扩展：
- `static let queryIntents: Set<AIIntent>` — `[.query, .queryTasks, .queryHabits]`
- `static let taskIntents: Set<AIIntent>` — `[.createTask, .completeTask, .updateTask]`
- `static let financeIntents: Set<AIIntent>` — `[.recordExpense, .recordIncome]`
- `var isQuery: Bool` / `var isTask: Bool` / `var isFinance: Bool`

替代项目中散落的 6+ 处硬编码字符串/枚举检查。

### Step 2: 统一实体解析 (核心)
**文件**: `Models/ChatMessageViewData.swift`

添加 `EntityCategory` 枚举（`.finance`, `.task`, `.habit`, `.thought`）
> 注：mood/weight 当前无导航需求，不在本次范围内。如需扩展，加 `.health` case。

添加两个公共方法（替代所有分散的 linkedXxx 属性）：
- `resolveLinkedEntityId(for category:) -> UUID?` — 先查 executionBatch，后查 extractedDataJSON
- `hasLinkedEntity(for category:) -> Bool`

**确认 `linkedEntity` 调用方**: grep 确认无调用方，**直接删除** `linkedEntity`（ChatMessageViewData）和 `ChatMessage.linkedEntity`（CoreDataProperties）

**保留但改为 private**: `linkedTransactionId`, `linkedTaskId`（仅供 resolveLinkedEntityId 兜底用）
**删除**: `hasTaskLinkedEntity`（已被 `hasLinkedEntity(for: .task)` 替代）

### Step 3: 修复 ChatView 导航
**文件**: `Views/Chat/ChatView.swift`

- `handleIntentTagTap` — 使用 `message.resolveLinkedEntityId(for:)`
- `handleCardTap` — 使用 `message.resolveLinkedEntityId(for:)`，**修复收入匹配**
- `openTransactionDetail` — 使用 `message.resolveLinkedEntityId(for: .finance)`
- **删除** `findLinkedEntityId(for:in:)` 和 `taskIdFromMessage(_:)` — 已被统一方法替代

### Step 4: 修复 MessageBubbleView
**文件**: `Views/Chat/MessageBubbleView.swift`

- `intentTag()` — 使用 `AIIntent` 枚举替代原始字符串比较，使用 `message.hasLinkedEntity(for:)`
- `intentIcon()` / `intentLabel()` — 参数改为 `AIIntent` 枚举，类型安全

### Step 5: 关键解码/编码添加日志
**文件**:
- `Models/ChatMessage+CoreDataProperties.swift` — 3 处 `try? JSONDecoder` → `do/catch + Logger`
- `Data/Repositories/ChatMessageRepository.swift` — 2 处解码添加日志
- `Views/Chat/ChatViewModel.swift` — 3 处编码添加日志

### Step 6: 清理死代码
**文件**: `Models/AI/ChatCardData.swift`

- 删除 `from(executionItem:)` 中计算后未使用的 `linkedId` 变量

### Step 7: 原子化消息最终写入
**文件**: `Data/Repositories/ChatMessageRepository.swift` + `Views/Chat/ChatViewModel.swift`

- ChatMessageRepository 新增 `finalizeMessage()` 方法 — 单次 Core Data save + 单次 snapshot 更新
- ChatViewModel 正常路径调用 `finalizeMessage()`，错误/取消路径保留 `finishStreaming()`

### Step 8: 统一 query intent 判断（4 个文件）
**文件**:
- `Services/AI/ConversationCoordinator.swift` — 3 处 → `$0.intent.isQuery`
- `Services/AI/OpenAICompatibleProvider.swift:251` — 1 处 → `single.intent.isQuery`
- `Services/AI/MockAIProvider.swift:282-283,300-304` — 3 处 → `.isQuery`
- `Services/AI/AIProvider.swift:44` — **现存 bug**：只检查 `.query`，遗漏 `.queryTasks`/`.queryHabits`，改为 `.isQuery`

---

## 文件变更总览

| 文件 | 变更量 | 关键变更 |
|------|--------|----------|
| `Models/AI/AIModels.swift` | +25 行 | AIIntent 类别扩展 |
| `Models/ChatMessageViewData.swift` | +40/-30 行 | 统一实体解析 |
| `Views/Chat/ChatView.swift` | +15/-40 行 | 用统一方法，删旧辅助函数 |
| `Views/Chat/MessageBubbleView.swift` | +25/-30 行 | 用枚举 + 统一检查 |
| `Models/ChatMessage+CoreDataProperties.swift` | +15 行 | 解码日志 |
| `Data/Repositories/ChatMessageRepository.swift` | +30/-5 行 | 解码日志 + finalizeMessage |
| `Views/Chat/ChatViewModel.swift` | +20/-10 行 | 编码日志 + 用 finalizeMessage |
| `Models/AI/ChatCardData.swift` | -1 行 | 删死代码 |
| `Services/AI/ConversationCoordinator.swift` | -5/+2 行 | 用 .isQuery |
| `Services/AI/OpenAICompatibleProvider.swift` | -1/+1 行 | 用 .isQuery |
| `Services/AI/MockAIProvider.swift` | -5/+2 行 | 用 .isQuery |
| `Services/AI/AIProvider.swift` | -3/+1 行 | 用 .isQuery（修复遗漏 bug） |

**净效果**: 删约 110 行，加约 95 行。代码更少但更健壮。

---

## 验证

每步完成后确保编译通过。全部完成后手动测试：

1. "记一笔消费 50 元午餐" → 支出卡片渲染，点击跳转交易详情
2. "收到工资 5000" → **收入卡片渲染，点击跳转交易详情**（之前静默失败）
3. "帮我创建一个任务买菜" → 任务卡片渲染，点击跳转任务详情
4. "今天有什么待办" → 查询意图标签显示，无导航箭头
5. Xcode 控制台无 "解析...失败" 日志（正常路径）
