# 意图识别与数据问答路由——长期架构方案

- 日期：2026-08-15
- 状态：待东林拍板（决策点见 §7）
- 性质：架构演进方案，分五阶段走，每阶段可独立验收与回滚
- 事实基础：2026-08-15 全链路调研（样本=modify_task_items 提交 4b552597 实测；后端 prompt 与护栏测试实测；Agent 机制实测）

---

## 0. 一页摘要

**问题**：AI 认识「系统有哪些能力、有哪些数据」靠三份手工维护的平行清单——后端意图提示词、客户端兜底提示词、聊天上下文注入块。每加一个意图动 14 个文件（其中 6 个插入点是双份重复维护），每加一类数据动 3 处并手写专属规则。后端意图提示词已 5005/5100 字符（护栏红线只剩 95 字符），下次加意图即顶爆。

**终态**：路由二分法。
- **执行类意图**（记账/建任务/打卡这类有固定表格要填、确认后本地落库的动作，约 15 个，增长慢）→ 保留轻量意图识别；
- **一切问答/查询/分析**（增长快、无穷尽）→ 交给 Agent。Agent 的工具目录天然自描述（这套机制项目里已建成：HoloToolDescriptor + 动态数据集 schema + 自动渲染），**新数据 = 注册一个数据集，零提示词改动**。

**路径**：P0 数据上下文注册表（治数据接入）→ P1 意图注册表（治双份维护）→ P2 问答灰度切 Agent → P3 意图识别瘦身 → P4 清理。全程灰度可回滚，不动执行类主链路。

---

## 1. 现状定量诊断

### 1.1 新增一个意图的真实成本（实测样本）

以 4b552597「对话式改任务条目」为样本：**2 仓库 14 文件、约 +365 行**。

| 类别 | 位置 | 性质 |
|---|---|---|
| 功能实现（合理成本，保留） | AIIntent 枚举、IntentRouter handler、ChatCardData、卡片 UI、ChatViewModel 接线 | 新功能本身的代码 |
| 提示词重复维护（**补丁成本，消灭对象**） | 后端 defaultPrompts.json 意图清单+2 条示例；客户端 PromptManager 兜底意图行+2 条示例；AIUserContextMessageBuilder 备忘单注入块 | 同一份知识写了 6 个插入点、两份副本 |
| 护栏维护（**补丁成本**） | prompts.test.js 长度红线 4700→5100 手动抬升 | 每加一次意图抬一次 |

### 1.2 新增一类数据的真实成本

以纪念日（2026-08-15 刚发生）为样本：UserContextBuilder 构行 + AIUserContextMessageBuilder 意图识别块（含专属路由规则）+ chat 块，共 3 处手写。且每类数据都让意图识别上下文再膨胀一块。

### 1.3 已经存在但未被复用的自描述机制

Agent 侧已建成完整的「能力自描述」：
- `HoloToolDescriptor`（HoloDataTool.swift:30-38）：每个工具声明名称/描述/支持查询/时间范围/输出度量/敏感度；
- `HoloAgentDynamicCatalogs`（HoloDataTool.swift:268-300）：12 个数据集带字段级 schema 元数据（type/unit/filterable/groupable/aggregatable）；
- `HoloToolRegistry.promptDescription()`：把上述自动序列化给 LLM——**这正是意图识别缺失的「单一事实源自动渲染」**；
- `HoloAgentToolCoverage` 白名单断言：注册即校验，防止漏配。

### 1.4 两套理解体系的割裂

- 意图识别（LLM）与 Agent 的 SemanticFrame（关键词规则）各自独立理解同一句话；意图识别产出的时间语义/领域提示（extractedData）**不传给 Agent**，Agent 重建一遍。
- 「离妈妈生日还有多久」这类数据问答，当前靠往意图识别上下文塞数据清单 + 专属规则解决（打补丁模式的典型）。

---

## 2. 终态架构

```
用户输入
   │
   ▼
┌─────────────────────────────┐
│ 轻量意图识别（瘦身后）        │   只回答一个问题：这是不是执行类动作？
│ · 是 → 输出执行意图+表格数据  │   （record_expense / create_task / check_in …）
│   （确认卡片流，本地落库）    │
│ · 否/纯问答 → 转 Agent       │
└─────────────────────────────┘
   │                    │
   ▼                    ▼
 执行链路            Agent（工具目录自描述）
 （现状保留）        · 数据问答：纪念日/习惯/任务/目标/财务/健康…
                    · 分析：query_analysis
                    · 单值查询：flexible_data_query
                    新数据 = 注册数据集 schema → 模型自动认识，零提示词改动
```

### 2.1 判定标准：什么留在执行类

一个意图留在轻量意图识别，当且仅当同时满足：
1. **强 schema**：输出是固定表格字段（金额/日期/标题…），确认后本地执行，回复文案不需要 LLM 生成；
2. **低频增长**：动作类型本身不会随数据积累而增加。

当前 21 个意图值中约 15 个符合（记账 2、任务 5、打卡 1、目标 3、笔记/心情/体重 3、unknown）；6 个不符合（query 系 4、memory_insight 1、以及未来一切新增数据问答）。

### 2.2 三份手工清单的归宿

| 现状清单 | 终态 |
|---|---|
| 后端意图提示词（意图清单+示例+分流规则） | 骨架化：通用规则保留，意图清单段由意图注册表渲染产物维护（走 managedPrompts 热更新通道），护栏测试改为「断言与注册表一致」 |
| 客户端 PromptManager 兜底提示词 | 从意图注册表**自动生成**，双份维护归一 |
| 聊天/意图识别上下文注入块 | 数据上下文注册表（AIContextSection）统一供给，chat 与意图识别两个消费者按预算取用 |

---

## 3. 设计原则（谨慎条款）

1. **执行类主链路全程不动**：记账/建任务/打卡的确认卡片流是产品核心路径，五阶段中任何改动不触碰其行为；每阶段验证含「执行类意图回归评测全绿」。
2. **每阶段独立可回滚**：所有路由行为变化挂 feature flag（沿用 HoloAIFeatureFlags 模式），回滚=关开关，不发版。
3. **先建尺子再动刀**：任何架构改动前先固化评测基线（§4 P0），没有基线的重构都是盲飞。
4. **单一事实源**：能力的定义只允许存在一处（注册表），其他一切（prompt/护栏/兜底）都是它的渲染产物。禁止新增手写清单。
5. **灰度对照**：问答切 Agent 采用用户级灰度，对照指标固化（§4 P2），异常自动回落。
6. **不动后端 prompt 的既有护栏语义**：长度红线、内容断言在 P1 改造为「注册表一致性断言」，保护强度不降低。

---

## 4. 分阶段演进路线

### P0 地基：评测基线 + 数据上下文注册表（约 2 天，纯客户端）

**评测基线**
- 从 ChatMessage 历史抽取真实用户输入样本 150-200 条（覆盖全部 21 意图 + 歧义句 + 纯闲聊），人工校对标注期望意图；
- 复用 HoloAgentEval 跑法建 `intent_eval` 回归集：每次改 prompt/路由前后跑，意图准确率不得低于基线 -2pp；
- 基线报告落盘 docs/holoai-audit/（沿用体检档案目录）。

**AIContextSection 注册表**
```swift
protocol AIContextSection {
    var id: String { get }                  // "anniversaries" / "recentTask" / …
    func chatLines(context: UserContext) -> [String]        // chat 上下文行
    func intentLines(context: UserContext) -> [String]?     // 意图识别上下文行（nil=不注入）
    var intentRules: [String] { get }       // 专属路由规则（如纪念日→query 不 clarification）
    var priority: Int { get }               // 预算裁剪顺序
}
```
- UserContextBuilder/AIUserContextMessageBuilder 遍历注册表渲染，删除现有手写块；
- 迁移前三个 section：纪念日、最近关联任务、数据覆盖度（吃狗粮）；
- 新数据接入成本：3 处手写 → 1 个文件。

**验收**：意图评测基线报告产出；三块迁移后 diff 对比上下文渲染逐字节等价（或差异可解释）；iOS 编译+既有测试全绿。
**回滚**：纯客户端，revert 即回。

### P1 意图注册表 + 后端提示词骨架化（约 3 天，客户端+一次后端发版）

**IntentDescriptor 注册表（客户端）**
```swift
struct IntentDescriptor {
    let intent: AIIntent
    let summary: String          // 一句话定义（进提示词）
    let examples: [String]       // few-shot 2 条（进提示词）
    let routingHints: [String]?  // 分流提示（仅 query 歧义类需要）
    let requiredFields: [String] // 供 AIParseBatchValidator 自动断言
}
```
- 一处注册 → 自动渲染三处：客户端兜底 prompt、chatDisplayLabel 元数据、解析校验 requiredFields；
- PromptManager 兜底 prompt 从 3 处手写点变为渲染产物。

**后端 intent_recognition 骨架化**
- 意图清单+示例段从 defaultPrompts.json 静态文本迁出，改为：意图定义 JSON（与客户端 IntentDescriptor 同构）随 promptRegistry 的 managedPrompts 通道热更新；
- 通用规则（日期映射/字段规则/分流总则）保留骨架；
- 护栏测试改造：长度红线保留（防膨胀反弹），内容断言改为「渲染产物包含全部注册意图且无未注册意图」——从「防删旧」升级为「防漏新」；
- **需后端发版一次**（迁移 intent prompt 结构）。

**验收**：新增一个玩具意图（测试用）的实测成本 ≤ 3 个文件（注册表 1 + 枚举 1 + handler 1）；意图评测基线不降。
**回滚**：客户端 revert；后端 promptRegistry 支持版本回滚（已有历史机制）。

### P2 问答灰度切 Agent（1-2 周观察期，客户端为主）

**范围**：`query`（普通问答）与 `flexible_data_query`（单值查询）两类意图，从「意图识别→本地组装上下文→chat/查账」改为「→ Agent 工具目录」。`query_analysis` 已走 Agent（现状），不动。

**改动**
- ConversationCoordinator.shouldRouteToDeepAgent 扩围（挂 flag `agentQueryRoutingEnabled`，默认关，灰度开）；
- **意图识别产出下传**：extractedData 的时间语义/领域提示传给 Agent（替代 SemanticFrame 重建一半工作，两者并存互校）；
- **快路径**：SemanticFrame 判定「数据已在聊天上下文」的简单事实问（如纪念日），跳过 Agent 工具循环直接流式回复——防「问个生日也跑十轮工具」的时延回退；
- Agent 数据集补齐：anniversary（新注册一个动态数据集 schema，作为「新数据零 prompt 接入」的首个实战）。

**灰度与对照**
- 用户级灰度（deviceID 哈希 10%→50%→100%）；
- 对照指标（每周看）：首字节时延 p50/p90、答案证据率（evidenceIDs 命中）、用户点踩率、Agent 步数分布、token 成本/请求；
- 任一指标越线（时延 p90 +50%、点踩率翻倍）自动回落开关。

**验收**：灰度期间指标达标；意图评测基线中 query 类准确率不降（此时意图识别只需判「是不是 query」，反而更简单）。
**回滚**：关 flag，回到现链路。

### P3 意图识别瘦身（P2 稳定 2-4 周后，一次后端发版）

- 从 intent prompt 移除 query_tasks / query_habits / query / flexible_data_query / generate_memory_insight 的定义与 few-shot（这些已由 Agent 承接），只保留「数据类问答→转对话 Agent」一条总规则；
- prompt 长度预期从 ~5000 回落到 ~3500 字符，护栏红线同步下调（防再膨胀）；
- 意图枚举保留 case（历史消息解码兼容），路由 switch 的 query 分支统一指 Agent。

**验收**：prompt 长度下降且护栏全绿；全量用户 query 类问答走 Agent 的指标持续达标。
**回滚**：后端 prompt 版本回滚。

### P4 清理（半天）

- 删除双份 prompt 维护残留（PromptManager 手写段）、旧注入块死代码；
- 意图注册表与 Agent 工具目录的关系文档化（哪些能力在哪注册，防止下一代人再建平行清单）；
- CHANGELOG + 本方案文档更新终态。

---

## 5. 风险登记册

| # | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R1 | Agent 多轮工具调用导致问答变慢（vs 意图识别单次） | 中 | 体验回退 | P2 快路径（上下文直答）；预算选择器限步数；流式首字节提前 |
| R2 | Agent 答案幻觉/编数据 | 中 | 信任损伤 | EvidencePolicy/ClaimVerifier 既有校验；灰度期证据率指标；未命中证据的答案显式降级表述 |
| R3 | 双轨期两套理解不一致（意图识别 vs SemanticFrame） | 高（过渡期） | 行为漂移 | extractedData 下传互校；评测集双轨跑分对照 |
| R4 | 后端 prompt 热更新被误改 | 低 | 线上事故 | promptRegistry 版本历史+回滚（已有）；护栏测试断言注册表一致性；admin 改动留 change_note |
| R5 | 灰度样本偏差（重度用户先命中） | 低 | 误判 | deviceID 哈希均匀分桶；按周对比 |
| R6 | token/服务器成本上升 | 中 | 订阅成本 | quota-isolation 桶已有先例，Agent 问答独立配额；步数预算；月度成本观察 |
| R7 | 评测基线本身有错标 | 中 | 尺子歪 | 双人校对（东林抽检 20 条）；歧义样本标「可接受集合」而非单值 |
| R8 | 既有 flaky 测试干扰护栏信号（2026-08-15 实测 prompts.test.js「恢复默认」偶发 500≠302） | 中 | 发布误停 | P0 顺手修该 flaky（测试状态隔离）；CI 重试一次策略 |
| R9 | 执行类意图误伤 | 低 | 核心路径事故 | 三条原则：主链路不动、每阶段执行类回归全绿、行为变化全挂 flag |
| R10 | Agent 承接后意图识别仍被新执行意图膨胀 | 低 | 问题换形复发 | 意图清单冻结：新增执行意图需过「§2.1 判定标准」评审，注册表里留判定记录字段 |

---

## 6. 成本与收益测算

**一次性成本**（按阶段）：P0 约 2 天、P1 约 3 天+1 次发版、P2 约 3 天开发+1-2 周灰度观察、P3 半天+1 次发版、P4 半天。合计约 2 周开发人力 + 2 周自然观察期。

**持续收益**：
- 新增数据域：3 处手写 → 1 个 section/数据集文件（约 -80% 改动量）；
- 新增执行意图：14 文件 6 插入点 → 预期 4-5 文件 1 插入点（prompt 侧归零）；
- 意图 prompt 长度 -30%（P3 后），意图识别本身的准确率随任务变简单而更稳；
- 「AI 认识新数据」从发版级（改后端 prompt）降为客户端版本级（注册数据集），迭代提速一个发布层级。

**不做什么**（明确排除）：不引入 embedding 意图检索/RAG 路由（当前意图规模用不上，复杂度不值）；不重写 Agent runtime；不合并意图识别与 Agent 为单次调用（时延不可接受）。

---

## 7. 需要东林拍板的决策点

1. **P0 何时启动**：评测基线需要从你的真实对话历史抽样本并人工校对（我可以全做，你只需抽检 20 条），是否本周启动？
2. **P2 灰度范围**：方案选了「query + flexible_data_query 两类」（保守）。备选：只 flexible_data_query（最保守）或加 query_analysis 一起（激进，但 query_analysis 已在 Agent，实为顺路）。我推荐当前方案。
3. **P3 瘦身触发条件**：方案写「P2 稳定 2-4 周后」。你若想更快，可改为「指标达标即瘦身」，风险是回滚成本升高。
4. **意图段热更新权限**：P1 后意图清单走 managedPrompts（管理后台可改）。是否限制为「仅代码发版可改意图清单、后台只能改措辞」？我推荐限制（防误操作），实现为：结构字段（意图名/必填字段）锁注册表，后台仅可编辑 summary 措辞。

---

## 附录 A：现状证据索引

- modify_task_items 样本：iOS 4b552597（12 文件 +360 行）、后端 2475e015（2 文件）
- 后端 intent_recognition：本体 4340 字符 + 注入块 2 个 ≈ serve 5005 字符，红线 5100（prompts.test.js:134-137 注释记录 4700→5100 历史）
- few-shot 13 条、意图条目 17 行覆盖 21 值、分流规则 5 条
- Agent 自描述：HoloToolDescriptor / HoloDynamicToolDecorator / HoloAgentDynamicCatalogs（8 数据集）+ health/finance schema / HoloToolRegistry.promptDescription / HoloAgentToolCoverage 白名单断言（HoloToolRegistry.swift:10-34）
- 路由现状：shouldRouteToDeepAgent（ConversationCoordinator.swift:44-54）排除 11 执行意图，query_analysis 恒走，flexible 受 dynamicQuery flag
- 意图识别产物不下传：ChatViewModel.swift:329-348 → HoloAgentAnalysisService.runAnalysis(question:) 只传原文
- 数据问答靠塞上下文的现状样本：纪念日块（AIUserContextMessageBuilder.swift:134-141）、最近任务备忘单（:150-163）、覆盖度（:143-148）

## 附录 B：阶段-文件映射（预期改动面）

| 阶段 | 新文件 | 改动文件 | 后端发版 |
|---|---|---|---|
| P0 | AIContextSection.swift + 3 个 section + intent_eval 语料 | UserContextBuilder / AIUserContextMessageBuilder / AIModels（UserContext 字段） | 否 |
| P1 | IntentDescriptor.swift + intents.json（与后端同构） | PromptManager / AIParseBatchValidator / 后端 promptRegistry+prompts.test.js | 是（1 次） |
| P2 | anniversary 动态数据集 | ConversationCoordinator / HoloAgentAnalysisService（extractedData 下传）/ HoloAgentRuntimeShared / SemanticFrameBuilder（快路径）/ FeatureFlags | 否 |
| P3 | — | 后端 defaultPrompts.json（删段）+ prompts.test.js 红线 / IntentRouter（query 分支归一） | 是（1 次） |
| P4 | — | 删死代码 | 否 |
