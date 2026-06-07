# Holo AI Sense Loop 公测方案 — 对抗性审查报告

> 审查日期：2026-06-07
> 审查方法：3 个并行探索代理深入代码架构，逐一验证方案的事实性声称
> 审查结论：**🔴 Conditional Stop — 方案前提与代码现状存在系统性偏差，需大幅修订后再进入实施**

---

## 0. 审查结论

本方案的产品直觉是对的——"Holo 缺少一条把用户档案、日常状态、记忆洞察、聊天表达和用户反馈串起来的理解闭环"这个判断完全正确。

但方案在**事实基础上存在系统性问题**：

1. 方案描述的 5 个核心组件中，**4 个已经在代码中实现**（反馈聚合、偏好画像、卡片重排序、每日状态）
2. 方案声称要"新建"的多项能力，实际是**扩展现有系统**而非从零构建
3. 方案多处**对现有系统的描述与代码不符**（状态数量、反馈选项、记忆层级、跨模块范围）
4. 方案完全忽略了已实现的**记忆候选语义类型化**（phaseShift/stablePattern/driftSignal/lifeEvent/statMilestone），这与方案提出的"流水/异常/高光/里程碑"分层高度重叠

**核心风险**：如果按当前方案直接实施，会重复造轮子、覆盖已有逻辑、遗漏真正的架构断层。

---

## 1. 🔴 CRITICAL：方案声称的"不存在"实际已存在

### #C1：反馈学习闭环已完整实现，方案视而不见

**方案声称（第 4.4 节）**：
> "公测第一版只做轻反馈，不做复杂编辑。"
> "建议每条洞察支持 4 个轻反馈：有用/不准/没感觉/少提醒这个"

**代码现状**：

| 组件 | 文件 | 状态 |
|------|------|------|
| InsightFeedbackAggregator | `Services/AI/InsightFeedbackAggregator.swift` | ✅ 完整实现 |
| InsightPreferenceProfile | `Models/InsightPreferenceProfile.swift` | ✅ 完整实现 |
| InsightCardReranker | `Services/AI/InsightCardReranker.swift` | ✅ 完整实现 |
| InsightFeedbackSheet | `Views/MemoryGallery/Components/InsightFeedbackSheet.swift` | ✅ UI 已实现 |

**已实现的能力**：

```swift
// InsightFeedbackAggregator 已实现：
- 模块权重调整（weight: 0.0-2.0）
- 模式惩罚机制（penalty: 0.0-1.0）
- 稳定偏好升级（evidenceCount >= 2 时 isStable = true）
- 弱信号过期机制（30 天过期）
- 语气信号收集（balanced/direct/gentle/dataFirst/fewerSuggestions）
```

```swift
// InsightCardReranker 已实现基于反馈的重排序：
- 模块权重应用
- 模式惩罚应用
- Critical anomaly 保底机制
```

**方案遗漏**：方案把反馈学习列为 Phase 4（公测期第一轮迭代），但这个系统**已经在线上运行**。方案不仅没有识别到这个能力，还在计划"新建"一个功能上高度重叠的系统。

**建议**：方案应明确标注"反馈学习闭环已实现，公测期任务为验证和调优，而非新建"。

---

### #C2：Daily Sense 状态摘要已实现，方案虚构了两个不存在的状态

**方案声称（Phase 1）**：
> 5 个状态：节奏不错 / 节奏有点乱 / 节奏在找回 / **压力偏高** / **新阶段出现**

**代码现状**：

```swift
// DailySenseSnapshot.swift — 只有 3 个状态
enum DailySenseState: String, Codable {
    case stable       // 节奏不错
    case atRisk       // 节奏有点乱
    case recovering   // 节奏在找回
}
```

**"压力偏高"和"新阶段出现"在代码中完全不存在。**

已实现的信号维度也少了"想法"：
```swift
enum SenseDimension: String, Codable, CaseIterable {
    case task      // 待办 ✅
    case habit     // 习惯 ✅
    case expense   // 消费 ✅
    case health    // 健康 ✅
    // ❌ 没有 thought（想法）维度
}
```

**影响**：如果按 5 个状态实施，需要从零扩展 `DailySenseStateBuilder` 的评分逻辑——这不是"让 Daily Sense 成为统一状态背景"那么简单，而是需要重新设计状态判定规则。

**建议**：要么承认只有 3 个状态并说明扩展计划，要么明确"压力偏高/新阶段出现"是新需求而非已有能力。

---

### #C3：记忆分层已部分实现，方案使用了错误的术语和层级

**方案声称（Phase 3）**：
> 4 层记忆：流水 / 异常 / 高光 / 里程碑

**代码现状**：

```swift
// MemoryTimelineNode.swift — 3 层结构
enum MemoryNodeType: String, Comparable {
    case dailySummary   // 日摘要（方案称之为"流水"）
    case highlight      // 高亮（对应方案的"高光"+"异常"）
    case milestone      // 里程碑
}
```

**不存在独立的"流水"和"异常"层级。** 它们分别融入了 `dailySummary` 和 `highlight`。

更关键的是，记忆候选系统已有**语义类型化**：

```swift
// MemoryInsightContextBuilder 中的 memoryCandidate 语义类型：
- phaseShift：用户跨过了一个阶段       ← 对应方案"里程碑"
- stablePattern：长期重复出现的行为倾向  ← 方案无对应
- driftSignal：偏离目标/节奏           ← 对应方案"异常"
- lifeEvent：重要生活事件              ← 方案无对应
- statMilestone：累计节点              ← 对应方案"里程碑"子类
```

**方案提出的"四条件里程碑判断"（阶段性/稳定性/用户相关性/可证据化）在代码中完全没有实现**——当前 `MilestoneDetector` 使用的是简单阈值检测，不是方案描述的四条件模型。

**建议**：
1. 术语对齐：使用代码已有的 `dailySummary / highlight / milestone` 体系
2. 明确区分"已有分层"和"需要升级的判断逻辑"
3. 将 `phaseShift / stablePattern / driftSignal` 等已有语义类型纳入方案

---

### #C4：跨模块信号观察已存在 7 种模式，但 Health 模块被遗漏

**方案声称（第 4.2 节）**：
> 观察财务、习惯、待办、想法、健康 5 个维度

**代码现状**：

```swift
// CrossModuleCorrelator.swift — 已实现 7 种跨模块关联
static func detect(
    finance: MemoryInsightFinanceContext,
    habits: MemoryInsightHabitContext,
    tasks: MemoryInsightTaskContext,
    thoughts: MemoryInsightThoughtContext
    // ❌ 没有 health 参数
) -> [CrossModuleCorrelation]
```

已实现的 7 种模式：习惯-消费关联、任务-消费关联、想法-习惯关联、任务-习惯关联、情绪-消费关联、工作日/周末模式、恢复迹象。

**Health 模块完全不参与跨模块关联检测。** 方案声称的"休息偏少时，其他节奏也有点乱"在实际代码中不存在。

同时，`HoloObservationPackageBuilder` 当前只支持 **Habit + Goal** 信号，缺失 Finance / Tasks / Thoughts / Health 信号构建器。

**建议**：方案应区分"已有跨模块关联（4 模块 7 模式）"和"需要扩展的部分（Health 接入 + 更多模式）"。

---

## 2. 🟠 HIGH：方案声称要"统一"的能力，实际已有但分散

### #H1：表达原则不是"没有"，而是已散布在多个 Prompt 中

**方案声称（Phase 0）**：
> "先让 Holo 不说错、不说重、不装懂。"
> "建议所有 Holo AI 相关 Prompt 共用以下规则..."

**代码现状**：

defaultPrompts.json 的 `memory_insight_generation` Prompt 已经包含：

```
## 语言风格
- 克制、温暖、具体。不说教，不审判。
- 只基于输入数据中明确存在的事实，不要编造。
- 不做心理诊断，不判断人格，不使用审判式表达。
- 禁止把'金额大、任务多、收入少'本身当成洞察。
- 跨模块关联只能表达为并发现象，不得推断原因。
```

**这些原则已经存在且正在生效。** 方案描述的问题（"洞察文案偏冷""上下文联动弱"）如果仍然存在，说明问题不是"缺少原则"，而是**原则没有被充分执行**或**执行后的文案仍然不够好**。

**真正的问题可能是**：
1. 原则只存在于 `memory_insight_generation` Prompt，其他 Prompt 没有对齐
2. LLM 对原则的遵循度不够高
3. 数据输入格式（偏数字/统计）导致输出偏数据化

**建议**：
1. 不说"统一表达原则"（暗示从零建），改为"将 `memory_insight_generation` 的表达原则扩展到所有 AI Prompt"
2. 补一个代码级诊断：当前洞察文案实际是什么样？是否真的"偏冷"？用真实输出验证问题
3. 如果问题在 LLM 遵循度，方案应考虑在 Prompt 外增加结构化约束（如强制"观察+假设+不确定"三段式）

---

### #H2：5 档表达强度系统完全不存在，从零构建成本被低估

**方案声称（第 4.3 节）**：
> 5 档表达：看见 / 归纳 / 提醒 / 行动建议 / 庆祝

**代码现状**：搜索了整个代码库，**没有任何表达强度分级、ExpressionLevel、ToneIntensity 或类似概念**。当前表达控制完全依赖 Prompt 文本约束，没有动态强度选择机制。

**这意味着**：
1. 需要新建 `ExpressionLevel` 枚举
2. 需要为每档设计不同的 Prompt 策略
3. 需要实现信号强度→表达档位的映射规则
4. 需要在所有 AI 入口（至少 6 条路径）集成档位选择逻辑
5. 需要 Feature Flag 控制回退

**这是整个方案中工程量最大、风险最高的部分**，但方案把它放在 Phase 0（"公测前必须做"），没有给出实现细节和时间评估。

**建议**：
1. 表达强度系统不应放在 Phase 0，应降级为 Phase 2 或更晚
2. Phase 0 只做"统一已有表达原则到所有 Prompt"——这是低风险高收益的
3. 如果 Phase 0 必须做表达强度，需要一份独立的工程实施方案

---

### #H3：反馈选项与代码不符，"没感觉"和"少提醒这个"不存在

**方案声称**：4 个反馈：有用 / 不准 / 没感觉 / 少提醒这个

**代码现状**：

```swift
// 实际反馈维度：
AccuracyRating: accurate / inaccurate        // 准 / 不准 ✅
ValueRating: useful / notUseful              // 有用 / 没用 ✅
FeedbackReasonType: dataWrong / relationWrong / priorityWrong / suggestionWrong / toneWrong

// ❌ 不存在"没感觉"独立选项
// ❌ 不存在"少提醒这个"频率控制反馈
```

**"没感觉"** 是一个重要创新——它和"不准"不同（事实对但没价值），方案对这个区分的描述很好。但它**需要新建 UI 和反馈处理逻辑**。

**"少提醒这个"** 更复杂——它涉及频率控制和冷却时间，需要新增存储和调度逻辑。

**建议**：明确标注哪些反馈是"已实现"，哪些是"需要新建"，以及新建的工程范围。

---

## 3. 🟡 MEDIUM：方案遗漏和逻辑问题

### #M1：方案完全忽略了已实现的 Feature Flag 体系

代码中已有两套 Feature Flag：

```swift
// HoloAIFeatureFlags — AI 核心能力开关
episodicMemoryObservationEnabled
memorySummaryInjectionEnabled
longTermMemoryWriteEnabled
semanticMemoryTypesEnabled
semanticMemoryPromptEnabled
semanticMemoryRecallEnabled
profileSnapshotEnabled
profileAnalysisInjectionEnabled

// InsightFeatureFlags — 洞察专用开关
feedbackEnabled
preferenceLearningEnabled
rerankEnabled
dailySenseEnabled
healthContextEnabled
actionCandidateEnabled
```

方案没有提及这些 Flag，也没有说明 Sense Loop 的各个 Phase 如何映射到已有 Flag。如果直接实施，可能新建一套冗余的开关系统。

**建议**：Sense Loop 的每个 Phase 应映射到现有 Flag 或新增 Flag，方案需要一份"Phase → Feature Flag 映射表"。

---

### #M2：方案声称 Daily Sense 是"规则引擎"而非 AI 生成，但暗示要改为 AI 生成

Daily Sense 当前由 `DailySenseStateBuilder` 基于规则生成（风险评分→状态判定），不经过 LLM。

方案没有明确说"要把 Daily Sense 改为 AI 生成"，但多处暗示需要更智能的状态判断（如"压力偏高""新阶段出现"）。如果是规则扩展，工程量小；如果是改为 AI 生成，需要新增 Prompt、LLM 调用和结果校验。

**建议**：明确 Daily Sense 状态判定是继续用规则引擎还是引入 AI。

---

### #M3：方案没有区分"Prompt 改进"和"代码改动"

方案 5 个 Phase 混合了两种不同性质的改动：

| 类型 | 例子 | 成本 | 风险 |
|------|------|------|------|
| Prompt 改进 | 统一表达原则、禁止文案、推荐文案模板 | 低（改文本） | 低（可回退） |
| 代码改动 | 5 档表达强度、反馈选项扩展、记忆分层升级 | 高（改架构） | 高（影响现有功能） |

**建议**：将 Phase 0 拆分为"Prompt 改进（可立即做）"和"代码改动（需独立方案）"。

---

### #M4：方案的"验收标准"无法量化验证

Phase 0 的验收标准是：
> "用户看不到'你是一个很自律的人'这类泛泛判断。"
> "洞察文案能说明证据来源。"

这些是定性标准，无法自动化验证。对于公测前的改动，需要更可测量的验收方式。

**建议**：补充"手工验收用例表"，类似 HoloProfile 方案的做法，包含具体输入→预期输出。

---

### #M5：InsightPreferenceProfile.preferredTone 与方案"表达决策层"重叠

`InsightPreferenceProfile` 有一个 `preferredTone` 字段（balanced/direct/gentle/dataFirst/fewerSuggestions），与方案的"表达决策层"概念重叠。但 `preferredTone` 当前是**死代码**——被收集但从未注入任何 Prompt。

如果方案的表达强度系统上线后，又有人激活 `preferredTone`，两个系统会冲突。

**建议**：在方案中明确 `InsightPreferenceProfile.preferredTone` 的处置——废弃（由表达强度系统替代）或作为 fallback。

---

## 4. 真正缺失的能力（方案应该聚焦的）

基于代码审查，真正需要做的不是方案描述的"新建 Sense Loop"，而是**补齐已有系统的断层**：

| 真正的断层 | 现状 | 方案对应位置 |
|-----------|------|-------------|
| 跨模块观察缺少 Finance/Tasks/Thoughts/Health 信号 | HoloObservationPackageBuilder 只支持 Habit+Goal | 方案未识别 |
| 分析查询完全绕过用户上下文 | `UserContext.empty` 传入分析路径 | 方案未识别 |
| FlexibleQuery 完全没有用户上下文 | `FlexibleQueryPlanner.plan()` 使用 `UserContext.empty` | 方案未识别 |
| 表达原则只存在于洞察 Prompt，其他 Prompt 未对齐 | 12 个独立 Prompt 各自为政 | 方案 #H1 部分覆盖 |
| 反馈系统缺"没感觉"和"频率控制"选项 | 只有 accurate/inaccurate/useful/notUseful | 方案 #H3 覆盖 |
| Health 不参与跨模块关联 | CrossModuleCorrelator 无 health 参数 | 方案描述错误 |
| Daily Sense 状态只有 3 个 | 缺少"压力偏高"和"新阶段出现" | 方案虚构为已有 |

---

## 5. 推荐修订方向

### 方案定位修正

**当前定位**："新建 Holo AI Sense Loop 体验闭环"

**建议修正为**："**识别并补齐** Holo 已有 AI 感知系统的架构断层，让 Daily Sense、洞察生成、反馈学习、卡片重排序等已实现的能力**真正串成闭环**"

### Phase 修正建议

| 原方案 Phase | 修正建议 |
|-------------|---------|
| Phase 0：统一表达原则 | ✅ 保留，但拆为"Prompt 改进"（立即做）+"代码改动"（需方案） |
| Phase 1：今日状态摘要 | ⚠️ 修正为"扩展已有 Daily Sense 3 状态为 5 状态"，不是新建 |
| Phase 2：洞察文案改造 | ⚠️ 修正为"验证现有 Prompt 表达原则的执行效果"，可能只需调 Prompt |
| Phase 3：记忆长廊筛选升级 | ⚠️ 修正为"升级已有 3 层结构 + 引入语义类型化判断"，不是新建 4 层 |
| Phase 4：轻反馈入口 | ⚠️ 修正为"在已有反馈系统上增加'没感觉'和'频率控制'选项" |
| Phase 5：生活模式模型 | ✅ 保留，这是真正的新能力 |

### 补充必要的 Phase

| 补充 Phase | 说明 |
|-----------|------|
| 补齐跨模块观察 | 扩展 HoloObservationPackageBuilder 支持 Finance/Tasks/Thoughts/Health |
| 分析查询注入用户上下文 | 修复 `UserContext.empty` 问题（与 HoloProfile 方案 Phase 1 重叠） |
| Feature Flag 映射 | Sense Loop 每个 Phase 映射到现有 HoloAIFeatureFlags / InsightFeatureFlags |

---

## 6. 总结

这份方案的产品感觉非常好——"让 Holo 不再展示 AI 能力，而是持续观察并越来越懂用户"这个方向完全正确。5 条核心原则、表达档位设计、反馈不直接进 Prompt 的架构决策都很到位。

**但方案犯了一个产品方案最致命的错误**：没有充分调研代码现状就开始设计。导致：

1. 把"已有"描述成"需要新建"→ 工程量评估失真
2. 把"不存在"描述成"已有"→ 实施时会撞墙
3. 忽略了真正的架构断层 → 最该做的事被掩盖

**建议**：先做一份"代码现状 vs 方案声称"的对齐修正，然后基于真实的断层列表重新排列优先级。方案的产品设计层（原则、文案策略、验收指标）可以保留，但实施层需要大幅修订。
