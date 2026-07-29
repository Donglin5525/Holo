# Holo Agent 连续追问完整产品与技术方案

- 状态：第三轮对抗性审查已完成，P0 文档修订已回填；进入实施前仍须先通过 Release Prompt 链和 Phase 0 契约门禁
- 日期：2026-07-29
- 适用范围：HoloAI Chat 中由用户主动发起的深度 Agent 分析
- 不适用范围：Observer 自动任务、Memory Gallery 回放、未经确认的自动执行
- 关联文档：
  - `docs/_common/Holo-Agent研发与验收规范.md`
  - `docs/_common/plans/2026-07-26-Holo-Agent统一答案展示架构ADR.md`
  - `docs/_common/plans/2026-07-29-Holo-Agent-P0四项能力实施方案.md`
  - `docs/_common/plans/2026-07-19-Holo-Agent真机与灰度验收清单.md`

## 1. 产品结论

这次改造不是给模型增加“最近几条聊天记录”，而是把 HoloAI 从：

> 每问一次，生成一份彼此孤立的分析报告

改造成：

> 用户可以围绕一份可信分析继续解释、深挖、纠正、换范围和跨领域验证；Holo 始终知道在承接哪份结果，并且不会把旧结论、旧时间范围或无关聊天污染进新答案。

产品形态仍然保留在当前 HoloAI Chat，不增加独立的 Agent 工作台。用户能看到的主要变化是：

1. Agent 卡片增加“继续追问”；
2. 输入框上方可以显示当前绑定的分析；
3. 简单解释使用轻量追问回复，不重复堆完整卡片；
4. 重新计算产生新 Agent 卡片，并明确标注“沿用旧依据”还是“已重新查询”；
5. 详情页可以从当前分析继续，也能看到本次结果承接自哪一份分析；
6. 历史卡片过期后仍可阅读，但不能伪装成仍可复用的实时分析。

本方案不以“承诺绝对没有任何未来 Bug”为完成标准，而以：

- 不遗留已知架构缺口；
- 所有高风险失败都有明确产品行为；
- 所有事实继承都有可验证的技术边界；
- 三轮 Review 发现的问题必须在方案内修正；
- 实施后通过自动化、真实模型、真机和灰度门禁；

作为可交付标准。

## 2. 用户承诺

连续追问上线后，Holo 对用户做出六个明确承诺：

1. **不失忆**：用户说“为什么”“第二点呢”时，Holo 能承接正确分析。
2. **不串题**：用户开始记账、建任务或聊新话题时，旧分析不会偷偷影响新问题。
3. **不混时间**：从“最近一个月”换成“今年”后，旧数字不会进入年度结论。
4. **不改历史**：用户纠正口径后，原分析保留，新分析成为一个独立结果。
5. **不把话术当事实**：只有通过 Verifier 的 Claim 和 Evidence 能进入下一轮事实 Context。
6. **不隐藏承接关系**：用户能看到 Holo 正在继续哪份分析，并能一键取消绑定。

## 3. 本期目标和非目标

### 3.1 必须实现

- 当前 Agent 结果后的自然相邻追问；
- 从任意仍可读取的历史 Agent 卡片显式继续；
- 解释已有结论；
- 深挖某条结论或建议；
- 纠正统计口径；
- 更换时间范围、领域或维度；
- 基于父 Evidence 补查新数据；
- child Job 独立取消、恢复、失败和完成；
- 上下文污染防护；
- Result 生命周期、过期和降级；
- 连续十轮以上时 Prompt Context 不随历史线性膨胀；
- 锁屏、断网、冷启动、重复发送下只产生一个 canonical Result。

### 3.2 不在本期偷偷扩张

- 不做任意跨所有聊天的无限记忆；
- 不让模型从几十轮自然语言中自由选择历史；
- 不把用户一句纠正直接修改财务、健康等原始数据；
- 不允许 Agent 绕过现有确认卡直接创建、删除或修改记录；
- 不把完整聊天历史、完整 Evidence 原文或敏感内容上传为追问 Context；
- 不让 Observer 自动任务承接用户 Chat 的分析线程。

### 3.3 执行型延伸的边界

用户说：

> 把第一条建议建成待办。

这不是新的分析 child Job，而是“从 Result 发起执行”：

- 只解析被选中的稳定 Recommendation ID；
- 生成现有待办确认卡；
- 用户确认后才落库；
- Action 记录 `sourceResultID / sourceRecommendationID`；
- 不把整份 Agent Context 传给执行 Router。

这保证分析和执行可以衔接，但不引入未经确认的自主操作。

### 3.4 与《P0 四项能力实施方案》的关系

两份方案不是并行重复实施：

- `2026-07-29-Holo-Agent-P0四项能力实施方案.md` 是 P0 总路线，决定四项能力的依赖、阶段和统一上线门禁；
- 本文是 P0-1“连续追问”的唯一详细产品与技术规格，负责具体交互、lineage、Context、生命周期和失败行为；
- Job、Result、Evidence、Lineage 等共享模型只修改一次；连续追问相关字段和语义以本文为准，总方案只保留摘要和依赖；
- 实施顺序为：Release 发布身份与 Prompt 获取链 → canonical metric identity → 本文连续追问主链路 → 真实模型、真机和灰度门禁；质量门禁可以与中间阶段并行建设；
- 两份文档发生字段或阶段冲突时，先回写总方案的摘要和依赖，不允许两个分支各自新增同义字段。

## 4. 当前产品为什么无法满足

当前真实实现存在五个断点：

1. `AgentDeepAnalysisCard` 整张卡只有“查看完整分析”，没有继续入口；
2. `AgentDeepAnalysisDetailSheet` 没有继续动作和来源关系；
3. `ChatInputView` 不显示正在基于哪份分析继续；
4. Agent Job 只有 `sourceMessageID`，没有 parent Result、root Job 或 relation；
5. Router 和 Runtime 只读取当前问题，“为什么”“第二点呢”缺少语义锚点。

现有基础可以复用：

- Chat 已有 user message 和 assistant message 的 parentMessageId；
- Scheduler、Job、Checkpoint、Result、Evidence、Message 已持久化；
- 每个 Job 已保证最多一条 canonical Result；
- Job 已冻结时间范围和 snapshotCutoffAt；
- Evidence 已有 redactedExcerpt、sensitivity 和稳定 ID；
- Verifier 已决定 Claim 能否交付；
- 冷启动和后台恢复已经围绕 Job generation / checkpoint 运行。

因此不需要重写 Agent，只需要补齐跨 Job 的产品关系和上下文编译边界。

### 4.1 架构决策

| 方案 | 优点 | 致命问题 | 结论 |
|---|---|---|---|
| 把最近 N 轮聊天全塞进 Prompt | 开发最快 | 串题、token 线性增长、旧事实和模型推测混入 | 拒绝 |
| 一个可变 Agent Thread 持续覆盖“当前结论” | 看起来像连续会话 | 用户纠正后历史被改写，无法审计和分支 | 拒绝 |
| 新建独立 Agent 工作台 | 状态容易集中展示 | 改变 HoloAI 主入口，增加理解和导航成本 | P0 不采用 |
| 不可变 Result 图 + 单父 child Job + 最小 Context Snapshot | 可追溯、可恢复、可分支、可控 Context | 需要补齐产品状态和持久化事务 | 采用 |

核心决策是：对用户保持“一段自然对话”，对系统内部保持“每一轮都是独立、不可变、可审计的 Result”。连续感来自明确关系，不来自把所有历史糊成一个大上下文。

## 5. 目标产品形态

### 5.1 Agent 结果卡

当前：

```text
┌─────────────────────────────┐
│ 深度分析                    │
│ 最近一个月 · 截至 7月29日   │
│ 外卖解释了主要支出增量……    │
│                             │
│ 查看完整分析 >              │
└─────────────────────────────┘
```

改造后：

```text
┌─────────────────────────────┐
│ 深度分析                    │
│ 最近一个月 · 截至 7月29日   │
│ 外卖解释了主要支出增量……    │
│                             │
│ 查看详情        继续追问     │
└─────────────────────────────┘
```

交互：

- 点击卡片主体或“查看详情”：打开现有详情页；
- 点击“继续追问”：关闭其他分析锚点，将这张卡绑定到输入框；
- 空结果、失败结果和过期结果使用不同动作：
  - `noData`：卡片显示“调整范围”，详情页提供“追问没数据的原因”；只继承问题/范围/coverage；
  - `unverifiable`：卡片显示“重新分析”，详情页提供“追问核验原因”；不继承被拒绝 Claim；
  - failed / cancelled：显示“重试”，不作为事实父 Result；
  - canonical Result 已过期：显示“按原问题重新分析”。

实现注意：

- 当前卡片是整张 Button，不能在 Button 内再嵌套 Button；
- 需要重构为“可点击内容区 + 独立 footer actions”，避免 SwiftUI 嵌套按钮的点击冲突。
- 两个 footer action 各自至少 44pt 点击区；Dynamic Type 过大时改为上下排列，不截断“继续追问”。
- disabled 动作不仅降低透明度，还显示可读原因，不能只靠颜色表达状态。

### 5.2 输入框 Context 锚定条

用户点击“继续追问”后，在输入框正上方显示：

```text
┌─────────────────────────────┐
│ 继续分析                    ×│
│ 最近一个月的外卖消费变化     │
│ 最近一个月 · 截至 7月29日    │
└─────────────────────────────┘
┌─────────────────────────────┐
│ 输入你的追问……              │ ↑
└─────────────────────────────┘
```

规则：

- 只显示标题和范围，不展示敏感数字；
- `×` 立即解除绑定，不删除历史 Result；
- 点击发送后，先把 parent IDs 转交并持久化到本轮 assistant interaction state；只有这一步成功，输入框文字和锚点才清空；
- 后续 child Job 创建失败时，原消息内显示“重试 / 作为新问题”，不把旧锚点重新塞回输入框，避免用户重复发送；
- App 在“尚未发送”时被关闭，草稿锚点不必跨冷启动恢复，避免无意保留；
- child Job 创建后，parentResultID 已落盘，冷启动恢复不再依赖输入框状态；
- 使用语音输入时沿用同一显式锚点；
- 用户点击 Quick Action 开始记账/建任务时，分析锚点自动解除。
- 用户直接键入明确的新话题或执行动作时，即使锚点仍显示，当前明确输入也优先；Router 确认 newTopic / execute 后自动解除锚点，不要求用户先手动点 `×`。
- 当前已有 Agent 正在运行时，历史卡片的“继续追问”置灰并提示“请先完成或停止当前分析”，不允许后台悄悄切换锚点。
- 用户在已有锚点时点击另一份结果的“继续追问”，新锚点直接替换旧锚点，并用轻提示说明“已切换到另一份分析”；不叠加两个父 Result。
- 输入期间若 parent Result 被清理、损坏或失去所需 Evidence，锚定条不会悄悄消失，而是变为“这份分析已无法继续”，提供“按原问题重新分析”和“取消”。
- 锚点草稿只保留在当前 ChatViewModel：用户切换到详情页再返回仍保留；离开 HoloAI 或 App 被终止则清空，避免隔很久后误带旧分析。
- VoiceOver 将整条读为“正在继续分析：标题，范围；双击取消”，`×` 具备独立可访问标签。

### 5.3 自然相邻追问

用户不点“继续追问”，直接在刚完成的 Agent 卡片后输入：

> 为什么是外卖？

Holo 可以自动承接，但仅在全部条件满足时：

1. 当前会话中，上一条 assistant 消息是已完成 Agent Result；
2. 中间没有其他用户问题、普通聊天或执行结果；
3. Result 的 canonical Job / Result 仍能读取；
4. 输入命中 P0 确定性指代规则，例如“为什么”“第二点呢”“换成今年”“不是金额，是频率”；
5. 当前输入不是记账、建任务、删除、打卡等执行 intent；
6. parent、relation 和 target 都能唯一解析，无并列候选。

如果不满足，不自动继承。

P0 不允许仅凭模型输出的 `confidence >= 0.8` 静默继承。模型置信度只能作为灰度期诊断信息；未命中确定性规则、parent/relation/target 任一不唯一时，一律确认或按新问题处理。后续是否扩大 implicit 语料，只能根据真实 Eval 的 precision、wrong-anchor 和用户立即纠正率单独决策。

会话边界优先使用消息邻接、当前 Chat 前台交互段和显式锚点判断。现有 Conversation Tool 的 4 小时间隔只作为缺少前台会话 token 时的兼容兜底，不是事实继承授权。显式点击仍可在任意时间继续一份未过期 Result；隐式候选跨前台会话或跨 4 小时则不静默承接，而是给出带明确来源的确认提示：

> 你是在继续「最近一个月的外卖消费变化」吗？

用户点击“继续这份分析”后形成显式锚点；点击“不是”则按新问题处理。确认状态需要随对应 assistant message 持久化，避免退出重进后按钮失效。

在同一会话内，如果只有**隐式候选** Result，但输入本身仍然模糊，例如“那其他呢”，也不让系统在后台猜。对话中插入一条可持久化确认消息：

```text
你想继续「最近一个月的外卖消费变化」，还是把它当作一个新问题？

[继续这份分析]  [作为新问题]
```

确认前不创建 Agent Job；用户选择后才保存确定的 parent 或 newTopic。退出重进后按钮仍有效，重复点击只处理一次。

如果用户已经主动点击“继续追问”，parent 本身不再模糊；此时“那其他呢”只需要澄清目标，例如：

> 你想看其他消费类别，还是其他可执行建议？

锚点继续保留，不再问“是否继续这份分析”。

确认消息出现后输入框仍可用：

- 按钮是 P0 的 canonical 决策入口；
- 文字只支持规范化后命中小型确定性词表的表达，例如“继续”“继续这份分析”“算了”“作为新问题”；
- “嗯继续呗”“先这样吧”等开放口语不自动映射到按钮，仍保持 pending 或按普通输入重新路由；
- 用户输入明确的新问题或执行动作，会先把 pending decision 标为已放弃，再按新输入路由；
- 模糊文字不会自动选择第一个按钮。

文字选择产生的新 user/assistant message 是 child 的 source message；原确认消息保存 `resolvedByMessageID`，使按钮立即失效，避免一个 pending decision 被按钮和文字各执行一次。

自然承接一旦成立，loading 状态立即显示：

> 正在继续「最近一个月的外卖消费变化」……

用户能在第一时间看到系统承接了哪份分析；如果发现不对，可以点击停止。

后续进度文案按 relation 生成，避免所有追问都显示笼统的“分析中”：

- explain：正在解释上一份结论；
- correct：正在按“购买频率”重新计算；
- changeScope：正在查询今年的数据；
- crossDomain：正在对齐财务和睡眠数据。

这些是 Job 状态的确定性文案，不让模型自由生成。停止只取消当前 child，不影响 parent。

### 5.4 轻量追问回复

简单的解释和深挖不重复生成大型 Agent 卡片：

```text
基于「最近一个月的外卖消费变化」

外卖之所以被判断为主要增量，是因为……

沿用 7月29日的数据依据 · 查看依据
```

适用：

- `explain`
- 同范围、不需要大规模重算的 `drillDown`

仍然会保存完整 canonical Result，只是展示为 `followUpReply`。

轻量追问回复底部提供：

```text
查看依据 · 继续追问
```

因此即使用户隔天滚动到这条轻量回复，也能精确从 Result B 继续，而不是只能从大型卡片继续。

### 5.5 新分析卡片

以下情况会生成新的完整 Agent 卡片：

- `changeScope`
- `correct`
- 跨领域补查；
- 结果结构或建议发生实质变化。

卡片上增加关系标签：

- “已按频率重新分析”
- “范围已改为今年”
- “补充了睡眠数据”
- “从上次分析继续”

卡片不能只写“继续分析”，必须说明本次发生了什么变化。

presentationStyle 由 relation 和 AnswerTask 契约决定，不由 SwiftUI 根据文字长度或工具数量临时猜测：

| relation | presentationStyle |
|---|---|
| explain | followUpReply |
| 同范围 drillDown | followUpReply |
| correct | analysisCard |
| changeScope | analysisCard |
| crossDomain | analysisCard |
| executeFromResult | 现有确认卡 |

### 5.6 详情页

详情页底部增加固定操作：

```text
[ 继续追问这份分析 ]
```

点击后按固定顺序执行：校验本机 Result 可用性 → 关闭详情页 → 在原 Chat 中显示 Context 锚定条 → 聚焦输入框。校验失败时详情页不消失，原地显示“重新分析 / 取消”，避免用户回到输入框才发现无法继续。

child Result 的详情页增加“本次分析关系”：

```text
本次分析
基于「最近一个月的外卖消费变化」
口径：金额 → 购买频率
数据：重新查询
范围：最近一个月 · 截至 7月29日
```

只展示用户能理解的关系，不显示 Job ID、Evidence ID 或 Context digest。

如果 parent Chat message 仍存在，“基于「……」”这一行可点按并回到对应消息；如果消息已删除，只保留不可点击的来源说明，不影响当前 Result 可读性。

底部按钮使用 safe-area inset 固定，不遮挡最后一条 Evidence；键盘出现后回到 Chat 并自动聚焦输入框，Context 锚定条立即可见。

### 5.7 历史分析

- 历史卡片仍可阅读；
- canonical Result 仍在保留期内：可以点击“继续追问”；
- canonical Result 已清理但 rendered JSON 仍在 Chat：卡片改显示“按原问题重新分析”；
- 重新分析会使用旧问题和旧范围作为新请求的起点，但数据快照使用当前时间；
- 不允许拿仅剩的展示文案伪造父 Evidence。

历史卡片的继续能力采用四态，而不是简单 `Bool`：

```text
checking → available / reanalyzeRequired / temporarilyUnavailable
```

- `checking`：按钮暂时不可点，显示轻量加载；
- `available`：允许继续；
- `reanalyzeRequired`：已确认本机没有 canonical Result/Evidence；
- `temporarilyUnavailable`：Store 读取失败或损坏诊断未完成，显示“暂时无法验证”，保留只读卡片，不误判成“已过期”。

历史分页加载后，由 ChatViewModel 收集本批消息中的 job/result IDs，一次性批量查询可用性并按 Store generation 缓存；卡片 body 不各自启动 Task、反复读取整份 JSON Store。Result 新增、cleanup 或 Store quarantine 时 generation 变化并使缓存失效。

## 6. 完整主 Use Case

### 用户目标

用户最近一个月总觉得钱不够花，希望找到原因并持续追问。

### Step 1：发起基础分析

用户输入：

> 帮我分析最近一个月为什么总觉得钱不够花，并给我建议。

界面：

- 用户消息正常显示；
- AI 占位卡显示“正在深度分析”；
- 完成后展示完整 Agent 卡。

Holo 回答示例：

> 最近一个月支出 6,820 元，比上一个月增加 1,240 元。主要增量来自餐饮，其中外卖增加 760 元。优先建议先控制工作日晚餐外卖，而不是全面压缩所有餐饮。

系统内部：

```text
Job A
  jobID = job-a
  timeRange = 最近一个月
  snapshotCutoffAt = 2026-07-29
  sourceUserMessageID = user-message-a
  sourceMessageID = assistant-message-a

Result A
  resultID = agent-result:job-a
  jobID = job-a
  claims = 已验证金额/分类/外卖结论
  evidenceIDs = 对应 Evidence
  lineage = nil
```

产品状态：

- 这是一条 root Result；
- 卡片显示“查看详情”“继续追问”；
- 输入框默认仍是普通输入状态，不强制锁定分析。

### Step 2：自然追问“为什么”

用户直接输入：

> 为什么你说外卖是主要问题？

Resolver：

- 相邻上一条是 Result A；
- 当前输入明确指向上一结论；
- intent 是分析解释，不是执行；
- relation = `explain`；
- targetClaimID = Result A 中的外卖增量 Claim。

Context：

- 沿用 Result A 的时间范围和 snapshotCutoffAt；
- 只选择目标 Claim 及其 Evidence；
- 不带 Result A 的完整回答、其他建议、聊天历史；
- 默认不重新调用财务 Tool。

Holo 轻量回复：

> 外卖之所以被判断为主要问题，是因为本月新增的 1,240 元支出中，有 760 元来自外卖，占增量约 61%。这里指的是“外卖解释了大部分新增支出”，不是说外卖占全部支出的 61%。

界面标注：

> 基于「最近一个月的外卖消费变化」  
> 沿用 7月29日的数据依据

系统内部：

```text
Job B
  lineage.parentJobID = job-a
  lineage.parentResultID = agent-result:job-a
  lineage.rootJobID = job-a
  lineage.relation = explain

Result B
  resultID = agent-result:job-b
  inheritedEvidenceIDs = [...]
  newEvidenceIDs = []
  presentationStyle = followUpReply
```

### Step 3：纠正统计口径

用户输入：

> 不是，我关心的不是花了多少钱，而是我是不是点得太频繁。

默认父结果：

- 直接父 Result 是 B；
- root Result 仍是 A；
- Resolver 从 B 的 lineage 知道主题仍是外卖；
- relation = `correct`；
- correction = `金额 → 购买频率`。

继承规则：

- 继承“外卖”和“最近一个月”这两个任务约束；
- 丢弃“外卖金额占增量 61%”作为本轮答案依据；
- 重新查询外卖交易次数和时间分布；
- 创建新的 snapshotCutoffAt。

Holo 新卡片：

> 已按“购买频率”重新分析  
> 最近一个月点了 18 次外卖，上个月是 11 次；平均从每 2.7 天一次变成每 1.7 天一次。频率确实明显增加，主要集中在工作日晚间。

系统内部：

```text
Job C
  parent = Result B
  root = Job A
  relation = correct
  inheritedClaims = []
  inheritedTask = 外卖分析 + 最近一个月
  newTask = 外卖购买频率
```

Result A、B 不修改；C 是用户最新确认的分析口径。

### Step 4：跨领域深挖

用户输入：

> 那和我最近睡眠变差有关系吗？

Resolver：

- relation = `crossDomain`
- existingTarget = 外卖购买频率；
- addedDomain = health.sleep；
- 用户没有要求“现在/最新”，沿用 Result C 的 `snapshotCutoffAt`；
- 复用 Result C 同一截止时间下已验证的财务频率 Evidence，只补查健康数据；
- 财务和睡眠必须使用可比较的重叠日期。

Context：

- 继承 Result C 的主题、频率口径、时间范围和通过 V2 的财务频率事实，不继承旧联合结论；
- 使用 Result C 的同一 `snapshotCutoffAt` 查询同期睡眠 Evidence；
- 不带金额口径的 Result A/B；
- Verifier 检查重叠窗口和“相关不等于因果”。

这里不能把父财务快照与超过其截止时间的新健康数据直接拼在一起。健康查询必须冻结到父 `snapshotCutoffAt`，联合计算引用财务旧 Evidence 和本轮新健康 Evidence，并逐项标明来源。如果用户问“现在还有关系吗”，才创建新 `snapshotCutoffAt` 并重查全部参与领域。

Holo 新卡片：

> 补充了睡眠数据  
> 在同时有睡眠和外卖记录的 21 天里，睡眠少于 6.5 小时后的第二天，晚间点外卖的比例更高。两者存在同期关联，但目前不能证明睡眠不足导致了外卖增加，也可能共同受到加班等因素影响。

### Step 5：更换时间范围

用户输入：

> 换成今年看，这个规律还成立吗？

Resolver：

- relation = `changeScope`
- oldScope = 最近一个月；
- newScope = 今年；
- 主题 = 睡眠与外卖频率关系。

继承规则：

- 继承分析目标和数据域；
- 不继承最近一个月的数值；
- 财务和睡眠全部按今年重新查询；
- 创建新的年度 snapshotCutoffAt。

Holo 新卡片：

> 范围已改为今年  
> 换成今年后，两者仍有弱关联，但明显弱于最近一个月。因此更准确的判断是：这是近期阶段性变化，还不能视为长期规律。

禁止行为：

- 不得把最近一个月 21 天的重叠样本当成年度样本；
- 不得沿用最近一个月的 18 次外卖；
- 不得把“相关”升级成“睡眠导致外卖”。

### Step 6：从历史分支重新继续

用户滚动到最初的 Result A，点击“继续追问”，输入框显示：

> 继续分析：最近一个月的外卖消费变化

用户输入：

> 如果只看周末呢？

本轮明确绑定 A，而不是最新的年度 Result：

```text
Job F
  parentResultID = Result A
  rootJobID = Job A
  relation = changeScope
  filter = weekend
```

这会形成新的分支，不修改 C、D、E。

### Step 7：把建议转成行动

用户在 Result A 详情页点击“继续追问”，输入：

> 把第一条建议建成待办。

系统：

- 读取 Result A 中稳定的 Recommendation ID；
- 生成任务草稿，例如“工作日晚餐减少外卖”；
- 显示现有确认卡；
- 用户确认后才创建任务；
- 不创建分析 child Job；
- 不将外卖金额、其他 Evidence 或整段聊天传入 Task Router。

### Step 8：锁屏或 App 被终止

如果 Job D 执行中 App 被系统终止：

- child Job 已持久化 parentResultID、relation 和 FollowUpContextSnapshot；
- 冷启动使用 checkpoint 和 contextDigest 恢复；
- 不重新读取“最近一条聊天”猜父结果；
- 恢复后仍回填原 AI 占位消息；
- 最终仍只有一个 Result D。

### Step 9：发送瞬间被终止

如果用户刚发送“为什么”，Chat 消息已经出现，但 child Job 还没完全创建时 App 被终止：

- assistant placeholder 已持久化 `agentInteractionJSON(launchingFollowUp)`；
- 若 transaction journal 还没创建，冷启动先用这条 interaction state 创建同一 idempotency transaction；
- 若 journal 已 prepared，则 Reconciler 前滚 Evidence/Checkpoint/Job；
- Scheduler 只运行 committed Job；
- 用户不会看到永久转圈，也不会因为重试产生两个 child。

若 parent 在恢复时确认已不可用，原消息切换为：

> 这份分析已经无法继续。  
> [按原问题重新分析] [作为新问题]

## 7. 其他用户场景与明确行为

| 场景 | 产品行为 |
|---|---|
| Agent 卡片后说“第二点呢” | 定位稳定的第二条 Claim/Recommendation ID，轻量回复 |
| Agent 卡片后说“你再分析下苹果” | “苹果”可能是食品、公司或健康数据；不静默继承，按普通 Router 或澄清 |
| 绑定分析后说“记午饭 50 元” | 执行 intent 优先，清除分析锚点，走记账确认 |
| 绑定分析后说“把第一条建待办” | 从稳定 Recommendation ID 生成确认卡 |
| 说“760 不对，应该是 500” | 不直接改 Evidence；若只是质疑总额/口径则重新查询或澄清；只有用户指出可唯一定位的具体原始记录时，才进入新增的结构化数据编辑确认流程 |
| 上一条是普通聊天，不是 Agent | 不启用自然追问 |
| 上一条 Agent 失败/取消 | 不作为自动父 Result |
| `noData` 结果后问“为什么没数据” | 可解释数据权限、范围和覆盖，但不能产生事实结论 |
| `unverifiable` 后继续追问 | 只能重新分析或解释核验失败，不能继承被拒绝 Claim |
| 历史卡片 canonical Result 已过期 | 显示“按原问题重新分析”，用当前数据创建新 root Job |
| 父消息被用户删除 | 已创建 child Job 不受影响；尚未发送的显式锚点自动失效 |
| 已绑定 A 后又点 B 的“继续追问” | 用 B 替换 A，明确提示已切换；不同时继承 A、B |
| 输入过程中 parent 失效 | 锚定条显示失效状态，允许按原问题重跑或取消；发送时不得降级为隐式继承 |
| 原始交易后来被删除/修改 | 解释旧 Result 时标明旧快照；询问当前情况必须重新查询 |
| 用户连续十轮追问 | 每轮只编译直接父 Result 的相关事实，不递归发送十轮历史 |
| 用户重复点击发送 | 同一 sourceUserMessageID / idempotency key 只创建一个 child Job |
| 隔夜后直接说“为什么” | 不静默承接，展示“继续上一份分析？”确认 |
| 说“回到最开始那份” | 只在当前 lineage 的 root Result 仍可用时精确绑定 root；不可用则提示从历史卡片重新分析 |
| 说“和最开始那份比较” | current Result 仍是唯一 parent，root Result 作为一个显式 secondary reference；不建立双父节点 |
| 问“现在呢 / 最新情况呢” | freshness 语义优先于 explain；保留主题但创建新快照并重新查询，不沿用旧数值 |

## 8. Result 的定义与生命周期

### 8.1 什么是 A Result、B Result

Result 不通过标题、内容相似度或“最近一份”区分，只通过稳定 ID：

```text
Message A → Job A → Result A
                         │
                         └── parentResultID
                              ↓
Message B → Job B → Result B
```

- `Result.id = agent-result:<jobID>`；
- 同一 Job 无论模型重试、后台恢复多少次，只能有一条 canonical Result；
- B 只有在自己的 lineage 明确记录 `parentResultID = A.id` 时，才是 A 的 child；
- 创建 child Job 后 parent 关系冻结，恢复时不重新推断。

### 8.2 root、parent、current

- `rootResult`：分析链最初的问题；
- `parentResult`：当前这一轮直接承接的结果；
- `currentResult`：用户当前刚得到的结果。

例如：

```text
A 金额分析
  └─ B 解释金额
      └─ C 纠正为频率
          └─ D 增加睡眠
```

对 D：

- root = A；
- parent = C；
- current = D。

自然下一问默认承接 D；从历史卡片 A 点击“继续追问”则显式分支 A。

“回到最开始那份”只允许解析当前 direct parent 已记录的 `rootJobID/rootResultID`，不允许模型在全部聊天中搜索一个“看起来像最开始”的结果。

每个 child Job 仍然只有一个 direct parent。需要“当前结果和最初结果比较”时，可以额外携带至多一个有稳定 ID 的 `referencedResultID`，它只作为比较材料，不参与 lineage 归属，也不能让模型自由搜索更多历史。

lineage 的唯一持久化模型为：

```swift
struct HoloAgentLineage: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var rootJobID: String
    var rootResultID: String
    var parentJobID: String
    var parentResultID: String
    var relationRawValue: String
    var lineageDepth: Int
}
```

`HoloAgentJob` 和 `HoloAgentResult` 共用这份类型，不分别维护散落字段；`referencedResultID` 属于 Context Snapshot，不进入 lineage。

lineage 写入时执行不可变校验：

- parent 必须是 completed 且有 canonical Result 的 Job；
- `parentJobID != childJobID`，`rootJobID != childJobID`；
- parent 有 root 时原样传播；旧 parent 没有 lineage 时，root 就是 parent；
- root Job 的 `lineageDepth = 0`，child 持久化 `lineageDepth = parent.lineageDepth + 1`；没有 lineage/depth 的旧 parent 按 legacy root（0）处理；
- `lineageDepth` 最大为 20；达到上限后把当前 Result 的最小可信 Snapshot 滚动为新 root，用户仍可自然继续，但不再无限延长原链；
- 创建时用 parent/root IDs、depth 和可读祖先校验环；不得要求每次递归加载整条历史后才能执行；
- 顺着当前可读 parent 链发现 child 自身或重复节点即拒绝，不能形成环；
- `referencedResultID` 不得同时冒充第二个 parent；
- lineage 一旦随 initial Checkpoint commit，重试、恢复和模型输出都不能改写。

### 8.3 生命周期

| 阶段 | 判断来源 | 能否继续 |
|---|---|---|
| Job 运行中 | Job 非终态 | 不能作为完成结果追问，只能停止或等待 |
| 可引用 | Job completed，canonical Result 和所需 Evidence 可读 | 可以 |
| 降级可引用 | Result 可读，但 Evidence partial 或部分已归档 | 可解释仍有效的旧 Claim 并保留 caveat；新计算只继承任务 |
| 展示保留 | Chat 仍有 rendered JSON，canonical Result 已清理 | 只能阅读或重新分析 |
| 已删除 | Chat 和 Agent Store 均不存在 | 不可继续 |

Result 生命周期的真相源仍是：

- Job 状态；
- canonical Result 是否存在；
- Evidence 状态；
- 清理策略。

不新增一套手工维护、容易漂移的 `resultLifecycleState`。

`failed`、`cancelled`、`superseded`、`noData` 和 `unverifiable` 都不是普通事实 parent：

- failed/cancelled/superseded：只能重试；
- noData：只能继承问题、范围和 coverage 原因，事实 Claim allowlist 为空；
- unverifiable：只能继承任务和 verifier rejection reason，不继承被拒绝 Claim。

### 8.4 保留与清理

当前完成 Job 默认保留 30 天。连续追问采用“child 自包含快照”，避免无限保留整条祖先：

1. 创建 child Job 时，立即把允许继承的结构化事实编译成 `FollowUpContextSnapshot`；
2. Snapshot 保存 parent IDs、选中的 Claim/Recommendation IDs、Evidence IDs、权威范围和 digest；
3. child Job 运行和恢复只依赖自己的 Snapshot，不反复读取整条祖先；
4. parent 至少保留到 child 创建和 Snapshot 落盘完成；
5. child Result 最终保存自己实际使用的 inherited/new Evidence IDs；
6. 父 Result 到期后可以按策略清理，不影响已完成 child 的可复核性；
7. 仍被非终态 child Job 使用的 Evidence 不得归档或删除；
8. Chat 中旧 rendered 结果可以继续展示，但继续按钮需要实时检查 canonical Store。

这样同时避免：

- 父 Result 提前删除导致 child 恢复失败；
- 一条长链导致所有祖先永久保留；
- 只剩 UI 文案却假装仍有事实依据。

这里的“自包含”是指 child 不再依赖祖先 Result/聊天文本；它仍通过稳定 ID 依赖统一 Evidence Ledger。把 Evidence 正文复制进每个 child Snapshot 会造成隐私副本和存储膨胀，因此不采用。

当前代码并没有形成完整清理闭环：`cleanupTerminalJobs` 顺序执行“先删 Job → 再删 Checkpoint → 再删 Result”，不是原子级联；`cleanupOrphanedEvidence` 虽然存在，但目前没有生产调用方驱动；`cascadeCheckpoint / cascadeResult / preserveReferencedEvidence` 三个 policy 开关也尚未被 Persistence Manager 读取。实施时不得把“存在方法”当作“生命周期已经运行”，必须把清理调度、引用重算、policy 执行和 journal 恢复一起接入。

## 9. Context 管理方案

### 9.1 不建立“聊天历史大 Context”

禁止：

```text
最近 20 条用户消息
+ 最近 20 条模型回复
+ 所有工具结果
+ 所有个人记忆
```

目标：

```text
当前输入
+ 唯一父 Result 的结构化任务
+ 本轮允许继承的已验证事实
+ 本轮权威时间范围
+ 与本轮有关的最小长期偏好
```

### 9.2 五个组件

#### 1. `HoloAgentContinuationDraft`

只存在于 ChatViewModel，服务输入框显式锚定：

- sourceAssistantMessageID
- jobID
- resultID
- title
- scopeLabel
- createdAt

它不是事实 Context，不能直接发给模型。

#### 2. `HoloAgentAnchorResolver`

输入：

- 当前 user message ID；
- 显式 ContinuationDraft（如有）；
- 当前会话的相邻消息；
- 当前 Router intent；
- Agent Store 可用性。

输出：

- exact parent job/result；
- anchorSource：`explicitCard / explicitDetail / implicitAdjacent`；
- 或 `nil`。

#### 3. `HoloAgentFollowUpResolver`

输入只包含：

- 当前用户原话；
- parent 的领域、AnswerTask、时间范围；
- Claim/Recommendation 的稳定 ID 和短标题；
- 不包含数值、Evidence 原文、历史聊天。

输出闭集：

```text
explain
drillDown
correct
changeScope
crossDomain
executeFromResult
newTopic
ambiguous
```

确定性规则优先：

- “为什么” → explain；
- “第二点” → 按稳定展示顺序定位 ID；
- “换成今年” → changeScope；
- “不是金额，是频率” → correct；
- 明确执行 intent → execute / newTopic。

开放性歧义再调用专用小 Router。它不能自行搜索任意历史，只能判断已经给定的唯一 parent。

需要澄清时，按钮选项由 Result 的稳定 presentationOrder、AnswerTask 维度和允许的 relation 构造；模型最多返回 option ID，不能凭空生成一个带新事实的选项。

#### 4. `HoloAgentContextCompiler`

根据 relation 执行继承策略，生成 `FollowUpContextSnapshot`。

它负责：

- 选择哪些 Claim / Recommendation；
- 选择哪些 Evidence；
- 决定是否沿用父范围；
- 决定哪些旧数字必须丢弃；
- 生成 Context digest；
- 控制 token 和隐私；
- 产出 child Job 的 standalone execution question / AnswerTask。

#### 5. `HoloAgentContextGuard`

模型调用前检查：

- parentResultID 是否准确；
- Result/Claim/Evidence 是否存在；
- Evidence 状态是否允许当前 relation 使用；
- scope 是否与 relation 相容；
- inherited metric identity 是否一致；
- Context 是否超预算；
- 是否含未经允许的自然语言历史；
- 是否存在 lineage 环。

回答完成后继续由 Claim Verifier 检查：

- 是否只引用允许的 inherited/new Evidence；
- 是否混用旧范围；
- 是否生成无依据的新数字；
- 是否把相关性升级成因果；
- 是否引用错误 canonical metric identity。

Context Guard 与 `HoloClaimVerifierV2` 保持前后两道门：

- Guard 是执行前授权，只决定哪些 parent/reference、范围和 Evidence 可以进入本轮 Context；
- V2 是输出后验证，只决定新 Claim 是否被允许的 Evidence、范围和因果边界支持；
- 两者复用相同的 scope、Evidence existence、window comparability、causal compliance 和 metric identity 纯校验原语；
- 不合并组件，也不复制两套规则；所有连续追问事实型任务强制使用 V2，不得回退到只覆盖较少维度的 V1 后仍交付答案。

Evidence 状态规则：

- `active`：按 relation allowlist 使用；
- `partial`：只允许解释一条本来就带 coverage 限制的旧 Claim，并必须保留 caveat；不得用于新比较/相关性计算；
- `orphaned / archived`：不进入 Prompt；
- Store quarantined / readFailed：整轮暂停，不能按“没有 Evidence”继续。

所有来自用户记录、父 Claim 标题、Recommendation 标题和 `redactedExcerpt` 的自由文本都按“不可信数据”处理：

- 使用类型化 JSON data block，而不是拼进 system instruction；
- 统一由 `HoloAgentPromptEscaper` 转义分隔符、控制字符和伪造 role 标签；
- Prompt 明确声明 data block 中的“忽略规则、调用工具、泄露内容”等句子只是用户数据，不是指令；
- Follow-up Router 优先读取稳定 ID、领域和类型枚举，自由文本 label 截断后仅用于指代消歧；
- Context Guard 拒绝超长字段、未知 schema 和未转义 payload。

这项防护不仅针对恶意输入，也防止用户在交易备注、观点内容中写的一句话意外接管 Agent 行为。

### 9.3 Context 权限层级

| 层级 | 内容 | 权限 |
|---|---|---|
| L0 当前明确输入 | 当前用户真正要求 | 决定本轮任务，但不能改写历史事实 |
| L1 Job 权威范围 | timeRange、baseline、snapshotCutoffAt | 决定本轮数据口径 |
| L2 Verified Evidence | 数值、单位、范围、血缘 | 唯一事实依据 |
| L3 已验证父 Claim | 对父 Evidence 的已核验表达 | 可作为解释目标，不可越过 Evidence |
| L4 长期偏好/记忆 | 表达偏好、稳定纠正、软背景 | 只能辅助，不能覆盖 L0–L3 |
| 禁止层 | 父模型完整回复、未验证推测、历史闲聊 | 不进入事实 Context |

当前输入优先，不代表用户可以通过一句话把旧 Evidence 改成另一个数值。用户纠正事实时，系统将其视为新约束或待确认数据修改，而不是直接覆盖账本。

### 9.4 relation 继承矩阵

| relation | 继承 AnswerTask | 继承父范围 | 继承父 Evidence | 是否重查 |
|---|---:|---:|---:|---:|
| explain | 是 | 是 | 仅目标 Claim | 默认否 |
| drillDown | 是 | 是 | 目标 Claim + 相关 Evidence | 只补缺失 |
| correct | 部分 | 未改范围则是 | 冲突事实否 | 通常是 |
| changeScope | 是 | 否 | 数值否 | 是 |
| crossDomain | 是 | 默认沿用父截止时间；出现 freshness 语义时冻结新范围 | 可继承同一截止时间下已验证的父领域事实，不继承旧联合结论 | 默认只补查新领域；新截止时间才重查全部参与领域 |
| executeFromResult | 仅目标 Recommendation | 不进入分析 Job | 不传事实 Context | 走确认卡 |
| newTopic | 否 | 否 | 否 | 按新问题 |

crossDomain 不默认滚雪球累积领域：

- “财务 → 那和睡眠呢”解析为“财务 + 睡眠”；
- 下一句“那和步数呢”默认替换新增比较域，解析为“财务 + 步数”，不自动变成“财务 + 睡眠 + 步数”；
- 只有用户明确说“把睡眠和步数一起比较”才累积；
- 同一结果最多同时比较 3 个领域；超过时保留当前问题并提示拆分，不让 Agent 静默扩大查询；
- Context Compiler 记录 `participatingDomains`、本轮复用/新查工具数和预计成本，Runtime 在执行前检查领域数、工具调用数和 Job 总预算。

### 9.5 Context Snapshot

建议模型：

```swift
struct HoloAgentInheritedClaimSnapshot: Codable, Equatable, Sendable {
    var claimID: String
    var sourceResultID: String
    var sourceRoleRawValue: String // directParent / comparisonReference
    var claimType: HoloAgentClaimType
    var normalizedAssertions: [HoloAgentMetricAssertion]
    var evidenceIDs: [String]
    var sourceScope: HoloAgentTimeRange?
    var sourceSnapshotCutoffAt: Date?
    var verifierDecision: HoloAgentVerifierDecision
}

struct HoloAgentInheritedRecommendationSnapshot: Codable, Equatable, Sendable {
    var recommendationID: String
    var sourceResultID: String
    var actionKind: HoloAgentActionKind?
    var sourceClaimIDs: [String]
}

struct HoloAgentFollowUpContextSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var rootJobID: String
    var parentJobID: String
    var parentResultID: String
    var relation: HoloAgentFollowUpRelation
    var anchorSource: HoloAgentAnchorSource
    var parentAnswerTask: HoloAnswerTask?
    var resolvedAnswerTask: HoloAnswerTask
    var inheritedScope: HoloAgentTimeRange?
    var referencedResultID: String?
    var participatingDomainRawValues: [String]
    var inheritedClaims: [HoloAgentInheritedClaimSnapshot]
    var inheritedRecommendations: [HoloAgentInheritedRecommendationSnapshot]
    var inheritedEvidenceIDs: [String]
    var directParentEvidenceIDs: [String]
    var comparisonReferenceEvidenceIDs: [String]
    var excludedEvidenceIDs: [String]
    var contextDigest: String
    var compiledAt: Date
}
```

Snapshot 必须是：

- 可持久化；
- 可 hash；
- 可恢复；
- 不含完整聊天；
- 不含完整 Evidence excerpt；
- 不含父模型 narrativeSummary；
- 不含 UI 临时标题作为事实。

示意代码里的 relation / anchorSource / presentationStyle 在内存中使用 enum；落盘模型保存 `rawValue: String` 并通过容错映射读取。未知值进入 `.unknown(rawValue)`/只读分支，不能让关键 JSON Store 因新增枚举值整体 quarantine。

不能只保存 `selectedClaimIDs`：否则 parent Result 清理后，child 虽然知道“曾经选过哪个 ID”，却已经没有可恢复的结构化事实。Snapshot 必须复制经过 Verifier 的最小 assertion payload，并标明它来自直接 parent 还是那一个显式 comparison reference；Evidence 内容仍保存在独立 Evidence Store，并由 child 的引用关系保护。

`referencedResultID` 始终至多一个。Compiler 分别生成 `directParent` 和 `comparisonReference` 两个类型化 data block，各自携带 sourceResultID、scope、snapshotCutoffAt、Claim 和 Evidence allowlist，禁止把两者的 assertion 合并成无来源数组。比较类 Claim 的每个数值都必须携带 source role 和 source scope，并由 V2 逐项核验；该隔离未实现前关闭 secondary reference 功能。

`contextDigest` 的计算采用稳定 canonical 编码：对象 key 排序，Claim 按 `sourceRoleRawValue + sourceResultID + claimID`、Evidence 在各自 role allowlist 内按 ID 排序；明确排除 `contextDigest` 自身、`compiledAt` 和纯 UI label。否则同一集合因数组顺序、时间戳或自引用也会产生不同哈希。

### 9.6 Context 体积

P0 默认上限：

- 1 个直接父 Result，必要时至多 1 个显式 lineage ancestor 作为比较 reference；
- 最多 5 条相关 Claim；
- 最多 12 条脱敏 Evidence 摘要；
- 渲染后 inherited Context 目标不超过约 1,500 token；
- 不随 lineage 深度增加；
- 超出时按 target ID、交付物相关性、置信度和时间匹配确定性裁剪；
- 禁止让模型自行总结整条历史作为压缩方案。

这些数值需要通过真实 Eval 调整，但必须保留独立硬上限。Snapshot 的 64 KiB 存储上限与 Prompt 中 1,500 token 的 inherited block 是两项不同约束：Snapshot 可以保存恢复所需的最小类型化 assertion，PromptBuilder 只渲染本轮 target 必需的子集。

1,500 token 是每次 Prompt 中 inherited block 的上限；每轮重复发送仍计入现有 Job 的累计 `consumedInputTokens`，不能因它叫“继承 Context”而绕过 80K/120K 总预算。

预算由统一的确定性 token estimator 在 PromptBuilder 最终序列化之后计算，而不是按 Swift 字符数猜测。裁剪顺序固定为：

1. 明确 target ID 对应的 assertion；
2. 支撑该 assertion 的必要 Evidence；
3. 当前交付物需要的相邻 Claim；
4. 次要 reference；
5. 非必要展示 label。

必要事实仍超上限时不得继续删到语义不完整；Context Guard 返回 `contextTooLarge`，由系统缩小问题或提示用户拆分，而不是让模型在残缺依据上回答。

Phase 0/6 必须记录并评估：

- inherited Context token 的 p50 / p95 / max；
- 每种 relation 的裁剪率和 `contextTooLarge` 率；
- 用户最终被要求拆分问题的比例，灰度目标 < 0.1%；
- 裁剪前后目标 Claim、数值、范围和 Evidence 完整性。

超预算的固定降级顺序为：保留 target assertion → 删除非目标 label/相邻 Claim → 删除 secondary reference → 能由确定性 Composer 回答时不再调用模型 → 能安全重查时改为目标工具重查 → 最后才提示用户拆分。1,500 token 在 Eval 前是保守初始值，不宣称为已证明的最终阈值。

### 9.7 Context 污染防护示例

#### 旧模型推测污染

父回复：

> 你可能因为工作压力大，所以更常点外卖。

如果“工作压力大”没有 Claim + Evidence：

- 不进入 child Context；
- 不允许下一轮说“既然你最近工作压力很大”；
- 用户追问压力时必须查询任务、观点或其他合法数据源。

#### 时间污染

父范围：最近一个月。  
用户：换成今年。

- 继承主题；
- inheritedEvidenceIDs = []；
- 新 Job 按今年重查；
- Verifier 拒绝最近一个月 Evidence 支撑年度 Claim。

#### 新鲜度污染

父范围和当前范围相同，但用户说“现在呢”“最新情况呢”：

- freshness 语义覆盖 explain/drillDown 的默认复用；
- 继承主题和指标口径；
- 创建新 `snapshotCutoffAt` 并重查；
- 旧 Evidence 只作为历史对照且必须明确标注旧快照，不能冒充当前事实。

#### 领域污染

父结果：外卖频率。  
用户：最近步数怎么样？

如果没有“那和外卖有什么关系”之类承接语义：

- relation = newTopic；
- 不继承财务 Context；
- 只查健康步数。

#### 长链污染

A → B → C → D → E：

- E 只读取 D 的 canonical Result 和 D 中实际使用的 Evidence；
- 不把 A/B/C/D 的模型消息递归加入 Prompt；
- rootJobID 只用于审计和 UI 路径。

## 10. 产品与技术总链路

```text
用户输入
   │
   ├── 显式卡片/详情锚点 ───────────────┐
   │                                     │
   └── 当前会话相邻 Agent 候选 ──────────┤
                                         ▼
                               Anchor Resolver
                                         │
                               当前 Intent Router
                                         │
                      ┌──────────────────┴─────────────────┐
                      │                                    │
                 执行 / 新话题                        分析追问候选
                      │                                    │
          现有确认/普通 Chat 链                  Follow-up Resolver
                                                           │
                                                  Context Compiler
                                                           │
                                                    Context Guard
                                                           │
                                    child Job + Checkpoint + Snapshot
                                                           │
                                      Tool → Evidence → Verifier
                                                           │
                                               canonical child Result
                                                           │
                             ┌─────────────────────────────┴──────────┐
                             │                                        │
                       轻量追问回复                              新分析卡片
```

## 11. 数据契约调整

### 11.1 `HoloAgentStartRequest`

新增可选：

- `sourceUserMessageID`
- `continuationAnchor`

不直接传整份 Context，由 Runtime 通过 canonical Store 编译。

### 11.2 `HoloAgentJob`

新增可选：

- `lineage`
- `originalUserQuestion`
- `followUpContextDigest`
- `sourceUserMessageID`
- `creationTransactionID`

为了兼容现有 Runtime，`userQuestion` 继续是实际执行入口，但 child Job 中保存 Context Compiler 生成的**可独立执行问题**；新增 `originalUserQuestion` 保存用户原话。root Job 两者相同。

例如用户只说“为什么”，child 的字段是：

```text
originalUserQuestion = "为什么"
userQuestion = "重新核对最近一个月的外卖支出增量，并解释外卖为何被判定为主要增量；若父 Context 不可用必须重查，不得凭空回答"
```

新 Runtime 仍优先使用类型化 `FollowUpContextSnapshot`，不会把上面这段文本当作关系真相。这个独立问题是降级安全网：如果灰度期间回到尚不了解 follow-up 字段的旧 Runtime，它会重查一份完整问题，而不是拿孤立的“为什么”生成错误答案。

展示层始终使用 source user message / `originalUserQuestion`，不会把内部独立问题显示给用户。时间解析和 AnswerTask 使用结构化结果，不通过简单拼接父问题字符串完成。

`sourceUserMessageID` 是 child 去重和相邻解析的用户消息真相源；现有 `sourceMessageID` 继续指向需要被回填的 assistant placeholder。两者不得混用：

```text
sourceUserMessageID      = 用户刚发送的追问
sourceMessageID          = 本轮等待回填的 AI 消息
lineage.parentResultID   = 上一份 canonical Result
```

### 11.3 `HoloAgentCheckpoint`

新增可选：

- `followUpContext`
- `inheritedEvidenceRecordIDs`

`conversationState` 只保存当前 child Job 的模型轮次。FollowUp Context 作为类型化字段持久化，再由 PromptBuilder 渲染，不把父历史伪装成普通 assistant 消息。

### 11.4 `HoloAgentInputSnapshot`

升级 schema，纳入：

- original user question；
- standalone execution question；
- lineage IDs；
- relation；
- followUpContextDigest；
- resolved scope；
- tool catalog version。

恢复时 digest 不一致：

- 不继续旧 checkpoint；
- 标记 inputChanged / superseded；
- 创建新 Job 或重新编译；
- 禁止混合旧 Context 和新输入。

新增字段不能直接改变所有存量 Job 的比较口径。`HoloAgentInputSnapshotHasher` 必须按 `schemaVersion` 提供版本化 canonical encoder：

- v1 Job 继续用 v1 字段集合重算和比较，不把缺失 follow-up 字段解释成输入变化；
- v2 child Job 使用包含 lineage、relation 和 contextDigest 的 v2 字段集合；
- 升级时对仍非终态的 v1 Job 做一次 reconcile，确认旧 hash 后再继续恢复；
- 禁止用“当前最新 struct 全字段编码”去比较旧 checkpoint，否则升级当刻的运行中任务会被误判为 needs-replan。

### 11.5 `HoloAgentResult`

新增可选：

- `lineage`
- `answerTask`
- `typedRecommendations`
- `presentationOrder`
- `inheritedEvidenceIDs`
- `newEvidenceIDs`
- `presentationStyle`
- `contextDigest`

Result 仍然只包含经过 Verifier 的产物。

`presentationOrder` 保存用户当时实际看到的 Claim/Recommendation 稳定 ID 顺序。“第二点”“第一条建议”必须按这份冻结顺序解析，不能在 Renderer 升版后重新排序。若旧 Result 没有稳定顺序，系统可以承接整份结果，但不能假装知道“第二点”指谁，必须让用户点选或重新分析。

Result 的 `evidenceIDs`、`inheritedEvidenceIDs`、`newEvidenceIDs` 统一通过一个 canonical collector 从 Claim 顶层引用和所有 assertion 引用取并集、去重、稳定排序。Renderer、Verifier 和清理逻辑不得各自实现一套 Evidence 收集规则。

### 11.6 `HoloRenderedAgentResult`

新增可选展示元数据：

```swift
struct HoloRenderedContinuationMetadata: Codable, Equatable, Sendable {
    var jobID: String
    var resultID: String
    var rootJobID: String
    var parentResultID: String?
    var relationRawValue: String?
    var presentationStyleRawValue: String
    var sourceTitle: String?
    var contextUsage: HoloRenderedContextUsage?
}
```

另外：

- `HoloRenderedAgentSection` 增加稳定 `id/sourceClaimID`；
- Recommendation ID 必须能映射 canonical Recommendation/Claim；
- UI 只能用这些稳定 ID 做“第二点”“第一条建议”，不能解析标题字符串。

这些字段全部 optional，旧 `agentResultJSON` 继续解码。

默认值固定：

- `presentationStyle == nil` → `.analysisCard`；
- `lineage == nil` → root Result；
- continuation metadata 缺失 → 先执行精确 backfill 查询，不直接显示可继续；
- 未知 enum/schema → 降级只读，不让整条 Chat 解码失败。

“未知 enum 降级”需要在 metadata / interaction 的自定义 `init(from:)` 中先读 raw string，再映射为 known-or-unknown；不能直接依赖 synthesized Codable，否则未来新增 relation 会让旧消息整段解码失败。

旧消息的按需兼容规则：

1. 新 metadata 存在：直接按 `jobID/resultID` 精确查询；
2. metadata 不存在：只允许用该 assistant message ID 查询 `Job.sourceMessageID`；
3. 找到唯一 completed Job 和 canonical Result 后，在内存中生成 metadata，并在下一次安全保存时回填；
4. 找不到或出现多条不一致记录：只提供“按原问题重新分析”；
5. 禁止按标题、摘要或相似问题猜 Result。

Store 补充精确且批量的查询接口：

- `ResultStore.byResultIDs(_:)`
- `ResultStore.forJobIDs(_:)`
- `JobStore.forSourceMessageIDs(_:)`
- `EvidenceLedger.find(ids:)` 继续作为唯一 Evidence 批量读取

单卡渲染和历史分页不得循环调用 `load all`。

### 11.7 Core Data

Result 的 continuation metadata 随 `agentResultJSON` 持久化；assistant.parentMessageId 继续关联本轮 user message；canonical parent/child 关系仍只保存在 Agent Job / Result Store。

但“你想继续这份分析，还是作为新问题”的确认消息需要跨退出恢复，而且它既不是 Agent Result，也不是普通自然语言。P0 因此新增一个 optional Chat 字段：

```swift
agentInteractionJSON: HoloAgentInteractionState?
```

其中只保存：

- `schemaVersion`
- `pendingDecisionID`
- `decisionKind`：anchorConfirmation / targetClarification；
- 有稳定 option ID 的选项和 resolution patch；
- candidate parent job/result/message IDs；
- source user/assistant message IDs；
- anchorSource 和 relation candidate；
- 状态：`pendingChoice / launchingFollowUp / routingNewTopic / failedLaunch / resolvedContinue / resolvedNewTopic / abandoned`；
- `creationTransactionID`；
- `resolvedByMessageID`；
- 创建和更新时间。

它不保存 Claim、Evidence、父摘要或聊天 Context，因此不是第二份事实真相源。旧数据字段为空即可兼容，Core Data / CloudKit schema 采用 optional additive migration。

按钮决策使用 compare-and-set：

1. `pendingChoice → launchingFollowUp / routingNewTopic` 只有一个点击成功；
2. 选择继续时关联 child creation transaction；
3. journal committed 后写 `resolvedContinue`；
4. 选择新问题时写 `resolvedNewTopic` 并进入普通 Router；
5. 创建失败进入 `failedLaunch`，保留原 parent 和 user message，提供“重试 / 作为新问题”；
6. 冷启动看到 launching/routing 时按 transaction journal 或普通消息状态判断继续完成还是恢复待选择。

显式锚点和命中确定性规则的隐式追问虽然不需要让用户选择，也必须先把 `launchingFollowUp` 连同 parent IDs 保存到 assistant placeholder，再开始多 Store transaction。否则 App 恰好在“Chat 消息已保存、Agent transaction 尚未 prepared”之间被杀，冷启动只会看到一个永远转圈、却不知道父 Result 的占位消息。

完整交接顺序：

```text
保存 user + assistant placeholder + agentInteractionJSON(launching)
→ prepare transaction journal
→ commit child Job
→ assistant interaction state = resolvedContinue
→ 结果完成后由 agentResultJSON 接管展示
```

冷启动可凭 `sourceUserMessageID + parentResultID` 重建同一个 idempotency key，不产生第二个 child Job。

需要明确跨设备行为：Chat 消息和 `agentResultJSON` 可能经 CloudKit 出现在另一台设备，但 Agent Job/Result/Evidence Store 当前是设备本地真相源。因此：

- 本机能精确读取 canonical Result 和必要 Evidence：允许继续；
- 只同步到展示 JSON、但本机没有 canonical Store：显示“在这台设备重新分析”；
- 重新分析使用当前设备的数据权限、当前快照和原问题，创建新的 root Job；
- P0 不跨设备同步 Evidence，也不把展示 JSON 当可继承事实。

### 11.8 创建 child Job 的原子边界

“读取 parent → 编译 Snapshot → 保护 Evidence → 创建 child”必须走同一条持久化事务通道，并与 cleanup 共用一个**非重入事务闸门**：

1. 按精确 `parentResultID` 读取 parent；
2. 验证 `parentResult.jobID == parentJob.id`，并核对来源 assistant message；
3. 检查 Result/Claim/Evidence 和 lineage 无环；
4. 编译并 canonical hash `FollowUpContextSnapshot`；
5. 把 child jobID 加入 inherited Evidence 的引用集合；
6. 持久化 initial Checkpoint、Job 和 InputSnapshot；
7. 全部成功后才返回“child 已创建”并清空输入框锚点。

不能只依赖 `HoloAgentPersistenceManager` 是 Swift actor：actor 在调用 Evidence/Checkpoint/Job 子 actor 的 `await` 期间允许重入，cleanup 仍可能插入多文件写入中间。实现必须新增：

- `HoloAgentPersistenceTransactionGate`：一次只发放一个 token，其他创建、完成、清理操作排队；
- `agentTransactions.json`：先写 prepared transaction，记录 transactionID、childJobID、parentResultID、目标 generation 和预期写入；
- 按现有顺序写 Evidence → Checkpoint → Job/InputSnapshot；
- 最后把 journal 标成 committed，才对外宣布创建成功；
- 冷启动 Reconciler 对 prepared 事务按幂等规则前滚，不通过猜测回滚已经写入的 Evidence。

Scheduler 只领取“`creationTransactionID` 对应 journal 已 committed”的 child Job。这样即使崩溃发生在 Job 文件刚写完、journal 尚未 commit 的瞬间，也不会运行一个缺少完整 Context 的半成品。

冷启动顺序固定为：

```text
Agent Store 完整性检查
→ 恢复 Chat 中 launching、但尚无 journal 的请求
→ Transaction Reconciler 前滚 prepared/cleanupPrepared
→ 跨 Store Consistency Reconciler
→ retention cleanup
→ Scheduler resume
```

cleanup 和 Scheduler 都不能早于事务恢复，否则进程崩溃后释放的内存 gate 失去保护，parent 可能先被清理。

每个单独 JSON 文件继续使用现有 `.atomic` 写入；跨文件一致性由 transaction journal 和 generation/CAS 保证。所有 Agent Store 及新 journal 沿用现有 `.completeUntilFirstUserAuthentication` 文件保护。

同时要先硬化现有 `HoloAgentJSONStore` 的替换失败路径：当前 fallback 会先删除目标文件再移动 temp，二次移动也失败时会出现主文件缺失。改造后保留独立 `last-known-good`，只有新文件写入、解码校验和保护属性设置全部成功后才删除旧副本；启动读取发现主文件缺失但 last-known-good 有效时恢复并记录诊断。corruption quarantine backup 与 last-known-good 使用不同文件，不能互相覆盖。

任何一步失败都不得留下“外部可运行的 Job、却没有 Snapshot”。即使留下已保护 Evidence，journal 也能在冷启动继续完成，或在确认 child 从未 commit 后由 Reconciler 安全移除引用。

cleanup 同样经过该 transaction gate：

- Persistence Manager 必须实际读取 `cascadeCheckpoint / cascadeResult / preserveReferencedEvidence`，不能继续无条件删除；
- `cleanupOrphanedEvidence` 接入唯一的生产 retention 调度，并与 Job cleanup 使用相同 transaction gate/journal；
- 非终态 child 引用的 Evidence 永不清理；
- completed child 的 Result 保留其实际使用的 Evidence 引用；
- child Result 清理后，Reconciler 移除该 child 的引用并判断 Evidence 是否成为 orphan；
- parent 删除不修改 child Snapshot；
- cleanup 与 child 创建竞争的测试必须稳定通过。
- committed journal 在 Job 进入终态、跨 Store 一致性校验通过并超过诊断保留期后压缩，避免事务日志无限增长。

这里的“同一事务通道”具体指持有同一个 transaction gate token，而不是只调用同一个 actor 方法。

终态 Job 清理也使用 journal，并调整现有“先删 Job”的顺序：

1. 写 `cleanupPrepared`；
2. 删除 Result 和 Checkpoint；
3. 从 Evidence 移除该 Job 引用，重新计算 orphan；
4. 最后删除 Job；
5. 写 `cleanupCommitted`。

这样崩溃时最多留下一个终态 Job 等待 Reconciler 继续清理，不会先失去 Job 真相源、却留下无法解释的 Result/Evidence。

UI 传来的 jobID/resultID 只是一条定位线索，不是可信事实。Persistence 层必须重新查 Store 并核对 Job、Result、Message 三者关系，防止陈旧 UI 状态或损坏 metadata 绑定到错误结果。

## 12. 路由顺序

发送一条消息时严格按以下顺序：

1. 保存 user message 和 AI placeholder；
2. 检查是否存在仍 pending 的结构化确认；当前输入能解析为选项时以 CAS 解决，明确无关时先 abandoned；
3. 读取显式 anchor，或从“当前 user message 之前的最后一条消息”构造唯一相邻候选；
4. 现有 Intent Router 只看当前输入和最小 Router Context；
5. 如果是明确执行 intent：
   - 能映射稳定 Recommendation ID → 走结果转行动；
   - 明确指向一条可唯一定位的原始记录修改 → 进入结构化 `dataCorrection` 分支和编辑确认流程；
   - 只说“总额不对”“760 应该是 500”但无法定位记录 → 不猜测修改对象，保留分析锚点并澄清是重算口径还是修改哪条记录；
   - 否则清除分析 anchor，走普通执行；
6. 如果是 query/query_analysis/unknown 且存在候选：
   - 确定性规则先判断；
   - 需要时调用专用 Follow-up Router；
7. relation = newTopic 时不继承事实；relation = ambiguous 时不创建 Job：
   - implicit anchor：确认“继续这份分析 / 作为新问题”；
   - explicit anchor：保留 parent，澄清要看的目标或维度；
8. relation 有效时编译 Context Snapshot；
9. Context Guard 通过后创建 child Job；
10. child Job 独立执行、恢复和落 Result；
11. 按 presentationStyle 渲染。

关键点：

- 不能用“消息数组最后一条”寻找自然候选，因为此时最后一条已经是本轮 AI placeholder；必须以 `sourceUserMessageID` 为界向前取前一条 assistant message；
- 不能先把父 Context 塞给通用 Intent Router；
- 不能让 Follow-up Router搜索全部历史；
- 不能因为显式 anchor 存在就覆盖用户当前明确执行意图；
- 不能在 Job 创建后重新选择 parent。

模糊确认消息保存：

- `pendingDecisionID`、候选 `parentResultID`、原始 `sourceUserMessageID` 和一次性状态；
- 选择“继续这份分析”后，同一 assistant message 从确认态切回 Agent placeholder，并用同一 idempotency key 创建 child；
- 选择“作为新问题”后，同一 user/assistant message 对进入普通 Chat/Router；
- 重复点击、冷启动恢复或旧回调只能有一个决定胜出。

## 13. Prompt 设计

### 13.1 新增 `agent_follow_up_router`

只负责闭集关系和目标选择：

- relation；
- targetClaimIDs；
- targetRecommendationIDs；
- scopeChange；
- correctedDimension；
- confidence；
- needsClarification。

它不输出答案，不读取 Evidence 数值，不选择任意历史。

### 13.2 调整 `agent_loop`

增加协议：

- inherited Evidence ID 可以被引用；
- 只能引用 Context Snapshot allowlist 中的 inherited Evidence；
- relation=changeScope 时禁止使用父数值；
- relation=correct 时不得重复已被纠正的口径；
- inherited/new Evidence 必须在 Claim 中保持来源；
- narrative 不得把父假设升级成事实。

### 13.3 双端和生产

当前代码边界：

- Debug `PromptManager` 含本地模板和 `loadRawTemplate`；
- Release `PromptManager` 只有类型标识和不可用 stub；
- 当前 `HoloBackendPromptService` 也是 DEBUG-only；
- Agent 前台分析和后台恢复却在 Release 直接调用 `loadRawTemplate`，已由 Release 编译证实为代码错误。

因此连续追问实施前先建立统一 `HoloPromptProvider` 协议：

- Release：只允许从后端获取 Prompt 正文和版本，失败时进入可解释等待/失败，不把商业 Prompt 烘焙进包；
- Debug：后端优先，允许使用 iOS fallback 便于开发和断网测试；
- 前台分析、后台恢复和冷启动续跑只依赖该协议，不直接调用 `PromptManager.loadRawTemplate`；
- 后端 Prompt 版本、协议版本和 source digest 写入 Job/诊断信封，便于恢复和发布证明。

每次 Prompt/协议变更必须：

1. iOS `PromptManager.swift` 增加/更新 Debug fallback；
2. 后端 `defaultPrompts.json` 同步；
3. `promptVersions` 升版；
4. 后端协议 validator 和 mock 同步；
5. Release configuration 编译通过，且二进制不包含商业 Prompt 正文；
6. ECS 重建部署；
7. 严格 release proof 和真实请求验证。

## 14. 失败模式与用户体验

| 失败 | 系统处理 | 用户看到 |
|---|---|---|
| parent Result 不存在 | 不编译 Context | “这份分析依据已过期，可以按原问题重新分析” |
| parent Evidence 为 partial/部分归档 | 解释可保留原 caveat；新计算只继承任务并重查 | “原依据覆盖不完整”或“原依据已不可复用，已重新查询” |
| Result Store 读取失败 | 不把失败当不存在，不创建 child | “暂时无法验证这份分析，请稍后重试” |
| 另一设备只有同步后的展示 JSON | 不继承展示文字 | “在这台设备重新分析” |
| Context digest 不一致 | 拒绝恢复旧 Job | “分析条件发生变化，正在重新开始” |
| child 创建未 commit | 不运行半成品；按 journal 前滚或进入 failedLaunch | 原消息显示“未能开始”，可重试或作为新问题 |
| implicit anchor 不确定 | 不静默继承 | 普通澄清或按新问题处理 |
| Follow-up Router 失败 | 确定性规则兜底；仍不确定则不继承 | 不出现错误承接 |
| 模型引用未授权 Evidence | Verifier reject / recovery | 不展示伪结论 |
| changeScope 仍引用旧范围 | Verifier reject | 重新分析或明确失败 |
| 继承 Context 超预算 | 确定性裁剪 | 用户无感；调试指标记录 |
| 必要事实裁剪后仍超预算 | 不生成残缺答案 | 提示缩小范围或拆分问题 |
| data block 含伪指令 | 转义隔离，仍当普通记录内容 | 不改变 Agent 行为 |
| 新增领域无权限 | 不用父结果猜新领域数据，生成 coverage/permission 结果 | “需要健康数据权限才能判断”并提供设置入口 |
| parent 消息删除 | 未发送 draft 失效；已建 child 不受影响 | 输入锚点消失或 child 正常完成 |
| App 被杀 | 按 child checkpoint 恢复 | 原消息继续更新，不新开一条 |
| 网络中断 | waitingForCondition.network | 显示等待网络，不显示失败结论 |
| 用户停止 | 只取消 child Job | 父分析仍可阅读 |
| 重复发送 | sourceUserMessageID/idempotency 去重 | 只出现一个结果 |
| 旧 App 不认识新字段 | optional 解码 | 仍按旧卡片展示 |

## 15. 隐私与安全

- 父用户问题原文不作为事实 Context重复注入；
- 父模型完整输出不进入新 Prompt；
- Evidence 只使用 `redactedExcerpt`；
- `redactedExcerpt`、记录备注和父标题仍按不可信数据转义并隔离，不能成为 Prompt 指令；
- sensitive/highImpact 继续服从现有脱敏和敏感度策略；
- Context Snapshot 保存在本机 Agent Store；
- transaction journal 只保存 ID、generation、digest 和状态，不复制 Claim/Evidence 正文；
- 服务端可观测性只上传枚举、数量、版本、耗时和错误码；
- 不上传 Result 标题、用户问题、Evidence 摘要或自由文本；
- 调试导出只提供 technical metadata；
- `contextDigest` 只用于本机一致性校验，不作为“脱敏”手段，也不得进入服务端遥测；隐私依赖最小化内容、文件保护和不上传原文。
- 账号与本机数据删除继续删除整个 `Application Support/Holo` 和全部 Chat Entity；新增 transaction journal 与 `agentInteractionJSON` 必须加入删除回归测试。

## 16. 非功能要求

### 正确性

- 明确新话题被错误继承：0 容忍；
- 明确历史卡片绑定错 Result：0 容忍；
- changeScope 混入旧范围数值：0 容忍；
- 未授权 Evidence 被最终答案引用：0 容忍；
- 同一 Job 多 canonical Result：0 容忍。

### 性能与成本

- 显式/确定性 anchor 解析在本地完成；
- 本地确定性 anchor/relation p95 目标 < 20ms；
- 一批 50 条历史 Agent 消息的 continuation availability 只做一次 Store load，目标 p95 < 100ms，滚动中不逐卡 I/O；
- inherited Context 默认目标 ≤ 1,500 token；
- inherited Context token、裁剪率和超预算率分别统计 p50/p95/max；用户被要求拆分的灰度目标 < 0.1%；
- 编码后的 FollowUpContextSnapshot 硬上限 64 KiB，`agentInteractionJSON` 硬上限 16 KiB；
- Prompt 体积不随追问轮数线性增长；
- explain 默认 0 新工具调用；
- drillDown 只调用缺失工具；
- crossDomain 默认只补查新领域，同时参与领域数 ≤ 3；记录工具复用数、新查数、耗时和预算拒绝数；
- relation Router 独立统计延迟和成本；
- 完整 Agent 预算仍由现有 BudgetSelector 决定。

### 可靠性

- RPO：已创建 child Job 的 lineage、Context Snapshot 和 checkpoint 不丢；
- child 创建事务一旦向 UI 返回成功，RPO = 0；未 commit 的请求必须可由 interaction state/journal 前滚或明确失败；
- 冷启动不重新猜 parent；
- 取消 child 不修改 parent；
- generation/CAS、step idempotency 和 canonical Result 唯一规则继续生效；
- 父 Result 清理不得破坏非终态 child。

### 可维护性

- 只有 Context Compiler 定义继承规则；
- 只有 Anchor Resolver 选择 parent；
- 只有 Job 决定权威时间范围；
- 只有 Evidence / Verifier 决定事实；
- UI 不解析自然语言判断 relation；
- Prompt 不承担生命周期和清理规则。

### 可观测性

本机或隐私安全聚合记录：

- anchorSource；
- relation；
- parent 是否可用；
- inherited/new Evidence 数；
- context token 数和裁剪数；
- Context Guard 拒绝原因；
- wrong-anchor 用户纠正信号；
- follow-up 完成率、恢复率、取消率；
- Prompt/协议/工具版本。

## 17. 分阶段实施

### Phase 0：契约与事故测试

- 先修复并验证 Release Prompt 获取链；Release configuration 必须不再调用不存在的 `loadRawTemplate`；
- 先建立 parent 选错、旧范围污染、长链膨胀、父结果过期等失败 fixture；
- 为 JSON Store 替换失败、主文件缺失和 last-known-good 恢复建立注入式故障测试；
- 建立 v1/v2 InputSnapshot hash 兼容和存量非终态 Job reconcile 测试；
- 用真实 fixture 记录 inherited Context token 的 p50/p95/max、裁剪率和拆分率，1,500 token 先作为保守初始值；
- 新增 model types，但全部 optional；
- 增加 optional `agentInteractionJSON` schema 和迁移测试；
- 定义 presentationStyle 和 UI 文案。

完成标准：没有业务功能前，失败边界已有红灯测试。

### Phase 1：显式锚定产品闭环

- Agent 卡片 footer actions；
- 详情页“继续追问”；
- ChatViewModel ContinuationDraft；
- ChatInput Context 锚定条；
- rendered continuation metadata；
- 历史 Result live availability check。
- 持久化 pending interaction state 和一次性按钮 CAS。

完成标准：用户能明确选择任意有效历史 Result，输入框清楚显示绑定对象。

### Phase 2：Result lineage 和 Context Snapshot

- Job / Result / Checkpoint / InputSnapshot 新字段；
- Result/Job Store 精确查询；
- Context Compiler / Guard；
- inherited Evidence allowlist；
- child 自包含恢复。
- transaction gate、journal 和启动前滚 Reconciler。
- cleanup policy 执行、Evidence orphan 重算和生产 retention 调度。

完成标准：显式追问可完成、取消、冷启动恢复且只产生一个 Result。

### Phase 3：relation 与执行策略

- 确定性 relation；
- 专用 Follow-up Router；
- explain/drillDown/correct/changeScope/crossDomain；
- 结果转待办确认卡；
- 区分分析口径纠正和可唯一定位的 `dataCorrection`；后者必须经过新增编辑确认流程；
- relation 对应的重查/复用策略。

完成标准：Use Case 全链路通过，父 Result 不被修改。

### Phase 4：自然相邻追问

- 只对当前会话相邻、命中确定性规则且 parent/relation/target 唯一的 Result 开启；
- loading 阶段显示承接来源；
- ambiguous/newTopic 不继承；
- 跨会话和 ambiguous 确认态可恢复、可幂等点击；
- implicit 开关独立于 explicit。

完成标准：自然追问可用，且对抗集无错误串题。

### Phase 5：展示与详情

- followUpReply；
- 变化标签；
- 详情页分析关系；
- expired / reanalyze；
- VoiceOver、Dynamic Type、长标题和 Dark Mode。

完成标准：连续追问不会造成卡片堆积，用户能理解沿用/重查区别。

### Phase 6：真实链路与灰度

- standalone / 组合 / UI 模型；
- 真实模型重复运行；
- 统计 inherited Context token p50/p95/max、裁剪率、超预算率和用户拆分率；
- 真机锁屏、断网、冷启动、取消；
- explicit-only 内测；
- 再开启 implicit；
- CloudKit optional schema 在开发环境验证后部署到生产 schema；
- TestFlight 达到既有样本门槛。

完成标准：不是“能聊起来”，而是正确承接、事实可信和恢复可靠同时过线。

## 18. 工程影响范围

### iOS 模型与 Runtime

- `HoloAgentExecutionModels.swift`
- `HoloAgentJobModels.swift`
- `HoloAgentCheckpointModels.swift`
- `HoloAgentResultModels.swift`
- `HoloAgentInputSnapshotHasher.swift`
- `HoloAgentAnalysisService.swift`
- `HoloBackgroundContinuationManager.swift`
- `HoloBackendPromptService.swift`
- `HoloAgentScheduler.swift`
- `HoloLocalAgentRuntime.swift`
- `ConversationCoordinator.swift`
- `AIUserContextMessageBuilder.swift`
- 新增 `HoloAgentAnchorResolver.swift`
- 新增 `HoloAgentFollowUpResolver.swift`
- 新增 `HoloAgentContextCompiler.swift`
- 新增 `HoloAgentContextGuard.swift`
- 新增 `HoloAgentPromptEscaper.swift`
- 新增 `HoloAgentEvidenceReferenceCollector.swift`

### iOS Chat 与展示

- `ChatViewModel.swift`
- `ChatView.swift`
- `ChatInputView.swift`
- `MessageBubbleView.swift`
- `AgentDeepAnalysisCard.swift`
- `AgentDeepAnalysisDetailSheet.swift`
- `HoloAgentResultRenderer.swift`
- `ChatMessage+CoreDataProperties.swift`
- `CoreDataStack+ChatEntities.swift`
- `ChatMessageViewData.swift`
- `ChatMessageRepository.swift`
- 新增 `HoloAgentInteractionState.swift`
- 新增 `AgentFollowUpReplyView.swift`

### Persistence

- `HoloAgentJobStore.swift`
- `HoloAgentResultStore.swift`
- `HoloAgentPersistenceManager.swift`
- Evidence orphan 生产 retention 调度；
- Evidence 引用和清理逻辑；
- 一致性 Reconciler。
- 新增 `HoloAgentPersistenceTransactionGate.swift`
- 新增 `HoloAgentTransactionStore.swift`
- 新增 `HoloAgentLineageValidator.swift`

### Prompt / Backend

- `PromptManager.swift`
- 新增 `HoloPromptProvider.swift`
- `HoloBackend/src/prompts/defaultPrompts.json`
- `HoloBackend/src/prompts/promptRegistry.js`
- Follow-up Router purpose / validator / mock；
- follow-up feature flags / 灰度组 release config 和 implicit kill switch；
- 生产 release proof。

### 测试

- Anchor Resolver standalone；
- Context Compiler / Guard standalone；
- Job lineage / cleanup / recovery；
- v1/v2 InputSnapshot hash 与存量非终态 Job reconcile；
- Release configuration Prompt Provider 编译和二进制 Prompt 扫描；
- Result Renderer / ViewData optional decode；
- ChatViewModel continuation state；
- Agent Eval 多轮 corpus；
- 后端 Prompt / validator / production verification。

## 19. 测试矩阵

### 19.1 关系识别

- 为什么；
- 第二点；
- 第一条建议；
- 不是金额，是频率；
- 换成今年；
- 那睡眠呢；
- 帮我记 50 元；
- 最近步数怎么样；
- 那其他呢（模糊）；
- 回到最开始那份。
- 未命中确定性规则但模型 confidence 很高时仍不自动继承；
- 同一输入出现两个可行 target 时进入确认，不选分数最高者。

### 19.2 Context 污染

- 父回复含无 Evidence 的模型推测；
- 父 Result 同时有金额、频率和建议；
- 两份相邻 Agent Result 来自不同领域；
- 父范围和 child 范围冲突；
- 父 Evidence canonical identity 相似但口径不同；
- profile 与当前指令冲突；
- 长期记忆与当前事实冲突；
- 20 轮 lineage；
- 敏感 Evidence；
- 父 Result 被清理。
- 交易备注/观点内容包含“忽略系统规则”“调用某工具”等伪指令；
- 父 Claim 短标题包含 role 标签或超长文本；
- “现在呢”错误沿用旧快照；
- 跨领域两侧使用不同 snapshotCutoffAt。

### 19.3 生命周期

- child 创建前 parent 被清理；
- child Snapshot 落盘后 parent 被清理；
- child 运行中 App 被杀；
- Context digest 变化；
- duplicate send；
- generation stale callback；
- parent 消息删除；
- Evidence archived；
- Result Store 损坏/读失败；
- old JSON 无新字段。
- v1 非终态 Job 在 v2 App 启动后按 v1 hash 恢复，不被误判 inputChanged；
- child 创建与 parent cleanup 并发；
- JSON Store replace 和 fallback 二次失败后仍能从 last-known-good 恢复；
- Snapshot staged write 在 commit 前被杀；
- Evidence 引用添加后 Job 保存失败；
- child Result 清理后的 Evidence orphan reconciliation；
- contextDigest 排除自身、时间戳后跨恢复保持稳定；
- lineage 自环、双 parent 和错误 root；
- lineage 第 20 轮正常完成，第 21 轮滚动为新 root；
- cleanup policy 三个开关组合和 orphan retention 生产入口；
- Claim 顶层与 assertion Evidence ID 并集一致；
- user message 后已有 placeholder 时，相邻候选仍定位到正确上一条 assistant Result；
- 模糊确认重复点击只产生一个决定和一个 Job；
- pending decision 同时发生按钮点击和文字回复时只有一个 CAS 胜出；
- CloudKit 只有展示 JSON、本机无 Agent Store；
- 旧 Result 无 `presentationOrder` 时输入“第二点”不会错误指代。

### 19.4 UI

- 卡片 0/1/2 个 footer action；
- explicit anchor；
- anchor 取消；
- voice input；
- followUpReply 长文；
- changeScope 新卡片；
- expired reanalyze；
- loading source label；
- stop；
- Dynamic Type；
- VoiceOver；
- Dark Mode；
- 历史加载后继续。
- 锚点 A 切换到 B；
- 锚点输入期间失效；
- Store checking / unavailable / reanalyzeRequired 四态；
- 跨 4 小时确认和冷启动恢复；
- 同会话 ambiguous 确认和冷启动恢复；
- 用文字选择/取消 pending decision；
- “继续/算了/作为新问题”命中确定性词表，“嗯继续呗/先这样吧”不自动点选；
- 另一台设备显示“在这台设备重新分析”。

### 19.5 跨领域

- 财务 → 健康；
- 健康 → 习惯；
- 习惯 → 任务；
- 任务 → 目标；
- 观点 → 情绪/习惯；
- 相关性不升级因果；
- 不同数据覆盖形态不混用。
- “财务 + 睡眠”后问“那和步数呢”默认成为“财务 + 步数”，不累积睡眠；
- 用户明确要求三个领域时允许，第四个领域提示拆分；
- 无 freshness 时复用父截止时间并只补查新域；“现在呢”冻结新截止时间并重查全部参与域；
- directParent 与 comparisonReference 的同名指标、不同范围不串值；
- secondary reference 未完成隔离时功能开关保持关闭。

## 20. 放量与回滚

功能开关：

- `agentExplicitFollowUpEnabled`
- `agentImplicitFollowUpEnabled`
- `agentFollowUpActionEnabled`

三项开关由后端 release config 控制并允许按构建/灰度组下发；客户端只缓存最后一次有效配置，首次读取失败或配置未知时 `agentImplicitFollowUpEnabled = false`。设备确认发生 wrong-anchor 后触发本地 circuit breaker，立即关闭该设备 implicit；聚合告警触发服务端关闭全局/灰度组 implicit。explicit 不依赖模型置信度，可单独保留。

顺序：

1. 内部构建只开 explicit；
2. 验证历史、恢复和 Context 污染；
3. TestFlight 只为确定性规则集开启 implicit，不用模型置信度单独放行；
4. 观察 wrong-anchor、用户立即纠正、完成率和成本；
5. 明确新话题或错误 parent 绑定保持 0 容忍；任一硬失败立即自动关闭 implicit，保留 explicit；
6. 只有真实 Eval 证明新增语料 precision 达标后才扩大规则集。

回滚：

1. 先关 implicit，保留显式继续；
2. 再关 result-to-action；
3. 必要时关 explicit UI；
4. 已写入的 optional lineage 和 Result 继续可解码；
5. optional `agentInteractionJSON` schema 保留但停止写入，旧/回滚 UI 忽略；
6. canonical Result、Evidence 和恢复可靠性能力不回滚。

如果是 TestFlight/内部构建的**二进制降级**，必须先由新版本停止新建 follow-up，等待或取消全部非终态 child，并确认无 prepared transaction；不能在多文件事务进行中直接安装旧 Runtime。普通服务端开关回滚不需要这一步。

## 21. 复杂度与排期

只做“把上一轮文字塞进 Prompt”的 Demo：1–2 个工程日，但不可交付。

完整主链路、不含充分真实验证：约 10–14 个工程日。

按本方案补齐：

- 显式和自然交互；
- Context 编译与污染防护；
- Result 生命周期；
- 轻量/完整两类展示；
- 结果转行动；
- 历史、冷启动、清理和迁移；
- 对抗测试与真实模型；

经过三轮 Review，把持久化事务、跨设备、确认态恢复、旧数据兼容、JSON Store 故障恢复、Release Prompt 链、hash 兼容、跨域成本和 reference 隔离纳入后，更合理的工程量是 **18–26 个工程日**，另需 **3–7 天真机和 TestFlight 观察**：

| 工作包 | 工程量 |
|---|---:|
| 卡片、锚定条、详情、轻量回复、确认态 | 3–4 日 |
| lineage、Snapshot、Store 查询和 schema | 3–4 日 |
| transaction gate/journal、cleanup、Reconciler | 3–5 日 |
| Anchor/Follow-up Resolver、Context Compiler/Guard | 4–5 日 |
| Runtime、Prompt、Verifier、结果转行动 | 3–4 日 |
| 自动化、迁移、对抗、真机前的修复 | 2–4 日 |

这不是重写 Agent 的成本，主要是把“能追问”做成“不会串、不会错、能恢复、用户看得懂”的成本。

## 22. Definition of Done

只有全部满足才算完成：

- [ ] Agent 卡片和详情页能显式继续；
- [ ] 输入框清楚显示显式绑定对象并可解除；
- [ ] 确定性规则覆盖的自然相邻追问可用，模型置信度不能单独放行；
- [ ] 模糊输入不静默继承；
- [ ] 模糊确认跨冷启动可恢复，重复点击只生效一次；
- [ ] 执行 intent 不受旧分析污染；
- [ ] parent/root/current Result 均由稳定 ID 定义；
- [ ] child Job 持久化 lineage 和 Context Snapshot；
- [ ] child 创建、cleanup 和恢复经过 transaction gate/journal，不暴露半成品 Job；
- [ ] cleanup policy 三个开关真实生效，Evidence orphan 清理已接入生产调度且可恢复；
- [ ] 父 Result 不被修改；
- [ ] explain 默认不重查；
- [ ] changeScope/correct 按规则重新查询；
- [ ] inherited/new Evidence 可区分；
- [ ] Context 只含 allowlist 事实和 redactedExcerpt；
- [ ] 所有自由文本 data block 已转义隔离，Prompt 注入对抗集通过；
- [ ] Context 体积不随历史轮数线性增长；
- [ ] inputSnapshotHash 包含 Context digest；
- [ ] v1/v2 InputSnapshot hash 兼容，升级中的非终态旧 Job 不被误判为输入变化；
- [ ] 冷启动不重新猜 parent；
- [ ] duplicate send 不产生双 Job/双 Result；
- [ ] canonical Result 过期后不会继续伪引用；
- [ ] 旧 agentResultJSON 可解码；
- [ ] 旧 Result 无稳定展示顺序时不猜“第二点”；
- [ ] 跨设备只有展示 JSON 时不伪造父事实，只提供本机重分析；
- [ ] optional Core Data / CloudKit schema 迁移和旧版本兼容通过；
- [ ] 财务、健康、习惯、任务和跨域对抗回归通过；
- [ ] crossDomain 默认不滚雪球累积，参与领域不超过 3，freshness/复用规则通过成本与正确性回归；
- [ ] secondary reference 以 directParent/comparisonReference 隔离，并由 V2 逐数值核验；未实现时功能关闭；
- [ ] lineageDepth 上限、滚动新 root 和第 20/21 轮边界测试通过；
- [ ] 数据原始记录修改只能在唯一定位后进入编辑确认流程；
- [ ] 真机锁屏、断网、冷启动、停止和恢复通过；
- [ ] Release Prompt Provider 链编译通过，前台/后台均不调用 Debug-only API；
- [ ] 后端 Prompt 双端同步、升版、部署和生产验证；
- [ ] TestFlight 达到既有样本和完成率门槛；
- [ ] 没有已知 P0 缺陷被以“后续再补”方式放行。

## 23. 三轮审查记录

### 23.1 第一轮：产品完整性 Review

审查问题：

1. 用户是否始终知道自己在继续哪份分析？
2. 用户不点按钮、从历史分支、跨会话、切换锚点时是否都有确定行为？
3. noData、unverifiable、failed、cancelled、expired 是否被错误当成普通结果？
4. 简单追问是否导致完整卡片无限堆叠？
5. 执行动作、语音、详情页、无障碍和大字体是否形成闭环？

发现并已修正：

- 原草稿只描述绑定，缺少 A→B 锚点替换和 parent 输入期间失效；
- 模糊自然追问缺少可恢复的“继续 / 新问题”确认；
- 显式锚点下的目标歧义不应再次问是否继续，改为澄清具体维度；
- 确认消息只支持按钮会卡住习惯打字的用户，补齐文字选择、取消和新话题覆盖；
- 轻量追问回复缺少“继续追问”，导致 Result B 无法成为历史分支；
- noData / unverifiable 缺少历史追问原因入口；
- Agent 运行中切换历史锚点会造成用户误解，改为禁用并解释；
- 详情页校验失败后不应先关闭，改为原地提供重新分析；
- 卡片嵌套 Button、44pt 点击区、Dynamic Type、VoiceOver 和 safe area 行为补齐。

结论：产品旅程从“发现入口 → 绑定 → 输入 → 确认 → 运行 → 展示 → 再追问 → 历史分支 → 失败恢复”已闭环，没有已知 P0 交互状态留给模型或 UI 临时猜测。

### 23.2 第二轮：技术、故障与数据边界 Review

审查问题：

1. parent 是否由稳定 ID 唯一确定，旧 UI metadata 能否伪造或错绑？
2. child 是否能在清理、崩溃、重复点击和 actor 重入下保持唯一且可恢复？
3. Context 是否会递归膨胀、混入旧范围、父 narrative、Prompt 伪指令或不同快照？
4. 旧数据、旧 Runtime、CloudKit 跨设备和 Store 读失败是否安全降级？
5. 历史列表、Evidence 引用、清理和 JSON 文件替换是否存在隐藏性能/数据丢失风险？

发现并已修正：

- 仅保存 selectedClaimIDs 无法在 parent 清理后恢复，改为保存最小 verified assertion snapshot；
- `contextDigest` 原设计存在自引用/时间戳/数组顺序不稳定，改为排除非身份字段并 canonical 排序；
- 跨领域只补查新领域会混用两个快照，改为默认重查全部参与联合计算的领域；
- `redactedExcerpt` 仍可能包含伪指令，补齐 data block 隔离、转义和注入对抗；
- 保存 AI placeholder 后再找“最后一条消息”会锚到自己，改为以 sourceUserMessageID 向前解析；
- 只靠 PersistenceManager actor 无法防止 `await` 重入，改为 transaction gate + journal + 前滚 Reconciler；
- 现有 cleanup 先删 Job 会留下无真相源残片，改为 Result/Checkpoint/Evidence 引用先处理、Job 最后删除；
- Chat 已保存、journal 尚未 prepared 的崩溃窗口会永久转圈，新增持久化 `agentInteractionJSON(launching)`；
- Result Store 读失败不能当作“结果不存在”，增加 temporarilyUnavailable；
- CloudKit 只有展示 JSON 时不能继承事实，改为本机重新分析；
- “第二点”在 Renderer 升版后可能漂移，新增冻结 presentationOrder；
- Result Evidence 顶层与 assertion 引用可能不一致，新增 canonical collector；
- 历史每卡单独读取 JSON 会放大 I/O，改为批量查询和 generation cache；
- 现有 JSON Store delete-then-move fallback 存在主文件缺失窗口，纳入 last-known-good 硬化；
- 新枚举值可能导致 persisted JSON 整体解码失败，改为 raw string + known-or-unknown；
- 旧 Runtime 只看到“为什么”会错误恢复，child 的 legacy `userQuestion` 改为可独立重查的问题，原话另存。

结论：第二轮发现的高风险竞态、恢复、兼容、污染和数据丢失问题均已进入主方案、实施阶段、失败表、测试矩阵和 DoD；当前没有已知 P0 技术缺口被延后。真正上线仍必须完成第 22 节全部门禁，文档 Review 不能替代实现和真机证明。

### 23.3 第三轮：对抗性审查（代码现状核实 + 自审盲区）

审查方式：逐条对照真实代码核实前两轮声称的“现有基础”和“当前断点”，并从前两轮未覆盖的盲区反向找问题。

本节保留 23.1/23.2 作为历史审查记录，不回写或改写其结论原文；涉及当前实施状态、优先级和门禁时，以 23.3 及已经回填到正文的决策为准。

#### 23.3.1 对代码现状的核实结果

总体：方案对现有 Job / Result / Evidence / Scheduler 主链的描述基本准确，但“10 项中 9 项属实”缺少逐项核验表，不能作为可复核数字保留。以下偏差已经回填正文，实施者必须以修正后的前提工作。

**修正点 1：cleanup 现状描述与代码不符**

第二轮（23.2）描述为“cleanup 先删 Job 会留下无真相源残片”。真实代码（`HoloAgentPersistenceManager.cleanupTerminalJobs`）现状是：

1. 先删 Job；
2. 再顺序删除 Checkpoint 和 Result；三个跨 Store 操作不是“同时级联”，中途失败会留下部分删除状态；
3. Evidence 不在这条链里；代码虽然存在独立的 `cleanupOrphanedEvidence`，但全工程目前没有找到生产调用方，不能称为“已经由独立路径驱动”；
4. 隐藏炸弹：cleanup policy 的 `cascadeCheckpoint / cascadeResult / preserveReferencedEvidence` 三个开关已在 `HoloAgentResultModels.swift` 定义，但 cleanup 代码**当前根本没读它们**，是无脑全删。

修正影响：方案第 8.4、11.8 节已改为真实生命周期闭环：Job cleanup、policy 执行、Evidence 引用重算、orphan 清理生产调度必须一起进入 transaction gate/journal。存在一个清理方法不等于生产生命周期已经成立。

**修正点 2：Scheduler 冷启动恢复是“全量扫描”，非按消息反查**

方案多处描述冷启动恢复像“精准定位”，但真实代码（`HoloLocalAgentRuntime.collectResumableJobs`）是 `jobStore.load()` 全量加载 → 过滤非终态、非 paused → 按优先级限量 resume；**根本不用 `sourceMessageID` 反查**，恢复的是任意非终态 Job。

由此衍生两个实施风险：

- 新增 child Job 会直接掉进这套全量扫描，`inputSnapshotMatches` 用 `inputSnapshotHash` 判断 needs-replan，而方案 11.4 要往 InputSnapshot 加 lineage/relation/followUpContextDigest——**加字段会改变 hash 值**。升级时若恰好有运行中的旧格式 Job，恢复时 hash 对不上会被误判为“输入变化”。处置为按 schemaVersion 使用不同字段集合计算 hash，并对存量非终态 v1 Job reconcile，已回填 11.4、Phase 0、测试和 DoD；
- 反向查询（从某条 ChatMessage 找其 Job）目前**无任何索引**。方案 11.6 的 `JobStore.forSourceMessageIDs(_:)` 是**待新建接口**，必须支持批量调用（历史分页一次性查询），不能逐条。

**修正点 3：Claim 在渲染层目前没有稳定 ID**

Use Case（Step 2 targetClaimID）和测试矩阵（19.1“第二点”）假设 Claim 有可引用稳定 ID 和展示顺序。真实代码：

- `HoloRenderedRecommendation` 有 `id`（= claim.id）✅；
- `HoloRenderedAgentSection`（承载 Claim 和观察）**没有 id 字段** ❌——render 时 claim.id 被丢弃。

方案 11.6 已明确补 `id/sourceClaimID`：这不是“读现成字段”，而是**从渲染器一路把 id 接通**。历史已渲染的旧卡片没有这个 id，只能走 11.6 的“旧数据降级”（不猜“第二点”、让用户点选）。该前提已进入测试和 DoD。

#### 23.3.2 两轮自审未覆盖的盲区

以下问题在前两轮未被触及，按风险排序。

**盲区 1（P0）：原方案把“高置信度”作为 implicit 总开关，但阈值未定义**

修订前的 5.3、Phase 4、第 20 节反复用“Resolver 达到高置信度”作为是否自动承接的门槛，但未定义：多高算高、如何校准、错判后如何快速止血。影响：

- implicit 自然追问是体验甜点，也是最大串题风险源；
- 阈值直接决定 implicit 能否开灰度；
- wrong-anchor 是事后观测，**若阈值定错，等观测到 wrong-anchor 飙高时已有大量用户被错承接**。

**处置结论**：不预设 `0.8` 这类未经校准的模型阈值。P0 只允许确定性规则 + 唯一 parent/relation/target 自动承接；模型 confidence 仅作诊断。明确新话题或错误 parent 绑定保持 0 容忍，一旦出现硬失败自动关闭 implicit、保留 explicit。该决策已回填 5.3、Phase 4 和第 20 节。

**盲区 2（P0）：crossDomain 连续追问的滚雪球式全量重查，成本无人评估**

方案原 9.4、Step 4 要求跨领域用同一 snapshotCutoffAt 重查全部参与领域，容易被实现为累积查询：

```
“那和睡眠呢” → 重查 财务 + 睡眠
“那和步数呢” → 重查 财务 + 睡眠 + 步数
“那和心情呢” → 重查 财务 + 睡眠 + 步数 + 心情
```

**处置结论**：上述滚雪球不是产品必然语义。新规则默认替换新增比较域：“财务 + 睡眠”后问“那和步数呢”解析为“财务 + 步数”；只有用户明确要求才累积。无 freshness 语义时沿用父截止时间并只补查新域；新截止时间才重查全部参与域；同时最多 3 个领域。该结论明确覆盖 23.2 中“默认重查全部参与领域”的历史判断，但按审查记录要求不改写 23.2 原文；当前实施以 9.4 为准。该项已回填 9.4、NFR、测试和 DoD。

**盲区 3（P1）：lineage 链无深度上限**

Context 不膨胀（靠 Snapshot）正确，但 lineage 链本身**未定义最大深度**，理论上可问出 A→…→Z 超长链。带来的隐患：

- 每轮 lineage 校验（防环、root 传播）遍历父链，深度极大时有性能成本；
- 20 轮长链里用户自己也说不清“最开始”是哪份；
- Snapshot 链式继承，**中间任一环的继承策略缺陷会沿链层层放大**，单轮测试看不出，长链才暴露。

**处置结论**：持久化 `lineageDepth`，最大 20；达到上限后将当前最小可信 Snapshot 滚动为新 root，用户仍能继续，不要求递归遍历整条祖先，也不生硬终止对话。已回填 8.2 和 DoD。

**盲区 4（P1）：“纠正事实” vs “纠正口径” Router 判不出来**

场景表（第 632 行）要求区分“更换分析口径”与“修改原始记录”，但 Follow-up Router 的闭集 relation（explain/drillDown/correct/changeScope/crossDomain/executeFromResult/newTopic/ambiguous）**没有“数据修正”档**。

用户说“760 不对应该是 500”可能是“重算口径”（→ correct）也可能是“改一笔账”。当前 `AIIntent` 没有编辑交易意图，现有待确认交易卡解决的是新增记录，不是对任意原始记录的 AI 编辑，因此不能写成“路由到现有编辑确认卡”。

**处置结论**：`dataCorrection` 属于执行路由而不是新的分析 lineage relation。仅当用户指出可唯一定位的具体记录时，进入新增结构化编辑确认流程；聚合总额无法映射到唯一记录时先澄清是重算口径还是修改哪条记录。已回填第 7、12、Phase 3 和 DoD。

**盲区 5（P1）：referencedResultID 的双事实隔离规则缺失**

方案 8.2 引入 `referencedResultID` 作为“比较材料、不建双父”。但**比较意味着 Context 里要同时放 current 和 referenced 两份事实**。若 current 是“今年”、referenced 是“最近一个月”（比较的常见场景），如何防止模型把两个范围的数值搅在一起？方案只说“不参与 lineage 归属”，但 Compiler 如何隔离两份事实、Verifier 如何校验“比较结论的数字确实来自对应范围”**一条规则都没写**。这其实是变相的双上下文问题——方案花大力气保证单父不污染，却在 referencedResultID 处开了一个没设防的口子。

**处置结论**：Snapshot 字段收紧为单数 `referencedResultID`；Compiler 分离 `directParent` 与 `comparisonReference` 两个类型化 block，比较 Claim 的每个数值携带 source role/scope 并由 V2 逐项核验。隔离未实现前关闭 secondary reference。已回填 9.5 和 DoD。

**盲区 6（P1）：1500 token 硬上限缺乏 Eval 支撑，极易频繁触发“拆分提示”**

inherited Context ≤ 1500 token 已写入 DoD 与性能指标，但方案自己承认“数值需通过真实 Eval 调整”。原 9.6 已经存在确定性裁剪顺序，因此“只有残缺裁剪和踢给用户拆分两极”的批评过度；真正缺口是缺少真实分布、溢出率和裁剪后语义完整性的 SLO。

**处置结论**：明确区分 64 KiB Snapshot 存储上限与 1,500 token Prompt block；记录 p50/p95/max、裁剪率、`contextTooLarge` 和用户拆分率，灰度拆分目标 < 0.1%；增加确定性 Composer/目标重查等中间降级。1,500 token 是 Eval 前的初始值，不是已证明常量。已回填 9.6、NFR 和 Phase 0。

#### 23.3.3 四项架构商榷的复核结论

**商榷 1：Prompt 获取链不是 P2，而是已证实的 P0 Release 阻塞**

原审查称“`PromptManager` 整个类 DEBUG-only、Release 从后端拉 Prompt”，事实不完整：Release 存在精简 stub；`HoloBackendPromptService` 反而也是 DEBUG-only；前台 `HoloAgentAnalysisService` 和后台 `HoloBackgroundContinuationManager` 在 Release 仍直接调用不存在的 `loadRawTemplate`。

2026-07-29 实际执行 Release configuration 编译，明确出现两处 `value of type 'PromptManager' has no member 'loadRawTemplate'`。构建同时有本机 Preview Macro 环境错误，但不影响这两个代码错误成立。处置是先建立统一 `HoloPromptProvider`，Release 后端-only、Debug 后端优先并允许本地 fallback；前台和后台只依赖协议。已回填 13.3、Phase 0 和 DoD。

**商榷 2：Context Guard 与现有 V2 Verifier 能力高度重合**

原审查称二者“几乎完全重合”过度。Context Guard 是执行前输入授权，V2 是输出后 Claim 验证，不能互相替代。正确关系是保留前后两道门，同时复用 scope、Evidence existence、window comparability、causal compliance 和 metric identity 纯校验原语，避免规则漂移；连续追问事实任务强制 V2。已回填 9.2。

**商榷 3：“4 小时会话边界”是缺乏依据的魔数**

4 小时并非完全无依据：现有 `HoloConversationTool.sessionActivity` 已用相邻消息间隔超过 4 小时切断当前会话。但这个规则只能作为兼容兜底，不能单独授予事实继承。新方案优先使用消息邻接、当前 Chat 前台交互段和显式锚点；显式历史继续不受 4 小时限制，implicit 跨前台会话或 4 小时必须确认。已回填 5.3。

**商榷 4：confirm 消息的文字选择依赖中文口语变体识别鲁棒性**

按钮是 P0 canonical 决策入口；文字只支持确定性小词表。开放口语不使用模型 confidence 自动点选，保持 pending 或按普通输入重路由。已回填 5.3。

#### 23.3.4 与同日《P0 四项能力实施方案》的关系需澄清

本文开头原本已经把 P0 四项方案列为关联文档，因此“两份关系完全未提及”不准确；真正缺口是没有规定实施权威和顺序。现已在 3.4 明确：P0 四项方案是总路线，本文是 P0-1 唯一详细规格；共享字段只改一次；先修 Release/发布身份和 metric identity，再实施连续追问，质量门禁并行建设。

#### 23.3.5 值得肯定的设计

对抗性审查不是挑刺比赛，以下确实扎实：

1. **对现有架构的主干描述诚实**——Job / Result / Evidence / Scheduler 的可复用方向成立，没有为了显得“改动小”而虚构第二套 Runtime；具体比例不再使用缺少核验表的“10 项中 9 项”。
2. **事务闸门（transaction gate + journal + 前滚 Reconciler）抓住了真实痛点**——PersistenceManager 确实是 actor，子 store 调用确实 `await` 挂起，actor 重入风险真实存在。这块是全篇最有技术价值的部分。
3. **跨设备“只有展示 JSON 不能继承事实”处理干净**——Verifier 经核实是 iOS 本地确定性校验（V1 两态、V2 十维三态，不是模型、不在服务端），“本机无 Agent Store 只能重新分析”与架构完全自洽，非硬凑。
4. **Prompt 注入防护到位**——`redactedExcerpt` 当不可信数据、data block 隔离、转义分隔符与伪造 role 标签，且第二轮专门补了交易备注/观点内容中的伪指令，比多数同类方案细。

#### 23.3.6 本轮结论与修订优先级

本轮对抗性审查发现的问题已经完成事实复核并回填正文。最终优先级按用户风险和实施阻塞重新排序：

| 优先级 | 事项 | 性质 |
|---|---|---|
| **P0** | 修复 Release Prompt Provider 链并通过 Release configuration 编译 | 当前前台/后台 Agent 在 Release 调用不存在的 API |
| **P0** | cleanup policy、Evidence orphan 标记和生产调度进入同一 journal/gate | 当前生命周期方法存在但闭环未运行 |
| **P0** | implicit 仅确定性规则放行，wrong-anchor 硬失败自动关闭 | 防止静默串题 |
| **P0** | crossDomain 默认替换比较域、同截止复用、freshness 重查、最多 3 域 | 防止查询滚雪球和快照错位 |
| **P0** | v1/v2 InputSnapshot hash 兼容与存量 Job reconcile | 防止升级时误拒绝恢复 |
| **P1** | Claim ID 全链路、lineageDepth、dataCorrection、reference 双事实隔离 | 完成稳定指代、长链和纠正边界 |
| **P1** | 1,500 token Eval、裁剪完整性和拆分率 SLO | 以真实分布决定最终阈值 |
| **P1** | P0 总方案与本文按 3.4 单向对齐 | 防止共享模型重复建设 |
| **P2** | 4 小时兜底和文字小词表持续通过真实反馈调整 | 不影响明确按钮路径 |

本方案的核心架构仍可交付，但当前状态是“P0 修订已回填、进入实施前门禁待通过”，不是无条件 Ready。可以先实施 Phase 0 的 Release Prompt 链、hash 兼容、事故 fixture 和 Eval 基线；在这些门禁变绿前，不进入 implicit 和跨域主链。真正上线仍必须完成第 22 节全部 DoD、Release 构建、真实模型、真机和 TestFlight 证明，文档 Review 不能替代实现证据。
