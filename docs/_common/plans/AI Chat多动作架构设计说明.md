# AI Chat多动作架构设计说明

## 文档定位

本文档用于替代“只围绕单个 `ParsedResult` 演进”的设计思路，给 HOLO AI Chat 提供一个可长期演进、但短期仍然能快速落地的中间态架构。

本文档关注：
- 为什么当前单意图架构不足以支撑“一句话多次记账 / 一句话多个任务”
- 在不一次性引入完整 Agent Runtime 的前提下，应该先调整哪些数据结构和模块边界
- 如何让短期的多动作能力与中长期 AI Chat 底座保持兼容

本文档不直接给出逐文件施工步骤。逐文件施工请看：
- [AI Chat多动作实施计划.md](./AI%20Chat多动作实施计划.md)

---

## 一、问题背景

当前 AI Chat 的主链路是：

```text
一条用户消息
  -> 一个 ParsedResult
  -> 一次 IntentRouter.route()
  -> 一条 assistant 文本
  -> 最多一张卡片
```

这条链路适合以下场景：
- “午饭 35”
- “提醒我下午开会”
- “帮我打卡喝水”

但不适合以下场景：
- “今天加油 200，停车费 20”
- “提醒我中午抢票，刚买早餐 12”
- “晚上买咖啡 28，再建个任务提醒我报销”

因为这些输入天然包含多个动作，而当前系统的核心数据模型、持久化结构和 UI 渲染方式都默认“一条消息只对应一个动作结果”。

---

## 二、设计目标

### 2.1 短期目标

在当前产品阶段，优先支持以下能力：

- 一句话拆成多个动作
- 顺序执行多个动作
- 支持“部分成功”
- 一个 assistant 消息展示多个执行结果
- 单意图消息继续按旧逻辑兼容

### 2.2 中期目标

- 让 AI Chat 从“自然语言快捷入口”升级为“轻量对话编排器”
- 为后续结构化输出、能力注册、执行轨迹留出稳定接口

### 2.3 非目标

当前阶段不做以下事情：

- 不引入完整 planner / agent runtime
- 不做后台长任务调度
- 不支持复杂混合型“查询 + 执行动作”自动编排
- 不做事务级回滚

---

## 三、核心设计判断

### 3.1 不再把单个 `ParsedResult` 作为系统中心

`ParsedResult` 可以继续保留，作为“单个动作解析结果”的兼容结构；但从本次方案开始，系统中心应升级为：

- `AIParseBatch`：这一轮用户输入的整体解析结果
- `AIParseItem`：这一轮输入里拆出的单个动作
- `AIExecutionBatch`：这一轮输入最终的执行结果集合
- `AIExecutionItem`：单个动作的执行结果

这意味着系统重心从：

```text
message -> parsedResult
```

升级为：

```text
message -> parseBatch -> executionBatch
```

### 3.2 现在先做“轻量编排层”，不做“重型执行层”

当前阶段没有必要一次性引入通用 Agent Runtime，但必须先抽出一层 `ConversationCoordinator`。

它负责：
- 调用 AI provider 进行 batch 解析
- 判断本轮消息属于什么交互模式
- 顺序执行每个动作
- 生成汇总文案
- 输出持久化所需的 batch 结果

它不负责：
- 真正的数据写入细节
- 具体业务逻辑
- UI 展示

业务动作仍然由现有 `IntentRouter` 承担。

### 3.3 当前阶段对“混合 query + action”采用保守策略

例如：
- “提醒我下午开会，再告诉我今天还有什么任务”

这种输入理论上可以支持，但当前阶段不建议直接自动混合执行。原因是：
- 查询型输出与执行型输出的结构差异大
- 当前 UI 与流式逻辑对 query 仍然是单路特化
- 如果为了短期强行混合，后续维护成本很高

因此当前阶段的规则是：

- 单个 `query`：继续走现有流式聊天路径
- `query` 和执行动作混合：返回澄清问题，请用户拆开说

这样会牺牲一部分“聪明感”，但能显著提升系统稳定性。

---

## 四、目标架构

### 4.1 高层结构

```text
ChatView / MessageBubbleView
  -> ChatViewModel
      -> ConversationCoordinator
          -> AIProvider
          -> IntentRouter
          -> ChatMessageRepository
```

### 4.2 角色分工

#### ChatViewModel

负责：
- 输入框和消息列表状态
- 创建占位消息
- 调用 Coordinator
- 处理纯 query 的流式展示

不再负责：
- 遍历多动作
- 聚合执行结果
- 自己拼接所有批处理持久化数据

#### ConversationCoordinator

这是本次新增的核心中间层。

负责：
- 调用 `AIProvider.parseUserInputBatch`
- 判断是否需要澄清
- 判断是否允许执行
- 顺序调用 `IntentRouter.route`
- 将每个动作的执行结果整理成 `AIExecutionBatch`
- 生成最终 assistant 文本

实现要求：
- 不使用全局单例作为唯一接入方式
- 通过构造参数注入 `IntentRouting` 之类的抽象，方便测试替身注入
- 在多动作循环中检查 `Task.isCancelled` / `Task.checkCancellation()`

#### AIProvider

继续承担模型调用，但接口需要从“只支持单结果”升级为“支持 batch 解析”。

升级方式不是直接替换旧接口，而是：
- 保留 `parseUserInput`
- 新增 `parseUserInputBatch`
- 用默认实现把旧单结果包成 batch

这样兼容成本最低。

补充说明：
- `PromptManager` 当前有两层覆盖：运行时内存 cache + `UserDefaults` 自定义模板
- 真正会长期挡住新默认模板的不是内存 cache，而是用户曾经保存过的 `UserDefaults` 自定义值
- 因此切换到 batch prompt 后，必须在实施方案中明确“重置自定义 prompt”或引入 prompt 版本迁移

#### IntentRouter

继续保持为本地业务执行层，不做大的职责扩张。

它仍然只关心：
- 接收一个动作
- 写入本地业务实体
- 返回 `RouteResult`

### 4.3 数据流

```text
用户发送消息
  -> ChatViewModel 创建 user / assistant 占位消息
  -> ConversationCoordinator 请求 AIParseBatch
  -> 判断：
       - clarification / unknown -> 直接返回追问
       - single query -> 交回 ChatViewModel 走流式聊天
       - action batch -> 顺序执行
  -> Coordinator 生成 AIExecutionBatch + summaryText
  -> ChatMessageRepository 双写：
       - 旧字段：intent / extractedDataJSON
       - 新字段：parsedBatchJSON / executionBatchJSON
  -> UI 优先从 executionBatchJSON 渲染多结果
```

---

## 五、推荐数据结构

### 5.1 交互模式

```swift
enum AIInteractionMode: String, Codable {
    case singleAction = "single_action"
    case multiAction = "multi_action"
    case query = "query"
    case clarification = "clarification"
    case unknown = "unknown"
}
```

### 5.2 解析结果

```swift
struct AIParseItem: Codable, Identifiable {
    let id: String
    let intent: AIIntent
    let confidence: Double
    let extractedData: [String: String]?
    let responseText: String?

    var isHighConfidence: Bool {
        confidence >= ParsedResult.highConfidenceThreshold
    }
}

struct AIParseBatch: Codable {
    let mode: AIInteractionMode
    let items: [AIParseItem]
    let needsClarification: Bool
    let clarificationQuestion: String?
    let fallbackResponseText: String?

    var first: AIParseItem? { items.first }
    var isEmpty: Bool { items.isEmpty }
}
```

### 5.3 执行结果

```swift
enum AIExecutionStatus: String, Codable {
    case success
    case failed
    case skipped
}

struct AIExecutionItem: Codable, Identifiable {
    let id: String
    let parseItemId: String
    let intent: AIIntent
    let status: AIExecutionStatus
    let summaryText: String
    let renderData: [String: String]?
    let linkedEntityType: String?
    let linkedEntityId: String?
    let errorText: String?
}

struct AIExecutionBatch: Codable {
    let mode: AIInteractionMode
    let items: [AIExecutionItem]
    let finalText: String
}
```

### 5.4 与现有 `ParsedResult` 的关系

短期不建议删除 `ParsedResult`，而是将它降级为兼容层：

- `OpenAICompatibleProvider` 在回退旧 JSON 时，仍然可以先解出 `ParsedResult`
- `AIProvider` 默认实现可以把 `ParsedResult` 包成 `AIParseBatch`
- `IntentRouter` 仍可继续吃 `ParsedResult`

为此建议新增转换：

```swift
extension ParsedResult {
    var asParseItem: AIParseItem { ... }
}

extension AIParseItem {
    var asParsedResult: ParsedResult { ... }
}
```

这一步能显著减少一次性重构量。

---

## 六、持久化策略

### 6.1 继续保留旧字段

以下字段继续保留：
- `intent`
- `extractedDataJSON`

原因：
- 兼容旧消息
- 兼容现有 UI 和卡片逻辑
- 允许分阶段改造

### 6.2 新增两个批量字段

在 `ChatMessage` 上新增：

- `parsedBatchJSON`
- `executionBatchJSON`

为什么不是继续使用 `multiResultsJSON`：
- `multiResultsJSON` 语义太弱，只表达“多个结果”
- 它无法清晰区分“AI 解析输出”和“本地执行结果”
- 它很难承载状态、错误、linked entity、汇总文案

`parsedBatchJSON` 用于保存 AI 的结构化解析输出。  
`executionBatchJSON` 用于保存本地执行后的最终状态，供 UI 渲染与后续审计使用。

### 6.3 持久化规则

- 单意图执行消息：写旧字段 + 写单元素 `executionBatchJSON`
- 多动作执行消息：写旧字段的 first mirror + 写完整 `parsedBatchJSON` / `executionBatchJSON`
- 纯 query：只写文本，不强制写 execution batch
- clarification / unknown：可只写 `parsedBatchJSON`，不写 execution batch

这里的 `first mirror` 必须被视为“兼容镜像字段”，不是多动作消息的真实来源。  
在多动作场景下：
- 旧字段仅用于兼容旧渲染链路和旧查询逻辑
- 新 UI 和后续逻辑必须优先读取 `executionBatchJSON`

---

## 七、UI 渲染策略

### 7.1 消息不再默认对应“一张卡片”

新的 UI 心智应改为：

- 一条 assistant message
- 对应一个 `AIExecutionBatch`
- 每个 `AIExecutionItem` 可映射成：
  - 交易卡片
  - 任务卡片
  - 打卡卡片
  - 心情卡片
  - 文本结果项

### 7.2 优先使用执行结果渲染

渲染顺序应为：

1. 如果存在 `executionBatchJSON`，优先按 batch 渲染
2. 否则回退到旧的 `intent + extractedDataJSON`

兼容要求：
- 从 `AIExecutionItem` 构建卡片时，要复用旧字段兜底逻辑
- `linkedEntityId` 缺失时，继续从 `transactionId` / `taskId` / `habitId` / `thoughtId` 推断
- 这样旧消息与新消息的点击行为才不会分叉

### 7.3 点击跳转基于 item 级实体链接

点击导航不应再依赖 message 级别的 `linkedTransactionId` / `linkedTaskId`。  
应该改为读取单个 `AIExecutionItem` 或单个卡片数据上的 `linkedEntityId`。

这对多动作场景是必须的。

---

## 八、执行语义

### 8.1 顺序执行

当前阶段统一按顺序执行，不并发。  
原因：
- 降低副作用冲突风险
- 便于调试
- 更符合当前本地 Core Data / Repository 心智

### 8.2 部分成功

当前阶段允许部分成功：

- 某个动作失败，不中断整轮
- 失败项记录 `status = failed`
- 成功项照常创建实体
- 最终 assistant 文本展示成功与失败汇总

### 8.3 不做回滚

当前阶段不实现跨动作回滚。  
原因：
- 本地多个 Repository 不具备统一事务边界
- 用户可接受“成功 2 项、失败 1 项”的结果
- 回滚复杂度远高于当前需求价值

### 8.4 混合 query + action

当前阶段规则：

- 单独 query：支持
- action batch：支持
- query + action 混合：返回澄清

建议在 prompt 中明确写死该规则，避免模型随意输出混合结构。

### 8.5 取消与中断

当前阶段沿用现有 `currentTask.cancel()` 取消链路。  
设计要求：

- 多动作执行期间，`ConversationCoordinator` 每轮循环检查取消状态
- 如果用户点击停止，已完成项保留，未执行项不再继续
- 当前阶段不对已完成项做回滚

### 8.6 ChatViewModel 预留点保护

`ChatViewModel` 中现有 `// ENERGY:` 预留位必须在重构后继续保留，不能被 Coordinator 接入过程吞掉。  
推荐保留位置：

- `userContext` 构建后
- batch 解析完成后
- assistant 消息写回成功后

---

## 九、模块调整建议

### 9.1 必调

- `AIProvider.swift`
- `OpenAICompatibleProvider.swift`
- `MockAIProvider.swift`
- `AIModels.swift`
- `ChatMessage+CoreDataProperties.swift`
- `ChatMessageViewData.swift`
- `ChatMessageRepository.swift`
- `ChatViewModel.swift`
- `MessageBubbleView.swift`
- `ChatView.swift`
- `ChatCardData.swift`

### 9.2 新增

- `Services/AI/ConversationCoordinator.swift`
- `Services/AI/IntentRouting.swift`
- `HoloTests/Services/AI/AIParseBatchTests.swift`
- `HoloTests/Services/AI/ConversationCoordinatorTests.swift`

### 9.3 可以后置

- 能力注册表
- 通用 tool schema
- 执行审计页面
- prompt 评估框架

---

## 十、分阶段路线

### Phase A：短期可交付

目标：
- 支持一句话多次记账
- 支持一句话多个任务 / 账单 + 任务
- 多结果 UI 展示

交付边界：
- `AIParseBatch`
- `AIExecutionBatch`
- `ConversationCoordinator`
- `parsedBatchJSON` / `executionBatchJSON`

### Phase B：中期稳态

目标：
- 完整结构化输出优先
- Provider 能力分层
- 结果可回放、可排错

交付边界：
- `structuredOutput(schema:)`
- prompt 回退策略
- execution trace 调试入口

### Phase C：长期演进

目标：
- AI Chat 成为复杂工作台入口

交付边界：
- 能力注册
- 多步计划
- 后台任务
- 可恢复执行

---

## 十一、最终结论

这次不应该把系统升级目标定义为“支持多意图”，而应该定义为：

> 把 AI Chat 从“单动作自然语言入口”升级为“轻量多动作对话编排器”。

这样做的价值是：
- 短期满足一句话多次记账、账单 + 任务等真实需求
- 不要求现在就把系统做成完整 Agent
- 为未来 AI Chat 承载更复杂任务留出正确的数据结构和模块边界

如果只做 `multiResultsJSON + forEach route`，短期虽然也能跑通，但很快会再次被数据结构和模块耦合卡住。  
因此本方案建议优先升级“系统形状”，再做具体多动作能力。
