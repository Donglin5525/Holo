# Holo AI Agent 全数据覆盖查漏补缺方案

## 1. 产品结论

当前 Holo AI Agent 不是“完全没接数据”，而是已经有一套本地工具体系，但覆盖深度不一致：

- 财务、习惯、目标、想法、待办已有可用的分析操作。
- 健康底层已经能读取步数、睡眠、站立、活动分钟和运动会话，但 Agent 工具只开放睡眠摘要。
- Profile、历史对话、Memory Insight 在 Holo 的数据覆盖模型中属于正式数据源，却没有 Agent 工具入口。
- 预算、账户、观点 Topic 等用户可感知数据存在于 Repository，但当前工具只覆盖对应模块的一部分。
- 目标与观点工具虽能执行，证据账本却把它们错标为通用 `agent` 来源，导致“读取到了，但利用和归因不完整”。

因此本次目标不是再造一套 AI 上下文，而是把现有 Agent 工具体系补成一个有明确边界、能持续审计的“语义数据访问层”。

## 2. “所有数据可调用”的产品定义

“所有 Holo 数据都能被 Agent 调用”定义为：

1. 所有用户能在产品里创建、连接或看到的核心语义数据，都有只读的 Agent 查询操作。
2. Agent 只能按问题所需读取摘要和证据，不一次性倾倒全部原始数据。
3. 每个数字和观察都能回到明确的数据源、时间范围和证据事件。
4. 权限关闭、设备不支持、样本不足和真正的零值必须尽量区分，不能统一说成“没有数据”。
5. 图片二进制、附件原文件、同步探针、UI 排序、缓存、日志、Agent job/checkpoint 等内部实现数据不直接暴露给模型。

Calendar/记忆长廊等派生视图不重复做一套平行取数工具；Agent 优先读取它们背后的源数据。已经生成并对用户可见的 Memory Insight/周观察属于产品数据，可作为历史观察摘要单独读取。

## 3. 当前覆盖矩阵

| 产品数据源 | 底层数据 | 当前 Agent | 本次决策 |
|---|---|---|---|
| 财务 | 交易、分类、账户、预算 | 交易分析较完整；账户/预算缺失 | 补账户与预算摘要 |
| 习惯 | 习惯、打卡、数值记录、目标关联 | 核心趋势已接 | 保持；报告子字段边界 |
| 待办 | 任务、完成/逾期、列表、标签、检查项、重复规则 | 核心负载/趋势已接 | 保持核心；结构类数据列入后续细化 |
| 目标 | 目标、关联任务/习惯、截止日期 | 已接 | 修正证据来源归因 |
| 观点 | 原文、心情、标签、Topic、关联 | 原文/心情/标签趋势已接；Topic 缺失 | 补 Topic 摘要并修正证据来源 |
| 健康 | 步数、睡眠、站立、活动分钟、运动会话 | 仅睡眠摘要 | 本次完整补齐 |
| Profile | 称呼、城市、职业、关注、沟通偏好、健康目标、敏感边界 | Agent loop 未接 | 补结构化、敏感工具 |
| 对话 | 历史消息、intent、Agent 结果 | Agent 只收到当前问题 | 先补不含原文的近期 intent/活动摘要 |
| Memory Insight | 日/周/月洞察、卡片、用户反馈 | 长期/情景 memory 工具不等价 | 补历史观察摘要；不回灌 rawResponse |
| AI 记忆 | 长期记忆、情景记忆、抑制规则 | 已接 | 保持 |

## 4. 方案选择

### 方案 A：只补健康

优点是改动小、能直接回答本次步数/睡眠/站立问题。缺点是产品原则仍然不成立，Profile、预算、历史观察等缺口继续存在。

### 方案 B：每个存储实体一个工具

表面覆盖最全，但会产生大量低价值工具，增加模型选错工具和 token 消耗；还可能把附件、聊天原文、日志和内部状态暴露给模型。

### 方案 C：按用户语义数据源建立工具与覆盖契约（采用）

每个产品数据源保留一个清晰工具，在工具内用不同 query 暴露高价值只读摘要；增加覆盖清单和注册测试，避免以后新增数据却忘记 Agent 接线。聊天只提供受控元数据摘要，不直接返回历史原文。

## 5. 健康工具设计

`health` 工具扩为六个操作：

- `health_overview`：一次返回步数、睡眠、站立/活动和运动的核心状态，适合“最近身体状态怎么样”。
- `steps_summary`：日均步数、达标天数、逐日步数证据。
- `sleep_summary`：平均睡眠、达标天数、低睡眠天数、逐日证据。
- `stand_summary`：日均站立小时、达标天数、逐日证据。
- `activity_summary`：日均活动分钟、达标天数、逐日证据；无 Watch 时作为站立替代信号。
- `workout_summary`：运动总分钟、会话数、运动天数、主要运动类型和逐日证据。

统一时间口径为 `[start, end)`。Agent 时间解析器本来就是闭开区间，HealthRepository 的范围 API 是包含结束日，因此 Health DataSource 必须把 `end` 转成前一天再查询，避免“上月”多读下月 1 日。无显式时间时默认最近 14 个自然日，包含今天。

每个 query 都返回真实覆盖天数。过滤零值后不能再写 `coverageRatio = 1`；应以请求窗口天数为分母，并对缺失指标返回独立 warning。

## 6. 其他数据工具设计

### Profile

新增 `profile` 工具，仅读取 `HoloProfileSnapshot` 的结构化字段：

- `profile_summary`：称呼、语言、时区、城市、职业等已填写字段。
- `current_focus`：当前关注、生活上下文、健康/习惯目标。
- `preference_boundaries`：沟通偏好与敏感边界。

不把整份 Markdown 原文作为证据；工具敏感度标记为 `sensitive`。

### Conversation

新增 `conversation` 工具，首版只提供：

- `recent_intent_summary`：近期完成消息数量、用户/助手数量、intent 频次。
- `session_activity`：当前会话消息量和最近活动时间。

不返回历史 message content，避免历史文本被当作新指令，也避免把完整聊天重复发送到后端。

### Memory Insight

新增 `insight` 工具，读取日/周/月最近的 ready/stale 洞察标题、摘要、周期和生成时间：

- `latest_observation`
- `recent_observations`

不返回 `rawResponse`、完整 cardsJSON 或用户纠正原文。

### Finance / Thought

- `finance` 增加 `budget_status` 与 `account_summary`，分别覆盖全局预算使用和净资产/账户数量。
- `thought` 增加 `topic_summary`，读取活跃 Topic 的标题、摘要、观点数量和关联标签。

## 7. 证据、安全与错误处理

新增统一证据策略：

- 工具名必须映射到正确 `HoloEvidenceSourceModule`；goal/thought/profile 不再落到 `.agent`。
- `HoloDataToolResult` 可携带可选敏感度，旧持久化 JSON 缺字段时仍可解码。
- Health/Profile/Thought/Conversation/Insight 使用 `sensitive`；其余默认 `normal`。
- 不支持的 query 在 validate 阶段返回 `INVALID_PARAMS`；无权限/无数据返回 `.empty` + 明确 warning，不伪造 0。
- 单个工具失败不阻断 Agent loop，模型可基于其他工具给出带边界的低置信回答。

## 8. Agent 选择与后端 Prompt

工具描述会自动注入 Agent system prompt，但健康问题需要显式选择规则，避免再次出现 intent 已识别为 health、Agent 却请求 habit 的旧故障。

双端同步：

- iOS `PromptManager.swift` 的 `.agentLoop` fallback 增加健康 query 选择表并提升版本。
- 后端 `defaultPrompts.json` 同步相同规则。
- 后端 `promptRegistry.js` 显式登记 `agent_loop` 版本。
- 后端测试断言 prompt 包含步数、睡眠、站立、活动、运动的 query 映射。

## 9. 验证策略

按照 TDD 执行：

1. 先扩 `HoloHealthToolTests`，验证新增 query、指标、事件、空数据、闭开区间覆盖，确认 RED。
2. 为证据来源映射新增独立测试，确认 goal/thought/profile 不再归为 agent。
3. Profile/Conversation/Insight/Finance/Thought 每个新增操作先写 standalone 失败测试。
4. 运行全部 Agent standalone tests；`Executed 0 tests` 不算通过。
5. 运行后端 prompt/chat tests。
6. 运行 iOS `xcodebuild build`。
7. 若后端有改动，部署 ECS 后验证 `/v1/health`、`/v1/prompts/agent_loop` 版本和 prompt 内容。

## 10. 验收问题

至少覆盖这些真实问法：

- “我这周平均每天走了多少步？” → `health.steps_summary`
- “最近睡眠怎么样？” → `health.sleep_summary`
- “这周站立达标了吗？” → `health.stand_summary`
- “没有 Apple Watch 的话，我最近活动够不够？” → `health.activity_summary`
- “最近运动情况怎么样？” → `health.workout_summary`
- “结合睡眠、步数和运动看，我最近状态怎么样？” → `health.health_overview`
- “我最近最关注什么？” → `profile.current_focus`
- “这个月预算还剩多少？” → `finance.budget_status`
- “我最近的观点主要收敛成哪些主题？” → `thought.topic_summary`
- “Holo 上一次观察到了什么？” → `insight.latest_observation`

## 11. 非目标

- 不开放写操作；Agent 不能自动修改 Profile、预算、Topic 或健康数据。
- 不上传附件图片/文件。
- 不把历史聊天原文作为工具结果。
- 不为 Calendar 重复建设一套数据查询层。
- 不在本次重构 Agent loop、Evidence Ledger 或 Core Data schema。
