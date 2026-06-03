# HoloAI 结构化执行与 Prompt 拆解实施方案 V3

> 状态：最终审查收敛版，可进入实施前评审。
> 当前日期口径：2026-06-03。
> 来源：吸收 V2、GLM/Claude/Codex 多轮审查结论后重写正文，不再依赖末尾审查记录补丁。

## 1. 目标

HoloAI 当前能把用户自然语言命中到模块级 intent，例如：

```text
record_expense
record_income
create_task
```

但还不能结构化支持模块内部执行参数：

```text
分期记账：总金额、期数、手续费、首期日期、按月拆分
重复任务：重复类型、间隔 interval、周几、每月日期
```

本方案目标是在不继续膨胀 `intent_recognition` prompt 的前提下，新增轻量 action parser，让以下用户输入变成真实可执行数据：

```text
我买了个沙发，总价2000，分三期，0手续费
提醒我每隔三天跟家里打个电话
提醒我每周三跟家里打个电话
每天晚上8点提醒我吃药
每月15号提醒我还信用卡
```

最终用户可见效果：

1. 分期记账：AI 生成待确认卡片，用户确认后创建真实分期组。
2. 重复任务：AI 生成待确认卡片，用户确认后创建真实 `RepeatRule`。
3. prompt 拆解：总路由不再承载所有字段，分期/重复字段由专用 parser 补充。
4. 上线后后端 prompt 和 iOS fallback 保持同步，避免本地能测、生产不生效。

## 2. 非目标

第一阶段不做：

```text
分三期，每两周一期
分四期，每季度一期
每 10 天一期的分期交易
每隔 2 周的周三提醒我
每隔 2 周的周一和周三提醒我
每月第二个周一提醒我
工作日且跳过节假日
重复 N 次后结束
复杂 RRULE
分期 pending 卡片打开 AddTransactionSheet 编辑
```

这些输入必须触发澄清、降级或暂不支持提示，不能静默按近似规则落库。

## 3. 核心架构

### 3.1 总体链路

```text
用户输入
  -> AIProvider.parseUserInputBatch(intent_recognition)
  -> ConversationCoordinator 保存 intentCallLog
  -> 本地判断是否需要 action parser
      -> 普通记账 / 普通任务：不追加 LLM 调用
      -> 分期记账候选：finance_action_parser
      -> 重复任务候选：task_action_parser
  -> action parser 返回补充字段
  -> ConversationCoordinator 合并 extractedData/renderData
  -> 生成 pending AIExecutionItem
  -> TransactionChatCard / TaskChatCard 展示待确认卡片
  -> 用户点击确认
  -> ChatViewModel.confirmPendingTransaction / confirmPendingTask
  -> IntentRouter.shared.route(...)
  -> 本地确定性落库
```

### 3.2 设计原则

1. `intent_recognition` 只做粗路由和基础字段抽取。
2. action parser 只补字段，不重新决定业务 intent。
3. action parser 失败时不直接落库，只能降级为普通 pending、追问或暂不支持。
4. 用户确认时不再调用 LLM。
5. 分期金额、尾差、重复日期计算由 iOS 本地确定性代码完成。
6. 后端 prompt 与 iOS fallback 必须同时更新。
7. 后端改动必须部署后才能声明线上生效。

## 4. 当前代码事实

### 4.1 AI 链路

关键文件：

```text
Holo/Holo APP/Holo/Holo/Services/AI/AIProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/OpenAICompatibleProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/MockAIProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/ConversationCoordinator.swift
Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift
Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift
Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift
```

现状：

1. `AIProvider.parseUserInputBatch(_ input:context:)` 没有 prompt type 参数。
2. `HoloBackendAIProvider.parseUserInputBatch` 固定加载 `.intentRecognition`，固定 `purpose: .intent`。
3. `OpenAICompatibleProvider.parseUserInputBatch` 固定加载 `.intentRecognition`。
4. `ConversationProcessResult` 已有 `intentCallLog`。
5. `MockAIProvider` 实现了 `parseUserInputBatch`，新增协议方法时也必须同步实现。

### 4.2 后端 prompt 链路

关键文件：

```text
HoloBackend/src/app.js
HoloBackend/src/config.js
HoloBackend/src/admin/adminRoutes.js
HoloBackend/src/prompts/defaultPrompts.json
HoloBackend/src/prompts/promptRegistry.js
HoloBackend/src/providers/mockChatProvider.js
```

现状：

1. `/v1/ai/chat/completions` 按 `request.purpose` 查 `config.routes[purpose]`。
2. 未注册 purpose 会返回 `UNKNOWN_PURPOSE`。
3. `config.routes` 当前没有 `finance_action_parser` 和 `task_action_parser`。
4. `adminRoutes.normalizePurpose` 当前手写白名单，且遗漏已有 `thought_voice_summary`、`memory_observer`。
5. `promptRegistry` 的可管理 prompt type 来自 `defaultPrompts.json` 的 key。

### 4.3 分期财务

关键文件：

```text
Holo/Holo APP/Holo/Holo/Models/FinanceRepository.swift
Holo/Holo APP/Holo/Holo/Models/Transaction.swift
Holo/Holo APP/Holo/Holo/Views/AddTransaction/TransactionSaveHandler.swift
```

已有能力：

```swift
func addInstallmentTransactions(
    totalAmount: Decimal,
    feePerPeriod: Decimal,
    periods: Int,
    type: TransactionType,
    category: Category,
    account: Account,
    startDate: Date,
    note: String?,
    remark: String? = nil
) async throws -> [Transaction]
```

事实：

1. 分期按月创建：`Calendar.current.date(byAdding: .month, value: i, to: startDate)`。
2. `FinanceRepository.addInstallmentTransactions` 已有本地尾差吸收逻辑。
3. `Transaction.isInstallment` 由 `installmentGroupId != nil` 推导。

### 4.4 重复任务

关键文件：

```text
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataClass.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataProperties.swift
Holo/Holo APP/Holo/Holo/Models/CoreDataStack+TodoEntities.swift
Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift
Holo/Holo APP/Holo/Holo/Views/Tasks/AddTaskSheet.swift
```

当前缺口：

```text
RepeatRule 没有 interval 字段。
```

当前 `calculateNextRawDate`：

```swift
case .daily:
    return calendar.date(byAdding: .day, value: 1, to: fromDate)
case .weekly:
    return calendar.date(byAdding: .weekOfYear, value: 1, to: fromDate)
case .monthly:
    return calendar.date(byAdding: .month, value: 1, to: fromDate)
case .yearly:
    return calendar.date(byAdding: .year, value: 1, to: fromDate)
case .custom:
    return nextCustomDate(from: fromDate, calendar: calendar)
```

第一阶段新增：

```text
RepeatRule.interval: Int16，默认 1。
```

但 `custom` 第一阶段不使用 interval，继续用 1-7 天扫描下一个选中周几。

## 5. 数据契约

### 5.1 finance_action_parser 输出

只输出 LLM 应负责识别的字段：

```json
{
  "amount": "2000",
  "type": "expense",
  "note": "沙发",
  "transactionDate": "2026-06-03",
  "categoryCandidate": "家具",
  "installmentEnabled": "true",
  "installmentTotalAmount": "2000",
  "installmentPeriods": "3",
  "installmentFeePerPeriod": "0",
  "installmentFirstDueDate": "2026-06-03"
}
```

字段说明：

| 字段 | 类型 | 要求 |
|------|------|------|
| `amount` | String Decimal | 与总额一致，供既有记账链路兼容 |
| `type` | `expense/income` | 分期第一阶段只允许 expense |
| `note` | String | 商品/服务说明 |
| `transactionDate` | ISO date | 默认今天 |
| `categoryCandidate` | String | 可为空 |
| `installmentEnabled` | `"true"` / `"false"` | 分期命中为 true |
| `installmentTotalAmount` | String Decimal | 总金额 |
| `installmentPeriods` | String Int | 2...36 |
| `installmentFeePerPeriod` | String Decimal | 未说手续费时默认为 0 |
| `installmentFirstDueDate` | ISO date | 默认交易日期 |

不得由 LLM 输出：

```text
installmentPeriodAmounts
installmentIntervalUnit
installmentIntervalValue
```

iOS 本地派生并写入 renderData：

```text
installmentPeriodAmounts
installmentRemainderPolicy
installmentSchedulePreview
installmentSummary
```

### 5.2 task_action_parser 输出

```json
{
  "title": "跟家里打电话",
  "dueDate": "2026-06-03T20:00:00+08:00",
  "repeatEnabled": "true",
  "repeatType": "daily",
  "repeatInterval": "3",
  "repeatWeekdays": "",
  "repeatMonthDay": "",
  "repeatSummary": "每隔 3 天"
}
```

支持映射：

| 用户表达 | `repeatType` | `repeatInterval` | 其他字段 |
|----------|--------------|------------------|----------|
| 每天 | `daily` | `1` | 空 |
| 每隔 3 天 | `daily` | `3` | 空 |
| 每周三 | `custom` | `1` | `repeatWeekdays=4` |
| 每周一三五 | `custom` | `1` | `repeatWeekdays=2,4,6` |
| 每月 15 号 | `monthly` | `1` | `repeatMonthDay=15` |

不支持映射：

| 用户表达 | 处理 |
|----------|------|
| 每隔 2 周的周三 | 追问或暂不支持 |
| 每隔 2 周的周一和周三 | 追问或暂不支持 |
| 每月第二个周一 | 追问或暂不支持 |
| 工作日跳过节假日 | 追问或暂不支持 |

### 5.3 renderData 约定

分期 pending 卡片 renderData：

```text
confirmationStatus=pending
pendingKind=transaction
installmentEnabled=true
installmentTotalAmount=2000
installmentPeriods=3
installmentFeePerPeriod=0
installmentFirstDueDate=2026-06-03
installmentPeriodAmounts=666.67,666.67,666.66
installmentSummary=按月分 3 期，0 手续费
```

重复任务 pending 卡片 renderData：

```text
confirmationStatus=pending
pendingKind=task
repeatEnabled=true
repeatType=daily
repeatInterval=3
repeatWeekdays=
repeatMonthDay=
repeatSummary=每隔 3 天
```

## 6. iOS 架构改造

### 6.1 PromptManager

修改文件：

```text
Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift
```

新增 PromptType：

```swift
case financeActionParser = "finance_action_parser"
case taskActionParser = "task_action_parser"
```

新增版本：

```swift
.financeActionParser: 1
.taskActionParser: 1
```

新增 fallback 模板：

1. `finance_action_parser`：只输出 JSON object，字段限于 §5.1。
2. `task_action_parser`：只输出 JSON object，字段限于 §5.2。
3. 模板必须明确“不支持时返回 needsClarification=true 或 unsupportedReason”，不能假装支持。

### 6.2 AIProvider

修改文件：

```text
Holo/Holo APP/Holo/Holo/Services/AI/AIProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/OpenAICompatibleProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/MockAIProvider.swift
```

新增 provider-agnostic 类型：

```swift
enum AIActionParserKind: Sendable {
    case financeInstallment
    case taskRepeat

    var promptType: PromptManager.PromptType {
        switch self {
        case .financeInstallment: return .financeActionParser
        case .taskRepeat: return .taskActionParser
        }
    }
}
```

新增协议方法：

```swift
func parseActionInput(
    _ input: String,
    context: UserContext,
    kind: AIActionParserKind
) async throws -> AIParseBatch
```

默认实现不应静默返回成功：

```swift
extension AIProvider {
    func parseActionInput(
        _ input: String,
        context: UserContext,
        kind: AIActionParserKind
    ) async throws -> AIParseBatch {
        throw APIError.serverError("当前 Provider 不支持结构化执行解析")
    }
}
```

`HoloBackendAIProvider` 映射：

```swift
private extension AIActionParserKind {
    var backendPurpose: HoloBackendPurpose {
        switch self {
        case .financeInstallment: return .financeActionParser
        case .taskRepeat: return .taskActionParser
        }
    }
}
```

`HoloBackendPurpose` 新增：

```swift
case financeActionParser = "finance_action_parser"
case taskActionParser = "task_action_parser"
```

`parseActionInput` 必须：

1. 加载 `kind.promptType`。
2. 使用 `AIUserContextMessageBuilder` 构建上下文。
3. 使用 `responseFormat: .jsonObject`。
4. 写入 `lastCallLog.type = kind.promptType.rawValue`。
5. 调用既有 `parseBatchFromJSON`。

`OpenAICompatibleProvider` 必须新增非流式 JSON 调用，不使用 streaming 拼文本替代。

`MockAIProvider` 必须覆盖至少两个样例：

```text
沙发 2000 分三期 0 手续费
每隔三天跟家里打电话
```

### 6.3 ConversationCoordinator

修改文件：

```text
Holo/Holo APP/Holo/Holo/Services/AI/ConversationCoordinator.swift
```

新增日志字段：

```swift
struct ConversationProcessResult {
    var intentCallLog: LLMCallLog?
    var actionParserCallLog: LLMCallLog?
}
```

注意：`intentCallLog` 已存在，只新增 `actionParserCallLog`。

新增判断：

```swift
private func actionParserKind(
    for item: AIParseItem,
    originalText: String
) -> AIActionParserKind? {
    if item.intent.isFinance,
       Self.looksLikeInstallment(originalText, data: item.extractedData) {
        return .financeInstallment
    }

    if item.intent == .createTask,
       Self.looksLikeRepeatTask(originalText, data: item.extractedData) {
        return .taskRepeat
    }

    return nil
}
```

触发判断输入必须是：

```text
原始用户文本 + intent_recognition 返回的 intent/extractedData
```

不能只靠本地关键词，也不能在第一次 LLM 之前判断。

合并策略：

1. action parser 返回成功时，用补充字段覆盖原 item 的同名字段。
2. 保留原 item 的 `intent`。
3. 保留 `confirmationStatus=pending`。
4. action parser 失败时：
   - 如果原 item 可作为普通 pending，则继续普通 pending。
   - 如果用户明确要求不支持范围，例如“每两周一期分期”，返回澄清/暂不支持，不落库。

### 6.4 IntentRouter

修改文件：

```text
Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift
```

财务分期：

1. 当 `installmentEnabled == "true"` 且 intent 为 expense 时，走分期创建。
2. 校验 `installmentPeriods` 为 2...36。
3. 校验 `installmentTotalAmount > 0`。
4. 校验 `installmentFeePerPeriod >= 0`。
5. 分类沿用当前记账分类匹配逻辑。
6. 调用 `FinanceRepository.addInstallmentTransactions(...)`。
7. route result 回写首笔 transaction id 或分期 group id。

重复任务：

1. 当 `repeatEnabled == "true"` 且 intent 为 createTask 时，创建任务后创建 repeat rule。
2. `repeatType=daily` 使用 `repeatInterval`。
3. `repeatType=custom` 使用 `repeatWeekdays`，interval 固定 1。
4. `repeatType=monthly` 使用 `repeatMonthDay`，interval 固定 1。
5. 不支持的组合直接抛出可读错误，不落库。

### 6.5 ChatViewModel

修改文件：

```text
Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift
```

`confirmPendingTask` 必须按 `confirmPendingTransaction` 的安全级别加固：

1. 使用 `confirmingItemIds` 去重。
2. 异步内重读 `latestExecutionBatch(for:)`。
3. 确认 item 仍是 pending。
4. 成功后回写 `taskId/entityType/entityId/confirmationStatus=confirmed`。
5. 失败后回写该卡片为 failed，并写入 `errorText`。

### 6.6 ChatCardData 和卡片 UI

修改文件：

```text
Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift
Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TransactionChatCard.swift
Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TaskChatCard.swift
Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift
```

`TransactionChatCardData` 新增：

```swift
let installmentEnabled: Bool
let installmentTotalAmount: String?
let installmentPeriods: Int?
let installmentFeePerPeriod: String?
let installmentSummary: String?
let installmentPeriodAmounts: [String]
```

`TaskChatCardData` 新增：

```swift
let repeatEnabled: Bool
let repeatType: String?
let repeatInterval: Int?
let repeatWeekdays: [Int]
let repeatMonthDay: Int?
let repeatSummary: String?
```

分期 pending 卡片第一阶段采用方案 A：

```text
installmentEnabled=true && confirmationStatus=pending 时，隐藏或禁用打开 AddTransactionSheet 的编辑入口。
```

分类不准时，只允许在卡片内更新 `renderData`，不能打开 `AddTransactionSheet`。

## 7. Core Data 与重复规则

### 7.1 RepeatRule interval 字段

修改文件：

```text
Holo/Holo APP/Holo/Holo/Models/CoreDataStack+TodoEntities.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataProperties.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataClass.swift
Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift
```

新增字段：

```text
RepeatRule.interval: Int16，默认 1。
```

若当前工程使用 xcdatamodel 文件，也需要在模型中新增 `interval` 属性，并提供轻量迁移。

Swift 访问口径：

```swift
var repeatInterval: Int {
    max(1, Int(interval))
}
```

日期计算：

```swift
case .daily:
    return calendar.date(byAdding: .day, value: repeatInterval, to: fromDate)
case .weekly:
    return calendar.date(byAdding: .weekOfYear, value: repeatInterval, to: fromDate)
case .monthly:
    return calendar.date(byAdding: .month, value: repeatInterval, to: fromDate)
case .yearly:
    return calendar.date(byAdding: .year, value: repeatInterval, to: fromDate)
case .custom:
    return nextCustomDate(from: fromDate, calendar: calendar)
```

`custom` 不使用 interval。

### 7.2 TodoRepository

`createRepeatRule` 新增参数：

```swift
interval: Int = 1
```

写入：

```swift
rule.interval = Int16(max(1, interval))
```

现有调用点：

1. UI 手动创建重复规则：传默认 1。
2. AI 重复任务确认：按 `repeatInterval` 传入。
3. 更新重复规则时保持现有 interval，除非明确编辑 interval。

## 8. 后端改造

### 8.1 config routes

修改文件：

```text
HoloBackend/src/config.js
```

新增：

```js
finance_action_parser: {
  provider: process.env.HOLO_FINANCE_ACTION_PARSER_PROVIDER ?? process.env.HOLO_INTENT_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
  model: process.env.HOLO_FINANCE_ACTION_PARSER_MODEL ?? process.env.HOLO_INTENT_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
  temperature: Number(process.env.HOLO_FINANCE_ACTION_PARSER_TEMPERATURE ?? 0),
  maxTokens: Number(process.env.HOLO_FINANCE_ACTION_PARSER_MAX_TOKENS ?? 512),
},
task_action_parser: {
  provider: process.env.HOLO_TASK_ACTION_PARSER_PROVIDER ?? process.env.HOLO_INTENT_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
  model: process.env.HOLO_TASK_ACTION_PARSER_MODEL ?? process.env.HOLO_INTENT_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
  temperature: Number(process.env.HOLO_TASK_ACTION_PARSER_TEMPERATURE ?? 0),
  maxTokens: Number(process.env.HOLO_TASK_ACTION_PARSER_MAX_TOKENS ?? 512),
},
```

### 8.2 prompt registry

修改文件：

```text
HoloBackend/src/prompts/defaultPrompts.json
HoloBackend/src/prompts/promptRegistry.js
```

`defaultPrompts.json` 新增 key：

```json
{
  "finance_action_parser": "...",
  "task_action_parser": "..."
}
```

`PROMPT_VERSIONS` 新增：

```js
finance_action_parser: 1,
task_action_parser: 1,
```

因为 `PROMPT_TYPES = Object.keys(defaultPrompts)`，新增 key 后后台 prompt 列表会自动出现。

### 8.3 admin purpose 动态校验

修改文件：

```text
HoloBackend/src/admin/adminRoutes.js
```

把手写白名单：

```js
function normalizePurpose(value) {
  if (["chat", "intent", "insight"].includes(value)) {
    return value;
  }
  return "chat";
}
```

改为基于 `config.routes`：

```js
function normalizePurpose(value, config) {
  if (value && Object.prototype.hasOwnProperty.call(config.routes, value)) {
    return value;
  }
  return "chat";
}
```

调用点传入 `config`：

```js
const purpose = normalizePurpose(body.get("purpose") ?? "chat", config);
```

这会同时修复已有 `thought_voice_summary`、`memory_observer` 在 admin 测试中被降级为 `chat` 的旧问题。

### 8.4 mock provider

修改文件：

```text
HoloBackend/src/providers/mockChatProvider.js
HoloBackend/tests/chat.test.js
HoloBackend/tests/prompts.test.js
```

后端 mock 必须支持：

```text
purpose=finance_action_parser
purpose=task_action_parser
```

并返回 JSON object，供后端测试验证 route 和 prompt 链路。

## 9. 实施阶段

### Phase 0：测试基线

目标：先写失败测试，锁定当前缺口。

新增或修改测试：

```text
HoloBackend/tests/chat.test.js
HoloBackend/tests/prompts.test.js
Holo/Holo APP/Holo/HoloTests/VerifyChatCardData.swift
Holo/Holo APP/Holo/HoloTests/RepeatRuleIntervalTests.swift
```

测试点：

1. 后端未知 purpose 返回 `UNKNOWN_PURPOSE`。
2. 新 purpose 注册后不返回 `UNKNOWN_PURPOSE`。
3. `normalizePurpose` 支持所有 `config.routes`。
4. `ChatCardData` 能解析分期字段。
5. `ChatCardData` 能解析重复字段。
6. `RepeatRule.daily interval=3` 下一日期为 +3 天。
7. `RepeatRule.custom weekdays` 不受 interval 影响。

### Phase 1：RepeatRule.interval

实施：

1. Core Data 模型新增 `interval`。
2. `RepeatRule+CoreDataProperties` 新增属性与安全访问器。
3. `calculateNextRawDate` 使用 interval。
4. `TodoRepository.createRepeatRule` 支持 interval。
5. 手动 UI 调用保持默认 1。

验收：

```text
每天 interval=1 行为不变。
每隔 3 天完成后下一次 +3 天。
每周三 custom 仍找下一个周三。
```

### Phase 2：后端 prompt/purpose

实施：

1. `config.js` 新增两个 purpose route。
2. `defaultPrompts.json` 新增两个 prompt。
3. `promptRegistry.js` 新增版本号。
4. `adminRoutes.normalizePurpose` 改动态 route 判断。
5. `mockChatProvider` 支持两个 purpose。
6. 后端测试覆盖 prompt 和 purpose。

本地验收：

```bash
cd HoloBackend
npm test
```

上线验收：

```text
GET /v1/prompts/finance_action_parser
GET /v1/prompts/task_action_parser
POST /v1/ai/chat/completions purpose=finance_action_parser
POST /v1/ai/chat/completions purpose=task_action_parser
```

注意：Phase 2 有后端改动，必须部署后端。只提交 GitHub 不等于线上生效。

### Phase 3：iOS provider/action parser

实施：

1. `PromptManager` 新增 PromptType、版本、fallback 模板。
2. `AIProvider` 新增 `AIActionParserKind` 和 `parseActionInput`。
3. `HoloBackendAIProvider` 接后端 purpose。
4. `OpenAICompatibleProvider` 新增非流式 JSON action parser。
5. `MockAIProvider` 新增样例。
6. `ConversationCoordinator` 调用 action parser 并保存 `actionParserCallLog`。

验收：

```text
iOS fallback 路径可解析样例。
后端部署后，HoloBackendAIProvider 可加载远端 prompt 并用新 purpose 返回 JSON。
```

### Phase 4：分期 pending 卡片

实施：

1. `ChatCardData` 增加分期字段。
2. `TransactionChatCard` 展示总额、期数、每期金额、手续费。
3. 分期 pending 卡片隐藏或禁用 sheet 编辑入口。
4. 分类修正只更新卡片 renderData，不打开 `AddTransactionSheet`。

验收：

```text
输入“我买了个沙发，总价2000，分三期，0手续费”
卡片展示“按月分 3 期，0 手续费”
不出现会打开普通记账 sheet 的编辑入口
```

### Phase 5：确认落库

实施：

1. `IntentRouter` 分期字段校验。
2. `IntentRouter` 调 `FinanceRepository.addInstallmentTransactions`。
3. `IntentRouter` 重复任务字段校验。
4. `IntentRouter` 创建 task 后创建 repeat rule。
5. `confirmPendingTask` 补去重、重读、错误回写。

验收：

```text
沙发 2000 分三期确认后创建 3 笔同组交易。
每隔三天跟家里打电话确认后创建 RepeatRule interval=3。
连续点击任务确认不会重复创建。
```

### Phase 6：端到端和部署

实施：

1. 跑 iOS build。
2. 跑后端测试。
3. 部署后端。
4. 验证 live promptVersion 和 purpose。
5. 用真实 HoloAI 输入样例确认 intent 和 action parser 都生效。

iOS build 命令：

```bash
xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-structured-action-build CODE_SIGNING_ALLOWED=NO build
```

## 10. 测试矩阵

### 10.1 分期

| 输入 | 期望 |
|------|------|
| 我买了个沙发，总价2000，分三期，0手续费 | pending 分期卡片，确认后 3 笔同组交易 |
| 买电脑 10000 分 12 期，每期手续费 10 | pending 分期卡片，每期手续费 10 |
| 买沙发 2000 分三期 | 手续费默认为 0 |
| 分三期，每两周一期 | 暂不支持或追问，不落库 |
| 买沙发 2000 分 0 期 | 校验失败，不落库 |

### 10.2 重复任务

| 输入 | 期望 |
|------|------|
| 每隔三天跟家里打电话 | `daily interval=3` |
| 每周三跟家里打电话 | `custom weekdays=4 interval=1` |
| 每周一三五健身 | `custom weekdays=2,4,6 interval=1` |
| 每月15号还信用卡 | `monthly monthDay=15 interval=1` |
| 每隔2周的周三开会 | 追问或暂不支持，不落库 |

### 10.3 prompt 和后端

| 项 | 期望 |
|----|------|
| `/v1/prompts/finance_action_parser` | 200，返回 prompt |
| `/v1/prompts/task_action_parser` | 200，返回 prompt |
| `purpose=finance_action_parser` | 200，JSON object |
| `purpose=task_action_parser` | 200，JSON object |
| admin 测试 `memory_observer` | 不再降级为 chat |

## 11. 风险与缓解

### 11.1 双调用消耗额度

一句分期或重复任务输入会消耗：

```text
intent_recognition 1 次
action_parser 1 次
```

当前后端所有 purpose 共用 `chatRequestsPerMinute/chatRequestsPerDay`。MVP 可接受，但上线说明中要记录：结构化执行请求比普通请求多一次后端调用。

### 11.2 复杂重复语义

`weekly + interval` 当前语义是“从完成日期 + N 周”，不是“固定每 N 周某周几”。所以第一阶段不承诺固定锚点式复杂重复。

### 11.3 分期编辑

第一阶段禁用分期 pending 卡片 sheet 编辑，是为了避免编辑路径绕过 `IntentRouter` 后创建普通交易。后续若要开放，需要扩展 `PendingTransactionPrefill` 和 `AddTransactionSheet` 的分期预填。

### 11.4 后端未部署

新增 prompt/purpose 如果只在本地提交，线上不会生效。Phase 2 后必须部署后端并做 live 验证。

## 12. 最终验收口径

方案进入实施后的最终验收必须同时满足：

1. 后端测试通过。
2. iOS build 通过。
3. live prompt 可访问。
4. live purpose 可调用。
5. 真机或本地运行中：
   - “沙发 2000 分三期 0 手续费”确认后创建真实分期组。
   - “每隔三天跟家里打电话”确认后创建真实 `RepeatRule(interval=3)`。
   - “每周三跟家里打电话”确认后创建 `custom weekdays=[4]`。
6. 分期 pending 卡片不会通过普通 sheet 编辑路径落成普通交易。
7. 连续点击任务确认不会重复创建任务。

## 13. 实施文件清单

### iOS

```text
Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift
Holo/Holo APP/Holo/Holo/Services/AI/AIProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/OpenAICompatibleProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/MockAIProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/ConversationCoordinator.swift
Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift
Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift
Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift
Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TransactionChatCard.swift
Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TaskChatCard.swift
Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataClass.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataProperties.swift
Holo/Holo APP/Holo/Holo/Models/CoreDataStack+TodoEntities.swift
Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift
```

### 后端

```text
HoloBackend/src/config.js
HoloBackend/src/app.js
HoloBackend/src/admin/adminRoutes.js
HoloBackend/src/prompts/defaultPrompts.json
HoloBackend/src/prompts/promptRegistry.js
HoloBackend/src/providers/mockChatProvider.js
HoloBackend/tests/chat.test.js
HoloBackend/tests/prompts.test.js
```

### 测试

```text
Holo/Holo APP/Holo/HoloTests/VerifyChatCardData.swift
Holo/Holo APP/Holo/HoloTests/RepeatRuleIntervalTests.swift
HoloBackend/tests/chat.test.js
HoloBackend/tests/prompts.test.js
```

## 14. 建议实施顺序

1. Phase 0：补测试基线。
2. Phase 1：实现 `RepeatRule.interval`。
3. Phase 2：实现并部署后端 prompt/purpose。
4. Phase 3：实现 iOS action parser 接线。
5. Phase 4：实现卡片展示和分期编辑禁用。
6. Phase 5：实现确认落库和任务确认加固。
7. Phase 6：端到端验证、后端部署、live prompt/purpose 校验。

每个 Phase 独立提交，涉及后端的 Phase 2 和 Phase 6 必须明确区分：

```text
本地测试通过
GitHub 已 push
后端已部署
线上 live 已验证
```

