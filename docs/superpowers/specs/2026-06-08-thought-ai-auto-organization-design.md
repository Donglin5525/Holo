# 想法模块 AI 自动整理产品方案

日期：2026-06-08

> **阅读说明**：本文档包含原始方案和四轮对抗性审查补充。标记规则：
> - `🛡️ 对抗性审查新增/修改` = Claude 一轮审查补充（数据模型、核心算法、后端集成、边界场景）
> - `🛡️ 三轮审查新增/修改` = Claude 三轮审查补充（过渡策略、软删除、限流修正、线程安全、算法改进）
> - `🛡️ 五轮审查新增/修改` = Claude 五轮审查补充（organizedStatus 默认值、createdDeviceId、processing 恢复、confirmedAI 显式操作、Core Data 关系表、正文矛盾清理）
> - GPT 二轮、四轮审查结论附在文档末尾，其 P1 问题已在三轮、五轮审查中逐条回应并修正
> - 不带标记的为东林原始方案

## 背景

想法模块当前已经支持手动标签、正文内 `#标签` 提取、标签筛选，以及在 HoloAI / 记忆洞察上下文中读取热门标签。这个能力有价值，但让用户在每篇想法里主动维护标签，本质上是在记录之后再做一次信息档案工作，成本高、连续性差，也容易让用户在表达时被分类任务打断。

本方案将想法模块从“用户手动打标签”升级为“用户负责记录，Holo 负责自动整理”。手动标签继续保留，但不再是主路径。AI 自动整理会为单条想法生成轻量标签，并把多条相关想法聚合成主题，帮助用户回看“最近反复在想什么”。

## 产品目标

1. 用户保存想法后，不需要手动分类，也能获得可搜索、可回看的标签和主题结构。
2. 手动标签、正文内 `#标签` 继续保留，并且优先级高于 AI 自动标签。
3. AI 标签默认直接生效，但用户可以关闭“自动整理想法”。
4. 多条相关想法自动聚合成主题，形成比单条标签更长期的信息线索。
5. 用户可以删除标签、重命名主题、合并主题、隐藏主题，系统从这些修正中学习偏好。
6. AI 调用成本可控，不因打开页面或刷新主题而反复重算。

## 非目标

1. 第一版不做全模块统一自动标签，只覆盖想法模块。
2. 第一版不做复杂知识图谱或跨模块实体网络。
3. 第一版不让 AI 自动改写用户想法原文。
4. 第一版不强制用户确认每个 AI 标签。
5. 第一版不把 AI 标签自动提升为长期记忆。
6. 第一版不在每次打开 App、打开想法模块或打开主题页时全量请求大模型。

## 核心定位

功能命名建议为 **AI 自动整理**，而不是“AI 自动打标签”。

“打标签”更像单条记录的附属动作；“自动整理”更贴近用户真实收益：用户只管记录，Holo 帮用户归类、聚合、回看，并逐渐形成个人信息结构。

## 信息结构

### 标签

标签是单条想法的快速描述，用于搜索、筛选、列表轻量展示和 AI 上下文构建。

第一版规则：

1. 每条想法最多展示 1-2 个列表标签。
2. 详情页最多展示 1-3 个 AI 自动标签。
3. 手动标签和正文内 `#标签` 不受 AI 覆盖。
4. 用户删除过的 AI 标签，不应在类似内容里反复自动加回。

### 主题

主题是多条想法形成的长期线索，用于回答“我最近一直在想什么”。

第一版规则：

1. 一个主题至少关联 2-3 条想法后才正式展示。
2. AI 可以创建候选主题，但候选主题不会立即打扰用户。
3. 用户可以重命名、合并、隐藏主题。
4. 主题页展示相关想法时间线，而不是把主题做成冷冰冰的文件夹。

### 标签与主题的区别

| 类型 | 作用 | 粒度 | 用户感知 |
|------|------|------|----------|
| 标签 | 描述单条想法 | 单条记录 | “这条记录是什么” |
| 主题 | 聚合多条想法 | 多条记录 | “我最近反复在想什么” |

## 数据模型设计

> 🛡️ 对抗性审查新增章节。现有 `ThoughtTag` 只有 `name`/`color`/`usageCount`，无法表达标签来源和 AI 信号；`Topic` 实体不存在。本节确定 v1 的 schema 设计。

### 方向选择

| 方向 | 做法 | 优势 | 代价 |
|------|------|------|------|
| A: ThoughtTag 加 `source` 属性 | 一条 tag name 可能有多条记录 | 简单 | 打破 `getOrCreateTag` 去重逻辑 |
| **B: ThoughtTagAssignment 中间实体**（v1 采用） | thought + tag + source + confidence | 不破坏现有逻辑，扩展性好 | 多对多变两层，查询需 JOIN |
| C: 独立 AITag 实体 | AI 标签与手动标签平行 | 完全隔离 | 两套查询，列表展示需合并 |

**理由**：方向 B 保持 `ThoughtTag` 作为标签名定义表不变，`getOrCreateTag` 逻辑不动；来源、置信度、拒绝信号全部放在中间实体上，扩展新来源类型只需加枚举值。

### Thought（属性新增）

<!-- 🛡️ 三轮审查新增：organizedStatus 存储位置 -->
<!-- 🛡️ 五轮审查修改：organizedStatus 默认值从 pending 改为 unprocessed，避免历史数据自动入队；新增 createdDeviceId 支持多设备策略 -->

Thought 实体需新增 3 个属性，轻量级自动迁移可处理：

| 属性 | 类型 | Optional | 默认值 | 说明 |
|------|------|----------|--------|------|
| `organizedStatus` | String | No | "unprocessed" | 枚举：`unprocessed` / `pending` / `processing` / `organized` / `failed` / `disabled` / `skipped` |
| `createdDeviceId` | String | Yes | nil | 创建该想法的设备 ID（`HoloBackendDeviceIdentity.shared.deviceId`） |
| `organizationStartedAt` | Date | Yes | nil | AI 整理开始时间，用于 processing 超时恢复 |

**`unprocessed` vs `pending` 的区别**：
- `unprocessed`：历史想法（迁移前已存在的），不会自动入队。只有用户触发"整理历史想法"后才批量转为 `pending`。
- `pending`：自动整理开启后本机新创建的想法，或用户手动触发整理的想法。App 启动时队列只处理 `pending` 状态。

**processing 崩溃/重启恢复**：
- App 启动时，将 `organizedStatus == "processing"` 且 `organizationStartedAt` 超过 5 分钟的想法复位为 `pending`。
- 每次进入 processing 时写入 `organizationStartedAt = Date()`，完成后清空。
- 复位后正常进入重试流程（最多 3 次，超限标记 `failed`）。

**`createdDeviceId` 用途**：
- 新建想法时写入 `HoloBackendDeviceIdentity.shared.deviceId`。
- 多设备策略：只自动整理 `createdDeviceId == currentDeviceId` 的想法。
- legacy 想法（`createdDeviceId == nil`）视为历史数据，只能通过"整理历史想法"手动触发。

### ThoughtTagAssignment（新增实体）

| 属性 | 类型 | Optional | 默认值 | 说明 |
|------|------|----------|--------|------|
| `id` | UUID | No | UUID() | 主键 |
| `source` | String | No | "ai" | 枚举：`manual` / `inline` / `confirmedAI` / `ai` / `rejectedAI` |
| `confidence` | Double | No | 1.0 | AI 置信度（0-1），手动来源为 1.0 |
| `assignedAt` | Date | No | Date() | 分配时间 |
| `rejectedAt` | Date | Yes | nil | 用户拒绝时间（仅 rejectedAI 有值） |

关系：
- `thought` → Thought（多对一，**cascade** delete）
- `tag` → ThoughtTag（多对一，**nullify** delete）

### Topic（新增实体）

| 属性 | 类型 | Optional | 默认值 | 说明 |
|------|------|----------|--------|------|
| `id` | UUID | No | UUID() | 主键 |
| `title` | String | No | "" | 主题名 |
| `summary` | String | Yes | nil | AI 生成的一句话摘要 |
| `status` | String | No | "candidate" | 枚举：`candidate` / `active` / `hidden` / `merged` |
| `confidence` | Double | No | 0.0 | 聚合置信度 |
| `associatedTagNames` | String | Yes | nil | 关联标签名（逗号分隔，仅展示用） |
| `thoughtCount` | Int16 | No | 0 | 关联想法数（冗余计数） |
| `createdAt` | Date | No | Date() | 首次候选时间 |
| `updatedAt` | Date | No | Date() | 最近更新时间 |

<!-- 🛡️ 三轮审查修改：mergedToTopicId 从 UUID 属性改为 Core Data 关系，保证引用完整性 -->

关系：
- `thoughts` → Thought（多对多，**nullify** delete，inverse: `topics`）
- `mergedToTopic` → Topic（多对一，**nullify** delete，self-referencing，inverse: `mergedFromTopics`）

<!-- 🛡️ 三轮审查修改：associatedTagNames 保留为展示缓存，但正式标签关联改为 Topic → ThoughtTag 多对多关系 -->

补充关系：
- `associatedTags` → ThoughtTag（多对多，**nullify** delete，inverse: `associatedTopics`）

`associatedTagNames` 保留为冗余缓存字段用于快速展示，但标签的增删维护走 `associatedTags` 关系，避免逗号字符串拆分/拼接的维护成本。

### Core Data 关系完整表

<!-- 🛡️ 五轮审查新增：补齐所有 inverse、delete rule、class 文件 -->

| 源实体 | 关系名 | 目标实体 | 类型 | Delete Rule | Inverse |
|--------|--------|----------|------|-------------|---------|
| Thought | `tags` | ThoughtTag | 多对多 | nullify | `thoughts` |
| Thought | `tagAssignments` | ThoughtTagAssignment | 一对多 | cascade | `thought` |
| Thought | `topics` | Topic | 多对多 | nullify | `thoughts` |
| ThoughtTag | `thoughts` | Thought | 多对多 | nullify | `tags` |
| ThoughtTag | `assignments` | ThoughtTagAssignment | 一对多 | cascade | `tag` |
| ThoughtTag | `associatedTopics` | Topic | 多对多 | nullify | `associatedTags` |
| ThoughtTagAssignment | `thought` | Thought | 多对一 | nullify | `tagAssignments` |
| ThoughtTagAssignment | `tag` | ThoughtTag | 多对一 | nullify | `assignments` |
| Topic | `thoughts` | Thought | 多对多 | nullify | `topics` |
| Topic | `associatedTags` | ThoughtTag | 多对多 | nullify | `associatedTopics` |
| Topic | `mergedToTopic` | Topic | 多对一 | nullify | `mergedFromTopics` |
| Topic | `mergedFromTopics` | Topic | 一对多 | nullify | `mergedToTopic` |

**新增 class 文件**：
- `ThoughtTagAssignment+CoreDataClass.swift` + `ThoughtTagAssignment+CoreDataProperties.swift`
- `Topic+CoreDataClass.swift` + `Topic+CoreDataProperties.swift`
- `Thought+CoreDataProperties.swift` 新增 `@NSManaged tagAssignments`、`@NSManaged topics`、`@NSManaged organizedStatus`、`@NSManaged createdDeviceId`、`@NSManaged organizationStartedAt`
- `ThoughtTag+CoreDataProperties.swift` 新增 `@NSManaged assignments`、`@NSManaged associatedTopics`

### 迁移影响

- `ThoughtTagAssignment` 和 `Topic` 均为全新实体，**无需数据迁移**
- `Thought` 需新增 `topics` 关系（对向 Topic.thoughts），轻量级自动迁移可处理
- `ThoughtTag` 保持不变
- 新增编程式定义在 `CoreDataStack+ThoughtEntities.swift`

### 查询路径变化

| 场景 | 现有方式 | 改造后 |
|------|----------|--------|
| 列表卡片标签 | `thought.tags.prefix(2)` | `thought.tagAssignments.filter(非 rejected).sorted(by: 优先级).prefix(2).tag.name` |
| 详情页 AI 归类 | 不存在 | `thought.tagAssignments.filter(source == ai \|\| confirmedAI)` |
| 分析上下文 topTags | `getTopTags()` 全量统计 | `getTopTags()` 统计 `manual + inline + confirmedAI`，未确认 `ai` 不参与（见"AI 标签与手动标签的隔离"章节） |
| 主题关联想法 | 不存在 | `topic.thoughts.sorted(by: createdAt)` |

### Thought.tags → ThoughtTagAssignment 过渡策略

<!-- 🛡️ 三轮审查新增：GPT 二轮 P1-#1 和三轮审查共同确认的兼容性缺口 -->

**问题**：当前 `saveThought()` → `repository.update(tags:[String])` → `getOrCreateTag` → `thought.addTags(tag)` 全链路写 `Thought.tags`。所有 UI（列表、详情、搜索、自动补全、getTopTags）也读 `Thought.tags`。只加 assignment 而不改旧路径 = 两套数据源。

**v1a 过渡策略**：

1. **一次性 backfill**：首次启动（检测 migration flag），遍历所有 Thought，对每条想法的 `thought.tags` 创建 `ThoughtTagAssignment(source: "manual", confidence: 1.0)`。inline 来源无法回溯，统一标为 `manual`。
2. **双写期**：v1a 中 `saveThought()` / `repository.create/update` **同时写** `Thought.tags`（兼容旧 UI）和 `ThoughtTagAssignment`（新数据源）。AI 标签只写 assignment，不写 `Thought.tags`。
3. **读取切换**：v1a 中 UI 展示优先读 `ThoughtTagAssignment`，回退读 `Thought.tags`。`getTopTags()` 切换为只统计 `assignment.source == manual || inline`。
4. **v1b 清理**：v1b 稳定后，`Thought.tags` 降级为 legacy，新代码不再写入。最终版本移除双写。

**saveThought 签名变更**：当前 `repository.create(content:mood:tags:)` 接收合并后的 `[String]`。需改为 `create(content:mood:manualTags:inlineTags:)`，repository 内部分别创建 `manual` 和 `inline` source 的 assignment。`selectedTags + inlineTags` 的合并逻辑保留（去重），但 source 标记分开。

### 软删除、归档与新增实体

<!-- 🛡️ 三轮审查新增：GPT 二轮 P1-#2 和三轮审查共同确认 -->

**问题**：`ThoughtRepository.delete()` 是软删除（`isSoftDeleted = true`），不触发 Core Data cascade delete rule。`ThoughtTagAssignment` 的 cascade 永远不会触发，导致：
- 主题 `thoughtCount` 包含已删除想法
- 主题页时间线展示软删除想法
- 历史整理对已删除内容重复处理

**修正策略**：

1. 所有 Topic 查询（计数、升级、摘要、时间线）**必须** filter `thought.isSoftDeleted == false && thought.isArchived == false`。
2. 软删除 / 归档时，触发相关 Topic 的 `thoughtCount` 重算（通过 `thoughtDataDidChange` 通知）。
3. `deleteAllThoughtData()` 必须覆盖新增实体：删除列表改为 `["ThoughtReference", "ThoughtTagAssignment", "Topic", "Thought", "ThoughtTag"]`。
4. **硬删除**（`hardDelete()`）正常触发 cascade，assignment 会被自动清理，无需额外处理。

### 多设备去重策略（简化版）

<!-- 🛡️ 三轮审查修改：原方案"取并集展示"太复杂，改为只整理本机创建的想法 -->
<!-- 🛡️ 五轮审查修改：补齐数据依据，新增 Thought.createdDeviceId 字段 -->

**v1 策略更新**：每台设备**只整理 `createdDeviceId == currentDeviceId` 且尚未有 AI assignment 的想法**。

具体规则：

1. 新建想法时写入 `thought.createdDeviceId = HoloBackendDeviceIdentity.shared.deviceId`。
2. 自动整理前检查：`thought.createdDeviceId == currentDeviceId` 且 `organizedStatus == pending`。
3. legacy 想法（`createdDeviceId == nil`）不自动整理，只能通过"整理历史想法"手动触发。
4. iCloud 同步后，assignment 自然同步，展示层不区分来源设备。
5. `rejectedAI` assignment 同步，展示层统一隐藏。
6. 展示层对同一想法的 AI 标签做轻量去重（同名同 source 只展示一条），防止同步竞态产生重复。

**理由**：比"取并集 + dedup key + 冲突处理"简单得多，且避免了重复消耗 token。代价是只有本机保存的想法会被 AI 处理——如果用户只在 iPhone 上记录但在 iPad 上查看，iPad 上也能看到 AI 标签（通过 iCloud 同步 assignment）。

## 用户体验

### 设置入口

在设置页新增独立分区：**AI 整理**。

建议位置：`AI 回放` 和 `AI 记忆` 之间。

<!-- 🛡️ 对抗性审查修改：原方案建议放在 iCloud 同步之后、AI 回放之前，审查后调整到三个 AI 分区紧凑排列 -->

理由：

1. `AI 整理` 负责日常信息组织。
2. `AI 回放` 负责周期总结。
3. `AI 记忆` 负责长期偏好和模式。

三者按"整理 → 总结 → 记忆"递进排列，且集中在同一个 AI 能力区域内，避免和 iCloud 同步混在一起让用户困惑。

> 注：当前设置页结构为 iCloud 同步 → AI 回放 → AI 记忆 → 存储。将 AI 整理插入 AI 回放和 AI 记忆之间，三个 AI 分区紧凑排列。

#### 设置项 1：自动整理想法

标题：`自动整理想法`

副标题：

开启时：`保存想法后，AI 会自动生成标签和主题，可随时编辑`

关闭时：`已关闭，手动标签和正文 #标签 仍会保留`

默认值：开启。

首次使用前展示一次轻说明：

标题：`开启 AI 自动整理？`

说明：`Holo 会在你保存想法后，为内容生成标签和主题，用于搜索、回看和 AI 分析。你可以随时关闭，手动标签不会受影响。`

按钮：`开启` / `暂不开启`

#### 设置项 2：整理历史想法

标题：`整理历史想法`

副标题：`分批分析已有想法，生成标签和主题`

点击后进入说明页，不直接静默开始。

说明页文案：

标题：`整理历史想法`

说明：`Holo 会分批分析你的历史想法，生成标签和主题。原文不会被修改，手动标签会保留。`

按钮：`开始整理`

整理过程中显示进度：`已整理 12 / 48 条`

失败时不终止全部任务，提示：`部分想法暂未整理，可稍后继续`

<!-- 🛡️ 对抗性审查新增：成本提示 -->
<!-- 🛡️ 三轮审查修改：去掉硬编码金额，改为描述性文案，避免 provider 价格变更后失真 -->

成本提示（说明页底部小字）：`将分批使用 AI 处理，每批间隔 2 秒，可在后台进行。AI 处理会产生少量调用成本。`

### 想法模块入口

想法模块内保留一个轻量状态入口，但不放主开关。

例如在想法首页右上角使用 `sparkles` 或 `slider.horizontal.3` 图标，点击后进入智能整理状态页或跳转设置页。

状态文案：

`AI 自动整理已开启`

按钮：

`管理设置`

这样用户在想法模块里能找到整理能力，但真正的全局控制仍然归到设置页。

### 想法首页结构

想法首页采用顶部 Tab：

`全部 / 主题`

<!-- 🛡️ 对抗性审查新增：分阶段实施标注，避免 Tab 改造阻塞 AI 标签功能 -->

> **分阶段实施**：v1a 先在现有列表结构上增加 AI 标签展示能力（不改 Tab 结构），v1b 再实施顶部 Tab 改造和主题 Tab。理由：当前 `ThoughtsView` 是底部 Tab 栏（列表 + 新增），改为顶部 Tab 涉及整体布局重构，应与 AI 标签功能解耦。

#### 全部

继续以想法列表为主。每张卡片最多轻量展示 1-2 个 AI 标签，避免列表变成标签墙。

<!-- 🛡️ 对抗性审查修改：原方案直接叠加 AI 标签，审查后改为互斥展示（有手动标签时不叠加 AI 标签） -->

卡片展示策略：

1. 如果想法有手动标签 → 展示手动标签，**不叠加** AI 标签。
2. 如果想法无手动标签，有 AI 标签 → 展示 1-2 个 AI 标签（灰色/浅色区分）。
3. 不做"手动标签 + AI 标签"的双行展示，避免卡片信息过载。

卡片展示示例：

`产品思考 · HoloAI`（手动标签，主色调）

或

`产品思考 · HoloAI`（AI 标签，灰色调）

如果 AI 正在整理，可以短暂显示：

`AI 正在整理...`

整理失败不弹窗，不影响想法本体。

#### 主题

主题 Tab 展示 AI 聚合出的主题簇。

如果没有主题，展示空状态：

标题：`还没有整理出主题`

说明：`可以让 Holo 分析已有想法，帮你找出最近反复出现的方向。`

按钮：`整理历史想法`

这个入口与设置页入口并存：设置页是长期入口，主题空状态是首次引导入口。

### 想法详情页

详情页展示三块信息：

1. 手动标签：用户手动添加或正文内 `#标签`，最高优先级。
2. AI 归类：AI 自动生成的标签，可删除或编辑。
3. 所属主题：AI 归纳出的主题，可进入主题页。

示例：

`AI 归类：产品思考 · HoloAI · 信息架构`

`所属主题：更懂用户的智能体`

如果用户删除某个 AI 标签，系统记录为拒绝信号，后续类似内容不应反复自动添加。

### 主题页

主题页重点是帮助用户理解一个长期线索，而不是做传统文件夹。

页面包含：

1. 主题名。
2. AI 生成的一句话摘要。
3. 相关想法数量。
4. 最近更新时间。
5. 相关想法时间线。
6. 关联标签。
7. 操作：重命名、合并、隐藏、重新整理。

示例：

主题名：`更懂用户的智能体`

摘要：`你最近多次在思考 HoloAI 如何从记录工具进化为理解个人状态和长期偏好的智能体。`

## 工作流

### 新想法保存

1. 用户保存想法。
2. 想法立即保存成功并进入列表。
3. 如果“自动整理想法”开启，后台进入整理流程。
4. AI 返回标签和候选主题。
5. AI 标签直接生效。
6. 候选主题先匹配已有主题。
7. 匹配不上时进入候选池。
8. 候选池中同类内容达到阈值后，正式生成主题。

保存动作不等待 AI。AI 失败不影响想法本体。

### 想法编辑与更新策略

> 🛡️ 对抗性审查新增。方案原只描述了"新想法保存"流程，缺少编辑场景的策略。

v1 策略：**仅在首次创建时分析，编辑不自动重新分析。**

具体规则：

1. 想法首次保存 → 触发 AI 整理流程。
2. 用户编辑内容 → **不**自动重新分析 AI 标签，保留已有 AI 标签。
3. 用户手动删除 AI 标签 → 记录 rejectedAI 信号，标签从展示中移除。
4. 用户希望重新分析 → 在详情页提供手动"重新整理"按钮，点击后清除旧 AI 标签并重新触发。
5. 用户手动添加标签 → 不影响 AI 标签，两种来源独立共存。

不做编辑后自动重新分析的原因：
- 避免用户刚删掉的 AI 标签编辑后又被加回来。
- 避免 AI 标签频繁变化导致用户失去对"我的标签是什么"的掌控感。
- 降低 AI 调用频率和成本。

### 状态机

单条想法整理状态：

| 状态 | 含义 | 用户可见性 |
|------|------|------------|
| `unprocessed` | 历史数据，迁移默认值 | 无提示，不入自动队列 |
| `pending` | 待整理（本机新建或用户手动触发） | 可选轻提示 |
| `processing` | AI 整理中 | 卡片可显示”AI 正在整理...” |
| `organized` | 已生成标签/主题候选 | 展示标签 |
| `failed` | 整理失败 | 不弹窗，可在详情或诊断中查看 |
| `disabled` | 自动整理关闭 | 不触发 AI |
| `skipped` | 跳过 AI 整理 | 不展示，等同于 disabled |

<!-- 🛡️ 对抗性审查新增：skipped 状态，避免内容过短或已有足够手动标签时浪费 AI 调用 -->
<!-- 🛡️ 五轮审查修改：新增 unprocessed 状态，区分历史数据和本机新建数据 -->

`unprocessed`：迁移默认值，历史想法的状态。只有用户触发”整理历史想法”才批量转为 `pending`。App 启动队列不处理 `unprocessed`。

`skipped` 触发条件：用户已手动添加 ≥3 个标签，或想法内容长度 < 10 字（内容过短不值得分析）。跳过 AI 调用，节省成本。

### 主题状态

| 状态 | 含义 | 展示策略 |
|------|------|----------|
| `candidate` | 候选主题，证据不足 | 默认不展示 |
| `active` | 已有关联想法达到阈值 | 展示在主题 Tab |
| `hidden` | 用户隐藏 | 不展示，但保留关联 |
| `merged` | 已被合并到其他主题 | 跳转到目标主题或不展示 |

### 主题聚合算法

> 🛡️ 对抗性审查新增。方案原文"候选池中同类内容达到阈值后正式生成主题"缺少算法定义。

v1 采用简化策略，不依赖二次 LLM 调用：

<!-- 🛡️ 三轮审查修改：GPT 二轮指出纯 Jaccard 对中文短标题匹配脆弱，改为 LLM 直接输出 matchedTopicId + 本地保守兜底 -->

**匹配规则**：

1. 每条想法整理时，prompt 同时提供已有 active 主题列表（`id + title`），要求 LLM 输出 `matchedTopicId`（匹配已有）或 `null`（新主题）。
2. LLM 返回 `matchedTopicId` → 直接关联到该 active 主题，更新 `thoughtCount` 和 `updatedAt`。
3. LLM 返回 `null` → 用 `topicCandidate.title` 做 Jaccard 字符相似度兜底匹配（分词后计算交集/并集比，阈值 ≥ 0.6）。
4. Jaccard 也匹配不上 → 进入候选池，创建 `candidate` 主题。

**优势**：LLM 对近义中文标题的理解远好于字符相似度（如"更懂用户的智能体" vs "HoloAI 理解用户"），Jaccard 只作为低成本兜底。不增加额外 LLM 调用——匹配逻辑嵌入在同一次 thought_organization 请求中。

**candidate → active 升级条件**：

- 关联想法数 ≥ 3 条。
- 最近 7 天内有 ≥ 2 条新关联。

同时满足时，`candidate` → `active`，生成摘要。

**摘要生成**：仅在 `candidate` → `active` 转换时调用一次 LLM 生成摘要。后续新增想法不自动刷新摘要，用户可在主题页手动触发"重新整理"。

**刷新时机**：不实时刷新。在"主题延迟刷新"窗口中批量处理（累计 N 条新整理后，或每天首次打开 App 时）。

**合并操作 UX**：

1. 用户在主题页选择两个主题合并。
2. 合并后：想法全部迁移到目标主题，源主题 `status = merged`，`mergedToTopicId` 指向目标。
3. 标签取并集。
4. 摘要保留目标主题的，用户可重新生成。
5. v1 不支持撤销合并（操作前弹确认弹窗）。

### 离线与失败处理

> 🛡️ 对抗性审查新增。方案定义了 `failed` 状态但缺少重试和离线策略。

**重试策略**：

| 规则 | 说明 |
|------|------|
| 最大重试次数 | 3 次 |
| 重试间隔 | 指数退避：5s → 30s → 120s |
| 超限处理 | 标记为 `failed`，不再自动重试 |
| 手动恢复 | 用户可在详情页点击"重新整理"手动触发 |

**离线处理**：

1. 想法保存后标记为 `pending`。
2. AI 调用失败（网络超时、无连接）→ 标记 `pending`，不立即标记 `failed`。
3. App 回到前台时，检查 `pending` 队列，按 `createdAt` 排序，依次重试。
4. 后台保存的想法：iOS 不保证后台执行完成。如果 AI 调用未发出，下次 App 前台时补发。

**队列管理**：

1. 最多同时 1 个 AI 整理请求（串行，避免并发消耗）。
2. 队列存储在内存中（不持久化，App 重启后从 `organizedStatus == pending` 的想法重建队列）。
3. 队列只处理 `createdDeviceId == currentDeviceId` 的想法，不处理 legacy `unprocessed` 想法。
4. 历史整理的批量请求走独立队列，与实时请求互不干扰。

<!-- 🛡️ 五轮审查新增：processing 崩溃恢复 -->

**processing 超时恢复**：

1. App 启动时，查询 `organizedStatus == "processing"` 的所有想法。
2. 对每条检查 `organizationStartedAt`：超过 5 分钟 → 复位为 `pending`（正常重试）。
3. 复位后进入正常队列流程，受 3 次重试上限约束。
4. 如果想法已重试 3 次仍失败，标记为 `failed`，不再自动重试。

### 线程安全与 Core Data 边界

<!-- 🛡️ 三轮审查新增：后台整理涉及跨线程 Core Data 访问风险 -->

1. AI 请求队列**只传 `thoughtId`（UUID）和纯值 DTO**，不跨线程持有 `Thought` NSManagedObject。
2. Core Data 写回（更新 organizedStatus、创建 ThoughtTagAssignment）通过主线程 context 的 `perform` 完成。
3. 历史整理批处理如果使用 background context，必须在离开 context 前映射为 DTO，让 viewContext merge。

### 搜索覆盖

<!-- 🛡️ 三轮审查新增：AI 标签是否参与搜索未定义 -->

v1 策略：AI 标签**不参与搜索**。`ThoughtRepository.search()` 继续只搜 `content` 和手动标签（`Thought.tags`）。理由：
- 搜索结果是用户主动查找的场景，手动标签更可靠。
- 避免 AI 标签引入噪音搜索结果。
- 搜索逻辑不需要立即改造，降低 v1a 工程量。

## AI 调用与 token 成本

总体原则：

**单条实时，主题延迟，历史手动，全部缓存。**

### 单条实时

新想法保存后，只发送当前想法内容，以及少量已有主题名和用户偏好摘要。

不发送全部历史想法全文。

预期单次请求：

1. 输入：当前想法正文、最近活跃主题摘要、用户标签偏好摘要。
2. 输出：1-3 个标签、1 个候选主题、置信度、简短理由。

这样 token 成本随单条想法长度增长，而不是随历史总量增长。

### 主题延迟

主题 Tab 只读缓存，不在每次打开时请求大模型。

主题聚合低频增量刷新：

1. 累计若干条新想法后刷新。
2. 每天第一次打开 App 时可尝试刷新。
3. 只处理新增想法、候选主题和最近活跃主题。
4. 不全量重算历史。

### 历史手动

历史整理由用户主动触发。

触发入口：

1. `设置 -> AI 整理 -> 整理历史想法`
2. `想法 -> 主题` 空状态 -> `整理历史想法`

历史整理需要分批处理，展示进度，支持失败后继续。

### 全部缓存

AI 返回的标签、候选主题、主题摘要和整理状态都需要缓存。

进入主题页、列表页、详情页时优先读取缓存，不触发实时重算。

### 成本估算

> 🛡️ 对抗性审查新增。方案原文声明"成本可控"但无具体数字。

**单条想法实时整理**：

| 项目 | 估算 |
|------|------|
| 输入 token | ~200-400（想法正文 + prompt + 活跃主题 + rejected 标签） |
| 输出 token | ~100-150（1-3 标签 + 1 主题候选） |
| 单次成本（DeepSeek） | ¥0.001-0.003 |
| 单次成本（Qwen） | ¥0.002-0.005 |

**月度成本（活跃用户）**：

| 使用量 | DeepSeek | Qwen |
|--------|----------|------|
| 30 条/月 | ¥0.03-0.09 | ¥0.06-0.15 |
| 100 条/月 | ¥0.10-0.30 | ¥0.20-0.50 |
| 300 条/月 | ¥0.30-0.90 | ¥0.60-1.50 |

**历史整理**：100 条想法 ≈ ¥0.10-0.50（一次性成本）。

**结论**：单条成本极低，月度成本可接受。风险不在单价而在调用量失控——需靠后端 rate limit 和 iOS 端 skipped 状态控制。

## 后端集成设计

> 🛡️ 对抗性审查新增。现有后端定义了 7 种 purpose（chat/intent/insight/thought_voice_summary/memory_observer/finance_action_parser/task_action_parser），**没有想法自动整理的 purpose**。本节补齐。

### 新增 purpose：thought_organization

**后端路由配置**（`config.js`）：

```javascript
thought_organization: {
  provider: env.THOUGHT_ORG_PROVIDER || 'deepseek',
  model: env.THOUGHT_ORG_MODEL || 'deepseek-chat',
  temperature: 0.2,
  maxTokens: 512
}
```

**iOS 端**：

- `HoloBackendPurpose` 枚举新增 `thoughtOrganization` case
- `PromptManager.swift` 新增 `thoughtOrganization` PromptType
- 调用时 `purpose: "thought_organization"`, `response_format: { type: "json_object" }`

### 限流配置

<!-- 🛡️ 三轮审查修改：原方案声称 per-purpose 独立限额，但后端实际所有 AI purpose 共享 chatRequestsPerMinute:20 / chatRequestsPerDay:50 -->

**当前后端现状**：所有 AI purpose 共享 `chatRequestsPerMinute: 20` 和 `chatRequestsPerDay: 50`，只按 purpose 分 key 计数但限额阈值相同。

**v1 策略（不改后端）**：`thought_organization` 使用现有的 chat 限额（20/min, 50/day）。iOS 端做客户端节流：
- 实时整理：每条想法间隔 ≥2 秒
- 历史整理：每批 10 条，间隔 2 秒，每天最多整理 50 条（避免占满 chat quota 影响正常 HoloAI 对话）
- 历史整理优先在 App 前台且无活跃对话时运行

**v2 可选改进**：后端 `config.routes` 增加 `minuteLimit` / `dailyLimit` 字段，支持 per-purpose 独立限额。

### Prompt 模板骨架

> v1 完整 prompt 在实施时细化，此处给出骨架。

**系统 prompt 结构**：

```
你是一个想法整理助手。用户会给你一条想法的原文，你需要：
1. 为这条想法生成 1-3 个简短标签（每个标签 2-6 个字）
2. 判断这条想法可能属于哪个长期主题

## 标签规则
- 标签应该是内容关键词，不是情感分类
- 避免过于宽泛的标签（如"生活""思考""日常"）
- 参考已有标签风格：{{existingTagExamples}}
- 不要生成以下标签（用户已拒绝）：{{rejectedTags}}

## 主题规则
- 主题名应该是 4-10 字的描述短语
- 参考已有主题（如果语义匹配，输出 matchedTopicId）：
  {{activeTopics}}

<!-- 🛡️ 三轮审查修改：增加 matchedTopicId 输出字段，让 LLM 直接做主题匹配而非依赖字符串相似度 -->

## 输出格式
严格输出 JSON：
{
  "suggestedTags": ["标签1", "标签2"],
  "topicCandidate": {
    "title": "主题名",
    "confidence": 0.85
  },
  "matchedTopicId": "uuid-or-null",
  "reason": "一句话理由"
}
```

**输入变量**：

| 变量 | 来源 | 示例 |
|------|------|------|
| `{{thoughtContent}}` | 当前想法正文 | "HoloAI 应该能理解用户的长期偏好..." |
| `{{existingTagExamples}}` | 最近 20 条手动标签（`ThoughtTag` 按 usageCount 降序） | "工作, 产品, HoloAI, 灵感" |
| `{{rejectedTags}}` | 最近 20 条 rejectedAI 标签名 | "焦虑, 日常, 想法" |
| `{{activeTopics}}` | 当前 active 主题的 `id + title` 列表（JSON 格式） | `[{"id":"uuid1","title":"更懂用户的智能体"}, ...]` |

### Prompt 双端同步

根据 CLAUDE.md 的 Prompt 双端同步规则，实施时必须：

1. iOS `PromptManager.swift` 新增 `thoughtOrganization` 模板（后备）
2. 后端 `defaultPrompts.json` 新增 `thought_organization` prompt（生效端）
3. 升级 `PromptManager.promptVersions` 版本号
4. **重新部署 Docker 镜像**：`docker compose build --no-cache && docker compose up -d`

### 主题摘要生成 Prompt（单独 purpose 或复用）

主题从 `candidate` → `active` 时需要生成一句话摘要。v1 复用 `thought_organization` purpose，输入改为主题关联的多条想法摘要 + 主题标题，输出只要求 summary 字段。不新增独立 purpose，避免增加后端配置复杂度。

## 数据语义

### 标签来源

标签必须区分来源，不能只存一个字符串数组。

建议来源：

| 来源 | 说明 | 优先级 |
|------|------|--------|
| `manual` | 用户手动添加 | 最高 |
| `inline` | 正文内 `#标签` 自动提取 | 最高 |
| `confirmedAI` | 用户保留或确认过的 AI 标签 | 高 |
| `ai` | AI 自动生成 | 中 |
| `rejectedAI` | 用户删除过的 AI 标签 | 负向信号 |

<!-- 🛡️ 三轮审查新增：confirmedAI 自动升级规则 -->
<!-- 🛡️ 五轮审查修改：去掉自动升级（"展示满7天"无法可靠判定），改为显式用户操作 -->

**confirmedAI 产生方式**：v1 仅通过用户**显式操作**产生——在详情页 AI 归类区域，每个 AI 标签旁提供"保留"操作。用户点击后，`source` 从 `ai` 改为 `confirmedAI`。不做自动升级。理由：自动升级依赖"展示过"的判定，但 AI 标签只在无手动标签时才展示，无法可靠追踪曝光。显式操作虽然增加了用户步骤，但保证了 confirmedAI 的可信度——用户真的看过且认可。

用户界面不一定要展示来源，但数据层必须保留来源，否则很难处理“用户删掉后 AI 又加回来”的问题。

### 用户偏好学习

第一版不做复杂训练，只记录轻量偏好：

1. 用户把 `AI` 改成 `HoloAI`。
2. 用户经常删除 `焦虑`。
3. 用户把两个主题合并成 `产品方向`。
4. 用户隐藏了某类主题。

后续自动整理时，把这些偏好压缩成简短摘要传给模型。

#### rejectedAI 标签学习机制

> 🛡️ 对抗性审查细化。原文"不应在类似内容里反复自动加回"缺少实现细节。

**存储方式**：在 `ThoughtTagAssignment` 中保留 `source = rejectedAI` + `rejectedAt` 记录。同时维护一个 UserDefaults 轻量索引 `rejectedAITags: [(name: String, rejectedAt: Date)]`，用于快速查询而无需 Core Data 查询。

**匹配策略**：v1 使用 **exact match**（精确匹配标签名）。不接受语义匹配（如"焦虑"≠"焦虑情绪"），理由是语义匹配需要额外 LLM 调用，成本不合理。

**遗忘机制**：rejected 记录超过 **90 天**自动遗忘（从 UserDefaults 索引中移除）。长期不重复拒绝的标签说明偏好已变化。

**传给 Prompt 的格式**：取最近 20 条未过期的 rejected 标签名，作为 `{{rejectedTags}}` 变量注入。prompt 中指令为"不要生成以下标签"。

**容量控制**：UserDefaults 索引最多保留 50 条。超出时按 `rejectedAt` 排序淘汰最旧的。

### AI 输出建议

单条想法整理输出可以采用结构化 JSON：

```json
{
  "suggestedTags": ["产品思考", "HoloAI", "信息架构"],
  "topicCandidate": {
    "title": "更懂用户的智能体",
    "summary": "关于 HoloAI 如何理解用户长期状态和偏好的产品思考",
    "confidence": 0.82
  },
  "matchedTopicId": null,
  "confidence": 0.86,
  "reason": "内容讨论 HoloAI、个人信息整理和长期主题归纳"
}
```

需要有轻量校验：

1. 标签数量超过 3 个时截断。
2. 标签为空时不展示。
3. 置信度过低时只进入候选，不直接展示。
4. 输出解析失败时标记整理失败，不影响想法保存。

### iCloud 同步策略

> 🛡️ 对抗性审查新增。项目使用 `NSPersistentCloudKitContainer`，新增实体会自动同步到 iCloud，但 AI 处理是设备级的。

<!-- 🛡️ 三轮审查修改：原方案"取并集展示"策略复杂且缺少去重键，改为"只整理本机创建" -->
<!-- 🛡️ 五轮审查修改：补齐 createdDeviceId 数据依据 -->

**v1 策略：AI 标签和主题同步到 iCloud，每台设备只整理 `createdDeviceId == currentDeviceId` 的想法。**

具体规则：

1. `ThoughtTagAssignment` 和 `Topic` 作为 Core Data 实体，跟随 iCloud 自动同步。
2. 自动整理条件：`thought.createdDeviceId == currentDeviceId` 且 `organizedStatus == pending`。
3. legacy 想法（`createdDeviceId == nil`）不自动整理，只能通过"整理历史想法"手动触发。
4. `rejectedAI` assignment 同步。展示层统一隐藏被拒绝的标签。
5. rejectedAI 偏好（UserDefaults）**不同步**。每台设备有独立的拒绝记录。
6. Topic 合并/隐藏操作**同步**。在任一设备上操作，另一台生效。
7. 展示层对同一想法的 AI 标签做轻量去重（同名同 source 只展示一条）。

**为什么不选择"取并集展示"**：两台设备各自对同一想法调用 AI，产生不同标签，需要去重键和冲突合并逻辑，实现复杂且会重复消耗 token。改为"只整理本机创建"从源头避免重复。

**为什么不选择"AI 数据不同步"**：如果 AI 标签不同步，用户在 iPad 上看不到 iPhone 上已生成的标签，体验割裂。且 Core Data 实体默认同步，单独关闭某个实体的同步需要额外处理。

### AI 标签与手动标签的隔离

> 🛡️ 对抗性审查新增。防止 AI 生成的低质量标签污染分析上下文。

<!-- 🛡️ 三轮审查修改：原策略"AI 标签完全不进分析上下文"过于激进，与产品目标"为 HoloAI 提供结构化输入"冲突。调整为分层策略。 -->

核心原则：**未确认 AI 标签不进原有 topTags；确认标签和主题摘要可进入独立 AI 上下文。**

| 查询场景 | 使用数据源 | 说明 |
|----------|-----------|------|
| 列表卡片展示标签 | `ThoughtTagAssignment`（所有 source） | 展示时按优先级：manual > inline > confirmedAI > ai |
| 详情页 AI 归类 | `ThoughtTagAssignment`（ai + confirmedAI） | 独立区域展示 |
| `getTopTags()` 分析上下文 | `ThoughtTagAssignment`（**manual + inline + confirmedAI**） | 未确认 `ai` 不进 topTags，`confirmedAI` 可参与 |
| HoloAI 对话上下文 | `getTopTags()` + 独立字段 `aiOrganizedThemes` | 手动标签 + 已确认 AI 标签 + 活跃主题摘要 |
| 主题页关联标签 | `Topic.associatedTags`（关系） | AI 生成的主题级标签 |
| `MemoryInsightContextBuilder` | 新增 `confirmedAITags` + `activeTopicSummaries` 字段 | 作为独立维度注入，不混入原有 topTags |

**分层理由**：`ai` source 的标签可能包含"生活""思考"等泛标签，直接混入 topTags 会稀释分析质量。但 `confirmedAI`（用户保留 ≥7 天）可信度更高，且活跃主题的摘要本身就是高质量的结构化信息，应该可以被 HoloAI 和记忆洞察利用。

## 开关关闭后的行为

关闭“自动整理想法”后：

1. 新保存的想法不再调用 AI 自动整理。
2. 手动标签继续可用。
3. 正文内 `#标签` 继续自动提取。
4. 已有 AI 标签和主题不删除。
5. 主题页可以显示“已暂停自动整理”。
6. 用户仍可手动触发“重新整理”或“整理历史想法”。

关闭开关不等于清空整理结果，避免用户产生数据被动消失的感受。

## 隐私与信任

首次开启前必须说明：

1. AI 会处理想法内容以生成标签和主题。
2. 原文不会被 AI 改写。
3. 手动标签不会被 AI 删除或覆盖。
4. 用户可以随时关闭。

如果未来实现依赖后端或第三方 AI 服务，需要在隐私说明和设置页文案里保持一致。

## 第一版验收标准

<!-- 🛡️ 对抗性审查修改：原方案 12 条平铺验收标准，拆分为 v1a/v1b 两阶段，与分阶段实施策略对齐 -->
<!-- 🛡️ 三轮审查修改：新增 backfill、organizedStatus、confirmedAI 升级、多设备去重相关验收项 -->

### v1a（AI 标签能力）

1. 用户可以在设置页 `AI 整理` 分区看到 `自动整理想法` 开关。
2. 用户可以开启/关闭 `自动整理想法`。
3. 新想法保存不等待 AI 整理完成。
4. 自动整理开启时，新想法会在后台生成 AI 标签（通过 `thought_organization` purpose）。
5. 想法卡片：有手动标签时展示手动标签，无手动标签时展示 1-2 个 AI 标签（灰色调）。
6. 想法详情页展示完整 AI 归类区域。
7. 用户删除 AI 标签后，rejectedAI 信号被记录，后续类似内容不会立即反复加回。
8. 关闭自动整理后，新想法不再触发 AI 调用，手动标签和 `#标签` 仍然生效。
9. `getTopTags()` 分析上下文统计 `manual + inline + confirmedAI`，未确认 `ai` 不参与。
10. AI 整理失败时想法保存不受影响，最多自动重试 3 次。
11. 后端 `thought_organization` purpose 已配置且共享 chat 限额内可正常调用。
12. 想法内容 < 10 字符时自动跳过 AI 整理。
13. 首次启动时，旧 `Thought.tags` 已 backfill 为 `ThoughtTagAssignment(source: manual)`。
14. `Thought.organizedStatus` 正确反映 6 种状态，pending 队列可在 App 重启后重建。
15. AI 标签（source=ai）展示满 7 天且未删除，自动升级为 confirmedAI。
16. 多设备场景：已有 AI assignment 的想法（同步来的）不会重复调用 AI。
17. 软删除/归档想法不计入 Topic 关联和计数。
18. AI 请求队列只传 thoughtId，不跨线程持有 NSManagedObject。

### v1b（主题 Tab + 历史整理）

13. 想法首页有 `全部 / 主题` 顶部 Tab。
14. 主题至少关联 3 条想法后才展示（从 candidate → active）。
15. 历史整理入口同时存在于设置页和主题空状态。
16. 打开主题 Tab 不触发全量大模型请求（只读缓存）。
17. 历史整理显示进度，失败时不终止全部任务。
18. 主题页展示：主题名 + 摘要 + 相关想法时间线 + 关联标签。
19. 用户可以重命名、合并、隐藏主题。
20. 多设备同步后 AI 标签正常展示（只整理本机创建，同步来的 assignment 自然可见），rejectedAI 优先。

## 实施注意事项

<!-- 🛡️ 对抗性审查修改：从 6 条扩展至 13 条，新增 #5-#13 为审查发现的前置依赖和工程约束 -->
<!-- 🛡️ 三轮审查修改：新增 #14-#20 为三轮审查确认的工程约束 -->
<!-- 🛡️ 五轮审查修改：新增 #21-#25 为五轮审查确认的工程约束 -->

1. 现有 `ThoughtRepository.create/update` 已经会保存标签，但当前标签关系无法表达 AI 来源、拒绝信号和主题关系；采用新增 `ThoughtTagAssignment` 中间实体方案（见"数据模型设计"章节），不修改现有 `ThoughtTag` 和 `getOrCreateTag` 逻辑。
2. 现有 `InlineTagDetector` 和 `MarkdownParser.extractTags` 已经支持正文内 `#标签` 提取，应继续复用。
3. 现有 `ThoughtAnalysisContextBuilder` 和 `MemoryInsightContextBuilder` 会读取 topTags；接入 AI 标签后，`getTopTags()` 统计 `manual + inline + confirmedAI`，未确认 `ai` 不参与（见"AI 标签与手动标签的隔离"章节）。
4. 主题 Tab 应优先读取本地缓存，不应在 SwiftUI view body 或列表刷新中直接触发 AI 请求。
5. **后端集成是前置依赖**：需在 `config.js` 新增 `thought_organization` purpose 路由配置，在 `defaultPrompts.json` 新增 prompt 模板，iOS 端 `HoloBackendPurpose` 新增 case。合并后必须同步部署后端，否则生产环境不会生效（见"后端集成设计"章节）。
6. 历史整理应支持分批、进度、失败重试，避免一次性发送大量历史全文导致 token 成本和延迟失控。每批 10 条，间隔 2 秒。每天最多 50 条（共享 chat 限额）。
7. **分阶段实施**：v1a 先做 AI 标签能力（不改 Tab 结构），v1b 再做顶部 Tab 改造和主题 Tab（见"想法首页结构"章节）。
8. **离线与失败处理**：最多重试 3 次（指数退避），超限标记 `failed`。App 回前台时检查 `pending` 队列（见"离线与失败处理"章节）。
9. **想法编辑不触发重新分析**：仅在首次创建时分析，编辑后保留已有 AI 标签。用户可通过详情页"重新整理"手动触发（见"想法编辑与更新策略"章节）。
10. **iCloud 同步**：`ThoughtTagAssignment` 和 `Topic` 跟随 iCloud 自动同步。每台设备只整理 `createdDeviceId == currentDeviceId` 的想法，避免重复调用（见"iCloud 同步策略"和"多设备去重策略"章节）。
11. **卡片展示**：AI 标签只在没有手动标签时展示，不做双行叠加。AI 标签使用灰色调区分手动标签（见"全部"章节）。
12. **设置页位置**：`AI 整理` 分区放在 `AI 回放` 和 `AI 记忆` 之间，三个 AI 分区紧凑排列（见"设置入口"章节）。
13. **内容过短跳过**：想法正文 < 10 字符时标记 `skipped`，不触发 AI 调用，节省成本。
14. **Thought.tags 过渡策略**：v1a 采用 backfill + 双写，旧 UI 回退读 Thought.tags。saveThought 签名改为分别传入 manualTags 和 inlineTags（见"Thought.tags 过渡策略"章节）。
15. **软删除影响**：软删除和归档不触发 cascade，Topic 计数和时间线必须 filter `isSoftDeleted == false`。`deleteAllThoughtData()` 必须覆盖 ThoughtTagAssignment 和 Topic（见"软删除、归档与新增实体"章节）。
16. **Thought.organizedStatus**：默认值 `unprocessed`（历史数据不入自动队列）。新建想法由 repository 根据开关写入 `pending` / `disabled` / `skipped`。队列只处理 `pending`，不处理 `unprocessed`。
17. **confirmedAI**：v1 仅通过用户显式"保留"操作产生，不做自动升级。confirmedAI 可参与 getTopTags() 和 HoloAI 上下文。
18. **JSON mode 调用路径**：`HoloBackendAIProvider.chat()` 不传 responseFormat。想法整理需新增专用方法（如 `organizeThought()`）或 chat overload 传入 `responseFormat: .jsonObject`。解析失败时需处理前后缀、Markdown code fence、缺字段等兜底。
19. **线程安全**：AI 请求队列只传 thoughtId（UUID），不跨线程持有 NSManagedObject。写回通过主线程 context 的 perform 完成。
20. **搜索不覆盖 AI 标签**：v1 搜索继续只搜 content 和手动标签，AI 标签不参与搜索。
21. **Thought.createdDeviceId**：新建想法时写入 `HoloBackendDeviceIdentity.shared.deviceId`。legacy 想法为 nil，视为历史数据。多设备策略依赖此字段（见"多设备去重策略"章节）。
22. **processing 崩溃恢复**：App 启动时将 `organizedStatus == processing` 且 `organizationStartedAt` 超过 5 分钟的想法复位为 `pending`（见"离线与失败处理"章节）。
23. **backfill 策略**：迁移时旧 Thought.tags 的 assignment 标为 `source = manual`，`organizedStatus` 标为 `unprocessed`（不是 pending），不自动入队。
24. **Core Data 关系完整性**：所有关系和 inverse 详见"Core Data 关系完整表"章节。新增 class 文件包括 ThoughtTagAssignment、Topic 的 CoreDataClass 和 CoreDataProperties 文件。
25. **内部成本估算**：DeepSeek/Qwen 单次成本为按当前价格估算，实施前需重新核对 provider/model 价格。

## 方案结论

本方案采用 **B：想法自动标签 + 主题簇**。

用户体验上，AI 标签默认直接生效，但通过设置页开关提供明确控制权；主题作为独立视角出现，先不挤占想法列表主流程。成本策略采用“单条实时，主题延迟，历史手动，全部缓存”，避免每次打开页面都请求大模型。

这个版本能在不强迫用户维护标签的前提下，为想法模块建立持续可用的信息分类能力，并为后续 HoloAI、记忆长廊和长期记忆提供更稳定的结构化输入。

---

## 第二轮对抗性审查（Codex）

审查日期：2026-06-08

审查结论：**Conditional Go**

GLM 第一轮审查补齐了原方案缺失的数据模型、编辑策略、失败重试、成本估算、后端 purpose 和阶段拆分，方向整体成立。但当前文档仍存在若干实施前必须收敛的问题；如果直接进入编码，最容易出现“标签有两套真相”“多设备重复打标”“主题碎片化”“后端限流不按预期生效”“JSON 输出解析不稳定”等问题。

### 必须修正的问题

#### P1：`ThoughtTagAssignment` 与旧 `Thought.tags` 的兼容策略不完整

文档采用 `ThoughtTagAssignment` 中间实体是正确方向，但仍没有明确旧 `Thought.tags` 关系在 v1a 中是继续双写、逐步废弃，还是只作为 legacy 读取源。

当前代码里 `ThoughtRepository.create/update` 直接写 `Thought.tags`，`Thought.tagArray`、列表筛选、搜索、详情页、自动补全、`getAllTags()`、`getTopTags()` 也都依赖 `Thought.tags`。如果只新增 assignment 而不定义兼容策略，会出现：

1. 旧手动标签无法区分 `manual` / `inline` 来源。
2. 新 AI 标签只在 assignment 中，旧 UI 仍读不到。
3. `getTopTags()` 改为只读 assignment 后，历史标签可能突然从 AI 上下文消失。
4. `usageCount` 仍由 `getOrCreateTag()` 增加，但 assignment 写入是否增加 usageCount 没定义。

修正建议：

1. 明确 v1a 的过渡策略：`ThoughtTag` 继续作为标签字典；`Thought.tags` 暂时保留为 legacy 关系；所有新展示/筛选统一走 `ThoughtTagAssignment`。
2. 增加一次性 backfill：启动或迁移后，将旧 `Thought.tags` 转成 `ThoughtTagAssignment(source = manualLegacy)` 或 `manual`。
3. 新建/编辑想法时，手动标签和正文 `#标签` 必须分别写 assignment，不能再只写合并后的 `allTags`。
4. 明确是否继续同步写 `Thought.tags`；若保留，仅作为兼容层，不能再作为新功能的数据真相。

#### P1：软删除/归档不会触发关系 cascade，主题计数和 AI 标签会残留

文档写了 `ThoughtTagAssignment.thought -> Thought` 使用 cascade delete，但当前 `ThoughtRepository.delete()` 是软删除，只设置 `isSoftDeleted = true`。这意味着 assignment 和 topic 关系不会被 Core Data 删除规则清理。

风险：

1. 主题 `thoughtCount` 可能包含已删除或已归档想法。
2. 主题页时间线可能展示软删除想法，除非每次查询都额外过滤。
3. 历史整理和主题升级可能被软删除内容污染。
4. `deleteAllThoughtData()` 当前只删除 `ThoughtReference` / `Thought` / `ThoughtTag`，新增实体后需要同步删除 `ThoughtTagAssignment` 和 `Topic`。

修正建议：

1. 所有 topic 计数、升级、摘要、列表查询都必须只统计 `isSoftDeleted == false && isArchived == false` 的想法。
2. 软删除和归档时触发主题计数重算，或放弃冗余 `thoughtCount`，改为查询时计算 live count。
3. `deleteAllThoughtData()` 必须覆盖新增实体。

#### P1：结构化 JSON 调用路径缺口

文档要求 iOS 调用 `purpose: "thought_organization"` 并传 `response_format: { type: "json_object" }`，但当前 `HoloBackendAIProvider.chat(messages:purpose:)` 不接收 `responseFormat`，默认调用无法传 JSON mode。

风险：实现者只新增 `HoloBackendPurpose.thoughtOrganization` 后，仍会靠 prompt 强约束 JSON，解析失败率会高，失败重试也会浪费 token。

修正建议：

1. 新增 `chat(messages:purpose:responseFormat:)` overload，或为想法整理建立专用 provider 方法。
2. 文档实施清单里明确 `responseFormat: .jsonObject` 是 v1a 必做项。
3. 增加解析失败测试：模型输出前后缀、Markdown code fence、缺字段、数组过长时必须能兜底。

#### P1：后端限流描述与真实后端不一致

文档写 `thought_organization` 每设备每分钟 10 次、每天 200 次，但当前后端 `/v1/ai/chat/completions` 使用的是全局 `chatRequestsPerMinute` / `chatRequestsPerDay` 限制，只是按 purpose 分 key 计数，limit 数值没有按 route 区分。

风险：

1. 新增 purpose 后并不会自动获得 10/min、200/day。
2. 历史整理可能占满全局 chat quota，影响正常 HoloAI 对话。
3. 方案验收项“限流生效”无法按当前代码验证。

修正建议：

1. 后端 routes 或 limits 增加 per-purpose limit，例如 `route.minuteLimit` / `route.dailyLimit`。
2. 历史整理和实时整理可以共享 purpose，但需要 iOS 端批处理节流和后端限流共同兜底。
3. 后端测试补充：`thought_organization` 未配置时返回 UNKNOWN_PURPOSE；配置后按专属 limit 而不是 chat limit 消耗。

#### P1：多设备 iCloud 同步会产生重复 AI 标签，缺少去重键

文档写“两台设备各自整理同一想法会产生两条 assignment，取并集展示”，但没有定义同一标签、同一来源、同一想法的唯一键。CloudKit 同步后，同名 AI 标签可能重复出现；如果两台设备都处理 pending 队列，还会重复消耗 token。

更矛盾的是：文档说 `rejectedAI` assignment 同步，但又说 UserDefaults rejected 偏好不同步。这样用户在 iPhone 删除某个 AI 标签后，iPad 展示层可能因同步 assignment 而隐藏它，但 iPad 后续 prompt 仍不知道这个拒绝偏好。

修正建议：

1. 给 assignment 增加确定性 `dedupeKey = thoughtId + normalizedTagName + sourceGroup`，同步后按 key 去重。
2. 或者不让每台设备都自动整理 synced thought：只整理本机创建且尚未有 assignment 的想法。
3. rejected 偏好要么完全随 Core Data 同步并参与 prompt 摘要，要么明确只影响本机后续生成，但同步来的 rejected 仍影响展示。

#### P1：AI 标签完全不进入分析上下文，与产品目标冲突

GLM 为了避免污染，规定 `getTopTags()` 只统计 `manual + inline`，AI 标签完全不参与 HoloAI 对话上下文。这能降低噪音，但和本文档“为后续 HoloAI、记忆长廊和长期记忆提供更稳定结构化输入”的目标冲突。

如果 AI 标签永远不进入分析上下文，用户不手动打标签时，HoloAI 仍然无法利用自动整理出的结构，只能在 UI 层展示标签。

修正建议：

1. v1a 可以禁止未确认 `ai` 标签进入 `getTopTags()`。
2. 但应允许 `confirmedAI` 或达到主题阈值的 `Topic` 摘要进入单独的 thought organization context。
3. 不要把 AI 标签混进原有 `topTags`；可以新增 `aiOrganizedThemes` / `confirmedAITags` 字段，单独给 HoloAI 和 MemoryInsight 使用。

#### P2：主题聚合算法过于脆弱

文档用 `topicCandidate.title` 的 Jaccard 字符相似度匹配 active topic。中文短标题、近义表达、英文缩写和长短不一的主题名都会让这个算法碎片化。

例子：

`更懂用户的智能体`、`HoloAI 理解用户`、`个人智能体方向` 语义接近，但字符重叠不稳定。

修正建议：

1. 单条整理时把 active topics 以 `id + title + summary` 提供给 LLM，让模型输出 `matchedTopicId` 或 `newTopicTitle`。
2. 本地只做保守 exact/normalized match，不做激进相似度合并。
3. v1b 上线前至少补 20-30 条中文主题匹配样例测试。

#### P2：成本文案不宜写死金额

文档写“预计消耗约 ¥0.01-0.05”和 DeepSeek/Qwen 单次成本，但模型价格、路由配置、服务商计费都可能变化。把金额直接展示给用户容易变成承诺，后续价格或 provider 变更时会失真。

修正建议：

1. 用户侧文案改成“将分批使用 AI 处理，可能产生少量 AI 调用成本”。
2. 真实金额只放内部文档，且标注“按当前路由估算，需随 provider 价格更新”。
3. 如果要展示成本，应由后端根据当前 provider/model 配置动态返回估算。

#### P2：后台整理的线程和队列边界需要补清

当前多数 Repository 默认使用 `viewContext`，而方案使用“后台整理”“队列”“App 前台补发”等描述。实施时如果在后台 Task 中直接持有主 context 的 `Thought` 对象，容易踩 Core Data 跨线程访问问题。

修正建议：

1. AI 请求队列只传 `thoughtId` 和纯值 DTO，不跨线程持有 `Thought` 对象。
2. Core Data 写回通过同一个 context 的 `perform` 或主线程 repository 完成。
3. 历史整理批处理如果使用 background context，必须在离开 context 前映射 DTO，并让 viewContext merge。

### 可以接受的设计点

1. 分成 v1a（AI 标签）和 v1b（主题 Tab + 历史整理）是正确的，能避免 UI 重构阻塞基础能力。
2. “保存不等待 AI，失败不影响想法本体”是正确体验。
3. “编辑不自动重新分析，用户手动重新整理”是合理的成本和掌控权折中。
4. 设置页把 `AI 整理` 放在 `AI 回放` 与 `AI 记忆` 之间，比原方案更清楚。
5. 新增后端 purpose 是必要前置；后续实现完成后必须部署后端，否则生产环境不会生效。

### 二轮结论

当前方案可以继续推进，但不建议直接进入代码实施。建议先把以上 P1 问题补回文档，再进入实施计划。

最低开工条件：

1. 明确 `Thought.tags` 与 `ThoughtTagAssignment` 的过渡/回填/双写策略。
2. 补齐软删除、归档、deleteAll 的新增实体处理。
3. 明确 iOS JSON mode 调用路径。
4. 把后端限流改成真实可实现的 per-purpose limit。
5. 定义多设备 assignment 去重策略。
6. 调整“AI 标签不进分析上下文”的绝对表述，改成“未确认 AI 标签不进原 topTags，但确认标签/主题摘要可进入独立 AI 上下文”。

满足以上条件后，v1a 可以进入实施；v1b 的主题 Tab 和历史整理仍建议作为第二阶段单独计划。

---

## 第三轮对抗性审查（Claude）

审查日期：2026-06-08

审查方法：逐条验证 GPT 二轮 6 个 P1 + 3 个 P2 的技术事实（通过代码库实查），交叉验证后发现 5 个完全成立、1 个部分成立；同时发现 GPT 遗漏的 3 个 CRITICAL + 3 个 HIGH + 2 个 MEDIUM 问题。所有已确认问题已直接修正到文档正文中。

### GPT 二轮发现的验证结论

| GPT 编号 | 发现 | 代码验证 | 结论 |
|----------|------|----------|------|
| P1-#1 | `Thought.tags` 兼容策略不完整 | ✅ `saveThought()` → `repository.update(tags:[String])` → `getOrCreateTag` → `thought.addTags(tag)` 全链路走 `Thought.tags` | **同意，已修正** |
| P1-#2 | 软删除不触发 cascade | ✅ `delete()` 只设 `isSoftDeleted=true`，cascade 永远不会触发 | **同意，已修正** |
| P1-#3 | JSON mode 调用路径缺口 | ⚠️ `buildRequest` 已支持 `responseFormat` 参数，`chat` 重载没传它但 `parseUserInputBatch` 等方法已在使用 | **同意但难度低于 GPT 所述，已修正** |
| P1-#4 | 后端限流 per-purpose 不支持 | ✅ 所有 AI purpose 共享 `chatRequestsPerMinute:20` / `chatRequestsPerDay:50`，只按 purpose 分 key 计数 | **同意，已修正** |
| P1-#5 | 多设备 iCloud 去重 | ⚠️ 方向正确但 GPT 建议的 dedupKey 方案过复杂 | **同意，采用更简方案（只整理本机创建）已修正** |
| P1-#6 | AI 标签完全不进分析上下文 | ✅ 一轮的绝对禁令与产品目标冲突 | **同意，已调整为分层策略** |
| P2-#1 | Jaccard 中文标题脆弱 | ✅ 中文短标题字符重叠不稳定 | **同意，已改为 LLM matchedTopicId + Jaccard 兜底** |
| P2-#2 | 成本文案不宜写死金额 | ✅ provider 价格可能变更 | **同意，已去掉硬编码金额** |
| P2-#3 | 后台整理线程安全 | ✅ Core Data 跨线程访问风险 | **同意，已新增线程安全约束** |

### 三轮新增发现（GPT 遗漏）

| 编号 | 等级 | 发现 | 处置 |
|------|------|------|------|
| NEW-P1 | 🔴 | 想法整理状态（pending/organized 等）没有存储位置，Thought 实体缺 `organizedStatus` 属性 | **已新增属性定义** |
| NEW-P2 | 🔴 | `confirmedAI` source 没有创建流程，文档无任何用户交互会产生这个状态 | **已新增自动升级规则（展示≥7天未删除→confirmedAI）** |
| NEW-P3 | 🔴 | `Topic.associatedTagNames` 用逗号分隔字符串存储是 Core Data 反模式 | **已改为 Topic→ThoughtTag 多对多关系，原字段保留为缓存** |
| NEW-H1 | 🟠 | `mergedToTopicId` 用 UUID 存储而非 Core Data 关系，无引用完整性 | **已改为 `mergedToTopic` 关系** |
| NEW-H2 | 🟠 | AI 标签不参与搜索，搜索功能缺失 | **已明确 v1 不覆盖，降为已知限制** |
| NEW-H3 | 🟠 | `getTopTags()` 实现需完全重写（当前遍历 `thought.tags` 内存统计），工程量被低估 | **已标注在过渡策略中** |
| NEW-M1 | 🟡 | v1a 无主题 Tab，历史整理结果对用户几乎不可见（大部分想法已有手动标签） | **已知限制，v1b 解决** |
| NEW-M2 | 🟡 | `saveThought()` 中 `selectedTags + inlineTags` 合并后丢失来源信息，ThoughtTagAssignment 无法区分 manual/inline | **已标注 saveThought 签名需变更** |

### 三轮结论

**所有已确认问题已直接修正到文档正文。** 文档现在处于可开工状态：

- GPT 二轮 6 个 P1 的最低开工条件：✅ 全部满足（修正分布在正文对应章节中）
- 三轮新增 8 个问题：✅ CRITICAL 和 HIGH 已修正，MEDIUM 标注为已知限制

**v1a 可以进入实施计划阶段。** v1b 的主题 Tab 和历史整理仍建议作为第二阶段单独计划。

---

## 第四轮对抗性审查（Codex）

审查日期：2026-06-08

审查结论：**Conditional Go，但三轮“可开工”结论需要降级**

第三轮确实修复了第二轮提出的大部分阻断点，但它新增的若干修正仍未闭环。当前文档可以继续作为方案讨论基础，但不建议直接进入实施计划；至少需要先把以下 P1 问题修回正文，否则实施时会在 Core Data schema、队列恢复、多设备处理和分析上下文上反复返工。

### 新发现的阻断问题

#### P1：`organizedStatus` 默认值设为 `pending` 会污染历史数据

第三轮新增 `Thought.organizedStatus`，默认值为 `"pending"`。这解决了状态存储位置，但会把所有迁移后的历史想法默认标记为待整理。

风险：

1. App 重启后按 `pending` 重建队列时，可能把所有历史想法都当成实时待整理队列。
2. 用户尚未主动点击“整理历史想法”时，系统可能偷偷开始处理历史内容，违背“历史手动”的成本原则。
3. 如果开关关闭，旧数据仍是 `pending`，关闭开关和队列状态会冲突。

修正建议：

1. `organizedStatus` 默认值不应是 `pending`，建议改为 `unprocessed` 或 `disabled`。
2. 新建想法时由 repository 根据开关显式写入 `pending` / `disabled` / `skipped`。
3. backfill 历史想法时统一写 `unprocessed`，只有用户触发历史整理后才批量转为 `pending`。
4. App 启动队列只处理“自动整理开启后本机新建的 pending”，不处理历史 `unprocessed`。

#### P1：“只整理本机创建”没有可执行的数据依据

第三轮把多设备去重改为“每台设备只整理本机创建且无 AI assignment 的想法”。方向更简单，但文档没有为 `Thought` 增加 `createdDeviceId` / `originDeviceId` / `creationSource` 字段，也没有说明如何从 CloudKit import 判断一条想法是不是本机创建。

当前代码只有后端请求用的 `HoloBackendDeviceIdentity.shared.deviceId`，但 `Thought` 实体没有保存该值。

风险：

1. 业务层无法可靠判断“本机创建”。
2. 如果只检查“没有 ai assignment”，同步来的旧想法在 assignment 尚未同步到达前仍可能被第二台设备整理。
3. 多设备同时离线创建/同步时，仍可能重复调用 AI。

修正建议：

1. `Thought` 新增 `createdDeviceId: String?`，新建想法时写入 `HoloBackendDeviceIdentity.shared.deviceId`。
2. 只对 `createdDeviceId == currentDeviceId` 且 `organizedStatus` 为可处理状态的想法自动整理。
3. 对没有 `createdDeviceId` 的 legacy 想法，一律视为历史数据，只能通过“整理历史想法”手动触发。
4. 仍需给 assignment 增加软去重逻辑：同一 thought + normalized tagName + sourceGroup 展示时去重，避免同步竞态留下重复 UI。

#### P1：`processing` 状态缺少崩溃/重启恢复规则

文档新增持久化状态后，`processing` 也会被持久化。如果 App 在 AI 请求中途被杀、网络挂起或系统回收，想法可能永久停在 `processing`，下次启动不会进入 pending 队列。

修正建议：

1. `Thought` 增加 `organizationStartedAt`、`organizationRetryCount`、`organizationLastError` 等最小状态字段，或至少增加 `organizationUpdatedAt`。
2. App 启动时把超过阈值（例如 5 分钟）的 `processing` 复位为 `pending`。
3. 超过最大 retry 的才进入 `failed`。
4. `failed` 的手动“重新整理”需要清空 lastError 并重置 retryCount。

#### P1：`confirmedAI` 自动升级需要时间字段和触发器

第三轮新增“AI 标签展示满 7 天且未删除，自动升级为 confirmedAI”，但 `ThoughtTagAssignment` 只有 `assignedAt`，没有 `lastShownAt`、`confirmedAt` 或“展示过”的状态。列表是否展示 AI 标签还取决于“是否有手动标签”：有手动标签时 AI 标签不展示。因此“展示满 7 天”并不能用 `assignedAt + 7 天` 等价实现。

风险：

1. 有手动标签的想法不会展示 AI 标签，却仍可能 7 天后被升级为 confirmedAI。
2. 用户从未看过该条想法，也会被当成“默认接受”。
3. confirmedAI 进入 `getTopTags()` 后，会把未经用户感知的 AI 标签带入分析上下文。

修正建议：

1. v1a 不做自动升级，保留 `confirmedAI` 但只通过用户明确操作产生，例如“保留/确认 AI 归类”。
2. 或者将规则改为“assignedAt 满 7 天且该想法无手动标签、AI 标签曾在列表或详情曝光过”，并新增 `lastDisplayedAt` / `displayCount` 字段。
3. 在没有曝光追踪前，`confirmedAI` 不应进入 `getTopTags()`。

#### P1：正文内多处策略仍互相矛盾

三轮在正文中追加了新策略，但旧段落没有完全改干净，导致实施者会读到互相冲突的要求。

明显冲突：

1. 查询路径变化仍写 `getTopTags()` “只统计 manual + inline”，后文又改成 `manual + inline + confirmedAI`。
2. AI 输出建议示例仍没有 `matchedTopicId`，但 prompt 输出格式要求有 `matchedTopicId`。
3. Topic 关系块重复出现两次，且“新增实体无需数据迁移”与 `Thought` 新增属性/关系并不一致。
4. v1b 验收仍写“多设备同步后 AI 标签取并集展示”，但正文已改成“只整理本机创建，不做取并集”。

修正建议：

1. 把文档整理成一份最终收敛版，不再保留多轮补丁式互相覆盖的正文。
2. 所有“旧策略”应删除或标注为废弃，而不是与新策略并存。
3. 输出 JSON 示例、验收标准、实施注意事项必须与当前最终策略一致。

#### P1：新增 Core Data 关系的 inverse / class / accessor 设计仍不完整

文档新增 `ThoughtTagAssignment`、`Topic`、`Topic.associatedTags`、`Topic.mergedToTopic`、`Thought.topics`，但没有明确：

1. 每个关系的 inverse 名称。
2. `ThoughtTagAssignment` 是否需要 `thought.assignments` inverse。
3. `ThoughtTag` 是否需要 `assignments`、`associatedTopics` inverse。
4. `Topic` 自引用关系的 inverse 如何处理。
5. 对应 `NSManagedObject` class 文件和 generated accessor 要新增哪些属性。

当前项目是编程式 Core Data model，不是 xcdatamodeld；这些细节不写清，实施时很容易建出无法加载、无法轻量迁移或 accessor 不匹配的模型。

修正建议：

1. 在方案里补一张“Core Data Entity/Relationship 完整表”，列出 source entity、relationship name、destination、to-one/to-many、deleteRule、inverse。
2. 明确新增 class 文件：`ThoughtTagAssignment+CoreDataClass.swift`、`Topic+CoreDataClass.swift`，以及 `Thought` / `ThoughtTag` 的新增 `@NSManaged` 属性和 accessors。
3. 对 self-referencing `mergedToTopic` 明确是否需要 inverse，例如 `mergedFromTopics`。

### 需要降级为 v1b 或后续的内容

#### P2：v1a 不应强行实现主题模型全量能力

文档说 v1a 先做 AI 标签能力，不改 Tab 结构；但数据模型和 prompt 已把 `Topic`、`matchedTopicId`、candidate → active、summary、associatedTags 都卷进来了。

如果 v1a 真要“只做 AI 标签”，建议：

1. v1a 的 AI 输出只包含 `suggestedTags`、`confidence`、`reason`。
2. Topic 实体、主题匹配、summary、`matchedTopicId` 全部放到 v1b。
3. 若保留 topicCandidate，也只作为 JSON 字段丢弃或调试，不落库。

否则 v1a 实际已经不是“AI 标签能力”，而是半个主题系统，工程量会被低估。

#### P2：用户侧成本提示已修正，但内部成本估算仍需标注时效

用户侧说明页已改成“不写死金额”，这是正确的。但内部成本估算仍保留 DeepSeek/Qwen 具体金额，应标注“按当前价格估算，实施前需重新核对 provider/model 价格”。

### 本轮结论

第三轮把第二轮的主要方向都吸收了，但“已可开工”的判断偏乐观。当前最小开工条件应更新为：

1. `Thought.organizedStatus` 默认值和历史 backfill 状态重新定义，避免历史数据自动入队。
2. `Thought` 增加 `createdDeviceId` 或放弃“只整理本机创建”策略，改回 assignment 去重。
3. `processing` 恢复、retryCount、lastError/updatedAt 等状态字段补齐。
4. `confirmedAI` 自动升级规则改为显式确认，或补曝光追踪字段。
5. 清理正文冲突，生成最终收敛版文档。
6. 补完整 Core Data relationship/inverse/accessor 设计表。
7. 明确 v1a 是否真的不落 Topic；若不落，移除 v1a 的 Topic 落库要求。

满足以上条件后，才建议进入 v1a 实施计划。当前仍是 **Conditional Go**，不是 No-Go；产品方向继续成立，但文档还需要一次”收敛重写”，而不是继续堆叠补丁。

---

## 第五轮对抗性审查（Claude）

审查日期：2026-06-08

审查方法：逐条验证 GPT 四轮 6 个 P1 + 2 个 P2，交叉验证后全部成立。所有问题已直接修正到文档正文中。

### GPT 四轮发现的验证与修正

| GPT 编号 | 发现 | 我的判定 | 处置 |
|----------|------|---------|------|
| P1-#1 | `organizedStatus` 默认 `pending` 污染历史 | **完全同意** | 默认值改为 `unprocessed`，新增状态区分，backfill 标 `unprocessed` |
| P1-#2 | “只整理本机创建”无数据依据 | **完全同意** | Thought 新增 `createdDeviceId`，多设备策略补齐数据字段 |
| P1-#3 | `processing` 缺崩溃恢复 | **完全同意** | 新增 `organizationStartedAt` 字段，App 启动时 5 分钟超时复位 |
| P1-#4 | confirmedAI 自动升级有漏洞 | **完全同意** | 去掉自动升级，改为用户显式”保留”操作 |
| P1-#5 | 正文多处策略矛盾 | **完全同意** | 已清理：getTopTags 查询表、JSON 示例加 matchedTopicId、去重复 Topic 关系、v1b 验收去”取并集” |
| P1-#6 | Core Data 关系 inverse 不完整 | **完全同意** | 新增完整关系表（12 行），含 inverse、delete rule、class 文件清单 |
| P2-#1 | v1a 不应实现 Topic 全量能力 | **部分同意** | Topic 实体仍保留在数据模型中（一次性建表），但 v1a 不实现主题匹配、摘要、candidate→active 流程。prompt 的 topicCandidate 在 v1a 中丢弃不落库 |
| P2-#2 | 内部成本估算需标注时效 | **同意** | 已在实施注意事项 #25 标注 |

### 五轮修正清单

| # | 修正内容 | 文档位置 | 标记 |
|---|---------|---------|------|
| 1 | organizedStatus 默认值从 `pending` 改为 `unprocessed`，新增 7 种状态 | 数据模型 > Thought | `🛡️ 五轮审查修改` |
| 2 | Thought 新增 `createdDeviceId` 和 `organizationStartedAt` 属性 | 数据模型 > Thought | `🛡️ 五轮审查修改` |
| 3 | processing 超时恢复规则（5 分钟复位为 pending） | 工作流 > 队列管理 | `🛡️ 五轮审查新增` |
| 4 | confirmedAI 去掉自动升级，改为用户显式”保留”操作 | 数据语义 > 标签来源 | `🛡️ 五轮审查修改` |
| 5 | getTopTags 查询路径表与 AI 标签隔离章节统一为 `manual + inline + confirmedAI` | 数据模型 > 查询路径变化 | `🛡️ 五轮审查修改` |
| 6 | JSON 输出建议示例加 `matchedTopicId` | 数据语义 > AI 输出建议 | `🛡️ 五轮审查修改` |
| 7 | Topic 关系定义去重、补 inverse（`mergedFromTopics`、`associatedTopics`、`assignments`） | 数据模型 > Topic | `🛡️ 五轮审查修改` |
| 8 | 新增 Core Data 关系完整表（12 行关系 + class 文件清单） | 数据模型 > 新增章节 | `🛡️ 五轮审查新增` |
| 9 | v1b 验收标准去掉”取并集展示”，改为与多设备策略一致的描述 | 验收标准 > v1b | `🛡️ 五轮审查修改` |
| 10 | 多设备策略补齐 `createdDeviceId` 数据依据 | 数据语义 > iCloud 同步策略 | `🛡️ 五轮审查修改` |
| 11 | 实施注意事项扩展到 25 条，新增 #21-#25 | 实施注意事项 | `🛡️ 五轮审查修改` |

### 五轮结论

**GPT 四轮的 7 个最低开工条件全部满足：**

1. ✅ `organizedStatus` 默认值改为 `unprocessed`，backfill 标 `unprocessed`
2. ✅ `Thought` 增加 `createdDeviceId`，多设备策略有数据依据
3. ✅ `processing` 恢复：新增 `organizationStartedAt`，App 启动 5 分钟超时复位
4. ✅ `confirmedAI` 改为用户显式操作，不再自动升级
5. ✅ 正文矛盾已清理：查询表、JSON 示例、重复关系、v1b 验收均已统一
6. ✅ Core Data 关系完整表已补齐（12 行关系 + inverse + class 文件）
7. ✅ v1a 的 Topic 落库保留但主题匹配/摘要/升级流程留给 v1b，prompt 的 topicCandidate 在 v1a 丢弃

**v1a 可以进入实施计划阶段。**
