# Holo Life Agent 每周计划 v1（LifePlan 状态机 + 周计划产品化）

- 日期：2026-08-15
- 状态：方案定稿（东林已拍板关键决策），未动工
- 背景：基于 Manus《Holo 核心 Agent 产品策略补充报告》+ 本地代码核验（报告对 Agent 现状的技术主张逐条验证零误差：触发源、normalDeep/extendedDeep 预算、saveDraft 链路均属实）+ 两轮讨论定稿。核心共识：Agent 从「无状态的聪明回答」升级为「维护计划状态的周期产物」，第一个产物是**本周计划**。

## 已确认决策（东林拍板）

| 决策点 | 结论 |
|---|---|
| 数据模型 | **六对象全量新增**（LifePlan / PlanPriority / PlanAction / PlanSignal / PlanFeedback / PlanRun）。系统有冗余承接能力，接受前期空表换取指标数据源与扩展余量 |
| 计划入口 | **先不改现有入口结构**：不加首页卡片、不动导航、不翻转「对话为中心」形态。入口 = Chat 内自然语言意图触发（「帮我规划这一周」） |
| 生成时机 | iOS 无可靠后台定时执行，**不做「周日自动生成」**。计划过期后，用户下次进 Chat 时提示刷新，打开后现跑（normalDeep 300s 内出结果） |
| 配额 | 第一刀**复用现有 chat 配额**（Agent run 幂等扣一次的机制现成）；独立 `lifePlan` quotaType 放第二刀随后端发版 |
| 与报告的取舍 | 采纳：六对象、L3 计划先行、指标体系、权限边界（只读草案无需逐次确认，写回必须确认+可撤销）。不采纳：首页中心化（入口先不改）、周日定时触发（iOS 现实）、90 天三阶段排期（按批次走） |

## 数据模型（`CoreDataStack+LifePlanEntities.swift`，代码化定义）

新建实体文件 + Repository（`LifePlanRepository`），完全沿用 `CoreDataStack+TodoEntities.swift` 的代码化实体模式与各域 Repository 惯例。全新实体无迁移负担；上线后字段变更需走轻量迁移评估。

### LifePlan（计划主体）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID | |
| scope | String | `"week"` 起步，预留 `"month"` |
| periodStart / periodEnd | Date | 周期起止 |
| status | String | draft → active → completed / superseded |
| constraintSummary | String? | 本周约束摘要（模型生成） |
| snapshotCutoffAt | Date | 数据快照截止，对齐 Job 冻结口径（job.snapshotCutoffAt） |
| version | Int16 | 同周期重生成递增 |
| trigger | String | weeklyPlanning / userQuestion / … |
| dataSufficient | Bool | 生成时数据充分度结论 |
| createdAt / updatedAt | Date | |

关系：priorities（一对多 cascade）、actions（一对多 cascade）、runs（一对多 cascade）、signals（一对多，cascade 或保留由实现定）。

### PlanPriority（优先结果，每计划最多 3 条）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID | |
| plan → LifePlan | 关系 | |
| outcome | String | 结果导向标题（「降体脂到 22%」而非「跑步」） |
| whyNow | String | 为什么是现在（截止临近/习惯断裂/预算触发…） |
| evidenceIDs | String(JSON array) | 指向 Evidence Ledger 证据 ID，点击可溯源 |
| priorityRank | Int16 | 1–3 |
| userDecision | String? | pending / accepted / edited / rejected |
| goalID | UUID? | 确认后创建的 Goal 回链 |

### PlanAction（行动卡，每计划 3–7 张）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID | |
| plan → LifePlan | 关系 | |
| type | String | task / habit / budgetGuardrail(预留不实现写回) / reminder(预留) / defer(预留) |
| draftPayload | String(JSON) | 内嵌 GoalTaskDraft / GoalHabitDraft 子结构；确认时组装 GoalDraft 走 `GoalRepository.saveDraft` |
| expectedBenefit | String? | 预期收益一句话 |
| tradeoff | String? | 取舍说明 |
| evidenceIDs | String(JSON array) | 证据回链 |
| requiresConfirmation | Bool | 默认 true（权限边界：写回必须确认） |
| status | String | proposed → accepted / rejected / completed / expired |
| undoToken | String(JSON)? | 确认落库后写入：创建的 goalId/taskId/habitId 列表，撤销=删除这些实体并回滚 status |
| createdAt / updatedAt | Date | |

### PlanSignal（原始数据变化 → 标准化信号）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID | |
| domain | String | finance / task / habit / health / goal / thought |
| severity / novelty / confidence / actionability / urgency | Float | 评分维度（第三刀偏离检测的输入） |
| evidenceIDs | String(JSON array) | |
| plan → LifePlan? | 可选关系 | 信号可先于计划独立存在 |
| outcome | String | surfaced / dismissed(含 dismissedAt) |
| createdAt | Date | |

### PlanFeedback（用户反馈，学习「用户教得会」）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID | |
| action → PlanAction | 关系 | |
| decision | String | accepted / edited / rejected |
| reasonTag | String? | 预设标签（不需要/时间不够/不喜欢方式/证据不信服…） |
| freeText | String? | |
| createdAt | Date | |

### PlanRun（运行记录：Job ↔ 计划 ↔ 成本）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID | |
| plan → LifePlan | 关系 | |
| jobID | String | HoloAgentJob.id 回链 |
| trigger | String | |
| inputSnapshotVersion | Int16 | 对齐 LifePlan.version |
| consumedBudgetJSON | String(JSON) | 从 job.budget 复制 consumedLLMRounds/ToolBatches/InputTokens/OutputTokens/activeRuntime → 「每个有效计划的成本」指标数据源 |
| resultStatus | String | completed / failedDegraded(降级为普通分析) / failed |
| createdAt | Date | |

### ⚠️ 证据引用保护（报告未覆盖的必做项）

`HoloJobCleanupPolicy` 默认 30 天回收终态 job，`preserveReferencedEvidence` 只认已注册的引用方。**PlanPriority/PlanAction/PlanSignal 的 evidenceIDs 必须注册进该保护机制**，否则计划卡上线一个月后证据链接批量失效——「可追溯」卖点崩塌且难排查。实施时在 Persistence Manager 的引用收集处加 LifePlan 域三处来源。

## 生成链路

1. **意图注册**（依赖意图路由批次先合入）：`intents.json` 注册 `weekly_planning` 意图（示例触发：「帮我规划这一周」「给我做个本周计划」「下周我该专注什么」），handler 创建 Agent Job（`trigger: .weeklyPlanning`，类型沿用深度分析）。生成入口只有这一个——入口先不改。
2. **数据充分度前置**：生成前检查近 7 天 ≥2 个域有有效记录（复用 `HoloDataCoverage`）。不满足时不伪装理解，直接返回「本周还缺哪些信息」+ 轻量补录引导；落 LifePlan(dataSufficient=false) 或不落（实现定，倾向不落库只返回提示）。
3. **生成 prompt**：`PromptManager` 新 purpose `weekly_plan_generation`。输入 = 十域工具上下文 + 上一份计划的 userDecision/完成情况滚动注入（Agent 有状态的起点：知道上周拒绝过什么）；输出 = 结构化 JSON（≤3 优先结果、3–7 行动卡、每条带 evidence 引用与 whyNow）。
4. **schema 校验与降级**：LLM 输出过 JSON schema 校验（外部输出边界，属必要防御）。失败重试 1 次；再失败**降级为普通深度分析文本回复**并落 PlanRun(resultStatus=failedDegraded)，不阻塞不崩溃。
5. **落库渲染**：校验通过 → 组装 LifePlan + PlanPriority + PlanAction 落库 → Chat 消息流插入计划卡。
6. **上一份计划滚动**：新计划生成时，将过期计划标 superseded/completed；其决策与完成数据作为下一份计划的输入注入。

## 呈现与确认（全部在现有 Chat 形态内）

- **计划卡**：仿 `GoalDraftReadyChatCard` 模式挂 Chat 消息流。结构：周期头（周期/状态/version）→ 3 优先结果卡（outcome + whyNow + 证据链接可点开溯源）→ 行动卡列表 → 批量确认入口。
- **确认页**：仿 `GoalDraftReviewView`。逐项勾选/编辑/拒绝（拒绝时可选 reasonTag → PlanFeedback）→ 组装 GoalDraft → `saveDraft` 落 Goal/TodoTask/Habit → 写回 PlanAction.status + undoToken + PlanPriority.goalID。
- **撤销**：确认成功提示条上提供撤销（读 undoToken 删实体回滚），这是权限边界「所有写入可撤销」的兑现。
- **历史查看**：第一刀不做独立入口；Chat 里问「我上周的计划」由读取 LifePlan 表回答（走现有对话链路，不新做 UI）。

## 分期

### 第一刀：纯客户端（本方案主体，无需后端发版）

1. 实体 + Repository + 证据引用保护注册
2. 意图注册 + 触发源 `weeklyPlanning` + Job 创建
3. 生成 prompt + schema 校验 + 降级
4. 计划卡 + 确认页 + 写回 + 撤销 + 反馈
5. 计划滚动（过期标记 + 上下文注入）
6. 本地指标统计（六表直算：计划激活率 = 确认≥1卡÷查看；执行率 = 确认后7天完成≥1÷确认；续航率 = 连续2周期÷首周期；每计划成本 = PlanRun.consumedBudget 汇总）——先本地可查，不做上报

### 第二刀：后端发版（需东林同步排期，实施前单独同步）

- `quotaPolicy.js` 的 QUOTA_TYPES 加 `lifePlan`（每自然周 1 次完整计划，按周窗口计量）+ `deepAnalysis`（月计量），Plus 权益映射同步
- 付费墙文案改版（结果型叙事「每周一份完整生活计划」，额度下沉为公平使用说明）——与配额天然一对，同批发；是否改版由东林届时拍板

### 第三刀：L4 偏离与调整（第一刀留存验证后）

- `planDeviation` 信号检测（PlanSignal 表此时启用：关键任务连续逾期/习惯断裂/预算护栏触发）
- 每日焦点（每天只推一条，带行动选项，可静音）
- 周末复盘 UI（完整复盘卡，替代轻量滚动标记）

## 明确不做（本轮）

- 首页中心化 / 新导航入口（东林拍板：入口先不改）
- 后台自动定时生成（iOS 限制，打开现跑）
- 预算护栏/提醒/延期类行动卡的写回（type 枚举预留，仅任务/习惯两类可落库）
- 日历时间块、外部日历接入
- 长期记忆回答关联（灰度未开，不承诺）
- 埋点上报基建（本地统计先行）
- 医疗诊断/投资建议类输出（prompt 护栏沿用现有边界）

## 风险与约定

- **实施前置**：当前工作区有未提交批次（意图路由 P0–P4、AI 数据补全第一批、体检修复），本方案动工前先验收提交，**不混批**；意图注册依赖意图路由合入。
- **最大新工程是生成质量**：结构化输出稳定性与计划内容质量需 prompt 迭代轮次，验收标准 = 连续生成 10 份计划 schema 通过率稳定 + 内容可被 ClaimVerifier 级别的证据约束。
- 项目用 PBXFileSystemSynchronizedRootGroup：新 .swift 自动编译，无需编辑 pbxproj。
- 每项独立编译通过，不自行提交（等东林验收）。
- 涉及后端的只有第二刀，届时按协作约定单独同步发版内容与影响范围。
