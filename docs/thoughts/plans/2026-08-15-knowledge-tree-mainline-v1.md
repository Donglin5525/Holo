# 想法模块知识树 v1 · 主线方案

> 日期：2026-08-15 ｜ 状态：一期已实施（含 v2 修正），待真机验收
> 决策人：东林（2026-08-15 原型确认「思路 ok，按这个来」；同日要求基于事实修正把握度/打标链路，v2 完成）
> 原型：`docs/prototypes/knowledge-tree-v1.html`

## 0. v3 视觉与结构修正（2026-08-15，东林真机反馈）

| 反馈 | 修正 |
|---|---|
| 旧抽屉与新知识树并存混乱 | **旧抽屉整体移除**（ThoughtKnowledgeDrawerView 删除、入口按钮删除）；其独有能力迁移：标签全局重命名/删除 → 主题详情页关键词长按菜单；主题重命名/删除 → 主题详情页 ··· 菜单；「AI 自动分类」开关唯一入口保留在设置页；DrawerNode 枚举保留（列表筛选意图载体，迁至 ThoughtListView） |
| 卡片有大有小、不对齐 | 卡片统一两列网格（取消奇数张时的全宽横卡）；同一行卡片强制等高（maxHeight 填充 + 顶对齐）；关键词胶囊行固定高度、最多 2 个、单个胶囊单行截断不换行；「最近想法」行无数据时显示「还没有想法」占位保持结构一致 |
| 图标全是文件夹 | Topic 新增 `iconEmoji` 字段；TopicIconProvider 三级策略：用户自选 > Onboarding 预设精确匹配（工作💼成长🌱灵感💡生活🏃财务💰关系👨‍👩‍👧）> 标题关键词启发式（14 组规则）> 标题稳定哈希兜底池；主题详情页 ··· 菜单「更换图标」emoji 网格选择器；管理页/选择器/待确认池/想法详情页全部接入 |

## 0.5 v2 修正记录（基于线上真实数据，2026-08-15）

> 后端待发版事项（2026-08-15 已改好未发）：`src/config.js` thought_organization 补 `reasoningEffort: "none"`（关思考模式，根治空响应）。后端 207 测试全过。

对线上 `ai_call_logs`（purpose=thought_organization，52 条调用，2026-07-15 ~ 08-15，模型 deepseek-v4-flash）的分析结论：

| 事实 | 数据 | 对方案的修正 |
|---|---|---|
| confidence 字段返回率 | 35/35 成功调用 100% 返回 | 「AI 漏字段导致爆池」风险排除；客户端兜底 0.5 保留为换模型保险丝 |
| confidence 分布 | 0.1~0.95，均值 0.804；<0.75 占 20%，且其中多数同时选了「未分类」（不挂主题不进池） | 阈值 0.75 与样本自然分界吻合；预估真正进池量 ≈ 6%~8% 新整理量，健康 |
| 低分与「无法判断」强相关 | 0.1/0.25/0.3/0.4 样本的 reason 均为「无意义占位/测试文本/无可用主题」 | 模型自报置信度在该 prompt 下有区分度，可作为分层依据 |
| reason 字段 | 35/35 返回且质量可用 | **从二期提前到一期**：客户端解析落库（Thought.topicAssignmentReason）+ 待确认池/详情页展示，无需后端发版 |
| 空响应（content=""） | 14/52（27%）；maxTokens 2048 修复（8-05 发版）后仍发生（8-14 有 2 条） | 根因确认：**thought_organization 未关思考模式**（8 月「关思考」只关了 thought_voice_summary，此 purpose 漏配）。双保险修复：① 后端 config 补 `reasoningEffort: "none"`（**需发版**，与语音总结同机制）；② 客户端空响应改为抛错走队列重试（已交付） |
| recentAITags 断链 | 后端 prompt v4（已发版）将「复用 existingTags/recentAITags」定为硬约束，客户端 payload 从未传该字段 | 客户端补传（近 90 天 AI 标签叶段 top30），后端复用机制接通，直接缓解标签发散 |
| 样本局限 | 52 条中含较多测试数据（「测试」「占位文本」），未分类比例被抬高 | 阈值 0.75 为初始值，上线后按行为数据校准（见 §7） |

## 1. 背景与问题

调研结论（2026-08-15）：知识树底层设计（Topic=单选分类边界，Tag=多选关键词）方向正确，但交付存在四个断层：

1. **心智模型不可见**：标签以「工作/Holo」路径字符串示人，主题与标签的关系用户无法从界面读出。
2. **入口散落**：知识树藏在左侧抽屉（进想法页 → 左上角菜单）；主题管理后台藏在系统设置页；主题存在后抽屉内无管理入口。
3. **筛选互相打架**：抽屉节点筛选 / 列表标签 chip / 日期筛选三套并存，互斥清空。
4. **分类只有成本没有收益**：AI 逐条打标 + 聚类建议，但主题点进去只有罗列，无综述、无理由、无置信度呈现；Topic.summary 字段从未被写入。

## 2. 目标与心智模型（已拍板）

**一句话心智模型：主题 = 书架（一条想法只进一个），关键词 = 便利贴（可贴多个）。**

界面语言统一为「主题 / 关键词」，不再向用户暴露斜杠路径：
- 主题内显示标签叶段名（如「Holo」）；
- 脱离主题上下文时显示「工作与事业 · Holo」；
- 路径仅作为存储结构存在，不进 UI 文案。

四个产品机制（原型已确认）：
1. 知识树升为想法模块主视图（「时间流 | 知识树」平级切换）；
2. 管理入口收拢进知识树（设置页入口撤除）；
3. AI 透明化：分类结果带置信度，高置信自动归档、低置信（<0.75）进「待确认池」集中轻确认；
4. 详情页补齐主题归属展示与修改。

## 3. 分期

| 期 | 内容 | 依赖 |
|---|---|---|
| 一期（本次，含 v2 修正） | 主视图化、主题详情页、待确认池、详情页主题区块、标签去路径化、入口收拢；**+ 分类理由落库展示、recentAITags 补链、空响应可重试** | 纯客户端，无需后端发版 |
| 二期 | 主题 AI 综述（激活 Topic.summary）、打标注入用户档案上下文 | **需后端发版**（新 purpose + payload 扩展），完成后单独同步东林 |
| 三期 | 数据地基重构：标签路径字符串→真层级、Thought.tags 双写合并、Topic 死字段清理 | 等一期二期价值验证后再排期 |

一期明确不做（避免假功能）：AI 综述卡（后端能力未就绪不放占位假数据）；「问 AI 这个主题」（后续版本）。

## 4. 一期详细设计

### 4.1 数据层

**新增字段** `Thought.topicConfidence: Double`（默认 0.0，CloudKit 轻量迁移）：
- AI 整理挂主题时写入 AI 返回的 confidence（含未归类=0）；
- 手动移入主题（`TopicRepository.assign`）、用户确认归并（`applyConvergence`）一律置 1.0；
- 待确认池查询口径：挂有 classification Topic && `0 < topicConfidence < 0.75` && organizedStatus == organized && 未删未归档。

**新增字段** `Thought.topicAssignmentReason: String?`（v2）：
- `applyClassification` 写入后端返回的一句话分类依据（挂主题与未归类两种结果都写）；
- 手动 `assign` / `remove` 清空（手动归档不需要 AI 理由）。

**写入点改造**：
- `TopicRepository.applyClassification` 增加 `confidence` / `reason` 参数；
- `TopicRepository.assign` 置 1.0 并清 reason；
- `TopicRepository.remove` 置 0 并清 reason；
- `ThoughtOrganizationService.organizeThought` 透传 `result.confidence` 与 `result.reason`。

**AI 调用链路修复（v2）**：
- payload 补 `recentAITags`（`fetchRecentAITagLeafNames`：近 90 天 AI 标签叶段名按命中想法数降序 top 30）——后端 v4 prompt 复用硬约束的原料；
- 空响应（content 为空白）由「标 failed 不重试」改为抛 `APIError.serverError` 走队列 5s/30s/120s 重试——修复线上 27% 的整理失败主因。

**新增查询** `ThoughtRepository.fetchThoughtsPendingTopicConfirmation()`。

### 4.2 知识树主视图（新文件 `ThoughtKnowledgeTreeView.swift`）

- 进入方式：`ThoughtListView` header 下方分段控件「时间流 | 知识树」，`@AppStorage("thoughtsBrowseMode")` 记忆；知识树模式下隐藏搜索栏/标签筛选栏。
- 结构（自上而下）：
  - **AI 状态条**：待确认 N 条（紫色，点击进待确认池）；整理进行中显示进度文案；无状态时隐藏。
  - **主题卡片墙**（两列网格）：folder 图标（按主题序号取色板色）+ 主题名 + 想法数 + 关键词 chips（叶段名，取该主题下标签桶 top 3）+ 最近想法相对时间；点击进主题详情页。
  - **未归类卡**（虚线边框）：数量 + 点击切回时间流并应用未归类筛选（复用 drawerSelection 机制）。
  - **发现新主题**行：复用现有归并流程（`startTopicConvergence`），徽章显示待归纳线索数。
  - **已归档**行：切回时间流并应用归档筛选。
- header 右侧加「管理」按钮 → sheet `TopicManagementView`。
- 数据：`fetchClassificationTopics` + `fetchAITagBuckets` + `fetchUnclassifiedThoughts` + `fetchArchived`，监听 `.thoughtDataDidChange` 刷新。

### 4.3 主题详情页（新文件 `TopicDetailView.swift`）

- 进入方式：知识树主题卡 fullScreenCover；内嵌 NavigationView，返回即关闭。
- 结构：
  - hero：folder 图标 + 主题名 + 「N 条想法 · M 个关键词」+「编辑」（重命名 alert / 删除确认，复用抽屉现有逻辑文案）。
  - 关键词筛选 chips（横向滚动）：全部 / 各标签桶（叶段名 + 计数）。
  - 想法卡片列表：`ThoughtCardView` 简配（无滑动操作）；点击进 `ThoughtDetailView`。
- 删除主题后想法回未归类并写 90 天拒绝记录（复用 `deleteClassificationTopic` + `ConvergenceRejectionRepository`）。
- 二期在此页首屏插入 AI 综述卡（预留位置，一期不放占位）。

### 4.4 待确认池（新文件 `TopicConfirmationQueueView.swift`）

- 进入方式：知识树 AI 状态条；时间流 `aiOrganizationBanner` 新增第四态（待确认 N 条）。
- 卡片：内容预览 + AI 当前挂的主题 + 置信度进度条 + 「放这里」（confirm 置 1.0）/「换一个」（弹 `TopicPickerView`，assign 置 1.0）。
- 确认后卡片移出列表；全部处理完显示空态（文案强调「确认会持续让分类更准」）。
- 「跳过」不持久化（低置信条目下次仍会出现，符合待确认语义）。
- 二期卡片补充分类理由（reason）。

### 4.5 想法详情页主题区块（`ThoughtDetailView.swift`）

- `contentSection` 之后新增「所属主题」区块：
  - 有主题：folder + 主题名 +「更换」→ `TopicPickerView`；长按菜单提供「移出主题」。
  - 无主题：「未归类」+「选择主题」入口。
- `TopicPickerView` 增加「移出主题」destructive 行（仅当该想法已有主题时显示，走 `TopicRepository.remove` 置 0）。

### 4.6 标签视觉去路径化（显示层，存储不动）

| 位置 | 改动 |
|---|---|
| `ThoughtCardView.tagChip` | 显示 `lastSegment(tag.name)`，点击筛选仍传完整路径 |
| `ThoughtDetailView.tagsSection` / `aiTagsSection` | 同上 |
| `ReferenceCardView` 标签 | 同上 |
| 抽屉 | 已用叶段名 + 副标题路径，不动 |

### 4.7 入口与死代码

- `SettingsView` 撤除「管理分类主题」入口（AI 分类开关保留）；管理唯一入口 = 知识树「管理」按钮。
- 抽屉保留为时间流快捷筛选（行为不动）；主题详情页承担主题浏览主路径。
- 删除死视图 `TagInputView.swift`。

## 5. 风险与边界

- `topicConfidence` 存量数据全为 0：存量已挂主题的想法不会进待确认池（`>0` 条件排除），只有新整理的想法参与，符合「新机制只管新数据」的渐进原则；手动移一次主题即可补齐置信度。
- CloudKit 多设备：字段随私有库同步，无 schema 冲突风险（加字段轻量迁移）。
- 抽屉点主题 = 列表筛选，知识树点主题 = 详情页：两个入口行为不同（筛选器心智 vs 浏览心智），文档记录该决策；若后续反馈混乱，统一收敛到详情页。
- 状态徽章（整理中/失败等）一期不动，简化方案记入后续优化。

## 6. 二期清单（需后端发版，完成后单独同步）

1. 新 purpose `thought_topic_summary`：输入主题下想法（截断摘要列表）→ 综述文本，写 `Topic.summary`；主题详情页首屏综述卡 + 手动重新生成；想法数变动超阈值自动重生成（客户端触发）。
2. 打标 payload 注入用户档案上下文（身份/在进行的事），解决单句想法无上下文分不准的问题。
3. 本地关键词兜底聚类撤除或明示「离线规则」，避免伪装 AI 消耗信任。
4. （原「分类理由需后端支持」一项作废——后端 v4 prompt 已在返回 reason，v2 已在客户端落地。）

## 7. 把握度校准机制（上线后执行）

自报置信度是未校准信号，0.75 只是初始值（依据见 §0 分布数据）。上线 2~4 周后校准：

1. **客户端行为**：统计待确认池「放这里 / 换一个 / 跳过」比例——「放这里」占绝对多数 → 阈值下调（如 0.6）减少打扰；「换一个」占比高 → 上调（如 0.85）。
2. **后端复核**：`ai_call_logs` 中 thought_organization 的 confidence 分布是否漂移（换模型时必查）。
3. 阈值是单一常量 `ThoughtRepository.topicConfirmationThreshold`，调整成本一行。
4. 统计口径（客户端本地，不上报）：待确认池 confirm/resolve 动作时累加 UserDefaults 计数器即可，避免为此上后端。
