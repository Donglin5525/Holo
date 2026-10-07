# UC-MATTER-001：国庆日本旅行从规划到完成

> 本文档是 Matter 首发版的唯一主 Use Case。
>
> 产品、设计、iOS、后端、测试必须以本文档为同一契约。
>
> 任何实现如果为了复用旧代码而改变本旅程，都应修代码，不应修 Use Case。
>
> 状态：用户契约，未实施，未经构建、真机、CloudKit 或生产验证。

---

## 1. Use Case 身份

| 字段 | 定义 |
|---|---|
| ID | `UC-MATTER-001` |
| 名称 | 国庆日本旅行从规划到完成 |
| 主要用户 | 一个需要筹备复杂生活事项的 Holo 用户 |
| 用户目标 | 不需要自己搭建一套项目管理系统，就能把旅行准备这件事真正推进完 |
| 对 Holo 的要求 | 记住背景、建立完整计划、每次给出一个下一步、根据进展更新，直到事项完成 |
| 触发入口 | HoloAI 对话 |
| 最终成功 | Matter 由 active 转为 completed，关联计划和任务保留可回看，Today 不再展示它 |

### 1.1 这个 Use Case 解决的不是“生成计划”

如果只生成一张看起来很全的清单，这个 Use Case 就失败了。

它要验证的是完整责任链：

```text
用户说出事情
→ Holo 理解这是一件持续事项
→ Holo 给出可一次接受的最小计划
→ 用户只确认一次
→ Holo 完整、原子化地建好计划
→ Holo 每次只告诉用户当下一步
→ 用户的完成和新信息自动回流
→ Holo 不要求用户重述背景
→ 整件事完成后正确退场
```

---

## 2. 全局不变量

以下规则比任何页面细节、代码复用或旧数据结构优先级更高。

### INV-01：用户只确认一次

无重复计划时，用户点“开始推进”后直接建立全部数据。

禁止再弹：

- 标题确认；
- 日期确认；
- 选择哪些任务；
- 是否加入 Matter；
- 是否加入清单。

### INV-02：点击前不得写业务数据

计划卡展示期间，只允许保存 ChatMessage / ContextPlan Draft。

不得创建：

- HoloMatter；
- TodoList；
- TodoTask；
- HoloMatterOpenLoop；
- HoloMatterLink；
- HoloMatterEvent。

### INV-03：点击后只能全部成功或全部失败

不得出现：

- 有 Matter 但没有清单；
- 有清单但只有部分任务；
- 任务已建但没有 MatterLink；
- UI 显示成功但实体不存在；
- 重试后产生重复实体。

### INV-04：执行计划必须有且只有一个主题清单

本 Use Case 必须创建或精确复用“国庆日本旅行”清单。

所有计划任务必须归入该清单，不得落入“全部”的无归属状态。

### INV-05：计划顺序必须被持久化

首发不执行 `dependencyEdges`，不建依赖图。

每个 `todoTask` 类型的 `HoloMatterLink` 必须保存：

```swift
planOrder: Int16
```

规则：

- 第一个计划任务为 0；
- 后续依次 +1；
- Matter 详情始终按 `planOrder` 展示；
- 下一步始终是 `planOrder` 最小的未完成、未删除、未归档任务；
- 不用标题匹配、创建时间或数组当前顺序猜测。

### INV-06：全 App 只有一个“当下一步”

同一 taskID 不得同时出现在：

- Today Primary Focus；
- Today Agenda；
- Today “正在推进”的下一步文案。

如果它是 Primary Focus：

- Agenda 排除该 taskID；
- “正在推进”只显示 Matter 名称和完成数，不再重复任务标题。

### INV-07：页面打开不依赖 LLM

Matter 详情和 Today 必须只读本地真实数据。

页面打开时不请求网络、不等待模型、不因 AI 失败而空白。

### INV-08：没有真实 entityID 就不得执行

所有打开、完成、更新、撤销都必须指向真实 ID。

禁止用任务标题做执行匹配。

### INV-09：对话中的状态更新只能来自用户明确表达

“可能买了”、“好像安排了”不得执行。

“机票已经买好了”可以更新为完成，但必须：

- 只操作当前 Matter 中的 linked taskID；
- 使用类型化 mutation；
- 给出原位回执；
- 允许撤销。

### INV-10：Matter 完成必须由用户亲手确认

即使所有任务均已完成，Holo 也只能显示“完成这件事”，不得自动改生命周期。

---

## 3. 前置条件

### 3.1 用户状态

- 用户已完成 Holo 基础启用；
- Core Data store 已 ready；
- HoloAI 对话可用；
- `matterStorageEnabled = true`；
- `matterUnifiedLaunchV2Enabled = true`；
- 当前没有标准化名称为“国庆日本旅行”的 active Matter；
- 当前没有同名 active TodoList；
- Today 当前没有更高优先级的日程或任务，便于验收 Matter Next Action 成为 Focus。

### 3.2 时间基线

- 当前日期：2026-09-21；
- 出发日期：2026-10-01；
- 返程日期：2026-10-07；
- 时区：Asia/Shanghai。

### 3.3 账号中允许存在的个人情境

可选存在：

- 用户的猫叫摩卡；
- 用户偏好减少频繁换酒店；
- 用户近期有 1 万元旅行预算。

如不存在，Holo 只用用户本轮输入，不得伪造个性化。

---

## 4. 固定验收输入

用户在 HoloAI 发送：

> 我 10 月 1 日到 7 日第一次去日本，想去东京和大阪。护照有，但签证、机票、酒店都还没弄。预算大概 1 万元，摩卡也要找人照顾。帮我整理一下要怎么准备。

该输入已足以形成计划，Holo 不得追问。

原因：

- 目标明确；
- 时间边界明确；
- 目的地范围明确；
- 当前进度明确；
- 家中约束明确；
- 剩余细节可在计划中逐步确认。

---

## 5. 标准计划输出

### 5.1 结构化 Draft 必须等价于

```text
goalSummary: 国庆日本旅行

answerText:
在出发前完成入境核实、行程分配、机票住宿、摩卡照顾和出行准备。

items:
0. 核实护照、签证与入境要求
1. 确定东京和大阪的停留天数
2. 预订往返机票
3. 安排东京与大阪之间的交通
4. 预订东京和大阪住宿
5. 确定摩卡的照顾安排
6. 准备支付、网络和出行资料

unknowns: []
dependencyEdges: []
```

### 5.2 为什么 `unknowns` 必须为空

“摩卡由谁照顾”已被表达为任务“确定摩卡的照顾安排”。

同一问题不得同时变成 Task 和 Open Loop，否则用户完成一次，系统还会显示“未解决”。

首发生成规则：

- 可以通过一个动作解决的问题 → Task；
- 只能等待外部结果、暂时不能行动的问题 → Open Loop；
- 二者不得重复。

### 5.3 不允许模型声称的事

在没有联网核验时，Holo 不得声称：

- 用户当前一定需要或不需要签证；
- 某项入境政策必然有效；
- 机票、酒店或汇率的实时情况；
- 1 万元预算一定足够。

所以第一条任务是“核实”，不是直接给出政策结论。

---

## 6. 主成功旅程

## S0：用户发送需求

### 用户看到

- 自己发送的原始消息；
- Holo 进入真实的规划运行态；
- 不出现假进度百分比。

### 系统必须做

1. 将该输入识别为 `contextual_planning`；
2. 保存用户 ChatMessage；
3. 创建 Context Plan run envelope；
4. 只读取允许读取的个人情境；
5. 将本轮用户明确输入作为最高优先级事实。

### 数据状态

| 对象 | 数量 |
|---|---:|
| User ChatMessage | 1 |
| Context Plan run | 1 |
| Matter | 0 |
| TodoList | 0 |
| TodoTask | 0 |

### 验收

- 用户消息只保存一次；
- 重进对话仍能恢复真实 run stage；
- 未进入计划卡前没有 Matter / Task 副作用。

---

## S1：Holo 展示计划卡

### 用户看到的完整主卡

```text
国庆日本旅行

在出发前完成入境核实、行程分配、机票住宿、摩卡照顾和出行准备。

○ 核实护照、签证与入境要求
○ 确定东京和大阪的停留天数
○ 预订往返机票
○ 安排东京与大阪之间的交通
○ 预订东京和大阪住宿
○ 确定摩卡的照顾安排
○ 准备支付、网络和出行资料

[开始推进]
调整计划
```

### 卡片行为

- 只有“开始推进”一个高强度按钮；
- “调整计划”是文字级次操作；
- “依据”收进更多菜单；
- 不显示单项“加入待办”；
- 不显示“全部加入”；
- 不显示行内日期选择；
- 不显示“开始整理 / 加入进行中的事”第二组操作。

### 数据状态

| 对象 | 数量 |
|---|---:|
| Assistant ContextPlan ChatMessage | 1 |
| HoloContextPlanDraft | 1 |
| Matter | 0 |
| TodoList | 0 |
| TodoTask | 0 |

### 验收

- 用户不了解 Matter 概念也能说出点击后会发生什么；
- 页面不超过两个可见操作；
- 退出 Chat 再进入，同一 Draft 仍可见；
- 用户未点击时，业务数据数量仍为 0。

---

## S2：用户点击“开始推进”

### 点击后立即反馈

- 按钮文案变为“正在建立计划…”；
- 按钮 disabled，防止连点；
- 不弹标题/日期表单；
- 不离开当前 Chat；
- 不先显示成功。

### 写入前必须校验

1. Draft 仍是当前 revision；
2. 个人情境 access generation 没有失效；
3. actionable items 为 1–7 条；
4. 条目 `itemID` 在 run 内唯一；
5. 没有同来源已完整 launch 的 Matter；
6. 没有需要用户选择的同名 active Matter。

### 性能要求

从点击到本地 receipt 返回，p95 小于 1 秒。

该阶段不请求 LLM，不需要联网。

---

## S3：系统原子化建立计划

### 单事务中必须完成

1. 创建 `HoloMatter M1`；
2. 创建 `TodoList L1`；
3. 创建 `TodoTask T1...T7`；
4. 创建 10 条 `HoloMatterLink`；
5. 创建 `activated` Event；
6. 建立确定性 Projection；
7. 一次 save；
8. 返回真实 receipt。

### Matter M1

| 字段 | 值 |
|---|---|
| title | 国庆日本旅行 |
| lifecycle | active |
| targetDate | 2026-10-01 |
| origin | contextPlan |
| originEntityID | 当前 Context Plan Message ID |

### TodoList L1

| 字段 | 值 |
|---|---|
| name | 国庆日本旅行 |
| archived | false |
| deletedAt | nil |

### Tasks

| ID | title | list | dueDate | completed | planOrder |
|---|---|---|---|---|---:|
| T1 | 核实护照、签证与入境要求 | L1 | nil | false | 0 |
| T2 | 确定东京和大阪的停留天数 | L1 | nil | false | 1 |
| T3 | 预订往返机票 | L1 | nil | false | 2 |
| T4 | 安排东京与大阪之间的交通 | L1 | nil | false | 3 |
| T5 | 预订东京和大阪住宿 | L1 | nil | false | 4 |
| T6 | 确定摩卡的照顾安排 | L1 | nil | false | 5 |
| T7 | 准备支付、网络和出行资料 | L1 | nil | false | 6 |

不允许把 Matter targetDate 复制到所有 Task dueDate。

### Links

| 关联 | entityType | role | 关键附加值 |
|---|---|---|---|
| M1 → Context Plan Message | contextPlan | origin | sourceRevision = draftRevision |
| M1 → User Message | chatMessage | conversation | 无 |
| M1 → L1 | todoList | action | 无 |
| M1 → T1 | todoTask | action | planOrder = 0 |
| M1 → T2 | todoTask | action | planOrder = 1 |
| M1 → T3 | todoTask | action | planOrder = 2 |
| M1 → T4 | todoTask | action | planOrder = 3 |
| M1 → T5 | todoTask | action | planOrder = 4 |
| M1 → T6 | todoTask | action | planOrder = 5 |
| M1 → T7 | todoTask | action | planOrder = 6 |

### Projection

```text
summary: 已建立 7 个准备步骤，尚未完成。
nextAction.kind: linkedTask
nextAction.entityID: T1
nextAction.title: 核实护照、签证与入境要求
sourceMatterRevision: M1.revision
```

### 成功回执

```text
matterID: M1
listID: L1
taskIDs: [T1, T2, T3, T4, T5, T6, T7]
createdTaskCount: 7
reusedTaskCount: 0
openLoopIDs: []
nextActionTaskID: T1
createdMatter: true
```

### 验收

- 业务对象数量与表格完全一致；
- T1...T7 全部挂在 L1；
- 7 个 task link 都有不同的 `planOrder`；
- Projection revision 与 Matter revision 一致；
- 无 Open Loop；
- 重复调用同一 request，所有实体数不增加。

---

## S4：原位显示成功回执

### 原卡片替换为

```text
已开始推进「国庆日本旅行」
已建立 7 个步骤

下一步
核实护照、签证与入境要求

[打开计划]
```

### 行为

- 原有“开始推进”消失；
- 不再显示“调整计划”，后续调整进 Matter Chat；
- “打开计划”使用 receipt.matterID；
- 不从标题重新查 Matter；
- 退出 Chat 再进入，通过 origin link 重建 launched 回执，不依赖临时 `@State`。

### 验收

- “打开计划”可用；
- 只打开 M1；
- 连续点击不创建副本；
- 冷启动后卡片仍是已启动状态。

---

## S5：用户打开计划详情

### 页面数据映射

| UI 区域 | 唯一数据源 |
|---|---|
| 标题 | `HoloMatter.title` |
| 目标日期 | `HoloMatter.targetDate` |
| 当前状态 | linked task 的 completed / total 确定性计算 |
| 下一步 | 最小 `planOrder` 的有效未完成 linked task |
| 计划列表 | role=action 的 todoTask links，按 `planOrder` |
| 待确认 | active Open Loops |
| 继续对话 | `matterID = M1` 的 Matter Chat Context |

### 用户看到

```text
国庆日本旅行
10 月 1 日出发

当前状态
0/7 已完成

下一步
核实护照、签证与入境要求
[打开任务]

计划
○ 核实护照、签证与入境要求
○ 确定东京和大阪的停留天数
○ 预订往返机票
○ 安排东京与大阪之间的交通
○ 预订东京和大阪住宿
○ 确定摩卡的照顾安排
○ 准备支付、网络和出行资料

[继续聊这件事]
```

### 交互

- 点击计划行的圆圈：完成该任务，底部显示可撤销提示；
- 点击计划行文字：打开真实 Task Detail；
- 点击“打开任务”：使用 nextAction.entityID 打开 T1；
- 点击“继续聊这件事”：进入 Matter Chat；
- 本页打开和刷新均不请求 LLM。

### 验收

- 列表顺序与 Draft 完全一致；
- 下一步是 T1；
- 详情不显示 phase、attention、projection revision 等内部词；
- 无 Open Loop 时，不显示空的“待确认”区块。

---

## S6：用户完成第一个任务

### 用户动作

用户在 Matter 计划列表中勾选 T1。

### 系统立即反馈

- T1 显示完成；
- 底部显示“已完成·撤销”；
- 当前状态变为 `1/7 已完成`；
- 下一步立即变为 T2；
- 更新不等待 LLM。

### 数据变化

| 对象 | 变化 |
|---|---|
| T1 | completed = true，completedAt 有值 |
| M1 | revision +1 |
| Projection | source revision 对齐 M1，nextAction.entityID = T2 |
| T2...T7 | 不变 |

### 撤销

如用户点“撤销”：

- T1 恢复未完成；
- 当前状态恢复 `0/7`；
- nextAction 恢复 T1；
- 不新建任务或 Matter。

### 验收

- 完成与撤销都能在本地即时完成；
- 下一步不出现短暂空白或旧值闪回；
- 重进页面后状态一致。

---

## S7：次日从 Today 继续

### 前置

- T1 已完成；
- T2...T7 未完成；
- 当日没有更高优先级的进行中日程、即将开始日程、逾期高优先级任务。

### Today 必须显示

#### Primary Focus

```text
现在最值得做
确定东京和大阪的停留天数
来自：国庆日本旅行
```

#### Agenda

- 不得再出现 T2；
- 其他今日任务/日程正常显示。

#### 正在推进

```text
国庆日本旅行    1/7
10 月 1 日出发
```

该行不得再显示 T2 标题。

### 验收

- 整个 Today 只出现一次 T2 文案；
- 点击 Focus 打开 T2；
- 点击“国庆日本旅行”行打开 M1；
- 断网时 Today 仍正常打开。

---

## S8：用户无需重述背景地更新进展

### 用户入口

用户从 M1 详情点击「继续聊这件事」。

Chat 输入框上方显示上下文胶囊（2026-09-23 东林拍板：与目标规划横幅等既有提示统一位置，不再单独占顶部）：

```text
正在聊：国庆日本旅行
```

### 生成回答前必须注入的最小快照

- matterID = M1；
- title；
- targetDate；
- revision；
- T1...T7 的真实 ID、标题和完成状态；
- planOrder；
- active Open Loops；
- 当前 nextAction.entityID；
- 不注入不相关的全量个人数据。

### 用户发送

> 东京 4 天、大阪 3 天定了，机票也买好了，摩卡我妈会来照顾。

用户不需要说“我在规划日本旅行”。

### Holo 可以执行的类型化更新

| 用户明确表达 | 实体操作 |
|---|---|
| 东京 4 天、大阪 3 天定了 | 完成 T2 |
| 机票买好了 | 完成 T3 |
| 摩卡我妈来照顾 | 完成 T6 |

执行器必须使用 T2 / T3 / T6 的真实 ID，不做二次标题搜索。

### Holo 回复

```text
已更新「国庆日本旅行」：
· 东京和大阪的停留天数已确定
· 往返机票已完成
· 摩卡照顾已安排

下一步：安排东京与大阪之间的交通。

[撤销本次更新]
```

### 更新后数据

| 任务 | 状态 |
|---|---|
| T1 | completed |
| T2 | completed |
| T3 | completed |
| T4 | open |
| T5 | open |
| T6 | completed |
| T7 | open |

```text
progress: 4/7
nextAction.entityID: T4
```

### 撤销

点击“撤销本次更新”必须将 T2 / T3 / T6 一次恢复到更新前状态，不影响 T1。

### 验收

- Holo 没有追问“你在说哪次旅行”；
- 回复中没有声称更新未成功的项；
- 更新回执和数据完全一致；
- 下一步为 T4；
- 冷启动后状态不丢失。

---

## S9：所有计划任务完成

### 前置

T1...T7 全部 completed，active Open Loops 为 0。

### Matter 详情显示

```text
国庆日本旅行

准备已完成
7/7 已完成

[完成这件事]
```

不再显示虚假 next action。

### Today

在用户尚未完成 Matter 前：

- M1 仍可出现在“正在推进”；
- 显示 `7/7 · 可完成`；
- 不再为 M1 生成 Primary Focus；
- 已完成 T1...T7 不进 Agenda。

### 验收

- 没有 next action 时页面不出现“还没有明确下一步”这类错误空态；
- 系统不自动完成 M1；
- 用户能明确看出现在只剩“收尾完成”。

---

## S10：用户完成 Matter

### 用户动作

用户点击“完成这件事”。

系统显示最后一次生命周期确认：

```text
完成「国庆日本旅行」？
计划和完成记录会保留，之后仍可回看。

[确认完成]
取消
```

### 数据变化

| 对象 | 变化 |
|---|---|
| M1.lifecycle | completed |
| M1.completedAt | 当前时间 |
| Event | 追加 completed，actor=user |
| L1 | 保留 |
| T1...T7 | 保留 completed |
| Links | 保留 |
| Chat | 保留 |

### Today 变化

- M1 从“正在推进”消失；
- M1 不再参与 Focus Resolver；
- T1...T7 不进 Agenda；
- 如果没有其他 active Matter，整个“正在推进”区块隐藏；
- 不显示 Matter 空状态卡。

### 历史回看

用户在“正在推进 → 已完成”中可找到 M1，打开后可查看：

- 标题和日期；
- 7 条已完成任务；
- 历史对话；
- 重新打开入口。

### 验收

- 完成不删除数据；
- 冷启动后仍为 completed；
- 另一设备 CloudKit 同步后生命周期、清单、任务和 links 一致；
- 重新打开时使用同一 M1，不复制数据。

---

## 7. 派生状态机

这是用户体验状态，不是要新增一个 Core Data lifecycle enum。

| 状态 | 真实数据条件 | 用户主操作 | 下一状态 |
|---|---|---|---|
| draftReady | 只有 Draft，无 Matter | 开始推进 | launching |
| launching | 本地事务执行中 | 无，防连点 | active |
| active | active Matter 且有未完成 linked task | 完成 next action / 继续聊 | active / readyToComplete |
| waiting | active Matter，无可行动任务，但有 active Open Loop | 继续聊并解决待确认 | active / readyToComplete |
| readyToComplete | 无未完成 linked task，无 active Open Loop | 完成这件事 | completed |
| completed | lifecycle = completed | 重新打开 | active |
| archived | lifecycle = archived | 重新打开 | active |

不存在“部分启动”用户状态。

如本地写入中断，恢复时只能解析为：

- draftReady：未保存成功；
- active：事务已完整保存。

---

## 8. 替代与异常分支

## A1：输入不符合 Matter 资格

### 输入

> 明天提醒我买牛奶。

### 结果

- 直接进建任务流程；
- 不生成 Context Plan 卡；
- 不出现“开始推进”；
- 不创建 Matter。

---

## A2：缺少会改变整份计划的关键信息

### 输入

> 帮我准备一次出国旅行。

### Holo 行为

只问一条组合问题：

> 你准备去哪里，大概什么时候出发？

用户回答前：

- 不生成计划卡；
- 不创建 Matter / List / Task。

---

## A3：用户在启动前调整计划

用户点“调整计划”，输入：

> 不去大阪了，只去东京。

系统：

1. 在同一 run 中生成 draftRevision +1；
2. 旧 Draft 不再可启动；
3. 新卡删除大阪停留、城市间交通和大阪住宿内容；
4. 所有业务对象仍为 0；
5. 用户点新 Draft 的“开始推进”后才创建数据。

---

## A4：存在同名 active Matter

在点击“开始推进”前检测到同名 active Matter，弹出：

```text
你已有一个「国庆日本旅行」

[打开已有计划]
另建一个
取消
```

### 打开已有计划

- 不将当前 Draft 自动合并进旧 Matter；
- 不创建新任务；
- 直接打开已有 Matter；
- 如需整合新内容，用户在已有 Matter Chat 中继续。

### 另建一个

必须先生成唯一名称：

```text
Matter.title: 国庆日本旅行 2
TodoList.name: 国庆日本旅行 2
```

或当年份/目标日期可明确区分时：

```text
2027 国庆日本旅行
```

另建分支必须绕过清单模糊复用，不得再将新任务放入旧同名清单。

---

## A5：本地原子启动失败

任意步骤失败时：

- transaction rollback；
- 卡片恢复 draftReady；
- 主按钮恢复“重试开始推进”；
- 显示：“这次没有建立成功，也没有创建部分内容。”

验收必须读数据库确认：

- Matter = 0；
- List = 0；
- Tasks = 0；
- Links = 0；
- Events = 0。

---

## A6：启动过程杀进程

冷启动恢复只允许两种结果：

### 事务未保存

- 保留 Draft；
- 不存在 Matter / List / Task；
- 卡片显示“开始推进”。

### 事务已保存

- 数据完整存在；
- 根据 origin link 恢复 receipt；
- 卡片显示“已开始推进”；
- 重试不创建副本。

不存在“继续完成剩余 3 个实体”的临时 UI。

---

## A7：Draft 使用的个人情境已被修改或忘记

点击时 access generation / draft revision 失效：

- 不启动旧 Draft；
- 显示“你的情况已有变化，我需要重新整理这份计划。”；
- 主操作为“重新整理”；
- 不创建任何业务数据。

---

## A8：规划生成时断网

如 Draft 还未生成：

- 显示真实失败；
- 允许重试；
- 不创建 Matter。

如 Draft 已经完整保存，之后断网：

- “开始推进”仍可用；
- 本地 Matter / List / Tasks 照常创建；
- CloudKit 等网络恢复后再同步。

---

## A9：关联任务被删除

用户将 T4 移入回收站后：

- T4 不再候选 next action；
- nextAction 变为 T5；
- Matter 详情显示一条轻提示：“1 个计划项已移入回收站”；
- 不自动重建 T4；
- 用户恢复 T4 后，仍使用原 link 和 planOrder。

---

## A10：Projection stale 或损坏

Matter 详情和 Today 不得显示旧 next action。

本地立即按真实 linked tasks + planOrder 重建确定性 projection。

如仍无法重建：

- 详情仍显示真实计划任务；
- 隐藏 next action；
- 不显示旧 AI 结论；
- 不影响用户手动完成任务。

---

## A11：用户重新打开已完成 Matter

用户点“重新打开”后：

- lifecycle 变为 active；
- completedAt 清空；
- 已完成 Tasks 不自动变为未完成；
- 如全部 Tasks 仍完成，详情处于 readyToComplete；
- 用户可通过 Matter Chat 新增后续任务，新任务 planOrder 接在末尾；
- 不创建新 Matter。

---

## A12：CloudKit 在另一设备导入数据

另一设备同步完成后必须满足：

- 同一 origin 只有一个 M1；
- 同一 aiSourceMessageId + itemID 只有一个 active Task；
- L1 不产生两个可见副本；
- task links 的 planOrder 不丢失；
- 另一设备查看到的 next action 与主设备一致；
- 如存在冲突副本，先在确定性 repair 层折叠，不让 UI 同时展示。

---

## 9. 明确禁止的实现

以下任意一项出现，Use Case 直接判定失败：

- 规划卡同时存在“加入待办”、“全部加入”、“开始整理”；
- 用户点完主 CTA 后又要填标题或日期；
- 规划任务有一条不在主题清单；
- Matter 详情任务顺序在冷启动或同步后变化；
- next action 由不同页面自己推断；
- 用任务标题反查真实任务；
- 一个问题同时作为 Task 和 Open Loop；
- 有部分数据落库时 UI 还显示成功；
- 重试产生第二个 Matter 或重复任务；
- Today 同屏显示两次同一 next action；
- Matter 完成后仍留在 Today active 区域；
- 页面打开必须等 LLM；
- 用户在 Matter Chat 中需要重新说明在讨论哪件事；
- Holo 声称更新成功，但实体状态没改；
- 所有任务完成后系统自动完成 Matter。

---

## 10. 可直接转为测试的验收清单

### 生成前

- [ ] 固定输入不追问。
- [ ] 没有虚构签证、入境、价格或预算结论。
- [ ] Draft 为 7 个 actionable items。
- [ ] `unknowns = []`。
- [ ] `dependencyEdges = []`。

### 卡片

- [ ] 只有一个主 CTA。
- [ ] 主 CTA 文案为“开始推进”。
- [ ] 不存在单项加入。
- [ ] 不存在批量加入。
- [ ] 不存在第二次 Matter 激活。
- [ ] 点击前业务数据为 0。

### 原子启动

- [ ] 点击一次创建 1 Matter。
- [ ] 创建 1 个“国庆日本旅行”清单。
- [ ] 创建 7 个任务。
- [ ] 7 个任务全部在该清单。
- [ ] 创建 10 个 links。
- [ ] task links 持久化 0...6 的 planOrder。
- [ ] nextActionTaskID = T1。
- [ ] 失败注入时全部回滚。
- [ ] 重试实体数不增加。

### 详情

- [ ] 计划顺序与 Draft 一致。
- [ ] 0/7 进度正确。
- [ ] 下一步为 T1。
- [ ] 无 Open Loop 时不显示空区块。
- [ ] 页面打开不请求网络。

### 推进

- [ ] 完成 T1 后进度为 1/7。
- [ ] 完成 T1 后 next action = T2。
- [ ] 撤销后恢复 T1。
- [ ] Today 只出现一次 T2。
- [ ] 断网时 Today 和 Matter 详情可打开。

### Matter Chat

- [ ] 不需要重述背景。
- [ ] 生成前注入 M1 快照。
- [ ] 只通过真实 ID 完成 T2 / T3 / T6。
- [ ] 回执与真实数据一致。
- [ ] 撤销仅恢复本次更新。
- [ ] next action = T4。

### 完成

- [ ] T1...T7 完成后不生成假 next action。
- [ ] Matter 不自动完成。
- [ ] 用户确认后 lifecycle = completed。
- [ ] Today 完全移除 M1。
- [ ] 历史中可回看。
- [ ] 重新打开不复制 Matter。

### 恢复与同步

- [ ] 启动中杀进程只有“全无”或“全有”两种数据结果。
- [ ] 冷启动恢复正确卡片状态。
- [ ] 双设备同步后 Matter / List / Tasks / Links 一致。
- [ ] planOrder 不丢失。
- [ ] 无可见重复 Matter、List 或 Task。

---

## 11. Gherkin 主场景

```gherkin
Feature: Holo 持续推进一次国庆日本旅行

  Scenario: 用户从规划到完成整件事
    Given 当前日期为 2026-09-21
      And 用户没有同名 active Matter 和 TodoList
      And Matter V2 功能已开启
    When 用户说明 10 月 1 日到 7 日去东京和大阪的准备情况
    Then Holo 不追问
      And Holo 展示包含 7 个行动项的计划卡
      And 卡片只有一个“开始推进”主操作
      And 此时不存在 Matter List Task

    When 用户点击“开始推进”
    Then 系统原子化创建 1 个 Matter
      And 创建 1 个“国庆日本旅行”清单
      And 创建 7 个全部归属该清单的任务
      And 任务关联保存 0 到 6 的 planOrder
      And 下一步指向第 1 个任务的真实 ID

    When 用户完成第 1 个任务
    Then 进度变为 1/7
      And 下一步指向第 2 个任务
      And Today 只显示一次该下一步

    When 用户从 Matter 继续对话并明确告知停留天数 机票 摩卡照顾已完成
    Then Holo 无需用户重述旅行背景
      And Holo 使用真实 ID 完成对应 3 个任务
      And 显示可撤销的更新回执
      And 下一步指向第 4 个任务

    When 所有 7 个任务已完成
    Then Holo 显示“完成这件事”
      And Holo 不自动完成 Matter

    When 用户确认完成
    Then Matter 生命周期变为 completed
      And Today 不再展示该 Matter 和关联任务
      And 用户仍可在已完成历史中回看全部计划与对话
```

---

## 12. Use Case 通过门槛

必须同时满足：

1. 主旅程 S0–S10 全部通过；
2. A1–A12 全部有对应测试或真机证据；
3. 数据不变量 INV-01–INV-10 无违反；
4. 主旅程使用真实 Context Plan，不使用 DemoSeed；
5. 本地数据库抽查与 UI 结果一致；
6. 冷启动、杀进程、断网和双设备均验证；
7. Prompt 更改已双端同步并完成后端发版；
8. 东林本人用这条旅程管理真实事项时，不需要另建清单、手工搬任务或重述背景。

只要第 8 条不满足，就不允许对外宣传 Matter。
