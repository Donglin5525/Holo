# 观点模块知识树设计方案

日期：2026-06-23（初稿）/ 2026-06-26（GLM 一轮 + GPT 交叉 + GLM 二轮 + GPT 三轮 + GLM 四轮定稿）
状态：**已定稿**（待决项已拍板，可进入 P1 实施）
范围：Holo iOS 观点模块
关联原型：
- `.superpowers/brainstorm/47610-1782203636/content/thought-slide-tree-aligned.html`
- `.superpowers/brainstorm/47610-1782203636/content/thought-knowledge-tree-hi-fi.html`

---

## 0. 修订摘要

初稿方向正确（轻量记录 + 渐进结构化 + 确认后生效）。经 GLM 一轮、GPT 交叉、GLM 二轮、GPT 三轮、GLM 四轮定稿：

- GLM 一轮砍掉高冲突手势与过重层级；
- GPT 交叉审查纠出 GLM 一轮的关键误判——把 `Topic`「结构已存在」当成「业务闭环已存在」，导致 P1 范围低估，据此拆出 P1.5；
- GLM 二轮认可上述纠错，并进一步发现 GPT 版在**拒绝键设计、`.confirmedAI` 语义撞车、主主题过度约束**三处仍有问题；
- GPT 三轮继续收敛实现细节，补齐**收纳判断粒度、来源词主源、Topic 幂等载体、P1 的 AI 整理入口行为、`.confirmedAI` 在 AI 标签池中的展示规则**五处落地缺口（决策 15-19）；
- GLM 四轮（定稿）：拍板 GPT 三轮遗留的两个待决项——**P1.5 不加 `canonicalKey`**（运行时归一化查询 + 同步后合并）、**P1 整理入口文案**定为「待整理 N 条 .ai 标签 + 开发中」；并补三条实施细节（来源词 get-or-create `ThoughtTag`、标签池计数按未收纳数、主主题活跃度统一用 `thoughts.count`）。

核心决策如下，正文已同步：

| # | 修订决策 | 修订理由（代码依据） |
|---|---|---|
| 1 | **砍「右滑开抽屉」手势**，改顶部菜单按钮入口 | 观点页是 `fullScreenCover` + 左边缘右滑返回（`HomeView:223` + `swipeBackToDismiss`），内部还有卡片左滑、标签横滑、列表竖滑，再叠全屏右滑必五方混战 |
| 2 | **三层「领域/主题/标签」→ 两层「主题/标签」** | `Topic` 结构已存在但业务闭环未完成；个人笔记量级第一版不引入领域实体 |
| 3 | **删除「AI 临时标签」概念，复用 `source = .ai`** | `ThoughtTagAssignment.source` 已有 `manual/inline/confirmedAI/ai/rejectedAI` 五类，再造分类会污染枚举 |
| 4 | ⚡二轮修订：**归并收纳不改 source（保持 `.ai`）**；⚡三轮修订：收纳语义靠 Thought+Tag+Topic 三者交集表达 | 现有 `confirmAssignment`（ThoughtOrganizationService:145）已占用 `.confirmedAI` 表示「单条确认」；归并若再升 `.confirmedAI` 会与单条确认撞语义，无法区分（见 §6.3） |
| 5 | **必须新增后端 purpose `thought_tag_convergence`** | 现有 `thought_organization` 是单条→单条打标签，无法 batch 收敛（见 §6.2） |
| 6 | **建议级拒绝改走 Core Data（iCloud 同步）** | 现有 `rejectedAITags` 在 UserDefaults、仅标签级、不同步，不适用 |
| 7 | ⚡二轮修订：**iCloud 并发归并冲突收敛在 Topic 归属关系上**（幂等建 Topic） | 归并不改 source（决策 4），故无「source 单调升级」一说；冲突只在 Topic 归属关系上合并（见 §6.4） |
| 8 | **原第一版拆 P1 / P1.5 / P2** | P1 只交付抽屉骨架与 AI 标签池；Topic 本地闭环独立为 P1.5；后端收敛为 P2（见 §8） |
| 9 | **`Topic.areaName` 暂不进入 P1** | 当前 Core Data schema 没有该字段；若要做分组，必须作为 schema migration 单独评估 |
| 10 | ⚡二轮新增：**建议级拒绝幂等键 = 主题名 + 来源词集合**（语义级，不含观点 ID/hash） | 观点集合随新增想法动态变化，用观点 hash 做键会导致「拒绝过的主题因新想法再次弹出」，拒绝效力失效（见 §6.4） |
| 11 | ⚡二轮新增：**主主题在展示层取**（按 `thoughts.count` 最高的 active Topic），数据层 `Thought.topics` 多对多不动 | 业务层强制单主题会阉割已存在关系，且 P2 放开多主题需迁移；展示层取主零迁移（见 §7.3） |
| 12 | ⚡二轮新增：**右边缘左滑关闭明确归入 P1.5**，P1 关闭只靠点击右侧区域 | 避免 §5.2 承诺的手势在 P1 弹性化后无人承接成为孤儿（见 §5.2/§8） |
| 13 | ⚡二轮新增：**P1 抽屉 Topic 区需空态设计** | Topic 表当前零业务数据，P1「只读展示已有 Topic」实际恒为空，需空态避免误导（见 §8 P1） |
| 14 | ⚡二轮新增：**`Topic.thoughtCount` 不维护缓存，按 `thoughts.count` 实时算** | 多对多 + iCloud 异步合并下，Int16 缓存与实际数量会漂移（见 §8 P1.5） |
| 15 | ⚡三轮新增：**被主题收纳的判断必须是 Thought + Tag + Topic 三者交集** | 只看 `tag ∈ Topic.associatedTags` 会误伤同名标签，把未归入该 Topic 的观点也从 AI 标签池隐藏（见 §6.3） |
| 16 | ⚡三轮新增：**`Topic.associatedTags` 是机器可查询主源，`associatedTagNames` 仅作展示缓存/兼容字段** | 收纳降权、筛选和 iCloud 合并都需要 relationship 主源；string 字段不能承担查询语义（见 §6.3/§7.3） |
| 17 | ⚡三轮+四轮定稿：**P1.5 不加 `canonicalKey`**，Topic 幂等用运行时归一化查询 + 同步后合并 | 避免 schema migration；归并前用 `normalized(title)` 查同名 Topic，CloudKit 同步后用现有 `mergedToTopic` 关系合并重复；强幂等留待 P2 多设备高频归并再评估（见 §6.4） |
| 18 | ⚡三轮+四轮定稿：**P1 的 AI 整理入口只做统计/预告，不触发归并**；文案「待整理 N 条 .ai 标签」，点击弹「积累后可一键归类，功能开发中」 | P1 是零后端阶段，真实收敛在 P2；入口必须是进度预告而非 dead button（见 §5.4/§8 P1） |
| 19 | ⚡三轮新增：**AI 标签池包含 `.ai + .confirmedAI`，但排除已被 Topic 收纳的 assignment**；⚡四轮定稿：池内计数只算未被收纳的 assignment | `.confirmedAI` 表示单条确认，仍是 AI 标签体系的一部分；不能从池里消失后无处可去（见 §7.2/§8 P1） |

> 实施时横向/边缘手势必须 `UIViewRepresentable + UIGestureRecognizer`，方向判定复用 `HorizontalGestureLock` 的思想；右边缘关闭需要新增同类组件或参数化现有组件，不能直接复用当前左边缘返回 modifier。

---

## 0.1 改动点逐条对照

### 结构层面（新增整节）

- 新增 **§0 / §0.1** 修订摘要与改动对照
- 新增 **§6.4 iCloud 多设备同步**（初稿仅在风险清单提了一句，无设计）
- **§8** 由「第一版范围」重写为「实施分期 P1/P1.5/P2」
- **§11** 由「15 个待审查问题」重写为「15 条对抗审查判定表」
- 新增文末「附：代码事实备查」

### §2 产品目标

- 第 3 条：~~「用户可通过右滑查看知识树，通过左滑回到具体笔记列表」~~ → **顶部菜单按钮唤出抽屉**（决策 1，手势冲突）
- 第 4 条：~~「AI 生成临时标签」~~ → **生成 `.ai` 标签，复用现有 source，不造临时标签概念**（决策 3）

### §3 非目标

- 第 1 条：~~「无限层级知识库」~~ → **第一版固定两层（主题/标签），不做领域实体层级**（决策 2）
- 新增第 8 条：~~全屏右滑/左滑切换抽屉~~（改按钮入口 + 边缘滑动关闭）

### §4 信息架构

- §4.1 层级：~~三层「领域/主题/标签」~~ → **两层「主题/标签」**（决策 2）
- §4.1 删除：~~领域定义~~ → 第一版不做领域；如后续需要分组，另行评估 `Topic.areaName` schema migration
- §4.1 树示例：~~含领域分组~~ → **扁平主题列表**
- §4.1 区块名：~~「临时标签」~~ → **「.ai 标签池」**
- §4.2 新增：**抽屉筛选与底部 Tab 共存规则**
- §4.2 删除：~~「领域 → 展示该领域下所有主题观点」~~（无领域层）

### §5 核心交互

- §5.1 打开方式：~~两种（右滑 + 菜单按钮）~~ → **仅菜单按钮**（决策 1）
- §5.2 关闭方式：~~「页面左滑」~~ → **点击右侧区域（P1）/ 右边缘左滑（P1.5 新增组件）**（决策 12）
- §5.4：⚡四轮定稿 → P1 `AI 整理` 入口文案「待整理 N 条 .ai 标签」+「功能开发中」（决策 18）

### §6 AI 整理流程

- §6.1：~~「AI 自动生成临时标签」~~ → **复用现有 `organizeThought`，不造新概念**
- §6.2：初稿仅列输入/输出 → **新增「数据流与 prompt 设计」**：必须新增 `thought_tag_convergence` purpose；队列只能复用节流/重试思想，不能直接塞进单条打标队列（决策 5）
- §6.3 确认后：⚡二轮 → **归并不改 source（保持 `.ai`）**（决策 4 修订）；⚡三轮 → 收纳语义靠 Thought+Tag+Topic 三者交集表达，来源词写入 `Topic.associatedTags` 主源；⚡四轮 → 来源词 relationship 写入前需 get-or-create `ThoughtTag`
- §6.4：**新增整节** iCloud 并发归并冲突策略；⚡二轮 → 拒绝键改主题名+来源词（决策 7 修订、10）；⚡四轮定稿 → P1.5 不加 `canonicalKey`，同步后合并（决策 17）

### §7 数据语义

- 概念分类：~~四类~~ → **三类「手动标签/.ai 标签/主题」**（决策 2、3）
- §7.2：⚡二轮 → **`.confirmedAI` 仅表示单条确认**，不承担主题收纳语义（决策 4 修订）；⚡三轮 → AI 标签池含 `.ai+.confirmedAI` 再按收纳排除（决策 19）；⚡四轮 → 池内计数只算未收纳 assignment
- §7.3：⚡二轮 → **主主题展示层取，数据层多对多不动**（决策 11）；⚡四轮 → 活跃度基准统一用 `thoughts.count`，不用 `updatedAt`/缓存 `thoughtCount`
- §7.4：~~「领域」~~ → **「分组（后置）」**；`Topic.areaName` 是可选 schema migration，不进 P1

### §8 第一版范围 → 实施分期

- 初稿 10 项平铺 → **P1（抽屉骨架 + AI 标签池）/ P1.5（Topic 本地闭环）/ P2（后端收敛）**（决策 8）
- ⚡二轮：P1 关闭只靠点击（右边缘归 P1.5）、P1 Topic 区空态、P1.5 thoughtCount 实时算、P1.5 主主题展示层取
- ⚡三轮：P1 的 AI 整理入口只做空态/统计/预告；P1.5 补收纳判断、来源词主源、Topic 幂等载体
- ⚡四轮定稿：P1 入口文案拍板；P1.5 不加 `canonicalKey`，改同步后合并（决策 17、18）

### §10 与现有实现的关系

- 修正 GLM 一轮误判：~~「`Topic` 已是完整主题模型」~~ → **「Topic 结构已存在，业务闭环未完成」**
- ⚡二轮补充：现有 `confirmAssignment` 已占用 `.confirmedAI`（单条确认），归并不能复用该 source

### §11 风险清单

- 初稿 15 条问题 → **15 条逐条判定**；⚡二轮修订第 2、7 条；⚡四轮第 15 条定稿

### §12 验收标准

- 初稿 10 条混合 → **P1/P1.5/P2 分段验收**；⚡二轮修订 P1.5 第 9 条、P2 第 13 条；⚡四轮定稿 P1 第 5、P1.5 第 11、P2 第 19 条

### §13 结论

- ~~「左侧横向滑出的知识树」~~ → **「顶部菜单按钮唤出的左侧知识树（无全屏右滑手势）」**
- ~~「AI 临时标签补位」~~ → **「复用 .ai source 的标签补位」**
- ~~「用户主动确认的主题归并」~~ → **「先完成 Topic 本地闭环，再新增 thought_tag_convergence purpose；归并不改 source」**

---

## 1. 背景

当前观点模块已经有手动标签、正文内 `#标签`、AI 自动整理队列、`ThoughtTagAssignment`、`Topic` 等基础能力。但现有 AI 自动整理是**单条打标签**：用户写完一条观点后，AI 针对这一条内容生成 1-3 个标签建议（`ThoughtOrganizationService.organizeThought`：单 thoughtId 输入 → 1-3 标签输出）。

这不能满足目标场景：

用户连续写了 10 条 coding 相关观点，AI 第一次可能打出 `AI`、`vibecoding`、`Claude Code`、`代码效率` 等碎片标签。用户希望在某次主动「AI 整理」时，Holo 能识别这些内容都指向同一个长期主题，并把它们收敛到一个稳定知识节点里，例如：

```text
编程实践
  coding
  vibecoding
  Claude Code
  代码效率
```

因此，本方案不是继续增强「单条 AI 打标」，而是把观点模块逐步升级为：

```text
笔记列表 + 左侧知识结构入口
```

用户仍然轻量记录观点；Holo 先用 `.ai` 标签补位，随后在用户主动整理时把零散观点收敛成长期主题。这里要注意：当前代码已有 `Topic` 数据结构，但还没有完整的 Topic 创建、关联、筛选和归并业务闭环。

## 2. 产品目标

1. 保留现有观点列表的轻量记录体验。
2. 在观点页通过**顶部菜单按钮**唤出左侧标签树/知识树抽屉（删除初稿「右滑打开」，见决策 1）。
3. 用户选择树节点后，右侧笔记列表即时切换筛选结果。
4. AI 在用户不手动添加标签时生成的 `.ai` 标签，用作后续整理信号（复用现有 source，不造「临时标签」概念，见决策 3）。
5. 用户主动触发 `AI 整理` 后，系统提出可确认的主题归并建议。
6. 用户确认后，`.ai` 标签被收敛为稳定主题；手动标签不被静默删除。
7. 让用户逐渐看到「我长期在想什么」，而不是只看到一堆碎标签。

## 3. 非目标

第一版不做以下能力：

1. 无限层级知识库。第一版最多两层（主题 / 标签），不做「领域」实体层级（见决策 2）。
2. 拖拽重排树节点。
3. AI 静默自动改写用户标签。
4. 多主题复杂图谱。
5. 独立重型主题详情页。
6. 全量历史标签一次性清洗。
7. 复杂知识库管理后台。
8. 全屏右滑/左滑切换抽屉的手势（改用按钮入口 + 边缘滑动关闭）。

## 4. 信息架构

观点模块主界面由两个横向相邻区域组成：

```text
左侧：知识树抽屉（默认收起，菜单按钮唤起）
右侧：具体笔记列表（默认态）
```

默认状态是右侧笔记列表。左侧知识树通过顶部菜单按钮打开。抽屉打开后，用户可通过**右边缘左滑**关闭抽屉回到笔记列表（P1.5 实现，需新增右边缘手势组件，不能直接复用左边缘返回 modifier）。

### 4.1 左侧知识树

知识树为**两层**（砍领域层）：

```text
主题
  标签 / 来源词
```

定义：

- 主题：一组反复出现的思考方向，例如 `编程实践`、`AI 协作`。对应现有 `Topic` 实体。
- 标签：具体入口词、来源词，例如 `coding`、`vibecoding`、`Claude Code`。对应现有 `ThoughtTag` / `ThoughtTagAssignment`。

> 第一版不做领域分组。若后续确需分组，可评估新增 `Topic.areaName: String?` 字段，但这是 Core Data schema migration，不是当前已有字段。

左侧树建议包含以下区块：

```text
观点
42 笔记 / 9 主题 / 31 天

最近记录热力图

全部笔记

编程实践 10
AI 协作 6
产品判断 5
习惯复盘 8
财务反思 4

AI 整理 3
未归类 9

.ai 标签池
  coding 7
  vibecoding 3
```

### 4.2 右侧笔记列表

右侧继续复用现有观点列表心智（`ThoughtListView` 已具备标题、搜索栏、筛选 chip、卡片列表、新建按钮、底部 Tab）：

- 顶部标题。
- 搜索栏。
- 筛选 chip。
- 观点卡片列表。
- 新建按钮。
- 底部 Tab（现有 `ThoughtTab` list/add）。

抽屉筛选状态与底部 Tab 状态需明确共存规则——抽屉选中主题时作用于「列表」Tab 内容，不影响「新增」Tab；切回「全部笔记」节点即清除筛选。

不同树节点对应不同列表状态：

```text
全部笔记 -> 展示全部观点
主题 -> 展示该主题下观点（需补 Thought.topics 筛选能力）
.ai 标签池 -> 展示命中该 .ai 标签的观点
AI 整理 -> 展示待确认整理建议
未归类 -> 展示还未进入任何 Topic 的观点
```

## 5. 核心交互

### 5.1 打开知识树

仅保留一种入口——**点击左上角菜单按钮**。删除初稿「在观点列表右滑打开」（与左边缘返回手势、卡片左滑、标签横滑冲突，见决策 1）。

打开后，左侧知识树完整展示，右侧笔记列表被推到右侧边缘保留可见，提示用户可关闭抽屉。

### 5.2 关闭知识树回到笔记列表

⚡ 二轮修订（决策 12）：分两期实现——

1. **P1**：点击右侧笔记区域关闭。
2. **P1.5**：从**右边缘左滑**关闭（新增 `RightEdgePanOverlay` 或参数化现有 edge-pan 组件，复用 `HorizontalGestureLock` 方向判定思想）。

回到列表后，左侧收起，不占用主要阅读空间。

### 5.3 选择树节点

点击某个树节点后：

1. 左侧节点进入选中态。
2. 右侧标题切换为该节点名称。
3. 右侧列表筛选为该节点相关观点。
4. 搜索栏默认搜索当前范围。
5. 筛选 chip 展示当前范围和 AI 整理入口。

### 5.4 AI 整理入口

`AI 整理` 位于左侧知识树中，也可保留为右侧列表顶部 chip。

当存在待整理建议时显示数量，例如：

```text
AI 整理 3
```

点击后进入整理建议确认流程，而不是立即静默改写数据。

⚡ 三轮+四轮定稿（决策 18）：在 P1 零后端阶段，`AI 整理` 入口**只做统计/预告，不触发跨观点归并、不展示假建议**。入口显示「待整理 N 条 .ai 标签」（N = 当前 `.ai` 标签数），点击弹出说明「积累后可一键归类，功能开发中」。P2 上线 `thought_tag_convergence` 后，该入口才进入真正的归并建议确认流程。

## 6. AI 整理流程

### 6.1 单条观点保存后

用户保存观点时：

1. 如果用户手动添加了标签，保留用户标签。
2. 如果用户没有手动添加标签，AI 自动生成 `.ai` 标签（**复用现有 `organizeThought` 流程，不造「临时标签」新概念**）。
3. `.ai` 标签只作为候选信号，不直接进入稳定知识树。

示例：

```text
观点 A -> .ai 标签：vibecoding
观点 B -> .ai 标签：Claude Code
观点 C -> .ai 标签：代码效率
```

### 6.2 用户主动触发 AI 整理（跨观点收敛）

这是方案的核心增量，初稿只问没答。

用户点击 `AI 整理` 后，系统分析：

- 观点原文或摘要。
- `.ai` 标签。
- 手动标签。
- 已有主题树（`Topic` 集合）。
- 已拒绝过的**建议**（建议级，非标签级）。
- 来源词。

AI 输出候选归并建议：

```text
发现可收敛主题：编程实践
建议归入主题：编程实践
关联观点：10 条
来源词：AI、vibecoding、Claude Code、代码效率
```

**数据流与 prompt 设计（必须）**：

- 现有 `thought_organization` purpose 是单条→单条打标签，**无法承载** batch 收敛。必须**新增后端 purpose `thought_tag_convergence`**（见决策 5）。
- prompt 结构：输入「N 条观点摘要 + 现有 `.ai` 标签聚合 + 现有 `Topic` 列表 + 已拒绝建议」，输出「归并建议数组（主题名 / 关联观点 ID / 来源词）」，JSON mode。
- 遵循 CLAUDE.md Prompt 双端同步：后端 `defaultPrompts.json` + `promptRegistry.js` + iOS `PromptManager` 后备模板 + 升版本号 + `docker compose build --no-cache` 重建部署 + `/v1/prompts/thought_tag_convergence` 验证。
- iOS 端**不能直接复用**现有 `ThoughtOrganizationQueue` 作为执行队列：它的输入、状态和重试终态都围绕单条 `thoughtId` 与 `Thought.organizedStatus`。P2 应新增 `ThoughtTagConvergenceJob` 或独立收敛任务状态；可以复用现有队列的节流、重试、rateLimited 暂停、断点续做等设计思想。

### 6.3 用户确认归并

整理建议必须经过用户确认。

用户可操作：确认归并 / 改名 / 移动到其他主题 / 暂不处理 / 拒绝该建议。

⚡ 二轮修订（决策 4）：确认后的数据迁移路径明确如下：

1. 相关观点关联到目标 `Topic`（`Thought.topics` 多对多，需 P1.5 补 Repository/Service）。**这是「观点被收纳进主题」的唯一表达**——观点是否属于某主题，看 `Thought.topics` 是否含该 Topic。
2. ⚡ 四轮定稿：目标 `Topic.associatedTags` 写入来源词对应的 `ThoughtTag` 关系（来源词对应的 `ThoughtTag` 可能尚不存在，**写入 relationship 前必须 get-or-create `ThoughtTag`**）；`Topic.associatedTagNames` 仅作为展示缓存/兼容字段，可由 `associatedTags.name` 派生。来源词保留为主题下来源词，不再作为主导航入口展示。
3. ⚡ 二轮：相关 `.ai` `ThoughtTagAssignment` 的 **source 保持 `.ai` 不变**（不升级、不删除、不新增枚举）。理由：现有 `confirmAssignment` 已用 `.confirmedAI` 表示「用户单条确认保留某 AI 标签」，归并若再升 `.confirmedAI` 会与单条确认撞语义，系统无法区分（见决策 4）。
4. 用户手动标签（`manual`/`inline`）**不动**，永不自动删除。
5. 未来相似 `.ai` 标签优先进入待确认池，下次整理优先建议归到该主题。

> ⚡ 三轮展示规则（P1.5 落实，决策 15/16/19）：被主题收纳的 assignment 才从 AI 标签池移除。判断必须是三者交集，不是只看 tag：  
> `assignment.thought ∈ activeTopic.thoughts` AND `assignment.tag ∈ activeTopic.associatedTags` AND `assignment.source ∈ [.ai, .confirmedAI]` AND `assignment.rejectedAt == nil`。  
> 这样可以避免 `AI`、`coding` 这类同名标签被某个 Topic 收纳后，把其他未归入该 Topic 的观点也从 AI 标签池误删。

### 6.4 iCloud 多设备同步

归并是多步写操作（建/更新 Topic → 关联 thought），在 `NSPersistentCloudKitContainer` 下多设备并发会冲突。策略（见决策 7、10、17）：

1. **Topic 创建幂等**：按归并建议的主题名 + 来源词集合做幂等键，已存在则复用，避免重复建 Topic。
2. ⚡ 二轮修订：归并不改 source（决策 4），故无「source 单调升级」问题；冲突收敛在 **Topic 归属关系**上——多设备并发给同一 thought 加 Topic，按 Topic 幂等合并（同 topic 复用），不产生重复 Topic。
3. ⚡ 二轮修订（决策 10）：**建议级拒绝走 Core Data**（建议新增独立实体，如 `ThoughtTagConvergenceRejection`）。**幂等键 = 主题名 + 来源词集合（语义级），不含观点 ID / hash**——观点集合随新增想法动态变化，用观点 hash 做键会导致「拒绝过的主题因新想法再次弹出」。字段：建议 key（主题名+来源词集合 hash）、主题名、来源词、rejectedAt、expiresAt，随 iCloud 同步。现有 `rejectedAITags`（UserDefaults）仅保留单条标签级拒绝。

⚡ 三轮+四轮定稿（决策 17）：P1.5 **不引入 `canonicalKey`**（避免 schema migration）。Topic 幂等策略：归并前用 `normalized(title)`（小写+trim）查询同名 Topic，命中则复用；CloudKit 同步后若出现重复 Topic，用现有 `mergedToTopic/mergedFromTopics` 关系合并去重。强幂等（持久化 `canonicalKey`）留待 P2 多设备高频归并真出现重复问题时再评估。

## 7. 数据语义

产品层区分三类概念（初稿四类，砍「AI 临时标签」）：

```text
手动标签（source: manual / inline）
.ai 标签（source: ai / confirmedAI / rejectedAI）
主题（Topic）
```

### 7.1 手动标签

用户显式添加的标签（`manual`/`inline`），代表用户意图。

规则：

- AI 不得静默删除。
- AI 整理可参考，但不能覆盖。
- 如果需要归并，应在确认界面明确提示。

### 7.2 .ai 标签

复用现有 `source` 枚举，**不造「AI 临时标签」新概念**（见决策 3）。

- `.ai`：AI 在用户未手动添加标签时生成的补位标签，也是**归并收纳后的稳定 source**（决策 4 修订：归并不改 source）。低权重，可展示但应标明 AI 来源。
- `.confirmedAI`：⚡ 二轮修订：**仅表示「用户单条确认保留的 AI 标签」**（现有 `confirmAssignment` 的语义，ThoughtOrganizationService:145）。**不用于表达主题归并收纳**——收纳语义改由 Topic 归属表达，避免两种「确认」共用一个 source 造成语义撞车（见决策 4）。
- `.rejectedAI`：用户拒绝过的 AI 标签，`isVisible = false`。
- ⚡ 三轮修订（决策 19）：AI 标签池的数据源包含 `.ai + .confirmedAI`，但排除已被 Topic 收纳的 assignment。`.confirmedAI` 如果未被主题收纳，仍应出现在 AI 标签池中，并用视觉区分「AI 建议」/「已确认」。
- ⚡ 四轮定稿（决策 19）：AI 标签池中每个标签后的**计数只统计未被 Topic 收纳的 assignment 数**（如 `coding` 共 7 条 assignment、3 条已入主题，池里显示 `coding 4`）。
- ⚡ 三轮修订（决策 15）：是否被主题收纳，不看 source，也不只看 tag；必须同时满足 `assignment.thought ∈ activeTopic.thoughts` 与 `assignment.tag ∈ activeTopic.associatedTags`。

### 7.3 主题

主题是一组观点的稳定聚合（`Topic` 实体），例如 `编程实践`。

规则：

- 用户主要通过主题浏览长期思考结构。
- 主题下可以有多个来源词。⚡ 三轮修订（决策 16）：`associatedTags` 是机器可查询主源；`associatedTagNames` 仅作展示缓存/兼容字段，可为空或由 relationship 派生，避免双写不一致。
- ⚡ 二轮修订（决策 11）：一条观点第一版**最多展示**一个主主题。⚡ 四轮定稿：主主题在**展示层**取——按 `thoughts.count` 最高的 active Topic 显示（不用 `updatedAt`，iCloud 跨设备时钟不可靠；也不用缓存的 `thoughtCount`）。**数据层 `Thought.topics` 多对多关系不动**——不强制单主题、不加主主题字段/排序。这样 P2 放开多主题零迁移。不能把多对多关系直接等同于「主主题」能力，但也不必为了「主主题」阉割它。
- 主题状态机复用现有 `TopicStatus`：`candidate`（候选）→ `active`（正式）→ `merged`（合并到其他主题）/ `hidden`（隐藏）。

### 7.4 分组（原「领域」降级）

第一版不建独立领域实体，也不新增分组字段。如需分组，可在后续版本评估 `Topic.areaName: String?`，仅作展示分组，不构成层级；但这属于 Core Data schema migration，需要单独设计迁移和 CloudKit 兼容。

## 8. 实施分期

原初稿第一版 10 项是 3-4 个迭代的工作量。拆为三段：先做入口和可见标签池，再补 Topic 本地闭环，最后做后端 AI 收敛。

### P1 — 纯本地入口，零后端改动

目标：先把左侧入口、抽屉形态、AI 标签池和未归类入口跑通，不承诺真正主题树已经可用。

1. 顶部菜单按钮打开左侧知识结构抽屉（无右滑打开手势）。
2. ⚡ 二轮修订（决策 12）：**点击右侧区域关闭**。右边缘左滑关闭明确归入 P1.5，P1 不做，避免手势成为孤儿。
3. 抽屉展示：全部笔记、未归类、AI 标签池、AI 整理入口。
4. ⚡ 三轮修订（决策 19）：AI 标签池按 `ThoughtTagAssignment(source: .ai 或 .confirmedAI)` 聚合展示；P1 尚无 Topic 收纳关系，因此不做收纳排除，只区分「AI 建议」与「已确认」视觉态。点击后按 assignment 关系筛选观点。
5. 抽屉筛选与底部 Tab 共存规则（见 §4.2）。
6. ⚡ 二轮修订（决策 13）：抽屉 Topic 区为**空态**（Topic 表当前零业务数据），需空态文案（如「暂无主题，AI 整理后生成」），不展示空主题树误导用户。
7. ⚡ 三轮+四轮定稿（决策 18）：`AI 整理` 入口显示「待整理 N 条 .ai 标签」（N = 当前 `.ai` 标签数），点击弹「积累后可一键归类，功能开发中」；不触发跨观点归并，不展示假建议。

### P1.5 — Topic 本地闭环

目标：让 `Topic` 从「已有结构」变成「产品可用对象」。

1. 新增本地 Topic Repository / Service：创建、查找、更新、隐藏、合并。⚡ 二轮修订（决策 14）：`thoughtCount` **不维护缓存，一律按 `thoughts.count` 实时算**（或进入主题视图时重算），避免多对多 + iCloud 计数漂移。
2. 新增 `fetchByTopic` / `searchWithinTopic` 等查询能力，明确是否包含 archived / softDeleted。
3. ⚡ 二轮修订（决策 11）：主主题策略在**展示层**取（按 `thoughts.count`），保存时不强制唯一性、不加主主题字段。
4. ⚡ 三轮修订（决策 16）：主题下展示来源词以 `associatedTags` relationship 为主源；`associatedTagNames` 仅作展示缓存/兼容字段，不作为查询判断依据。
5. ⚡ 三轮修订（决策 15/19）：被主题收纳的 assignment 展示降权——判断依据是 `assignment.thought ∈ activeTopic.thoughts` 且 `assignment.tag ∈ activeTopic.associatedTags`，不是 source，也不是单独的 tag 命中。从 AI 标签池移除后，只在主题来源词区展示。
6. 右边缘左滑关闭抽屉手势（决策 12，新增组件，验证不冲突系统返回/卡片左滑/标签横滑/列表竖滑）。
7. 手动调整能力：用户可把观点移入/移出主题，手动标签不被自动删除。
8. ⚡ 三轮+四轮定稿（决策 17）：**不加 `canonicalKey`**。归并前用 `normalized(title)` 查同名 Topic 复用；CloudKit 同步后用 `mergedToTopic/mergedFromTopics` 合并重复 Topic。
9. 本地迁移与 CloudKit 行为验证；若新增 `areaName` 或拒绝实体，必须在这一期单独评估 schema migration（`canonicalKey` 本期不加）。

### P2 — 含后端，完整 AI 收敛能力

1. 新增后端 purpose `thought_tag_convergence` + prompt + route（双端同步 + 部署）。
2. 新增 iOS 收敛任务模型（例如 `ThoughtTagConvergenceJob`），不要直接复用单条 `ThoughtOrganizationQueue`。
3. 跨观点归并建议生成 + 用户确认 UI。
4. 确认后数据迁移（§6.3，**不改 source**）。
5. 建议级拒绝存储（Core Data，幂等键 = 主题名+来源词，走 iCloud）。
6. iCloud 并发归并冲突处理（§6.4）。
7. 来源词保留为主题下展示词。

## 9. 设计原则

### 9.1 记录优先
用户写观点不能变复杂。写完即可保存，标签结构由 Holo 后续整理。

### 9.2 结构渐进
知识树不要求用户一开始手动搭建。它应该随着观点积累逐渐长出来。

### 9.3 确认后生效
AI 可以建议，但不能偷偷改用户的知识结构。

### 9.4 不把标签树做成负担
左侧树是导航和整理入口，不是重型知识库管理后台。

## 10. 与现有实现的关系

`Topic` 的 Core Data 结构已经存在，但产品业务闭环尚未完成。

当前已有能力可复用：

| 现有实现 | 复用点 |
|---|---|
| `Thought` | `topics` 多对多关系已通，`organizedStatus` 状态机完整 |
| `ThoughtTag` / `ThoughtTagAssignment` | `source` 五类枚举完整，直接承载手动/.ai/确认/拒绝 |
| `Topic` | **结构性实体已存在**：`title/summary/status/confidence/associatedTagNames/thoughtCount` + `thoughts`/`associatedTags` 关系 + `mergedToTopic/mergedFromTopics` + `TopicStatus`(candidate/active/hidden/merged) 状态机 |
| `ThoughtOrganizationService.confirmAssignment` | ⚡ 二轮：已占用 `.ai → .confirmedAI` 表示单条确认；归并不能复用该 source（决策 4） |
| `ThoughtOrganizationService` | 单条打标签流程（P1 复用），P2 需新增跨观点收敛能力 |
| `ThoughtOrganizationQueue` | 串行、节流、rateLimited 暂停、断点续做等设计可参考；不能直接作为 P2 收敛任务队列 |
| `ThoughtOrganizeActionChip` / `ThoughtListView` / `ThoughtCardView` | UI 复用 |

当前缺口：

1. `Topic` 缺本地业务闭环：Repository / Service、创建与关联、按 Topic 筛选、计数维护、主题合并/隐藏的 UI 与测试。
2. AI 整理仍是单条打标签，不是跨观点收敛（P2 新增 purpose）。
3. `.ai` 标签和现有 `Thought.tags` 展示/筛选路径割裂：左侧 `.ai` 标签池应直接基于 `ThoughtTagAssignment` 聚合，不能依赖 `Thought.tags`。
4. 领域分组后置；不需要新增领域模型，`Topic.areaName` 若引入必须作为 schema migration。
5. 来源词语义：模型层同时有 `Topic.associatedTagNames` 和 `associatedTags`，本方案定 `associatedTags` 为主源、`associatedTagNames` 为展示缓存/兼容字段。
6. 缺少用户确认归并 UI。
7. ⚡ 四轮定稿（决策 17）：Topic 幂等 P1.5 不加 `canonicalKey`，用运行时归一化查询 + 同步后 `mergedToTopic` 合并。
8. 不引入全屏横向滑动树导航（手势冲突），改按钮入口。

## 11. 风险与对抗审查判定

| # | 风险 | 判定 |
|---|---|---|
| 1 | 三层结构是否过重 | **过重，砍到两层**。第一版不做领域；后续如需分组再评估 `areaName` migration（决策 2） |
| 2 | 一条观点多主题 vs 单主主题 | ⚡二轮：**展示层取主主题**，数据层 `Thought.topics` 多对多不动（决策 11） |
| 3 | AI 临时标签与手动标签 UI 混淆 | **复用 `.ai/.confirmedAI` source，UI 按单条确认态与 Topic 收纳态区分展示**，删新概念（决策 3、4、19） |
| 4 | 来源词是否可点击筛选 | **第一版不可点**，只展示。可点击=重复筛选路径 |
| 5 | 领域独立实体 vs 字段缓存 | **第一版不做领域**。`Topic.areaName` 只能作为后续 schema migration 候选 |
| 6 | `Topic` 是否够承载 | **结构够，业务闭环不够**。需 P1.5 补 Repository、筛选、计数、确认/手调 UI |
| 7 | 归并后旧 assignment 处理 | ⚡三轮：**不改 source**，收纳语义靠 Thought+Tag+Topic 三者交集表达 + 写 `associatedTags` 主源 + 调展示范围（决策 4、15、16） |
| 8 | 拒绝后避免重复 | ⚡二轮：**新建建议级拒绝实体（Core Data/iCloud），幂等键=主题名+来源词**，不含观点 hash（决策 6、10） |
| 9 | 手动标签与 AI 主题冲突 | **手动标签永远赢**，冲突时不自动改，仅确认界面提示 |
| 10 | 横向滑动与现有手势冲突 | **确认冲突，砍右滑开抽屉**（决策 1）；右边缘关闭归 P1.5（决策 12） |
| 11 | 未归类与临时标签池边界 | **保留两个入口但共享底层统计**：未归类看未进入 Topic 的观点，AI 标签池看未被 Topic 收纳的 `.ai/.confirmedAI` assignment |
| 12 | 是否新增 purpose | **必须新增** `thought_tag_convergence`（决策 5） |
| 13 | 后端部署如何保证生效 | 遵循 CLAUDE.md 双端同步 + `build --no-cache`（决策 5） |
| 14 | 历史首次整理成本/限流/恢复 | **现有 Queue 的设计可参考，但不能直接复用**；P2 需独立 convergence job |
| 15 | iCloud 同步冲突 | ⚡四轮定稿：**方案已补**（§6.4，决策 7、10、17）；P1.5 用同步后合并（不加 `canonicalKey`），强幂等留 P2 |

## 12. 建议验收标准

**P1 验收**：

1. 用户可点击菜单按钮打开左侧知识结构抽屉，点击右侧区域关闭。
2. 抽屉展示全部笔记、未归类、AI 标签池、AI 整理入口；Topic 区为空态（「暂无主题，AI 整理后生成」），不出现空主题树误导用户（决策 13）。
3. AI 标签池基于 `ThoughtTagAssignment(source: .ai 或 .confirmedAI)` 聚合展示，点击后能筛选对应观点，并区分「AI 建议」/「已确认」视觉态（决策 19）。
4. 现有观点记录、搜索、底部 Tab 体验不被破坏。
5. ⚡四轮定稿：`AI 整理` 入口显示「待整理 N 条 .ai 标签」，点击弹「功能开发中」，不触发跨观点归并（决策 18）。

**P1.5 验收**：

6. 用户或系统可以创建/更新/隐藏 Topic；`thoughtCount` 按 `thoughts.count` 实时算，无缓存漂移（决策 14）。
7. 用户点击主题后，右侧列表按 Topic 正确筛选；搜索可限定在当前主题范围。
8. 一条观点第一版最多展示一个主主题（展示层按 `thoughts.count` 取主），策略有测试覆盖（决策 11）。
9. 被主题收纳的 assignment（Thought+Tag+Topic 三者交集）不再出现在 AI 标签池主入口，只作为主题来源词展示；同名但未进入该 Topic 的 assignment 不受影响（决策 15）。
10. `associatedTags` 是主源，`associatedTagNames` 是展示缓存/兼容字段，不出现双写不一致（决策 16）。
11. ⚡四轮定稿：Topic 幂等——归并前 `normalized(title)` 查重命中复用；CloudKit 同步后重复 Topic 可用 `mergedToTopic` 合并（决策 17，不加 `canonicalKey`）。
12. 右边缘左滑关闭抽屉已实现，且不影响系统返回、卡片左滑、标签横滑、列表竖滑（决策 12）。

**P2 验收**：

13. AI 整理能基于多条观点提出主题归并候选（`thought_tag_convergence` purpose）。
14. iOS 使用独立收敛任务模型承载 batch job，不复用单条打标队列的 thoughtId 状态机。
15. 用户确认归并后，相关观点进入对应主题，旧 `.ai/.confirmedAI` assignment **source 不变**，按 Thought+Tag+Topic 三者交集降权展示（决策 4、15）。
16. 用户手动标签不被自动删除。
17. 被归并的来源词保留为主题下展示词，并写入 `associatedTags` 主源。
18. 被拒绝的建议不会短期内重复出现（建议级拒绝，幂等键=主题名+来源词，走 iCloud）（决策 10）。
19. ⚡四轮定稿：多设备并发归并——同步后重复 Topic 可检测并合并（决策 17）；若 P2 多设备高频归并暴露重复问题，再评估加 `canonicalKey`。
20. 后端改动部署后 `/v1/prompts/thought_tag_convergence` 验证通过，才算上线完成。

## 13. 结论

推荐方向：

```text
保留现有观点列表
+ 顶部菜单按钮唤出的左侧知识树（无全屏右滑手势）
+ 复用 .ai source 的标签补位
+ P1.5 补齐 Topic 本地闭环（归并不改 source，收纳靠 Thought+Tag+Topic 三者交集）
+ 用户主动确认的主题归并（P2 新增 thought_tag_convergence purpose）
```

这个方向能兼顾三件事：

1. 观点记录仍然轻量。
2. P1 可以先把入口和 AI 标签池做出来，不被 Topic 空数据卡死。
3. Holo 能逐渐形成用户的个人知识结构。

最终用户感受应该是：

> 我不需要每次写观点都想分类。Holo 会先帮我暂存，等内容积累够了，再告诉我：这些想法其实都在指向同一个主题，要不要归到这里？

---

## 附：本次审查核实的代码事实（备查）

- `ThoughtsView` 为 `fullScreenCover`（`HomeView.swift:223`）+ `.swipeBackToDismiss`（左边缘右滑返回）；内部有底部 Tab（`ThoughtTab` list/add）。
- `ThoughtListView`（633 行）含：垂直 `ScrollView`（主列表）、水平 `ScrollView`（标签 chip 横滑，:483）、`SwipeActionView` 卡片左滑（:541，配合 `revealedThoughtId`）。
- `Topic` 字段：`id/title/summary?/status/confidence/associatedTagNames?/thoughtCount/createdAt/updatedAt` + 关系 `thoughts/associatedTags/mergedToTopic/mergedFromTopics` + `TopicStatus`(candidate/active/hidden/merged)。
- `Topic` 当前**无 Repository**；`ThoughtRepository` 中 `Topic` 仅出现在删除 nullify（:321）与清库（:498）；`addTopics` 仅有 @NSManaged accessor，**零业务调用**；`Topic+CoreDataClass.swift` 顶部注释自述「v1a 只建表，不实现主题匹配/摘要/升级流程」。Topic 表当前零业务数据。
- `Topic` 当前没有 `areaName` / `canonicalKey` 字段；如需领域分组或强幂等，需要 Core Data schema migration。
- `ThoughtTagAssignment.source`：`manual/inline/confirmedAI/ai/rejectedAI`，`isHighPriority`、`isVisible` 已实现。
- ⚡ 二轮：现有 `ThoughtOrganizationService.confirmAssignment`（:145）已占用 `.ai → .confirmedAI` 表示**单条确认**；故主题归并收纳不能再复用 `.confirmedAI`，改保持 `.ai`、靠 Thought+Tag+Topic 三者交集表达收纳（决策 4、15）。
- 现有 AI 标签 UI 会展示 `.ai` 与 `.confirmedAI`；source 升级不会自动改变展示位置，收纳降权必须按 Thought+Tag+Topic 三者交集判断。
- `ThoughtOrganizationService.organizeThought`：单 thoughtId → 1-3 标签，配 `rejectedAITags`（UserDefaults，90 天/50 条，标签级）。
- `ThoughtOrganizationQueue`：串行、`itemInterval=4s`、`rateLimited` 暂停、`rebuildFromDatabase` 续做、`batchTotal/batchCompleted` 进度；但输入和状态机围绕单条 thoughtId，不能直接承载跨观点收敛 job。
- 后端 `config.js:63` 已有 `thought_organization` purpose；`defaultPrompts.json` 无 `thought_tag_convergence`。
