# AI Chat多动作能力 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 HOLO AI Chat 在保持现有单意图兼容的前提下，支持一句话完成多次记账、多个任务、以及账单 + 任务的组合执行。

**Architecture:** 采用“轻量对话编排器”方案：保留现有 `IntentRouter` 作为业务执行层，新增 `ConversationCoordinator` 负责 batch 解析、顺序执行和结果聚合；新增 `parsedBatchJSON` / `executionBatchJSON` 两个批量字段承载未来演进所需的结构化数据。

**Tech Stack:** SwiftUI、Core Data、OpenAI-Compatible Chat API、PromptManager、Repository 模式、现有 IntentRouter。

---

## 前置说明

### 与旧方案的关系

本计划替代：
- [多意图识别实施计划.md](./%E5%A4%9A%E6%84%8F%E5%9B%BE%E8%AF%86%E5%88%AB%E5%AE%9E%E6%96%BD%E8%AE%A1%E5%88%92.md)

旧方案的主要问题：
- 直接替换 `AIProvider.parseUserInput` 返回类型，兼容风险高
- `multiResultsJSON` 结构过弱，无法支撑部分成功和后续演进
- 多动作执行逻辑直接堆在 `ChatViewModel`

### 当前工程约束

已确认：
- 工程文件是 [Holo.xcodeproj](/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo%20APP/Holo/Holo.xcodeproj)
- `xcodebuild -list -project Holo.xcodeproj` 当前只显示 `Holo` 目标
- `project.pbxproj` 中未检索到 `HoloTests`，说明现有测试文件目录不一定已接入测试 target
- `CoreDataStack` 当前已显式开启 `NSMigratePersistentStoresAutomaticallyOption` 与 `NSInferMappingModelAutomaticallyOption`

因此本计划把“测试 target 接线检查”列为显式步骤。  
如果测试 target 尚未接线，优先接线；如果暂时不接线，则至少保留测试文件并执行编译验证。

---

## 文件结构与职责

### 新增文件

- `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/ConversationCoordinator.swift`
  - AI Chat 的轻量编排层
  - 负责 batch 解析、执行聚合、结果汇总

- `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/IntentRouting.swift`
  - 为 `IntentRouter` 抽出可测试协议

- `HOLO/Holo/Holo APP/Holo/HoloTests/Services/AI/AIParseBatchTests.swift`
  - 校验 batch JSON 解码与回退行为

- `HOLO/Holo/Holo APP/Holo/HoloTests/Services/AI/ConversationCoordinatorTests.swift`
  - 校验多动作执行、部分成功、混合 query + action 澄清

### 修改文件

- `HOLO/Holo/Holo APP/Holo/Holo/Models/AI/AIModels.swift`
  - 新增 batch 相关模型

- `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/AIProvider.swift`
  - 增加 batch 解析接口与默认兼容实现

- `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/OpenAICompatibleProvider.swift`
  - 解析 batch JSON

- `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/MockAIProvider.swift`
  - 支持多动作 mock，便于 UI 调试
  - 注意：这里只提供非常弱的分句能力，不代表正式拆分策略

- `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift`
  - 更新意图识别 prompt 为 batch 输出

- `HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift`
  - 为 `ChatMessage` 添加 `parsedBatchJSON` / `executionBatchJSON`

- `HOLO/Holo/Holo APP/Holo/Holo/Models/ChatMessage+CoreDataProperties.swift`
  - 解析新字段，增加缓存

- `HOLO/Holo/Holo APP/Holo/Holo/Models/ChatMessageViewData.swift`
  - 将 batch 结构透出给 UI 层

- `HOLO/Holo/Holo APP/Holo/Holo/Data/Repositories/ChatMessageRepository.swift`
  - 持久化新字段

- `HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift`
  - 改为依赖 `ConversationCoordinator`

- `HOLO/Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift`
  - 从 `AIExecutionItem` 构建卡片数据

- `HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/MessageBubbleView.swift`
  - 支持渲染多结果

- `HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift`
  - 点击跳转改成 item 级实体链接

---

## Task 1: 建立新的批量数据模型

**Files:**
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Models/AI/AIModels.swift`

- [ ] **Step 1: 在 `AIModels.swift` 中新增交互模式与批量结构**

在 `ParsedResult` 之后新增以下结构：

```swift
enum AIInteractionMode: String, Codable {
    case singleAction = "single_action"
    case multiAction = "multi_action"
    case query = "query"
    case clarification = "clarification"
    case unknown = "unknown"
}

enum AIExecutionStatus: String, Codable {
    case success
    case failed
    case skipped
}

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

    init(
        mode: AIInteractionMode,
        items: [AIParseItem],
        needsClarification: Bool = false,
        clarificationQuestion: String? = nil,
        fallbackResponseText: String? = nil
    ) {
        self.mode = mode
        self.items = items
        self.needsClarification = needsClarification
        self.clarificationQuestion = clarificationQuestion
        self.fallbackResponseText = fallbackResponseText
    }
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

- [ ] **Step 2: 为旧 `ParsedResult` 增加转换能力**

在同文件中增加扩展：

```swift
extension ParsedResult {
    var asParseItem: AIParseItem {
        AIParseItem(
            id: UUID().uuidString,
            intent: intent,
            confidence: confidence,
            extractedData: extractedData,
            responseText: responseText
        )
    }
}

extension AIParseItem {
    var asParsedResult: ParsedResult {
        ParsedResult(
            intent: intent,
            confidence: confidence,
            extractedData: extractedData,
            needsClarification: false,
            clarificationQuestion: nil,
            responseText: responseText
        )
    }
}
```

- [ ] **Step 3: 补充 batch 编码/解码帮助方法**

建议继续放在 `AIModels.swift` 或新建同文件内 extension：

```swift
extension AIParseBatch {
    var first: AIParseItem? { items.first }
    var isEmpty: Bool { items.isEmpty }
}
```

- [ ] **Step 4: 编译检查**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:
- 工程能继续编译
- 此阶段不会改业务行为

---

## Task 2: 升级 AIProvider，但保留旧接口兼容

**Files:**
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/AIProvider.swift`
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/MockAIProvider.swift`

- [ ] **Step 1: 为 `AIProvider` 增加 batch 接口**

在协议中新增：

```swift
func parseUserInputBatch(_ input: String, context: UserContext) async throws -> AIParseBatch
```

并加协议扩展默认实现：

```swift
extension AIProvider {
    func parseUserInputBatch(_ input: String, context: UserContext) async throws -> AIParseBatch {
        let single = try await parseUserInput(input, context: context)

        let mode: AIInteractionMode
        switch single.intent {
        case .query:
            mode = .query
        case .unknown:
            mode = single.needsClarification ? .clarification : .unknown
        default:
            mode = .singleAction
        }

        return AIParseBatch(
            mode: mode,
            items: [single.asParseItem],
            needsClarification: single.needsClarification,
            clarificationQuestion: single.clarificationQuestion,
            fallbackResponseText: single.responseText
        )
    }
}
```

- [ ] **Step 2: 为 `MockAIProvider` 实现 batch mock**

不要只依赖默认实现，直接覆盖 `parseUserInputBatch`，方便本地测试多动作 UI。  
建议规则：

- 先按 `，` / `,` / `；` / `;` 拆句
- 每段调用现有 `parseUserInput`
- 只要拆出 2 个以上可执行动作，`mode = .multiAction`
- 如果同时出现 `query` 和 action，返回 clarification

建议最小实现：

```swift
func parseUserInputBatch(_ input: String, context: UserContext) async throws -> AIParseBatch {
    func wrapSingle(_ parsed: ParsedResult) -> AIParseBatch {
        let mode: AIInteractionMode
        switch parsed.intent {
        case .query:
            mode = .query
        case .unknown:
            mode = parsed.needsClarification ? .clarification : .unknown
        default:
            mode = .singleAction
        }

        return AIParseBatch(
            mode: mode,
            items: [parsed.asParseItem],
            needsClarification: parsed.needsClarification,
            clarificationQuestion: parsed.clarificationQuestion,
            fallbackResponseText: parsed.responseText
        )
    }

    let segments = input
        .split(whereSeparator: { "，,；;".contains($0) })
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    if segments.count <= 1 {
        let single = try await parseUserInput(input, context: context)
        return wrapSingle(single)
    }

    var items: [AIParseItem] = []
    for segment in segments {
        let parsed = try await parseUserInput(segment, context: context)
        items.append(parsed.asParseItem)
    }

    let hasQuery = items.contains { $0.intent == .query }
    let hasAction = items.contains { $0.intent != .query && $0.intent != .unknown }

    if hasQuery && hasAction {
        return AIParseBatch(
            mode: .clarification,
            items: items,
            needsClarification: true,
            clarificationQuestion: "当前版本暂不支持把查询和执行操作混在一句话里，请拆成两句发送。"
        )
    }

    return AIParseBatch(mode: .multiAction, items: items)
}
```

- [ ] **Step 3: 编译检查**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:
- 旧调用点仍可编译
- Mock provider 可支持多动作调试

---

## Task 3: 更新 Prompt 与 OpenAI batch JSON 解析

**Files:**
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift`
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/OpenAICompatibleProvider.swift`

- [ ] **Step 1: 将意图识别 prompt 改为 batch 输出**

把 `.intentRecognition` 的 JSON 输出格式改成：

```json
{
  "mode": "multi_action",
  "items": [
    {
      "id": "1",
      "intent": "record_expense",
      "confidence": 0.95,
      "extractedData": {
        "amount": "200",
        "note": "加油",
        "primaryCategory": "交通",
        "subCategory": "加油"
      },
      "responseText": "记录加油支出"
    },
    {
      "id": "2",
      "intent": "record_expense",
      "confidence": 0.93,
      "extractedData": {
        "amount": "20",
        "note": "停车费",
        "primaryCategory": "交通",
        "subCategory": "停车"
      },
      "responseText": "记录停车支出"
    }
  ],
  "needsClarification": false,
  "clarificationQuestion": null,
  "fallbackResponseText": null
}
```

并在 prompt 中增加规则：

- 单个执行动作也输出 batch
- `query + action` 混合时，不要输出可执行 batch，改为 `needsClarification = true`
- 无法可靠拆分时，宁可返回 clarification，不要猜测执行

- [ ] **Step 1.5: 处理 PromptManager 的默认模板覆盖问题**

当前 `PromptManager` 是：
- 先读内存 `cache`
- 再读 `UserDefaults` 自定义模板
- 最后才回退到硬编码默认模板

因此真正会持续挡住新 batch prompt 的是“用户曾保存过旧版 `intentRecognition` 模板”。  
本轮至少做以下之一：

- 方案 A：在发布说明与验证步骤中明确要求重置 `intentRecognition`
- 方案 B：给 `intentRecognition` 引入版本号，检测到旧版本自定义模板时自动回退默认值

短期推荐先做方案 A，并在人工验证前执行：

```swift
PromptManager.shared.resetCustomPrompt(.intentRecognition)
PromptManager.shared.clearCache()
```

- [ ] **Step 2: 在 `OpenAICompatibleProvider` 中新增 batch 解析方法**

新增：

```swift
func parseUserInputBatch(_ input: String, context: UserContext) async throws -> AIParseBatch
```

内部流程：

1. 与旧 `parseUserInput` 共用同一 prompt 请求
2. 优先尝试解码 `AIParseBatch`
3. 回退解码 `ParsedResult`
4. 最终回退成 clarification / unknown batch

`extractJSON(from:)` 当前已存在于 `OpenAICompatibleProvider.swift`，本轮可直接复用；如果后续 provider 增多，再考虑抽成共享工具方法。

核心方法建议：

```swift
private func parseBatchFromJSON(_ text: String) -> AIParseBatch {
    let jsonString = extractJSON(from: text)

    guard let data = jsonString.data(using: .utf8) else {
        return AIParseBatch(
            mode: .clarification,
            items: [],
            needsClarification: true,
            clarificationQuestion: "我没完全理解这句话，你可以拆开再说一次吗？",
            fallbackResponseText: text
        )
    }

    if let batch = try? JSONDecoder().decode(AIParseBatch.self, from: data) {
        return batch
    }

    if let single = try? JSONDecoder().decode(ParsedResult.self, from: data) {
        let mode: AIInteractionMode = single.intent == .query ? .query : .singleAction
        return AIParseBatch(
            mode: mode,
            items: [single.asParseItem],
            needsClarification: single.needsClarification,
            clarificationQuestion: single.clarificationQuestion,
            fallbackResponseText: single.responseText
        )
    }

    return AIParseBatch(
        mode: .clarification,
        items: [],
        needsClarification: true,
        clarificationQuestion: "我没完全理解这句话，你可以拆开再说一次吗？",
        fallbackResponseText: text
    )
}
```

- [ ] **Step 3: 保持旧 `parseUserInput` 可用**

旧方法不要删除。  
改成复用 batch 接口：

```swift
func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult {
    let batch = try await parseUserInputBatch(input, context: context)
    return batch.first?.asParsedResult ?? ParsedResult(
        intent: .unknown,
        confidence: 0.3,
        extractedData: nil,
        needsClarification: batch.needsClarification,
        clarificationQuestion: batch.clarificationQuestion,
        responseText: batch.fallbackResponseText
    )
}
```

- [ ] **Step 4: 用 PromptTestSheet 做人工回归**

重点输入：

- `今天加油200，停车费20`
- `提醒我今天中午抢票，刚买早饭5块钱`
- `帮我记午饭25`
- `告诉我今天还有什么任务，再记一笔咖啡18`

Expected:
- 前两个返回 batch
- 第三个返回单元素 batch
- 第四个返回 clarification
- 如果之前自定义过 prompt，需要先执行 reset，再测

---

## Task 4: 扩展 ChatMessage 持久化结构

**Files:**
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift`
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Models/ChatMessage+CoreDataProperties.swift`
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Models/ChatMessageViewData.swift`
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Data/Repositories/ChatMessageRepository.swift`

- [ ] **Step 1: 在 Core Data 中新增字段**

在 `ChatMessage` 属性中新增：

```swift
let chatParsedBatch = NSAttributeDescription()
chatParsedBatch.name = "parsedBatchJSON"
chatParsedBatch.attributeType = .stringAttributeType
chatParsedBatch.isOptional = true
chatAttributes.append(chatParsedBatch)

let chatExecutionBatch = NSAttributeDescription()
chatExecutionBatch.name = "executionBatchJSON"
chatExecutionBatch.attributeType = .stringAttributeType
chatExecutionBatch.isOptional = true
chatAttributes.append(chatExecutionBatch)
```

不要再引入 `multiResultsJSON`。

- [ ] **Step 2: 在 `ChatMessage+CoreDataProperties.swift` 中声明字段**

新增：

```swift
@NSManaged var parsedBatchJSON: String?
@NSManaged var executionBatchJSON: String?
```

并加入缓存解析属性：

```swift
var parsedBatch: AIParseBatch? { ... }
var executionBatch: AIExecutionBatch? { ... }
```

解析方式与 `extractedDataDictionary` 一致，使用 associated object 做缓存。

- [ ] **Step 3: 在 `ChatMessageViewData` 中透出 batch**

新增字段：

```swift
var parsedBatchJSON: String?
var executionBatchJSON: String?
```

新增计算属性：

```swift
var parsedBatch: AIParseBatch? { ... }
var executionBatch: AIExecutionBatch? { ... }
```

并更新 `init(message:)` 与主初始化器。

注意：
- `ChatMessageViewData` 是 `struct`，不能使用 associated object
- 本轮推荐在 `init(message:)` 时预解析并落成存储属性，避免每次渲染重复解析

建议形态：

```swift
let parsedBatch: AIParseBatch?
let executionBatch: AIExecutionBatch?
```

并在初始化器里完成 JSON -> model 解码。

- [ ] **Step 4: 扩展 Repository 的元数据更新方法**

将：

```swift
func updateMessageMetadata(_ messageId: UUID, intent: String?, extractedDataJSON: String?)
```

升级为：

```swift
func updateMessageMetadata(
    _ messageId: UUID,
    intent: String?,
    extractedDataJSON: String?,
    parsedBatchJSON: String? = nil,
    executionBatchJSON: String? = nil
)
```

同时同步更新 snapshot。

- [ ] **Step 5: 编译与迁移验证**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Manual Check:
- 旧消息能正常显示
- 新字段为空时不影响旧逻辑
- Core Data 轻量迁移不报错
- 旧消息加载后不会因为 `parsedBatchJSON == nil` 或 `executionBatchJSON == nil` 崩溃

---

## Task 5: 新增 ConversationCoordinator，承接多动作编排

**Files:**
- Create: `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/ConversationCoordinator.swift`
- Create: `HOLO/Holo/Holo APP/Holo/Holo/Services/AI/IntentRouting.swift`

- [ ] **Step 1: 定义 Coordinator 输出结构**

在新文件里新增：

```swift
struct ConversationProcessResult {
    let finalText: String
    let parsedBatch: AIParseBatch?
    let executionBatch: AIExecutionBatch?
    let firstIntent: AIIntent?
    let firstExtractedData: [String: String]?
    let shouldStreamChat: Bool
}
```

这里的 `firstIntent` / `firstExtractedData` 只用于兼容旧字段写入。  
多动作消息的真实渲染与后续逻辑必须优先读取 `executionBatch`。

- [ ] **Step 2: 实现主入口**

建议主签名：

```swift
protocol IntentRouting {
    func route(_ result: ParsedResult) async throws -> IntentRouter.RouteResult
}

extension IntentRouter: IntentRouting {}

@MainActor
final class ConversationCoordinator {
    private let intentRouter: IntentRouting

    init(intentRouter: IntentRouting = IntentRouter.shared) {
        self.intentRouter = intentRouter
    }

    func process(
        text: String,
        userContext: UserContext,
        provider: AIProvider
    ) async throws -> ConversationProcessResult
}
```

- [ ] **Step 3: 写清楚分支规则**

核心逻辑按以下顺序写：

1. 调 `provider.parseUserInputBatch`
2. `needsClarification == true` -> 直接返回追问
3. `items.isEmpty` -> clarification
4. `mode == .query && items.count == 1` -> `shouldStreamChat = true`
5. 如果存在 `query + action` 混合 -> clarification
6. 如果存在低置信度 item -> clarification
7. 其余情况按顺序执行
8. 每轮执行前检查取消状态

建议核心骨架：

```swift
let parseBatch = try await provider.parseUserInputBatch(text, context: userContext)

if parseBatch.needsClarification {
    return ConversationProcessResult(...)
}

if parseBatch.mode == .query, parseBatch.items.count == 1 {
    return ConversationProcessResult(
        finalText: "",
        parsedBatch: parseBatch,
        executionBatch: nil,
        firstIntent: parseBatch.first?.intent,
        firstExtractedData: parseBatch.first?.extractedData,
        shouldStreamChat: true
    )
}
```

- [ ] **Step 4: 顺序执行每个动作，并允许部分成功**

对每个 item：

```swift
var executionItems: [AIExecutionItem] = []

for item in parseBatch.items {
    try Task.checkCancellation()

    do {
        let routeResult = try await intentRouter.route(item.asParsedResult)
        let renderData = Self.buildRenderData(from: item, routeResult: routeResult)

        executionItems.append(
            AIExecutionItem(
                id: UUID().uuidString,
                parseItemId: item.id,
                intent: item.intent,
                status: .success,
                summaryText: routeResult.text,
                renderData: renderData,
                linkedEntityType: routeResult.linkedEntity?.type.rawValue,
                linkedEntityId: routeResult.linkedEntity?.id.uuidString,
                errorText: nil
            )
        )
    } catch {
        executionItems.append(
            AIExecutionItem(
                id: UUID().uuidString,
                parseItemId: item.id,
                intent: item.intent,
                status: .failed,
                summaryText: "\(item.intent.rawValue) 执行失败",
                renderData: item.extractedData,
                linkedEntityType: nil,
                linkedEntityId: nil,
                errorText: error.localizedDescription
            )
        )
    }
}
```

`buildRenderData` 不能留空，本轮需要显式定义。  
建议最小实现：

```swift
private static func buildRenderData(
    from item: AIParseItem,
    routeResult: IntentRouter.RouteResult
) -> [String: String]? {
    var data = item.extractedData ?? [:]

    if let entity = routeResult.linkedEntity {
        data["entityType"] = entity.type.rawValue
        data["entityId"] = entity.id.uuidString
    }
    if let txId = routeResult.transactionId {
        data["transactionId"] = txId.uuidString
    }
    if let taskId = routeResult.taskId {
        data["taskId"] = taskId.uuidString
    }
    if let habitId = routeResult.habitId {
        data["habitId"] = habitId.uuidString
    }
    if let thoughtId = routeResult.thoughtId {
        data["thoughtId"] = thoughtId.uuidString
    }

    return data.isEmpty ? nil : data
}
```

- [ ] **Step 5: 本地生成汇总文案**

不要把汇总文案交回 LLM。  
推荐规则：

- 1 个动作：直接显示该动作 summary
- 多个动作：`已为你处理 N 件事：` + 分行列表
- 如果包含失败项：尾部补充 `其中 X 项失败`

示例：

```swift
private static func buildFinalText(from items: [AIExecutionItem]) -> String {
    guard !items.isEmpty else { return "我没能识别出可执行操作，请拆开重试。" }
    if items.count == 1 { return items[0].summaryText }

    let lines = items.enumerated().map { index, item in
        let prefix = "\(index + 1). "
        if item.status == .failed {
            return prefix + "\(item.summaryText)：\(item.errorText ?? "未知错误")"
        }
        return prefix + item.summaryText
    }

    return "已为你处理 \(items.count) 件事：\n" + lines.joined(separator: "\n")
}
```

---

## Task 6: 重构 ChatViewModel，改由 Coordinator 驱动

**Files:**
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift`

- [ ] **Step 1: 在 `sendMessage()` 中接入 `ConversationCoordinator`**

把现有 `parseUserInput -> switch intent -> route` 的大段逻辑替换为：

```swift
let processResult = try await self.coordinator.process(
    text: text,
    userContext: userContext,
    provider: self.provider
)
```

为此先在 `ChatViewModel` 中增加：

```swift
private let coordinator: ConversationCoordinator
```

并在初始化器里注入：

```swift
init(provider: AIProvider? = nil, coordinator: ConversationCoordinator = ConversationCoordinator()) {
    self.provider = provider ?? MockAIProvider()
    self.coordinator = coordinator
    ...
}
```

- [ ] **Step 2: 保留纯 query 的流式逻辑**

只有满足：

```swift
processResult.shouldStreamChat == true
```

才继续走当前 streaming path。  
其余情况一律由 `processResult.finalText` 直接结束 assistant 消息。

- [ ] **Step 3: 将 batch 双写到消息元数据**

写入规则：

```swift
self.chatRepo?.updateMessageMetadata(
    aiMessageId,
    intent: processResult.firstIntent?.rawValue,
    extractedDataJSON: Self.encodeExtractedData(processResult.firstExtractedData),
    parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
    executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch)
)
```

新增两个 helper：

```swift
private static func encodeParseBatch(_ batch: AIParseBatch?) -> String? { ... }
private static func encodeExecutionBatch(_ batch: AIExecutionBatch?) -> String? { ... }
```

- [ ] **Step 4: 删除 ViewModel 中直接负责多动作聚合的逻辑**

确保 `ChatViewModel` 只保留：
- 占位消息创建
- query 流式输出
- 元数据保存
- 错误兜底

不要把多动作执行细节重新堆回 ViewModel。

- [ ] **Step 5: 保留现有取消链路与 ENERGY 预留位**

要求：
- 保留 `currentTask.cancel()` 作为统一取消入口
- `ConversationCoordinator` 内部支持取消后，ViewModel 不需要重复实现多动作中断
- 保留原有三处 `// ENERGY:` 注释锚点，只调整其包围的逻辑
- 当前阶段可以继续复用 `isStreaming` 作为“处理中”状态；如果后续语义变重，再统一重命名为 `isProcessing`

---

## Task 7: UI 改为支持多结果渲染

**Files:**
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift`
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/MessageBubbleView.swift`
- Modify: `HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift`

- [ ] **Step 1: 让 `ChatCardData` 支持从 execution item 构建**

为各卡片数据结构增加：

```swift
let linkedEntityId: String?
```

新增工厂：

```swift
static func from(executionItem: AIExecutionItem) -> ChatCardData?
static func multiple(from batch: AIExecutionBatch?) -> [ChatCardData]
```

`from(executionItem:)` 优先读取：
- `executionItem.renderData`
- `executionItem.linkedEntityId`

并要求显式复用旧兜底逻辑：

```swift
let linkedEntityId = executionItem.linkedEntityId ?? ChatCardData.linkedEntityId(from: executionItem.renderData)
```

- [ ] **Step 2: `MessageBubbleView` 优先渲染 execution batch**

新增：

```swift
private var executionCards: [ChatCardData] {
    ChatCardData.multiple(from: message.executionBatch)
}
```

渲染优先级：

1. `executionCards.count > 1` -> 多卡片 VStack
2. `executionCards.count == 1` -> 单卡片
3. 回退旧 `cardData`
4. 最后回退文本气泡

- [ ] **Step 3: 给多结果加汇总标题**

推荐样式：

```swift
VStack(alignment: .leading, spacing: 8) {
    HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
        Text("已为你处理 \(cards.count) 件事")
            .font(.system(size: 13, weight: .semibold))
    }

    ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
        cardView(for: card)
    }
}
```

- [ ] **Step 4: `ChatView` 改成 item 级跳转**

把 `handleCardTap` 改为读取 card 自带的 `linkedEntityId`。  
不要继续依赖 message 级 `linkedTransactionId` / `linkedTaskId`。

交易跳转示例：

```swift
case .transaction(let data):
    guard let id = data.linkedEntityId,
          let uuid = UUID(uuidString: id) else { return }
    let transaction = FinanceRepository.shared.findTransaction(by: uuid)
    editingTransaction = transaction
```

任务跳转示例：

```swift
case .task(let data):
    guard let id = data.linkedEntityId,
          let uuid = UUID(uuidString: id) else { return }
    DeepLinkState.shared.pendingTarget = .taskDetail(taskId: uuid)
    dismiss()
```

---

## Task 8: 测试接线与新增测试

**Files:**
- Create: `HOLO/Holo/Holo APP/Holo/HoloTests/Services/AI/AIParseBatchTests.swift`
- Create: `HOLO/Holo/Holo APP/Holo/HoloTests/Services/AI/ConversationCoordinatorTests.swift`
- Modify: `HOLO/Holo/Holo APP/Holo/HoloTests/Models/AI/ChatCardDataTests.swift`
- Project: `HOLO/Holo/Holo APP/Holo/Holo.xcodeproj`

- [ ] **Step 1: 检查测试 target 是否存在**

检查：

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -list -project Holo.xcodeproj
```

如果输出里依旧没有测试 target：
- 需要在 Xcode 中创建 `HoloTests` 单元测试 target
- 将现有 `HoloTests` 目录下文件加入该 target

如果当前轮次不方便接测试 target，至少保留测试文件并完成编译验证，但不要在文档里假设测试已自动可跑。

- [ ] **Step 2: 新增 `AIParseBatchTests`**

覆盖：
- batch JSON 正常解码
- 单对象 JSON 回退包装
- 空 items -> clarification
- query + action -> clarification

示例测试点：

```swift
func testDecodeBatchJSON() throws
func testFallbackToSingleParsedResult() throws
func testEmptyBatchReturnsClarification() throws
```

- [ ] **Step 3: 新增 `ConversationCoordinatorTests`**

覆盖：
- 两笔记账全部成功
- 一笔成功一笔失败
- 单 query 走 `shouldStreamChat`
- 混合 query + action 返回 clarification

- [ ] **Step 4: 更新 `ChatCardDataTests`**

新增：
- `from(executionItem:)`
- `multiple(from:)`
- linkedEntityId 透传
- 多张卡片数量正确

---

## Task 9: 端到端验证

**Files:**
- None

- [ ] **Step 1: 编译主工程**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

- [ ] **Step 2: 手工验证单意图不回归**

验证输入：
- `午饭35`
- `提醒我下午三点开会`

Expected:
- 单卡片仍正常显示
- 旧字段兼容仍可用

- [ ] **Step 3: 手工验证多动作**

验证输入：
- `今天加油200，停车费20`
- `提醒我今天中午抢票，刚买早饭5块钱`
- `买咖啡28，再记停车费12，再提醒我晚上报销`

Expected:
- assistant 只生成一条消息
- message 下展示多结果
- 各卡片可独立点击跳转
- 旧消息仍能按旧路径点击跳转

- [ ] **Step 4: 手工验证混合 query + action**

验证输入：
- `告诉我今天还有什么任务，再记一笔奶茶16`

Expected:
- 返回澄清，不执行任何副作用操作

- [ ] **Step 5: 手工验证部分成功**

构造一个会失败的任务更新 / 删除输入，与一个成功记账放在一句话里。  
Expected:
- 成功项照常写入
- 失败项显示在汇总文本中
- 不因单项失败导致整轮中断

---

## 风险与对应策略

| 风险 | 表现 | 对策 |
|------|------|------|
| Provider 返回旧 JSON | 部分模型仍返回单对象 | `OpenAICompatibleProvider` 做 batch -> single -> clarification 三层回退 |
| 混合 query + action 行为不稳定 | 用户感觉“没那么聪明” | 当前阶段显式澄清，后续再扩成真正混合编排 |
| ViewModel 再次膨胀 | 多动作逻辑重新塞回 UI 层 | 统一收口到 `ConversationCoordinator` |
| 批量字段过弱 | 后续又想补状态/错误 | 直接使用 `parsedBatchJSON` / `executionBatchJSON`，不要用 `multiResultsJSON` |
| 测试 target 未接线 | AI 跑计划时测试命令失效 | 把接线检查列成显式前置步骤 |

---

## 完成定义

满足以下条件时，本计划可视为完成：

- 单意图消息行为不回归
- 能稳定支持一句话 2 笔记账
- 能稳定支持一句话“记账 + 任务”
- assistant 一条消息可展示多个结果
- 多结果点击跳转正确
- `ChatViewModel` 不再直接承担多动作编排
- 新增批量字段已落库并可被 UI 读取

---

## 推荐实施顺序

1. Task 1 -> Task 4：先把模型与持久化打底
2. Task 5 -> Task 6：接入 Coordinator，让主链路跑通
3. Task 7：补 UI 渲染
4. Task 8 -> Task 9：补测试与回归验证

如果中途只完成前半段，也优先保证：
- batch 数据模型正确
- 持久化结构正确
- Coordinator 已经落地

这三项是整个长期演进最关键的基础。
