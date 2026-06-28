# Holo Agent Data Coverage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 HoloAI Agent 在深度分析时能自助读取 Holo 的目标、想法情绪、待办任务等关键生活数据，并用上架前验收题验证它不再只会泛泛回答。

**Architecture:** 沿用现有 `HoloDataTool` 协议，不重造 Agent loop。新增 Goal / Thought / Task 三类本地工具及生产 DataSource，注册到 `HoloAgentRuntimeShared`，必要时小幅增强后端 `agent_loop` prompt 的工具选择指引。第一阶段只做只读分析工具，不做自动改数据。

**Tech Stack:** Swift, Core Data, `HoloLocalAgentRuntime`, `HoloDataTool`, standalone `swiftc` tests, optional Node backend tests for prompt changes.

---

## 对抗性审查记录（GLM 一轮 · 2026-06-26）

> **审查状态**：已完成 GLM 一轮对抗审查，并经 GPT 复核。GLM 原审查记录保留在本节内，作为历史挑刺依据；正文实施计划已按 GPT 复核结论修订。
>
> **GLM 一轮原始定性**：方案的**架构判断与工具分层正确**（standalone test 编译模式、tool/dataSource 分层、现有四工具现状判断均成立），但**数据层事实核实不到位**——`task` 工具照抄了不存在的 Repository 方法名（致命前提错误），`thought` 工具忽略了 Repository 非单例且有线程陷阱。**不能按现方案直接进实施。**
>
> **GPT 复核定性**：`thought` 线程风险成立；`task` 阻塞结论为误报，GLM 只核了 `TodoRepository.swift` 主文件，漏看 `TodoRepository+Stats.swift` 与 `TodoRepository+Kanban.swift` 扩展。方案不需要降级 Task Tool，但必须修订 DataSource 线程模板与测试口径。

### 三工具可实施性

| 工具 | 可实施性 | 阻塞点 |
|---|---|---|
| `goal` | 🟢 基本可实施 | 仅需补 `@MainActor` 跨界调用模板（H-1） |
| `thought` | 🟡 需补 2 处 | Repository 无单例 + `viewContext` 线程陷阱（P0-2）、`getTopTags` 返回 NSManagedObject（H-2） |
| `task` | 🟢 可实施 | GLM P0-1 经复核为误报；相关方法在 `TodoRepository+Stats.swift` / `TodoRepository+Kanban.swift` |

### 问题汇总

| 编号 | 级别 | 标题 |
|---|---|---|
| P0-1 | ✅ 误报 | `task` 工具方法存在于 Repository extension 文件 |
| P0-2 | 🔴 已修订约束 | `ThoughtRepository` 无单例 + 非 `@MainActor` + `viewContext` 线程陷阱 |
| H-1 | 🟠 已修订约束 | `Goal`/`Todo` Repository `@MainActor` 同步方法的跨界调用模式未定义 |
| H-2 | 🟠 已修订约束 | `getTopTags` 返回 `[ThoughtTag]` 是 `NSManagedObject`，需跨边界转值类型 |
| M-1 | 🟡 已修订 | Task 1 测试断言「`.error` with `INVALID_PARAMS`」与 validate/execute 分层不符 |
| M-2 | 🟡 已修订 | Task 11 缺 standalone 编译命令（`HoloToolRegistry` 是 actor） |
| M-3 | 🟡 中 | `HoloAgentRuntimeShared.swift:15` 旧注释「Habit/Finance 待适配」与现状不符，恐误导 |

---

### ✅ P0-1 复核：`task` 工具方法存在，GLM 阻塞结论撤销

**GLM 原判断**：逐个核实 `TodoRepository.swift` Query Methods 区段 `:748-872` 后，认为 Task 9 点名的方法大多不存在。

**GPT 复核事实**：这些方法存在于 `TodoRepository` 的 extension 文件，而不是主文件。

| 方案 Task 9 点名 reuse 的方法 | 真实存在？ | 实际可用方法 |
|---|---|---|
| `getTodayTaskStats()` | ✅ 存在 | `TodoRepository+Stats.swift:45` |
| `getCompletionStats(from:to:)` | ✅ 存在 | `TodoRepository+Stats.swift:103` |
| `getCompletionTrend(from:to:)` | ✅ 存在 | `TodoRepository+Stats.swift:76` |
| `getUncompletedRecentTasks(limit:)` | ✅ 存在 | `TodoRepository+Kanban.swift:104` |
| `getUnplannedOpenTasks(limit:)` | ✅ 存在 | `TodoRepository+Kanban.swift:138` |
| `getOverdueTasks()` | ✅ 存在 | `TodoRepository.swift:805` |

补充核实：

- `TodoTask.completedAt` 存在于 `TodoTask+CoreDataClass.swift:27`，Core Data schema 也有 `completedAt`。
- `DailyTaskCount` 与 `TaskPeriodStats` 已定义在 `TodoRepository.swift:899` / `:904`。
- `completion_trend`、`backlog_risk`、`today_load` 可按原方案继续实施。

**修正**：撤销 GLM 的 Task 降级建议。Task Tool 保留原数据契约，但 Task DataSource 必须遵守 `@MainActor` 值类型快照模板，不能把 `TodoTask` 带出 actor 边界。

---

### 🔴 P0-2：`ThoughtRepository` 无单例 + 非 `@MainActor` + `viewContext` 线程陷阱

**事实**（`ThoughtRepository.swift`）：
- `class ThoughtRepository`（`:21`）—— **既无 `@MainActor`，也无 `static let shared`**。
- `init(context: NSManagedObjectContext = CoreDataStack.shared.viewContext)`（`:36`）—— 默认绑定**主线程 `viewContext`**。
- 方案 Task 6 点名的 5 个统计方法**签名全部正确存在**（`:783/:790/:809/:828/:849`）✅，但都是**同步**方法。

**影响**：
1. 方案 Task 6「Reuse `ThoughtRepository.xxx`」没说实例从哪来——它不是单例，得 `ThoughtRepository()` 实例化或注入。
2. **线程安全**：这些方法跑在 `viewContext` 上。Agent 的 dataSource 是 `async`，极可能执行在后台线程。后台线程访问 `viewContext` = **Core Data 线程违规**，开 `-com.apple.CoreData.ConcurrencyDebug 1` 会直接 trap——正好踩中 CLAUDE.md「闪退排查」点名的隐蔽崩溃模式。

**修正**：Task 6 必须明确线程模式——`await MainActor.run { ThoughtRepository().getMoodDistribution(...) }`，或 dataSource 内用 `CoreDataStack.shared.newBackgroundContext().perform { }`。原方案正文未写明；GPT 复核后已在 Task 6 补充模板。

---

### 🟠 H-1：`Goal`/`Todo` Repository `@MainActor` 同步方法的跨界调用模式未定义

**事实**：`GoalRepository.swift:12-13` `@MainActor final class`、`TodoRepository.swift:25-26` `@MainActor class`，两者方法均**同步**、返回 `NSManagedObject`（`Goal+CoreDataClass.swift:12`、`TodoTask+CoreDataClass.swift:12`）。

方案 Task 3 仅说「should be `@MainActor` compatible or perform value extraction on main actor」——**太模糊，照抄 Health 样板会出错**：Health 的 `HoloDefaultHealthDataSource` 调的是 `HealthRepository.shared.fetchSleepRange`（async、自管 context），而 Goal/Todo 是同步 `@MainActor` 方法，照搬会编译报错或运行时死锁。

**修正**：给出明确模板 `await MainActor.run { ... 取数 + 立即转 value snapshot ... }`，NSManagedObject 绝不跨 async 边界传递。

### 🟠 H-2：`getTopTags` 返回 `[ThoughtTag]` 是 `NSManagedObject`

**事实**：`ThoughtTag+CoreDataClass.swift:12` `class ThoughtTag: NSManagedObject`。`getMoodDistribution`/`getThoughtTexts`/`getThoughtCountByDay` 返回 `[String:Int]`/`[String]`（安全），唯独 `getTopTags`（`ThoughtRepository.swift:828`）返回实体。

**修正**：Task 5 的 `HoloThoughtToolSnapshot.topTags` 必须显式声明为 `[String]` 或值类型 struct，在 `@MainActor`/`perform` 块内完成实体→值的转换。方案现仅说「top tags」。

---

### 🟡 M-1 / M-2 / M-3

- **M-1（Task 1 测试歧义）**：原方案写「Unsupported query returns `.error` with `INVALID_PARAMS`」。但 Health 样板里不支持 query 在 `validate(_:)` 阶段就返回 `.invalid(reason:)`，**不进 `execute`**。GPT 复核后已改为：Tool 直测断言 `.invalid`，Executor 测试再断言 `.error(INVALID_PARAMS)`。
- **M-2（Task 11 缺编译命令）**：`HoloToolRegistry` 是 **actor**（`HoloToolRegistry.swift:11`），`promptDescription()` 需 `await`，standalone 编译需把 `HoloToolRegistry.swift` + mock 工具一起拉进来。GPT 复核后已补 Task 11 编译命令。
- **M-3（旧注释干扰）**：`HoloAgentRuntimeShared.swift:15` 注释还写「Habit/Finance 工具待生产 dataSource 适配（Task #34）」，实际 `:33-35` 已接入。Task 10 改这里无碍，但别被旧注释误导。

---

### ✅ 已核实正确（公平记录）

- **standalone test 编译模式自洽**：`HoloDataTool.swift` 只含 protocol/descriptor/validationResult/errorCode，真正的 `HoloToolRequest`/`HoloDataToolResult`/`HoloMetric`/`HoloEvidenceEvent` 在 `Models/AI/Agent/*.swift`（8 文件）——Task 1/4/7 的 swiftc 命令把整个目录拉进来，覆盖完整。`HoloHealthToolTests.swift` 已证明这条路通，复刻样板成立。
- **工具分层正确**：tool 依赖 protocol + 值类型、production dataSource 依赖 Core Data，与 Health 一致。
- `activeGoalsForAI`（`GoalRepository.swift:33`）**已内置 `allowAIContext == YES` 过滤**（`:36`），方案 §2「遵守 allowAIContext」成立且无需重复过滤。
- `HoloToolRegistry.promptDescription()`（`:34`）按名排序，Task 11 排序测试成立。
- P1/P2 分期合理，P2「并发现象不说因果」措辞与现有规范一致。

---

### 附：代码事实清单（供 GPT 复查，无需重新核实）

- `HoloAgentRuntimeShared.shared`：`@MainActor static let`，注册 `memory/habit/health/finance` 四工具（`:31-36`）。
- `HoloDataTool.swift`：仅含 `HoloDataTool` 协议 / `HoloToolDescriptor` / `HoloToolValidationResult` / `HoloToolErrorCode`。
- 模型类型位置：`Models/AI/Agent/` 8 文件——`HoloAgentToolModels.swift`（`HoloToolRequest`/`HoloDataToolResult`）、`HoloEvidenceModels.swift`（`HoloMetric`/`HoloEvidenceEvent`/`HoloDataCoverage`/`HoloToolWarning`）、`HoloAgentTimeRange.swift` 等。
- `HoloToolRegistry`：**actor**，`promptDescription()` 按 `descriptor.name` 排序汇总（`HoloToolRegistry.swift:11/34`）。
- `HoloToolRequest` 字段（来自 `HoloHealthToolTests.swift:32-41`）：`id/tool/query/timeRange/baseline/requiredMetrics/parameters`。
- `GoalRepository`：`@MainActor final class` + `static let shared`（`:12-14`）；`activeGoalsForAI(limit:) -> [Goal]` 同步（`:33`），内置 `allowAIContext == YES` 过滤（`:36`）；`Goal`/`Goal+CoreDataProperties` 有 `allowAIContext: Bool` 字段。
- `TodoRepository`：`@MainActor class` + `static let shared`（`:25-32`）；Query Methods 完整公开清单见下表；`TodoTask: NSManagedObject`。
- `ThoughtRepository`：**`class`（无 `@MainActor`）+ `init(context:=viewContext)`，无 `static let shared`**；5 个统计方法同步、签名正确；`ThoughtTag: NSManagedObject`。

**`TodoRepository` Query Methods 原始清单（GLM 仅核主文件，存在遗漏）**：

| 方法 | 返回 |
|---|---|
| `findTask(by:)` / `findList(by:)` / `findFolder(by:)` | 单个实体? |
| `getTasks(for list:)` | `[TodoTask]` |
| `getTodayTasks()` | `[TodoTask]` |
| `getOverdueTasks()` | `[TodoTask]` |
| `getTasks(priority:)` / `getTasks(tag:)` | `[TodoTask]` |
| `searchTasks(keyword:)` | `[TodoTask]` |
| `getTrashedTasks()` / `clearTrash()` | `[TodoTask]` / Void |

> GPT 复核：此结论不成立。完成趋势 / 完成统计在 `TodoRepository+Stats.swift`，近期待办 / 无计划任务在 `TodoRepository+Kanban.swift`。

## GPT 复核修订结论（2026-06-26）

### 继续执行的前提

本方案可以继续按 `goal + thought + task` 三工具实施，不需要砍掉 Task Tool，也不需要新增 Core Data schema。实施前必须按以下约束修正文档和代码：

1. 生产 DataSource 统一使用 `await MainActor.run { ... }` 读取主线程 Repository，并在闭包内立即转为 `Codable/Sendable` 值类型快照。
2. `Goal`、`TodoTask`、`ThoughtTag` 等 `NSManagedObject` 不得跨 async / actor 边界返回。
3. Tool 直测断言 `validate(_:) == .invalid`；只有 Executor 测试才断言 `.error` + `INVALID_PARAMS`。
4. Task Tool 保留 `today_load` / `backlog_risk` / `completion_trend`，数据来源分别为 `TodoRepository+Stats.swift` 与 `TodoRepository+Kanban.swift`。

### DataSource 统一模板

生产 DataSource 的形态统一如下：

```swift
struct HoloDefaultXDataSource: HoloXDataSource {
    func snapshot(timeRange: HoloAgentTimeRange?) async -> HoloXSnapshot {
        await MainActor.run {
            let repo = ...
            let managedObjects = repo...
            return HoloXSnapshot(
                // 在这里完成 NSManagedObject -> value snapshot
            )
        }
    }
}
```

禁止：

```swift
let goals = await MainActor.run { GoalRepository.shared.activeGoalsForAI(limit: 20) }
return goals.map { ... } // 错：NSManagedObject 已跨出 MainActor
```

---

## 对抗性审查记录（GLM 二轮 · 2026-06-26）

> **本轮目的**：核实 GPT 复核结论的事实正确性，并审查 GPT 修订后的正文（§3 Task 9 等）是否引入新问题。
>
> **二轮定性**：GPT 推翻 GLM 一轮 P0-1 **完全正确，GLM 一轮 P0-1 为误报，在此撤销并认错**。但 GPT 复核后新写的 Task 9 DataSource 模板**引入了一个与 P0-1 镜像的新 bug**（N1，破坏 standalone test 编译隔离），需 GPT 三轮修正。

### 1. 认错：P0-1 误报确认 + 方法论反思

GLM 二轮重新核实，方法全部存在（铁证）：

| 方法 | 位置 | 存在 |
|---|---|---|
| `getTodayTaskStats()` | `TodoRepository+Stats.swift:45` | ✅ |
| `getCompletionTrend(from:to:)` | `TodoRepository+Stats.swift:76` | ✅ |
| `getCompletionStats(from:to:)` | `TodoRepository+Stats.swift:103` | ✅ |
| `getUncompletedRecentTasks(limit:)` | `TodoRepository+Kanban.swift:104` | ✅ |
| `getUnplannedOpenTasks(limit:)` | `TodoRepository+Kanban.swift:138` | ✅ |
| `TodoTask.completedAt` | `TodoTask+CoreDataClass.swift:27` | ✅ |
| `DailyTaskCount`/`TaskPeriodStats` | `TodoRepository.swift:899/904` | ✅ |

**GLM 一轮的方法论缺陷**：用 `find -name "TodoRepository.swift"` 精确名匹配，漏掉 `+Stats.swift` / `+Kanban.swift` / `+Attachments.swift` 三个 extension；随后又只在主文件 grep `func`，自然找不到 extension 里的方法。核实「方法是否存在」本应直接 grep 方法名全模块。

**不再犯的计划**：①核实符号存在性一律 `grep -rn "func symbolName" --include='*.swift' <模块根>`；②`find` Repository 一律用通配前缀 `RepoName*.swift` 覆盖 extension；③任何「不存在」断言，先排除 extension/拆分文件再下结论。

### 2. GPT 复核正确的部分（确认）

P0-1 翻案；P0-2/H-1/H-2 修订到位（DataSource 统一 `await MainActor.run`、闭包内完成实体→值转换、反例准确）；M-1 测试口径、M-2 Task 11 编译命令已补。

### 3. 本轮新发现

#### 🔴 N1（确定 bug，阻塞 standalone test）：Task 9 snapshot 复用 Repository 层类型，破坏编译隔离

**事实**：
- `TaskPeriodStats`（`TodoRepository.swift:904`）/ `DailyTaskCount`（`:899`）定义在 TodoRepository 主文件，依赖整套 Core Data stack。
- §5 standalone 编译命令（正文行 614-620）只拉 `Models/AI/Agent/*.swift` + `HoloDataTool.swift` + `HoloTaskTool.swift` + test，**不含 `TodoRepository.swift`**。
- GPT 写的 Task 9 模板（正文行 493-501）让 `HoloTaskToolSnapshot` 字段直接是 Repository 类型（`periodStats: periodStats`、`completionTrend: trend`）→ `HoloTaskTool.swift` 一引用这俩类型，standalone 编译**立即失败**（找不到符号）。

**镜像讽刺**：GPT 揪出 GLM「漏看 extension 文件」，自己却「漏看 standalone 编译命令的文件清单」——同型错误，方向相反。GPT 在 goal（`HoloGoalToolRecord`）、thought（`.map(\.name)` 转 String）都守住了 tool/dataSource 分层，**唯独 task 的 stats 类型漏了转换**。

**字段定义（已核实，供修正模板用）**：

```swift
struct DailyTaskCount { let date: Date; let completedCount: Int }

struct TaskPeriodStats {
    let completedInPeriod: Int; let dueInPeriod: Int; let overdueInPeriod: Int
    let completionRate: Double; let highPriorityCompletionRate: Double?
    let createdInPeriod: Int; let carriedOverBacklogCount: Int; let activeBacklogCount: Int
}
```

**修正后模板**（GPT 三轮据此改正文 Task 9）：

```swift
func snapshot(timeRange: HoloAgentTimeRange?) async -> HoloTaskToolSnapshot {
    await MainActor.run {
        let repo = TodoRepository.shared
        let todayStats = repo.getTodayTaskStats()
        let period = repo.getCompletionStats(from: start, to: end)
        let trend = repo.getCompletionTrend(from: start, to: end)
        return HoloTaskToolSnapshot(
            todayStats: HoloTodayTaskStats(
                dueToday: todayStats.dueToday,
                completedToday: todayStats.completedToday,
                overdue: todayStats.overdue),
            completionRate: period.completionRate,
            activeBacklogCount: period.activeBacklogCount,
            completionTrend: trend.map { HoloDailyTaskCount(
                date: $0.date, completedCount: $0.completedCount) },
            overdueTasks: repo.getOverdueTasks().map { HoloTaskToolRecord(task: $0) },
            recentTasks: repo.getUncompletedRecentTasks(limit: 5).map { HoloTaskToolRecord(task: $0) },
            unplannedTasks: repo.getUnplannedOpenTasks(limit: 5).map { HoloTaskToolRecord(task: $0) }
        )
    }
}
```

要点：snapshot 字段全部用 tool 自定义值类型（`HoloTodayTaskStats` / `HoloDailyTaskCount` / `HoloTaskToolRecord`），闭包内完成 Repository 类型→tool 类型的映射；`TaskPeriodStats` 只提取 tool 需要的 `completionRate` / `activeBacklogCount`（对齐 §2 output metrics），不整结构搬。

#### 🟡 N2：`.map(HoloTaskToolRecord.init)` 隐藏了 80 字截断

GPT 模板 `repo.getOverdueTasks().map(HoloTaskToolRecord.init)` 假设有 `init(_ : TodoTask)`，但 §2 Events 要求「描述最多截断 80 字」——截断逻辑只能藏在该 init 内，方案未体现。`HoloTaskToolRecord(task:)` 的 init 必须显式做 80 字截断（与 thought snippet 的 `prefix(120)` 同理）。N1 修正模板已改用 `HoloTaskToolRecord(task: $0)`，实施时该 init 内补截断。

#### 🟡 N3：`todayStats` 是无名元组，不可 Codable

`getTodayTaskStats()` 返回无名元组（`TodoRepository+Stats.swift:45`）。N1 修正模板已用 `HoloTodayTaskStats` 值类型承接，同时解决 N3。

#### 🟡 N4（待核实，本轮不断言）：ThoughtTag 标签名字段名

Task 6 模板用 `.map(\.name)`。GLM 二轮 grep `ThoughtTag+CoreDataProperties.swift` 的 `var name` **未命中**——可能属性定义在 `+CoreDataClass.swift`，或字段名非 `name`（如 `tagName`）。**实施前需确认字段名**，否则 Task 6 编译失败。本轮明确标「待核实」而非断言「不存在」（吸取一轮教训）。

#### ✅ N5（GLM 二轮主动核查，疑点排除）：Goal `tasks`/`habits` 关系运行时已注册

GLM 二轮怀疑 `createGoalEntity().properties`（`CoreDataStack+GoalEntities.swift:95-99`）只列 14 个 attribute、没有 tasks/habits relationship。核实后**排除**：

- `CoreDataStack+TodoEntities.swift:659` → `goalEntity.properties.append(goalTasksRelation)` ✅
- `CoreDataStack+HabitEntities.swift:253` → `goalEntity.properties.append(goalHabitsRelation)` ✅
- 配合 `Goal+CoreDataProperties.swift:26-27/51-61` 的 `tasks/habits: NSSet` + `sortedTasks/sortedHabits` 便捷属性。

→ goal 工具 `goal_progress_context`（关联任务完成率 / 关联习惯数）**数据来源完整成立**。relationship 用「反向侧定义 + append 到 goalEntity」的编程式 wire-up 模式，运行时可访问。

### 4. 二轮总评

| 项 | 结论 |
|---|---|
| GLM 一轮 P0-1 | ❌ 误报，撤销 |
| GPT 复核 P0-1 翻案 + P0-2/H-1/H-2/M-1/M-2 | ✅ 正确 |
| GPT Task 9 模板 | 🔴 N1 编译隔离破坏（镜像错误），已附修正模板 |
| Goal 关联关系 | ✅ 已注册，疑点排除 |

**当前方案唯一确定的阻塞 bug 是 N1**，修正成本极低（闭包内加一层值类型映射）。N2/N3 随 N1 一并解决，N4 为实施前确认项。**修完 N1 + 确认 N4，方案即可进实施。**

---

## GPT 三轮修订结论（2026-06-26）

### 二轮反馈处理

| 编号 | 结论 | 处理 |
|---|---|---|
| N1 | 成立 | Task Tool Snapshot 不得复用 `TaskPeriodStats` / `DailyTaskCount`，已改为 tool 自定义值类型 |
| N2 | 成立 | `HoloTaskToolRecord(task:)` 必须显式做 desc 80 字截断 |
| N3 | 成立 | `getTodayTaskStats()` 的无名元组必须映射为 `HoloTodayTaskStats` |
| N4 | 已核实排除 | `ThoughtTag.name` 存在于 `ThoughtTag+CoreDataClass.swift:20`，Task 6 的 `.map(\.name)` 可用 |
| N5 | 已确认 | Goal 的 tasks/habits 反向关系已注册，Goal Tool 数据来源成立 |

### Task Tool 编译隔离规则

`HoloTaskTool.swift` 参与 standalone 编译时不能依赖 Todo/Core Data 文件，因此这些 Repository 层类型只能在 `HoloTaskDataSource.swift` 内出现，并必须在 `MainActor.run` 闭包内转换掉：

- 不允许在 `HoloTaskTool.swift` 中引用 `TaskPeriodStats`
- 不允许在 `HoloTaskTool.swift` 中引用 `DailyTaskCount`
- 不允许在 `HoloTaskToolSnapshot` 中保存无名元组
- 不允许把 `TodoTask` 带出 `MainActor.run`

Tool 层自定义值类型至少包括：

```swift
struct HoloTodayTaskStats: Codable, Equatable, Sendable {
    var dueToday: Int
    var completedToday: Int
    var overdue: Int
}

struct HoloDailyTaskCount: Codable, Equatable, Sendable {
    var date: Date
    var completedCount: Int
}
```

`HoloTaskToolRecord(task:)` 必须放在生产 DataSource 文件中完成字段抽取，并确保描述截断。不要把依赖 `TodoTask` 的 initializer 放进 `HoloTaskTool.swift`，否则 standalone tool test 会因为找不到 Core Data 类型而编译失败：

```swift
HoloTaskToolRecord(
    id: task.id.uuidString,
    title: task.title,
    descExcerpt: task.desc.map { String($0.prefix(80)) },
    priority: Int(task.priority),
    dueDate: task.dueDate,
    plannedDate: task.plannedDate,
    completed: task.completed
)
```

---

## 对抗性审查记录（GLM 三轮 · 2026-06-27 · 定稿确认）

> **审查状态**：5 轮对抗审查闭环。本节为 GLM 三轮对 GPT 三轮修订的事实复核 + 定稿确认。**结论：方案可进实施。**

### 事实基石复核（亲自核实，非采信 GPT 判定表）

| 核实项 | 结论 |
|---|---|
| `ThoughtTag.name`（N4 排除依据） | ✅ `ThoughtTag+CoreDataClass.swift:20` `@NSManaged var name: String` 真实存在 |
| `task.desc`（N1/N2 模板字段） | ✅ `TodoTask+CoreDataClass.swift:21` `desc: String?` 真实存在 |
| TodoTask 其余字段（title/priority/dueDate/plannedDate/completed/id） | ✅ 全部核实 |
| Task 9 字段映射（completionRate/activeBacklogCount/date/completedCount） | ✅ 与 `TaskPeriodStats`/`DailyTaskCount` 定义一致 |
| Task 6 thought dataSource（MainActor.run + `.map(\.name)` + prefix(120)） | ✅ 正确 |
| Goal linked snapshot | ✅ Task 2 已要求定义 `HoloGoalLinkedTaskSnapshot` + completion rate，Task 3 行 538 注释占位非 gap |

**GPT 三轮无新 bug，N1-N5 全部处理到位。** GPT 三轮另有一个精准约束：`init(task: TodoTask)` 必须放 `HoloTaskDataSource.swift`（`@MainActor`），禁入 tool 文件——否则 standalone test 编译失败。

### 实施前硬约束 checklist

1. 三个生产 dataSource 统一 `await MainActor.run { }`，闭包内完成 NSManagedObject→值类型转换，实体不跨 async/actor 边界。
2. Task tool：`HoloTaskToolSnapshot` 只用 tool-local 值类型（`HoloTodayTaskStats`/`HoloDailyTaskCount`/scalar），禁引用 `TaskPeriodStats`/`DailyTaskCount`；`init(task:)` 放 dataSource 文件。
3. Thought tool：`topTags` 用 `[String]`（`.map(\.name)`），snippet `prefix(120)`。
4. Goal tool：`HoloGoalToolRecord` + `HoloGoalLinkedTaskSnapshot`（带 completed，支撑 `goal.linked_task.completion_rate`）。
5. standalone 编译：tool 文件零 Core Data 依赖（dataSource protocol + 值类型定义在 tool 文件，生产 dataSource 与 `init(task:)` 在 dataSource 文件）。
6. 测试口径：tool 直测 `validate(_:) == .invalid`；executor 测 `.error + INVALID_PARAMS`。
7. Task 10 注册三工具到 `HoloAgentRuntimeShared.shared`（`@MainActor static let` 闭包内追加，忽略 `:15` 旧注释）。
8. Task 12 后端 prompt 仅在真实模型不主动调工具时改，改必 `docker compose build --no-cache` 部署 + 验证 `/v1/prompts/agent_loop` + 真机重开清 2 分钟 metaTTL 缓存。

### 收敛声明

方案经 GLM 一轮（P0-1 误报）→ GPT 复核（翻案 + 修 P0-2/H-1/H-2/M-1/M-2）→ GLM 二轮（认错 + 揪 N1 + 核 N5）→ GPT 三轮（修 N1/N2/N3 + 核 N4）→ GLM 三轮（确认）共 5 轮，所有阻塞性问题闭环，事实核实充分。**可按 §3 Task 1-12 进实施。**

---

## 0. Current Audit

当前生产 Agent runtime 只注册了四个工具：

- `memory`: 长期/情景记忆、抑制规则。
- `habit`: 正负向习惯趋势、完成率、超限。
- `health`: 睡眠摘要。
- `finance`: 支出、分类、关键词交易。

缺口：

- `goal`: `GoalRepository.activeGoalsForAI(limit:)` 已有 AI 入口，但 Agent loop 没工具可读。
- `thought`: `ThoughtRepository.getMoodDistribution/getTopTags/getThoughtTexts/getThoughtCountByDay` 已有统计能力，但 Agent loop 没工具可读。
- `task`: `TodoRepository` 主文件及扩展文件已提供今日、逾期、近期待办、无计划任务、完成统计和完成趋势等查询，但 Agent loop 没工具可读。

产品影响：

- 用户问“我最近是不是偏离目标了”，Agent 只能看习惯/财务/健康，缺少目标本身。
- 用户问“我为什么状态不好”，Agent 能看睡眠，但缺少最近想法、情绪、待办压力。
- 用户问“我最近最该调整什么”，Agent 缺少目标、任务、想法三者之间的关联证据。

## 1. Scope

P0 上架前必做：

- 新增 `goal` 工具。
- 新增 `thought` 工具。
- 新增 `task` 工具。
- 注册三类工具到生产 runtime。
- 添加工具级 standalone tests。
- 添加 Agent 能力验收清单。

P1 上架前建议做：

- 如果真实模型不会主动调用新工具，更新后端 `agent_loop` prompt 的工具选择指引。
- 若修改 `HoloBackend/src/prompts/defaultPrompts.json` 或 `promptRegistry.js`，必须部署后端并验证 `https://api.holoapp.cn`。

P2 上架后增强：

- 分析卡片化、证据可视化、详情页。
- 自动追问策略。
- 跨模块归因评分，但必须继续表达为“并发现象/可能相关”，不能说成因果。

## 2. Data Contract

### Goal Tool

Tool name: `goal`

Supported queries:

- `active_goal_summary`: 当前活跃目标、领域、截止时间、关联任务/习惯数量。
- `goal_progress_context`: 活跃目标与关联任务/习惯进度。
- `goal_deadline_risk`: 近期截止目标、逾期/无推进风险。

Output metrics:

- `goal.active.count`
- `goal.deadline.upcoming_days`
- `goal.linked_task.completion_rate`
- `goal.linked_habit.count`

Events:

- 每个目标一条事件，excerpt 只包含标题、领域、截止时间、期望结果摘要。
- 遵守 `allowAIContext == true`。

### Thought Tool

Tool name: `thought`

Supported queries:

- `mood_summary`: 心情分布、想法数量、热门标签。
- `thought_theme_summary`: 最近想法摘要、热门标签。
- `thought_activity_trend`: 按天想法数量趋势。

Output metrics:

- `thought.count.total`
- `thought.mood.count`
- `thought.activity.daily_count`

Events:

- mood/tag 事件使用统计摘要。
- 原文只用 `getThoughtTexts(... limit:)` 的短摘录，限制数量和长度，避免把完整私密内容直接灌给模型。

### Task Tool

Tool name: `task`

Supported queries:

- `today_load`: 今日规划、今日到期、今日完成、今日看板进度。
- `backlog_risk`: 未完成、逾期、无计划任务、近期待办。
- `completion_trend`: 任务完成趋势。

Output metrics:

- `task.today.total`
- `task.today.completed`
- `task.overdue.count`
- `task.backlog.active_count`
- `task.completion.rate`

Events:

- 任务事件只包含标题、优先级、截止/规划时间、完成状态。
- 不读取附件内容，不读取长描述全文；描述最多截断 80 字。

## 3. Implementation Tasks

### Task 1: Goal Tool Tests

**Files:**

- Create: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloGoalToolTests.swift`
- Create later: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloGoalTool.swift`

**Step 1: Write failing tests**

Test cases:

- `active_goal_summary` returns `.success` with active goal count and one event per goal.
- `goal_progress_context` calculates linked task completion rate.
- Empty goal list returns `.empty`.
- Tool-level unsupported query test asserts `validate(_:) == .invalid`.
- Executor-level unsupported query test asserts `.error` with `INVALID_PARAMS`.

**Step 2: Run failing test**

Run:

```bash
swiftc -parse-as-library \
  "Holo/Holo APP/Holo/Holo/Models/AI/Agent/"*.swift \
  "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloDataTool.swift" \
  "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloGoalTool.swift" \
  "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloGoalToolTests.swift" \
  -o /private/tmp/holo_goal_tool_test
```

Expected: fail because `HoloGoalTool.swift` does not exist.

### Task 2: Implement Goal Tool

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloGoalTool.swift`

**Implementation notes:**

- Define `HoloGoalToolRecord` as Sendable/Codable value type.
- Define `HoloGoalLinkedTaskSnapshot` and `HoloGoalLinkedHabitSnapshot`.
- Define `HoloGoalDataSource` protocol.
- Implement metrics from value types only.
- No Core Data objects cross async/tool boundaries.

**Step 1: Implement minimal logic**

- `active_goal_summary`: count goals, emit `goal.active.count`, one event per goal.
- `goal_progress_context`: aggregate linked task completion rate.
- `goal_deadline_risk`: compute nearest deadline days.

**Step 2: Run tests**

Expected: `HoloGoalToolTests passed`.

### Task 3: Goal Production DataSource

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloGoalDataSource.swift`

**Implementation notes:**

- Use `GoalRepository.shared.activeGoalsForAI(limit: 20)`.
- Because `GoalRepository` is `@MainActor`, production DataSource must read and convert inside `await MainActor.run { ... }`.
- Convert `Goal`, `TodoTask`, `Habit` into value snapshots inside the `MainActor.run` closure.
- Never return `[Goal]`, `[TodoTask]`, or `[Habit]` from the closure.
- Respect `allowAIContext`.

Required shape:

```swift
func goals(timeRange: HoloAgentTimeRange?) async -> [HoloGoalToolRecord] {
    await MainActor.run {
        GoalRepository.shared.activeGoalsForAI(limit: 20).map { goal in
            HoloGoalToolRecord(
                id: goal.id.uuidString,
                title: goal.title,
                // copy scalar fields and linked task/habit snapshots here
            )
        }
    }
}
```

**Verification:**

- `xcodebuild build` must compile with app target.

### Task 4: Thought Tool Tests

**Files:**

- Create: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloThoughtToolTests.swift`
- Create later: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloThoughtTool.swift`

**Test cases:**

- `mood_summary` returns mood distribution metrics and tag events.
- `thought_theme_summary` emits limited redacted snippets.
- `thought_activity_trend` emits daily count events.
- Empty thought summary returns `.empty`.

### Task 5: Implement Thought Tool

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloThoughtTool.swift`

**Implementation notes:**

- Define `HoloThoughtToolSnapshot` with total count, mood distribution, top tag names, snippets, daily counts.
- `topTags` must be `[String]` or a pure value struct, never `[ThoughtTag]`.
- Keep snippets limited: max 5 snippets, max 120 characters each in tool output.
- Use metric/event excerpts that say “最近想法出现...” rather than making psychological judgments.

### Task 6: Thought Production DataSource

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloThoughtDataSource.swift`

**Implementation notes:**

- Reuse `ThoughtRepository.getThoughtCount`, `getMoodDistribution`, `getTopTags`, `getThoughtTexts`, `getThoughtCountByDay`.
- Default range: last 14 days if request has no time range.
- Do not fetch deleted/hidden content outside repository base predicate.
- `ThoughtRepository` is not a singleton and defaults to `CoreDataStack.shared.viewContext`; production DataSource must instantiate and query it inside `await MainActor.run { ... }`.
- Convert `ThoughtTag` to `String` inside the `MainActor.run` closure.

Required shape:

```swift
func snapshot(timeRange: HoloAgentTimeRange?) async -> HoloThoughtToolSnapshot {
    await MainActor.run {
        let repo = ThoughtRepository()
        let topTags = repo.getTopTags(from: start, to: end, limit: 5).map(\.name)
        return HoloThoughtToolSnapshot(
            totalCount: repo.getThoughtCount(from: start, to: end),
            moodDistribution: repo.getMoodDistribution(from: start, to: end),
            topTags: topTags,
            snippets: repo.getThoughtTexts(from: start, to: end, limit: 5)
                .map { String($0.prefix(120)) },
            dailyCounts: repo.getThoughtCountByDay(from: start, to: end)
        )
    }
}
```

### Task 7: Task Tool Tests

**Files:**

- Create: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloTaskToolTests.swift`
- Create later: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloTaskTool.swift`

**Test cases:**

- `today_load` returns today total/completed metrics.
- `backlog_risk` returns active backlog and overdue metrics.
- `completion_trend` returns daily completion events.
- Empty task list returns `.empty`.

### Task 8: Implement Task Tool

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloTaskTool.swift`

**Implementation notes:**

- Define `HoloTaskToolSnapshot` using only tool-local `Codable/Equatable/Sendable` value types.
- Define `HoloTodayTaskStats` instead of storing the anonymous tuple returned by `TodoRepository.getTodayTaskStats()`.
- Define `HoloDailyTaskCount` instead of referencing Repository-layer `DailyTaskCount`.
- Store `completionRate` and `activeBacklogCount` as scalar fields instead of storing Repository-layer `TaskPeriodStats`.
- Define `HoloTaskToolRecord` as a pure value type; it must not reference `TodoTask`.
- Read-only only.
- Event excerpts should be concise: title, status, due/planned date, priority.
- Tool-level unsupported query test asserts `validate(_:) == .invalid`; Executor-level invalid request test covers `.error` + `INVALID_PARAMS`.

### Task 9: Task Production DataSource

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloTaskDataSource.swift`

**Implementation notes:**

- Reuse `TodoRepository.shared.getTodayTaskStats()`.
- Reuse `getCompletionStats(from:to:)`, `getCompletionTrend(from:to:)`.
- Reuse `getUncompletedRecentTasks(limit:)`, `getUnplannedOpenTasks(limit:)`, `getOverdueTasks()`.
- If `activeTasks` may be stale, call the repo loading path already used by app before snapshotting.
- These methods exist in `TodoRepository+Stats.swift` and `TodoRepository+Kanban.swift`; do not remove `completion_trend`.
- Because `TodoRepository` is `@MainActor`, production DataSource must read and convert inside `await MainActor.run { ... }`.
- Convert `TodoTask` into `HoloTaskToolRecord` inside the closure. Do not return managed objects.
- Convert `TaskPeriodStats` into scalar fields or tool-local value types inside the closure. Do not store `TaskPeriodStats` in `HoloTaskToolSnapshot`.
- Convert `DailyTaskCount` into `HoloDailyTaskCount` inside the closure. Do not store Repository-layer `DailyTaskCount` in `HoloTaskToolSnapshot`.
- Convert the `getTodayTaskStats()` anonymous tuple into `HoloTodayTaskStats`.
- `HoloTaskToolRecord(task:)` or the mapping closure must truncate `desc` to 80 characters before storing it as `descExcerpt`.

Required shape:

```swift
func snapshot(timeRange: HoloAgentTimeRange?) async -> HoloTaskToolSnapshot {
    await MainActor.run {
        let repo = TodoRepository.shared
        let todayStats = repo.getTodayTaskStats()
        let period = repo.getCompletionStats(from: start, to: end)
        let trend = repo.getCompletionTrend(from: start, to: end)
        return HoloTaskToolSnapshot(
            todayStats: HoloTodayTaskStats(
                dueToday: todayStats.dueToday,
                completedToday: todayStats.completedToday,
                overdue: todayStats.overdue
            ),
            completionRate: period.completionRate,
            activeBacklogCount: period.activeBacklogCount,
            completionTrend: trend.map {
                HoloDailyTaskCount(date: $0.date, completedCount: $0.completedCount)
            },
            overdueTasks: repo.getOverdueTasks().map { HoloTaskToolRecord(task: $0) },
            recentTasks: repo.getUncompletedRecentTasks(limit: 5).map { HoloTaskToolRecord(task: $0) },
            unplannedTasks: repo.getUnplannedOpenTasks(limit: 5).map { HoloTaskToolRecord(task: $0) }
        )
    }
}
```

`HoloTaskToolRecord(task:)` must live in `HoloTaskDataSource.swift`, copy only scalar fields, and truncate description:

```swift
extension HoloTaskToolRecord {
    @MainActor
    init(task: TodoTask) {
        self.init(
            id: task.id.uuidString,
            title: task.title,
            descExcerpt: task.desc.map { String($0.prefix(80)) },
            priority: Int(task.priority),
            dueDate: task.dueDate,
            plannedDate: task.plannedDate,
            completed: task.completed
        )
    }
}
```

### Task 10: Register Tools

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentRuntimeShared.swift`

**Change:**

Add:

```swift
HoloGoalTool(dataSource: HoloDefaultGoalDataSource()),
HoloThoughtTool(dataSource: HoloDefaultThoughtDataSource()),
HoloTaskTool(dataSource: HoloDefaultTaskDataSource())
```

Expected tool list after change:

- memory
- habit
- health
- finance
- goal
- thought
- task

### Task 11: Tool Registry Coverage Test

**Files:**

- Create or modify: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloToolRegistryTests.swift`

**Test cases:**

- Registry prompt description contains `goal`, `thought`, `task`.
- Each new tool advertises supported queries.
- Tool names are stable and sorted in prompt description.

**Standalone compile command shape:**

```bash
swiftc -parse-as-library \
  "Holo/Holo APP/Holo/Holo/Models/AI/Agent/"*.swift \
  "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloDataTool.swift" \
  "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloToolRegistry.swift" \
  "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloGoalTool.swift" \
  "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloThoughtTool.swift" \
  "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloTaskTool.swift" \
  "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloToolRegistryTests.swift" \
  -o /private/tmp/holo_tool_registry_test && /private/tmp/holo_tool_registry_test
```

### Task 12: Backend Prompt Guidance, Only If Needed

**Files:**

- Modify if live/manual test shows model ignores new tools: `HoloBackend/src/prompts/defaultPrompts.json`
- Modify if versioned prompt tests require it: `HoloBackend/src/prompts/promptRegistry.js`
- Test: `HoloBackend/tests/chat.test.js`
- Test: `HoloBackend/tests/prompts.test.js`

**Guidance to add:**

- 状态/压力/情绪类问题优先考虑 `health + thought + task`。
- 偏离目标/长期方向类问题优先考虑 `goal + task + habit`。
- 消费/冲动/生活模式类问题优先考虑 `finance + thought + habit`。
- 只能基于工具结果输出 claims；不要把并发现象写成因果。

**Deployment warning:**

Any backend prompt change requires backend deployment and live validation against `https://api.holoapp.cn`, including `/v1/health`, prompt version/source, and real `purpose: agent_loop` or intent path validation.

## 4. Product Acceptance Questions

上架前用以下自然语言做验收。每个问题都要看三件事：有没有调用正确工具、有没有引用证据、有没有承认边界。

1. “我最近状态为什么不好？”
   - Expected tools: `health`, `thought`, `task`, optionally `habit`.
   - Good answer: 结合睡眠、想法/情绪、逾期/积压任务，只说可能相关。

2. “我这周是不是偏离目标了？”
   - Expected tools: `goal`, `task`, `habit`.
   - Good answer: 先说目标是什么，再看关联任务/习惯有没有推进。

3. “我最近花钱和情绪有没有关系？”
   - Expected tools: `finance`, `thought`, optionally `habit`.
   - Good answer: 只能说时间上并发，不能说情绪导致消费。

4. “我现在最该调整的一件事是什么？”
   - Expected tools: `goal`, `task`, `health`, `habit`, `thought`.
   - Good answer: 给一个小而具体的建议，并说明证据来源。

5. “我有哪些事一直拖着？”
   - Expected tools: `task`, optionally `goal`.
   - Good answer: 展示逾期、无计划、近期待办，指出与目标有关的项。

6. “我最近是不是又进入了老模式？”
   - Expected tools: `memory`, `habit`, `thought`, `finance`, optionally `health`.
   - Good answer: 使用长期/情景记忆辅助，但不覆盖当前事实。

## 5. Verification Commands

Run standalone tests for each new tool:

```bash
swiftc -parse-as-library \
  "Holo/Holo APP/Holo/Holo/Models/AI/Agent/"*.swift \
  "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloDataTool.swift" \
  "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloGoalTool.swift" \
  "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloGoalToolTests.swift" \
  -o /private/tmp/holo_goal_tool_test && /private/tmp/holo_goal_tool_test
```

Repeat for Thought and Task tools.

Run app build:

```bash
xcodebuild build \
  -project "Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/HoloAgentDataCoverageDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

If backend prompt changed:

```bash
cd HoloBackend
npm test
```

Then deploy backend before claiming the feature is live.

## 6. Rollout Strategy

1. Land iOS tools behind existing `agentRuntimeEnabled` path.
2. Verify standalone tests.
3. Verify app build.
4. Run local/manual Agent debug with the acceptance questions.
5. Only if model does not choose new tools, update backend prompt.
6. If backend changed, deploy to ECS and validate public endpoint.

## 7. Non-Goals

- No automatic task creation/editing in Agent loop.
- No medical/psychological diagnosis.
- No full raw thought export.
- No new Core Data schema unless a later card/detail feature requires persisted structured Agent result.
- No large visual redesign in this phase.
