# HoloAI 结构化执行与 Prompt 拆解方案 V2

> 状态：第二轮修订版，可交给 GLM 进行下一轮对抗性审查。
> 决策更新：第一阶段补 `RepeatRule.interval`，让“每隔三天/每隔 N 天”真实生效。
> 当前日期口径：2026-06-03。

## 1. 核心结论

Holo 底层已经具备两个重要能力：

1. 财务模块已有分期交易字段与 `FinanceRepository.addInstallmentTransactions(...)`。
2. 待办模块已有 `RepeatRule`、重复任务 UI 和完成后生成下一实例的逻辑。

但 HoloAI 目前只会把自然语言命中到模块级意图：

```text
record_expense
record_income
create_task
```

它还不能把用户输入解析为模块内部结构：

```text
分期交易：总金额、期数、手续费、首期日期、按月拆分
重复任务：重复类型、间隔 interval、周几、每月日期、结束日期
```

V2 方案采用：

```text
轻量总路由 + 专用执行解析器 + pending 卡片确认 + 本地确定性落库
```

关键变化：

1. 不再继续膨胀 `intent_recognition`。
2. 新增 `finance_action_parser` 和 `task_action_parser`。
3. 第一阶段明确分期固定为“按月分期”。
4. 第一阶段新增 `RepeatRule.interval`，支持“每隔三天/每隔 N 天”。
5. 结构解析必须发生在 pending 卡片生成前，用户确认时不再调用 LLM。
6. 后端 prompt 与 iOS fallback 必须同步版本，先修复现有 v15/v14 漂移。

## 2. 用户可见目标

### 2.1 AI 分期记账

用户输入：

```text
我买了个沙发，总价2000，分三期，0手续费
```

期望体验：

1. HoloAI 识别为支出待确认。
2. 卡片展示：沙发、总价 2000、3 期、0 手续费、按月分期。
3. 用户点击确认后，账本创建 3 笔同组分期交易。
4. 每笔交易有同一个 `installmentGroupId`。
5. 金额按真实每期金额展示，末期吸收尾差。

第一阶段分期限制：

```text
只支持按月分期。
```

如果用户说：

```text
分三期，每两周一期
分四期，每季度一期
每 10 天一期
```

AI 必须澄清或返回暂不支持，不能静默按月处理。

### 2.2 AI 重复任务

用户输入：

```text
提醒我每周三跟家里打个电话
提醒我每隔三天跟家里打个电话
每天晚上8点提醒我吃药
每月15号提醒我还信用卡
```

期望体验：

1. HoloAI 识别为任务待确认。
2. 卡片展示重复摘要，例如“每周三”“每隔 3 天”“每天 20:00”。
3. 用户点击确认后创建真实 `TodoTask` 和 `RepeatRule`。
4. 完成重复任务后，下一实例按规则生成。

V2 明确支持：

```text
每天
每隔 N 天
每周几
每隔 N 周
每月某日
每隔 N 月
```

第一阶段不支持：

```text
每月第二个周一
工作日且跳过节假日
重复 N 次后结束
复杂 RRULE
```

## 3. 当前代码事实

### 3.1 AI pending 与确认链路

真实链路：

```text
用户输入
  -> ConversationCoordinator.process(...)
  -> AIProvider.parseUserInputBatch(...)
  -> ConversationCoordinator 生成 pending AIExecutionItem
  -> ChatCardData.from(intent:data:) 读取 renderData
  -> TransactionChatCard / TaskChatCard 展示待确认卡片
  -> 用户点击确认
  -> ChatViewModel.confirmPendingTransaction / confirmPendingTask
  -> 重新组 ParsedResult
  -> IntentRouter.shared.route(result)
  -> 真正落库
```

关键文件：

```text
Holo/Holo APP/Holo/Holo/Services/AI/ConversationCoordinator.swift
Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift
Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift
Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift
Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TransactionChatCard.swift
Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TaskChatCard.swift
```

修正后的实施原则：

1. 结构解析发生在 `ConversationCoordinator` 生成 pending item 之前。
2. 结构字段必须进入 `AIParseItem.extractedData` 和 pending `renderData`。
3. 卡片从 `renderData` 展示分期/重复摘要。
4. 用户确认后，`ChatViewModel` 把最新 `renderData` 传给 `IntentRouter.route(...)`。
5. `IntentRouter` 负责最终本地落库，但不能是唯一改动点。

### 3.2 财务分期代码事实

关键文件：

```text
Holo/Holo APP/Holo/Holo/Models/Transaction.swift
Holo/Holo APP/Holo/Holo/Models/CoreDataStack+FinanceEntities.swift
Holo/Holo APP/Holo/Holo/Models/FinanceRepository.swift
```

已有字段：

```swift
installmentGroupId: UUID?
installmentIndex: Int16
installmentTotal: Int16
```

已有方法：

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

限制：

```swift
Calendar.current.date(byAdding: .month, value: i, to: startDate)
```

所以第一阶段分期固定为按月分期。

### 3.3 重复任务代码事实

关键文件：

```text
Holo/Holo APP/Holo/Holo/Models/TodoTaskModels.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataClass.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataProperties.swift
Holo/Holo APP/Holo/Holo/Models/CoreDataStack+TodoEntities.swift
Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift
```

当前 `RepeatRule` 字段：

```text
id
type
weekdays
monthDay
monthWeekOrdinal
monthWeekday
untilCount
untilDate
skipHolidays
skipWeekends
createdAt
task
```

当前缺口：

```text
没有 interval 字段。
```

当前 `nextDueDate(from:)` 硬编码：

```swift
daily   -> +1 day
weekly  -> +1 week
monthly -> +1 month
yearly  -> +1 year
```

V2 决策：

```text
第一阶段新增 RepeatRule.interval: Int16，默认 1。
```

## 4. 架构设计

### 4.1 总体流程

```text
用户输入
  -> intent_recognition
  -> 本地判断是否需要专用 parser
      -> 普通记账/普通任务：不追加 LLM 调用
      -> 分期记账：finance_action_parser
      -> 重复任务：task_action_parser
  -> 合并 parser 字段
  -> 生成 pending 卡片
  -> 用户确认
  -> IntentRouter 本地执行
  -> 更新 executionBatch / linkedEntity
```

### 4.2 Prompt 职责拆分

`intent_recognition`：

1. 只判断意图大类。
2. 保留最小字段：`amount/title/categoryCandidate/dueDate/reminderDate`。
3. 不输出分期细节字段。
4. 不输出重复细节字段。

`finance_action_parser`：

1. 解析普通财务执行字段。
2. 解析分期字段。
3. 处理分期澄清与 unsupported。
4. 输出严格 JSON。

`task_action_parser`：

1. 解析任务标题、日期、提醒、子任务。
2. 解析重复规则字段。
3. 处理重复规则澄清与 unsupported。
4. 输出严格 JSON。

`flexible_query_planner`：

继续只负责财务查询计划，不承接执行型分期记账。

### 4.3 LLM 调用次数

普通执行：

```text
1 次 LLM：intent_recognition
```

分期/重复执行：

```text
第 1 次 LLM：intent_recognition
第 2 次 LLM：finance_action_parser 或 task_action_parser
```

目标：

```text
额外延迟控制在 0.8-2.5 秒。
专用 parser 超时或失败时，fallback 到普通待确认卡，并提示分期/重复规则需要手动补充。
```

建议 UI loading 文案：

```text
正在识别你的指令...
正在解析分期信息...
正在解析重复规则...
```

## 5. Schema 设计

### 5.1 财务分期字段

仍使用 `[String: String]`，第一阶段避免大改历史消息与 batch 序列化。

```text
installmentEnabled              "true" | "false"
installmentTotalAmount          总金额
installmentPeriods              期数，2-60
installmentFeePerPeriod         每期手续费，未提为 0
installmentStartDate            yyyy-MM-dd
installmentIntervalUnit         第一阶段固定 month
installmentIntervalValue        第一阶段固定 1
installmentSummary              卡片摘要
installmentPeriodAmounts        本地计算后的每期金额，逗号分隔
```

示例：

```json
{
  "intent": "record_expense",
  "confidence": 0.95,
  "extractedData": {
    "amount": "2000",
    "note": "沙发",
    "categoryCandidate": "沙发",
    "normalizedCategoryCandidate": "家具",
    "semanticCategoryHint": "购物",
    "installmentEnabled": "true",
    "installmentTotalAmount": "2000",
    "installmentPeriods": "3",
    "installmentFeePerPeriod": "0",
    "installmentStartDate": "2026-06-03",
    "installmentIntervalUnit": "month",
    "installmentIntervalValue": "1",
    "installmentSummary": "总价2000，按月分3期，0手续费"
  },
  "needsClarification": false,
  "clarificationQuestion": null
}
```

澄清规则：

1. 有“分期”但无金额：澄清金额。
2. 有“分期”但无期数：澄清期数。
3. 期数小于 2 或大于 60：澄清或拒绝。
4. 明确非月间隔：返回暂不支持，不要按月落库。
5. 总金额和每期金额同时出现且不一致：澄清。

### 5.2 任务重复字段

```text
repeatEnabled             "true" | "false"
repeatType                daily | weekly | monthly | yearly | custom
repeatInterval            默认 1；每隔 N 天/周/月时为 N
repeatWeekdays            周一=1 ... 周日=7，逗号分隔
repeatMonthDay            1-31
repeatUntilDate           yyyy-MM-dd
repeatSummary             卡片摘要
```

示例：每周三

```json
{
  "intent": "create_task",
  "confidence": 0.95,
  "extractedData": {
    "title": "跟家里打电话",
    "dueDate": "2026-06-03",
    "repeatEnabled": "true",
    "repeatType": "weekly",
    "repeatInterval": "1",
    "repeatWeekdays": "3",
    "repeatSummary": "每周三重复"
  },
  "needsClarification": false,
  "clarificationQuestion": null
}
```

示例：每隔三天

```json
{
  "intent": "create_task",
  "confidence": 0.95,
  "extractedData": {
    "title": "跟家里打电话",
    "dueDate": "2026-06-03",
    "repeatEnabled": "true",
    "repeatType": "daily",
    "repeatInterval": "3",
    "repeatSummary": "每隔3天重复"
  },
  "needsClarification": false,
  "clarificationQuestion": null
}
```

澄清规则：

1. “经常提醒我”没有明确频率：澄清。
2. “每周提醒我”没有周几：澄清。
3. “每月提醒我”没有日期：澄清。
4. `repeatInterval < 1`：拒绝。
5. 第一阶段不输出 `repeatUntilCount`，因为现有 `untilCount` 未实现完成次数追踪。

## 6. 数据模型改造：RepeatRule.interval

### 6.1 新增字段

修改：

```text
Holo/Holo APP/Holo/Holo/Models/CoreDataStack+TodoEntities.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataClass.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataProperties.swift
```

新增 Core Data 属性：

```swift
let ruleInterval = NSAttributeDescription()
ruleInterval.name = "interval"
ruleInterval.attributeType = .integer16AttributeType
ruleInterval.isOptional = false
ruleInterval.defaultValue = 1
repeatRuleAttributes.append(ruleInterval)
```

新增 NSManaged：

```swift
@NSManaged var interval: Int16
```

新增安全计算属性：

```swift
var safeInterval: Int {
    max(Int(interval), 1)
}
```

### 6.2 修改 nextDueDate

当前：

```swift
case .daily:
    return calendar.date(byAdding: .day, value: 1, to: fromDate)
```

修改：

```swift
case .daily:
    return calendar.date(byAdding: .day, value: safeInterval, to: fromDate)

case .weekly:
    return calendar.date(byAdding: .weekOfYear, value: safeInterval, to: fromDate)

case .monthly:
    return calendar.date(byAdding: .month, value: safeInterval, to: fromDate)

case .yearly:
    return calendar.date(byAdding: .year, value: safeInterval, to: fromDate)
```

对于 `custom` + weekdays：

第一阶段保留现有逻辑，不引入“每隔 N 周的自定义周几组合”。AI 的“每隔 N 周”先映射为 `weekly + interval=N`，不带多 weekdays；“每周一三五”仍走 `custom` 或 `weekly + weekdays`，interval 默认 1。

### 6.3 Repository 更新

修改：

```text
Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift
```

`createRepeatRule(...)` 新增参数：

```swift
interval: Int = 1
```

并写入：

```swift
rule.interval = Int16(max(interval, 1))
```

`updateRepeatRuleMonthlyParams(...)` 可暂不处理 interval，或新增独立 `updateRepeatRuleInterval(...)`。

### 6.4 UI 兼容

第一阶段 AI 能写 interval，任务编辑 UI 可以先做到只展示现有重复描述，不必立刻提供完整 interval 编辑器。

但为了避免用户打开编辑页后丢失 interval，以下文件必须至少做到读取/保留：

```text
Holo/Holo APP/Holo/Holo/Views/Tasks/AddTaskSheet.swift
Holo/Holo APP/Holo/Holo/Views/Tasks/TaskDatePickerSheet.swift
Holo/Holo APP/Holo/Holo/Views/Tasks/RepeatPicker.swift
```

最低要求：

1. 打开已有任务时读取 `rule.interval`。
2. 保存任务时不把 interval 重置为 1。
3. displayDescription 显示“每隔 3 天/每隔 2 周/每隔 2 月”。

## 7. iOS 执行链路改造

### 7.1 AIActionParser

新增：

```text
Holo/Holo APP/Holo/Holo/Services/AI/AIActionParser.swift
```

职责：

1. 判断是否需要专用 parser。
2. 调用 provider 获取 `finance_action_parser` 或 `task_action_parser`。
3. 合并字段。
4. 处理超时和 fallback。

触发条件：

财务：

```text
intent 是 record_expense/record_income
并且命中：
分期
分[一二三四五六七八九十0-9]+期
[0-9一二三四五六七八九十]+期
手续费
总价 + 分期语境
```

不允许单独匹配：

```text
期
```

任务：

```text
intent 是 create_task
并且命中：
每天 / 每日
每周 + 周几
每月 + 日期
每隔 + 数字 + 天/周/月
重复
```

反例必须不触发：

```text
今天心情不错
明天有期末考试
我最近状态还行
```

### 7.2 ConversationCoordinator

修改：

```text
Holo/Holo APP/Holo/Holo/Services/AI/ConversationCoordinator.swift
```

在生成 pending `AIExecutionItem` 之前执行：

```swift
let enrichedItems = try await AIActionParser(...).enrichItemsIfNeeded(
    parseBatch.items,
    originalText: text,
    provider: provider
)
```

随后 pending item 使用 enriched `extractedData`。

合并规则：

```text
专用 parser 字段覆盖总路由同名字段。
但 selectedCategoryId、confirmationStatus、用户手动修改字段不得被 parser 覆盖。
```

### 7.3 ChatViewModel

修改：

```text
Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift
```

确认入口已经存在：

```swift
confirmPendingTransaction(from:)
confirmPendingTask(from:)
```

修订要求：

1. 确认时使用最新 message 的 `executionBatch`，避免旧 renderData。
2. 分期/重复字段必须随 `renderData` 进入 `ParsedResult`。
3. 确认阶段不再调用 LLM。
4. 分期确认成功后，如果返回多笔交易，至少保存第一笔 `transactionId`，并建议新增 `installmentGroupId` 字段用于后续跳转整组。

### 7.4 IntentRouter

修改：

```text
Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift
```

财务：

```swift
if data["installmentEnabled"] == "true" {
    return try await handleRecordInstallmentExpense(result)
}
```

任务：

```swift
let task = try todoRepo.createTask(...)
if data["repeatEnabled"] == "true" {
    try createRepeatRuleIfNeeded(task: task, data: data)
}
```

注意：

`IntentRouter` 是确认后的落库执行器，不是 pending 卡片生成入口。实现不能只改 `IntentRouter`。

## 8. 卡片数据与 UI

### 8.1 TransactionCardData

修改：

```text
Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift
```

新增：

```swift
let installmentEnabled: Bool
let installmentPeriods: Int?
let installmentFeePerPeriod: String?
let installmentStartDate: String?
let installmentSummary: String?
let installmentPeriodAmounts: [String]
```

`ChatCardData.from(intent:data:)` 解析：

```swift
installmentEnabled: data["installmentEnabled"] == "true"
installmentPeriods: Int(data["installmentPeriods"] ?? "")
installmentPeriodAmounts: CommaSeparatedParser.parse(data["installmentPeriodAmounts"])
```

### 8.2 TransactionChatCard

修改：

```text
Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TransactionChatCard.swift
```

待确认分期卡片展示：

```text
分期：按月 3 期
手续费：¥0/期
首期：2026-06-03
金额：前2期 ¥666.67，末期 ¥666.66
```

金额展示规则：

1. parser 不计算每期金额。
2. iOS 本地用 Decimal 计算真实每期展示金额。
3. 末期吸收尾差。
4. 不展示会导致合计错误的“每期 ¥666.67”。

### 8.3 TaskCardData

新增：

```swift
let repeatEnabled: Bool
let repeatType: String?
let repeatInterval: Int?
let repeatWeekdays: [Int]
let repeatMonthDay: Int?
let repeatSummary: String?
```

### 8.4 TaskChatCard

待确认重复任务卡片展示：

```text
重复：每周三
提醒：20:00
```

或：

```text
重复：每隔 3 天
```

## 9. 后端 Prompt 改造

修改：

```text
HoloBackend/src/prompts/defaultPrompts.json
HoloBackend/src/prompts/promptRegistry.js
HoloBackend/tests/prompts.test.js
HoloBackend/tests/chat.test.js
```

### 9.1 Prompt types

新增：

```text
finance_action_parser
task_action_parser
```

版本：

```js
const PROMPT_VERSIONS = {
  intent_recognition: 16,
  finance_action_parser: 1,
  task_action_parser: 1,
  memory_insight_generation: 5,
  analysis_prompt: 2,
  annual_review: 1,
  thought_voice_summary: 2,
  flexible_query_planner: 1,
  memory_observer: 1,
};
```

### 9.2 intent_recognition 瘦身

本次应同步修改：

1. 后端 `intent_recognition` 从 v15 升到 v16。
2. iOS `PromptManager` 先从 v14 对齐到 v15，再本次升到 v16。
3. `intent_recognition` 不再输出分期和重复细节字段。
4. 分期/重复细节只由专用 parser 输出。

保留字段：

```text
amount
note
categoryCandidate
normalizedCategoryCandidate
semanticCategoryHint
title
dueDate
reminderDate
subtasks
analysisDomain
queryDomain
queryGoal
rawConstraints
```

新增字段不要放在总路由：

```text
installment*
repeat*
```

## 10. iOS PromptManager 同步

修改：

```text
Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift
```

必须新增：

```swift
case financeActionParser = "finance_action_parser"
case taskActionParser = "task_action_parser"
```

版本：

```swift
.intentRecognition: 16
.financeActionParser: 1
.taskActionParser: 1
```

注意：

当前 iOS `.intentRecognition` 仍是 14，而后端是 15。本次实现第一步必须先确认 v15 内容已同步，再统一升 v16。

## 11. 测试计划

### 11.1 后端测试

运行：

```bash
cd /Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend
npm test
```

新增/修改测试：

1. `/v1/prompts` 包含 `finance_action_parser`。
2. `/v1/prompts` 包含 `task_action_parser`。
3. `/v1/prompts/intent_recognition` version 为 16。
4. `/v1/prompts/finance_action_parser` version 为 1。
5. `/v1/prompts/task_action_parser` version 为 1。
6. `finance_action_parser` prompt 包含 `installmentTotalAmount/installmentPeriods/installmentFeePerPeriod/installmentIntervalUnit`。
7. `task_action_parser` prompt 包含 `repeatType/repeatInterval/repeatWeekdays/repeatMonthDay`。
8. `intent_recognition` 不包含分期/重复细节 schema。

### 11.2 iOS 单元/独立测试

建议新增：

```text
AIActionParserTriggerTests
RepeatRuleIntervalTests
InstallmentAmountPreviewTests
IntentRouterInstallmentTests
IntentRouterRepeatTaskTests
ChatCardDataStructuredExecutionTests
```

关键用例：

```text
沙发2000分三期0手续费
手机6000分12期每期手续费10
每周三提醒我跟家里打电话
每隔三天提醒我跟家里打电话
每天晚上8点提醒我吃药
每月15号提醒我还信用卡
今天心情不错
明天有期末考试
```

验证：

1. 分期文本触发 `finance_action_parser`。
2. “期末考试”不触发分期 parser。
3. 分期卡片展示末期尾差。
4. 确认后创建多笔同组交易。
5. `repeatInterval=3` 的 daily rule 下一次日期为 3 天后。
6. 每周三 rule 下一次日期正确。
7. 打开/保存已有重复任务不会把 interval 重置为 1。

### 11.3 编译验证

运行：

```bash
xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-ai-structured-execution-v2-build CODE_SIGNING_ALLOWED=NO build
```

如果 `xcodebuild test` 因 scheme 无 Test action 失败，不作为阻断；用 build + standalone Swift 测试补足。

## 12. 部署要求

本方案会修改：

```text
HoloBackend/src/prompts/defaultPrompts.json
HoloBackend/src/prompts/promptRegistry.js
```

因此必须后端发版。否则生产环境仍使用旧 prompt，HoloAI 不会识别新 parser。

发版后验证：

```text
/v1/health
/v1/prompts/intent_recognition
/v1/prompts/finance_action_parser
/v1/prompts/task_action_parser
```

必须确认：

```text
intent_recognition version >= 16
finance_action_parser version = 1
task_action_parser version = 1
```

## 13. 分阶段实施计划

### Phase 0：对齐 prompt 版本与模型缺口

目标：

1. 确认后端 v15 与 iOS v14 漂移内容。
2. 将 iOS fallback 先对齐到 v15。
3. 确认 `RepeatRule.interval` 新增路径。

输出：

```text
PromptManager intentRecognition 对齐 v15
RepeatRule interval 改造 checklist
```

### Phase 1：新增 RepeatRule.interval

文件：

```text
CoreDataStack+TodoEntities.swift
RepeatRule+CoreDataClass.swift
RepeatRule+CoreDataProperties.swift
TodoRepository.swift
AddTaskSheet.swift
TaskDatePickerSheet.swift
RepeatPicker.swift
```

验收：

1. 现有 daily/weekly/monthly/yearly interval=1 行为不变。
2. daily interval=3 生成 3 天后任务。
3. 打开/保存任务不丢 interval。

### Phase 2：后端新增专用 parser prompt

文件：

```text
HoloBackend/src/prompts/defaultPrompts.json
HoloBackend/src/prompts/promptRegistry.js
HoloBackend/tests/prompts.test.js
HoloBackend/tests/chat.test.js
```

验收：

```bash
npm test
```

### Phase 3：iOS 新增 AIActionParser

文件：

```text
AIActionParser.swift
ConversationCoordinator.swift
PromptManager.swift
AIProvider.swift
HoloBackendAIProvider.swift
OpenAICompatibleProvider.swift
```

验收：

1. 分期/重复文本会二次 parser。
2. 普通文本不二次 parser。
3. parser 结果进入 pending renderData。

### Phase 4：AI 分期记账落库与卡片

文件：

```text
IntentRouter.swift
FinanceRepository.swift
ChatCardData.swift
TransactionChatCard.swift
ChatViewModel.swift
```

验收：

1. 分期卡片展示总价、期数、手续费、按月、每期金额。
2. 确认后创建多笔同组分期交易。
3. periods 校验 2-60。
4. 非月间隔不静默落库。

### Phase 5：AI 重复任务落库与卡片

文件：

```text
IntentRouter.swift
TodoRepository.swift
ChatCardData.swift
TaskChatCard.swift
ChatViewModel.swift
```

验收：

1. 每周三任务创建 repeat rule。
2. 每隔三天任务创建 `repeatType=daily, interval=3`。
3. 完成后下一实例日期正确。
4. 有提醒时间时通知调度不退化。

### Phase 6：Prompt 瘦身与漂移防护

目标：

1. `intent_recognition` 去掉分期/重复细节。
2. 专用 parser 字段成为唯一结构化来源。
3. 后端与 iOS fallback 版本测试固化。

## 14. 风险与缓解

### 风险 1：Core Data interval 迁移影响旧任务

缓解：

1. `interval` 默认 1。
2. `safeInterval = max(Int(interval), 1)`。
3. 旧任务行为保持不变。

### 风险 2：二次 LLM 调用延迟

缓解：

1. 只在结构化触发词命中时二次调用。
2. 专用 parser prompt 短小。
3. 超时 fallback 到普通待确认卡。

### 风险 3：分期金额显示与落库金额不一致

缓解：

1. 本地统一计算每期金额。
2. 卡片展示 `installmentPeriodAmounts`。
3. 末期吸收尾差。

### 风险 4：prompt 双源冲突

缓解：

1. `intent_recognition` 不输出 `installment*` 和 `repeat*`。
2. 专用 parser 字段覆盖同名基础字段。
3. 用户确认后手动修改字段不被 parser 覆盖。

### 风险 5：后端未发版

缓解：

1. 方案实施完成后必须部署 HoloBackend。
2. 验证 live prompt versions。
3. changelog 明确提示“后端改动已发版/需发版”。

## 15. GLM 下一轮审查重点

请重点审查：

1. `RepeatRule.interval` 新增字段与轻量迁移是否足够安全。
2. `custom + weekdays` 与 `weekly + interval` 的边界是否清晰。
3. `ConversationCoordinator -> ChatViewModel -> IntentRouter` 的确认链路是否描述完整。
4. `intent_recognition` 不输出分期/重复细节是否会影响普通卡片体验。
5. 分期按月限制是否写得足够明确，是否会误导用户。
6. 分期金额尾差展示方案是否和 `FinanceRepository.addInstallmentTransactions(...)` 一致。
7. Phase 0-6 的实施顺序是否能避免 prompt 双源冲突。

## 16. 最终建议

V2 可以进入下一轮审查。相比初稿，关键阻断点已收敛：

1. “每隔三天”不再悬空，明确通过 `RepeatRule.interval` 实现。
2. 分期明确限定为按月。
3. 执行链路改为 pending 前解析、确认时本地落库。
4. prompt 拆解不再和总路由抢字段。
5. 卡片字段与金额尾差展示进入实施范围。

如果 GLM 下一轮没有新的阻断意见，建议把 V2 作为实施基线。

---

## 17. 第二轮对抗性审查记录（Claude 审查，2026-06-03）

> 基于对 ChatViewModel、AIProvider、RepeatRule custom 类型的逐文件验证。V2 已修正第一轮 C-1~C-4 关键问题，本轮聚焦新引入的细节缺陷和遗漏。

### CRITICAL — 方案必须修正

#### C2-1：AIProvider 硬编码 intent_recognition——专用 parser 无法调用

**V2 声明**（§7.1）：`AIActionParser` 调用 `provider` 获取 `finance_action_parser` 或 `task_action_parser`。

**实际代码验证**：

两个 provider 都把 prompt 类型硬编码为 `.intentRecognition`：

- `HoloBackendAIProvider.swift:48`：`let systemPrompt = await loadManagedPrompt(.intentRecognition)` — 硬编码。
- `OpenAICompatibleProvider.swift:40`：`let systemPrompt = try PromptManager.shared.loadPrompt(.intentRecognition)` — 硬编码。

`parseUserInputBatch` 没有接受 prompt 类型的参数。且 `HoloBackendPurpose` 枚举只有 5 个 case（`chat/intent/insight/thoughtVoiceSummary/memoryObserver`），后端按 purpose 路由 model 和 temperature。

**影响**：V2 列出的 Phase 3 文件包括 `AIProvider.swift`、`HoloBackendAIProvider.swift`、`OpenAICompatibleProvider.swift`，但没有说明具体改什么。这不是"新增一个方法"那么简单——需要：

1. `AIProvider` 协议的 `parseUserInputBatch` 新增 `promptType` 参数（或新增独立方法如 `parseWithCustomPrompt`）。
2. 两个实现类都要改。
3. 后端 `HoloBackendPurpose` 新增 case（如 `.financeActionParser` / `.taskActionParser`）。
4. 后端 `src/config.js` 为新 purpose 配置 model/temperature。
5. 调用方（ConversationCoordinator + 新 AIActionParser）需要传 promptType。

**建议修正**：在 §7.1 或 Phase 3 中补充：
- `AIProvider` 协议改动方案（新增参数 vs 新增方法，推荐后者避免影响现有调用点）。
- 后端 `config.js` 的 purpose 路由配置。
- 后端 `app.js` 是否需要新路由（现有 `/v1/ai/chat/completions` 是否足够）。

#### C2-2：`custom` 与 `weekly` 的映射规则有语义冲突

**V2 声明**（§6.2）：

```text
AI 的"每隔 N 周"先映射为 weekly + interval=N，不带多 weekdays；
"每周一三五"仍走 custom 或 weekly + weekdays，interval 默认 1。
```

**实际代码验证**：

当前 `calculateNextRawDate` 中 `.weekly` 的实现是：

```swift
case .weekly:
    return calendar.date(byAdding: .weekOfYear, value: 1, to: fromDate)
```

`.weekly` 完全忽略 `weekdays` 字段——只做 `+7 天`。而 `.custom` 才是"找下一个选中周几"的逻辑（1-7 天内扫描）。

同时，`AddTaskSheet` 在保存时只对 `.custom` 传 weekdays：

```swift
weekdays: repeatType == .custom ? Array(selectedWeekdays) : nil
```

所以当前实际语义是：

| 类型 | 行为 | 是否支持多周几 |
|------|------|---------------|
| `.weekly` | 从当前日期加 N 周 | 不支持（weekdays 被丢弃） |
| `.custom` | 找下一个选中周几（1-7天内） | 支持 |

V2 的映射问题：

1. **"每隔2周的周三" → `weekly + interval=2`**：`calculateNextRawDate` 会变成 `calendar.date(byAdding: .weekOfYear, value: 2, to: fromDate)`。这实际上是从当前完成日期加 14 天——**如果用户中途某次晚了 3 天才完成，下一次日期会漂移**。这不是"每隔2周的周三"，而是"距上一次完成后 2 周"。
2. **"每周一三五" → `custom`**：正确，但 V2 写的是"custom 或 weekly + weekdays"——`weekly + weekdays` 在代码中不工作（weekly 忽略 weekdays）。
3. **"每隔2周的周一和周三" → `custom + interval=2`**：V2 明确说第一阶段不做，这是合理的。但方案应明确写出"每隔 N 周 + 多周几"不支持。

**建议修正**：

1. §6.2 去掉"或 weekly + weekdays"的表述，明确 `custom` 才是支持多周几的类型。
2. 补充说明：`weekly + interval=N` 的语义是"距上一次完成 N 周后"，不是"固定每 N 周的某一天"。如果产品需要"固定每 2 周的周三"，需要用不同实现（锚定起始日期的周计算）。
3. §5.2 澄清规则中增加"每隔 N 周 + 多周几"暂不支持。

#### C2-3：`dismissPendingCardAfterEdit` 路径会丢失分期信息

**实际代码验证**：`ChatViewModel` 中存在第三个确认路径 `dismissPendingCardAfterEdit(from:)`（lines 736-775）：

- 用户点击待确认卡片 → 打开 `AddTransactionSheet` 编辑并保存 → `AddTransactionSheet` 自行调用 `addTransaction` 创建交易 → `dismissPendingCardAfterEdit` 仅将卡片标记为已确认。
- 这个路径**完全绕过 `IntentRouter`**。

**影响**：如果用户对 AI 分期卡片点了编辑（而非直接确认），分期信息不会传递给 `AddTransactionSheet`，`AddTransactionSheet` 会创建一笔普通交易而非分期组。

**建议修正**：方案应在 §7.3 或 §8 中明确：

- 第一阶段：分期卡片的编辑按钮应跳转到专用分期编辑页，或直接禁用编辑入口只保留确认/取消。
- 任务卡片同理：如果用户编辑了重复任务的标题/日期，`RepeatRule` 不会被自动创建。

### HIGH — 重要但非阻断

#### H2-1：`installmentPeriodAmounts` 字段自相矛盾

**V2 §5.1** 把 `installmentPeriodAmounts` 列为 parser 输出字段。但 **§8.2** 写"parser 不计算每期金额，iOS 本地用 Decimal 计算真实每期展示金额"。

如果 parser 不计算，就不应该出现在 parser schema 中。如果要让本地计算，字段应该叫别的名字（如 `computedPeriodAmounts`），且不经过 LLM。

**建议**：从 §5.1 schema 中移除 `installmentPeriodAmounts`，改为 §8.2 中本地计算后直接写入 `renderData`，卡片从 `renderData` 读取。

#### H2-2：`installmentIntervalUnit` 和 `installmentIntervalValue` 是无用字段

第一阶段分期固定为按月（`intervalUnit=month, intervalValue=1`）。这两个字段在 parser schema 中永远是固定值，增加了 LLM 输出复杂度但无实际收益。

**建议**：第一阶段从 parser schema 中移除，在代码中硬编码。如果第二阶段要支持非月间隔再添加。字段名 `installmentPeriods` 已经隐含了"按月分 N 期"的语义。

#### H2-3：`confirmPendingTask` 缺少安全机制

**实际代码对比**：

| 安全机制 | `confirmPendingTransaction` | `confirmPendingTask` |
|---------|---------------------------|---------------------|
| 去重守卫（`confirmingItemIds`） | ✅ 有 | ❌ 没有 |
| 过期数据重读 | ✅ 有 | ❌ 没有 |
| 错误时 renderData 更新 | ✅ 有（`writeTransactionError`） | ❌ 没有（只设 `errorMessage`） |
| AI 创建标记 | ✅ 有 | ❌ 没有 |

用户快速连续点击确认按钮时，任务可能被创建两次。这不是 V2 引入的问题，但 V2 在同一代码路径上添加重复任务逻辑，应一并加固。

**建议**：Phase 5 实施前至少补充 `confirmPendingTask` 的去重守卫和过期数据重读。

#### H2-4：Phase 2→3 依赖但未标注阻断条件

Phase 2（后端 prompt）完成后需要**部署**才能让 Phase 3（iOS parser）使用新 prompt。如果 Phase 3 在后端部署前测试，iOS 只能走本地 fallback——如果 fallback 不完整，测试结果不可靠。

**建议**：在 Phase 2 验收条件中增加"后端已部署且 `/v1/prompts/finance_action_parser` 可访问"。Phase 3 验收应分两步：先验证 fallback 路径，再验证后端路径。

#### H2-5：V2 §4.1 流程图中"本地判断"时机不明确

V2 写"intent_recognition → 本地判断是否需要专用 parser"。但 `intent_recognition` 的 LLM 返回 `AIParseBatch`，这个返回值已经被 JSON decode 成 Swift struct。"本地判断"发生在第一次 LLM 调用返回之后、第二次调用之前。

方案应明确：触发词判断的输入是**原始用户文本** + **LLM 返回的 intent**，而非仅用户文本。当前 §7.1 的伪代码 `switch item.intent` 已正确实现这一点，但 §4.1 的流程图和 §4.3 的说明应更精确。

### MEDIUM — 值得注意

#### M2-1：`weekly + interval` 的漂移语义应写入产品说明

V2 §2.2 支持"每隔 N 周"并映射为 `weekly + interval=N`。但当前 `calculateNextRawDate` 对 weekly 的实现是 `date(byAdding: .weekOfYear, value: N, to: lastCompletedDate)`——基于完成日期而非固定周期。

如果用户"每隔 2 周的周三提醒我开会"，但某次晚了 3 天（周六）才完成，下一次会变成两周后的周六而非周三。这与用户预期的"固定每 2 周三"不同。

这不是第一阶段的阻断问题（"每隔 N 天"不受此影响），但应在方案或 PRD 中注明这个语义差异。

#### M2-2：后端 `config.js` 可能需要新增 purpose 配置

`HoloBackend/src/config.js` 按 purpose 路由不同的 model/temperature。新增 `finance_action_parser` 和 `task_action_parser` 需要：
- 在 config.js 中注册新的 purpose。
- 决定使用哪个 model 和 temperature（建议与 intent 一致）。
- 确认后端 `/v1/ai/chat/completions` 能接受新 purpose 值。

### 审查结论

| 等级 | # | 问题 | 一句话 |
|------|---|------|--------|
| CRITICAL | C2-1 | AIProvider 硬编码 prompt 类型 | 专用 parser 无法直接调用，需改协议+后端 purpose |
| CRITICAL | C2-2 | custom vs weekly 语义冲突 | weekly 忽略 weekdays，"每隔 N 周"会漂移 |
| CRITICAL | C2-3 | dismissPendingCardAfterEdit 绕过 IntentRouter | 编辑分期卡片会创建普通交易 |
| HIGH | H2-1 | installmentPeriodAmounts 自相矛盾 | schema 说 parser 输出，正文说本地计算 |
| HIGH | H2-2 | 两个固定值字段无收益 | intervalUnit/Value 永远固定，白增复杂度 |
| HIGH | H2-3 | confirmPendingTask 缺安全机制 | 无去重守卫，连续点击会创建重复任务 |
| HIGH | H2-4 | Phase 2→3 部署依赖未标注 | 后端不部署，iOS 只能用 fallback 测试 |
| HIGH | H2-5 | "本地判断"时机不精确 | 应明确触发词判断发生在 LLM 返回后 |
| MEDIUM | M2-1 | weekly+interval 漂移语义 | 基于完成日期而非固定周期 |
| MEDIUM | M2-2 | 后端 config.js 需配置 | 新 purpose 需要 model/temperature 路由 |

**核心判断**：V2 相比初稿有本质性进步——执行链路、RepeatRule interval、分期按月限制、prompt 拆解策略都已正确。本轮 C2-1（AIProvider 协议改造）是最关键的遗漏——它是专用 parser 能否被调用的基础设施，方案必须补充。C2-3（编辑路径绕过 IntentRouter）和 C2-2（custom/weekly 语义）影响产品正确性。建议修正后可以作为实施基线。

---

## 18. 第三轮对抗性审查记录（Codex 复审，2026-06-03）

> 本轮目标：复核第 17 节第二轮审查意见是否成立，并把可执行的修订口径收敛到下一版方案。结论不是推翻 V2，而是要求 V2 在进入实施前补齐 4 个硬约束。

### 18.1 复审结论

**Conditional Go**。

V2 的核心架构方向可以保留：

1. 总路由继续使用 `intent_recognition`，不把所有分期/重复字段塞回总 prompt。
2. 命中候选动作后再用专用 parser 补充结构化字段。
3. 分期固定按月，真实落库由 iOS 本地确认路径完成。
4. 重复任务第一阶段补 `RepeatRule.interval`，让“每隔三天/每隔 N 天”真实生效。
5. prompt 拆解方向成立，但必须补齐 iOS provider、后端 purpose 和 prompt registry 的真实接线。

进入实施前必须修正：

| 编号 | 结论 | 修订要求 |
|------|------|----------|
| R3-1 | C2-1 成立 | 新增专用 JSON parser 能力，不能只写 `AIActionParser` 抽象 |
| R3-2 | C2-2 成立且需收缩范围 | 第一阶段只承诺“每隔 N 天”，不要承诺“固定每隔 N 周/月的某周几” |
| R3-3 | C2-3 成立 | 分期卡片编辑路径必须处理，否则编辑后会创建普通交易 |
| R3-4 | H2-3 成立 | `confirmPendingTask` 必须补去重、重读和错误回写 |
| R3-5 | H2-1/H2-2 成立 | LLM schema 删除本地计算字段和固定字段 |
| R3-6 | H2-4/M2-2 成立 | 后端 prompt/purpose 部署是 Phase 3 的前置条件 |

### 18.2 R3-1：专用 parser 接线必须写成基础设施改造

第 17 节指出 `AIProvider.parseUserInputBatch` 硬编码 `.intentRecognition`，复核成立。

实际代码边界：

- `AIProvider` 协议只有 `parseUserInputBatch(_ input:context:)`，没有 promptType 或 purpose 参数。
- `HoloBackendAIProvider.parseUserInputBatch` 固定加载 `.intentRecognition`，并固定使用 `purpose: .intent`。
- `OpenAICompatibleProvider.parseUserInputBatch` 固定加载 `.intentRecognition`。
- `HoloBackendPurpose` 当前只有 `chat / intent / insight / thought_voice_summary / memory_observer`。
- 后端 `/v1/ai/chat/completions` 会按 `request.purpose` 查 `config.routes[purpose]`，没有 route 会返回 `UNKNOWN_PURPOSE`。
- 后端 `adminRoutes.normalizePurpose` 当前只允许 `chat / intent / insight`，新增 purpose 后后台测试入口也会被静默降级到 `chat`。

第三轮建议采用“新增窄方法”，不要直接扩展 `parseUserInputBatch` 参数：

```swift
protocol AIProvider {
    func parseActionInput(
        _ input: String,
        context: UserContext,
        promptType: PromptManager.PromptType,
        backendPurpose: HoloBackendPurpose?
    ) async throws -> AIParseBatch
}
```

如果要避免协议暴露 `HoloBackendPurpose`，也可以定义 provider-agnostic 的 `AIActionParserKind`：

```swift
enum AIActionParserKind {
    case financeInstallment
    case taskRepeat
}
```

再由各 provider 内部映射：

| kind | iOS PromptType | 后端 purpose | response_format |
|------|----------------|--------------|-----------------|
| financeInstallment | `finance_action_parser` | `finance_action_parser` | json_object |
| taskRepeat | `task_action_parser` | `task_action_parser` | json_object |

实施必须覆盖：

1. `PromptManager.PromptType` 新增 `financeActionParser`、`taskActionParser`。
2. `PromptManager.promptVersions` 增加两个新版本号。
3. iOS fallback prompt 增加两个新模板。
4. `HoloBackendPurpose` 增加两个新 case。
5. `HoloBackend/src/config.js` 增加两个 purpose route，建议沿用 intent 的 provider/model/temperature/maxTokens。
6. `HoloBackend/src/prompts/promptRegistry.js` 注册两个 prompt type、默认版本和默认模板。
7. `HoloBackend/src/admin/adminRoutes.js` 的 `normalizePurpose` 支持两个新 purpose。
8. `MockAIProvider` 和后端 mock provider 增加测试样例，避免测试只能覆盖 fallback。

非阻断但要写入风险：新增 parser 调用仍走后端 chat completions 入口，会消耗同一 `chatRequestsPerMinute/chatRequestsPerDay` 配额。用户一句话如果先走 intent、再走 action parser，相当于两次后端调用。MVP 可以接受，但方案要把双调用带来的限额和延迟写清楚。

### 18.3 R3-2：重复任务第一阶段必须收缩到“每隔 N 天”

第 17 节指出 `custom` 与 `weekly` 的语义冲突，复核成立；并且 V2 应进一步收缩承诺。

用户本轮选择的是 B：补 `RepeatRule.interval`，让“每隔三天/每隔 N 天”生效。这个选择并不等价于支持所有“每隔 N 周/月”的固定日历语义。

第一阶段建议只承诺：

| 用户表达 | 结构化结果 | 是否支持 |
|----------|------------|----------|
| 每天 | `daily, interval=1` | 支持 |
| 每隔 3 天 | `daily, interval=3` | 支持 |
| 每周三 | `custom, weekdays=[4], interval=1` | 支持 |
| 每周一三五 | `custom, weekdays=[2,4,6], interval=1` | 支持 |
| 每月 15 号 | `monthly, monthDay=15, interval=1` | 支持 |
| 每隔 2 周 | `weekly, interval=2` | 可选支持，但语义是“完成后 +2 周” |
| 每隔 2 周的周三 | 不落结构化，追问或降级 | 第一阶段不支持 |
| 每隔 2 周的周一和周三 | 不落结构化，追问或降级 | 第一阶段不支持 |

必须从 V2 正文删除或改写：

```text
"每周一三五"仍走 custom 或 weekly + weekdays
```

应改为：

```text
"每周一三五"只走 custom + weekdays，interval=1；weekly 不承载 weekdays。
```

同时，`RepeatRule.calculateNextRawDate` 的新增 interval 应只改现有类型的步长，不改变现有锚点模型：

```swift
case .daily:
    return calendar.date(byAdding: .day, value: interval, to: fromDate)
case .weekly:
    return calendar.date(byAdding: .weekOfYear, value: interval, to: fromDate)
case .monthly:
    return calendar.date(byAdding: .month, value: interval, to: fromDate)
case .yearly:
    return calendar.date(byAdding: .year, value: interval, to: fromDate)
case .custom:
    return nextCustomDate(from: fromDate, calendar: calendar)
```

注意：`custom` 第一阶段不使用 interval。若未来要支持“每隔 2 周的周三”，需要新增 anchor date / scheduled date 语义，而不是简单把 interval 塞进 `custom`。

### 18.4 R3-3：分期卡片编辑路径必须二选一

第 17 节指出 `dismissPendingCardAfterEdit` 绕过 `IntentRouter`，复核成立。

当前路径是：

1. 聊天卡片打开 `AddTransactionSheet`。
2. `AddTransactionSheet` 自己保存交易。
3. 保存后 `dismissPendingCardAfterEdit` 只把卡片标记为已确认。
4. 这条路不会经过 `confirmPendingTransaction`，也不会经过未来的分期落库逻辑。

下一版方案必须二选一，不要留成“实现时看情况”。

推荐薄切片方案：

**方案 A：第一阶段分期卡片禁用 sheet 编辑入口。**

- 分期 pending 卡片只提供“确认”和“取消”。
- 分类不准时，只允许在卡片内用 picker 更新 `renderData`，不打开 `AddTransactionSheet`。
- 点击确认仍走 `confirmPendingTransaction`，由统一路径创建分期组。
- 优点：范围小，最不容易把分期写成普通交易。
- 缺点：用户不能在 sheet 里改金额/期数。

完整体验方案：

**方案 B：扩展 `PendingTransactionPrefill`，让 sheet 支持分期预填。**

- `PendingTransactionPrefill` 增加 `isInstallment`、`installmentPeriods`、`feePerPeriod`、`installmentGroupId` 或等价字段。
- `AddTransactionSheet` 初始化时读取这些字段，打开后显示分期 UI。
- sheet 保存后必须仍创建分期组，而不是普通交易。
- `dismissPendingCardAfterEdit` 需要回写分期 group/entity 信息。
- 优点：体验完整。
- 缺点：会触碰 `ChatView`、`AddTransactionSheet`、`TransactionSaveHandler` 和卡片回写，第一阶段成本更高。

第三轮建议：若目标是尽快让“我买了沙发 2000 分三期 0 手续费”真实可用，先采用方案 A。把分期编辑能力放 Phase 6 或 Phase 7。

### 18.5 R3-4：`confirmPendingTask` 加固应列入 Phase 5 前置

第 17 节指出 `confirmPendingTask` 缺少安全机制，复核成立。

当前 `confirmPendingTransaction` 已有：

- `confirmingItemIds` 去重守卫。
- `latestExecutionBatch(for:)` 重读最新状态。
- 错误时通过 `writeTransactionError` 回写卡片。
- AI 创建来源标记。

但 `confirmPendingTask` 直接使用旧 `message.executionBatch`，没有去重、没有重读、错误只写全局 `errorMessage`。

新增重复任务后，`confirmPendingTask` 将承担真实落库，必须在 Phase 5 前补齐：

1. 使用同一 `confirmingItemIds` 或新增 `confirmingTaskItemIds`。
2. 进入异步任务前插入 item id。
3. 异步内先重读 `latestExecutionBatch(for:)`，确认仍是 pending。
4. 错误时把对应卡片改为 failed，并写入 `errorText`。
5. 成功后回写 `taskId`、`entityType`、`entityId`、`confirmationStatus=confirmed`。

否则“重复任务”还没开始复杂，连续点两次确认就可能创建两个任务。

### 18.6 R3-5：分期 parser schema 继续瘦身

第 17 节 H2-1/H2-2 复核成立。

第一阶段 `finance_action_parser` 的 LLM schema 不应包含：

```text
installmentPeriodAmounts
installmentIntervalUnit
installmentIntervalValue
```

原因：

1. 每期金额和尾差必须由 iOS 用 Decimal 本地计算，不能让 LLM 算。
2. 第一阶段固定按月分期，interval unit/value 没有信息增益。
3. parser 输出字段越多，越容易出现 schema 看起来完整、业务却需要二次纠错的问题。

建议保留的 parser 字段：

```text
amount
type
note
transactionDate
categoryCandidate
isInstallment
installmentTotalAmount
installmentPeriods
installmentFeePerPeriod
installmentFirstDueDate
```

本地派生字段写入 renderData：

```text
installmentPeriodAmounts
installmentRemainderPolicy
installmentSchedulePreview
```

### 18.7 R3-6：后端部署依赖必须写成验收条件

第 17 节 H2-4/M2-2 复核成立。

因为后端 prompt 和 purpose 都在 `/v1/ai/chat/completions` 与 `/v1/prompts/<type>` 链路上生效，Phase 2 不能只写“新增 prompt 文件”。必须写成：

1. 后端新增 prompt type。
2. 后端新增 purpose route。
3. 后端 admin 测试入口可选择新 purpose。
4. 后端部署完成。
5. live 验证：

```text
GET /v1/prompts/finance_action_parser
GET /v1/prompts/task_action_parser
POST /v1/ai/chat/completions purpose=finance_action_parser
POST /v1/ai/chat/completions purpose=task_action_parser
```

Phase 3 iOS 验收必须分两条：

| 路径 | 验收 |
|------|------|
| fallback | 断网或 prompt 获取失败时，iOS 本地 prompt 能解析样例 |
| backend | 后端已部署后，能从 `/v1/prompts/<type>` 获取新版 prompt，并用新 purpose 返回 JSON |

如果后端不部署，iOS 只能验证 fallback，不能声明“专用 parser 已上线”。

### 18.8 R3-7：新增 parser 会覆盖 `lastCallLog`，调试日志需调整

这是第三轮新增发现。

当前 `ConversationCoordinator.process` 在第一次解析后立即保存：

```swift
let parseBatch = try await provider.parseUserInputBatch(text, context: userContext)
let intentLog = provider.lastCallLog
```

如果未来流程变成：

```text
intent_recognition -> action_parser -> execution
```

provider 的 `lastCallLog` 会在第二次 LLM 调用时被覆盖。若 action parser 在 `ConversationCoordinator` 内调用，需要保留两个日志：

- intent recognition log
- action parser log

否则排查时只能看到最后一次 parser 调用，容易丢掉“为什么命中 finance/task”的证据。

建议下一版方案新增：

```swift
struct ConversationProcessResult {
    var intentCallLog: LLMCallLog?
    var actionParserCallLog: LLMCallLog?
}
```

或更通用：

```swift
var llmCallLogs: [LLMCallLog]
```

MVP 可以只存 `intentCallLog` + `actionParserCallLog` 两个字段，避免一次性改太多历史日志结构。

### 18.9 下一版方案必须改动的正文位置

请在 V3 中至少修改以下章节，而不是只把审查意见贴在末尾：

| 章节 | 必改内容 |
|------|----------|
| §2.2 | 重复任务范围收缩：第一阶段只强承诺“每隔 N 天”和现有每周几 |
| §4.1/§4.3 | 明确 action parser 发生在第一次 LLM 返回之后 |
| §5.1 | 删除 `installmentPeriodAmounts`、`installmentIntervalUnit`、`installmentIntervalValue` |
| §5.2 | 删除或降级“每隔 N 周/月固定周几”的承诺 |
| §6.2 | 改写 `custom` vs `weekly` 映射，删除 `weekly + weekdays` |
| §7.1 | 补 `AIProvider` 专用 JSON parser 方法、PromptType、purpose、response_format |
| §7.3/§8 | 明确分期卡片编辑路径选 A 或 B |
| §9 | 增加 `actionParserCallLog` 或 `llmCallLogs` |
| §10/§11 | 后端 prompt registry、config.js、admin normalizePurpose、部署验收 |
| §12 | `confirmPendingTask` 加固列入任务结构化前置 |
| §13 | 增加 live prompt/purpose 验证和双调用限额风险 |

### 18.10 第三轮最终结论

V2 不是推倒重来，而是需要生成 V3 后再给 GLM 审查。

Go 条件：

1. 专用 parser 的真实调用链补齐：iOS PromptType + provider 方法 + backend purpose + config route + prompt registry。
2. 重复任务范围收缩到“每隔 N 天”以及现有“每周几/每月几号”，不要承诺复杂固定周期。
3. 分期卡片编辑路径明确采用 A 或 B。
4. `confirmPendingTask` 在重复任务落库前补齐确认安全机制。
5. 分期 schema 删除本地计算字段和固定字段。
6. 后端部署和 live 验证写入 Phase 验收。

满足以上 6 条后，方案可进入实施；否则实现很可能出现”parser 写了但调不到””每隔周几语义漂移””编辑分期后变普通交易”这三类用户可见失败。

---

## 19. 第三轮对抗性审查记录（Claude 复审 Codex §18，2026-06-03）

> 本轮对 Codex §18 的 6 条硬约束和 R3-7 进行逐条代码验证。Codex 审查整体质量高，但有 1 个事实错误和 3 个细节需要纠正。

### 总体判断

§18 的 6 条 Go 条件（R3-1 到 R3-6）**全部成立**，建议直接采纳。但 R3-7（日志覆盖）存在关键事实错误。以下逐条给出验证结论。

### R3-1 验证：AIProvider 硬编码——✅ 成立，且遗漏比描述更多

Codex 指出 `parseUserInputBatch` 硬编码 `.intentRecognition`，需新增专用 parser 方法。**完全成立**。

代码验证补充两个 Codex 未提及的点：

**1. `normalizePurpose` 白名单比描述的更陈旧**

Codex 说 `normalizePurpose` “当前只允许 `chat / intent / insight`”——这确实成立，但问题比描述的更大：

```js
// adminRoutes.js:318-324
function normalizePurpose(value) {
  if ([“chat”, “intent”, “insight”].includes(value)) {
    return value;
  }
  return “chat”;
}
```

这个白名单甚至没有包含**已存在**的 `thought_voice_summary` 和 `memory_observer`。意味着当前后台测试这两个 purpose 时就被静默降级为 `chat`。这不是新增问题，但 V3 应一次性修成动态取 `config.routes` 的 keys，而不是继续手动维护白名单。

**2. 速率限额共用的定量影响**

所有 purpose 共用同一 `chatRequestsPerMinute=20` / `chatRequestsPerDay=50`（per-device）。用户说”沙发 2000 分三期”会消耗 2 次后端调用。按当前限额，连续 25 条分期记账就耗尽日限额。MVP 可接受，但 V3 应在风险章节注明。

### R3-2 验证：重复任务收缩到”每隔 N 天”——✅ 成立，建议完全采纳

Codex 的范围收缩表与代码完全一致。补充一点验证：

`custom` 类型在 `calculateNextRawDate` 中走 `nextCustomDate`，用 1-7 天扫描找下一个选中周几。加入 `interval` 后，`custom` 分支的第一阶段正确做法是**不改**——interval 只影响 `daily/weekly/monthly/yearly` 的步长，不影响 `custom` 的扫描逻辑。

Codex §18.3 的代码片段：

```swift
case .custom:
    return nextCustomDate(from: fromDate, calendar: calendar)
```

与现有代码一致，正确。V3 应明确：**`custom` 类型第一阶段不使用 interval 字段**。

### R3-3 验证：分期卡片编辑路径——✅ 成立，方案 A 推荐正确

代码验证确认 `dismissPendingCardAfterEdit`（ChatViewModel.swift:736-775）路径确实绕过 IntentRouter：

1. `AddTransactionSheet` 自行调用 `FinanceRepository.addTransaction` 创建普通交易。
2. `dismissPendingCardAfterEdit` 仅标记 `confirmationStatus = “confirmed”`。
3. 不经过 `confirmPendingTransaction`，不经过 `IntentRouter.route`。

分期卡片走这条路径会丢失全部分期信息，创建单笔普通交易。Codex 推荐方案 A（禁用编辑入口）作为第一阶段选择是正确的。

补充建议：方案 A 的实现方式应是在 `TransactionChatCard` 中对 `installmentEnabled == true` 的 pending 卡片隐藏或禁用编辑按钮，而非在 `AddTransactionSheet` 中判断。这样改动面最小。

### R3-4 验证：confirmPendingTask 加固——✅ 成立

代码验证确认 `confirmPendingTask`（ChatViewModel.swift:511-576）确实缺少：

| 安全机制 | confirmPendingTransaction | confirmPendingTask |
|---------|--------------------------|-------------------|
| 去重守卫 | ✅ `confirmingItemIds` | ❌ |
| 过期数据重读 | ✅ `latestExecutionBatch(for:)` | ❌ |
| 错误时 renderData 回写 | ✅ `writeTransactionError` | ❌ |
| AI 创建标记 | ✅ `markTransactionAsAICreated` | ❌ |

Codex 建议在 Phase 5 前补齐，正确。但建议进一步：**在 Phase 5 实施时就直接补齐，而不是作为前置任务单独做**——因为改动只在 `confirmPendingTask` 一个方法内，拆成两个 PR 反而增加协调成本。

### R3-5 验证：分期 schema 瘦身——✅ 成立

`installmentPeriodAmounts`、`installmentIntervalUnit`、`installmentIntervalValue` 从 LLM schema 中移除，完全正确。补充验证：

- `FinanceRepository.addInstallmentTransactions` 内部已经做了 `perPeriodBase = totalAmount / Decimal(periods)` + 末期尾差吸收。本地计算逻辑已存在，不需要 LLM 参与。
- Codex 建议的保留字段列表中 `isInstallment` 比 V2 的 `installmentEnabled` 更简洁，建议 V3 统一用 `installmentEnabled`（与 `repeatEnabled` 对称）。

### R3-6 验证：后端部署依赖——✅ 成立

代码验证确认：

1. `config.routes[purpose]` 对未知 purpose 返回 `undefined`，直接 throw `UNKNOWN_PURPOSE`（HTTP 400）。
2. 不部署新 prompt 和 purpose，iOS 只能走 fallback。
3. 后端部署是 Phase 3 的硬前置。

Codex 建议的 Phase 2 验收条件（live prompt + purpose 验证）正确，V3 应直接采纳。

### R3-7 验证：lastCallLog 覆盖——⚠️ 部分成立，但核心建议有事实错误

**Codex 声称**（§18.7）：

> “provider 的 `lastCallLog` 会在第二次 LLM 调用时被覆盖。若 action parser 在 `ConversationCoordinator` 内调用，需要保留两个日志”

**实际代码**：

```swift
// ConversationCoordinator.swift:46
let parseBatch = try await provider.parseUserInputBatch(text, context: userContext)
let intentLog = provider.lastCallLog    // ← 立即快照
```

`ConversationCoordinator` 在第一次 LLM 调用后**立即把 `lastCallLog` 捕获到局部变量 `intentLog`**。后续所有路径都通过这个局部变量传递，不受第二次调用覆盖的影响。

同时，`ConversationProcessResult` **已经有 `intentCallLog` 字段**：

```swift
struct ConversationProcessResult {
    // ...
    var intentCallLog: LLMCallLog?    // 已存在
}
```

还有已定义但未使用的 `LLMLog` struct：

```swift
struct LLMLog: Codable, Equatable {
    let calls: [LLMCallLog]
}
```

**Codex 建议新增 `intentCallLog + actionParserCallLog` 是错的**——`intentCallLog` 已经存在。实际需要的只是新增 `actionParserCallLog: LLMCallLog?` 一个字段，并在 Coordinator 中第二次调用后同样做快照。

**§18.9 的改位表也有误**：把 `actionParserCallLog` 写在 §9（后端 Prompt 改造），但这是 iOS 侧的日志改造，应该在 §7（iOS 执行链路）或单独一节。

### 新增发现：N3-1——`normalizePurpose` 已有的白名单 bug 应在 V3 顺带修复

`normalizePurpose` 白名单缺少 `thought_voice_summary` 和 `memory_observer`，导致这两个已有 purpose 在后台测试时被静默降级为 `chat`。这不是 V3 引入的 bug，但既然 V3 要新增两个 purpose 并修白名单，应一并修复现有遗漏。

建议改为动态取值：

```js
function normalizePurpose(value, config) {
  if (Object.keys(config.routes).includes(value)) {
    return value;
  }
  return “chat”;
}
```

### 新增发现：N3-2——Codex 建议的 `parseActionInput` 方法签名需注意 MockAIProvider

Codex §18.2 推荐新增 `parseActionInput` 方法到 `AIProvider` 协议。但当前 `MockAIProvider`（如果存在）也需实现。V3 应注明所有 `AIProvider` 实现类都需要更新，并确保 mock 能返回有效 JSON 供测试使用。

### 审查结论

| 条目 | Codex 判定 | Claude 验证 | 备注 |
|------|-----------|------------|------|
| R3-1 AIProvider 硬编码 | 成立 | ✅ 成立+补充 | `normalizePurpose` 白名单遗漏比描述更多；速率限额影响需写入风险 |
| R3-2 重复任务收缩 | 成立 | ✅ 完全正确 | `custom` 不用 interval 应明确写出 |
| R3-3 编辑路径 | 成立 | ✅ 正确 | 实现方式建议在卡片层禁用而非 sheet 层 |
| R3-4 confirmPendingTask 加固 | 成立 | ✅ 正确 | 建议合并到 Phase 5 一起做 |
| R3-5 Schema 瘦身 | 成立 | ✅ 正确 | `installmentEnabled` vs `isInstallment` 命名需统一 |
| R3-6 部署依赖 | 成立 | ✅ 完全正确 | |
| R3-7 日志覆盖 | 成立 | ⚠️ 方向正确但事实错误 | `intentCallLog` 已存在，只需加 `actionParserCallLog`；改位应从 §9 移到 §7 |

**新增**：

| 条目 | 说明 |
|------|------|
| N3-1 | `normalizePurpose` 白名单已有 bug，V3 应一并修复 |
| N3-2 | `parseActionInput` 需覆盖所有 AIProvider 实现类含 Mock |

**核心判断**：Codex §18 的 6 条 Go 条件**全部通过代码验证**，方向正确、建议可执行。唯一的实质性修正是 R3-7——`intentCallLog` 已存在于 `ConversationProcessResult`，V3 只需新增 `actionParserCallLog`。其余建议可直接作为 V3 的修订基线。方案在满足 Codex 6 条 + 本轮 2 条补充后，可以进入实施。

---

## 20. 最后一轮收口审查（Codex 最终复核，2026-06-03）

> 本轮目标：复核 §19 对 §18 的纠偏是否成立，并给出是否可以生成 V3 实施基线的最终结论。

### 20.1 最终结论

**Conditional Go，可生成 V3。**

§19 对 §18 的复核基本成立，尤其是对 R3-7 的纠偏是必要的：`ConversationCoordinator` 已在第一次 `parseUserInputBatch` 后立即快照 `intentLog`，且 `ConversationProcessResult.intentCallLog` 已存在。因此 V3 不应写“新增 intentCallLog”，而应写：

```swift
var intentCallLog: LLMCallLog?       // 已存在，保留
var actionParserCallLog: LLMCallLog? // 新增
```

或在后续更大重构中改为：

```swift
var llmCallLogs: [LLMCallLog]
```

MVP 推荐前者，改动面更小。

### 20.2 接受 §19 的修正点

| 条目 | 最终判断 | V3 处理 |
|------|----------|---------|
| R3-1 provider/purpose 接线 | 接受 | 按 §18 保留，并补 §19 的 admin 白名单和限额说明 |
| R3-2 重复任务范围收缩 | 接受 | 第一阶段只强承诺“每隔 N 天”；`custom` 不使用 interval |
| R3-3 分期编辑路径 | 接受 | 第一阶段采用方案 A：分期 pending 卡片禁用 sheet 编辑入口 |
| R3-4 `confirmPendingTask` 加固 | 接受 | 直接并入 Phase 5，不单独拆前置 PR |
| R3-5 schema 瘦身 | 接受 | 删除本地计算字段和固定字段，命名统一为 `installmentEnabled` |
| R3-6 后端部署依赖 | 接受 | Phase 2 必须包含部署和 live purpose 验证 |
| R3-7 日志覆盖 | 修正后接受 | 只新增 `actionParserCallLog`，不要重复新增 `intentCallLog` |
| N3-1 `normalizePurpose` 旧 bug | 接受 | 改成基于 `config.routes` 动态判断 |
| N3-2 Mock provider 覆盖 | 接受 | 所有 `AIProvider` 实现都要实现新 parser 方法 |

### 20.3 最终实施基线

V3 应直接吸收以下最终基线，不再继续追加“审查记录式”的正文：

1. **执行链路**
   - `intent_recognition` 只负责粗路由。
   - 第一次 LLM 返回后，本地结合原始文本和 intent 判断是否需要 action parser。
   - `finance_action_parser` / `task_action_parser` 只补字段，不重新决定业务 intent。
   - action parser 失败时降级到普通 pending/追问，不直接落库。

2. **Provider 和后端 purpose**
   - `AIProvider` 新增窄方法，例如 `parseActionInput(_:context:kind:)`。
   - `HoloBackendAIProvider` 通过 `purpose=finance_action_parser/task_action_parser` 调后端。
   - `OpenAICompatibleProvider` 通过本地 prompt + `response_format=json_object` 调用。
   - `MockAIProvider` 必须实现样例返回。
   - 后端 `config.routes`、`promptRegistry`、admin 测试入口同时更新。

3. **分期**
   - 第一阶段只支持“按月分 N 期，0 或固定每期手续费”。
   - parser 输出 `installmentEnabled`、总额、期数、每期手续费、首期日期。
   - 每期金额、尾差、展示 schedule 由 iOS 本地 Decimal 计算。
   - 分期 pending 卡片第一阶段禁用 sheet 编辑入口，只允许确认/取消；分类修正必须在卡片内更新 renderData，不打开 `AddTransactionSheet`。

4. **重复任务**
   - 第一阶段支持：
     - 每天 / 每隔 N 天：`daily + interval=N`
     - 每周几 / 每周多天：`custom + weekdays + interval=1`
     - 每月几号：`monthly + interval=1`
   - 第一阶段不支持：
     - 每隔 N 周的某周几
     - 每隔 N 周的多个周几
     - 固定锚点式“每两周周三”
   - `custom` 类型不使用 interval，保持现有 1-7 天扫描逻辑。

5. **确认安全**
   - `confirmPendingTask` 按 `confirmPendingTransaction` 的标准补齐去重、重读、错误回写。
   - 重复任务落库必须经过统一确认路径。
   - 任务卡片编辑路径如果未来支持，也必须保留 repeat rule 字段；MVP 可先不开放。

6. **日志和可观测性**
   - 保留现有 `intentCallLog`。
   - 新增 `actionParserCallLog`。
   - 后端 admin prompt 测试的 purpose 不再手写白名单，动态读取 `config.routes`。
   - 风险章节写明一句用户请求可能消耗两次 chat quota。

7. **验收**
   - iOS fallback prompt 样例测试通过。
   - 后端部署后：
     - `/v1/prompts/finance_action_parser` 可访问。
     - `/v1/prompts/task_action_parser` 可访问。
     - `/v1/ai/chat/completions purpose=finance_action_parser` 返回 JSON。
     - `/v1/ai/chat/completions purpose=task_action_parser` 返回 JSON。
   - “沙发 2000 分三期 0 手续费”确认后创建真实分期组。
   - “每隔三天跟家里打电话”确认后创建真实 RepeatRule，完成后下一次日期为 +3 天。

### 20.4 最终 Go 条件

满足以下条件后可以进入实施：

| 条件 | 要求 |
|------|------|
| G1 | V3 正文吸收 §18/§19/§20 结论，不只是在末尾追加审查记录 |
| G2 | 明确采用分期编辑方案 A |
| G3 | 重复任务范围收缩写入产品范围和 parser schema |
| G4 | 新 parser 方法覆盖 `HoloBackendAIProvider`、`OpenAICompatibleProvider`、`MockAIProvider` |
| G5 | 后端新增 purpose、prompt registry、config route、admin purpose 动态校验 |
| G6 | `confirmPendingTask` 加固并入 Phase 5 |
| G7 | 日志只新增 `actionParserCallLog`，保留现有 `intentCallLog` |
| G8 | 后端部署和 live 验证写入 Phase 2/3 验收 |

### 20.5 最后一轮判断

没有新的 No-Go 项。

当前方案已经完成审查收敛，可以生成 V3 作为实施基线。V3 生成时应把前 20 节的审查结论内化到正文结构中，并删除或降级已经被收缩掉的承诺，尤其是复杂“每隔 N 周的某周几”和分期 sheet 编辑能力。
