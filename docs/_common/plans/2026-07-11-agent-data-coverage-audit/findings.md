# Holo AI Agent 全数据覆盖排查发现

## 已知历史证据（待当前代码复核）

- 2026-06-26 曾修复健康分析链路：新增 `HoloHealthTool` / `HoloDefaultHealthDataSource` 并注册到 `HoloAgentRuntimeShared`。
- 当时线上 intent 已能把“最近状态不好，看看睡眠咋样”识别为 `query_analysis / health / sleep`；旧故障是 intent 正确但 Agent 误用 habit 工具。
- 当时验证包括 `HoloHealthToolTests passed`、后端相关测试通过、iOS build 成功，以及生产 prompt `intent_recognition v20`。
- 以上是历史快照，不代表 2026-07-11 当前代码仍完整；本轮必须复核实现内容、工具能力范围和回归状态。

## 当前工作区状态

- 仓库：`/Users/tangyuxuan/Desktop/Claude/HOLO`，当前分支 `main`，HEAD `6816171`。
- 工作区已有多组未提交改动，涉及观点、PromptManager、Memory Gallery、时间查询计划文件等；本任务必须严格 scoped。
- 根目录已有另一任务的 `task_plan.md` / `findings.md` / `progress.md`，内容属于“时间查询一致性修复”，本任务不覆盖，独立保存在当前目录。

## 待证实问题

- `HoloHealthTool` 当前具体支持哪些 operation，是否同时覆盖步数、睡眠时段/时长、站立小时。
- 默认健康数据源是否查询 HealthKit 原始数据、Holo 缓存数据，还是仅查询日汇总。
- Agent 的工具描述是否足够让模型为“步数/睡眠/站立”选中 health，而不是 habit 或 flexible query。
- 全量数据覆盖计划是否已经被实施；若只停留在计划，需要找出已落地与未落地的差异。

## 当前代码确认：健康链路

- `HealthRepository` 已真实接入 HealthKit 的步数、睡眠、Apple 站立小时、活动分钟和运动会话，并提供日期范围查询；健康页能展示这些数据。
- Agent 注册表确实注册了 `health`，但 `HoloHealthTool` 目前只声明并只接受 `sleep_summary`，DataSource 也只有 `sleepRecords`。因此：
  - 睡眠：Agent 工具链已接入，可产生平均睡眠、达标天数、低睡眠天数和逐日证据。
  - 步数：HealthKit/Repository/旧分析 Context 已接入，但 Agent 工具未接入。
  - 站立：HealthKit/Repository/旧分析 Context 已接入，但 Agent 工具未接入。
  - 活动分钟、运动会话：底层已接入，但 Agent 工具未接入。
- `HealthAnalysisContextBuilder` 是另一条非 Agent 工具链，已同时查询 steps/sleep/stand/active；它不能证明 Agent loop 可调用这些指标。
- `HoloHealthToolTests` 当前只有睡眠成功和无睡眠数据两个用例，没有步数、站立、活动、运动或工具路由覆盖。
- 默认 `HoloDefaultHealthDataSource` 把无显式 range 的 `end` 设为“今天 0 点”，且范围查询包含 endDay；历史方案明确要求 14 天窗口用“明天 0 点”避免漏今天，当前默认边界需在实现中统一澄清。

## 当前 Agent 工具覆盖（初步）

生产 runtime 当前注册 7 个工具：

| 数据域 | 已支持操作 | 初步判断 |
|---|---|---|
| memory | 长期记忆摘要、情景记忆、抑制规则 | 已接入，需核对是否覆盖 Memory Insight/周观察等派生数据 |
| habit | 趋势、负向习惯控制、目标冲突 | 已接入核心统计 |
| finance | 周期支出拆解、消费模式、餐饮时段、分类集中度、关键词趋势 | 已接入交易分析；预算/账户资产类尚未看到 Agent 操作 |
| health | 仅睡眠摘要 | 严重部分接入；步数、站立、活动分钟、运动会话缺失 |
| goal | 活跃目标、进度上下文、截止风险 | 已接入核心分析 |
| thought | 心情、主题、活跃趋势 | 已接入核心分析；Topic/归并结果是否可读待核 |
| task | 今日负载、积压风险、完成趋势 | 已接入核心分析 |

已看到但尚未有独立 Agent 工具/操作的用户数据：预算、财务账户、Topic/观点归并、Memory Insight/周观察、聊天历史、个人 Profile、日历/排期，以及健康中的步数/站立/活动/运动。后续要区分“应直接暴露给 Agent 的产品数据”与“内部缓存/配置/任务状态”。

## Agent 利用层的额外断点

- `HoloLocalAgentRuntime.sourceModule(for:)` 当前只映射 finance/habit/memory/task/health；已经注册并能执行的 `goal`、`thought` 会被错误记成 `.agent`。这会破坏证据来源语义，属于“能读但没被正确利用/归因”的确定缺口。
- `HoloEvidenceSourceModule` 已预留 `.profile`，但生产 runtime 没有 profile 工具；这说明架构预期存在而接线尚未完成。
- `HoloMemorySource` 的产品数据源枚举共有 finance/tasks/habits/thoughts/goals/health/profile/conversation/memoryInsight 九类。当前 Agent 直接工具覆盖前六类（health 仍部分），memory 工具读取的是长期/情景记忆与抑制规则，不等价于 conversation 或 MemoryInsight。
- Agent loop 初始请求只注入当前问题和工具描述，没有注入 `UserContextBuilder` 已构建的 profile/account/recentTrend/最近洞察。因此标准分析链路能见的数据，不会自动出现在 Agent loop。
- iOS fallback 的 `agentLoop` 已是 v3，后端 `PROMPT_VERSIONS` 却未显式登记 `agent_loop`（缺省基线 v1）；默认 prompt 双端版本契约不完整。
- 后端 `agent_loop` prompt 只显式指导 finance 工具选择，没有健康工具选择规则；扩健康操作后应补“步数/睡眠/站立/活动/运动 → health 对应 query”的确定性指引。

## 产品范围判断

- “所有数据可调用”应定义为：所有用户可感知、可用于分析的语义数据源都有只读工具操作；不要求把图片二进制、同步探针、UI 排序配置、缓存、Agent job/checkpoint、日志等内部实现数据暴露给模型。
- Calendar/记忆长廊大多是财务、习惯、待办、想法、健康的派生视图，应优先保证源数据可查询；派生洞察（MemoryInsight/周观察）本身仍应作为单独的“过去已生成观察”被调用。
- 聊天历史含历史指令文本，直接作为 tool result 送入模型有 prompt-injection 与隐私放大风险；应先做“当前会话上下文注入/受控摘要”设计，不宜和健康 P0 一起裸接原文。

## 实施后结论

- 生产 Agent 已由 7 类工具扩为 10 类：memory、habit、health、finance、goal、thought、task、profile、conversation、insight。
- health 已覆盖 overview、steps、sleep、stand、activity、workout；原先仅睡眠可用的断点已消除。
- conversation 采用角色/意图/时间元数据，不读取消息原文；insight 只读取已生成观察的标题和摘要。
- Calendar/记忆长廊按派生视图处理，其源数据和已生成 Insight 均已可查询，不重复建一个宽泛 calendar 工具。
- 自动化不能访问真机 HealthKit 私有数据；代码、工具、路由和构建链路已验证，真实数值仍需真机授权与数据存在作为外部条件。
