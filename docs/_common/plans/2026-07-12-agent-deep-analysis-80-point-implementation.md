# Holo Agent 深度分析 80 分产品 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task. 本项目禁止 subagent，本计划在当前唯一工作副本中由主 Agent 顺序执行，并对每一步做 scoped 验证。

**Goal:** 让所有 Holo Agent 查询先生成完整、主题一致、用户可理解的答案，再以无重复层级的深度分析卡片呈现；彻底消除内部字段、错误主题和“观察 01”编号。

**Architecture:** 在现有工具 metric key 与 UI 之间建立确定性语义层，统一负责指标名称、数值格式、主题标题、直接答案、覆盖信息与内部字段拦截。`HoloAgentResultRenderer` 将 claim/evidence/question 转换为向后兼容的用户答案模型，runtime 与 Prompt 保证完整性，SwiftUI 只消费整理后的语义。

**Tech Stack:** Swift 6、SwiftUI、Foundation、Codable、standalone `swiftc` tests、XCTest/test_sim、Node.js tests、Hono Prompt Registry、ECS Docker Compose。

---

### Task 1: 用失败测试钉住用户答案契约

**Files:**
- Modify: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentResultRendererTests.swift`
- Modify: `Holo/Holo APP/Holo/HoloTests/Models/ChatMessageViewDataAgentResultTests.swift`
- Modify: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloHealthToolTests.swift`

**Step 1: 写步数问题的 Renderer 失败测试**

构造 `health.steps.average = 6990.8`、`health.steps.goal_met_days = 1`、最近一个月 28/30 天覆盖，调用 renderer 时传入问题“最近一个月平均步数是多少？”。断言：

- `headline == "最近一个月的步数"`；
- `directAnswer` 含“日均 6,991 步”；
- 标题不含“睡眠”；
- 所有用户可见文本不含 `health.`、`goal_met_days`、`average =`；
- section title 不匹配 `观察\s*\d+`；
- `coverageText` 含“28/30 天”或等价自然中文。

**Step 2: 写旧 JSON 向后兼容失败测试**

用缺少 `headline/directAnswer/coverageText/question` 的旧结果 JSON 解码，断言成功且新增字段为 nil；用新 JSON 解码，断言语义字段完整。

**Step 3: 写详情模型无编号、无重复失败测试**

构造新语义结果，断言详情 opening 使用 `headline/directAnswer`，observation label 为空或不含“观察 01”，与直接答案重复的 section 不再二次展示。

**Step 4: 写健康证据自然语言失败测试**

在 `HoloHealthToolTests` 的步数摘要中新增断言：汇总 evidence excerpt 包含“平均每天 10,000 步”和“达到 10,000 步 2 天”，且不含 `health.`。

**Step 5: 运行相关测试确认 RED**

Run: 使用项目现有 `test_sim` 执行 `HoloAgentResultRendererTests` 与 `ChatMessageViewDataAgentResultTests`；使用既有 Agent 模型、动态查询与工具文件的 standalone `swiftc` 命令执行 `HoloHealthToolTests.swift`。

Expected: 新断言因语义字段不存在、编号仍存在、健康证据暴露 metric key 而失败；现有基础测试继续可编译。

---

### Task 2: 建立跨领域确定性指标语义层

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentRuntimeShared.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloHealthTool.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloHealthToolTests.swift`

**Step 1: 增加 `HoloMetricSemanticCatalog`**

在 Agent shared 层提供：

- `title(for metricKey:)`：如“平均步数”“达标情况”“平均睡眠”；
- `sentence(metricKey:value:unit:comparison:)`：统一整数千位、金额两位或自然精度、百分比与量词；
- `topic(for metricKey:)`：步数、睡眠、站立、活动、运动、财务、习惯、任务、目标、观点等；
- `containsInternalToken(_:)`：识别域前缀、下划线 key、` = ` 等机器格式；
- 未知 key 绝不回显 key，只返回安全通用标题/正文。

优先覆盖所有 Agent tool descriptor 当前声明的固定 outputMetrics；dynamic key 根据 source、aggregation id 和 unit 做安全语义推断。

**Step 2: 改造健康汇总证据**

`HoloHealthTool.summaryEvidenceEvents` 使用语义层生成自然中文 excerpt。逐日 evidence 保持日期 + 指标 + 数值形式。

**Step 3: 运行 standalone 健康测试确认 GREEN**

Expected: `HoloHealthToolTests passed`，且新增自然语言/禁止内部 key 断言通过。

**Step 4: scoped commit**

Commit message: `feat: 建立 Agent 指标用户语义层`

---

### Task 3: 将 Renderer 升级为向后兼容的用户答案模型

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Presentation/HoloAgentResultRenderer.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentAnalysisService.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentResultRendererTests.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Models/ChatMessageViewDataAgentResultTests.swift`

**Step 1: 扩展 `HoloRenderedAgentResult`**

新增可选字段：`question`、`headline`、`directAnswer`、`coverageText`、`limitations`。保持旧字段和旧 JSON 解码兼容。

**Step 2: Renderer 接收本轮 question**

新增 `question: String? = nil` 参数。`HoloAgentAnalysisService.runAnalysis` 传入原始 question；恢复路径从 `HoloAgentJob.userQuestion` 传入。

**Step 3: 生成确定性主题标题**

从用户问题识别明确主题和时间短语；多主题只在用户确实询问关联时组合。标题优先问题，其次主指标，最后才使用数据域。确保单步数问题不出现睡眠。

**Step 4: 选择主指标并生成直接答案**

根据问题关键词（平均、总额、次数、占比、趋势等）和 assertion 匹配主指标，使用语义层生成一句可独立理解的 `directAnswer`。步数例输出“最近一个月，日均 6,991 步”。

**Step 5: 生成有意义的 sections**

- 不再生成“观察 N”；
- 原 claim 可读且承担趋势/关联逻辑时保留正文，标题按 claim type/主指标生成；
- claim 含内部格式时根据 assertions 重建自然语言；
- 主指标已在 `directAnswer` 展示时，不再生成完全重复 section；
- 规范化文本后去重。

**Step 6: 生成 coverage 与可读 evidence**

从 evidence timeRange 和记录覆盖信息生成 `coverageText`。证据摘要若仍含内部 token，则根据 metric value/unit 重建，不能原样显示。

**Step 7: 运行 Renderer 与 JSON 测试确认 GREEN**

Expected: 步数主题、直接答案、无内部 key、无“观察 N”、旧 JSON 兼容全部通过；财务 drilldown 回归不变。

**Step 8: scoped commit**

Commit message: `feat: 统一 Agent 用户答案模型`

---

### Task 4: 修复 runtime 完成与健康兜底表达

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift`
- Modify: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloLocalAgentRuntimeTests.swift`

**Step 1: 写步数 fallback 失败测试**

让 fake tool 返回步数 average/goal/coverage，模型返回空或 partial claim。断言最终 result claim：

- 直接使用自然中文；
- 完整覆盖平均步数与达标天数；
- 不含内部 key；
- 不生成泛化建议。

**Step 2: 统一 `readableMetricText`**

删除 runtime 内“平均值/数量/计算结果”的粗粒度猜测，改用 `HoloMetricSemanticCatalog`。健康非睡眠 fallback 不再拼接 event 原始 excerpt。

**Step 3: 完成性与重复治理**

补齐缺失 assertion 时使用语义层生成正文；按 metric key 去重；保留跨指标 claim 的逻辑，但不重复同一指标事实。

**Step 4: 运行 runtime standalone 测试**

Run: 按 `HoloLocalAgentRuntimeTests.swift` 文件头说明，编译 Agent models、persistence、runtime、factory、parser/miner/verification 与测试文件。

Expected: `HoloLocalAgentRuntimeTests passed`，步数与既有睡眠/财务完整性测试均通过。

**Step 5: scoped commit**

Commit message: `fix: 保证 Agent 查询完整且可读`

---

### Task 5: 重构外层卡片与详情信息层级

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/Analysis/AgentDeepAnalysisCard.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/Analysis/AgentDeepAnalysisDetailSheet.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Models/ChatMessageViewDataAgentResultTests.swift`

**Step 1: 外层卡片改为答案预览**

展示顺序：主题标题 → 大号直接答案 → 小号覆盖信息 → “查看分析”。删除“核心观察”和 section.title 展示，不在外层复制详情正文。

**Step 2: 详情页改为语义章节**

opening 使用 headline/directAnswer；移除 signal strip 的摘要拆词；section 只显示有意义标题与正文，不显示编号 label；coverage/limitations 独立为低干扰信息块；evidence 默认折叠。

**Step 3: 去除通用“下一步”**

只有结果明确携带 suggestion 时展示行动区，不能因 evidence 为空就自动生成通用建议。

**Step 4: 更新叙事模型测试**

断言步数结果只出现一次主答案、无“观察 01”、标题主题正确、旧结果仍能通过适配器显示。

**Step 5: 运行 targeted XCTest/test_sim**

Expected: 相关测试真实执行且 0 failure；确认不是 `Executed 0 tests`。

**Step 6: scoped commit**

Commit message: `refactor: 重塑 Agent 深度分析信息层级`

---

### Task 6: 同步 Agent Prompt v10 双端契约

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift`
- Modify: `HoloBackend/src/prompts/defaultPrompts.json`
- Modify: `HoloBackend/src/prompts/promptRegistry.js`
- Modify: `HoloBackend/tests/prompt-registry.test.js`（如现有测试固定 v9/marker）
- Modify: `HoloBackend/scripts/verify-prod.sh` 或对应 verifier（仅当仍固定旧 marker）

**Step 1: iOS fallback Prompt 增加用户答案契约**

明确禁止 metric key、工具名、JSON 字段和“观察 N”；要求 displayText 单独可理解、标题绑定问题主题、查询题无空泛建议、final_claims 前逐项核对子问题。

**Step 2: 后端 Prompt 同步 v10 appendix**

将 `_agent_loop_v9_contract` 升级为 v10 marker，保留 v9 完整查询规则并加入可读答案契约；`PROMPT_VERSIONS.agent_loop` 和 iOS 最低版本同步升至 10。

**Step 3: 更新后端合约测试与生产 verifier**

断言 v10 marker、禁止内部字段表达、主题一致和完整回答规则均存在。

**Step 4: 运行后端测试**

Run: `npm test` in `HoloBackend`。

Expected: 全部测试通过。

**Step 5: scoped commit**

Commit message: `feat: 升级 Agent 可读答案契约 v10`

---

### Task 7: 完整验证、部署与端到端验收

**Files:**
- Verify only: all modified files above
- Update if required: `CHANGELOG.md`

**Step 1: 静态完成审计**

搜索用户可见构造路径，确认不再生成“观察 N”；搜索 `health.steps.average`/`goal_met_days`，确认只存在内部模型、测试或日志，不存在用户可见文案拼接。

**Step 2: 运行跨领域测试矩阵**

执行 HealthTool、Runtime、Renderer、ChatMessage narrative、财务 drilldown、Prompt registry 测试。记录每套真实执行数量和结果。

**Step 3: iOS Simulator 完整构建**

Run: 项目既有 `build_sim` 或等价 `xcodebuild`，使用独立 DerivedData 路径，避免污染 repo。

Expected: `** BUILD SUCCEEDED **`。

**Step 4: scoped commit/push**

核对 origin 必须为 `git@github.com:Donglin5525/Holo.git`；只 stage 本次 Agent、Prompt、测试和 changelog 文件，不混入现有工作区其他改动。

**Step 5: 部署 HoloBackend**

按 `holo-backend-deploy` skill：本地测试与版本确认 → rsync → ECS 加锁/SQLite 备份 → classic builder 重建 → 本机和公网分层验收。

**Step 6: 验收生产 Prompt**

确认：

- `/v1/health` 正常；
- `/v1/prompts/meta` 中 `agent_loop = 10`；
- `/v1/prompts/agent_loop` 含 v10 marker 和可读答案契约；
- `npm run verify:prod` 通过。

**Step 7: 真实问题端到端检查**

在可用的真实 App/Agent 环境中再次输入“最近一个月平均步数是多少？”，依据持久化 `agentResultJSON` 或 UI 实际结果检查设计文档 §9.1 的全部断言。无法自动触发真实 HealthKit 时，使用相同 renderer fixture 证明输出结构，并明确把真实设备验证留给东林验收，不能把 fixture 冒充生产实测。

**Step 8: 最终完成审计**

逐项对照设计文档的直接回答、主题一致、人类语言、完整性、去重复、证据边界、建议克制、稳定降级八项标准；任何一项证据不足都继续修复，不提前宣告完成。

