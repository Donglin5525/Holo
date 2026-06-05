# HoloAI 结构化执行与 Prompt 拆解方案

> 状态：方案初稿，可交给 GLM 做对抗性审查。
> 目标版本：先支持 AI 分期记账与 AI 重复任务薄切片，再拆解并瘦身 `intent_recognition`。
> 当前日期口径：2026-06-03。

## 1. 背景与结论

用户期望 HoloAI 不只把自然语言识别成“记账”或“创建待办”，还要能命中模块内部已有的结构化能力：

```text
我买了个沙发，总价2000，分三期，0手续费
提醒我，每周三跟家里打个电话
提醒我，每隔三天跟家里打个电话
```

当前真实情况是：

1. 财务底层已经有分期交易能力，但 AI 记账链路只创建普通交易。
2. 待办底层已经有重复任务能力，但 AI 创建任务链路只创建普通任务。
3. `intent_recognition` prompt 已经承担过多职责，继续追加字段和规则会加重上下文噪音、路由冲突和后端/iOS fallback 漂移。

因此，本方案不建议继续把所有新能力塞进一个超长 `intent_recognition` prompt。推荐改成：

```text
轻量总路由
  -> 财务执行解析器
      -> 普通记账 / 分期记账
  -> 任务执行解析器
      -> 一次性任务 / 带提醒任务 / 重复任务
  -> 查询类 Planner
      -> flexible_data_query / query_analysis
```

第一阶段只做两个高价值薄切片：

1. AI 分期记账：支持总金额、期数、手续费为 0 或每期手续费、起始日期。
2. AI 重复任务：支持每周几、每隔 N 天、每天、每月某日。

Prompt 拆解在第一阶段以“新增专用 parser prompt + 保留兼容字段”为主，不做全量 Agent 化。

## 2. 当前真实代码链路

### 2.1 AI 执行链路

核心入口：

```text
Holo/Holo APP/Holo/Holo/Services/AI/ConversationCoordinator.swift
Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift
Holo/Holo APP/Holo/Holo/Models/AI/AIModels.swift
Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift
```

当前 `AIIntent` 只有模块级意图：

```swift
record_expense
record_income
create_task
complete_task
update_task
delete_task
query_analysis
flexible_data_query
query
```

`ParsedResult.extractedData` 当前是：

```swift
let extractedData: [String: String]?
```

这说明 AI 结构化结果目前更适合扁平字段，不适合复杂对象。但分期和重复任务可以先用字符串字段薄切片落地，例如：

```text
installmentTotalAmount
installmentPeriods
installmentFeePerPeriod
installmentStartDate
repeatType
repeatInterval
repeatWeekdays
repeatUntilDate
```

### 2.2 财务分期能力

已有模型：

```text
Holo/Holo APP/Holo/Holo/Models/Transaction.swift
Holo/Holo APP/Holo/Holo/Models/CoreDataStack+FinanceEntities.swift
Holo/Holo APP/Holo/Holo/Models/FinanceRepository.swift
```

`Transaction` 已有分期字段：

```swift
installmentGroupId: UUID?
installmentIndex: Int16
installmentTotal: Int16
```

`FinanceRepository.addInstallmentTransactions(...)` 已能按总金额、每期手续费、期数、起始日期创建分期组。

当前 AI 记账执行问题在于：

```swift
handleRecordExpense(...)
  -> addTransaction(...)
```

它不会读取分期字段，也不会调用：

```swift
addInstallmentTransactions(...)
```

所以“沙发 2000 分三期 0 手续费”现在最多变成一笔普通支出。

### 2.3 待办重复能力

已有模型与执行器：

```text
Holo/Holo APP/Holo/Holo/Models/TodoTaskModels.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataClass.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataProperties.swift
Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift
Holo/Holo APP/Holo/Holo/Views/Tasks/RepeatRuleView.swift
```

`TodoRepository.createRepeatRule(...)` 当前支持：

```swift
type: RepeatType
weekdays: [Weekday]?
untilDate: Date?
```

`TodoRepository.completeRepeatingTask(...)` 已支持完成当前实例后生成下一实例。

当前 AI 创建任务执行问题在于：

```swift
handleCreateTask(...)
  -> createTask(...)
```

它只读取：

```text
title
dueDate
reminderDate
priority
subtasks
```

不会读取 `repeatType` / `repeatWeekdays` / `repeatInterval`，也不会调用 `createRepeatRule(...)`。

### 2.4 Prompt 现状

后端 prompt：

```text
HoloBackend/src/prompts/defaultPrompts.json
HoloBackend/src/prompts/promptRegistry.js
```

当前 `intent_recognition` 已经包含：

1. 意图列表。
2. 财务科目抽取。
3. 日期与提醒解析。
4. flexible query 路由。
5. negative habit 识别。
6. 子任务识别。
7. 大量示例。

`promptRegistry.js` 当前 `intent_recognition` 版本为 15。只要修改后端 prompt，就必须同步版本测试，并完成后端发版，否则生产环境不会生效。

iOS fallback prompt：

```text
Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift
```

这里也维护了本地 fallback 内容。历史上已经出现过后端 prompt 与 iOS fallback 不同步的问题，因此本方案要求把 prompt schema 与用例抽到可对照的测试里，而不是只改其中一端。

## 3. 需求边界

### 3.1 第一阶段必须支持

AI 分期记账：

```text
沙发2000，分三期，0手续费
买了个手机 6000 分 12 期，每期手续费 10
今天买了沙发，总价2000，分三期
```

解析要求：

1. 总金额是 `totalAmount`，不是每期金额。
2. 期数必须是正整数，建议 2-60。
3. 未提手续费时默认为 0，但卡片上要显示“手续费 0”或“不含手续费”。
4. 未提起始日期时使用当天。
5. 分类仍沿用现有本地类目匹配和二级分类硬约束。
6. 先走待确认卡片，不静默落库。

AI 重复任务：

```text
每周三提醒我跟家里打电话
提醒我每隔三天跟家里打个电话
每天晚上8点提醒我吃药
每月15号提醒我还信用卡
```

解析要求：

1. `每周三` -> `repeatType=weekly` + `repeatWeekdays=3`。
2. `每隔三天` -> `repeatType=daily` + `repeatInterval=3`。
3. `每天` -> `repeatType=daily` + `repeatInterval=1`。
4. `每月15号` -> `repeatType=monthly` + `monthDay=15`。
5. 有具体时间时保留 `dueDate/reminderDate`，并继续走现有提醒调度。
6. 先走待确认卡片，不静默创建。

Prompt 拆解：

1. 新增财务执行解析 prompt：`finance_action_parser`。
2. 新增任务执行解析 prompt：`task_action_parser`。
3. `intent_recognition` 降级为总路由和最小必要字段抽取。
4. iOS fallback 与后端 prompt schema 同步。

### 3.2 第一阶段明确不做

1. 不做真实信用卡账单还款计划或账户负债模型。
2. 不做分期手续费年化利率计算。
3. 不做账单分期的提前还款、剩余本金、还款状态追踪。
4. 不做复杂 RRULE 全量语法。
5. 不做“每月第二个周一”“工作日且跳过节假日”的 AI 自动解析，保留后续扩展。
6. 不把 `extractedData` 立即改成任意嵌套 JSON 对象，避免改动面过大。

## 4. 架构决策

### ADR-1：使用“总路由 + 专用 parser”，不继续膨胀 `intent_recognition`

决策：

```text
intent_recognition 只负责判断用户意图大类。
财务执行细节交给 finance_action_parser。
任务执行细节交给 task_action_parser。
```

理由：

1. 分期和重复任务都是模块内部结构，不适合塞在总路由 prompt 里。
2. 总路由 prompt 越长，越容易影响 flexible query、query analysis、negative habit 等已有规则。
3. 专用 parser 可以用更短 schema 和更少示例，提高稳定性。
4. 后续可单独版本化、测试和回滚某个 parser。

代价：

1. AI 调用次数可能增加。
2. `ConversationCoordinator` 需要能在识别到执行型意图后调用专用 parser。
3. 后端 prompt registry 需要新增 prompt type 和测试。

缓解：

第一阶段只在命中 `record_expense/record_income/create_task` 且用户文本含结构化触发词时调用专用 parser：

```text
分期 / 期 / 手续费 / 总价
每周 / 每隔 / 每天 / 每月 / 重复
```

普通“午饭35”“明天提醒我买牛奶”仍可走现有轻链路。

### ADR-2：第一阶段保留扁平 `extractedData`，用字段命名表达结构

决策：

继续使用 `[String: String]` 承载 AI 解析结果，新增字段：

```text
installmentEnabled
installmentTotalAmount
installmentPeriods
installmentFeePerPeriod
installmentStartDate
installmentSummary

repeatEnabled
repeatType
repeatInterval
repeatWeekdays
repeatMonthDay
repeatUntilDate
repeatSummary
```

理由：

1. 当前 `AIParseItem`、`ParsedResult`、`AIExecutionItem.renderData`、`ChatCardData` 都围绕 `[String: String]` 建立。
2. 立即改成嵌套 schema 会影响 batch parse、卡片渲染、确认流、历史消息序列化。
3. 扁平字段足以覆盖第一阶段能力。

代价：

字段会继续增加。第二阶段应考虑引入 typed draft：

```swift
TransactionDraft
TaskDraft
InstallmentDraft
RepeatRuleDraft
```

### ADR-3：分期记账仍归属 `record_expense`，不新增 `record_installment_expense`

决策：

分期是支出记录的创建模式，不是独立业务意图。保留：

```text
intent = record_expense
installmentEnabled = true
```

理由：

1. 分类、账户、确认卡片、AI 创建标记都能复用现有财务链路。
2. 不扩大 `AIIntent` 枚举，不增加路由分裂。
3. 用户说“买沙发 2000 分三期”本质仍是记账。

例外：

如果后续发展成信用卡账单管理、还款计划、负债追踪，再考虑新增 `create_installment_plan`。

### ADR-4：重复任务仍归属 `create_task`，不新增 `create_recurring_task`

决策：

重复规则是任务属性，不是独立意图。保留：

```text
intent = create_task
repeatEnabled = true
```

理由：

1. `TodoTask` 与 `RepeatRule` 已是一对一关系。
2. 现有待确认任务卡片、子任务、提醒可复用。
3. “每周三提醒我打电话”本质仍是创建任务。

## 5. 目标数据 Schema

### 5.1 财务执行解析 schema

新增 prompt type：

```text
finance_action_parser
```

输入：

```json
{
  "todayDate": "2026-06-03",
  "currentTime": "14:30",
  "userText": "我买了个沙发，总价2000，分三期，0手续费",
  "baseIntent": "record_expense"
}
```

输出：

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
    "installmentSummary": "总价2000，分3期，0手续费"
  },
  "needsClarification": false,
  "clarificationQuestion": null
}
```

字段规则：

| 字段 | 类型 | 规则 |
|---|---|---|
| `amount` | String | 兼容现有卡片，分期场景填总金额 |
| `installmentEnabled` | `"true"|"false"` | 用户明确提分期/期数时为 true |
| `installmentTotalAmount` | String | 总金额；如果用户说“每期 1000，共 3 期”，可计算为 3000 |
| `installmentPeriods` | String | 正整数，2-60 |
| `installmentFeePerPeriod` | String | 未提为 0；“0 手续费”为 0 |
| `installmentStartDate` | String | yyyy-MM-dd，未提为 todayDate |
| `installmentSummary` | String | 卡片展示摘要 |

澄清规则：

1. 只说“分期”但没有期数：需要澄清。
2. 只说“每期 1000”但没有期数：需要澄清。
3. 只说“分 3 期”但没有金额：需要澄清。
4. 期数大于 60：需要澄清或拒绝。

### 5.2 任务执行解析 schema

新增 prompt type：

```text
task_action_parser
```

输入：

```json
{
  "todayDate": "2026-06-03",
  "currentTime": "14:30",
  "userText": "提醒我每周三跟家里打个电话",
  "baseIntent": "create_task"
}
```

输出：

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

输出示例：

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

字段规则：

| 字段 | 类型 | 规则 |
|---|---|---|
| `repeatEnabled` | `"true"|"false"` | 用户明确提周期时为 true |
| `repeatType` | `daily|weekly|monthly|yearly` | 第一阶段支持 daily/weekly/monthly |
| `repeatInterval` | String | 每隔 N 天时 N；每周/每月默认 1 |
| `repeatWeekdays` | String | 逗号分隔，周一=1，周日=7 |
| `repeatMonthDay` | String | 每月某日，1-31 |
| `repeatUntilDate` | String? | yyyy-MM-dd |
| `repeatSummary` | String | 卡片展示摘要 |

澄清规则：

1. “经常提醒我”没有明确频率：需要澄清。
2. “每周提醒我”没有说周几：可默认今天对应的星期，也可以澄清。第一阶段建议澄清，避免误建长期规则。
3. “每个月提醒我”没有说日期：可默认今天日期，但第一阶段建议澄清。

## 6. iOS 实施设计

### 6.1 新增解析服务

建议新增：

```text
Holo/Holo APP/Holo/Holo/Services/AI/AIActionParser.swift
```

职责：

1. 判断是否需要专用 parser。
2. 调用 `AIProvider` 获取 `finance_action_parser` 或 `task_action_parser`。
3. 将专用 parser 结果合并回 `AIParseItem.extractedData`。

伪代码：

```swift
struct AIActionParser {
    func enrichIfNeeded(
        item: AIParseItem,
        originalText: String,
        provider: AIProvider
    ) async throws -> AIParseItem {
        switch item.intent {
        case .recordExpense, .recordIncome where looksLikeInstallment(originalText):
            return try await parseFinanceAction(item, originalText, provider)
        case .createTask where looksLikeRepeatTask(originalText):
            return try await parseTaskAction(item, originalText, provider)
        default:
            return item
        }
    }
}
```

第一阶段触发词：

```swift
installment: ["分期", "期", "手续费", "总价"]
repeat: ["每周", "每隔", "每天", "每日", "每月", "重复"]
```

注意：

1. 触发词只决定是否二次解析，不直接决定落库。
2. 专用 parser 失败时应回退到原 `item`，但卡片可提示“我识别到普通记账/任务，分期/重复规则需要你手动补充”。

### 6.2 财务执行器改造

修改：

```text
Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift
```

在 `handleRecordExpense(...)` 中：

```swift
if data["installmentEnabled"] == "true" {
    return try await handleRecordInstallmentExpense(result)
}
```

新增私有方法：

```swift
private func handleRecordInstallmentExpense(_ result: ParsedResult) async throws -> RouteResult
```

执行流程：

1. 读取 `installmentTotalAmount`，fallback 到 `amount`。
2. 读取 `installmentPeriods`，校验 2-60。
3. 读取 `installmentFeePerPeriod`，空值为 0。
4. 读取 `installmentStartDate`，空值为今天。
5. 复用 `matchCategory(...)` 和默认账户。
6. 调用 `FinanceRepository.addInstallmentTransactions(...)`。
7. 返回第一笔交易 ID 或新增 `installmentGroupId` 到 `RouteResult`。

建议扩展 `RouteResult`：

```swift
let installmentGroupId: UUID?
let installmentCount: Int?
```

但第一阶段可以先不改 `RouteResult`，只把第一笔 `transactionId` 写入卡片，并在 `renderData` 保留 `installmentSummary`。

### 6.3 任务执行器改造

修改：

```text
Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift
```

在 `handleCreateTask(...)` 创建 task 后：

```swift
if data["repeatEnabled"] == "true" {
    try createRepeatRuleIfNeeded(task: task, data: data)
}
```

新增私有方法：

```swift
private func createRepeatRuleIfNeeded(task: TodoTask, data: [String: String]) throws
```

映射：

```text
daily + repeatInterval=1 -> RepeatType.daily
weekly + repeatWeekdays=3 -> RepeatType.weekly + weekdays=[.wednesday]
monthly + repeatMonthDay=15 -> RepeatType.monthly + update monthly params
```

当前 `TodoRepository.createRepeatRule(...)` 只接收 `type/weekdays/untilDate`，对 `repeatInterval` 和 `monthDay` 的完整支持需要核对 `RepeatRule` 属性。如果 `RepeatRule` 已有 interval 字段则直接写；如果没有，第一阶段应做两种选择之一：

1. 支持 `every 3 days`：补 `RepeatRule.interval` 字段和迁移。
2. 暂不支持 `every 3 days`：parser 返回澄清或 unsupported。

从产品需求看，“每隔三天”是明确用例，建议补 `interval` 字段；但需要先对 `RepeatRule+CoreDataProperties.swift` 与 `RepeatRule.nextDueDate(from:)` 做代码审查确认。

### 6.4 卡片展示

修改：

```text
Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift
Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TransactionChatCard.swift
Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TaskChatCard.swift
```

交易卡新增展示：

```text
分期：3期
每期：¥666.67
手续费：¥0/期
首期：2026-06-03
```

任务卡新增展示：

```text
重复：每周三
提醒：晚上 8:00
```

要求：

1. 待确认状态必须清楚展示分期/重复摘要。
2. 确认按钮仍沿用现有 pending 交互。
3. 卡片字段只展示已解析出的结构，不让用户误以为不确定字段已生效。

## 7. 后端 Prompt 与 Registry 改造

### 7.1 新增 prompt types

修改：

```text
HoloBackend/src/prompts/defaultPrompts.json
HoloBackend/src/prompts/promptRegistry.js
HoloBackend/tests/prompts.test.js
HoloBackend/tests/chat.test.js
```

新增：

```js
const PROMPT_VERSIONS = {
  intent_recognition: 16,
  finance_action_parser: 1,
  task_action_parser: 1,
  ...
}
```

`defaultPrompts.json` 新增：

```json
{
  "finance_action_parser": "...",
  "task_action_parser": "..."
}
```

测试必须覆盖：

1. `/v1/prompts` 返回新增 prompt metadata。
2. `/v1/prompts/finance_action_parser` 返回 version 1。
3. `/v1/prompts/task_action_parser` 返回 version 1。
4. `intent_recognition` version 更新到 16。
5. 默认 prompt 历史同步仍能工作。

### 7.2 `intent_recognition` 瘦身策略

第一阶段不要一次性大删 prompt。推荐做“低风险拆分”：

保留：

1. 意图列表。
2. 关键路由规则。
3. 最小字段 schema。
4. 代表性示例。

下沉到 `finance_action_parser`：

1. 科目归一细节。
2. 分期字段。
3. 多笔记账字段对应规则。
4. 财务执行示例。

下沉到 `task_action_parser`：

1. 日期/提醒细节。
2. 子任务识别。
3. 重复任务规则。
4. 任务执行示例。

保留在 `flexible_query_planner`：

1. 单点财务查询。
2. 金额/关键词过滤。
3. 查询计划与计算口径。

收益：

1. 总路由 prompt 明显变短。
2. 各 parser 的失败更容易定位。
3. 新增能力不会污染查询路由。

### 7.3 iOS fallback 同步

修改：

```text
Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift
```

要求：

1. `PromptType` 新增 `financeActionParser` 和 `taskActionParser`。
2. `promptVersions` 同步新增版本。
3. fallback 内容与后端 schema 保持一致。
4. 新增本地测试或静态断言，检查后端 schema 字段在 fallback 中存在。

## 8. 测试计划

### 8.1 后端测试

运行：

```bash
cd /Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend
npm test
```

新增测试：

```text
tests/prompts.test.js
tests/chat.test.js
```

用例：

1. prompt registry 暴露 `finance_action_parser`。
2. prompt registry 暴露 `task_action_parser`。
3. `intent_recognition` 新版本号正确。
4. finance parser prompt 包含 `installmentTotalAmount/installmentPeriods/installmentFeePerPeriod`。
5. task parser prompt 包含 `repeatType/repeatInterval/repeatWeekdays/repeatMonthDay`。

### 8.2 iOS 解析测试

建议新增或扩展 standalone Swift 测试，避免每次都跑完整 Xcode test：

```text
Holo/Holo APP/Holo/HoloTests/AIActionParserTests.swift
Holo/Holo APP/Holo/HoloTests/IntentRouterInstallmentTests.swift
Holo/Holo APP/Holo/HoloTests/IntentRouterRepeatTaskTests.swift
```

核心用例：

```text
沙发2000分三期0手续费
手机6000分12期每期手续费10
每周三提醒我跟家里打电话
每隔三天提醒我跟家里打电话
每天晚上8点提醒我吃药
```

验证：

1. 分期字段正确进入 renderData。
2. 待确认卡片展示分期摘要。
3. 确认后创建 3 笔交易，同一 `installmentGroupId`。
4. 每期金额正确，末期吸收尾差。
5. 重复任务确认后存在 `repeatRule`。
6. 完成重复任务后能生成下一实例。

### 8.3 编译验证

运行：

```bash
xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-ai-structured-execution-build CODE_SIGNING_ALLOWED=NO build
```

如果 `xcodebuild test` 因 scheme 无 Test action 失败，不把它作为阻断；用 build + standalone Swift 测试补足。

### 8.4 手工验收

用例 1：

```text
我买了个沙发，总价2000，分三期，0手续费
```

期望：

1. 聊天卡显示待确认支出。
2. 卡片显示总价 2000、3 期、0 手续费。
3. 确认后账本出现 3 笔分期交易。
4. 每笔交易有 `[分期 1/3]` 等标记。

用例 2：

```text
提醒我每周三跟家里打个电话
```

期望：

1. 聊天卡显示待确认任务。
2. 卡片显示重复：每周三。
3. 确认后任务有重复规则。
4. 完成任务后生成下一周三实例。

用例 3：

```text
提醒我每隔三天跟家里打个电话
```

期望：

1. 卡片显示重复：每隔 3 天。
2. 确认后任务有 interval=3 的重复规则。
3. 完成任务后生成 3 天后的实例。

## 9. 分阶段实施计划

### Phase 0：代码审查与字段确认

目标：

确认 `RepeatRule` 是否已有 interval 字段，确认分期字段与卡片字段承载方式。

文件：

```text
Holo/Holo APP/Holo/Holo/Models/TodoTaskModels.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataProperties.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataClass.swift
Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift
Holo/Holo APP/Holo/Holo/Models/FinanceRepository.swift
```

输出：

1. 是否需要新增 `RepeatRule.interval`。
2. 是否需要轻量迁移。
3. `RouteResult` 是否扩展 `installmentGroupId`。

### Phase 1：Prompt registry 新增 parser

目标：

新增 `finance_action_parser` 与 `task_action_parser`，并保留 `intent_recognition` 兼容。

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

注意：

这是后端改动。完成后需要后端发版，线上 HoloAI 才会使用新 prompt。

### Phase 2：iOS parser 调用与 fallback 同步

目标：

iOS 能按触发词调用专用 parser，并把解析字段合并到 `AIParseItem`。

文件：

```text
Holo/Holo APP/Holo/Holo/Services/AI/AIProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/OpenAICompatibleProvider.swift
Holo/Holo APP/Holo/Holo/Services/AI/AIActionParser.swift
Holo/Holo APP/Holo/Holo/Services/AI/ConversationCoordinator.swift
Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift
```

验收：

1. 普通记账不额外调用 parser。
2. 分期文本调用 `finance_action_parser`。
3. 重复任务文本调用 `task_action_parser`。
4. parser 失败时不破坏普通执行。

### Phase 3：AI 分期记账落库

目标：

确认后调用 `addInstallmentTransactions(...)` 创建分期组。

文件：

```text
Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift
Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift
Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TransactionChatCard.swift
Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift
```

验收：

1. 待确认卡片展示分期信息。
2. 确认后创建多笔交易。
3. 分类匹配仍落到二级分类。
4. AI 创建标记仍写入。

### Phase 4：AI 重复任务落库

目标：

确认后创建任务并附加 `RepeatRule`。

文件：

```text
Holo/Holo APP/Holo/Holo/Services/AI/IntentRouter.swift
Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataProperties.swift
Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift
Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TaskChatCard.swift
```

验收：

1. 每周三创建 weekly repeat rule。
2. 每隔三天创建 interval repeat rule。
3. 有提醒时间时本地通知仍调度。
4. 完成后生成下一实例。

### Phase 5：Prompt 瘦身与漂移防护

目标：

把 `intent_recognition` 中已经下沉到专用 parser 的细节删掉，并建立同步测试。

文件：

```text
HoloBackend/src/prompts/defaultPrompts.json
HoloBackend/tests/prompts.test.js
Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift
```

验收：

1. `intent_recognition` 字符数明显下降。
2. 后端 prompt 与 iOS fallback 均包含新增 schema 字段。
3. flexible query 路由测试继续通过。
4. negative habit 与子任务关键用例继续通过。

## 10. 风险与缓解

### 风险 1：多一次 LLM 调用增加延迟

缓解：

1. 只在触发词命中时调用专用 parser。
2. 普通记账/任务仍走原链路。
3. parser prompt 保持短小，maxTokens 限制在 512-800。

### 风险 2：prompt 拆解后字段不一致

缓解：

1. 后端 tests 检查 prompt schema 字段。
2. iOS tests 检查 fallback schema 字段。
3. 文档中固定字段名，不允许 parser 自由命名。

### 风险 3：重复任务 `interval` 数据模型缺口

缓解：

Phase 0 先确认。如果缺字段，必须补 Core Data 属性和迁移，再实现“每隔三天”；不能只在 prompt 输出 `repeatInterval`，却让执行器忽略。

### 风险 4：分期总金额/每期金额歧义

缓解：

规则写死：

1. “总价/总金额/一共”是总金额。
2. “每期”是每期金额。
3. 如果同时出现总金额和每期金额且不一致，进入澄清。

### 风险 5：生产环境 prompt 未更新

缓解：

凡是修改 `HoloBackend` prompt 或 registry，必须后端发版，并验证：

```text
/v1/health
/v1/prompts/finance_action_parser
/v1/prompts/task_action_parser
/v1/prompts/intent_recognition
```

## 11. 推荐实施顺序

推荐先做：

```text
Phase 0 -> Phase 1 -> Phase 2 -> Phase 3 -> Phase 4 -> Phase 5
```

不要先大规模瘦身 `intent_recognition`。原因是分期和重复任务是用户可见功能，先用专用 parser 接起来，再回头删总路由 prompt 的细节，更容易验证行为没有退化。

## 12. GLM 审查重点

请重点审查以下问题：

1. `RepeatRule` 是否已经支持 interval；如果不支持，本方案的“每隔三天”是否需要先补模型。
2. `addInstallmentTransactions(...)` 是否足以表达“账单分期”，还是只能表达“支出拆分”。本方案第一阶段按“支出拆分”处理。
3. `record_expense + installmentEnabled=true` 是否优于新增独立 intent。
4. `create_task + repeatEnabled=true` 是否优于新增独立 intent。
5. 专用 parser 是否应该由后端统一执行，还是 iOS 本地调用 provider 执行。
6. `intent_recognition` 瘦身是否应该在第一阶段完成，还是等功能稳定后再做。
7. iOS fallback 与后端 prompt 的同步测试是否足够防止漂移。

## 13. 最终建议

这次改造的核心不是“让模型知道更多规则”，而是让 HoloAI 的执行链路从：

```text
模块级意图 + 扁平字段 + 普通落库
```

升级为：

```text
模块级意图 + 专用结构解析 + 模块内部结构化落库
```

第一阶段只要把两个用户可见场景打通，就已经能明显改善 HoloAI 的真实助理感：

1. “沙发 2000 分三期 0 手续费”能创建真实分期交易。
2. “每周三/每隔三天提醒我打电话”能创建真实重复任务。

Prompt 拆解应作为这两个场景的基础设施一起做，但不要为了追求一次性完美，把所有 prompt 全量重写。

---

## 14. 对抗性审查记录（Claude 审查，2026-06-03）

> 基于对实际代码的逐文件验证，以下问题按严重程度排列。GPT 审查请重点关注 CRITICAL 项。

### CRITICAL — 方案必须修正

#### C-1：分期间隔硬编码为月，方案未声明限制

**方案原文问题**：§2.2 声称 `addInstallmentTransactions` 支持"总金额、每期手续费、期数、起始日期"。

**实际代码验证**：`FinanceRepository.swift:173` 分期间隔硬编码为 `calendar.date(byAdding: .month, value: i, to: startDate)`——**只能按月分期**，无法按周或按季。

**影响**：用户说"沙发 2000 分 3 期"按月没问题，但如果说"分 3 期，每两周一期"，当前实现无法支持。方案没有明确"分期=按月分期"。

**建议修正**：在 §3.1 需求边界中明确写死"第一阶段分期间隔固定为月"，在 parser 澄清规则中增加"如果用户提到非月间隔，提示暂不支持"。

#### C-2：RepeatRule 无 interval 字段——"每隔三天"第一阶段无法实现

**方案原文问题**：§3.1 列"每隔三天跟家里打个电话"为第一阶段必须支持。

**实际代码验证**：`RepeatRule` 完整字段列表为 `id/type/weekdays/monthDay/monthWeekOrdinal/monthWeekday/untilCount/untilDate/skipHolidays/skipWeekends/createdAt/task`——**没有 interval 字段**。`calculateNextRawDate` 所有分支中 `calendar.date(byAdding:, value: 1, to:)` 硬编码为 1。

**影响**：方案 Risk 3 提到了这个风险，但 Phase 0 只说"确认"，没有给出明确决策。方案在 §6.3 给了两个选项但没选定。如果把"每隔 N 天"列为第一阶段需求却无法实现，Phase 4 的所有测试都会失败。

**建议修正（二选一，必须现在决定）**：

- **(A) 砍掉"每隔 N 天"**：第一阶段只支持每天/每周几/每月某日（不需要改 CoreData 模型）。从 §3.1 用例列表和 §8 测试计划中移除"每隔三天"相关条目。
- **(B) 补 interval 字段**：Phase 0 新增 `RepeatRule.interval`（Int16，默认 1）+ CoreData 轻量迁移 + 修改 `calculateNextRawDate` 所有分支把 `value: 1` 改为 `value: interval`。工作量中等但可控。

方案不应把核心需求决策推到"Phase 0 确认后决定"。

#### C-3：IntentRouter 不是执行入口——方案改错了文件

**方案原文问题**：§6.2 写"在 `handleRecordExpense(...)` 中添加分期分支"，§6.3 写"在 `handleCreateTask(...)` 后附加 `createRepeatRuleIfNeeded`"。

**实际代码验证**：`ConversationCoordinator` 对 `createTask` 和 `recordExpense/recordIncome` 做了拦截——这些 intent **永远不会到达 IntentRouter**。Coordinator 直接把它们标记为 `.skipped` + `confirmationStatus = "pending"` 生成待确认卡片。真正的落库发生在用户点击确认后的回调中（推测在 `ChatViewModel` 确认处理逻辑中）。

**影响**：§6.2 写的 `handleRecordInstallmentExpense` 新方法和 §6.3 写的 `handleCreateTask` 后附加逻辑——**永远不会被调用**。

**建议修正**：方案必须补充对确认链路的分析：
1. 找到确认回调的实际位置（`ChatViewModel` 或类似处的确认 handler）
2. 在确认回调中添加分期/重复逻辑（而非 IntentRouter）
3. 在 Coordinator 的 `buildRenderData` 中把分期/重复字段写入 `renderData` 供卡片展示
4. 更新 §6.2/§6.3 的文件列表，移除或重写对 IntentRouter 的改造描述

这是方案最大的结构性缺陷——执行链路分析不完整。

#### C-4：AIActionParser 调用时机与延迟未评估

**方案原文问题**：§6.1 提出 `AIActionParser.enrichIfNeeded` 但未明确调用时机。

**实际代码验证**：当前 Coordinator 对执行型 intent 的处理流程是：

```text
LLM parse → Coordinator preview → pending card → confirm → execute
```

专用 parser 在哪一步介入？

- **如果 parse 阶段介入**：第一次 LLM 调用识别出 `record_expense` → 检测到触发词"分期" → 发第二次 LLM 调用获取分期字段。**两个 LLM 调用串行，延迟翻倍**。方案没有分析这个延迟对用户体验的影响。
- **如果确认阶段介入**：先展示普通卡片，用户确认时再调 parser 解析分期细节。但用户在卡片上看不到分期信息就按了确认，违背"先走待确认卡片展示分期摘要"的原则。

**建议修正**：明确专用 parser 的调用时机，并给出延迟估算。如果走串行双调用（推荐），需要给用户加载反馈（如"正在分析分期方案..."），并在方案中写明预期延迟范围。

### HIGH — 重要但非阻断

#### H-1：ChatCardData 工厂方法改动方案缺失

**实际代码**：`TransactionCardData` 和 `TaskCardData` 都是 struct with let properties（不可变）。`ChatCardData.from(intent:data:)` 是从 `renderData` 字典读取字段的关键工厂方法。

**问题**：§6.4 只说了"修改 ChatCardData.swift"和展示内容，没有给出：
1. struct 中需要添加哪些新属性
2. `from(intent:data:)` 中如何解析新字段
3. 卡片视图中新 UI 的布局方案

**建议**：补充 `TransactionCardData` 和 `TaskCardData` 的具体属性新增列表，以及 `from(intent:data:)` 的解析逻辑。

#### H-2：intent_recognition 版本漂移

**实际代码**：后端 `intent_recognition` 版本为 **15**，iOS `promptVersions` 最小版本为 **14**。版本已经漂移。

**影响**：如果第一阶段要改 `intent_recognition`（§7.2 瘦身），需要先把 iOS 版本对齐到 15，再升到 16。方案只说了"升到 16"，没提对齐 15。

#### H-3：触发词误触风险

**方案原文**：触发词 `["分期", "期", "手续费", "总价"]`。

**误触场景**：
- "今天心情不错" → 包含"期"字 → 不应触发分期 parser
- "明天有期末考试" → 包含"期"字 → 不应触发
- "总价" 在非财务上下文中出现 → 不应触发

**建议**：触发词判断应结合 intent（方案伪代码已做了 `switch item.intent`，这是对的）。但触发词列表本身需要更精细——建议用短语匹配而非单字匹配（如"分期"/"分.*期"用正则），移除单独的"期"字。

#### H-4：分期金额精度展示问题

**实际代码**：`FinanceRepository` 用 `Decimal` 做金额除法，尾差由最后一期吸收。`Decimal` 除法在 Swift 中截断而非四舍五入到分位。

**场景**：沙发 2000 分 3 期，每期 666.666...，展示为 ¥666.67 时三期加起来显示 ¥2000.01，用户困惑。

**建议**：卡片展示规则中明确——每期金额用分位四舍五入展示，末尾注"尾差由末一期吸收"或直接展示末期为 ¥666.66。

#### H-5：Phase 1-5 期间双源冲突

**方案设计**：Phase 1-4 新增专用 parser 后，`intent_recognition` 仍保留完整的财务/任务字段规则。Phase 5 才做瘦身。

**问题**：在 Phase 1-5 期间，总路由 prompt 仍输出完整财务/任务字段，专用 parser 也输出相同字段，两套输出可能不一致（例如总路由输出 `amount=2000`，专用 parser 输出 `installmentTotalAmount=2000`，字段名不同但语义重叠）。

**建议**：Phase 1 新增 parser 时，应同时从 `intent_recognition` 中标注已下沉字段为 deprecated（或用注释标记），不需要等到 Phase 5。

### MEDIUM — 值得注意但可后续处理

#### M-1：分期交易 tags 不会传递

`addInstallmentTransactions` 没有 `tags` 参数，分期交易的标签不会被设置。如果 AI 记账链路会传 tags，分期链路会丢失。建议在 §3.2"明确不做"中列出。

#### M-2：addInstallmentTransactions 不校验 periods >= 2

传入 `periods: 0` 会静默返回空数组并 save context。执行器中应加校验。

#### M-3：RepeatRule.untilCount 未实现

`RepeatRule.nextDueDate(from:)` 中有 `TODO` 注释，`untilCount` 检查未实现。第一阶段用 `repeatUntilDate` 不受影响，但需记录。

### 审查结论

| 等级 | # | 问题 | 一句话 |
|------|---|------|--------|
| CRITICAL | C-1 | 分期间隔硬编码为月 | 方案未声明"分期=按月分期"限制 |
| CRITICAL | C-2 | RepeatRule 无 interval | "每隔三天"第一阶段做不了，必须现在决策 |
| CRITICAL | C-3 | IntentRouter 不是执行入口 | 方案改错了文件，执行发生在确认回调 |
| CRITICAL | C-4 | Parser 调用时机不明 | 串行双调用延迟未评估 |
| HIGH | H-1 | ChatCardData 改动缺失 | 未分析工厂方法和 struct 不变性 |
| HIGH | H-2 | 版本漂移 | 后端 v15 vs iOS v14 |
| HIGH | H-3 | 触发词误触 | 单独匹配"期"字会误触 |
| HIGH | H-4 | 金额精度展示 | 尾差可能导致卡片金额加总不一致 |
| HIGH | H-5 | 瘦身顺序 | Phase 1-5 期间双源冲突 |
| MEDIUM | M-1~3 | tags/校验/untilCount | 第一阶段可接受，但需记录 |

**核心判断**：方案的业务分析、schema 设计和 Prompt 拆解策略都是合理的。但技术实施层面存在关键偏差——尤其是 **IntentRouter 并非执行入口**（C-3）和 **RepeatRule 缺 interval**（C-2），如果在实施前不修正，Phase 3/4 会直接碰壁。建议修正后重新评审。

---

## 15. 第二轮审查记录（Codex 复审，2026-06-03）

> 复审目标：逐条核对第 14 节审查意见是否符合真实代码，并给出方案修订方向。结论是：第 14 节大部分问题成立，但 C-3 的表述需要修正；`IntentRouter` 不是初始 pending 卡片的执行入口，但它仍是用户点击确认后的落库执行器。

### 15.1 结论总览

| 等级 | 编号 | 复审结论 | 方案处理 |
|------|------|----------|----------|
| CRITICAL | C-1 | 成立 | 第一阶段明确“分期=按月分期”，非月间隔进入澄清/unsupported |
| CRITICAL | C-2 | 成立，需产品决策 | 必须现在选择：砍掉“每隔 N 天”或补 `RepeatRule.interval` |
| CRITICAL | C-3 | 部分成立，原表述过强 | 初始阶段由 `ConversationCoordinator` 生成 pending；确认阶段仍调用 `IntentRouter.route` 落库 |
| CRITICAL | C-4 | 成立 | 必须明确 parser 在 pending 卡生成前串行调用，并标注延迟/加载状态 |
| HIGH | H-1 | 成立 | 补 `ChatCardData.from(...)`、struct 新字段与卡片 UI 字段清单 |
| HIGH | H-2 | 成立 | iOS `PromptManager` 先对齐 v15，再随本次改造升 v16 |
| HIGH | H-3 | 成立 | 删除单字“期”触发词，改为上下文正则和 intent 约束 |
| HIGH | H-4 | 成立 | 明确分期展示按每期真实金额列表展示，末期吸收尾差 |
| HIGH | H-5 | 成立 | Phase 1 即标注总路由字段 deprecated，避免双源冲突 |
| MEDIUM | M-1 | 成立 | 第一阶段列为不做，或扩展分期 repository 参数 |
| MEDIUM | M-2 | 成立 | 执行器必须校验 `periods >= 2` |
| MEDIUM | M-3 | 成立 | 第一阶段不使用 `untilCount`，只支持 `untilDate` |

### 15.2 C-1：分期间隔固定为月

复审结论：成立。

代码依据：

```text
Holo/Holo APP/Holo/Holo/Models/FinanceRepository.swift
```

`addInstallmentTransactions(...)` 内部使用：

```swift
Calendar.current.date(byAdding: .month, value: i, to: startDate)
```

因此当前分期能力实际是“按月拆分交易”，不是通用分期计划。

方案修订要求：

1. §3.1 增加约束：第一阶段只支持按月分期。
2. `finance_action_parser` schema 增加 `installmentIntervalUnit`，第一阶段固定输出 `month`。
3. 如果用户明确说“每两周一期/每 10 天一期/按季度分期”，parser 返回 `unsupported` 或 clarification，不要静默按月处理。

建议字段：

```text
installmentIntervalUnit = month
installmentIntervalValue = 1
```

第一阶段可以先不把这两个字段传给 repository，只用于卡片展示和 future-proof。

### 15.3 C-2：RepeatRule 缺 interval，必须现在拍板

复审结论：成立，且这是当前方案唯一必须由产品侧决策的点。

代码依据：

```text
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataClass.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataProperties.swift
Holo/Holo APP/Holo/Holo/Models/CoreDataStack+TodoEntities.swift
```

当前字段只有：

```text
id/type/weekdays/monthDay/monthWeekOrdinal/monthWeekday/untilCount/untilDate/skipHolidays/skipWeekends/createdAt/task
```

没有：

```text
interval
```

`nextDueDate(from:)` 当前也写死：

```swift
daily   -> +1 day
weekly  -> +1 week
monthly -> +1 month
yearly  -> +1 year
```

所以“每隔三天”无法只靠 prompt 或执行器实现。

两个可选修订方向：

#### 选项 A：第一阶段砍掉“每隔 N 天”

范围：

```text
支持：每天、每周几、每月某日
不支持：每隔 N 天、每隔 N 周、每隔 N 月
```

优点：

1. 不改 Core Data 模型。
2. 实施更快。
3. 复用现有 UI/Repository 更稳。

缺点：

1. 用户明确提出的“每隔三天”不能在第一阶段生效。
2. HoloAI 仍会在一个自然语言高频场景上显得半成品。

#### 选项 B：第一阶段补 `RepeatRule.interval`

范围：

```text
新增 RepeatRule.interval: Int16, default 1
daily + interval=3 表示每隔 3 天
weekly + interval=2 表示每隔 2 周
monthly + interval=2 表示每隔 2 月
```

必改文件：

```text
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataClass.swift
Holo/Holo APP/Holo/Holo/Models/RepeatRule+CoreDataProperties.swift
Holo/Holo APP/Holo/Holo/Models/CoreDataStack+TodoEntities.swift
Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift
Holo/Holo APP/Holo/Holo/Views/Tasks/AddTaskSheet.swift
Holo/Holo APP/Holo/Holo/Views/Tasks/TaskDatePickerSheet.swift
Holo/Holo APP/Holo/Holo/Views/Tasks/RepeatPicker.swift
```

最低实现要求：

1. `interval` 默认 1，现有重复任务行为不变。
2. `calculateNextRawDate` 使用 `max(Int(interval), 1)` 替代所有 `value: 1`。
3. displayDescription 支持“每隔 3 天”。
4. AI 只需要写入 `interval`，UI 后续可再增强。

我的建议：

如果目标是让用户提出的两个样例都真实生效，选 B。这个改动是中等工作量，但比后续再补更干净，因为现在方案本来就在设计重复任务结构化入口。

### 15.4 C-3：确认链路表述需要修正

复审结论：第 14 节指出的问题方向正确，但“IntentRouter 永远不会被调用”表述不准确。

真实链路是：

```text
用户输入
  -> ConversationCoordinator.process(...)
  -> parseBatch
  -> createTask / finance intent 被 Coordinator 拦截
  -> 生成 pending AIExecutionItem
  -> ChatCardData.from(...) 读取 renderData 展示待确认卡片
  -> 用户点击确认
  -> ChatViewModel.confirmPendingTask/confirmPendingTransaction
  -> 重新组 ParsedResult
  -> IntentRouter.shared.route(result)
  -> 真正落库
```

因此，方案修订应改成：

1. 专用 parser 必须在 pending 卡片生成前完成，否则卡片看不到分期/重复摘要。
2. `ConversationCoordinator` 负责把 parser 结果合并进 `AIParseItem.extractedData` 和 pending `renderData`。
3. `ChatViewModel.confirmPendingTask/confirmPendingTransaction` 是确认入口，需要确保它传入的是最新 `renderData`。
4. `IntentRouter` 仍可以承载最终落库逻辑，但不能只改 `IntentRouter` 而不改 Coordinator/ChatViewModel/ChatCardData。

建议把 §6.2/§6.3 改为：

```text
结构解析发生在 ConversationCoordinator pending 前
卡片展示发生在 ChatCardData + Card View
确认入口在 ChatViewModel
落库执行仍由 IntentRouter 负责，必要时抽出 TransactionActionExecutor / TaskActionExecutor
```

### 15.5 C-4：parser 调用时机与延迟

复审结论：成立。

推荐调用时机：

```text
第一次 LLM：intent_recognition
本地触发词判断：只在 finance/task intent 且文本命中特征时继续
第二次 LLM：finance_action_parser 或 task_action_parser
pending 卡片：展示增强后的结构字段
用户确认：本地执行落库，不再调用 LLM
```

这会带来串行双调用，但好处是用户确认前能看到结构化摘要。确认阶段不应再调用 parser。

方案修订要求：

1. §6.1 写明 `AIActionParser.enrichIfNeeded(...)` 调用位置在 `ConversationCoordinator` 生成 pending item 之前。
2. UI loading 文案从泛化“思考中”扩展为可选状态：

```text
正在识别你的指令...
正在解析分期信息...
正在解析重复规则...
```

3. 延迟评估写入 NFR：

```text
普通执行：1 次 LLM
分期/重复执行：2 次串行 LLM
目标：额外延迟尽量控制在 0.8-2.5 秒，超时 fallback 到普通待确认卡 + 提示需手动补充
```

### 15.6 H-1：ChatCardData 与 UI 字段清单

复审结论：成立。

当前：

```swift
TransactionCardData
TaskCardData
```

都是 `let` 属性；`ChatCardData.from(intent:data:)` 是唯一工厂入口之一。方案必须写清楚新增属性。

建议新增：

```swift
// TransactionCardData
let installmentEnabled: Bool
let installmentPeriods: Int?
let installmentFeePerPeriod: String?
let installmentStartDate: String?
let installmentSummary: String?
let installmentPeriodAmounts: [String]

// TaskCardData
let repeatEnabled: Bool
let repeatType: String?
let repeatInterval: Int?
let repeatWeekdays: [Int]
let repeatMonthDay: Int?
let repeatSummary: String?
```

注意：

由于 `extractedData` 仍是 `[String: String]`，数组字段建议先用逗号分隔字符串：

```text
repeatWeekdays = "3"
installmentPeriodAmounts = "666.67,666.67,666.66"
```

### 15.7 H-2：prompt 版本漂移

复审结论：成立。

当前：

```text
HoloBackend promptRegistry.js: intent_recognition = 15
PromptManager.swift: intentRecognition = 14
```

方案修订要求：

1. Phase 1 第一小步先把 iOS `PromptManager` 的 `.intentRecognition` 最低版本从 14 同步到 15。
2. 本次改 `intent_recognition` 后，后端和 iOS 再一起升到 16。
3. tests 必须断言后端 prompt version 与 iOS fallback 最低版本不会长期漂移。

### 15.8 H-3：触发词误触

复审结论：成立。

必须移除单独的：

```text
期
```

建议触发条件：

```text
finance intent 且命中以下之一：
- 分期
- 分[一二三四五六七八九十0-9]+期
- [0-9一二三四五六七八九十]+期
- 手续费
- 总价 + 分期语境

task intent 且命中以下之一：
- 每天 / 每日
- 每周 + 周几
- 每月 + 日期
- 每隔 + 数字 + 天/周/月
- 重复
```

同时要加反例测试：

```text
今天心情不错
期末考试
我最近状态还行
```

### 15.9 H-4：金额精度展示

复审结论：成立。

分期落库可继续让最后一期吸收尾差，但卡片展示不能只写“每期 ¥666.67”，否则 3 期合计会显示成 2000.01。

建议：

1. parser 不负责计算每期金额。
2. iOS 本地用 Decimal 计算 `installmentPeriodAmounts`。
3. 卡片展示：

```text
第1期 ¥666.67
第2期 ¥666.67
第3期 ¥666.66
```

或在摘要中写：

```text
前2期 ¥666.67，末期 ¥666.66
```

### 15.10 H-5：双源冲突

复审结论：成立。

如果 Phase 1 新增专用 parser，但 `intent_recognition` 仍继续输出所有财务/任务细节，会出现：

```text
总路由解析字段 A
专用 parser 解析字段 B
Coordinator 合并冲突
```

修订建议：

1. `intent_recognition` 保留基础字段：

```text
amount/title/categoryCandidate/dueDate/reminderDate
```

2. 分期/重复细节字段只由专用 parser 写入。
3. `AIActionParser` 合并规则必须是：

```text
专用 parser 字段覆盖总路由同名字段
但 categoryCandidate / selectedCategoryId 等用户确认编辑字段不得被覆盖
```

### 15.11 MEDIUM 项

M-1 分期 tags：

第一阶段建议明确不支持 AI 分期 tags，或同步给 `addInstallmentTransactions(...)` 增加 `tags` 参数。为了薄切片，建议先列入不做。

M-2 periods 校验：

执行器必须校验：

```text
2 <= installmentPeriods <= 60
```

否则 `periods=0` 会产生空分期组风险。

M-3 untilCount：

第一阶段不要让 AI 输出 `repeatUntilCount`。只支持：

```text
repeatUntilDate
```

因为 `untilCount` 当前 display 有，但 `nextDueDate` 没实现完成次数追踪。

## 16. 第二轮最终建议

方案主方向仍然成立：

```text
轻量总路由 + 专用 parser + pending 卡片确认 + 本地确定性执行
```

但实施版必须做以下修正后再开工：

1. 明确第一阶段分期固定按月。
2. 对“每隔 N 天”做产品决策：砍掉或补 `RepeatRule.interval`。
3. 改写执行链路：结构解析在 `ConversationCoordinator` pending 前，确认入口在 `ChatViewModel`，落库可继续由 `IntentRouter` 执行。
4. 补 `ChatCardData` 和卡片 UI 的字段级设计。
5. 修正 prompt 版本漂移：iOS v14 -> v15 -> 本次 v16。
6. 移除单字“期”触发词。
7. 分期金额展示按真实每期金额列表或末期尾差展示。
8. Phase 1 就声明专用 parser 字段优先，避免总路由和专用 parser 双源冲突。

### 16.1 需要用户拍板的问题

是否要把“每隔三天/每隔 N 天”纳入第一阶段？

```text
选 A：第一阶段不做每隔 N 天，只做每天、每周几、每月某日。
选 B：第一阶段补 RepeatRule.interval，让每隔三天真实生效。
```

Codex 推荐选 B，因为这是用户明确提出的样例，而且现在正好在做重复任务结构化入口；此时补 interval 比以后返工更干净。
