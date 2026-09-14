# Holo「今天」Matter 化完整实施方案

- 日期：2026-09-14
- 交付对象：GLM 实施代理
- 项目绝对路径：`/Users/tangyuxuan/Desktop/Claude/HOLO`
- 当前核对基线：`1.0.4` 分支，HEAD `220ce02fc`
- 文档状态：待实施；本文完成不代表代码、构建、模拟器、真机、CloudKit 或生产已经通过
- 用户侧页面名称：`今天`
- 代码侧兼容名称：首轮保留 `DailyKanban`，不要为改名制造无价值的大规模文件重命名
- 首个纵向验收场景：`2026 国庆日本旅行`
- 上位规范：
  - `/Users/tangyuxuan/Desktop/Claude/HOLO/docs/standards/Holo-Agent研发与验收规范.md`
  - `/Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-09-11-Holo-Matter进行中的事完整实施方案.md`
  - `/Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-09-09-HoloAI个人情境规划一致性与可信交互实施方案.md`

本文是对当前已上线 Matter M0-M3 骨架的增量改造方案，不是重新实现 Matter。目标是把首页中央的“今日看板”从模块数据汇总页，升级为以“现在最值得推进什么”为核心的每日行动工作台，并补齐当前真实旅程中的断链。

---

## 0. 给 GLM 的强制执行指令

### 0.1 开始前

1. 完整阅读本文及三份上位规范，不只读取标题或摘要。
2. 执行 `git -C /Users/tangyuxuan/Desktop/Claude/HOLO status --short`，保存实施前快照。当前工作区已有大量与本方案无关的在途修改，不得覆盖、回滚、格式化或夹带。
3. 重新核对本文列出的现有类型、函数与路径。本文基于 `220ce02fc` 审计，后续源码若漂移，以当前代码为准，但不得改变本文的不变量。
4. 先写 RED 测试，再改公共契约，再改 UI。禁止从 SwiftUI 页面直接拼查询、解析自然语言或建立第二套 Matter 排序逻辑。
5. 所有 Git 命令使用 `git -C /Users/tangyuxuan/Desktop/Claude/HOLO ...`，禁止 `cd ... && git ...`。
6. 新文件位于 Xcode filesystem synchronized group 时不要机械编辑 `project.pbxproj`；测试文件是否进入 target 必须实际核对。
7. 未经东林明确授权，不自行 commit、push、部署后端、修改 CloudKit Production schema 或提交 App Store。
8. 不调用 subagents。

### 0.2 实施顺序

严格按以下顺序执行：

```text
T0 基线与事故回归
  ↓
T1 补齐 Matter 行动闭环
  ↓
T2 建立「今天」统一快照与确定性排序
  ↓
T3 重构「今天」页面
  ↓
T4 合并首页入口与路由
  ↓
T5 全链路验收、灰度与回滚验证
```

不得先画完新 UI，再回头补任务关联、Matter 对话上下文或 Next Action 执行。T1 未通过时，T3 不得宣称完成。

### 0.3 本方案默认不需要后端改动

“今天”页面必须完全由本地确定性快照驱动，打开页面不得触发 LLM 请求。

Matter-scoped Chat 的普通回答上下文优先通过现有 `UserContext`、`AIContextSectionRegistry` 和 `AIUserContextMessageBuilder` 注入，不新增后端数据库，不新建平行聊天接口。

如果实施中确实修改了 `HoloBackend/` 或任一 Prompt：

1. 同步 iOS `PromptManager.swift` 后备模板与 `HoloBackend/src/prompts/defaultPrompts.json`；
2. 升 `promptVersions`；
3. 完成本地后端测试；
4. 交付时明确写“后端改动需要部署后端”；
5. 获得授权后按后端发布规范部署，并用 `/v1/release/status`、`/v1/prompts/meta` 和真实请求验收。只看到 health 200 不算生效。

---

## 1. 产品结论

### 1.1 一句话目标

> 用户打开 Holo，不需要先选择任务、想法、财务或 Matter，就能知道今天最值得推进什么、为什么，以及下一步可以直接做什么。

### 1.2 三层产品职责

```text
首页
└── 告诉用户今天是否有值得关注的事，并提供明确入口

今天
├── 做判断：现在最值得推进什么
├── 做行动：打开、加入今日、完成、确认或继续讨论
└── 做统筹：把 Matter、日程、任务和日常状态组织在一起

Matter 详情
└── 持续解释一件事现在怎么样、还差什么、下一步是什么
```

### 1.3 核心改造不是“新增 Matter 卡片”

禁止把 Matter 作为现有预算、习惯、日程、待办、记录、健康之后的第七个平级模块。

新版信息优先级固定为：

```text
行动 > 事情 > 安排 > 状态 > 数据
```

### 1.4 用户侧改名

- 页面标题从“今日看板”改为“今天”。
- 首页中央入口明确显示“今天”，不再只展示无文字的动态球体。
- 代码首轮仍保留 `DailyKanbanView`、`DailyKanbanEntryButton` 等名称，避免无价值重命名扩大 diff。

---

## 2. 当前实现基线与已确认缺口

以下结论来自当前源码，不允许 GLM 把“已有骨架”误写成“尚未实现”，也不允许把“有类型”误写成“旅程已闭环”。

| 当前能力 | 现状 | 本轮决策 |
|---|---|---|
| 今日看板 | `DailyKanbanView` 按预算、习惯、日程、待办、记录、健康平铺 | 重构为行动优先的信息架构 |
| 顶部 Hero | `KanbanProgressHero` 用任务+习惯计算统一百分比 | 退役百分比 Hero，换成“现在最值得推进” |
| 首页中央入口 | `DailyKanbanEntryButton` 是 192pt 动态球体，没有可见名称 | 保留品牌感，但增加“今天”和状态摘要 |
| 首页 Matter | 0 个 active Matter 时整块隐藏；存在时另插一张焦点卡 | 新版开启后并入“今天”，首页不再重复两套焦点 |
| Matter 排序 | `MatterHomeSurface` 已有 attention → 日期 → 更新时间的确定性排序 | 复用 attention 规则，但由新的 Today Resolver 统筹日程和任务 |
| Context Plan 保存 | 依靠勾选后底部统一“添加选中的 N 项” | 改为逐条即时加入；批量仅保留为次要快捷操作 |
| 多个无日期条目 | 当前可能自动合并为一个主任务+多个 check item | 禁止仅因“数量≥2”自动合并；只有草案明确父子语义时才能合并 |
| 任务清单分类 | 当前多条任务会按方案主题匹配/创建清单 | 保留该修复，不得回退到全部堆在“全部” |
| 任务来源 | `TodoTask` 已有 `aiSourceMessageId` / `aiSourceItemId` | 创建时真实写入，作为跨重启追溯与补链依据 |
| Matter 激活 | `HoloMatterActivationCoordinator` 已能从方案卡激活 | 扩展为读取真实任务回执并建立 `MatterLink` |
| Matter Next Action | 类型支持 linkedTask/openLoopAction/suggestion；当前 builder 主要从 confirmed Open Loop 生成且常无 entityID | 补齐真实动作目标、执行能力和降级状态 |
| Matter 详情讨论 | `MatterDetailView` 接受 `onDiscuss`，但首页/列表打开时可传 nil | 所有入口统一接线，按钮不得看得见但无动作 |
| Matter 对话 | 用户消息会关联，回答结束后会对账 | 普通回答生成前还需注入 Matter 最小快照，避免只在回答后更新 |
| Open Loop 更多操作 | 行级存在省略号，但主要动作挂在 context menu | 改为点按可见 Menu/confirmation，不依赖长按发现 |
| Matter UI 测试 | 当前主要通过 `MatterDemoSeed` 直接造完整 Matter | 增加真实激活、逐条建任务、补链和“今天”旅程测试 |

---

## 3. 产品不变量与非目标

### 3.1 强制不变量

1. Matter 是持续事项层，不是新 Tab、文件夹或项目管理模块。
2. “今天”不是 Matter 列表页；即使没有 Matter，也必须服务日程、普通任务和习惯。
3. Task 可以属于 Matter，也可以独立存在；禁止强迫所有任务归入 Matter。
4. Matter、Task、Calendar、Habit 各自保持唯一真相源；“今天”只消费类型化快照，不复制业务状态。
5. 首页优先级由代码确定，模型只能在已验证事实内解释，不得决定颜色、风险级别或排序。
6. suggested Open Loop 和 suggestion Next Action 不得伪装成已确认事实或直接执行动作。
7. stale Matter projection 不得继续显示旧 summary/nextAction 为当前判断。
8. 不显示 Matter 完成百分比；生活事项没有可靠分母时禁止制造 73% 之类的伪精确。
9. 创建任务、完成 Matter、关闭 Open Loop 等副作用必须有明确动作、真实回执和必要的撤销/确认。
10. 页面打开不依赖网络或模型；局部数据失败不得让整页空白。
11. SwiftUI body 不直接做重复 Core Data 查询；所有模块消费同一 `HoloTodaySnapshot`。
12. 新版关闭后，旧看板和既有 Matter 数据仍可使用；回滚不删除任何用户数据。

### 3.2 本轮非目标

- 不做 Matter 自动历史聚类；
- 不开放 inferredAssociation 或 Matter 主动通知；
- 不增加底部 Tab；
- 不重做 Task、Habit、Health、Finance 的业务模型；
- 不做联网旅行攻略；
- 不用模型每次实时生成“今日建议”；
- 不用新版首页替代 Matter 详情；
- 不在本轮引入新的远端分析服务或后端 Matter 数据库；
- 不删除旧 Kanban 组件，灰度稳定前仅降级/复用，保留快速回滚。

---

## 4. 目标信息架构

### 4.1 iPhone 首屏

```text
今天                              9月14日 周一

HOLO 今日判断
日本旅行整体正常，但签证材料仍未确认。
因为距离出发还有 16 天，建议今天先处理它。

现在最值得推进
确认日本签证材料
来自：日本旅行
[开始处理]  [稍后]

进行中的事                         全部 3 件
🇯🇵 日本旅行
有 1 项需要关注 · 下一步：确认签证材料

💼 Holo 1.0.4 上线
等待审核结果

[＋ 开始一件事]

今天的安排
10:00  产品评审
○       确认签证材料              日本旅行
○       修改更新说明              Holo 上线

保持状态
习惯 3/5  ·  睡眠 6.4h  ·  步数 4,230

今日概况
支出 ¥186  ·  预算正常  ·  记录今天
```

### 4.2 固定阅读顺序

1. Header：今天、日期、关闭。
2. Primary Focus：一个最值得推进的行动及原因。
3. Weekly Brief：仅 `showWeeklyBrief == true` 时以次级横幅出现，不得压过 Primary Focus。
4. Matter Section：正在进行的事及稳定入口。
5. Agenda：今日日程、今日/逾期任务、无日期待推进任务。
6. Maintain：习惯和健康的紧凑状态。
7. Overview：预算、支出和今日记录。

### 4.3 iPad

- Header、Primary Focus、Weekly Brief 始终跨双栏。
- 左栏：进行中的事 + 今日概况。
- 右栏：今天的安排 + 保持状态。
- 双栏不是把旧模块随意左右分配；语义顺序仍由上到下成立。
- 内容列最大宽度沿用现有 `.holoContentColumn()` 约束，不能铺满大屏。

---

## 5. 页面状态与文案规格

### 5.1 Primary Focus

#### 有可执行动作

```text
现在最值得推进
确认日本签证材料
来自：日本旅行
距离出发还有 16 天，这件事仍未确认。

[开始处理]
```

按钮根据类型显示：

| 动作类型 | 主按钮 | 行为 |
|---|---|---|
| 已存在任务 | `查看任务` | 打开对应 TaskDetailView |
| confirmed Open Loop、尚无任务 | `加入今日` | 创建任务并建立 MatterLink |
| Matter 需要用户确认 | `确认一下` | 打开 Matter 详情并聚焦对应 Open Loop |
| 固定日程 | `查看日程` | 打开日程详情 |
| 普通任务 | `查看任务` | 打开任务详情 |
| 只有 Matter、无可靠下一步 | `和 Holo 梳理` | 进入带快照的 Matter-scoped Chat |

#### 没有紧急事项

```text
今天没有必须立刻处理的事
可以按自己的节奏推进安排。
```

不展示 0%，不补“开始美好的一天”等无信息口号。

#### 数据正在加载

- 使用与最终卡等高的 skeleton；
- 200ms 内完成时不闪 skeleton；
- 不先显示“没有事项”再跳成风险卡。

#### 局部失败

```text
部分状态暂时没有更新
已展示设备上最近可用的信息。
[重试]
```

只在确实使用缓存时写“最近可用”；没有缓存时如实说明对应模块不可用。

### 5.2 Matter Section

#### 0 个 active Matter

整块不能隐藏：

```text
进行中的事
最近有什么想让 Holo 一起推进？
例如旅行、搬家、求职或一次重要发布。
[开始一件事]
```

点击后进入 HoloAI，展示引导 placeholder；不得自动替用户发送一条消息。

#### 1 个 active Matter

- 展示完整卡：标题、attention、原因、Next Action；
- 无 Next Action 时显示“还没有明确下一步”，操作为“和 Holo 梳理”；
- suggested 内容必须带“建议/待确认”。

#### 2 个及以上

- 最多展示 3 个；
- 第一个使用完整卡，其余用紧凑行；
- 右上显示 `全部 N 件`；
- 首页/今天只选焦点，不等于其他 Matter 被降级或归档。

#### completed-only

- 仍展示 0 active 空态；
- 同时提供 `查看已完成`，用户不能因为首页隐藏而失去历史入口。

### 5.3 Agenda

显示顺序：

1. 正在发生的日程；
2. 90 分钟内开始的日程；
3. 已逾期任务；
4. 今日到期任务；
5. 用户明确加入今日但无具体时间的任务；
6. 最多 3 条近期待推进任务。

规则：

- 同一 Task 若同时是 Matter Next Action 和今日任务，只出现一次；
- 行尾显示 Matter 名称轻标签，但不显示内部 `matterID`；
- 完成任务后提供现有 3 秒撤回；
- 已完成任务不长期占据首屏，可在当日短暂显示成功反馈后收起；
- “近期待办”不再与“今日待办”拆成两张重量相同的大卡。

### 5.4 Maintain

- 默认只展示一行摘要：习惯完成、睡眠、步数/活动；
- 有未完成习惯时可展开快速打卡；
- Health 未授权时显示紧凑 `连接 Apple Health`，不占据整张大卡；
- 健康数据不能参与任务完成百分比；
- 减少型/负向习惯不得以“打卡越多越好”的形式渲染。

### 5.5 Overview

- 预算正常时只显示紧凑摘要；
- 超支或确定性达到风险阈值时提升为 attention signal；
- 今日记录保持快速输入，但默认折叠为一行入口；
- 财务加载失败显示 `--`，不得误报 `¥0`；
- 第一版预算和健康信号不参与 Primary Focus，以避免跨域优先级在缺少产品证据时膨胀。

---

## 6. “今天”统一数据契约

### 6.1 新增纯值类型

新增：

`/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/Today/HoloTodaySnapshot.swift`

建议契约：

```swift
nonisolated struct HoloTodaySnapshot: Equatable, Sendable {
    let referenceTime: Date
    let dayStart: Date
    let dayEnd: Date
    let timeZoneIdentifier: String
    let generatedAt: Date
    let freshness: HoloTodayFreshness
    let primaryFocus: HoloTodayFocus?
    let matters: [HoloTodayMatterItem]
    let agenda: [HoloTodayAgendaItem]
    let routine: HoloTodayRoutineSummary
    let overview: HoloTodayOverview
    let sectionStates: [HoloTodaySection: HoloTodaySectionState]
}

nonisolated struct HoloTodayFocus: Equatable, Sendable, Identifiable {
    let id: String
    let source: HoloTodayFocusSource
    let title: String
    let reasonCode: HoloTodayFocusReason
    let reasonArguments: HoloTodayReasonArguments
    let dueAt: Date?
    let severity: HoloTodaySeverity
    let matterID: UUID?
    let action: HoloTodayAction
}

nonisolated enum HoloTodayAction: Equatable, Sendable {
    case openTask(UUID)
    case openSchedule(String)
    case openMatter(UUID, focusOpenLoopID: UUID?)
    case createTaskFromOpenLoop(matterID: UUID, openLoopID: UUID)
    case discussMatter(UUID)
    case none
}

nonisolated enum HoloTodayFocusSource: String, Sendable {
    case currentSchedule
    case upcomingSchedule
    case matterLinkedTask
    case matterOpenLoop
    case overdueTask
    case todayTask
    case habitWindow
}
```

强制要求：

- `HoloTodaySnapshot` 内不得保存 `NSManagedObject`；
- `reasonCode` 是类型化原因，UI 在单一 renderer 中本地化，不靠拼接/解析模型自然语言；
- `action` 是唯一动作出口，卡片不得根据标题猜路由；
- `referenceTime/dayStart/dayEnd/timeZoneIdentifier` 必须冻结在同一次构建，避免各模块跨午夜口径不一致；
- `sectionStates` 区分 `.loading`、`.content`、`.empty`、`.failed(lastSuccessfulAt:)`；
- 缺数据与真实 0 必须分开。

### 6.2 Builder

新增：

`/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Today/HoloTodaySnapshotBuilder.swift`

职责：

1. 从现有 Schedule、Todo、Habit、Health、Finance、Matter Repository 拉取轻量值快照；
2. 统一日边界；
3. 解析真实 `MatterLink`，为任务附加 `matterID/matterTitle`；
4. 对 task、Matter Next Action 做同实体去重；
5. 调用唯一 `HoloTodayFocusResolver`；
6. 返回完整快照，局部失败写入 section state；
7. 不发网络请求，不触发模型，不写业务数据。

### 6.3 ViewModel

新增：

`/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/HoloTodayViewModel.swift`

职责：

- `@Published private(set) var state: HoloTodayViewState`；
- 首次打开等待 Core Data ready 后加载；
- 监听现有 `.todoDataDidChange`、`.habitDataDidChange`、`.financeDataDidChange`、日程变化、Matter repository 发布；
- 100ms 合并窗口去抖，避免一次动作触发多轮重复 fetch；
- 保留最后成功快照作为局部降级；
- 所有写动作调用现有 repository/coordinator，再以真实回执刷新；
- 禁止动画状态驱动 Core Data 重查。

### 6.4 不新增 Core Data 实体

本轮 Today Snapshot 是可重建读模型，不持久化为新实体，不修改 CloudKit schema。

允许在内存中保留最后成功快照；若后续需要跨冷启动缓存，必须另行评审隐私、版本和失效策略，不能在本轮顺手塞进 UserDefaults。

---

## 7. Primary Focus 确定性排序

新增：

`/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Today/HoloTodayFocusResolver.swift`

必须是可 standalone 测试的纯函数，不依赖 SwiftUI、Core Data、单例或当前系统时钟。

### 7.1 候选过滤

不进入 Primary Focus：

- 已完成/已删除/已归档任务；
- completed/archived/dismissed Matter；
- suggested Open Loop；
- suggestion 类型但未经用户确认的 Next Action；
- stale projection 里的 summary 与 nextAction；
- 无可执行出口的普通统计；
- 预算/健康的一般状态；
- 被用户本日“稍后”的同一候选（仅本次会话降级，首版不永久 suppression）。

### 7.2 优先级层级

```text
P0 正在发生的固定日程
P1 90 分钟内开始的固定日程
P2 已逾期的硬截止任务 / atRisk Matter 的已确认动作
P3 今日到期任务 / needsAttention Matter 的已确认动作
P4 用户明确加入今日的无时间任务
P5 有明确时间窗口的未完成习惯
```

同层 tie-break：

1. `dueAt/startAt` 更早；
2. Task 显式优先级更高；
3. Matter 最近由用户互动的时间更近；
4. 稳定 ID 字典序，保证同输入同输出。

### 7.3 Matter 与 Task 去重

- Matter Next Action `kind == .linkedTask` 且 `entityID` 能解析为真实任务时，只保留 task candidate，并附加 Matter 上下文；
- Open Loop 已链接任务时，只展示任务，不再展示同标题 Open Loop；
- entityID 丢失、任务已删除或无权限时，不猜标题匹配；降级为打开 Matter；
- 标题相同但 ID 不同不自动合并。

### 7.4 stale 降级

- stale projection 的旧 nextAction 禁止进入候选；
- 仍可用 `HoloMatterAttentionPolicy` 基于当前 targetDate + confirmed loops 做确定性 attention；
- 如果确定存在风险但没有可靠动作，Primary Focus 只显示“查看这件事”，不生成假任务。

### 7.5 模型边界

- Resolver 不调用模型；
- 模型生成的 Matter summary 只有在 `sourceMatterRevision == matter.revision` 时可作为说明；
- Primary Focus 的 title、reasonCode、action 均来自类型化事实；
- 模型不得覆盖 resolver 的 priority/severity。

---

## 8. 必须先补齐的 Matter 行动闭环

### 8.1 Context Plan 改为逐条即时加入

修改：

- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/Cards/ContextPlanChatCard.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PersonalContext/HoloContextPlanExecutionAdapter.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/MessageBubbleView.swift`

交互状态：

```text
未加入： [加入待办]
保存中： ProgressView，禁重复点击
已加入： ✓ 已加入  [查看]
失败：   未加入成功  [重试]
阻断：   方案背景已变化，请重新生成
```

规则：

1. 每个 task/checklist item 自己持有保存状态；
2. 点击后只创建该项，成功立即显示回执；
3. 两项以上时可在列表末尾保留次要 `全部加入`，但不能成为唯一入口；
4. 批量执行逐条回报，部分失败不回滚已成功项；
5. 去掉“只因选中无日期条目≥2就自动并成主任务”的规则；
6. 只有 draft 明确表达父任务+checklist 子项关系时才能创建主任务；
7. 同一逻辑项重复点击、退出重进、草案 revision 更新后不得重复创建；
8. 日期仍需用户确认，未知日期不得默认今天。

### 8.2 升级任务执行回执

当前 `[logicalItemID: fingerprint]` 无法支持 Matter 补链。新增兼容 V2：

```swift
nonisolated struct HoloContextPlanTaskReceiptV2: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let logicalItemID: String
    let fingerprint: String
    let taskID: UUID?
    let sourceMessageID: UUID?
    let sourceItemID: String
    let createdAt: Date
}
```

要求：

- 读取旧 `[String: String]` 时转换为“仅有 fingerprint、无 taskID”的 legacy 状态；
- V2 新写入的成功回执必须同时有 taskID/sourceMessageID；Optional 只用于兼容 legacy，业务代码不能生成缺 ID 的新回执；
- legacy 状态仍能防重复，但不能伪造 MatterLink；
- 新创建任务真实写入 `TodoTask.aiSourceMessageId` 和 `aiSourceItemId`；
- 回执容量清理按 createdAt 删除最旧项，禁止 `Dictionary.keys.prefix` 的非确定性淘汰；
- 回执只有任务落库成功后写；
- 任务被删除后回执不能让 UI 显示“已加入”，应显示“原任务已删除，可重新加入”。

### 8.3 任务与 Matter 补链

修改：

- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/Matter/HoloMatterActivationCoordinator.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Data/Repositories/HoloMatterRepository.swift`

规则：

1. Matter 已激活：任务成功创建后立即 `addLink(entityType: .todoTask, role: .action)`；
2. 任务先创建、Matter 后激活：ActivationCoordinator 按同一 contextPlanMessageID 读取 V2 receipts 并补链；
3. Matter 先激活、后逐条创建：按 origin link 找到 Matter 并补链；
4. link 写入幂等；重复调用返回已有 link；
5. Task 成功但 link 失败时不删除 Task，显示“已加入待办，正在补充关联”，提供重试；
6. link 只有真实 taskID，不用标题建立关系；
7. 删除 Task 后 Matter UI 显示来源不可用并允许移除断链，不复活任务。

### 8.4 Next Action 变成可执行对象

修改：

- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/Matter/HoloMatterProjectionBuilder.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/AI/HoloMatterModels.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Matter/MatterDetailView.swift`

规则：

- linkedTask：`entityID` 必须为真实 task UUID；
- openLoopAction：`entityID` 必须为真实 confirmed Open Loop UUID；
- suggestion：明确标记建议，只能“确认/加入”，不能直接显示为已存在任务；
- Matter 详情和 Today Hero 共用同一个 action resolver；
- 无 entityID 时只允许 `.discussMatter` 或 `.openMatter` 降级，禁止标题匹配；
- 完成 linked task 后刷新 Matter projection；
- Open Loop 建任务后，Next Action 从 openLoopAction 升级为 linkedTask；
- 下一步变化必须来自 revision 更新，不由 View 本地替换文字。

新增：

`/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/Matter/HoloMatterLinkedEntityChangeCoordinator.swift`

职责：

1. 接收 Task 创建、更新截止日、完成、撤回完成、归档和删除的类型化变更；
2. 按真实 taskID 查找 `MatterLink(.todoTask)`，不扫描标题；
3. 让 `HoloMatterRepository` 记录幂等 linked-entity event、递增相关 Matter revision 并重建投影；
4. Task 仍是完成状态唯一真相源，Matter 不复制一份 task completed 布尔值；
5. 同一 `taskID + task.updatedAt + changeKind` 只处理一次；
6. 没有关联 Matter 时立即返回，不增加普通任务路径成本；
7. 不在 Notification 的 `object=nil` 上反猜变化实体；若现有通知缺少 ID，新增类型化 payload/回调边界。

### 8.5 打通所有 Matter 详情与讨论路由

修改：

- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/HomeView.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Matter/MatterListView.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Matter/MatterDetailView.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/MessageBubbleView.swift`

要求：

- 从首页、Today、MatterList、ContextPlan 卡进入的详情都必须获得非 nil `onDiscuss`；
- 点击后调用 `MatterChatContextStore.enter(matterID:source:)`，关闭当前 cover/sheet，再进入 resident Chat；
- 路由转换期间不得先清空 Matter context；
- ContextPlan 激活完成后的“查看”必须真实可点；
- Open Loop 省略号改为可见 `Menu` 或点按弹出的 confirmation dialog，不依赖长按 context menu；
- 路由失败时保留当前页并提示，不出现无响应按钮。

### 8.6 普通回答生成前注入 Matter 最小快照

修改：

- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/AI/AIModels.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/UserContextBuilder.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/AIUserContextMessageBuilder.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift`

新增 `HoloMatterPromptSnapshot`：

```swift
nonisolated struct HoloMatterPromptSnapshot: Equatable, Sendable {
    let matterID: UUID
    let title: String
    let targetDate: Date?
    let phase: HoloMatterPhase?
    let revision: Int64
    let summary: String?
    let confirmedOpenLoops: [HoloMatterPromptLoop]
    let suggestedOpenLoops: [HoloMatterPromptLoop]
    let nextAction: HoloMatterNextAction?
}
```

规则：

- 仅 `MatterChatContextStore.active` 存在且 Matter 可访问时注入；
- summary/nextAction stale 时不注入旧内容，只注入当前确定性状态；
- confirmed 与 suggested 分区，明确告诉模型 suggested 不是事实；
- 最多 10 个 active loops，不上传无关 Matter、整段历史或其他域原始数据；
- 当前用户消息始终优先；Matter context 只提供背景，不自动扩展动作；
- 普通回答生成和回答后 reconciliation 使用同一 matterID/revision；
- 回答期间用户切换 Matter 时，迟到对账按原请求上下文校验，不写入新 Matter。

---

## 9. UI 组件与视觉规范

### 9.1 新增组件

| 绝对路径 | 职责 |
|---|---|
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayPrimaryFocusCard.swift` | 今日判断 + 唯一主行动 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayMatterSection.swift` | 0/1/多 Matter 与稳定入口 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayAgendaSection.swift` | 日程+任务统一时间序列 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayRoutineStrip.swift` | 习惯+健康紧凑状态与展开 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayOverviewSection.swift` | 财务+记录摘要 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayActionDispatcher.swift` | 类型化 action 到现有页面/仓库的唯一分发边界 |

HomeView 持有唯一 `@StateObject HoloTodayViewModel`，同时传给 `DailyKanbanEntryButton` 和 `DailyKanbanView`。禁止首页入口和 Today 页面各建一个 ViewModel、各查一遍相同数据。

### 9.2 复用与退役

- `MatterFocusCard` 拆出无导航的展示子组件供 Today 复用；排序仍由 resolver 完成；
- `KanbanHabitSection`、`KanbanHealthSection`、`KanbanBudgetSection` 增加 compact presentation 或拆出可复用内容，不复制业务查询；
- `KanbanProgressHero` 在新 flag 开启时不渲染，但首轮不删除；
- `KanbanTaskSection` 由 `TodayAgendaSection` 替代，但首轮保留供旧版回滚；
- `KanbanMoodSection` 的保存逻辑复用，入口改为紧凑展开；
- `KanbanWeeklyBriefCard` 保留，移动到 Primary Focus 之后。

### 9.3 设计令牌

不新增独立牌色，沿用 Holo DesignSystem：

- 页面水平 padding：iPhone `16`，expanded `32`；
- 一级区块间距：`20`；
- 卡内 padding：`14–16`；
- 行最小高度：`44`；
- 主卡圆角：`HoloRadius.xl`；普通卡：`HoloRadius.lg`；
- 页面标题：`.holoHeading`；
- 主行动标题：`.title3.weight(.semibold)`；
- 正文：`.holoBody` / `.subheadline`；
- 辅助说明：`.holoCaption` / `.caption`；
- risk 使用 `.holoError`，attention 使用 `.holoPrimary`，success 使用 `.holoSuccess`；
- 状态不能只靠颜色，必须同时有文字或图标；
- 阴影沿用 `HoloShadow.card`，禁止每张卡重新发明阴影。

### 9.4 首页中央入口

`DailyKanbanEntryButton` 新版内容：

```text
       今天
  1 件事需要关注
```

状态：

| 状态 | 副标题 |
|---|---|
| risk/attention | `1 件事需要关注` |
| 有安排无风险 | `今天有 4 项安排` |
| 空闲 | `今天暂无紧急事项` |
| 加载 | `正在整理今天` |
| 局部失败 | `查看今天` |

规则：

- 保留柔和呼吸和环形品牌语言，但动画不再表达任务+习惯伪总进度；
- 移除三环分别代表总体/习惯/任务的产品语义；
- 开启 Reduce Motion 时停止持续旋转和呼吸，仅保留静态层次；
- accessibility label 必须读出“今天，1 件事需要关注，按钮”；
- 可见文案不能只存在于 VoiceOver；
- 点击热区至少 44×44，实际保持完整圆形热区。

### 9.5 可访问性

- Dynamic Type 到 AX5 不截断主行动；必要时按钮纵向堆叠；
- VoiceOver 顺序严格跟随视觉阅读顺序；
- 所有省略号、状态徽标、任务来源提供准确 label/hint；
- 深色/浅色均达到正常文本 4.5:1、较大文本 3:1 的对比目标；
- 颜色之外必须有文字状态；
- 不用 drag、长按、hover 作为唯一入口；
- 键盘/外接键盘焦点可到达主按钮、Matter 卡、Agenda 行和展开控件；
- iPad 指针 hover 只是增强，不影响点击；
- skeleton 对 VoiceOver 隐藏，并用一次“正在整理今天”状态播报替代。

---

## 10. 导航与动作架构

### 10.1 Today 内部路由

新增类型化路由：

```swift
enum HoloTodayRoute: Hashable {
    case matterList
    case matterDetail(UUID, focusOpenLoopID: UUID?)
    case taskDetail(UUID)
    case scheduleDetail(String)
}
```

- `DailyKanbanView` 内建立一个 NavigationStack；
- 不让 MatterListView 再嵌套一层不必要的 NavigationStack；可拆 `MatterListContent` 供独立 sheet 与 Today route 共用；
- Today 关闭仍使用现有 fullScreenCover 行为；
- 从详情讨论 Matter 时，由 HomeView 提供 `onOpenChatWithMatter`，先保存 context，再关闭 Today，最后切 resident `.ai`；
- 不通过 Notification 字符串传 matterID。

### 10.2 Action Dispatcher

所有主行动统一走 `TodayActionDispatcher`：

1. 验证目标仍存在；
2. 验证 Matter revision / task 状态仍匹配；
3. 执行或导航；
4. 接收真实回执；
5. 更新 ViewModel snapshot；
6. 失败时保留原卡并显示局部错误；
7. 幂等动作禁止双击重复写入。

View 不得出现多套 `switch source`、标题匹配或自行查 repository。

---

## 11. 文件级实施范围

### 11.1 新增文件

| 阶段 | 绝对路径 |
|---|---|
| T0/T2 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/Today/HoloTodaySnapshot.swift` |
| T2 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Today/HoloTodaySnapshotBuilder.swift` |
| T2 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Today/HoloTodayFocusResolver.swift` |
| T2 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/HoloTodayViewModel.swift` |
| T3 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayPrimaryFocusCard.swift` |
| T3 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayMatterSection.swift` |
| T3 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayAgendaSection.swift` |
| T3 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayRoutineStrip.swift` |
| T3 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayOverviewSection.swift` |
| T3/T4 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/TodayActionDispatcher.swift` |
| T1 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/Matter/HoloMatterLinkedEntityChangeCoordinator.swift` |
| T4 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/HoloTodayRolloutPolicy.swift` |
| T0/T2 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/HoloTests/Views/Today/HoloTodayFocusResolverTests.swift` |
| T1 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/HoloTests/Services/AI/PersonalContext/ContextPlanItemExecutionTests.swift` |
| T1 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/HoloTests/Services/Matter/HoloMatterTaskLinkingTests.swift` |
| T5 | `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/HoloUITests/TodayMatterVerticalSliceUITests.swift` |

### 11.2 修改文件

| 文件 | 目的 |
|---|---|
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/DailyKanbanView.swift` | 新信息架构、统一 ViewModel、内部路由 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Components/DailyKanbanEntryButton.swift` | 显式“今天”入口与状态摘要 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/HomeView.swift` | 条件移除重复 Matter 卡、Today 路由、Matter Chat 接线 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Onboarding/HomeCoachTour.swift` | 引导从“点击球体”改为“从今天开始” |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/KanbanHabitSection.swift` | 提取 compact 内容，不改业务规则 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/KanbanHealthSection.swift` | 提取 compact 状态 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/KanbanBudgetSection.swift` | 提取 overview 数据与异常态 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/DailyKanban/KanbanMoodSection.swift` | 紧凑入口/展开复用 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/TodoRepository+Kanban.swift` | 统一 Today 查询，不再在 View body 重复 fetch |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/Cards/ContextPlanChatCard.swift` | 单条即时创建、逐条回执 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/PersonalContext/HoloContextPlanExecutionAdapter.swift` | 单条 prepare、V2 receipt、幂等 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/MessageBubbleView.swift` | 真正写来源字段、创建后补 MatterLink、激活卡查看路由 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/Matter/HoloMatterActivationCoordinator.swift` | 激活后补链 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/Matter/HoloMatterProjectionBuilder.swift` | linkedTask/openLoopAction 真目标 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Matter/MatterDetailView.swift` | 可执行 Next Action、显式 Menu、讨论接线 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Matter/MatterListView.swift` | 可嵌入内容与统一路由 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/AI/AIModels.swift` | 可选 Matter prompt snapshot |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/UserContextBuilder.swift` | 当前 Matter 最小快照构建 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/AI/AIUserContextMessageBuilder.swift` | chat/intent 两种安全注入规则 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift` | 冻结请求级 Matter context 与迟到校验 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/TodoRepository.swift` | 发出带 taskID/changeKind 的类型化变化，驱动关联 Matter 失效/重建 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Localizable.xcstrings` | 简中/繁中/英文文案 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Diagnostics/HoloAppStoreScreenshotSeeder.swift` | 新版 Today 确定性展示种子，不作为真实旅程验收 |

### 11.3 明确不改

- `HoloBackend/`：除非 T1.6 的现有 UserContext 注入无法满足；
- Matter Core Data schema：本轮不新增实体/属性；
- Task、Thought、Finance、Health 的既有数据模型；
- App 底部导航结构；
- Matter inferredAssociation/intervention 默认开关。

---

## 12. 分阶段实施工单

### T0：基线与事故回归

任务：

1. 记录 git 状态、当前 HEAD、可用模拟器和现有失败基线。
2. 为以下问题先建 RED 用例：
   - 0 Matter 时入口消失；
   - stale nextAction 被选为今日焦点；
   - Matter linkedTask 与今日任务重复；
   - suggested Open Loop 成为主行动；
   - 多个无日期计划项被强制合并；
   - 单项创建后退出重进重复创建；
   - 任务已创建但 Matter 激活后没有链接；
   - 首页/列表详情的“和 Holo 讨论”无动作；
   - Matter 普通回答没有当前事情背景；
   - Open Loop 省略号点按无菜单。
3. 为 resolver 建正例/反例 fixture：日本旅行、发布、普通买牛奶、无 Matter、多个 Matter、跨午夜、时区变化。
4. 核对已有 Matter tests、ContextPlan standalone tests、Daily Kanban UI tests 是否真实进入 target。

出口：

- 新测试在修复前确实失败；
- 不用截图或文字搜索代替功能断言；
- 明确记录哪些测试是 standalone、XCTest、UI test。

### T1：Matter 行动闭环

任务：

1. 实现单项任务创建状态机和可选批量快捷动作。
2. 实现 receipt V2 与旧 receipt 兼容。
3. 真实写 `aiSourceMessageId/aiSourceItemId`。
4. 实现创建后即时链接、激活后补链和补链失败重试。
5. 补齐 linkedTask/openLoopAction entityID 与统一动作解析。
6. 接通全部 Matter 详情的 onDiscuss。
7. 用显式 Menu 替换不可发现的 Open Loop 长按入口。
8. 在普通回答生成前注入冻结的 Matter 最小快照。

出口：

- 单个建议能独立加入待办；
- 任务真实落库才显示成功；
- 重复点击不重复建任务；
- 任务和 Matter 可双向追溯；
- 从任意 Matter 详情都能进入正确 scoped chat；
- “猫怎么办？”的回答能读取日本旅行当前未解决项；
- 回答后对账仍可撤销；
- 不触碰后端时明确写“本阶段无后端改动”。

### T2：Today Snapshot 与 Resolver

任务：

1. 建立 HoloTodaySnapshot 类型和 section state。
2. 建立 SnapshotBuilder，统一日边界和局部失败。
3. 建立纯函数 FocusResolver 和 reason renderer。
4. 建立 task/Matter 去重与断链降级。
5. 建立 HoloTodayViewModel 的事件监听、去抖和最后成功快照。
6. 增加性能保护：一次 refresh 中每个 repository 最多一轮查询。

出口：

- 相同输入稳定输出相同 primary focus；
- 0/1/多 Matter、stale、linkedTask、跨午夜全部通过；
- Builder 不调用模型/网络；
- UI body 不触发 repository 查询；
- 局部模块失败不影响其他区块。

### T3：重构“今天”页面

任务：

1. `DailyKanbanView` 改消费统一 ViewModel。
2. 用 TodayPrimaryFocusCard 替换 KanbanProgressHero。
3. 实现 Matter 0/1/多状态。
4. 实现统一 Agenda。
5. 将 Habit/Health 压缩为 Routine Strip。
6. 将 Budget/Mood 压缩为 Overview。
7. Weekly Brief 移至主行动之后。
8. 完成 loading/empty/error/stale/partial-success 状态。
9. 完成 iPhone/iPad/Dynamic Type/VoiceOver/Reduce Motion。

出口：

- 首屏无需滚动即可看到主行动和至少一个 Matter 入口；
- 无 Matter 用户仍能理解页面用途并开始一件事；
- 页面不出现伪总百分比；
- 正常预算/健康不抢主行动；
- 所有按钮可见、可点、结果真实。

### T4：首页入口与路由合并

任务：

1. DailyKanbanEntryButton 显示“今天”及摘要。
2. 新版 flag 开启时隐藏 HomeView 独立 MatterFocusCard，避免重复。
3. flag 关闭时完整恢复旧入口+旧看板+旧 Matter 焦点卡。
4. 更新 HomeCoachTour 文案和定位。
5. 接通 Today 内 MatterList、MatterDetail、TaskDetail、ScheduleDetail 和 scoped chat。
6. 检查所有 deep link、晨报打开 Today 的入口仍正常。

出口：

- 新用户无需猜中央球体用途；
- 首页只存在一套“今天该关注什么”的语义；
- 晨报、日程条、小组件/深链原入口不回归；
- 关闭 flag 不丢数据、不崩溃。

### T5：全链路验收与内部灰度

任务：

1. 跑测试矩阵和全工程 Debug build。
2. 用真实 Context Plan 跑日本旅行，不使用 MatterDemoSeed 代替主验收。
3. 再用 DemoSeed 验证 0/1/多/stale/失败等 UI 边界。
4. 至少一台小屏 iPhone、一台常规 iPhone；iPad 未测必须明确记录。
5. 真机验证 Matter 对话、任务补链、退出重进、冷启动、撤回。
6. 内部灰度至少连续使用 7 天，记录误判、漏判和主行动采用情况。
7. 灰度稳定后才能删除旧组件；本轮默认不删除。

出口：

- 满足 §14 Definition of Done；
- 交付报告区分代码、单测、build、模拟器、真机、CloudKit、后端和生产；
- `Executed 0 tests` 不算通过。

---

## 13. 测试与验收矩阵

### 13.1 Resolver 单元/standalone

| 场景 | 预期 |
|---|---|
| 当前有正在进行的日程 | 日程为 P0 |
| 80 分钟后有日程，同时有普通今日任务 | 日程为 P1 |
| atRisk Matter 有 confirmed action | 进入 P2 |
| atRisk Matter 只有 suggested loop | 不成为可执行主行动，只能打开 Matter |
| projection stale | 旧 nextAction 不出现 |
| Matter nextAction 指向今日 task | 只出现一条 task candidate |
| linked task 已删除 | 不猜标题，降级打开 Matter |
| 两个候选所有字段相同 | stable ID 保证顺序固定 |
| referenceTime 临近午夜 | 全部模块使用同一 day interval |
| 时区切换 | dayStart/dayEnd 重新构建，不沿用旧日 |
| 无任何候选 | primaryFocus=nil，页面显示 calm state |

### 13.2 Context Plan 与补链

- 单条加入成功；
- 单条加入失败重试；
- 双击幂等；
- 退出重进恢复已加入状态；
- draft revision 改变但条目未变不重复；
- 条目实质变化提示重新确认；
- 多条无日期任务不自动合并；
- 明确父子结构才生成 check items；
- 任务先于 Matter / Matter 先于任务两种顺序均补链；
- Task 成功、link 失败、重试成功；
- 删除 Task 后回执降级；
- legacy receipt 解码不崩溃。

### 13.3 Matter scoped chat

- 首页详情 → 讨论；
- Today 详情 → 讨论；
- MatterList 详情 → 讨论；
- ContextPlan 激活回执 → 查看 → 讨论；
- 回答生成前含当前 Matter 标题、confirmed loops、fresh nextAction；
- suggested 明确标记为推测；
- stale 内容不注入；
- 用户退出 Matter 胶囊后下一条不再关联；
- 回答过程中切换 Matter，迟到对账不串事项；
- “酒店订好了”唯一匹配可撤销；东京/京都并存时必须追问。

### 13.4 Today UI

- 0/1/2/3/10 个 active Matter；
- completed-only；
- 长中文/英文标题；
- 大字体 AX1–AX5；
- 深色/浅色；
- Reduce Motion；
- VoiceOver 阅读顺序；
- Health 未授权/无数据/不支持；
- Finance 真实 0/加载/失败/超支；
- Habit 0 个、check-in、count、measure、负向习惯；
- Task overdue/today/no-date/completed/pending undo；
- Schedule 无权限/无日程/当前/即将开始；
- iPhone 375×667、常规 iPhone、iPad 双栏；
- 页面中途数据刷新不跳回顶部。

### 13.5 真实日本旅行旅程

1. 清空测试账号 active Matter，只保留普通任务与习惯。
2. 首页中央入口可见“今天”；进入后看到 0 Matter 空态和“开始一件事”。
3. 在 HoloAI 输入：`国庆准备去日本，签证、猫、日元和攻略怎么安排？`
4. 等待真实 Context Plan 完成。
5. 先只对“确认签证材料”点击“加入待办”，不勾选/保存其他项。
6. 验证任务立即真实创建、正确归组、退出重进仍显示已加入。
7. 再点击“开始整理”，确认创建“国庆日本旅行”。
8. 验证既有签证任务自动链接到 Matter。
9. 回首页：中央入口显示需要关注；进入 Today 首屏为签证行动。
10. 点击“查看任务”，进入正确任务而非标题相似任务。
11. 返回 Matter，点击“和 Holo 讨论这件事”，输入：`猫怎么办？`
12. 验证普通回答知道当前是日本旅行，并引用当前未解决状态而非要求重述背景。
13. 输入：`酒店订好了。`；唯一匹配时更新并可撤销，多个酒店时追问。
14. 完成签证任务；返回 Today，主行动更新，不再重复显示旧动作。
15. 冷启动后再次进入，Matter、链接、任务回执与 Next Action 一致。
16. 完成 Matter 后首页退出 attention，但 Today 仍可进入已完成列表。

任何一步使用 DemoSeed、手工数据库改值或只看日志代替，都不能算该旅程通过。

### 13.6 构建与命令原则

GLM 先用当前可用 Simulator ID，不硬编码可能不存在的设备名。示例：

```bash
xcodebuild test \
  -project '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj' \
  -scheme Holo \
  -destination 'platform=iOS Simulator,id=<CURRENT_SIMULATOR_UDID>' \
  -only-testing:HoloTests/HoloTodayFocusResolverTests \
  -only-testing:HoloTests/ContextPlanItemExecutionTests \
  -only-testing:HoloTests/HoloMatterTaskLinkingTests
```

```bash
xcodebuild \
  -project '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj' \
  -scheme Holo \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/holo-today-matter-build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

如果新增测试未登记进 HoloTests target，必须按项目惯例同时提供可直接 `swiftc` 执行的 standalone 入口，报告真实断言数；不能用 `build_sim` 代替测试。

---

## 14. Definition of Done

只有全部满足，才可以写“新版今天 Matter 化完成”：

- [ ] 用户侧标题为“今天”，首页中央入口有可见名称和状态摘要
- [ ] 新版不是旧模块上方多插一张 Matter 卡，而是行动优先结构
- [ ] 退役任务+习惯伪总百分比
- [ ] 页面打开不触发模型/网络请求
- [ ] 所有区块消费同一冻结日边界的 HoloTodaySnapshot
- [ ] SwiftUI body 不重复查询 Core Data
- [ ] Primary Focus 由唯一确定性 Resolver 决定
- [ ] suggested/stale/无动作目标内容不会成为可执行主行动
- [ ] Matter linkedTask 与 Agenda 不重复
- [ ] 0 Matter 时仍有稳定创建入口和历史入口
- [ ] 1/多 Matter 正确展示且最多首屏展示 3 件
- [ ] Context Plan 每条任务可独立即时加入
- [ ] 批量加入只是次要快捷操作
- [ ] 多个无日期条目不会因为数量被自动合并成父任务
- [ ] 任务创建有真实回执、来源 ID 和跨重启幂等
- [ ] 任务先创建/后创建两种顺序都能关联 Matter
- [ ] Task 成功但 MatterLink 失败时不丢 Task，并可补链
- [ ] Next Action 有真实 entityID 或明确安全降级
- [ ] 从首页、Today、MatterList、ContextPlan 打开的详情都能讨论该 Matter
- [ ] Open Loop 省略号点按可直接操作，不依赖长按
- [ ] Matter 普通回答生成前收到 fresh 最小快照
- [ ] 回答后对账仍遵守 revision、歧义和撤销规则
- [ ] Agenda 能混合日程、Matter 任务和独立任务，并保持唯一实体
- [ ] Budget/Health 正常态降级，错误与真实 0 可区分
- [ ] loading/empty/error/stale/partial failure 全部有真实状态
- [ ] iPhone 小屏、常规 iPhone、iPad、深浅色、大字体、VoiceOver、Reduce Motion 可用
- [ ] 页面刷新不跳顶部、不重复闪空态
- [ ] 新增测试真实执行且断言数非零
- [ ] 既有 Matter、Context Plan、Todo、Habit、Schedule 回归通过
- [ ] 全工程 Debug build 通过
- [ ] 真实日本旅行纵向旅程通过，DemoSeed 未冒充真实验收
- [ ] 至少一台真机验收；未测设备明确记录
- [ ] Today 灰度关闭可恢复旧看板和旧首页布局
- [ ] 回滚不删除 Matter/Task/Thought 等用户数据
- [ ] 没有夹带或覆盖实施前工作区的无关修改
- [ ] 若触及后端/Prompt，已明确部署要求并完成相应生产验证；否则明确写“无后端改动”

---

## 15. 灰度、指标与回滚

### 15.1 Feature Flag

建议新增单一 UI 开关：`todayCommandCenterEnabled`。

开关由独立 `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/HoloTodayRolloutPolicy.swift` 管理，不塞进 `HoloMatterRolloutPolicy`。原因是“今天”即使没有 Matter 也必须服务普通日程、任务和习惯，两者生命周期不能强耦合。

- 开：新首页入口摘要 + 新 Today + 首页独立 Matter 卡隐藏；
- 关：旧 DailyKanbanEntryButton + 旧 DailyKanbanView + 旧 MatterFocusCard 全部恢复；
- Matter 数据层、激活、scoped chat 原开关不受影响；
- 新 Today 在 Matter storage 关闭时仍可显示普通日程/任务/习惯，但 Matter Section 显示不可用而不是崩溃。

首版不要为每个小区块加十几个组合 flag，避免产生不可测状态空间。

### 15.2 内部观察指标

优先记录真正的帮助，不以页面打开量自我安慰：

| 指标 | 含义 |
|---|---|
| `today_primary_action_open_rate` | 用户是否愿意处理首要行动 |
| `today_primary_action_complete_rate_24h` | 建议后 24h 内是否真实完成/解决 |
| `context_plan_single_item_create_success` | 单项加入成功率 |
| `matter_task_link_success` | 任务与 Matter 关联成功率 |
| `matter_next_action_stale_suppressed` | 成功拦截旧动作次数 |
| `today_focus_manual_disagreement` | 用户点“稍后/不相关”的比例 |
| `matter_scoped_chat_continuity_success` | 用户无需重述背景的抽样通过率 |

禁止把 Matter 创建数、卡片曝光数、生成字数当北极星。

如果当前没有统一产品分析基础设施，先用内部诊断事件和 7 天手工试用表，不为本轮另建外部埋点系统。

### 15.3 回滚

- Today UI 异常：关闭 `todayCommandCenterEnabled`，立即恢复旧入口和旧看板；
- Resolver 异常：新 UI 进入 calm state，保留 Agenda/Matter 列表入口，不随机选择；
- 单项创建异常：关闭逐条 CTA，临时恢复既有批量保存，不删除已建任务；
- Matter 补链异常：停止自动补链，保留 Task 和待重试 receipt；
- scoped context 异常：关闭 `matterScopedChatEnabled`，普通聊天可用，Matter 详情保留只读；
- 任何回滚都不移除 Core Data Matter 实体、不删除 Link、不改 Task 内容；
- 新版稳定灰度前不删除 Legacy Kanban 组件。

---

## 16. 性能与隐私门禁

### 16.1 性能

- 首次打开先展示本地框架，主数据读取 P95 目标 `< 100ms`（不含 Core Data 冷启动 ready）；
- 不发网络；
- Matter 首页候选最多读取 20 个 active，展示最多 3 个；
- Agenda 默认最多展示 12 项，其余进入对应列表；
- Open Loop 构建每个 Matter 只读 active 必要字段；
- 一次数据变化合并为一次 snapshot refresh；
- 动画不得触发 repository 查询；
- Instruments/日志确认没有因卡片 body 重算造成 N×fetch。

### 16.2 隐私

- Today Snapshot 只在本机内存存在；
- Matter Chat 只上传当前 Matter 最小快照；
- 不上传其他 Matter、无关交易、健康原始样本或整段历史；
- suggested 明确标注推测；
- 用户撤销/删除/遗忘后，下次 snapshot 与 prompt 都不得继续包含来源；
- 内部诊断事件不记录标题、对话正文、金额明细或健康值。

---

## 17. GLM 最终交付报告模板

GLM 完成 T0-T5 后必须按以下结构报告，不得只说“已完成”或“build succeeded”。

### 用户可见结果

- 首页现在显示什么；
- 0/1/多 Matter 分别如何；
- 单条任务如何加入；
- 主行动如何执行；
- 失败和 stale 时用户看到什么；
- 与旧看板相比移除了什么、保留了什么。

### 实际修改

- 新增文件；
- 修改文件；
- 未修改但计划原本考虑的文件及原因；
- 数据契约；
- feature flag；
- 后端/Prompt 是否触及；
- 与本文任何偏差及理由。

### 验证证据

| 层级 | 命令/设备 | 实际执行数 | 结果 | 证据路径 |
|---|---|---:|---|---|
| standalone |  |  |  |  |
| XCTest |  |  |  |  |
| UI test |  |  |  |  |
| Debug build |  |  |  |  |
| 小屏 iPhone |  |  |  |  |
| 常规 iPhone |  |  |  |  |
| iPad |  |  |  |  |
| 真机 |  |  |  |  |
| CloudKit | 不涉及则写“不涉及” |  |  |  |
| 后端 | 不涉及则写“无后端改动” |  |  |  |
| 生产 | 未部署则写“未部署” |  |  |  |

### 真实旅程结果

- 日本旅行每一步的实际结果；
- 首个单项任务 ID；
- Matter ID；
- MatterLink 是否存在；
- 完成任务前后的 Next Action；
- 冷启动后是否一致；
- 是否使用 DemoSeed；若用了，只能列为边界 UI 验证。

### 剩余风险

- 未测设备；
- 已知失败；
- 工作区外部阻断；
- 需要东林拍板的上线/提交/部署事项。

---

## 18. 最终产品判断

这次改版的成功标准不是“首页更漂亮”或“多了一张 Matter 卡”，而是：

> 用户每天打开 Holo，都能更快地找到现实生活中最值得推进的一件事，并能在同一个入口把它真正向前推一步。

日本旅行场景中，成功体验应当是：

```text
Holo 知道我正在准备日本旅行
→ 知道签证仍有风险
→ 今天把签证放到最值得推进的位置
→ 我单独点一下就加入待办
→ 任务属于日本旅行，不会散落
→ 做完后 Holo 自动转向下一个未解决问题
→ 我继续聊天时不需要重新解释背景
```

如果最终只完成了新版排版、动画和卡片顺序，而这条链路没有成立，应判定本次实施未完成。
