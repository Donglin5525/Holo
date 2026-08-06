# Holo Agent P0 四项能力实施方案

- 状态：Proposed
- 日期：2026-07-29
- 适用范围：Holo Chat 深度 Agent、Agent Runtime、Evidence / Verifier、Agent Eval、HoloBackend 发布与可观测性
- 关联规范：
  - `docs/standards/Holo-Agent研发与验收规范.md`
  - `docs/_common/plans/2026-07-26-Holo-Agent统一答案展示架构ADR.md`
  - `docs/_common/plans/2026-07-19-Holo-Agent真机与灰度验收清单.md`

## 1. 产品结论

当前 Holo Agent 的主要缺口已经不是“还能不能多查一种数据”，而是用户能否持续信任它：

1. 上一轮分析能不能自然接着问、纠正和换范围；
2. 同一个指标在 Tool、Evidence、Claim 和展示中是否始终是同一口径；
3. 本地 fixture 通过后，真实模型、真机和灰度用户是否也稳定；
4. 出现问题时，能否证明用户实际命中了哪一版后端、Prompt、协议和模型。

这四项不是四个互不相关的功能。它们共同组成一个可信闭环：

`连续追问 → 复用可信证据 → 真实链路门禁 → 线上版本可证明、问题可定位`

建议实施顺序：

1. **P0-4 生产发布身份**：先恢复“线上版本可证明”，它是后续所有生产验证的前提；
2. **P0-2 指标唯一身份**：先让上一轮证据具备可安全复用的稳定口径；
3. **P0-1 连续追问**：在现有 Job / Result / Evidence 上增加 lineage 和结构化追问上下文；
4. **P0-3 真实质量门禁**：从第一阶段开始建设，最后作为前三项能否放量的统一 Go / No-Go。

## 2. 工作量与复杂度判断

| P0 | 复杂度 | 粗略工程量 | 难点 |
|---|---:|---:|---|
| P0-4 生产发布身份与可观测性 | 中 | 3–5 个工程日 | 发布证明、版本信封与隐私安全聚合 |
| P0-2 指标唯一身份 | 中 | 3–5 个工程日 | 新旧结果兼容、动态与固定工具统一 |
| P0-1 连续追问与纠正 | 中偏高 | 5–8 个工程日 | 正确承接、证据复用、快照与跨天生命周期 |
| P0-3 真实模型 / 真机 / 灰度门禁 | 中偏高 | 4–6 个工程日 + 3–7 天观察 | 非确定性模型、真机生命周期、样本与发布判定 |

四项直接相加为 15–24 个工程日；质量门禁与可观测性有一部分共用工程，单人聚焦后的有效粗估约 **13–21 个工程日**，其中真机和灰度观察时间不能用编码并行完全消除。

连续追问如果只做 Demo，1–2 天即可把上一段聊天塞进 Prompt；但这种实现会串错主题、引用过期数字、跨天断链，也无法审计。达到可给用户使用的 P0，复杂度属于中偏高，但**不需要重写 Agent Runtime**：现有 Job、Checkpoint、Result、Evidence、Scheduler、恢复链路都能复用，主要工作是补齐它们之间的跨 Job 关系。

## 3. 总体架构决策

### ADR-P0-01：已完成结果不可变，追问创建子 Job

- 状态：Proposed
- 决策：上一轮完成的 Job / Result 保持不可变；每次追问创建新的 child Job，并记录 `rootJobID / parentJobID / parentResultID / relation`。
- 原因：保留当时的时间范围、数据快照、结论和证据，避免用户纠正后历史答案被静默改写。
- 代价：需要 lineage 清理策略和跨 Job Evidence 引用。
- 否决方案：恢复并改写已完成 Job。它会破坏唯一结果、恢复、审计和历史回看。

### ADR-P0-02：继承结构化事实，不继承整段聊天

- 状态：Proposed
- 决策：追问只继承上一轮已验证 claims、Evidence 引用、权威时间范围、回答任务和未完成交付物；不把完整聊天记录作为事实上下文。
- 原因：聊天文字包含模型表达和过时信息，不是数值真相源；完整历史还会放大隐私、token 和串题风险。
- 代价：需要一个有版本的 `HoloAgentFollowUpContext`。
- 否决方案：把最近 N 条消息无差别放进 Prompt。

### ADR-P0-03：指标别名只允许出现在输入边界

- 状态：Proposed
- 决策：Tool 创建指标时生成稳定 canonical identity；进入 Evidence、Claim、Verifier 后按 identity 精确匹配。`metricKey` 和自然语言别名仅用于输入适配和旧结果兼容。
- 原因：当前“同领域 token 重叠即可匹配”的规则仍可能混淆同域不同口径指标。
- 代价：模型协议和历史 Evidence 需要兼容迁移。

### ADR-P0-04：质量门禁分层，真实模型不直接阻塞每次 PR

- 状态：Proposed
- 决策：PR 使用确定性 fixture 和录制轨迹回放；候选版本使用真实模型评测；发版前必须通过真机生命周期；放量必须满足 TestFlight 样本门槛。
- 原因：真实模型有成本和波动，不适合替代单元门禁；纯 fixture 又无法证明真实规划和表达。
- 代价：需要保存版本化评测报告，并区分“代码回归失败”和“模型波动”。

### ADR-P0-05：生产发布证明 fail closed

- 状态：Proposed
- 决策：生产的 commit、source digest、build time、Prompt 版本或协议身份缺失时，部署不得报告成功。
- 原因：`health = 200` 只能证明服务活着，不能证明目标代码和 Prompt 已上线。
- 代价：发布脚本更严格，错误配置会阻止发版；这是期望行为。

## 4. P0-1：连续追问、纠正与换范围

### 4.1 用户应该获得什么

用户不需要进入“追问模式”，直接在上一份 Agent 分析后输入：

- “为什么你觉得餐饮是主要问题？”
- “第二点具体说说。”
- “那睡眠呢？”
- “换成今年看。”
- “不是总金额，我问的是购买频率。”

Holo 应知道用户在承接哪一份分析，并根据关系采取不同动作：

| 追问关系 | 用户意图 | 系统动作 |
|---|---|---|
| `explain` | 解释已有结论 | 沿用父 Result 的快照和 Evidence，默认不重新查数据 |
| `drillDown` | 深挖某条结论 | 复用相关 Evidence，只查询缺失部分 |
| `changeScope` | 换时间、领域或维度 | 继承问题目标，不复用已失效的数值，按新范围重新规划 |
| `correct` | 纠正理解或口径 | 保留父结果，重建 AnswerTask 和子 Job，不静默篡改历史 |
| `newTopic` | 开始新问题 | 不继承父 Job |

P0 不包含：

- 无限期、跨所有聊天的自由联想；
- 把用户一句纠正自动写回财务、健康等原始数据；
- 让追问绕过确认直接执行高风险操作；
- 用完整聊天历史替代长期记忆。

### 4.2 三种“多轮”必须分开

1. **同一 Job 内模型多轮**：模型规划、调用工具、继续推理；继续使用现有 `checkpoint.conversationState`。
2. **同一 Job 等待用户澄清**：Job 尚未完成，用户补充信息后恢复原 Job。
3. **已完成结果后的追问**：创建 child Job，继承父 Result 的结构化事实。

如果把三者合成一个“历史消息数组”，取消、恢复、结果唯一性和审计都会失真。

### 4.3 新增结构化契约

#### `HoloAgentLineage`

建议作为可选字段加入 `HoloAgentStartRequest`、`HoloAgentJob` 和 `HoloAgentResult`：

```swift
struct HoloAgentLineage: Codable, Equatable, Sendable {
    var rootJobID: String
    var parentJobID: String
    var parentResultID: String
    var relation: HoloAgentFollowUpRelation
}
```

旧 Job 缺失该字段时按独立根 Job 解码，避免迁移阻塞。

#### `HoloAgentFollowUpContext`

它不是一份新聊天历史，而是给 child Job 的结构化工作区：

- 父问题与父 `HoloAgentAnswerTask`；
- 父 Job 的 `primaryTimeRange / baseline / snapshotCutoffAt`；
- 已验证 claim ID、类型化 metric assertions；
- 被引用的 Evidence IDs；
- 已交付和未完成的 deliverables；
- 本轮用户的纠正或范围变更；
- schema version 与确定性截断信息。

持久化时优先保存引用和稳定结构，不复制完整 Evidence 或模型原文。Prompt 只渲染与本轮追问相关的最小子集。

### 4.4 路由与锚点解析

新增 `HoloAgentFollowUpResolver`，职责只有两个：

1. 从当前 Chat 消息的邻接关系中选择**候选父 Agent 消息**；
2. 判定本轮是 `explain / drillDown / changeScope / correct / newTopic`。

约束：

- 只允许使用当前用户消息之前、同一聊天上下文中、已完成且可读取 canonical Result 的 Agent 消息；
- 不读取“全局最后一个 Agent Result”；
- 明确的新记账、建任务、删除等执行意图优先，不得被追问路由劫持；
- “为什么、第二点、换成今年、不是 X 是 Y”等明确指代可确定性识别；
- 开放性或模糊判断可交给 Router / 模型，但只输出闭集 relation，不允许模型自行选择任意历史；
- 无法确定父结果时，宁可按新问题处理或澄清，也不能静默串到错误结果。

Chat 入口复用现有 `assistant.parentMessageId → user message ID`，并把本轮 user message ID 传给 Resolver；Scheduler 增加由 `sourceMessageID` 反查 Job 的只读能力，用于把上一条 Agent AI 消息解析成 canonical parent Job / Result。

### 4.5 Runtime 执行策略

child Job 仍走现有完整链路：

`Job → Checkpoint → Tool → Evidence → Verifier → Result → Renderer`

差异只在初始上下文：

- `explain`：父 Job 的快照继续有效；默认零新增工具调用，结论仍由父 Evidence 支撑；
- `drillDown`：父 Evidence 加入 `inheritedEvidenceRecordIDs`，只补查缺少的指标；
- `changeScope`：沿用主题和交付目标，但时间范围由新 child Job 冻结；父数值不得冒充新范围事实；
- `correct`：把纠正转成新的 AnswerTask 约束，重新规划；父 Job / Result 保持不变；
- 新 child Result 的 Evidence 必须来自“继承且有效”或“本轮新生成”两种明确来源。

展示层只消费 child Result，不自行拼接父卡片文字。详情页可披露：

- “基于上一份分析继续”；
- 沿用的分析日期或范围；
- 复用 Evidence 数 / 新增 Evidence 数。

首屏不增加复杂控制器或模式选择。

### 4.6 时间、新鲜度与跨天

- 解释父结论时，继续使用父 Job 的 `snapshotCutoffAt`，不能把旧结果说成“当前最新”；
- 用户出现“现在、最新、截至今天、换成本月”等语义时，新 child Job 必须冻结新快照并重新查询；
- 父 Result 默认可在现有 30 天保留期内承接；
- 清理器增加 lineage 引用保护：仍被未过期 child Job 引用的父 Job / Result 不得级联删除；
- 父 Result 或 Evidence 已不存在时，不伪造连续性：重新分析，或明确说明无法复用原依据；
- lineage 必须禁止环、限制最大继承深度，并将 Prompt 上下文确定性压缩，避免链条越长 token 越大。

### 4.7 可靠性与恢复

- child Job 有独立 generation、checkpoint、预算、取消和 canonical Result；
- 重试发送同一用户消息不得创建两个有效 child Job；
- 取消 child Job 不影响父结果；
- 冷启动恢复后仍能由 child 的 `sourceMessageID` 回填原 AI 消息；
- 父 Job 失败、取消或 `unverifiable` 时不能成为默认可信锚点；
- 同时存在运行中 Job 与新追问时，必须按现有 Scheduler 预算和抢占规则处理，不另建平行队列。

### 4.8 连续追问验收矩阵

| 场景 | 必须结果 | 禁止结果 |
|---|---|---|
| “为什么这么判断” | 绑定上一份完成结果，引用父 Evidence | 重新猜一个新主题 |
| “第二点呢” | 精确定位第二条 claim / recommendation | 仅根据自然语言序号猜错 |
| “换成今年” | 新时间范围、新快照、重新查数 | 沿用父范围数值 |
| “那睡眠呢” | 继承整体目标，切换健康工具 | 把财务 Evidence 当健康证据 |
| “不是金额，是频率” | relation=`correct`，新 AnswerTask | 覆盖或删除父结果 |
| 清晰新话题 | 正常进入新 intent | 被最近 Agent 卡片劫持 |
| 父结果被清理或损坏 | 透明重查或澄清 | 假装已经复用 |
| 数据在两轮之间变化 | 解释旧结论仍标旧快照；新分析查新数据 | 混合两个快照 |
| 锁屏、断网、冷启动 | child Job 可恢复且只产生一个 Result | 永久运行、双执行、重复 Result |
| 快速重复发送 | 幂等命中同一 child Job | 产生两条不同结论 |

至少覆盖财务、健康、习惯和一个跨域链路；每类关系同时覆盖短指代和完整问法。

## 5. P0-2：指标语义唯一身份

### 5.1 产品问题

用户看到的“平均步数”“总金额”“完成率”必须从计算到展示始终是同一个指标。当前类型化语义已解决了大量展示猜测，但 Verifier 为兼容固定指标和动态指标，仍允许 `metricKey` 只要有两个同域 token 重叠就视为相容。该规则无法严格区分：

- 平均值与总和；
- 当前值与变化率；
- 同领域不同数据集；
- 分类 A 与分类 B；
- 相同单位但不同统计窗口。

连续追问会放大这个风险，因为它需要安全复用旧 Evidence。

### 5.2 数据契约

在现有 `HoloMetricSemantic` 上增加版本化 `HoloMetricIdentity`，不建立第二套 Catalog：

```swift
struct HoloMetricIdentity: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var domain: HoloEvidenceSourceModule
    var datasetID: String
    var measure: HoloMetricMeasure
    var operation: HoloMetricOperation
    var valueRole: HoloMetricValueRole
    var dimension: HoloMetricDimension?
    var dimensionValueID: String?
}
```

原则：

- identity 由 `HoloMetricSemanticFactory` 在 Tool 产出时确定性生成；
- `dimensionValueID` 使用稳定原始值，不使用可能变化的展示文案；
- Tool Result、Evidence Record、Metric Assertion 传递同一 identity；
- Verifier 对新数据按 identity 精确匹配，再校验 value / unit / window；
- 模型只能复制工具提供的 canonical ID，不能自行创造；
- 历史 Evidence 缺 identity 时进入唯一兼容适配器，保留旧规则但记录 `legacyMetricFallback`。

### 5.3 迁移顺序

1. 给语义模型加可选 identity，保证旧 JSON 可解码；
2. 动态查询和固定工具统一从 Factory 生成 identity；
3. Evidence 落盘保存 identity；
4. Prompt / 响应协议允许 assertion 复制 canonical ID；
5. Verifier 新结果强校验 identity；
6. Renderer 仍只读类型化 semantic，不读取 canonical ID 猜展示；
7. 统计旧兼容命中率，达到可接受水平后再移除宽松匹配。

### 5.4 验收

- 同指标不同问法得到同 identity；
- 同领域的 sum / average / percentageChange 不得互相引用；
- 分类值不同不得因 metricKey 相似而通过；
- fixed tool 与 dynamic query 表达同一业务指标时可显式归一；
- 跨领域相关性左右数据集和窗口可追溯；
- 新结果 `legacyMetricFallback = 0`；
- 旧消息仍可展示，但不得被升级成比原证据更强的结论。

## 6. P0-3：真实模型、真机与灰度质量门禁

### 6.1 四层门禁

#### Gate A：确定性契约门禁（每次 PR）

复用现有 165+ Eval，并增加：

- 连续追问 relation、lineage、Evidence 复用和新话题防劫持；
- canonical metric identity 碰撞与错配；
- release manifest / 版本字段；
- 历史 JSON 兼容；
- 后台、取消、恢复和幂等状态机。

该层不调用 LLM，失败必须阻止合入。

#### Gate B：录制轨迹回放（每次 PR）

将真实 Provider 的脱敏响应保存成版本化 trajectory fixture，回放：

`模型原始输出 → Parser → Runtime 决策 → Tool 结果注入 → Verifier → Renderer`

目的不是模拟模型聪明程度，而是防止真实 JSON / SSE / tool call 形态再次让 Runtime 解析中断。

fixture 不保存用户原始敏感内容，只保存最小化的合成输入和脱敏输出。

#### Gate C：真实模型候选版评测（候选版本 / Prompt 变更）

对生产候选模型和 Prompt 运行固定核心集，至少包含：

- 现有跨领域主问题；
- 多轮追问四类关系；
- 模糊短问句；
- 时间范围变化；
- 工具失败、空数据、覆盖不足；
- 诱导因果、诱导编造和协议破坏。

每个硬事实用例至少重复两次。报告必须绑定：

- 后端 commit / source digest；
- Prompt type / version / digest；
- 模型 provider / model ID；
- Agent protocol / tool schema version；
- fixture corpus version；
- 通过率、失败样本、token、延迟和成本。

硬性零容忍：

- 错误硬数字；
- Evidence 不存在或口径不一致；
- 时间范围冲突；
- 隐私原文进入不允许的日志；
- 同一 Job 双执行或重复 canonical Result；
- 解析失败后在预算内提前终止且无恢复。

模型总体完成率和追问承接正确率不得低于 95%；明确指代绑定错误、新话题被错误继承均视为硬失败。

#### Gate D：真机与 TestFlight

直接复用现有验收清单：

- 内部：至少 2 台 iOS 26 真机、30 个主动 Job、持续 2–3 天；
- 第一档：至少 10 名用户或 100 个有效 Job、持续至少 3 天；
- 正常网络完成率 ≥95%，条件恢复完成率 ≥95%；
- 回到 active 后 2 秒内进入执行或明确等待状态；
- crash-free sessions ≥99.5%；
- 扩大默认开启前累计至少 300 个有效 Job、连续 7 天，且无清单中的 P0 事故。

连续追问需单独统计：

- 正确绑定率；
- 错误继承率；
- 新增工具调用数与 Evidence 复用率；
- 用户立即改口率；
- child Job 完成 / 恢复 / 取消率。

### 6.2 发布判定

一次候选版本只有同时满足以下条件才可放量：

`Gate A PASS + Gate B PASS + Gate C 有版本化报告且过线 + Gate D 达到样本门槛`

不能使用以下说法替代：

- “本地编译成功”；
- “跑了 165 条 fixture”；
- “health 返回 200”；
- “暂时没收到用户反馈”；
- “0 次失败”，但样本数为 0。

## 7. P0-4：生产发布身份与整体可观测性

### 7.1 先修发布证明

当前代码已经有严格的 `verify-production-release.sh`，会拒绝 release identity 为 `unknown`；但 `deploy.sh` 只检查公网响应含服务名，因此仍可能报告部署成功。

实施：

1. `deploy.sh` 计算并冻结本次 expected commit、source digest、build time；
2. 容器强制重建后调用统一的严格验证脚本；
3. 验证脚本新增 expected commit / expected source digest 精确比较；
4. identity 缺失、unknown、与 expected 不一致或 build time 不属于本次部署，发布失败；
5. 管理员状态同时验证 Prompt 版本 / digest、路由、数据库和安全能力；
6. 报告保存为可归档 release proof，禁止只靠终端口头成功；
7. 失败时保留上一可证明版本，不宣布生产已更新。

公开 `/v1/release/status` 只暴露无敏感的发布身份；Prompt 内容继续只在管理员鉴权接口中读取。公开 `/v1/prompts/meta` 维持关闭不属于故障。

### 7.2 增加 Agent 端到端版本信封

每个 Agent 请求和质量事件携带非敏感版本信封：

- iOS app version / build；
- Agent protocol version；
- tool schema version；
- Prompt type / version；
- provider / model ID；
- backend release commit / source digest；
- Job generation 与 root / parent 是否存在。

它用于回答“这次用户到底跑了哪一版”，不携带用户原文。

### 7.3 隐私安全的整体遥测

设备本地事件保留详细调试能力；服务端只收集可聚合字段：

- 状态迁移、耗时、重试、恢复、取消、expiration；
- 工具名称、调用数、成功 / 失败码；
- Parser 修复次数、协议失败码；
- Verifier verified / degraded / rejected 数；
- Evidence 复用 / 新增数量；
- follow-up relation、是否正确完成、是否发生重新路由；
- token、模型成本、首结果和总耗时；
- app / OS / release / Prompt / model 版本。

禁止上传：

- 用户原始问题；
- 财务、健康、观点、任务的业务原文；
- Evidence excerpt；
- 完整模型响应；
- 可反推出用户身份的自由文本。

### 7.4 运营视图与告警

按 release / Prompt / model / app build 切片观察：

- 有效 Job 完成率与恢复完成率；
- 解析失败率和预算耗尽率；
- 错误继承率、追问改口率；
- Verifier 拒绝率与 legacy metric fallback；
- 重复 Result、stale rejection、幂等冲突；
- p50 / p95 延迟、token 与成本；
- crash / watchdog / 后台能耗信号。

任何指标只有在分母达到最低样本数后才显示成功率，避免把“没有数据”解释成“100% 正常”。

## 8. 分阶段实施计划

### Phase 0：基线冻结与事故集（0.5–1 天）

- 冻结当前协议、Prompt、Eval corpus 和生产 release 状态；
- 把 `release identity unknown`、短追问串题、同域指标错配加入永久回归；
- 建立每项 P0 的 before / after 报告模板。

完成标准：四个缺口都有可重复失败证据，不依赖口头描述。

### Phase 1：发布身份 fail closed（1–2 天）

- 收口 deploy 与 verify 脚本；
- 补 expected identity 精确断言；
- 本地后端测试；
- 在得到生产部署授权后发布并生成 production proof。

完成标准：公网 release identity 不再是 unknown，且能与本次源码 digest 精确对应。

### Phase 2：canonical metric identity（3–5 天）

- 新增 identity 契约和兼容解码；
- 动态 / 固定 Tool 全部由 Factory 生成；
- Evidence / Claim / Verifier 全链路接入；
- 补跨域和错配对抗测试；
- 升 Agent 协议 / Prompt 版本。

完成标准：所有新 Evidence 使用 canonical identity，Verifier 新链路不再依赖 token 重叠。

### Phase 3：连续追问主链路（5–8 天）

- Chat 候选父结果解析；
- lineage 和 child Job；
- `HoloAgentFollowUpContext`；
- relation 路由；
- Evidence 继承与范围失效规则；
- 清理引用保护；
- Renderer / Detail 的追问披露；
- 取消、恢复、冷启动、幂等与跨天测试。

完成标准：四类追问在财务、健康、习惯和跨域中闭环；新话题不被错误继承。

### Phase 4：真实质量门禁（4–6 天，可与 Phase 2–3 交叉）

- 录制轨迹回放；
- 真实模型候选评测 runner；
- 版本化报告；
- 端到端版本信封和隐私安全聚合；
- Go / No-Go 自动汇总。

完成标准：候选版能用一份报告证明代码、Prompt、模型、协议、真机和线上版本。

### Phase 5：真机与灰度（3–7 天观察）

- 2 台真机 / 30 Job 内部验证；
- 10 用户或 100 Job 第一档；
- 达标后再进入 300 Job / 7 天扩大验证；
- 任一 P0 硬事故直接 No-Go。

完成标准：达到现有灰度清单门槛，而不是“主观感觉已经稳定”。

## 9. 主要风险与控制

| 风险 | 用户影响 | 控制 |
|---|---|---|
| 追问绑定错父结果 | 一本正经回答错误主题 | 消息邻接 + canonical parent；模糊时不静默继承 |
| 旧 Evidence 被当成当前数据 | 用户误以为是最新结论 | 父 snapshot 固定；涉及“现在/最新”必须新查 |
| 同域不同指标误匹配 | 数字看似有证据但口径错误 | canonical identity 精确校验 |
| lineage 过长 | 延迟、token 和成本增长 | 只取相关已验证事实；限制深度和上下文预算 |
| 父 Job 被清理 | 跨天追问断链 | lineage 引用保护；缺失时透明重查 |
| 真实模型门禁波动 | 发布节奏不稳定 | PR 回放确定性；live gate 仅候选版执行并重复样本 |
| 遥测泄露用户数据 | 隐私与商用风险 | 服务端只收闭集枚举和数值，不收自由文本 |
| deploy 误报成功 | 本地改了但线上未生效 | identity unknown / mismatch 直接失败 |

## 10. P0 总体验收

四项全部满足后，才可以把 Holo Agent 定义为“可小范围托付使用”：

- 用户能自然追问、纠正、换范围，新话题不会串线；
- 每个新数值从 Tool 到 Evidence、Claim、Verifier 使用同一 canonical identity；
- 真实模型在版本化核心集上通过硬门禁；
- 真机的锁屏、断网、冷启动、取消和恢复不破坏唯一结果；
- TestFlight 达到既定样本量和完成率；
- 每个线上 Job 都能回答命中了哪一版 app、后端、Prompt、模型和协议；
- 线上异常能按错误码和版本聚合定位，不需要读取用户隐私原文；
- 生产 release identity 不允许 unknown。

完成这组 P0 后，Holo 才从“单轮结果偶尔很好”进入“多轮过程可持续、错误可发现、版本可证明”的阶段。
