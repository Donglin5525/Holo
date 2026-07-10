# Holo AI Agent 全数据覆盖实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. 本项目明确不启用 subagent，所有步骤在当前工作区内联执行。

**Goal:** 补齐健康全指标和 Holo 核心语义数据源的 Agent 只读能力，并用证据归因、Prompt 路由和覆盖测试保证整条链路可验证。

**Architecture:** 沿用 `HoloDataTool` + production DataSource + `HoloToolRegistry`。工具文件只保存 Codable/Sendable 值类型，Repository/Core Data 转换留在 DataSource；Agent runtime 用统一证据策略记录来源和敏感度。后端只负责 Agent 推理和工具选择，不接收本地数据库。

**Tech Stack:** Swift, Swift concurrency, Core Data, HealthKit, standalone `swiftc` tests, Node.js tests, Hono backend, Xcode build.

---

## 文件结构

### 新增

- `Holo/.../Agent/HoloAgentEvidencePolicy.swift`：工具名到证据来源、敏感度的纯逻辑策略。
- `Holo/.../Agent/Tools/HoloProfileTool.swift` / `HoloProfileDataSource.swift`：结构化 Profile 查询。
- `Holo/.../Agent/Tools/HoloConversationTool.swift` / `HoloConversationDataSource.swift`：不含聊天原文的近期 intent/活动摘要。
- `Holo/.../Agent/Tools/HoloInsightTool.swift` / `HoloInsightDataSource.swift`：最近 Memory Insight 摘要。
- 对应的 standalone tests。

### 修改

- `HoloHealthTool.swift` / `HoloHealthDataSource.swift` / `HoloHealthToolTests.swift`
- `HoloFinanceTool.swift` / `HoloFinanceDataSource.swift` / `HoloFinanceToolTests.swift`
- `HoloThoughtTool.swift` / `HoloThoughtDataSource.swift` / `HoloThoughtToolTests.swift`
- `HoloAgentToolModels.swift` / `HoloEvidenceModels.swift` / `HoloLocalAgentRuntime.swift`
- `HoloAgentRuntimeShared.swift` / `HoloToolRegistryTests.swift`
- `PromptManager.swift`
- `HoloBackend/src/prompts/defaultPrompts.json`
- `HoloBackend/src/prompts/promptRegistry.js`
- `HoloBackend/tests/prompts.test.js`
- `CHANGELOG.md`

## Task 1：健康工具 RED

**Files:**

- Modify: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloHealthToolTests.swift`
- Later modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloHealthTool.swift`

- [ ] **Step 1: 把 mock data source 改为多指标数据源**

测试期望的接口：

```swift
struct MockHealthDataSource: HoloHealthDataSource {
    let daily: [HoloHealthMetricKind: [HoloHealthDailyRecord]]
    let workouts: [HoloHealthWorkoutRecord]

    func dailyRecords(for metric: HoloHealthMetricKind, timeRange: HoloAgentTimeRange?) async -> [HoloHealthDailyRecord] {
        daily[metric] ?? []
    }

    func workoutRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthWorkoutRecord] {
        workouts
    }
}
```

- [ ] **Step 2: 新增六类行为测试**

分别断言：

```swift
steps_summary -> health.steps.average, health.steps.goal_met_days, daily events
sleep_summary -> 现有三个指标保持兼容
stand_summary -> health.stand.average_hours, health.stand.goal_met_days
activity_summary -> health.activity.average_minutes, health.activity.goal_met_days
workout_summary -> health.workout.total_minutes, session_count, active_days
health_overview -> 同时含有可用指标，缺失指标产生 warning 但不吞掉已有数据
```

另加时间覆盖测试：`start=7/1 00:00, end=7/8 00:00` 的 `totalDays` 必须是 7。

- [ ] **Step 3: 运行 RED**

Run:

```bash
swiftc -parse-as-library "Holo/Holo APP/Holo/Holo/Models/AI/Agent/"*.swift \
  "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloDataTool.swift" \
  "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloHealthTool.swift" \
  "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloHealthToolTests.swift" \
  -o /tmp/holo_health_tool_test && /tmp/holo_health_tool_test
```

Expected: FAIL，缺少 `HoloHealthMetricKind`、`HoloHealthWorkoutRecord` 或新增 query。

## Task 2：健康工具 GREEN

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloHealthTool.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloHealthDataSource.swift`

- [ ] **Step 1: 定义工具侧值类型**

```swift
enum HoloHealthMetricKind: String, Codable, CaseIterable, Sendable {
    case steps, sleep, stand, activity
}

struct HoloHealthWorkoutRecord: Codable, Equatable, Sendable {
    var date: Date
    var totalMinutes: Double
    var sessionCount: Int
    var topType: String?
}
```

协议改为 `dailyRecords(for:timeRange:)` 与 `workoutRecords(timeRange:)`。

- [ ] **Step 2: 实现六个 query**

目标、单位和 metric key 固定为：

```text
steps: goal 10000, unit 步, health.steps.average / goal_met_days / daily
sleep: goal 8, unit 小时, health.sleep.average_hours / goal_met_days / low_days / hours
stand: goal 12, unit 小时, health.stand.average_hours / goal_met_days / hours
activity: goal 30, unit 分钟, health.activity.average_minutes / goal_met_days / minutes
workout: health.workout.total_minutes / session_count / active_days / daily_minutes
```

- [ ] **Step 3: 修正时间窗口**

DataSource 将 Agent 的 `[start, end)` 转为 Repository 的包含结束日范围：

```swift
let today = calendar.startOfDay(for: Date())
let exclusiveEnd = timeRange?.end.map(calendar.startOfDay) ?? calendar.date(byAdding: .day, value: 1, to: today)!
let start = timeRange?.start.map(calendar.startOfDay) ?? calendar.date(byAdding: .day, value: -13, to: today)!
let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) ?? start
```

- [ ] **Step 4: 运行 GREEN**

Run Task 1 同一命令。Expected: `HoloHealthToolTests passed`。

## Task 3：证据来源与敏感度 RED/GREEN

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentEvidencePolicy.swift`
- Create: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentEvidencePolicyTests.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentToolModels.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloEvidenceModels.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift`

- [ ] **Step 1: 写失败测试**

```swift
expect(HoloAgentEvidencePolicy.sourceModule(for: "goal") == .goal)
expect(HoloAgentEvidencePolicy.sourceModule(for: "thought") == .thought)
expect(HoloAgentEvidencePolicy.sourceModule(for: "profile") == .profile)
expect(HoloAgentEvidencePolicy.sourceModule(for: "conversation") == .conversation)
expect(HoloAgentEvidencePolicy.sourceModule(for: "insight") == .memoryInsight)
```

- [ ] **Step 2: 运行 RED**

用 Agent models + 新测试编译。Expected: FAIL，policy/cases 尚不存在。

- [ ] **Step 3: 最小实现**

在 `HoloEvidenceSourceModule` 新增 `.conversation` 与 `.memoryInsight`；`HoloDataToolResult` 新增可选字段：

```swift
var sensitivity: HoloEvidenceSensitivity? = nil
```

旧 JSON 缺字段可解码。Runtime 记录 evidence 时使用 policy 和 `result.sensitivity ?? .normal`。

- [ ] **Step 4: 运行 GREEN 和 Runtime 回归**

Expected: policy test 通过；`HoloLocalAgentRuntimeTests` 通过。

## Task 4：Profile 工具 RED/GREEN

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloProfileTool.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloProfileDataSource.swift`
- Create: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloProfileToolTests.swift`

- [ ] **Step 1: 写失败测试**

工具侧快照：

```swift
struct HoloProfileToolSnapshot: Codable, Equatable, Sendable {
    var preferredName: String?
    var language: String?
    var timezone: String?
    var city: String?
    var profession: String?
    var communicationStyle: [String]
    var currentFocus: [String]
    var lifeContext: [String]
    var healthHabitContext: [String]
    var sensitiveBoundaries: [String]
}
```

断言三类 query、空档案 `.empty`、`result.sensitivity == .sensitive`。

- [ ] **Step 2: 运行 RED**

Expected: FAIL，Profile 工具不存在。

- [ ] **Step 3: 实现工具和生产 DataSource**

DataSource 在 `MainActor.run` 内调用 `HoloProfileService.shared.loadSnapshot()` 并立即转成工具快照；不复制 `rawMarkdown`。

- [ ] **Step 4: 运行 GREEN**

Expected: `HoloProfileToolTests passed`。

## Task 5：Conversation 与 Insight 工具 RED/GREEN

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloConversationTool.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloConversationDataSource.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloInsightTool.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloInsightDataSource.swift`
- Create: corresponding tests under `HoloTests/Services/AI/Agent/`

- [ ] **Step 1: Conversation RED**

定义只含元数据的记录：

```swift
struct HoloConversationRecord: Codable, Equatable, Sendable {
    var role: String
    var intent: String?
    var timestamp: Date
}
```

测试 `recent_intent_summary` 输出总消息数、用户/助手数量和 intent 计数；`session_activity` 输出当前会话数量与最近时间；任何 event excerpt 都不得包含测试消息原文。

- [ ] **Step 2: Conversation GREEN**

生产 DataSource 使用 background context 的 dictionary fetch，只取 `role/intent/timestamp/isStreaming`，过滤 streaming，最多 50 条。4 小时间隔作为当前会话边界。

- [ ] **Step 3: Insight RED**

```swift
struct HoloInsightToolRecord: Codable, Equatable, Sendable {
    var id: UUID
    var periodType: String
    var periodStart: Date
    var periodEnd: Date
    var title: String
    var summary: String
    var generatedAt: Date
    var status: String
}
```

测试 `latest_observation` 只返回最新一条，`recent_observations` 最多返回 6 条，空记录 `.empty`，且没有 rawResponse/cardsJSON 字段。

- [ ] **Step 4: Insight GREEN**

DataSource 在 `MainActor.run` 内读取 daily/weekly/monthly 最新 ready/stale 记录并转值类型。工具敏感度为 `.sensitive`。

- [ ] **Step 5: 运行两个 standalone tests**

Expected: `HoloConversationToolTests passed`、`HoloInsightToolTests passed`。

## Task 6：Finance 预算/账户与 Thought Topic RED/GREEN

**Files:**

- Modify: `HoloFinanceTool.swift`, `HoloFinanceDataSource.swift`, `HoloFinanceToolTests.swift`
- Modify: `HoloThoughtTool.swift`, `HoloThoughtDataSource.swift`, `HoloThoughtToolTests.swift`

- [ ] **Step 1: Finance RED**

扩 `HoloFinanceToolRecord`：

```swift
var budget: HoloFinanceBudgetSnapshot?
var account: HoloFinanceAccountSnapshot?
```

其中预算含 total/spent/remaining/progress/remainingDays/warningCategoryNames；账户含 activeAccountCount/assets/liabilities/netWorth/defaultAccountName。

测试：

```text
budget_status -> finance.budget.total/spent/remaining/progress
account_summary -> finance.account.count/assets/liabilities/net_worth
```

- [ ] **Step 2: Finance GREEN**

DataSource 在 `MainActor.run` 内调用 `BudgetRepository.computeGlobalTotalBudgetStatus(.month)`、`getWarningCategoryBudgets(.month)`、`FinanceRepository.getTotalNetWorth()` 和账户查询，转成值类型后再离开 actor。

- [ ] **Step 3: Thought RED**

扩 snapshot：

```swift
var topics: [HoloThoughtTopicRecord]
```

测试 `topic_summary` 输出 `thought.topic.count` 和每个 Topic 的 evidence，包含 title、summary、thoughtCount、associatedTagNames。

- [ ] **Step 4: Thought GREEN**

DataSource 在 `MainActor.run` 内实例化 `TopicRepository`，读取活跃 Topic 并立即转成工具值类型。

- [ ] **Step 5: 运行现有 Finance/Thought tests**

Expected: 两套 standalone tests 全绿，旧 query 不回归。

## Task 7：注册、覆盖契约与 Prompt RED/GREEN

**Files:**

- Modify: `HoloAgentRuntimeShared.swift`
- Modify: `HoloToolRegistryTests.swift`
- Modify: `PromptManager.swift`
- Modify: `HoloBackend/src/prompts/defaultPrompts.json`
- Modify: `HoloBackend/src/prompts/promptRegistry.js`
- Modify: `HoloBackend/tests/prompts.test.js`

- [ ] **Step 1: Registry RED**

生产覆盖期望工具名：

```swift
["conversation", "finance", "goal", "habit", "health", "insight", "memory", "profile", "task", "thought"]
```

测试 prompt description 包含 health 六个 query，以及 profile/conversation/insight。

- [ ] **Step 2: 注册新工具并转绿**

在 shared registry 加：

```swift
HoloProfileTool(dataSource: HoloDefaultProfileDataSource()),
HoloConversationTool(dataSource: HoloDefaultConversationDataSource()),
HoloInsightTool(dataSource: HoloDefaultInsightDataSource())
```

- [ ] **Step 3: 后端 Prompt RED**

`prompts.test.js` 新增断言：

```js
assert.match(prompt.content, /steps_summary/);
assert.match(prompt.content, /sleep_summary/);
assert.match(prompt.content, /stand_summary/);
assert.match(prompt.content, /activity_summary/);
assert.match(prompt.content, /workout_summary/);
assert.match(prompt.content, /health_overview/);
```

运行该测试，Expected: FAIL。

- [ ] **Step 4: 双端同步 Prompt**

iOS `.agentLoop` 从 v3 升 v4；后端 `PROMPT_VERSIONS.agent_loop = 4`。两端追加同一选择规则：

```text
综合健康状态 -> health_overview
步数 -> steps_summary
睡眠 -> sleep_summary
站立 -> stand_summary
活动分钟 -> activity_summary
运动/锻炼 -> workout_summary
```

- [ ] **Step 5: 后端 GREEN**

Run: `npm test -- tests/prompts.test.js tests/chat.test.js`

Expected: 0 failed。

## Task 8：全量回归与 iOS 构建

**Files:** all changed files.

- [ ] **Step 1: 运行所有 Agent standalone tests**

逐个执行 Health/Profile/Conversation/Insight/Finance/Thought/Goal/Task/Habit/Memory/Registry/EvidencePolicy tests。任何一个无实际断言或未执行都不算通过。

- [ ] **Step 2: 运行后端全量测试**

Run: `npm test`

Expected: 0 failed。

- [ ] **Step 3: 运行 iOS 构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -sdk iphonesimulator build
```

Expected: `BUILD SUCCEEDED`。

- [ ] **Step 4: Diff 与需求逐条核对**

检查用户验收问题、设计覆盖矩阵、旧 Codable 兼容、工作区无关改动未被覆盖。

## Task 9：报告、CHANGELOG、部署与 scoped 交付

**Files:**

- Create: `docs/_common/plans/2026-07-11-Holo-Agent数据覆盖排查报告.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: 写最终报告**

报告必须区分：已完整接入、部分接入、未接入/明确不接、权限与设备边界，并列出真实验证命令和结果。

- [ ] **Step 2: 更新 CHANGELOG**

记录健康全指标、Profile/Conversation/Insight、预算/账户/Topic、证据归因和 Prompt 路由变化。

- [ ] **Step 3: scoped commit**

仅暂存本任务文件，不包含现有 Memory Gallery、观点标签方案、时间查询等无关改动。Commit message：

```text
feat(iOS): 补齐 Agent 核心数据覆盖与健康全指标
```

- [ ] **Step 4: HoloBackend 发版**

按项目稳定路径排除 `.env`、`deploy/.env.production`、`deploy/data` 后同步 ECS，执行：

```bash
DOCKER_BUILDKIT=0 docker compose build holo-backend
docker compose up -d --force-recreate holo-backend
```

- [ ] **Step 5: 线上验证**

验证：

```text
https://api.holoapp.cn/v1/health -> ok
https://api.holoapp.cn/v1/prompts/agent_loop -> version >= 4
prompt content 包含 health_overview / steps_summary / stand_summary / workout_summary
```
