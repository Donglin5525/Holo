# Holo Matter 战略收敛与首发重构完整实施方案

> 日期：2026-09-21
>
> 状态：实施方案，未修改业务代码，未经构建、真机、CloudKit 或生产验证
>
> 首发纵向场景：日本旅行
>
> 本方案覆盖并取代旧 Matter / Today 方案中与首发交互冲突的部分，保留已有的数据底座。
>
> 唯一可执行验收契约：[`UC-MATTER-001-国庆日本旅行从规划到完成完整用户UseCase.md`](./UC-MATTER-001-国庆日本旅行从规划到完成完整用户UseCase.md)

---

## 0. 先说结论

Matter 现在不该继续“补功能”，而应该停止向用户暴露内部结构。

它的唯一职责是：

> 当用户有一件需要跨多天、多步骤推进的事，Holo 接下“持续记住、判断现状、给出下一步”的责任。

用户不需要理解 Matter，也不需要管理规划草案、清单、Open Loop、Projection 之间的关系。用户只应该看到四件事：

1. 这件事最后要变成什么；
2. 现在到了哪里；
3. 还有什么没定；
4. 当下只要做什么。

首发版不做一个“强大的 Matter 系统”，只做一条用户真的愿意用的闭环：

```text
说出一件持续事项
  → Holo 整理成简洁计划
  → 用户只确认一次“开始推进”
  → Holo 原子化建立计划与任务
  → Today 只告诉用户当下一步
  → 完成或新信息自动回流
  → 无需重述背景，继续推进
```

### 0.1 现在最不该做的事

- 不要单独修 `creations.count >= 2` 的清单归组 bug；新主流将退役这条旧链路。
- 不要继续给 `ContextPlanChatCard` 加按钮、状态或解释。
- 不要先做外部内容联想、主动提醒、联网搜索、自动聚类。
- 不要用新 Core Data 实体存另一份“计划步骤”；执行计划直接复用 TodoList + TodoTask。
- 不要通过更长 Prompt 提升看起来的智能度；当前缺的是责任闭环，不是更多文字。

---

## 1. 产品宪法

### 1.1 五个对象的唯一分工

| 对象 | 它只负责什么 | 它不负责什么 |
|---|---|---|
| Memory | 我是谁、发生过什么、稳定偏好 | 不管一件事的执行状态 |
| Goal | 长期想变成什么 | 不管短期事件的每日推进 |
| Matter | 一件有起止、会变化、需持续跟进的事 | 不成为文件夹、清单或项目管理界面 |
| Task | 一个可完成的原子行动 | 不承担整件事的背景 |
| Chat | 一次理解、决策或修正 | 不是跨时间真相源 |

判定示例：

- “提升日语”是 Goal。
- “准备 12 月的日语考试”是 Matter。
- “今晚做一套听力题”是 Task。
- “旅行时喜欢少换酒店”是 Memory。

### 1.2 Matter 的三条资格线

只有同时满足以下条件，才建立 Matter：

1. 预计跨越一天；
2. 至少有两个独立行动或一个待决策问题；
3. 未来的新信息、完成状态或时间变化会影响下一步。

不满足时的去向：

- 一次性行动 → 直接建 Task；
- 纯查询或建议 → 直接回答；
- 长期模糊愿望 → 进 Goal 共创；
- 每日/每周重复 → Habit；
- 单纯收藏资料 → Thought / Memory。

### 1.3 Holo 对用户的四个承诺

- 不用重复解释背景。
- 一次确认后，整件事的容器与行动一次建好。
- 每个时刻最多给一个主下一步。
- 事情变了，Holo 更新路线，而不是让用户重做整个计划。

---

## 2. 首发范围

### 2.1 只做五类事

- 旅行准备；
- 搬家；
- 考试/证书准备；
- 求职/面试；
- 有日期的发布、活动或交付。

这五类共同特征是：边界清楚、跨日、多步骤、有忘记成本、有明显完成状态。

### 2.2 首发明确不做

- 宏大人生目标、无截止期自我成长；
- 复杂团队项目管理；
- 甘特图、进度百分比、多人协作；
- 自动从所有聊天和记录中创建 Matter；
- 主动通知、联网搜索、无限外部关联；
- 用 AI 自动完成、归档或删除 Matter。

### 2.3 用户侧命名

`Matter` 仅保留在代码和数据层。用户侧统一用：

- 列表/入口：“正在推进”；
- 卡片主按钮：“开始推进”；
- 详情：直接显示事项名，不显示“Matter 详情”；
- 对话：“继续聊这件事”；
- 用户看得见的执行容器：“计划”。

---

## 3. 唯一主旅程

### 3.1 用户输入

> “我 10 月 1 日到 7 日第一次去日本，想去东京和大阪。护照有，但签证、机票、酒店都还没弄。预算大概 1 万元，摩卡也要找人照顾。帮我整理一下要怎么准备。”

### 3.2 Holo 最多追问一个问题

只有当缺失信息会改变大部分计划时才追问，例如“是第一次出国，还是已经有签证？”。

以下问题不得在首轮阻断：

- 住哪家酒店；
- 每天去哪个景点；
- 换多少日元；
- 某个细节是否已决定。

这些应进入“待确认”，不应让用户在创建前完成调查问卷。

### 3.3 Holo 返回一张简化计划卡

首屏只显示：

```text
国庆日本旅行
在出发前把入境、行程、交通、住宿和摩卡照顾安排好。

计划
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

交互不可妥协规则：

- 不在每个条目下显示“加入待办”；
- 不同时提供“单项加入”和“全部加入”；
- 不在卡片内让用户给每条任务选日期；
- 不继续显示“已安排好 / 本次不用 / 情况变了”三选项；
- 不再额外显示“继续整理这件事”的第二次激活入口；
- 依据、个性化变化、覆盖范围只进“更多”，不参与主决策。

### 3.4 点击“开始推进”

无重复候选时，不弹第二个确认表单，直接执行。

仅当已有同名 active Matter 时，出现一次最小歧义确认：

> “你已有一个「国庆日本旅行」，继续它还是另建一个？”

默认主操作是“继续已有计划”，次操作是“另建”。

### 3.5 成功回执

```text
已开始推进「国庆日本旅行」
已建立 7 个步骤
下一步：核实护照、签证与入境要求

[打开计划]
```

卡片不再保留原有多组加入按钮和状态。

### 3.6 持续推进

- 用户完成一条任务后，Matter 投影失效并重算下一步。
- 用户在 Matter Chat 说“机票已经买了，改成去大阪”，Holo 使用当前 Matter 快照理解，提出更新，确认后修改。
- 用户不需要重述“我在做日本旅行规划”。
- 全部关联任务完成且没有未解决问题时，Holo 只建议完成 Matter，不自动完成。

---

## 4. 信息架构重构

### 4.1 规划卡

主层只保留：

1. 标题；
2. 结果句；
3. 3–7 个行动项；
4. 待确认数量，最多显示一条；
5. 一个主 CTA。

二级内容：

- 调整计划；
- 查看依据；
- 查看“因你的情况调整了什么”。

这些二级内容默认折叠，不能挤压主路径。

### 4.2 详情页

当前详情同时显示阶段、Holo 判断、下一步、Open Loop、已解决、相关内容、最近变化。首发改成：

```text
日本旅行                  …
10 月 1 日前准备好

当前状态
已建好行程框架，入境准备还没确认。

下一步
确认护照有效期和签证要求
[打开任务]

计划  2/5
✓ 确定旅行日期
✓ 确定城市顺序
○ 确认入境要求
○ 预订机票与住宿
○ 处理猫咪照顾

待确认 1
· 猫咪由谁照顾

[继续聊这件事]
```

默认不显示：

- 内部 phase 标签；
- attention 分类名；
- “AI 猜测”统计；
- 证据链路；
- 事件流；
- 投影更新状态。

这些放入“更多 / 历史与依据”，只在用户主动查看时展开。

### 4.3 Today

Today 的任务是“压缩注意力”，不是把所有模块再展示一次。

单列顺序改为：

1. 现在最值得做（最多一件）；
2. 今天的安排（排除焦点中的同一任务）；
3. 正在推进（最多两个紧凑行，无 active 时整块隐藏）；
4. 保持状态；
5. 概况。

去掉：

- Today 里的大型 Matter 空状态；
- “开始一件事”的虚线框；
- 同一 linked task 同时出现在 Primary Focus、Matter 卡和 Agenda；
- Matter 卡里与 Focus 完全相同的“下一步”。

“正在推进”行只展示：标题、已完成/全部任务数、近期截止提示。点击进详情。

### 4.4 列表页

- 页面名从“进行中的事”改为“正在推进”。
- 默认只展示 active。
- “已完成 / 已归档”收进右上角筛选，不在主列表同屏堆三组。
- 右上角 `+` 不直接建空 Matter，打开 Holo 并展示提示“你想推进什么？”。

---

## 5. 数据与原子执行契约

### 5.1 不新建“计划步骤”实体

首发真相源：

- `HoloMatter`：持续事项的标题、目标日期、生命周期；
- `TodoList`：用户可见的执行计划容器；
- `TodoTask`：可完成的计划步骤；
- `HoloMatterOpenLoop`：还没有答案的问题；
- `HoloMatterLink`：把 Matter 与规划、对话、清单、任务连起来；
- `HoloMatterEvent`：记录用户确认和系统变化。

### 5.2 新增链接类型与持久化顺序

`HoloMatterLinkEntityType` 新增：

```swift
case todoList
```

并加入首发可写白名单。Matter 详情优先通过该 link 查找计划清单；老数据没有 `todoList` link 时，从 linked task 的 `list` 反查并可选补链。

`HoloMatterLink` 新增非可选字段：

```swift
@NSManaged var planOrder: Int16
```

数据规则：

- 默认值为 `-1`，保证旧数据轻量迁移和 CloudKit schema 兼容；
- 仅 `entityType = todoTask && role = action` 时使用 `0...N-1`；
- 其他 link 必须保持 `-1`；
- 计划展示、下一步选择、重试修复都以 `planOrder` 为准，不依赖 Core Data 返回顺序、创建时间或标题匹配。

### 5.3 唯一写入请求

```swift
nonisolated struct HoloMatterPlanLaunchRequest: Sendable {
    let contextPlanMessageID: UUID
    let userMessageID: UUID?
    let draft: HoloContextPlanDraft
    let confirmedTitle: String
    let targetDate: Date?
    let existingMatterID: UUID?
}
```

不接收 `selectedItemIDs`。用户点“开始推进”就是确认整份计划，所有 `task` / `checklistItem` 一次创建。`adjustment` / `information` 不创建任务。

约束：

- actionable items 为 1–7 条；
- unknowns 最多 2 条；
- 无可执行项时不允许启动，卡片改为纯建议回答；
- 不根据 `relativeTiming` 擅自写具体日期；
- 只保存用户明确确认的 `confirmedDate`；
- 不默认把日期设为今天。

### 5.4 唯一成功回执

```swift
nonisolated struct HoloMatterPlanLaunchReceipt: Sendable, Equatable {
    let matterID: UUID
    let listID: UUID
    let taskIDs: [UUID]
    let createdTaskCount: Int
    let reusedTaskCount: Int
    let openLoopIDs: [UUID]
    let nextActionTaskID: UUID?
    let createdMatter: Bool
}
```

UI 只能以这个回执展示成功。“请求发出”、“本地临时状态已改”都不算成功。

### 5.5 单事务执行顺序

新增 `HoloMatterRepository.launchPlan(request:)`，是这条链路的唯一写入入口。

执行必须在 `CoreDataStack.shared.performBackgroundTask` 创建的独立上下文中完成，且只 `save()` 一次：

1. 用 `contextPlanMessageID` 查 origin link，命中则进入幂等修复，不新建；
2. 标准化 `confirmedTitle`，得到清单名；
3. 用 `TodoListNameResolver` 精确匹配，未命中才新建清单；
4. 创建或取得 Matter；
5. 按 `aiSourceMessageId + aiSourceItemId` 幂等创建所有行动任务，创建时直接挂到主题清单；
6. 创建 unknown 对应的 suggested Open Loop；
7. 创建 contextPlan、chatMessage、todoList、todoTask links，task links 按 Draft 顺序写入 `planOrder`；
8. 选出 `planOrder` 最小的有效未完成 linked task，写入确定性 next action projection；
9. 追加一个 `activated` event，payload 只记录数量和 ID，不重复存用户文本；
10. 一次 `context.save()`；
11. 任一步失败就 `context.rollback()` 并抛错，不留空 Matter、孤儿清单或部分任务；
12. 保存成功后回到 MainActor，刷新 Todo / Matter 观察者并发出回执。

`CoreDataStack.performBackgroundTask` 当前不会自动 save，新链路必须在 block 内明确 `save()`，不能依赖注释或假设。

### 5.6 下一步确定性规则

1. 候选只能是 `role = action` 的 linked task；
2. 已完成、已删除、已归档任务排除；
3. 在候选中取 `planOrder` 最小者；
4. `planOrder` 相同属于数据异常，以 `createdAt + id` 稳定打破平局并记录诊断，不自动改写用户数据；
5. 无候选 task 但有 active Open Loop 时，显示“还需要确认一件事”；
6. 无候选 task 且无 active Open Loop 时，进入 `readyToComplete`，不生成假下一步。

首发不执行 `dependencyEdges`。原因不是依赖不重要，而是当前没有可靠的依赖持久化契约；在没有持久化、编辑、同步和故障恢复闭环前，不允许用临时 Draft 假装支持依赖图。

### 5.7 幂等与修复

同一 `contextPlanMessageID` 重复点击时：

- 返回同一 matterID / listID；
- 按条目来源键补齐缺失任务；
- 补齐缺失 links；
- 不重复创建已存在任务；
- 修复完成后返回 receipt；
- 不依赖 UserDefaults 回执成为真相源，回执只用于展示加速。

---

## 6. Prompt 与生成契约

### 6.1 新 Prompt 目标

Prompt 不是让模型“考虑更全”，而是限制它只产出可以被用户一次接受的最小计划。

必须新增规则：

- `goalSummary` 是 4–16 个字的事项名，不带“帮我/计划/安排一下”；
- `answerText` 最多 80 个中文字，只描述目标状态；
- actionable items 必须 3–7 条，每条是可完成的动作；
- 不把知识说明、注意事项、理由冒充任务；
- unknowns 最多 2 条，只保留会改变路线的问题；
- 不为没有锚点的相对时间伪造日期；
- 不输出重复或包含关系的任务；
- `dependencyEdges` 首发固定输出空数组；
- 同一件事不得同时输出为 actionable item 和 unknown；
- 用户已能直接行动的内容进 item，只能等待外部结果且暂时无法行动的问题才进 unknown；
- 如果不符合 Matter 资格线，返回纯建议而不制造多步计划。

### 6.2 不升级 Draft schema

首发继续使用 `HoloContextPlanDraft.schemaVersion = 1`。当前字段已足够，改变是语义收缩和展示收缩，不是数据格式换代。

### 6.3 双端同步

修改 Prompt 时必须同一个 commit 完成：

1. 在 `PromptManager.swift` 的 Debug / Release 两套 `PromptType` 中新增 `.personalContextPlanning`；
2. 在 iOS 内嵌后备模板中放入同语义契约；
3. `promptVersions` 设为 2；
4. 修改 `HoloBackend/src/prompts/defaultPrompts.json`；
5. `HoloBackend/src/prompts/promptRegistry.js` 中 `personal_context_planning` 从 1 升到 2；
6. 增加 10 条固定 fixture，检查条数、可执行性、标题凝练和非 Matter 降级；
7. 本地通过后部署后端；
8. 用 `/v1/prompts/meta` 核对生产版本与 source digest；
9. 跑一次真实 `personal_context_planning` 请求，不得用 health 或 JSON 合法代替。

`HoloBackend/` 改动不部署就不会在生产生效。

---

## 7. 代码改动范围

### 7.1 新增文件

| 文件 | 职责 |
|---|---|
| `Holo/Holo APP/Holo/Holo/Models/AI/HoloMatterPlanLaunchModels.swift` | request / receipt / error 契约 |
| `Holo/Holo APP/Holo/Holo/Services/AI/Matter/HoloMatterPlanLaunchTransaction.swift` | 在注入 context 内组装清单、任务、Matter、Link、Projection，不自行 save |
| `Holo/Holo APP/Holo/Holo/Services/AI/Matter/HoloMatterPlanLaunchCoordinator.swift` | UI 唯一入口，预检重复、调用 repository、刷新观察者 |
| `Holo/Holo APP/Holo/Holo/Services/Diagnostics/MatterJourneyMetricsStore.swift` | 无 PII 本地旅程指标，Debug 可导出 |
| `Holo/Holo APP/Holo/HoloTests/Services/Matter/HoloMatterPlanLaunchTests.swift` | 原子创建、幂等、回滚、旧数据补链 |
| `Holo/Holo APP/Holo/HoloTests/Views/Chat/ContextPlanPrimaryActionTests.swift` | 卡片只有一个主动作的纯状态测试 |
| `Holo/Holo APP/Holo/HoloTests/Views/Today/HoloTodayDeduplicationTests.swift` | Focus / Agenda / 正在推进去重 |

### 7.2 修改文件

| 文件 | 必做改动 |
|---|---|
| `Data/Repositories/HoloMatterRepository.swift` | 新增 `launchPlan(request:)`，用背景 context 单次保存，失败 rollback |
| `Models/CoreDataStack+MatterEntities.swift` | `HoloMatterLink` 增加非可选 `planOrder`，默认 `-1` |
| `Models/HoloMatterLink+CoreDataClass.swift` | 增加 `@NSManaged planOrder: Int16` |
| `Models/HoloMatterVocabulary.swift` | 新增 `todoList` link 类型和幂等键 |
| `Models/TodoRepository.swift` | 新增外部事务提交后的统一 refresh；旧 `createContextPlanTask` 保留兼容但不再是 V2 主路径 |
| `Views/Chat/Cards/ContextPlanChatCard.swift` | 删掉单项/批量保存、行内日期、纠正三选项、独立 Matter 激活段；改为一个 primary CTA |
| `Views/Chat/MessageBubbleView.swift` | 删除 UI 内的任务创建编排；传入 launch 闭包和 `onOpenMatter` |
| `Views/Chat/ChatView.swift` | 确保成功回执能打开详情，Matter Chat 上下文不丢失 |
| `Views/Matter/MatterDetailView.swift` | 改为状态→下一步→计划→待确认→继续对话 |
| `Views/Matter/MatterListView.swift` | 改名“正在推进”，主列表只显示 active，历史状态收进筛选 |
| `Services/Today/HoloTodaySnapshotBuilder.swift` | 建立 displayedTaskIDs，在返回前排除 Focus 已占用的 agenda task，计算 Matter 任务进度 |
| `Views/DailyKanban/DailyKanbanView.swift` | 调整顺序，将“正在推进”放到 Agenda 后 |
| `Views/DailyKanban/TodayMatterSection.swift` | 删除大卡、空状态和开始入口；最多两个紧凑行 |
| `Services/HoloMatterRolloutPolicy.swift` | 新增 `matterUnifiedLaunchV2Enabled`，不与 storage 关闭绑死 |
| `Services/AI/PromptManager.swift` | 增加双构建后备 Prompt 类型、内容和 v2 |
| `HoloBackend/src/prompts/defaultPrompts.json` | 收缩 `personal_context_planning` 输出契约 |
| `HoloBackend/src/prompts/promptRegistry.js` | 版本升到 2 |
| `Localizable.xcstrings` | 新增统一用户文案，旧文案不再被 V2 路径引用 |

### 7.3 退役但暂不删除

为了可回退，首个版本暂时保留：

- `HoloMatterActivationCoordinator`；
- `ContextPlanUserDefaultsReceipts` 旧单项回执；
- `createContextPlanTask`；
- 旧卡片交互分支。

但它们必须被 `matterUnifiedLaunchV2Enabled` 隔离，新流程不得再经过。内部试用结束后的下一个版本再删除。

---

## 8. 实施阶段

### R0：静态样机与红线测试（0.5–1 天）

目标：先验证“愿不愿意用”，不先改数据层。

交付：

- 一个固定日本旅行数据的简化规划卡；
- 一个固定数据的新详情页；
- 一个去重后的 Today 示意；
- 将旧卡片与新卡片同屏对照。

通过门槛：

- 东林能在 5 秒内说出主操作是什么；
- 不需要解释 Matter 和 TodoList 的关系；
- 卡片上只有一个高强度 CTA；
- 如果看完仍不愿用它管理真实旅行，停止后续开发，继续收缩产品契约。

### R1：原子启动底座（2 天）

先写 RED 测试，再实现。

必须通过：

1. 国庆日本旅行 7 条 actionable items 一次创建 1 Matter + 1 List + 7 Tasks + 10 Links；
2. 所有 Tasks 的 `listID` 都是日本旅行清单；
3. 7 个 task links 的 `planOrder` 为 0...6，冷启动后顺序不变；
4. 重复调用两次，实体数不增加；
5. 在创建第 3 个任务时注入错误，六类对象全部为 0；
6. 已有同来源 Matter 但少 1 个 task link，重试仅补链并恢复原 `planOrder`；
7. 无日期任务不被默认为今天；
8. 下一步指向 `planOrder = 0` 的真实 taskID，不用标题匹配。

决策门：R1 未全绿，不准改 UI。

### R2：规划卡与 Prompt 收缩（2 天）

实施顺序：

1. 先用当前 Draft 做新卡片展示；
2. 接入一次 launch；
3. 打通成功回执和打开详情；
4. 跑本地 fixture；
5. 收缩 iOS / Backend Prompt；
6. 升版并部署后端；
7. 跑生产真实请求。

验收：

- 主卡可见交互不超过 2 个：“开始推进”和“调整计划”；
- 用户从卡片到完整落库只点一次；
- 成功回执的“打开计划”真能进详情；
- 杀进程重启后不重复创建；
- 模型输出的 actionable items 始终为 3–7 条，非 Matter 场景不强行拆解。

### R3：详情与 Today 去重（2 天）

详情：

- 直接查 `todoList` link 显示所有计划任务；
- 任务完成后即时刷新完成数和 next action；
- 待确认最多展开 3 条，其余收起；
- 证据与事件收进“更多”。

Today：

- 建立同一个 `displayedTaskIDs` 去重集合；
- 如 Focus 是 task，Agenda 不再显示它；
- 如 Focus 来自 Matter linked task，正在推进行不再重复下一步文案；
- 0 Matter 时隐藏整个区块；
- 页面打开不请求网络或 LLM。

### R4：纵向旅程与故障测试（1–2 天）

必测场景：

- 日本旅行；
- 搬家；
- 考试准备；
- 求职；
- 发布活动；
- 一次性“明天买牛奶”不得创建 Matter；
- 长期“我想变得更自律”不得创建 Matter；
- 网络断开不影响已生成 Draft 的本地 launch；
- 中途杀进程、冷启动、重复点击；
- 创建后从 Chat、Today、任务清单三个入口打开；
- 完成第一个任务后 next action 更新；
- 在 Matter Chat 继续讨论时无需重述背景。

### R5：7 天内部真实使用

不用 DemoSeed，不用为验收特制的假数据。

东林至少真实创建并推进 3 件事，其中必须包含一件旅行类和一件非旅行类。

每天只记录：

- 是否主动打开过详情；
- 是否完成了一个 linked task；
- 是否需要手工搬移/删除/补建任务；
- 是否需要重述背景；
- 哪一次因为信息太多而退出。

这 7 天里不新增功能，只修阻断闭环的 P0/P1。

---

## 9. 测试矩阵

### 9.1 纯逻辑

- Matter 资格判定；
- 标题清理与清单名解析；
- actionable items 过滤与上限；
- `planOrder` 生成、持久化和稳定排序；
- 最小有效 `planOrder` 的 next task 选择；
- Task / Open Loop 语义互斥；
- Focus / Agenda 去重；
- 旧 Matter 缺 list link 的兼容解析。

### 9.2 Repository

- 完整原子成功；
- 任意步骤失败全回滚；
- 同来源幂等；
- 部分历史数据补齐；
- 同名清单复用；
- 多清单模糊命中不误合并；
- 真实 ID link；
- 任务完成/删除后投影 stale 与重建。

### 9.3 UI 状态

Context Plan 卡：

- ready；
- launching；
- launched；
- failure + retry；
- duplicate choice；
- non-Matter answer；
- 0 actionable item 不出现 CTA。

详情：

- 无 target date；
- 无 next action；
- 无 open loop；
- 任务被删除；
- projection stale；
- completed / archived / reopened。

Today：

- 0 / 1 / 3 active Matter；
- Focus 是普通 task；
- Focus 是 Matter linked task；
- Focus 是 open loop；
- Agenda 局部失败；
- 离线打开。

### 9.4 真实旅程验收语句

```text
我 10 月 1 日到 7 日第一次去日本，想去东京和大阪。护照有，但签证、机票、酒店都还没弄。预算大概 1 万元，摩卡也要找人照顾。帮我整理一下要怎么准备。
```

验收时必须逐项查：

- 只有一个主 CTA；
- 点一次完成整体落库；
- 存在“国庆日本旅行”清单；
- 每个行动项都在该清单；
- 每个 task 都有 MatterLink；
- Matter 有 list link；
- 成功回执可打开详情；
- Today 只有一处展示当下主动作；
- 完成当下任务后，下一步变化；
- 冷启动后以上状态仍在；
- 继续聊时不需重述日本旅行背景。

### 9.5 验证分层

1. 代码静态检查和 `git diff --check`；
2. 纯逻辑/独立测试；
3. 定向 Xcode 测试，必须确认用例真实执行，`Executed 0 tests` 不算通过；
4. iOS Simulator 构建并安装；
5. 真机纵向旅程；
6. 冷启动/杀进程；
7. 双设备 CloudKit：清单、任务、Matter 与 Links 均到达；
8. 后端 Prompt 生产版本和真实请求。

### 9.6 建议命令

实施前先用 `xcodebuild -list` 确认当前 scheme / test target，不假设历史配置仍然有效。

```bash
git -C /Users/tangyuxuan/Desktop/Claude/HOLO status --short

xcodebuild -project "/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj" -list

xcodebuild -project "/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'generic/platform=iOS Simulator' \
  build

git -C /Users/tangyuxuan/Desktop/Claude/HOLO diff --check
```

如 Matter 新测试未被 Xcode test target 实际执行，必须按项目现有 standalone bridge 方式编译运行，不能报假绿。

---

## 10. 指标与发布门槛

### 10.1 北极星

**7 天有效推进率**

```text
7 天内至少完成一个 linked task
或在 Matter Chat 中确认一次有效状态更新的 Matter 数
÷
成功启动的 Matter 数
```

不看 Matter 创建数，因为创建数会奖励产品制造空壳。

### 10.2 过程指标

- 从卡片可见到 launch 成功的中位时长；
- launch 成功率；
- launch 重试率；
- 孤儿 Matter / 孤儿清单 / 未链接任务数；
- 成功后打开计划的比例；
- 首个 next action 完成率；
- 需重述背景率；
- 手工清理率（创建后 24 小时内删除/移动超过 30% 任务）。

埋点不记录标题、聊天文本和任务内容，只记录枚举、数量、耗时、成功/失败类型和不可逆哈希 ID。

### 10.3 内部发布线

下列任一项不满足就 No-Go：

- 10 次真实 launch 中无一次部分落库；
- 无重复任务、无孤儿 Matter、无无清单任务；
- 日本旅行主旅程冷启动后完整；
- 同一任务不在 Today 重复出现；
- 7 天真实试用中，东林不需要手工重建“日本旅行”清单；
- 至少 70% 的真实 Matter 在 7 天内有有效推进；
- 至少 80% 的试用用户能在不解释 Matter 概念的前提下完成首次启动；
- 东林本人愿意继续把下一件真实事放进去。

最后一条是硬门槛。如果开发者自己仍然觉得“我不如手动建个清单”，就不准宣传。

---

## 11. 灰度与回退

### 11.1 开关

新增：

```swift
case matterUnifiedLaunchV2Enabled
```

依赖 `matterStorageEnabled`，但不影响已有 Matter 的只读查看。

节奏：

1. Debug 手动开；
2. 东林内部账号默认开；
3. TestFlight 小样本；
4. 无数据破坏后再全量。

### 11.2 回退策略

- 关闭 V2 开关，新规划卡回到旧交互；
- 不删除已创建 Matter / List / Task / Link；
- V2 数据使用已有实体，老版仍能读；
- Prompt v2 必须与 schema v1 兼容，可在后端回退到 v1；
- 回退后不得自动清理用户已有计划。

### 11.3 数据治理

内部灰度期每次启动扫描以下不变量，只记录诊断，不自动删除：

- active Matter 是否有 origin link；
- V2 Matter 是否有 todoList link；
- todoList 中的 AI 来源任务是否都有 todoTask link；
- projection nextAction 的 taskID 是否真实存在；
- 同来源键是否有多个活跃任务。

---

## 12. Definition of Done

以下全部满足才可以称为“Matter 首发完成”：

### 产品

- [ ] 用户不需要理解 Matter / Open Loop / Projection。
- [ ] 规划卡只有一个主操作。
- [ ] 无重复 Matter 时，用户只确认一次。
- [ ] 详情默认只回答状态、下一步、计划和待确认。
- [ ] Today 不重复同一行动，且没有大型 Matter 空状态。

### 数据

- [ ] Matter + List + Tasks + Open Loops + Links + Projection 单事务成功。
- [ ] 失败时全回滚。
- [ ] 重试幂等。
- [ ] 所有任务进主题清单。
- [ ] 任务关联持久化唯一 `planOrder`，冷启动和 CloudKit 同步后不丢失。
- [ ] 同一问题不同时成为 Task 和 Open Loop。
- [ ] nextAction 只引用真实存在的 entityID。
- [ ] 旧 Matter 仍可打开、完成、归档和重开。

### AI / 后端

- [ ] iOS 后备 Prompt 与后端 Prompt 同步。
- [ ] `personal_context_planning` 版本升到 2。
- [ ] 10 条 fixture 全通过。
- [ ] 后端已部署。
- [ ] 生产 `/v1/prompts/meta` 版本和 digest 正确。
- [ ] 生产真实日本旅行请求通过。

### 验证

- [ ] 纯逻辑和 Repository 测试真执行，非 0 tests。
- [ ] Simulator 构建通过。
- [ ] 真机纵向旅程通过。
- [ ] 冷启动通过。
- [ ] 双设备 CloudKit 通过。
- [ ] 7 天内部真实使用达到发布线。

---

## 13. 实施顺序的硬规则

1. 先做 R0 静态样机，不先写 Repository。
2. 样机通过后，先写 R1 失败测试。
3. 原子契约没有全绿，不准接 UI。
4. UI 接通后再改 Prompt，避免同时调试模型和数据落库。
5. Prompt 改动完必须部署后端，不能只提交代码。
6. 日本旅行纵向旅程没跑通，不做其他场景扩展。
7. 7 天试用期不加新功能，只修 P0/P1。
8. 东林自己不愿继续用，就 No-Go，不用“功能还需要教育用户”来解释。

---

## 14. 最终交付报告模板

实施完每个阶段，只按以下格式报告：

```markdown
## 用户可见结果
- 用户现在可以做什么
- 比旧流程少了哪些决策

## 数据契约
- 本阶段建立的不变量
- 幂等/回滚/兼容结果

## 实际修改
- 精确文件清单
- 每个文件的职责变化

## 验证证据
- 纯逻辑测试：执行数/通过数
- Xcode 测试：执行数/通过数
- Simulator build
- 真机
- 冷启动
- 双设备 CloudKit
- 后端版本与真实请求

## 未验证与剩余风险
- 明确写“未测”，不得用已写代码代替已验证

## 决策门
- 本阶段 Go / No-Go
- 是否允许进入下一阶段
```

---

## 15. 最后一句产品定义

> Matter 不是用户要学会管理的新模块，而是 Holo 对一件持续事项负责到底的内部机制。用户只需要说出事情、确认一次，之后每次回来都能知道现在怎么样、还差什么、下一步做什么。
