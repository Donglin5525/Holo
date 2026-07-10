# Holo AI Agent 数据覆盖排查报告

日期：2026-07-11
结论：**核心用户语义数据已从 7 类工具扩展为 10 类工具；健康数据从“仅睡眠”补齐为步数、睡眠、站立、活动分钟和运动会话全覆盖。**

## 1. 产品结论

### 1.1 健康链路现在能不能走通

可以。当前链路为：

`HealthKit 授权数据 → HealthRepository → HoloHealthDataSource → HoloHealthTool → Agent evidence → HoloAI 回答`

| 用户问题 | Agent query | 当前能力 |
|---|---|---|
| 最近身体状态怎么样 | `health_overview` | 同时汇总步数、睡眠、站立、活动分钟、运动 |
| 最近走了多少步 | `steps_summary` | 总步数、日均步数、达标天数、逐日证据 |
| 最近睡得怎么样 | `sleep_summary` | 平均睡眠、达标/低睡眠天数、逐日证据 |
| 最近是不是久坐 | `stand_summary` | 平均站立小时、达标天数、逐日证据 |
| 最近活动量怎么样 | `activity_summary` | 平均活动分钟、达标天数、逐日证据 |
| 最近运动了几次 | `workout_summary` | 运动次数、总时长、活跃天数、逐日证据 |

修复前，Holo 已经从 HealthKit 读取上述数据，但 Agent 的 health 工具只开放了睡眠。因此“健康页有步数/站立，AI 却读不到”是一个真实断点，不是 HealthKit 没接。现在这个断点已经补上。

### 1.2 “Holo 所有数据都应能被 Agent 调用”的口径

本轮按**用户可感知的语义数据源**补齐，而不是把 Core Data 表、图片二进制、缓存、日志和内部任务状态全部裸露给模型。这样既满足分析能力，又避免把实现细节、隐私和 prompt-injection 风险放大。

## 2. 全量覆盖矩阵

| Holo 数据域 | Agent 工具 | 覆盖状态 | 本轮变化 |
|---|---|---|---|
| 记账交易/分类 | `finance` | 已覆盖 | 保持既有消费分析 |
| 预算 | `finance.budget_status` | 已覆盖 | 新增预算总额、已用、剩余、使用率 |
| 账户/净资产 | `finance.account_summary` | 已覆盖 | 新增账户数、资产、负债、净资产 |
| 习惯/习惯记录 | `habit` | 已覆盖 | 保持趋势、坏习惯与目标冲突分析 |
| 待办/完成情况 | `task` | 已覆盖 | 保持今日负载、积压风险、完成趋势 |
| 目标及关联待办/习惯 | `goal` | 已覆盖 | 保持目标摘要、进度、截止风险 |
| 观点/情绪/标签 | `thought` | 已覆盖 | 保持观点主题与活动趋势 |
| 观点 Topic/归并主题 | `thought.topic_summary` | 已覆盖 | 新增收敛主题、摘要、观点数、标签证据 |
| 健康：步数 | `health.steps_summary` | 已覆盖 | 本轮新增 |
| 健康：睡眠 | `health.sleep_summary` | 已覆盖 | 既有链路保留并统一窗口口径 |
| 健康：站立 | `health.stand_summary` | 已覆盖 | 本轮新增 |
| 健康：活动分钟 | `health.activity_summary` | 已覆盖 | 本轮新增 |
| 健康：运动会话 | `health.workout_summary` | 已覆盖 | 本轮新增 |
| Holo Profile | `profile` | 已覆盖 | 新增结构化资料、当前关注、偏好与边界 |
| 对话历史 | `conversation` | 受控覆盖 | 新增意图与会话活跃度；不暴露历史原文 |
| 本周/日/月观察 | `insight` | 已覆盖 | 新增最新与近期 Memory Insight 摘要 |
| 长期/情景记忆 | `memory` | 已覆盖 | 保持记忆召回与抑制规则 |
| 日历/记忆长廊 | 来源已覆盖 | 派生视图 | 由记账、习惯、待办、观点、健康等源数据派生，不重复建工具 |

生产注册表增加了覆盖契约：上述 10 类语义工具缺任意一个时，Debug 构建会立即暴露注册不完整，防止以后新增/重构时静默掉线。

## 3. 本轮修复的利用层问题

- Agent prompt 增加确定性工具选择规则，明确把“步数/睡眠/站立/活动/运动”路由到对应 health query。
- 补齐预算、账户、Topic、Profile、Insight、Conversation 的工具选择提示。
- 修复目标和观点证据此前被错误记为通用 `agent` 来源的问题；现在 10 类工具都有正确来源。
- 健康、Profile、对话元数据、洞察、观点等结果标为敏感证据，不再一律当作普通数据。
- 修复健康时间边界：Agent 使用 `[start, end)`，HealthRepository 使用包含结束日的范围；DataSource 现在会把 end 转成前一天，避免“上个月”误带入本月 1 日。
- `agent_loop` prompt 双端升级到 v4，后端版本注册补齐。

## 4. 明确保留的安全边界

以下不是“漏接”，而是有意不直接交给模型：

- 历史聊天原文：只给角色、意图、时间等受控元数据，避免旧消息成为提示词注入通道。
- 图片/语音/附件二进制：附件所属的待办或观点语义可用，但文件本身不作为 Agent 通用数据源。
- Agent job、checkpoint、缓存、同步探针、UI 排序、日志、Prompt 配置：属于实现状态，不是用户分析数据。
- Memory Insight 的模型原始响应、cardsJSON、错误堆栈和反馈内部字段：只暴露已生成观察的标题与摘要。

## 5. 验证证据

- 10 类工具 standalone 回归：Goal、Task、Habit、Memory、Finance、Thought、Health、Profile、Conversation、Insight 全部通过。
- Agent 基础设施回归：`HoloToolRegistryTests`、`HoloToolExecutorTests`、`HoloLocalAgentRuntimeTests` 全部通过。
- HoloBackend 全量测试：85 tests，85 pass，0 fail。
- Holo iOS Debug / iOS Simulator 全工程构建：`BUILD SUCCEEDED`。

## 6. 仍需真机确认的唯一外部条件

代码链路已经走通，但自动化环境无法读取东林真机上的 HealthKit 私有数据。因此最终用户态验证还取决于：

1. Holo 已获得“步数、睡眠分析、Apple 站立小时、锻炼”等读取权限；
2. Apple 健康中相应日期确实有数据；
3. 真机更新到包含本次改动的版本。

建议真机依次问：

- “看看我最近 7 天的综合健康状态。”
- “我最近 7 天平均每天走多少步？”
- “我最近 7 天平均睡多久？”
- “我最近 7 天站立达标了几天？”
- “我最近 7 天运动了几次？”

如果某项授权或数据缺失，Agent 会返回 partial/empty 和对应缺数警告，而不是拿其他指标猜答案。
