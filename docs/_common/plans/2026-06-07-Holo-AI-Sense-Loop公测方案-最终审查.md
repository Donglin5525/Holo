# Holo AI Sense Loop 公测方案 — 最终审查报告（终版）

> 审查日期：2026-06-07
> 审查轮次：第一轮（代码验证）+ 第二轮（内部逻辑 + 跨方案冲突）
> 审查结论：**🔴 Conditional Stop — 方案方向正确但前提失实，需做 3 处结构性修正后才能进入实施规划**

---

## 0. 总体判断

### 方案做对了什么

1. **问题诊断准确**：Holo 确实缺少一条把用户档案、日常状态、记忆洞察、聊天表达和用户反馈串起来的理解闭环。
2. **产品方向正确**：从"展示 AI 能力"转向"持续理解并陪伴用户"，这个方向是正确的。
3. **核心原则到位**：观察先于表达、不把假设说成事实、反馈不直接进 Prompt——这些架构决策都很好。
4. **5 条核心原则、表达档位、文案模板**的产品设计质量高。

### 方案做错了什么

1. **没有充分调研代码现状**：方案声称要"新建"的 5 个核心组件中，4 个已经实现。
2. **多处事实描述与代码不符**：状态数量、反馈选项、记忆层级、跨模块范围均有误差。
3. **忽略了 3 份已在进行的相关方案**：Holo Sense Layer 洞察闭环（5月23日）、记忆管理类型化重构（6月6日）、HoloProfile 长期上下文（6月7日）。这三份方案覆盖了 Sense Loop 60%+ 的内容。
4. **Phase 排序不合理**：反馈入口放在最后、表达强度系统未评估工程量、Phase 0 隐含了"一次性重构所有 AI 链路"。

### 一句话总结

> 方案的**产品设计层**（what & why）可以保留，但**实施规划层**（how & when）需要基于代码现状和已有方案，做大幅修订。

---

## 1. 🔴 CRITICAL：与已有方案的严重重叠

Sense Loop 方案不是凭空出现的——过去 3 周已有 3 份方案在解决相同方向的问题，且多已进入代码实施阶段。

### 1.1 与 "Holo Sense Layer 洞察闭环方案"的重叠（5月23日，已实施）

| Sense Layer 方案设计 | Sense Loop 方案声称 | 重叠度 |
|---------------------|-------------------|--------|
| "Sense Context 层：今日状态信号 + 健康信号 + 长期偏好摘要" | Phase 1 "今日状态摘要" | 90% |
| "Learning & Action Layer：用户反馈 + 偏好聚合 + 卡片 rerank" | Phase 4 "轻反馈入口" | 85% |
| "洞察卡片生成后：偏好聚合 → rerank / filter" | Phase 3 "记忆长廊筛选升级" | 70% |
| "非目标：不一次性重构 AI Chat 全链路" | 非目标第5条：完全相同的约束 | 100% |

**Sense Layer 方案的核心能力已经实现**：
- `InsightFeedbackAggregator` → 反馈聚合
- `InsightPreferenceProfile` → 偏好画像
- `InsightCardReranker` → 卡片重排序
- `DailySenseStateBuilder` → 每日状态
- `CrossModuleCorrelator` → 跨模块关联
- `InsightFeatureFlags` → 功能开关

**Sense Loop 方案完全没有引用或承认 Sense Layer 方案的存在**——这是最严重的问题。Sense Loop 方案给人的印象是"从零建一个闭环"，但实际上闭环的大部分已经在运行。

### 1.2 与 "Holo 记忆管理类型化重构方案"的重叠（6月6日，已部分实施）

| 记忆类型化方案内容 | Sense Loop 方案内容 | 重叠度 |
|------------------|-------------------|--------|
| 5 种语义类型：phaseShift / stablePattern / driftSignal / lifeEvent / statMilestone | Phase 3 "流水/异常/高光/里程碑"四层 | 75% |
| displaySummary + aiUseSummary 双层摘要 | 无对应设计 | - |
| useScopes + prohibitedInferences AI 使用控制 | 无对应设计 | - |
| 记忆召回去重与冲突检测 | Phase 3 "里程碑判断四条件" | 60% |

**关键冲突**：
1. 记忆类型化方案的 5 种语义类型比 Sense Loop 的"流水/异常/高光/里程碑"四层更精细、更面向 AI 使用。如果两个体系并存，会出现"一条记忆同时有两种分类"的混乱。
2. 记忆类型化方案已经考虑了 useScopes（决定何时召回）和 prohibitedInferences（决定不能误判什么），Sense Loop 方案完全没有涉及这些维度。
3. 记忆类型化方案已在实施——`MemoryCandidateSemanticMapper.swift`、HoloLongTermMemory 模型改动、Feature Flags 均已完成。

### 1.3 与 "HoloProfile 作为 AI 长期上下文方案"的重叠（6月7日，Phase 1 代码已写）

| HoloProfile 方案内容 | Sense Loop 方案内容 | 重叠度 |
|---------------------|-------------------|--------|
| 用户理解层：preferredName / communicationStyle / currentFocus / sensitiveBoundaries | 第 4.1 节"用户理解层"：长期关注/当前目标/偏好表达/敏感边界 | 80% |
| 四层优先级模型：当前输入 > Profile > 长期记忆 > 情景上下文 | 第 6 节优先级：当前明确输入 > 用户主动目标 > 最近状态 > AI 推断模式 | 85% |
| HoloProfilePromptRenderer 渲染 prompt 文本 | 第 7 节"Prompt 与文案策略" | 60% |

**关键冲突**：
1. Sense Loop 的"用户理解层"把"最近状态"放在用户档案中。HoloProfile 方案明确区分了"用户主动档案"和"情景上下文"——最近状态属于情景上下文，不是用户档案。
2. Sense Loop 的优先级模型把 AI 推断模式列为第四优先。HoloProfile 方案把长期记忆（AI 提取+用户确认）放在第三层，比 Sense Loop 给 AI 推断的权重更高。
3. InsightPreferenceProfile.preferredTone 是死代码（收集但从未注入 prompt），HoloProfile 的 communicationStyle 刚实现（Phase 1 已完成）。如果 Sense Loop 也引入表达偏好，会变成三个系统管理同一个概念。

---

## 2. 🔴 CRITICAL：方案内部逻辑矛盾

### 矛盾 2.1：非目标 vs Phase 0 自相矛盾

```
非目标第5条："不一次性重构所有 AI 链路"

Phase 0 描述："统一 Holo AI 文案原则。Prompt 规则：聊天、洞察、Daily Sense 共用一套表达边界。"
```

Phase 0 要求统一所有 Prompt 的表达原则——这**就是一次性重构所有 AI 链路**。目前 12 个 Prompt 各有各的表达规则，要"共用一套表达边界"，需要改动：
- `memoryInsightGeneration` prompt
- `systemPrompt`（聊天主 prompt）
- `intentRecognition` prompt
- `analysisPrompt`（分析查询）
- `flexibleQueryPlanner` prompt
- `memoryObserver` prompt
- `dataExtraction` prompt
- `clarification` prompt
- 等至少 6-8 个 Prompt

**要么去掉非目标第5条，要么缩小 Phase 0 的范围。**

### 矛盾 2.2：Phase 排序不合理

```
公测前必须做（4 项）→ 公测期第一轮迭代（反馈入口）→ 公测后核心升级（生活模式模型）
```

**问题**：反馈入口（Phase 4）放在"公测期第一轮迭代"，意味着公测第一天没有反馈收集能力。但公测第一天恰恰是"第一印象"窗口——用户看到第一条洞察、感受到第一次 AI 陪伴的质量信号，一旦错过就无法重来。

**建议排序**：

```
公测前：
  1. 轻反馈入口（已有系统验证 + 补充"没感觉"+"频率控制"） — 感知最高
  2. 洞察 Prompt 表达原则对齐（不新增系统，只对齐已有原则） — 风险最低
  3. 记忆筛选升级（基于已有语义类型） — 已有基础

公测期第一轮迭代：
  4. 状态摘要扩展（3 状态 → 5 状态）
  5. 表达强度系统（从零构建，工程量最大）
```

### 矛盾 2.3："归纳"档位 vs "不把猜测说成结论"

方案原则："（不把）并发信号说成因果关系"
5 档表达中的"归纳"："多信号并发 → 它可能代表某个状态"

"多信号并发 → 更像一个忙碌支撑状态" 这种表达，在用户看来就是"Holo 在推论我的状态"。从信号到状态的归纳，本质上是推断。方案没有给出"归纳"和"强因果"的边界标准——什么时候是安全的归纳，什么时候越界了？

**建议**：补充"归纳"档位的判断规则。例如：
- 归纳必须有 ≥3 个独立信号源
- 归纳必须用"可能/像是/值得留意"，不可用"说明/导致/因为"
- 归纳不涉及用户人格或长期能力判断

---

## 3. 🟠 HIGH：方案假设与代码事实的系统性偏差

以下为第一轮代码审查的 5 个关键发现（详细证据见第一轮审查报告）：

| # | 方案声称 | 代码事实 | 影响 |
|---|---------|---------|------|
| H1 | 需要建立反馈学习闭环 | `InsightFeedbackAggregator` + `InsightPreferenceProfile` + `InsightCardReranker` 已完整实现 | Phase 4 不能叫"新建"，应叫"补缺" |
| H2 | Daily Sense 有 5 个状态 | 只有 3 个（stable/atRisk/recovering），无"压力偏高""新阶段出现" | Phase 1 需要从零扩展判定逻辑 |
| H3 | 4 个反馈选项 | 只有 accurate/inaccurate + useful/notUseful，无"没感觉""少提醒这个" | 需要新建 UI 和处理逻辑 |
| H4 | 5 档表达强度系统 | 代码中完全不存在，无 ExpressionLevel 或类似概念 | 整个方案中工程量最大的一项 |
| H5 | 跨模块观察 5 个维度含 Health | CrossModuleCorrelator 无 health 参数，DailySenseDimension 无 thought | 方案描述与代码不符 |

---

## 4. 🟠 HIGH：遗漏的关键场景

### 4.1 冷启动场景（无数据用户）

新用户安装 Holo 后：
- 没有习惯记录 → 习惯信号全空
- 没有消费数据 → 消费信号全空
- 没有待办 → 任务信号全空
- 没有想法 → 想法信号全空
- 没有 HoloProfile → 无用户档案

**Sense Loop 如何降级？** 方案完全没有提及。如果没有降级策略，新用户看到的可能是"今天没有足够的数据"或者更糟糕——系统胡乱推断。

### 4.2 模块部分启用场景

用户可能只用记账、不用习惯；或者只用待办、不用健康。Sense Loop 的 5 维度观察需要处理模块缺失——如果只有一个模块有数据，是无法做"多信号并发→归纳"的。

### 4.3 LLM 调用失败场景

Sense Loop 如果依赖 AI 生成状态摘要或洞察文案，LLM 调用可能失败（网络、限流、后端故障）。方案没有设计降级策略——回退到规则引擎？展示提示？静默跳过？

### 4.4 用户已存在的感知系统状态

已有用户已经看到基于规则的 Daily Sense 状态、已有反馈系统在运行。Sense Loop 上线后：
- 用户之前反馈过的洞察，如何处理？
- 已有 InsightPreferenceProfile 数据，需要迁移吗？
- 用户已经习惯的 Daily Sense 3 状态变成 5 状态，会困惑吗？

---

## 5. 🟡 MEDIUM：验收与度量问题

### 5.1 验收指标依赖尚未就绪的系统

| 方案指标 | 依赖 | 问题 |
|---------|------|------|
| 洞察有用率 | 反馈系统（Phase 4） | Phase 4 在公测后才能工作，无法测量公测前的改进效果 |
| 不准率 | 反馈系统（Phase 4） | 同上 |
| 没感觉率 | "没感觉"反馈选项 | 该选项不存在，需先新建 |
| 打扰感 | "少提醒这个"反馈选项 | 该选项不存在，需先新建 |
| 回访问题 | 用户行为跟踪 | 什么是"回访问题"？如何检测？缺少技术定义 |

### 5.2 缺少基线

方案没有说明如何测量 **公测前的基线**：
- 当前洞察有多少用户点"有用"？不知道。
- 当前洞察有多少用户点"不准"？也不知道。
- 当前 Daily Sense 状态准确率如何？不清楚。

没有基线，公测后的任何指标都无从对比，无法判断 Sense Loop 是否真的改进了体验。

**建议**：公测前至少用现有反馈系统（accurate/useful）收集 2 周基线数据。

---

## 6. 推荐行动方案

### 不做什么

1. **不要废弃 Sense Loop 方案**——产品方向正确，核心原则有价值。
2. **不要从零新建闭环**——已有系统（反馈、偏好、重排序、跨模块关联）可以通过补齐断层形成闭环。
3. **不要独立实施 Sense Loop**——必须与 HoloProfile 方案、记忆类型化方案协调，避免三个方案各建一套用户理解/表达偏好系统。

### 要做什么

#### 步骤 1：承认已有方案和代码，修正 Sense Loop 定位

将方案定位从：
> "新建 Holo AI Sense Loop 体验闭环"

修正为：
> "**识别并补齐已有 AI 感知系统的架构断层**。Holo 的反馈学习、偏好画像、卡片重排序、跨模块关联、每日状态摘要已经分别实现。Sense Loop 的任务是把它们**串成真正工作的闭环**，并补充缺失的表达强度系统和升级的状态摘要。"

#### 步骤 2：做一份 "方案-代码-已有方案" 三方对齐表

Sense Loop 方案需要明确引用并说明与以下已有产物的关系：

| 已有产物 | 关系 | 处理 |
|---------|------|------|
| Holo Sense Layer 洞察闭环方案 | 前身 | Sense Loop 是 Sense Layer 的上扩（纳入 Chat + Daily Sense + Memory Gallery） |
| Holo 记忆管理类型化重构方案 | 同层级 | 记忆类型化定义了语义层，Sense Loop 的 Phase 3 应直接使用 phaseShift/stablePattern/driftSignal/lifeEvent/statMilestone，不另建四级分类 |
| HoloProfile 长期上下文方案 | 相邻层 | 用户理解层应直接读取 HoloProfile + HoloProfileSnapshot，不另建档案字段 |
| InsightFeedbackAggregator | 已有组件 | 直接复用，只需补充"没感觉"和频率控制反馈 |
| DailySenseStateBuilder | 已有组件 | 扩展 3 状态为 5 状态，增加 AI 辅助判断 |

#### 步骤 3：重新排列 Phase 优先级

```
公测前（必须在 App Store 发布前完成）：

  Phase A：反馈入口补齐（1-2 天）
    - 基于已有 InsightFeedbackSheet，增加"没感觉"+"少提醒这个"选项
    - 确保反馈数据可被 InsightFeedbackAggregator 消费
    → 这是公测期间收集用户信号的基础设施

  Phase B：表达原则 Prompt 对齐（1-2 天）
    - 将 memoryInsightGeneration 已有的表达原则（克制/温暖/具体/不说教）
      扩展到 systemPrompt + intentRecognition + analysisPrompt
    - 不新增系统，只对齐文本
    - 后端 defaultPrompts.json + iOS PromptManager 双端同步
    → 公测前最低成本、最低风险、最高感知的改进

公测期第一轮迭代：

  Phase C：状态摘要扩展（3-5 天）
    - 基于已有 DailySenseStateBuilder，增加"压力偏高"+"新阶段出现"状态
    - 引入 AI 辅助判断（LLM 评估跨模块信号 → 状态判定）
    - 保留规则引擎作为 AI 失败时的 fallback

  Phase D：表达强度系统（需独立工程方案）
    - 这是整个 Sense Loop 中工程量最大、风险最高的一项
    - 需要独立的工程实施方案，不能只靠方案中的一段描述落地

公测后：

  Phase E：生活模式模型（已正确延期）
```

#### 步骤 4：补充冷启动和边界场景

方案需新增一节描述：
- 新用户（无数据）降级策略
- 部分模块启用降级策略
- LLM 失败时回退到规则引擎
- 已有用户数据平滑过渡

---

## 7. 最终结论

**Conditional Stop → 修正 3 处后可 Conditional Go。**

| # | 修正事项 | 性质 | 阻断级 |
|---|---------|------|--------|
| 1 | 方案定位从"新建闭环"改为"补齐已有系统断层"，并明确引用 3 份已有方案的继承关系 | 🔴 结构性 | 阻断 |
| 2 | 重新排列 Phase 优先级：反馈入口优先于状态扩展，表达强度独立方案 | 🔴 实施风险 | 阻断 |
| 3 | 补充冷启动/部分模块/LLM 失败/已有用户过渡的降级策略 | 🟠 边界遗漏 | 阻断 |

**完成以上 3 项修正后，Sense Loop 方案可以进入实施规划。**

---

## 附录：Sense Loop 方案独有的增量价值

尽管审查发现方案在多处与代码现状不符，但以下内容是 Sense Loop **相比已有方案的真正增量**，应该在修订后保留：

1. **5 档表达强度系统**（看见/归纳/提醒/行动建议/庆祝）——全新的产品概念，已有方案均未涉及
2. **Sense Loop 作为一个统一的品牌概念**——让团队和用户理解 Holo 正在建立"理解→表达→反馈→更理解"的闭环，这个叙事有价值
3. **文案模板和禁止文案示例**（第 7.2、7.3 节）——具体、可执行、可验收
4. **公测指标设计**（第 9 节）——方向正确，需要补充基线测量方法
5. **"不把猜测说成结论"的细致分层**——比已有 Prompt 原则更系统化
