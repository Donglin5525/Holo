# 意图识别与数据问答路由——长期架构方案

- 日期：2026-08-15（v3 实施完成版）
- 状态：**P0-P4 已全部实施**（2026-08-15，待东林验收；后端发版清单见 §9）
- 性质：架构演进方案，分阶段走，每阶段可独立验收与回滚
- 事实基础：2026-08-15 全链路调研（样本=modify_task_items 提交 4b552597 实测；后端 prompt 与护栏测试实测；Agent 机制实测）；三轮对抗审查（6 个独立核查 agent 对代码逐条对质）

---

## 0. 一页摘要

**问题**：AI 认识「系统有哪些能力、有哪些数据」靠三份手工维护的平行清单——后端意图提示词、客户端兜底提示词、聊天上下文注入块。每加一个意图动 14 个文件（含后端发版），每加一类数据动 3 处并手写专属规则。后端意图提示词已 5005/5100 字符（红线只剩 95 字符，模型实见约 5966 含人设前言），下次加意图即顶爆。

**终态**：路由二分法。
- **执行类意图**（记账/建任务/打卡这类有固定表格要填、确认后本地落库的动作，约 15 个，增长慢）→ 保留轻量意图识别；
- **数据问答/分析**（增长快、无穷尽）→ 交给 Agent。Agent 的工具目录天然自描述（HoloToolDescriptor + 动态数据集 schema + 自动渲染，机制已建成，现有 13 个动态数据集），**新数据 = 注册数据集（约 4 处改动，跨 3-4 文件），零提示词改动、不发后端版**。

**关键修订（相对 v1）**：
1. **普通问答（query）不切 Agent**（东林 1C 拍板）：简单/事实问答留在现有 chat 流式链路，深度分析（query_analysis，现状已走 Agent）维持卡片形态。P2 从「大手术」缩为「小升级」；
2. **灰度安全网先建再动**（东林 2A 拍板）：现状所有 AI 开关都是客户端硬编码、无服务端下发通道，「关开关不发版」在 v1 中不成立。P2 先建服务端可控开关+指标仪表盘；用户量小，上线即全量、不跑灰度阶梯，开关当急停按钮；
3. **P1 全量做**（东林 3B 拍板）：客户端 IntentDescriptor 注册表也建（额外约 1 天，顺带把必填字段校验从硬编码 5 意图扩到全量），并补上 v1 缺失的跨仓库一致性对拍设计。

**路径**：P0 数据上下文注册表+评测基线 → P1 意图注册表+后端骨架化 → P2 Agent 问答基建（开关/降级/步骤可视化）→ P3 意图识别瘦身（收益收窄，见 §4 P3）→ P4 清理。

---

## 1. 现状定量诊断（审查核实版）

### 1.1 新增一个意图的真实成本（实测样本）

以 4b552597「对话式改任务条目」为样本：**2 仓库 14 文件、约 +365 行**（iOS 12 文件 +360 行；后端 2475e015 2 文件，需后端发版）。

| 类别 | 位置 | 性质 |
|---|---|---|
| 功能实现（合理成本，保留） | AIIntent 枚举、IntentRouter handler、ChatCardData、卡片 UI、ChatViewModel 接线 | 新功能本身的代码 |
| 提示词重复维护（**补丁成本，消灭对象**） | 后端 defaultPrompts.json 意图清单+2 条示例；客户端 PromptManager 兜底意图行+2 条示例；AIUserContextMessageBuilder 备忘单注入块 | 同一份知识多插入点、双份副本 |
| 护栏维护（**补丁成本**） | prompts.test.js 长度红线 4700→5100 手动抬升 | 每加一次意图抬一次 |

注（审查修正）：客户端 PromptManager 兜底 prompt 为 `#if DEBUG`，Release 正文为空（`loadPrompt` 直接 throw），生产链路只跑后端那份；但两份已实际漂移（iOS 缺 3 个 goal 意图与健康分流线），维护性债务真实存在。

### 1.2 新增一类数据的真实成本

以纪念日（87799eb5，2026-08-15）为样本：模型字段 + UserContextBuilder 构行 + MessageBuilder chat 块 + intent 块（含专属路由规则），共 3 处手写。且每类数据都让意图识别上下文再膨胀一块（备忘单 08-14、纪念日 08-15）。

### 1.3 已经存在但未被复用的自描述机制

Agent 侧已建成完整的「能力自描述」：
- `HoloToolDescriptor`（HoloDataTool.swift:30-38）：每个工具声明名称/描述/支持查询/时间范围/输出度量/敏感度；
- 动态数据集共 **13 个**（HoloAgentDynamicCatalogs 8 个 + health 4 个 + finance 1 个；v1 文档写 12/附录写 8 均误，此为实测值），带字段级 schema 元数据；
- `HoloToolRegistry.promptDescription()`（HoloToolRegistry.swift:64-90）：把上述自动序列化进 Agent system prompt（链路：Registry → ToolExecutor → HoloLocalAgentRuntime.toolDescriptions → HoloAgentPromptBuilder），**这正是意图识别缺失的「单一事实源自动渲染」**；
- `HoloAgentToolCoverage` 白名单断言（HoloToolRegistry.swift:11-39，13 数据集+10 工具，DEBUG assert）：注册即校验，防止漏配。

### 1.4 两套理解体系的割裂

- 意图识别（LLM）与 Agent 的 SemanticFrame（关键词规则）各自独立理解同一句话；意图识别产出的时间语义/领域提示（extractedData）**不传给 Agent**（`runAnalysis(question:)` 签名无此参数，ChatViewModel.swift:329-348 只传原文）。
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
│ · 事实/简单问答 → chat 流式   │   （1C：query 留在现有链路）
│ · 深度分析 → Agent（现状已是）│
└─────────────────────────────┘
   │           │            │
   ▼           ▼            ▼
 执行链路    chat 流式      Agent（工具目录自描述）
 （现状保留） （1C 保留）    · 深度分析：query_analysis（现状已走）
                           · 单值查询：flexible_data_query（现状已走，开关默认开）
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
| 后端意图提示词（意图清单+示例+分流规则） | 骨架化：通用规则保留，意图清单段由意图定义 JSON 渲染（走 managedPrompts 热更新通道，仅后端注入侧生效），护栏测试改为「断言与注册表一致」 |
| 客户端 PromptManager 兜底提示词（DEBUG 专用） | 从意图注册表**自动生成**（3B：注册表也建，顺带驱动 chatDisplayLabel 与 requiredFields 校验） |
| 聊天/意图识别上下文注入块 | 数据上下文注册表（AIContextSection）统一供给，chat 与意图识别两个消费者按预算取用 |

---

## 3. 设计原则（谨慎条款）

1. **执行类主链路全程不动**：记账/建任务/打卡的确认卡片流是产品核心路径，各阶段改动不触碰其行为；每阶段验证含「执行类意图回归评测全绿」。
2. **行为开关必须服务端可控**（v2 修正）：v1 的「回滚=关开关不发版」基于错误前提（现状所有 AI flag 为客户端硬编码，`agentRuntimeEnabled` 每次启动还被 AgentProductPolicy 强制覆盖回 true）。P2 先建服务端开关下发（搭 `GET /v1/subscription/status` 的 per-device 判定便车），开关语义=「Agent 问答路由总闸」，回滚=后台改配置，不发版。
3. **先建尺子再动刀**：任何架构改动前先固化评测基线（§4 P0）。注意（审查修正）：HoloAgentEval 是本地确定性门禁、不调 LLM，意图评测必须真实调用后端 LLM（purpose=intent），跑法需新建而非直接复用。
4. **单一事实源 + 跨仓库对拍**：能力的定义只允许存在一处，其他一切（prompt/护栏/兜底）是渲染产物。客户端 IntentDescriptor 与后端意图定义 JSON 分属两仓库天然是两份——**对拍机制是本方案的组成部分**（§4 P1），不是可选项。
5. **上线即全量 + 急停开关**（2A 拍板）：当前用户量小，不跑 10%→50%→100% 灰度阶梯；服务端开关+仪表盘作为出问题时的急停与观测。
6. **不动后端 prompt 的既有护栏语义**：长度红线、内容断言在 P1 改造为「注册表一致性断言」，保护强度不降低。

---

## 4. 分阶段演进路线

### P0 地基：数据上下文注册表 + 评测基线（纯客户端）

**AIContextSection 注册表**
```swift
protocol AIContextSection {
    var id: String { get }                  // "anniversaries" / "recentLinkedTask" / …
    var priority: Int { get }               // 预算裁剪顺序（越大越先裁）
    func chatBlock(_ context: UserContext) -> String?      // chat 上下文注入块，nil=不注入
    func intentBlock(_ context: UserContext) -> String?    // 意图识别上下文注入块（含专属规则），nil=不注入
}
```
- AIUserContextMessageBuilder 遍历注册表渲染，删除现有手写块；
- 迁移前三个 section：**纪念日、数据覆盖度、最近关联任务**（吃狗粮）；
- 新数据接入成本：3 处手写 → 1 个 section。

**评测基线（intent_eval）**
- 语料 JSON（可接受集合标注，支持歧义样本）覆盖全部 21 意图 + 歧义句 + 纯闲聊，共 150-200 条；先用种子语料（本仓库构造），真实用户样本从 ChatMessage 历史导出后补充（需小改 `loadRecentDTOsAsync` 的 predicate，现硬编码 role IN {user,assistant}）；
- runner（Node 脚本）：逐条 POST 后端 `/v1/ai/chat/completions` purpose=intent → 比对 acceptable 集合 → 准确率+错判清单报告落盘 `docs/holoai-audit/intent-eval/reports/`；本地 mock 冒烟验证管道，真实基线在 dev/生产环境跑（deepseek-v4-flash，200 条成本可控）；
- 门禁：每次改 prompt/路由前后跑，意图准确率不得低于基线 -2pp。

**验收**：三块迁移后上下文渲染逐字节等价（含换行）；iOS 编译绿；评测管道 mock 冒烟通过+真实基线报告产出（或明确记录阻塞原因）。
**回滚**：纯客户端，revert 即回。

### P1 意图注册表 + 后端提示词骨架化（约 4 天，客户端+一次后端发版；3B 全量）

**IntentDescriptor 注册表（客户端）**
```swift
struct IntentDescriptor {
    let intent: AIIntent
    let summary: String          // 一句话定义（进提示词）
    let examples: [String]       // few-shot 2 条（进提示词）
    let routingHints: [String]?  // 分流提示（仅 query 歧义类需要）
    let requiredFields: [String] // 供 AIParseBatchValidator 自动断言（现状硬编码仅覆盖 5 意图 → 扩到全量）
}
```
- 一处注册 → 自动渲染三处：客户端兜底 prompt（DEBUG）、chatDisplayLabel 元数据、requiredFields 解析校验；
- PromptManager 兜底 prompt 从 3 处手写点变为渲染产物（注：Release 本就不加载，此项收益作用于 DEBUG/本地直连路径）。

**后端 intent_recognition 骨架化**
- 意图清单+示例段从 defaultPrompts.json 静态文本迁出，改为：意图定义 JSON（与客户端 IntentDescriptor 同构）随 promptRegistry 的 managedPrompts 通道热更新（仅后端注入侧；`/v1/prompts*` 端点生产关闭，客户端无感知）；
- 通用规则（日期映射/字段规则/分流总则）保留骨架；
- 护栏测试改造：长度红线保留（防膨胀反弹），内容断言改为「渲染产物包含全部注册意图且无未注册意图」——从「防删旧」升级为「防漏新」。

**跨仓库对拍（v2 新增，P1 验收必含）**
- 意图定义 JSON 以**后端仓库为单一事实源**；客户端 CI/测试拉取后端 JSON 与 IntentDescriptor 注册表对拍（意图名集合/summary 哈希一致），漂移即红；
- 备选实现：两仓库各断言自身一致 + 发版 checklist 人工对拍（若 CI 互访不可行）。

**验收**：新增一个玩具意图（测试用）的实测成本 ≤ 3 个文件+1 处后端 JSON（注册表 1 + 枚举 1 + handler 1）；意图评测基线不降。
**回滚**：客户端 revert；后端 promptRegistry 版本回滚（已有历史机制）。

### P2 Agent 问答基建（约 4-5 天开发 + 1 次后端发版；1C/2A 收窄版）

**范围重定义（1C）**：query **不切** Agent，留在 chat 流式链路；query_analysis 与 flexible_data_query 现状已走 Agent（`shouldRouteToDeepAgent`，后者受本地 flag 默认开），不变。P2 做的是基建与体验补课，不是切流。

**改动清单**
1. **服务端路由总闸**（2A）：后端新增 per-device 配置下发（搭 `GET /v1/subscription/status` 模式），客户端 `shouldRouteToDeepAgent` 的总开关从「本地硬编码+启动强制覆盖」改为「服务端值优先、本地默认兜底」——回滚=后台改配置，不发版；
2. **指标仪表盘**（2A）：服务端 `ai_call_logs` 已记 device_id+purpose+duration_ms（30 天），加一个 admin 聚合页（按 purpose/日的 p50/p90 时延、错误率、调用量）；点踩上报**延后**（用户量小无统计意义，v1 中「点踩率」数据源本就不存在）；
3. **Agent 失败降级回 chat**（新增必做）：现状 Agent 失败只渲染无重试按钮的「深度分析出错」卡片。P2 补：失败时自动降级走 chat 流式链路重答（保留失败卡片可展开查看原因）；
4. **前台步骤实时化**：现状前台聊天页等待时是静止卡片，步骤文案只在回前台/解锁瞬间快照刷新。步骤文案全集已存在（HoloAgentAnalysisService.swift:153-178），推送管道已通（updateAgentMessageProgress → @Published → UI），补一条 Scheduler→ChatViewModel 的步骤事件通道即可；
5. **anniversary 数据集注册**（示范性，非切流依赖）：按「新数据零 prompt 接入」实战注册一个动态数据集（schema+行数据+基座工具+装配约 4 处改动），让深度分析也能回答纪念日类问题。

**验收**：后台改开关→客户端下次请求即变（不发版）；Agent 强制失败场景自动降级出流式答案；前台等待时步骤文案随 job 进度变化；仪表盘能看到 purpose=agent_loop 的时延分布。
**回滚**：服务端开关关=回到纯本地行为；各项独立可 revert。

### P3 意图识别瘦身（P2 稳定后，一次后端发版；收益收窄）

**v2 修正**：因 1C 下 query 留在 chat 链路，意图识别必须继续认识 query，v1 的「删 query 定义」不可行。可删/可收敛的只有：
- `flexible_data_query` 定义与 few-shot（已由 Agent 承接，路由总闸统一指 Agent，无需细分意图）；
- `generate_memory_insight` 的细分定义（若其触发可由规则/Agent 侧承接，动工前先核实其现有链路）；
- `query_tasks`/`query_habits` 的细分定义可尝试收敛为 query 统称（风险：chat 上下文组装依赖细分意图的话则保留，动工前核实）。

- 字符配额预期节省约 **500-800**（v1 预估 1500 基于 query 也删除的前提，已不成立）；红线同步下调（防再膨胀）；
- 意图枚举保留 case（历史消息解码兼容）。

**验收**：prompt 长度下降且护栏全绿；意图评测基线不降。
**回滚**：后端 prompt 版本回滚。

### P4 清理（半天）

- 删除双份 prompt 维护残留（PromptManager 手写段由注册表渲染产物替代）、旧注入块死代码；
- 意图注册表与 Agent 工具目录的关系文档化（哪些能力在哪注册，防止下一代人再建平行清单）；
- CHANGELOG + 本方案文档更新终态。

---

## 5. 风险登记册（v2 修订）

| # | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R1 | Agent 多轮工具调用导致深度分析变慢 | 中 | 体验回退 | 真正限步的是 budget.maxLLMRounds（12/16/2 轮，300s/420s 活跃时长）——v1 引用的「预算选择器 maxToolRounds」是死配置已删；discover 前置+工具结果增量注入已生效 |
| R2 | Agent 答案幻觉/编数据 | 中 | 信任损伤 | ClaimVerifier V1/V2 + evidenceIDs 契约（十维校验+三态 verdict，接线完整）——v1 误写 EvidencePolicy（实为来源/敏感度标注），已修正 |
| R3 | 双轨期两套理解不一致（意图识别 vs SemanticFrame） | 低（1C 下 query 不切，双轨面缩小） | 行为漂移 | extractedData 下传暂不需要；评测集对照 |
| R4 | 后端 prompt 热更新被误改 | 低 | 线上事故 | promptRegistry 版本历史+回滚（已有）；护栏测试断言注册表一致性；admin 改动留 change_note |
| R5 | ~~灰度样本偏差~~ | — | — | 已不适用：2A 拍板上线即全量，无灰度阶梯 |
| R6 | token/服务器成本上升 | 中 | 订阅成本 | per-purpose 限流桶已有先例（agent_loop 已独立配额）；月度 ai_call_logs 成本观察 |
| R7 | 评测基线本身有错标 | 中 | 尺子歪 | 种子语料可接受集合标注；东林抽检 20 条；真实样本补入后双人校对 |
| R8 | 既有 flaky 测试干扰护栏信号（prompts.test.js「恢复默认」偶发 500≠302） | 中 | 发布误停 | 已定位根因：adminRoutes reset 无 try/catch + saveManagedPrompts 的 unlinkSync/writeFileSync 未捕获 + node --test 并行竞争共享 managedPrompts.json。P1 顺手修（reset 分支补 catch + 测试用独立 managedPrompts 路径） |
| R9 | 执行类意图误伤 | 低 | 核心路径事故 | 三条原则：主链路不动、每阶段执行类回归全绿、行为变化全挂服务端开关 |
| R10 | Agent 承接后意图识别仍被新执行意图膨胀 | 低 | 问题换形复发 | 意图清单冻结：新增执行意图需过「§2.1 判定标准」评审，注册表里留判定记录字段 |
| R11 | **（v2 新增）Agent 失败无兜底**：现状失败=无重试的死卡片，且 Agent 路径取消了 90s/300s 流式 watchdog | 高（现状即如此） | 信任损伤 | P2 必做项：失败自动降级回 chat 流式；保留失败原因可展开 |
| R12 | **（v2 新增）两仓库注册表漂移**：客户端 IntentDescriptor 与后端意图 JSON 各自演化 | 中 | 行为不一致 | P1 跨仓库对拍（CI 级优先，退而求其次发版 checklist） |
| R13 | **（v2 新增）意图识别的确定性旁路行为差**：「我最近状态怎么样」类输入被 intentResponseStabilizer 规则短路（0 次 LLM，返回 query_analysis） | 低 | 认知盲区 | 已核实旁路返回的意图现状即走 Agent，不因 P2 改变；评测语料纳入旁路命中样本，报告标注 provider=holo-rules |

---

## 6. 成本与收益测算（v2 修正）

**一次性成本**（按阶段）：P0 约 2 天、P1 约 4 天+1 次发版、P2 约 4-5 天+1 次发版、P3 半天+1 次发版、P4 半天。合计约 **2.5 周**开发人力（v1 估 2 周，P1/P2 因补齐基建与降级上调）+ 自然观察期。

**持续收益**：
- 新增数据域：3 处手写 → 1 个 section（chat 场景）；Agent 场景 = 数据集注册 4 处改动但零提示词零发版；
- 新增执行意图：14 文件 6 插入点 → 预期 4-5 文件 1 插入点+1 处后端 JSON（prompt 手写归零）；
- 意图 prompt 字符配额腾出约 500-800（P3 后），意图识别任务不变但清单更干净；
- 「AI 认识新数据（Agent 侧）」从发版级降为客户端版本级，迭代提速一个发布层级；
- 服务端开关+仪表盘为后续一切 AI 行为实验提供不发版回滚能力（基础设施复用价值）。

**不做什么**（明确排除）：不引入 embedding 意图检索/RAG 路由；不重写 Agent runtime；不合并意图识别与 Agent 为单次调用（时延不可接受）；query 不切 Agent（1C）。

---

## 7. 拍板记录（2026-08-15，东林）

| # | 决策点 | 拍板 | 备注 |
|---|---|---|---|
| 1 | 问答答案形态 | **1C 混合**：简单/事实问答保持现有 chat 链路（流式），深度分析用卡片+步骤可视化 | 澄清后落地：flexible_data_query 现状已走 Agent，实际决策只剩「query 切不切」——选不切 |
| 2 | 灰度安全网 | **2A 建最小基建**：服务端开关+仪表盘；用户量小上线即全量，开关当急停 | 点踩上报延后（样本量不足） |
| 3 | P1 范围 | **3B 全量**：客户端 IntentDescriptor 注册表也建 | 额外约 1 天；requiredFields 校验从 5 意图扩到全量 |
| 4 | 意图段热更新权限 | 沿用 v1 建议：结构字段（意图名/必填字段）锁注册表，后台仅可编辑 summary 措辞 | 实现：intents JSON 结构字段不可经 admin 修改 |
| — | P0 启动 | 2026-08-15 随本定稿即启动 | 种子语料先行，真实样本后补 |
| — | P3 触发 | P2 验收全绿后即可（不设 2-4 周等待，因 P3 收窄后风险低） | 若 P3 核实中发现 query_tasks/query_habits 收敛有风险，可只删 flexible_data_query |

---

## 8. 三轮对抗审查修订记录（2026-08-15）

**审查方法**：第一轮事实核查（4 个核查 agent 对方案的每个数字/行号/机制声明在代码库对质）；第二轮设计攻击（灰度回滚真实性/注册表是否消灭重复/成本与风险遗漏）；第三轮收敛验证（灰度基建、失败兜底、时延指标、流式体感、步骤可视化五个争议焦点代码级终审）。

**核实为真**（方案立足的事实）：21 意图、4340/5005/5100 红线、13 few-shot/17 意图条目/5 分流、12 文件+360 行、纪念日 3 处手写、extractedData 不下传、Agent 自描述链路完整、promptRegistry 热更新+版本回滚存在、ClaimVerifier V1/V2+evidenceIDs 接线完整。

**修正的失真**（v1 → v2）：
1. 「回滚=关开关不发版」前提不存在（flag 全客户端硬编码）→ P2 先建服务端开关；
2. 「预算选择器限步数」是死配置（maxToolRounds 全仓无消费）→ 改为 budget.maxLLMRounds 实情；
3. R2 误标 EvidencePolicy 为防幻觉组件 → 实为 ClaimVerifier V1/V2；
4. SemanticFrame 无聊天上下文入口，「快路径」非现成能力 → 1C 下快路径需求消失（chat 链路即快路径）；
5. 客户端兜底 prompt 生产不跑（#if DEBUG）→ P1 收益口径修正，3B 保留是为了注册表的正向价值；
6. 数据集 12/8 均误 → 实为 13；
7. HoloAgentEval 不调 LLM，意图评测需新建管道 → P0 已按此设计；
8. 「serve 5005」≠模型实见（约 5966 含 Preamble）→ 预算论证口径修正；
9. flexible_data_query 现状已走 Agent（flag 默认开）→ P2 范围重定义的直接依据；
10. prompt 热更新仅后端注入侧生效（/v1/prompts* 生产关闭）→ P1 设计限定；
11. 意图识别存在 intentResponseStabilizer 确定性旁路（返回 query_analysis，现状即走 Agent）→ R13。

**体感分歧澄清**（东林提问驱动）：普通问答技术上真流式（逐 chunk SSE+33ms 节流），短回复时体感「三个点后一次性蹦出」为上游出字速度所致，非实现差异；深度分析前台卡片静止，所见步骤变化来自锁屏 Live Activity 或回前台/解锁瞬间快照——P2 补前台实时化。

---

## 9. 实施终态记录（2026-08-15，P0-P4 完成）

### 9.1 各阶段实施结果

| 阶段 | 结果 | 验收证据 |
|---|---|---|
| P0 注册表+评测基线 | ✅ | 14 组边界样例逐字节等价（工具归档 docs/holoai-audit/context-section-equiv-check/）；评测集 123 条；真实基线 **95.1%**（deepseek-chat） |
| P1 意图注册表+骨架化 | ✅ | intents.json 单一事实源（17 条目/21 意图）→ 后端 marker 渲染（逐内容等价）+ 客户端 IntentDescriptor.swift **程序化生成**（generator + --check 对拍护栏进 npm test）；requiredFields 从 5 意图扩到全量；flaky 修复（原子写+SQLite 失败抛出+admin 兜底）；后端 215/215 绿；评测 95.1% 持平 |
| P2 Agent 基建 | ✅ | feature_flags 表+admin 开关页+订阅状态下发（不发版急停）；admin AI 指标聚合页（p50/p90/错误率/14日趋势）；Agent 失败自动降级回 chat 流式（两层兜底）；前台步骤实时化（2s 轮询单条 job）；anniversary 动态数据集注册（零提示词改动实战，白名单 14 数据集）；评测 95.1% 持平 |
| P3 意图 prompt 瘦身 | ✅（范围修正） | 删与分流规则重复的 few-shot 3 条 + flexible_data_query 摘要与 V23 聚合契约对齐；5002→4745 字符，红线 5100→4900；评测 **95.9%**（+0.8pp） |
| P4 清理 | ✅ | PromptManager 手写段/AIUserContextMessageBuilder 手写块已在 P0/P1 迁移中删除；本节+CHANGELOG 为终态文档 |

### 9.2 P3 范围修正说明（重要）

v2 方案写的「删 flexible_data_query / generate_memory_insight 意图定义」经核实**不可行**：意图识别若不再输出该意图，单值查询会被归为 query 走 chat 文本链路，失去 FlexibleQuery 本地精确计算引擎与 Agent 承接——这是行为回退不是瘦身。1C 约束（query 不切 Agent）下，意图定义必须全部保留。实际执行的瘦身=删重复 few-shot+修 V23 自相矛盾，收益 257 字符（小于 v2 预估的 500-800，但零行为风险且评测反升）。

### 9.3 「在哪里注册什么」——给下一个人（防平行清单复发）

| 要加什么 | 在哪注册 | 不要做什么 |
|---|---|---|
| 新意图（执行类） | 1. 后端 `HoloBackend/src/prompts/intents.json` 加条目（summary/requiredFields/examples）→ 2. `node scripts/generate-intent-descriptors.mjs` 重生成客户端 → 3. iOS AIIntent 枚举 + IntentRouter handler + 卡片 UI → 4. 评测语料加样本（对拍测试强制） | 不要手写 PromptManager 模板/后端 defaultPrompts 意图段；不要只改一端（对拍测试会红） |
| 新数据域（chat/意图识别上下文） | iOS `Services/AI/AIContextSection.swift` 加一个 section 并注册 | 不要在 AIUserContextMessageBuilder 加手写块 |
| 新数据集（Agent 问答） | iOS：schema（HoloAgentDynamicCatalogs）+ rows 分支（HoloAgentRuntimeShared）+ 基座工具 + 装配 + 白名单，共 4 处 | 不改任何提示词、不发后端版 |
| 意图 prompt 措辞调整 | 改 intents.json 的 summary/examples → 重生成客户端 | 红线 4900 不得超；改后必跑 intent_eval |
| Agent 问答行为急停 | admin 后台「功能开关」页关 agentDeepAnalysis | 无需发版，客户端下次刷新订阅状态生效 |

### 9.4 后端发版清单（需东林验收后执行）

本方案共需 **1 次后端发版**（P1+P2+P3 合并）：
- intents.json（新文件）+ defaultPrompts.json 骨架化 + promptRegistry marker 渲染 + v26 + flaky 修复
- feature_flags 表（migration #12，启动自动执行）+ admin 两页面 + 订阅状态 featureFlags 下发
- 影响：意图 prompt serve 产物 4745 字符（<红线4900）；发版后 syncDefaultPromptsToHistory 自动登记 v26；若线上出问题可 admin「恢复默认」或按版本回滚
- 发版顺序：先发后端（新 prompt 结构+开关），再发 iOS（P1/P2 客户端部分不依赖后端新字段——featureFlags 为可选字段，旧后端响应无此字段时客户端按默认值走）

---

## 附录 A：现状证据索引（实施前基线，2026-08-15）

- modify_task_items 样本：iOS 4b552597（12 文件 +360 行）、后端 2475e015（2 文件）
- 后端 intent_recognition：本体 4340 字符 + 2 附录 ≈ serve 5005，红线 5100（prompts.test.js:134-137；4700→5100 历史在 git 2475e015）；模型实见约 5966（+Persona Preamble 969+日期渲染）
- few-shot 13 条、意图条目 17 行覆盖 21 值、分流规则 5 条
- Agent 自描述：HoloToolDescriptor（HoloDataTool.swift:30-38）/ HoloAgentDynamicCatalogs（:268-300，8 数据集）+ health 4（HoloHealthTool.swift:113-147）+ finance 1（HoloFinanceTool.swift:164-181）= 13 动态数据集 / HoloToolRegistry.promptDescription（:64-90）/ 覆盖断言（:11-39）
- 路由现状：shouldRouteToDeepAgent（ConversationCoordinator.swift:44-54）排除 11 执行意图；query_analysis 恒走（总闸开启下）；flexible_data_query 受 HoloAgentDynamicQueryFlags（默认 true，**现状已走 Agent**）
- 意图识别产物不下传：ChatViewModel.swift:329-348 → runAnalysis(question:) 只传原文
- 数据问答塞上下文样本：纪念日块（AIUserContextMessageBuilder.swift:134-141）、覆盖度（:143-148）、最近任务备忘单（:150-163）
- AI flag 现状：HoloAIFeatureFlags/HoloAgentDynamicQueryFlags 全客户端（HoloAICapability.swift:409-474 等），agentRuntimeEnabled 启动强制覆盖（:226-235），无远程下发
- Agent 失败现状：HoloAgentAnalysisService 统一 fail 不抛错；失败卡片无重试无降级（MessageBubbleView.swift:146-157 → AgentDeepAnalysisCard 空态）
- Agent 时延数据：服务端 ai_call_logs（30 天，device_id+purpose+duration_ms）；客户端 HoloAgentTelemetryEvent 仅本地文件不上传
- 步骤文案全集：HoloAgentAnalysisService.swift:153-178；前台静止、回前台快照刷新（syncRecoverableChatMessages）

## 附录 B：阶段-文件映射（预期改动面，v2）

| 阶段 | 新文件 | 改动文件 | 后端发版 |
|---|---|---|---|
| P0 | Services/AI/AIContextSection.swift（协议+注册表+3 section）；docs/holoai-audit/intent-eval/（语料+runner+README） | AIUserContextMessageBuilder（遍历渲染）/（评测样本导出小改 ChatMessageRepository，可延后） | 否 |
| P1 | IntentDescriptor.swift + intents.json（后端为源） | PromptManager / AIParseBatchValidator / 后端 promptRegistry+prompts.test.js / 跨仓库对拍脚本 | 是（1 次） |
| P2 | （后端）路由开关端点+聚合页；（客户端）步骤事件通道 | ConversationCoordinator / HoloAIFeatureFlags（服务端值优先）/ HoloAgentAnalysisService+ChatViewModel（降级+实时步骤）/ HoloAgentRuntimeShared（anniversary 数据集 4 处） | **是（1 次）** |
| P3 | — | 后端 defaultPrompts.json（删段）+ prompts.test.js 红线 / IntentRouter（细分意图归一） | 是（1 次） |
| P4 | — | 删死代码 | 否 |
