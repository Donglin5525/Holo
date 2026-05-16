# Holo 目标系统 v1 设计

## 概述

Holo 目标系统 v1 为用户提供一个从模糊长期愿望到可执行行动系统的轻量闭环。

用户可以在 HoloAI 中表达类似「我想学习 SwiftUI」「我想减脂」「我想准备考试」这样的长期目标。HoloAI 通过最多 3 轮追问澄清目标，再生成一个可编辑的目标计划草案。用户确认后，系统保存一个 `Goal`，并按用户选择创建关联的任务和习惯。

目标本身放在「个人 > 我的目标」中长期管理。任务模块继续负责一次性行动，习惯模块继续负责持续行为，Goal 只承担聚合、关联、进展解释和 AI 上下文感知。

## 设计目标

- 让 HoloAI 可以把用户的长期意图转化为结构化行动计划。
- 在「个人」模块下新增轻量的目标管理能力。
- 让任务和习惯可以归属于某个目标，并支持目标级进展统计。
- 让 HoloAI 后续对话和洞察能在用户授权后感知目标上下文。
- 保持 v1 范围克制，避免把 Goal 做成复杂项目管理系统。

## 非目标

- v1 不支持用户在「个人 > 我的目标」中手动新建目标。
- v1 不支持一个任务或习惯关联多个目标。
- v1 不提供复杂 OKR、里程碑、多层项目管理、甘特图或团队协作能力。
- v1 不让 AI 自动把目标标记为完成。
- v1 不把完整目标列表自动写入 `HoloProfile.md`。

## 核心定位

Goal 是 Holo 对「用户为什么要做这些任务和习惯」的理解层。

```text
Goal：回答「我为什么要持续做这些事」
Task：回答「我接下来要完成什么一次性行动」
Habit：回答「我需要长期坚持什么行为」
HoloAI：负责把模糊目标变成 Goal + Task + Habit 的草案
个人模块：负责长期查看和管理 Goal
```

示例：

```text
Goal：学习 SwiftUI 到能独立开发 App
  Task：看完 SwiftUI 官方教程
  Task：做一个 Todo demo
  Task：重构 Holo 中的一个真实页面
  Habit：每周学习 4 次，每次 45 分钟
  Habit：每周复盘一次学习笔记
```

```text
Goal：减脂 5kg
  Task：制定一周饮食计划
  Task：购买体脂秤
  Habit：每周健身 3 次
  Habit：每天记录体重
  Habit：每周最多一次放纵餐
```

## 用户故事

### 用户故事 1：通过 HoloAI 规划学习目标

用户在 HoloAI 中点击「规划目标」，输入「我想学习 SwiftUI」。

HoloAI 追问：
- 想学到什么程度？
- 学习这个技能是为了什么？
- 每周大概能投入多少时间？

用户回答后，HoloAI 生成目标草案：
- 一个学习 SwiftUI 的 Goal
- 若干阶段性任务
- 一个每周学习习惯
- 一个每周复盘习惯

用户在确认看板中轻量编辑标题、截止日期和习惯频率，勾选要创建的项目，授权保存目标，并授权 HoloAI 后续参考该目标。

### 用户故事 2：管理已有目标

用户进入「个人 > 我的目标」，看到所有目标列表。

每个目标展示：
- 标题
- 当前状态
- 粗粒度进展
- 关联任务完成情况
- 关联习惯近期坚持情况

用户点进目标详情，可以查看关联任务和习惯，也可以暂停、恢复、完成或删除目标。

### 用户故事 3：删除目标但保留行动

用户删除某个目标时，系统提示：

```text
删除目标后，基于该目标创建的任务和习惯不会被删除，只会解除与该目标的关联。
```

用户确认后，系统删除 Goal 或解除 Goal 记录，同时保留所有任务、习惯、打卡记录和任务完成历史。

### 用户故事 4：AI 在授权后感知目标

用户授权某个目标进入 AI 上下文后，后续向 HoloAI 提问「我最近是不是有点拖延」。

HoloAI 可以结合：
- 当前 active Goal
- 目标下任务完成情况
- 目标下习惯近期完成情况
- 用户的近期对话和记录

给出相关建议，例如：

```text
你最近的 SwiftUI 学习目标里，习惯还保持得不错，但「完成第一个 demo」这个任务已经停了 5 天。
要不要我帮你把它拆成一个 30 分钟能开始的小任务？
```

## 产品范围

### 目标创建入口

v1 有两个入口：

- HoloAI 快捷入口 Chip：「规划目标」
- 「个人 > 我的目标」空状态按钮：「让 HoloAI 帮你规划第一个目标」

「个人 > 我的目标」不提供手动新建按钮。空状态入口只负责跳转到 HoloAI 的目标规划流程。

### 创建方式

目标只能由 HoloAI 创建。

流程：

```text
用户进入目标规划
  -> HoloAI 识别目标类型
  -> 最多 3 轮追问
  -> 用户选择精简 / 完整模式
  -> HoloAI 生成 GoalDraft
  -> 用户在确认看板中编辑和勾选
  -> 用户授权保存
  -> 系统写入 Goal、任务、习惯及关联关系
```

### 生成模式

v1 支持两种生成策略，但底层统一输出 `GoalDraft`。

| 模式 | 用途 | 输出倾向 |
|------|------|----------|
| 精简模式 | 用户想快速开始 | 少量高置信任务和习惯 |
| 完整模式 | 用户想要阶段化计划 | 更多阶段任务、持续习惯和复盘节点 |

生成模式不改变数据结构，只影响 AI 生成草案时的密度和拆解粒度。

### 多轮追问

最多追问 3 轮。

追问优先级：

1. 目标结果：用户希望达到什么程度。
2. 动机和用途：为什么要做这个目标。
3. 时间和资源：截止时间、每周投入、已有基础或限制。

如果 3 轮后信息仍不完整，HoloAI 不继续追问，而是生成带不确定项提示的草案，让用户在确认看板中调整。

## 数据模型

### Goal

`Goal` 是结构化持久化实体，建议使用 Core Data 存储。

核心字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `UUID` | 目标唯一 ID |
| `title` | `String` | 目标标题 |
| `summary` | `String?` | 简短说明 |
| `domain` | `String` | 目标领域，如 learning、health、career、finance、life、project |
| `desiredOutcome` | `String?` | 用户希望达到的结果 |
| `motivation` | `String?` | 用户做这个目标的原因 |
| `status` | `String` | active、paused、completed |
| `deadline` | `Date?` | 可选截止日期 |
| `createdAt` | `Date` | 创建时间 |
| `updatedAt` | `Date` | 更新时间 |
| `completedAt` | `Date?` | 完成时间 |
| `source` | `String` | v1 固定为 holoAI |
| `allowAIContext` | `Bool` | 是否允许 HoloAI 后续参考该目标 |
| `lastInsightSummary` | `String?` | 最近一次 AI 目标解释摘要，可选 |

### GoalStatus

```swift
enum GoalStatus: String, Codable {
    case active
    case paused
    case completed
}
```

删除行为不需要在 v1 UI 中展示 `deleted` 状态。实现时可以根据 Core Data 现有风格选择硬删除或软删除，但用户侧表现是目标被移除。

### GoalDomain

v1 可以先用字符串或轻量枚举：

```swift
enum GoalDomain: String, Codable {
    case learning
    case health
    case career
    case finance
    case life
    case project
    case other
}
```

领域主要用于：
- AI 追问策略
- 图标和颜色
- 目标列表筛选或分组
- 后续洞察时的语境判断

### 任务和习惯关联

v1 采用单归属关系。

```text
一个 Goal 可以关联多个 TodoTask
一个 Goal 可以关联多个 Habit
一个 TodoTask 最多属于一个 Goal
一个 Habit 最多属于一个 Goal
```

建议在现有实体上增加可选字段：

| 实体 | 新字段 | 说明 |
|------|--------|------|
| `TodoTask` | `goalId: UUID?` | 所属目标 |
| `Habit` | `goalId: UUID?` | 所属目标 |

v1 不做多对多关系，避免进度重复计算、解除关联复杂化和 UI 解释成本。

### GoalDraft

`GoalDraft` 是 AI 生成后的临时草案，不直接等同于持久化实体。

```swift
struct GoalDraft: Codable, Equatable {
    let id: String
    var title: String
    var summary: String?
    var domain: GoalDomain
    var desiredOutcome: String?
    var motivation: String?
    var deadlineText: String?
    var tasks: [GoalTaskDraft]
    var habits: [GoalHabitDraft]
    var missingInfoWarnings: [String]
}
```

### GoalTaskDraft

```swift
struct GoalTaskDraft: Codable, Equatable, Identifiable {
    let id: String
    var isSelected: Bool
    var title: String
    var dueDateText: String?
    var priority: Int?
    var note: String?
}
```

### GoalHabitDraft

```swift
struct GoalHabitDraft: Codable, Equatable, Identifiable {
    let id: String
    var isSelected: Bool
    var name: String
    var frequency: String
    var targetCount: Int?
    var type: String
    var unit: String?
    var targetValue: Double?
}
```

## AI 架构

### 新增意图

建议新增目标规划相关意图：

| 意图 | 用途 |
|------|------|
| `plan_goal` | 用户表达想建立长期目标或从快捷入口进入规划 |
| `continue_goal_planning` | 目标规划多轮追问中的继续回答 |
| `confirm_goal_plan` | 用户确认保存目标草案 |

如果 v1 希望保持 `AIParseBatch` 不变，也可以先把目标规划视为独立 flow，不走普通 `IntentRouter.route()` 立即执行。

推荐做法：

```text
普通快捷动作：
ChatViewModel -> ConversationCoordinator -> IntentRouter

目标规划：
ChatViewModel -> GoalPlanningCoordinator -> GoalPlanningProvider -> GoalDraftBoard
```

原因：
- 目标规划需要多轮状态。
- 目标规划不会在第一轮直接写库。
- 目标规划输出的是草案和确认看板，不是普通聊天卡片。

### GoalPlanningSession

目标规划需要一个轻量会话状态：

| 字段 | 说明 |
|------|------|
| `id` | 会话 ID |
| `initialUserText` | 用户最初表达 |
| `turnCount` | 已追问轮数 |
| `maxTurns` | v1 固定 3 |
| `answers` | 已收集回答 |
| `mode` | concise 或 complete |
| `status` | collecting、draftReady、confirmed、cancelled |
| `draft` | 当前 GoalDraft |

该会话可以先保存在内存中。若用户退出聊天或 App 被杀，v1 可以丢弃未确认草案，不做复杂恢复。

### 追问策略

不同领域使用不同追问模板。

学习类：
- 想学到什么程度？
- 学习它是为了做什么？
- 当前基础如何，每周能投入多少时间？

健康类：
- 目标是减脂、增肌、改善作息，还是饮食控制？
- 有什么身体限制或饮食禁忌？
- 每周能接受几次运动或记录？

职业类：
- 目标对应什么结果，如求职、晋升、作品集？
- 有没有截止时间？
- 当前已有基础是什么？

项目类：
- 最终交付物是什么？
- 有哪些必须完成的阶段？
- 期望什么时候完成？

### 草案输出规则

HoloAI 输出草案时必须遵守：

- 不直接创建任务或习惯。
- 不生成过多低置信建议。
- 每个任务必须是可执行动作。
- 每个习惯必须有明确频率或目标次数。
- 对不确定信息写入 `missingInfoWarnings`。
- 草案中的任务和习惯默认选中，但用户可以取消。

## 确认看板

确认看板是目标创建前的关键安全层。

### 看板能力

用户可以：
- 编辑 Goal 标题。
- 编辑 Goal 说明。
- 编辑 Goal 领域。
- 编辑可选截止日期。
- 勾选或取消任务草案。
- 编辑任务标题、截止日期、优先级和简短说明。
- 勾选或取消习惯草案。
- 编辑习惯名称、频率、目标次数和类型。
- 选择是否保存目标。
- 选择是否允许 HoloAI 后续参考该目标。

### 看板不支持

v1 不在确认看板中支持：
- 任务附件。
- 复杂提醒设置。
- 多级清单编辑。
- 标签管理。
- 习惯高级统计配置。
- 目标下的多层阶段树。

这些能力可在任务或习惯创建后进入对应模块继续编辑。

### 保存行为

用户点击确认后：

1. 创建 `Goal`。
2. 为选中的 `GoalTaskDraft` 创建 `TodoTask`，并写入 `goalId`。
3. 为选中的 `GoalHabitDraft` 创建 `Habit`，并写入 `goalId`。
4. 保存 `allowAIContext` 授权状态。
5. 在 HoloAI 中展示创建成功结果。
6. 提供跳转到「个人 > 我的目标」或目标详情的入口。

如果任务或习惯部分创建失败，应保留已创建项，并在结果中明确显示失败项。v1 不要求事务级回滚。

## 个人模块 UI

### 入口位置

在「个人」页面新增「我的目标」入口。

入口状态：

- 没有目标：展示空状态和按钮「让 HoloAI 帮你规划第一个目标」。
- 有目标：展示目标数量、进行中数量或最近目标摘要。

### 目标列表

目标列表展示：

- 目标标题
- 目标领域图标
- 状态标签
- 粗粒度进展状态
- 任务完成摘要，如 `任务 4/9`
- 习惯近期摘要，如 `近 14 天 68%`
- 是否允许 AI 上下文的标识

默认排序：

1. active
2. paused
3. completed

同状态内按 `updatedAt` 倒序。

### 目标详情

目标详情展示：

- 标题和说明
- 状态
- 截止日期
- 任务推进情况
- 习惯坚持情况
- AI 进展解释
- 关联任务列表
- 关联习惯列表
- AI 上下文授权开关

操作：

- 暂停
- 恢复
- 标记完成
- 删除目标

删除确认文案：

```text
删除目标后，基于该目标创建的任务和习惯不会被删除，只会解除与该目标的关联。
```

### 创建引导

「个人 > 我的目标」不提供手动新建目标。

空状态或页面右上角可以提供跳转：

```text
去 HoloAI 规划目标
```

跳转后 HoloAI 自动带入目标规划模式，降低用户输入成本。

## 进度模型

目标进度很难被真实量化，因此 v1 不强调精确百分比。

底层可以计算粗略分数，用于排序和状态判断；UI 主要展示可解释的粗粒度状态。

### 数据来源

进度由两部分构成：

- 任务推进情况：目标下任务完成数 / 总任务数。
- 习惯坚持情况：目标下习惯最近 7、14 或 30 天完成率。

默认使用近 14 天习惯完成率，兼顾敏感度和稳定性。

### 综合规则

如果目标同时有关联任务和习惯：

```text
综合分数 = 任务完成率 * 0.5 + 习惯完成率 * 0.5
```

如果只有任务：

```text
综合分数 = 任务完成率
```

如果只有习惯：

```text
综合分数 = 习惯完成率
```

如果既没有任务也没有习惯：

```text
综合状态 = 起步中
```

### 粗粒度状态

| 状态 | 建议条件 | 说明 |
|------|----------|------|
| 起步中 | 任务和习惯数据较少 | 目标刚创建或尚未明显推进 |
| 稳定推进 | 任务有完成，习惯近期较稳定 | 目标正在健康推进 |
| 有些停滞 | 近期任务无推进或习惯完成率低 | 需要提醒或拆小行动 |
| 接近完成 | 大部分任务完成，习惯稳定 | 可以提示用户确认是否完成 |
| 已暂停 | `status == paused` | 不参与 active 目标建议 |
| 已完成 | `status == completed` | 保留历史展示，不再作为 active 上下文 |

### AI 的角色

AI 可以解释状态和给出建议，但不直接决定进度数字，也不自动完成目标。

AI 适合输出：

```text
任务推进良好，但习惯坚持一般。
```

不适合输出：

```text
你已经完成了 53.7%。
```

## 完成、暂停和删除

### 完成

v1 支持用户手动标记完成。

HoloAI 或系统可以在未来提示「建议完成」，但必须由用户确认后才把 `Goal.status` 改为 `completed`。

### 暂停

暂停后的目标：

- 保留所有关联。
- 不出现在 active 目标上下文中。
- 可以在个人目标页恢复。

是否仍进入 AI 上下文：
- 默认不进入。
- 即使 `allowAIContext == true`，`paused` 目标也不主动注入普通聊天上下文。

### 删除

删除目标时：

- 删除 Goal 或将 Goal 从用户可见列表移除。
- 清空关联任务和习惯上的 `goalId`。
- 不删除任何任务。
- 不删除任何习惯。
- 不删除任务完成历史。
- 不删除习惯打卡历史。

## AI 上下文和授权

### 授权原则

保存目标和让 HoloAI 长期参考目标是两件事。

用户确认看板中需要两个明确动作：

- 保存为目标。
- 允许 HoloAI 在后续对话和洞察中参考此目标。

目标详情页也必须提供 `allowAIContext` 开关，用户可以随时撤销。

### 不写入 HoloProfile.md

v1 不把完整目标自动写入 `HoloProfile.md`。

`HoloProfile.md` 继续作为用户长期背景和偏好，例如职业、作息、沟通风格、健康提醒偏好。

目标数据保存在结构化 `Goal` 实体中。

### UserContextBuilder 扩展

`UserContextBuilder` 应动态读取：

- `status == active`
- `allowAIContext == true`

的目标，并拼接为 AI 上下文。

建议上下文格式：

```text
## 当前目标

- 学习 SwiftUI 到能独立开发 App
  - 状态：稳定推进
  - 任务：已完成 4/9
  - 习惯：近 14 天完成率 68%
  - 说明：用户希望用 SwiftUI 独立开发 Holo 功能

- 减脂 5kg
  - 状态：有些停滞
  - 任务：已完成 2/4
  - 习惯：近 14 天完成率 42%
```

为避免 prompt 过长，v1 可以只注入最多 3 个 active 且授权的目标，排序优先级：

1. 最近更新。
2. 有停滞风险。
3. 创建时间较近。

## 与现有 Holo 架构的关系

### HoloAI

现有 HoloAI 已有：

- `AIParseBatch`
- `ConversationCoordinator`
- `IntentRouter`
- 多动作执行结果
- 聊天卡片渲染

目标规划不建议直接塞进普通多动作执行链路。目标规划需要多轮状态和确认看板，应通过独立的 `GoalPlanningCoordinator` 管理。

### 任务模块

任务模块继续负责：

- 任务创建
- 截止日期
- 优先级
- 完成状态
- 任务详情编辑

Goal 只通过 `goalId` 关联任务，不改变任务模块的核心行为。

### 习惯模块

习惯模块继续负责：

- 打卡型习惯
- 数值型习惯
- 频率
- 目标次数
- 打卡记录
- 统计

Goal 只通过 `goalId` 关联习惯，不改变习惯模块的核心行为。

### 个人模块

个人模块新增「我的目标」入口。

这让个人模块从静态档案扩展为：

- 个人资料
- 目标管理
- 长期授权边界

### HoloProfile

HoloProfile 不承担目标系统的结构化存储。

它仍然用于长期用户背景。Goal 上下文由 `UserContextBuilder` 动态注入，便于授权撤销和状态过滤。

## 错误处理

### AI 追问失败

如果目标规划中的 AI 调用失败：

- 展示错误提示。
- 保留用户已输入内容。
- 允许重试。
- 不写入任何目标、任务或习惯。

### 草案解析失败

如果 AI 返回内容无法解析为 `GoalDraft`：

- 展示「计划生成失败，可以重试」。
- 记录 LLM 调用日志。
- 不展示不完整看板。

### 部分保存失败

如果确认保存时部分任务或习惯创建失败：

- 已成功创建的实体保留。
- 失败项在结果中展示。
- Goal 仍然保存。
- 用户可以稍后手动补充任务或习惯。

v1 不要求事务级全量回滚。

## 隐私和安全

- 用户必须明确授权目标进入 AI 上下文。
- 关闭授权后，后续普通聊天和洞察不主动使用该目标。
- 暂停和完成目标默认不进入 active 上下文。
- 删除目标不会删除任务和习惯，避免误删生活数据。
- AI 生成草案必须经过用户确认，不允许直接创建目标、任务或习惯。

## 文件影响范围

### 可能新增

| 文件 | 说明 |
|------|------|
| `Models/Goal+CoreDataClass.swift` | Goal Core Data 实体 |
| `Models/Goal+CoreDataProperties.swift` | Goal 属性扩展 |
| `Models/GoalModels.swift` | GoalStatus、GoalDomain、GoalDraft 等值类型 |
| `Models/GoalRepository.swift` | Goal 读写、统计、关联管理 |
| `Services/AI/GoalPlanningCoordinator.swift` | 目标规划多轮编排 |
| `Services/AI/GoalPlanningPromptBuilder.swift` | 目标规划 prompt |
| `Views/Goals/GoalListView.swift` | 目标列表 |
| `Views/Goals/GoalDetailView.swift` | 目标详情 |
| `Views/Goals/GoalDraftReviewView.swift` | 目标草案确认看板 |

### 可能修改

| 文件 | 说明 |
|------|------|
| `Models/CoreDataStack.swift` | 增加 Goal 实体，给 TodoTask/Habit 增加 goalId |
| `Models/TodoTask+CoreDataProperties.swift` | 增加 goalId 访问 |
| `Models/Habit+CoreDataProperties.swift` | 增加 goalId 访问 |
| `Services/AI/UserContextBuilder.swift` | 注入授权 active Goal 上下文 |
| `Views/Chat/ChatView.swift` | 接入目标规划入口和草案看板 |
| `Views/Chat/QuickActionBar.swift` | 增加「规划目标」快捷入口 |
| `Views/Personal/PersonalView.swift` | 增加「我的目标」入口 |

## 分阶段实施建议

### Phase 1：数据底座和个人目标页

- 新增 Goal 实体。
- 给 TodoTask 和 Habit 增加 `goalId`。
- 新增 GoalRepository。
- 新增「个人 > 我的目标」列表和详情。
- 支持暂停、恢复、完成、删除。
- 删除 Goal 时保留任务和习惯。

### Phase 2：HoloAI 目标规划流程

- 新增 HoloAI 快捷入口「规划目标」。
- 新增 GoalPlanningCoordinator。
- 支持最多 3 轮追问。
- 支持精简 / 完整模式。
- 生成 GoalDraft。

### Phase 3：确认看板和写入

- 新增 GoalDraftReviewView。
- 支持轻量编辑 Goal、任务、习惯关键字段。
- 支持勾选创建项。
- 支持保存目标和 AI 上下文授权。
- 确认后创建 Goal、TodoTask、Habit。

### Phase 4：进度和 AI 上下文

- 实现任务完成率统计。
- 实现习惯近 14 天完成率统计。
- 映射粗粒度状态。
- UserContextBuilder 注入授权 active Goal。
- HoloAI 后续对话和洞察可以参考目标。

## 测试要点

- HoloAI 快捷入口可以进入目标规划流程。
- 个人目标空状态可以跳转到 HoloAI 目标规划。
- 目标规划最多追问 3 轮。
- 精简模式和完整模式都能生成可解析 GoalDraft。
- 草案看板可以编辑 Goal 关键字段。
- 草案看板可以勾选和取消任务、习惯。
- 确认后能创建 Goal、任务和习惯。
- 创建出的任务和习惯写入正确 `goalId`。
- 一个任务或习惯不能同时归属多个 Goal。
- 目标列表展示 active、paused、completed 状态。
- 暂停目标后不进入 active AI 上下文。
- 完成目标必须由用户手动确认。
- 删除目标不删除任务和习惯。
- 删除目标后任务和习惯的 `goalId` 被清空。
- 关闭 `allowAIContext` 后，UserContextBuilder 不注入该目标。
- 打开 `allowAIContext` 后，active 目标可以进入 AI 上下文。
- 没有目标时个人目标页显示空状态和跳转入口。

## 后续预留

- 多目标关联：一个任务或习惯服务多个 Goal。
- 目标建议完成：系统检测接近完成后提示用户确认。
- 目标复盘：按周或月生成目标推进总结。
- 目标模板：学习、健康、考试、项目等常见模板。
- 目标归档：保留已删除或历史目标。
- 更细粒度阶段：在 Goal 下增加 Phase 或 Milestone。

## 关键决策记录

- Goal 放在「个人」下作为独立长期管理模块。
- Goal v1 不能手动创建，只能由 HoloAI 创建。
- HoloAI 入口采用「快捷入口 Chip + 个人目标空状态跳转」。
- 多轮追问上限为 3 轮。
- AI 生成支持精简和完整两种模式。
- 确认看板支持轻量编辑关键字段。
- Goal 与任务/习惯是单归属关系。
- 进度由任务完成情况和习惯近期完成情况共同判断。
- UI 不强调精确百分比，展示粗粒度进展状态。
- 用户手动标记完成，AI 不自动完成目标。
- 删除 Goal 不删除任务和习惯，只解除关联。
- Goal 不自动写入 HoloProfile，AI 上下文由授权 active Goal 动态注入。
