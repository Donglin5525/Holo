# Holo AI Sense Loop 公测实施方案

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 把 Holo 已有的 Daily Sense、Memory Insight、反馈学习、记忆类型化、HoloProfile 长期上下文串成一个真正工作的“理解 -> 表达 -> 反馈 -> 更理解”闭环。

**Architecture:** 本方案不新建一套并行 AI 系统，而是复用已有的 Sense Layer、InsightPreferenceProfile、InsightFeedbackAggregator、InsightCardReranker、DailySenseStateBuilder、HoloProfileSnapshot、Holo 长期记忆语义类型。实施重点是补齐断点、统一表达边界、补充用户反馈信号、让状态与记忆进入 HoloAI 的真实上下文。

**Tech Stack:** Swift / SwiftUI / Core Data / UserDefaults Feature Flags / HoloBackend Prompt Registry / Node.js backend tests / Xcode build.

---

## 0. 最终实施定位

### 0.1 本方案取代什么

本方案取代以下草案里的实施顺序，但保留其产品方向：

- `docs/_common/plans/2026-06-07-Holo-AI-Sense-Loop公测方案.md`
- `docs/_common/plans/2026-06-07-Holo-AI-Sense-Loop公测方案-对抗审查.md`
- `docs/_common/plans/2026-06-07-Holo-AI-Sense-Loop公测方案-最终审查.md`

最终定性：

> Sense Loop 不是“新建闭环”，而是“补齐已有 AI 感知系统之间的断点”。

### 0.2 必须复用的已有能力

| 已有能力 | 当前文件 | 本方案处理 |
| --- | --- | --- |
| 洞察反馈 UI | `Views/MemoryGallery/Components/InsightFeedbackSheet.swift` | 扩展反馈选项，不重做 UI 体系 |
| 反馈存储 | `MemoryInsightFeedback+CoreDataProperties.swift` / `MemoryInsightRepository.saveFeedback()` | 复用现有字符串字段，首版不做 Core Data 迁移 |
| 反馈聚合 | `Services/AI/InsightFeedbackAggregator.swift` | 增加“没感觉/少提醒”处理逻辑 |
| 洞察偏好画像 | `Models/InsightPreferenceProfile.swift` | 继续作为洞察偏好层，不与 HoloProfile 合并 |
| 卡片重排序 | `Services/AI/InsightCardReranker.swift` | 增加对“少提醒”类 pattern penalty 的消费 |
| Daily Sense | `DailySenseSnapshot.swift` / `DailySenseStateBuilder.swift` | 先复用 3 状态，再扩展状态标签 |
| HoloProfile | `HoloProfileSnapshot.swift` / `HoloProfilePromptRenderer.swift` | 作为用户主动档案层，不存最近状态 |
| 长期记忆语义类型 | `HoloLongTermMemoryModels.swift` / `MemoryCandidateSemanticMapper.swift` | 使用 `phaseShift/stablePattern/driftSignal/lifeEvent/statMilestone`，不另建记忆分类 |
| Prompt 管理 | iOS `PromptManager.swift` + 后端 `defaultPrompts.json` | 双端同步；涉及后端 prompt 的改动必须发版 |

### 0.3 最终优先级

1. 当前输入最高。
2. 用户主动档案 HoloProfile 第二。
3. 用户确认/静默接受的长期记忆第三。
4. Daily Sense、近期趋势、洞察偏好等情景上下文第四。
5. AI 推断模式只能作为低优先辅助，不能覆盖以上四层。

### 0.4 不做的事

- 不新建第二套用户画像。
- 不把最近状态写入 HoloProfile。
- 不把原始反馈文本直接塞进 Prompt。
- 不把“流水/异常/高光/里程碑”做成新的工程分类体系。
- 不让 Daily Sense 首版完全依赖 LLM。
- 不在没有证据时做“压力大”“人格”“心理状态”判断。

---

## Task 1: 建立基线与现状保护

**目标:** 在改功能前固定当前行为，避免后续无法判断体验是否变好。

**Files:**

- Read: `Holo/Holo APP/Holo/Holo/Services/AI/InsightFeedbackAggregator.swift`
- Read: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/InsightFeedbackSheet.swift`
- Read: `Holo/Holo APP/Holo/Holo/Services/AI/DailySenseStateBuilder.swift`
- Read: `Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift`
- Read: `HoloBackend/src/prompts/defaultPrompts.json`
- Modify: `docs/CHANGELOG.md` only after implementation, not during this task

### Step 1: 记录当前反馈基线

执行前先在现有数据上统计：

- `MemoryInsightFeedback` 总数。
- `accuracyRating=accurate/inaccurate` 数量。
- `valueRating=useful/notUseful` 数量。
- 未消费反馈数量。
- `InsightPreferenceProfile.json` 是否存在，是否已有 moduleWeights / dislikedPatterns。

如果没有现成调试入口，先用临时开发日志或 Xcode debug console 查询，不要为了统计新增用户可见 UI。

### Step 2: 固定现有 Daily Sense 表现

手工记录 3 类样例：

- 数据丰富用户：至少有财务、习惯、待办、健康中的 3 个维度。
- 部分模块用户：只用其中 1-2 个模块。
- 冷启动用户：几乎没有记录。

记录每类用户当前 Daily Sense 显示的 state 和 signals。

### Step 3: 记录现有 AI 文案样例

至少生成或收集 8 条样例：

| 场景 | 样例数 |
| --- | --- |
| 普通聊天 | 2 |
| 记忆洞察 | 2 |
| 分析查询 | 2 |
| flexible data query | 1 |
| Daily Sense 文案 | 1 |

验收时要对比这些样例是否减少了冷数据感、强因果和泛泛鼓励。

### Step 4: 工作区保护

实施前运行：

```bash
git -C /Users/tangyuxuan/Desktop/Claude/HOLO status --short
```

只提交本轮相关文件。不要混入已经存在的审查文档草稿，除非用户明确要求一起提交。

---

## Task 2: 反馈入口补齐

**目标:** 公测第一天就能收集“懂不懂用户”的信号。复用现有反馈体系，新增“没感觉”和“少提醒这个”。

**产品语义:**

| 用户动作 | 真实含义 | 系统行为 |
| --- | --- | --- |
| 准 | 事实和关联基本正确 | 对模块轻微升权 |
| 不准 | 事实、关系或建议错误 | 按原因降权或惩罚 pattern |
| 有用 | 对我有帮助 | 对模块或 pattern 轻微升权 |
| 没感觉 | 可能没错，但我不在乎 | 降低相同 pattern 的展示优先级，不等同于事实错误 |
| 少提醒这个 | 内容可能有用，但出现太频繁或时机不对 | 增加 pattern penalty，并偏向 `fewerSuggestions` |

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Models/MemoryInsightModels.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/InsightFeedbackSheet.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/InsightFeedbackAggregator.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/InsightCardReranker.swift` if needed
- Test: add or extend `Holo/Holo APP/Holo/HoloTests/Services/AI/InsightFeedbackAggregatorTests.swift`

### Step 1: 扩展反馈枚举，不做 Core Data 迁移

在 `MemoryInsightModels.swift` 中扩展现有 enum：

```swift
enum ValueRating: String, Codable {
    case useful
    case notUseful
    case notMeaningful   // 用户觉得“没感觉”
}

enum FeedbackReasonType: String, Codable, CaseIterable {
    case dataWrong
    case relationWrong
    case priorityWrong
    case suggestionWrong
    case toneWrong
    case tooFrequent     // 用户选择“少提醒这个”

    var displayName: String {
        switch self {
        case .dataWrong: return "数据不准"
        case .relationWrong: return "关联不准"
        case .priorityWrong: return "重点不准"
        case .suggestionWrong: return "建议不适合"
        case .toneWrong: return "语气不喜欢"
        case .tooFrequent: return "少提醒这个"
        }
    }
}
```

说明：

- `valueRating` 和 `reasonType` 在 Core Data 中是字符串字段，所以新增 raw value 不需要新增 Core Data attribute。
- 不要改 `.xcdatamodeld`，除非实施时确认 schema 有硬枚举限制。

### Step 2: 更新反馈 Sheet

在 `InsightFeedbackSheet.swift` 中把“没用”拆成两个按钮：

- `没感觉`：`valueRating = .notMeaningful`
- `没用`：`valueRating = .notUseful`

新增一个独立低摩擦选项：

- `少提醒这个`：`reasonType = .tooFrequent`

交互规则：

- “不准”仍然要求选择不准原因。
- “没感觉”不要求选择不准原因。
- “少提醒这个”可以单独提交，也可以和“没感觉”一起提交。
- 不要把“少提醒这个”放在“不准原因”里面，只是复用 `reasonType` 存储。

### Step 3: 更新提交校验

`canSubmit` 规则改成：

```swift
private var canSubmit: Bool {
    if accuracyRating == .inaccurate {
        return reasonType != nil
    }
    return accuracyRating != nil || valueRating != nil || reasonType == .tooFrequent
}
```

### Step 4: 更新聚合逻辑

在 `InsightFeedbackAggregator.aggregate(in:)` 中新增处理：

```swift
case .tooFrequent:
    if let pattern = feedback.patternType ?? feedback.module {
        var pen = patternPenalties[pattern] ?? (penalty: 0.15, count: 0, reason: nil)
        pen.count += 1
        pen.reason = "用户希望减少此类提醒"
        patternPenalties[pattern] = pen
    }
    toneSignals[.fewerSuggestions, default: 0] += 1
```

处理 `ValueRating.notMeaningful`：

```swift
case .notMeaningful:
    if let pattern = feedback.patternType ?? feedback.module {
        var pen = patternPenalties[pattern] ?? (penalty: 0.1, count: 0, reason: nil)
        pen.count += 1
        pen.reason = "用户觉得这类洞察没感觉"
        patternPenalties[pattern] = pen
    }
```

`notUseful` 仍可降低模块权重，但 `notMeaningful` 优先惩罚 pattern，避免因为一类冷数据卡片让整个 finance/habit 模块被过度降权。

### Step 5: 让 preferredTone 真正生效

当前 `InsightPreferenceProfile.preferredTone` 已存在，但主要是收集字段。首版先做最小消费：

- 当 `toneSignals[.fewerSuggestions] >= 1` 时，更新 profile.preferredTone = `.fewerSuggestions`。
- 在 Prompt 对齐阶段，把稳定的 `preferredTone` 摘要注入洞察生成 Prompt，不注入原始反馈。

### Step 6: 测试

新增或扩展测试覆盖：

1. `notMeaningful` 不会被当成 `inaccurate`。
2. `tooFrequent` 会增加对应 pattern penalty。
3. `notMeaningful` 优先惩罚 pattern，而不是直接打低整个模块。
4. `tooFrequent` 会把 `preferredTone` 推向 `.fewerSuggestions`。
5. 旧的 `useful/notUseful/accurate/inaccurate` 行为不变。

推荐命令：

```bash
xcodebuild -project "/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' test
```

如果当前 scheme 没有稳定 Test action，至少运行：

```bash
xcodebuild -project "/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

---

## Task 3: Prompt 表达原则对齐

**目标:** 把“克制、具体、有证据、不强因果、不人格判断”扩展到高曝光 AI 入口。不要一次性改所有 Prompt。

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift`
- Modify: `HoloBackend/src/prompts/defaultPrompts.json`
- Test: `HoloBackend/tests/prompts.test.js`

### Step 1: 只改 4 个高曝光 Prompt

本轮只改：

| Prompt | 原因 |
| --- | --- |
| `system_prompt` | 普通聊天主入口 |
| `memory_insight_generation` | 洞察卡片主入口 |
| `analysis_prompt` | 分析查询主入口 |
| `flexible_query_planner` | 灵活数据查询规划入口，避免 profile/状态误导查询 |

不在本轮改：

- `dataExtraction`
- `clarification`
- `thought_voice_summary`
- 低频或纯工具类 Prompt

### Step 2: 提炼统一表达边界

每个高曝光 Prompt 都应包含以下规则，但写法可以按场景精简：

```text
表达边界：
- 只基于真实上下文和用户当前输入回答。
- 区分事实、观察、假设和建议。
- 低置信判断必须使用“可能/像是/值得留意”，不能说成确定结论。
- 跨模块关系只能表达为并发现象或值得留意的关联，不能说“导致/证明/说明一定因为”。
- 不做人格、心理、医疗诊断。
- 少用空泛鼓励，多给一个具体、可执行的小切口。
- 用户当前明确输入永远优先；档案、记忆、近期状态只能辅助理解。
```

### Step 3: 把 HoloProfile 优先级写进 Prompt

在 chat / analysis / flexible query 相关 Prompt 中加入：

```text
用户档案与长期记忆使用规则：
- HoloProfile 是用户主动档案，权重高于 AI 自动推断记忆。
- 长期记忆和近期状态只能辅助理解，不能覆盖用户本轮明确输入。
- 如果档案/记忆与本轮输入冲突，以本轮输入为准。
- 不要主动暴露敏感档案细节，除非用户话题相关。
```

### Step 4: 把洞察偏好摘要接入 memory insight

不要把原始反馈进 Prompt。只允许进入稳定、压缩后的摘要。例如：

```text
洞察偏好摘要：
- 用户近期对 {pattern} 类洞察反馈“没感觉”，请降低其优先级，除非有强证据。
- 用户选择 fewerSuggestions，请减少建议数量，优先输出观察和一个最小动作。
```

实现位置优先选择：

- `MemoryInsightContextBuilder` 将稳定偏好摘要加入 context。
- 或 `MemoryInsightService` 调用 provider 前附加到 context JSON。

不要把 `MemoryInsightFeedback.userCorrection` 原文直接拼入 Prompt。

### Step 5: 双端同步

涉及 Prompt 时必须同步：

- iOS fallback：`PromptManager.swift`
- 后端默认：`HoloBackend/src/prompts/defaultPrompts.json`
- 后端版本：`HoloBackend/src/prompts/promptRegistry.js` 中对应版本号
- 后端测试：`HoloBackend/tests/prompts.test.js`

### Step 6: 后端测试

新增断言：

```js
assert.match(prompt.content, /区分事实、观察、假设和建议/);
assert.match(prompt.content, /当前明确输入永远优先/);
assert.match(prompt.content, /不能说.*导致|跨模块关系/);
assert.doesNotMatch(prompt.content, /你是一个很自律的人/);
```

运行：

```bash
cd /Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend
npm test
```

### Step 7: 后端发版要求

如果改了 `HoloBackend/src/prompts/defaultPrompts.json` 或 `promptRegistry.js`，实施完成后必须发版后端：

```bash
rsync -az --delete --exclude node_modules --exclude .env --exclude deploy/.env.production --exclude deploy/data /Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend/ root@123.56.104.9:/root/Holo/HoloBackend/
ssh root@123.56.104.9 'cd /root/Holo/HoloBackend/deploy && DOCKER_BUILDKIT=0 docker compose build holo-backend && docker compose up -d --force-recreate holo-backend'
```

上线后必须验证：

- `/v1/health`
- `/v1/prompts/system_prompt`
- `/v1/prompts/memory_insight_generation`
- `/v1/prompts/analysis_prompt`
- `/v1/prompts/flexible_query_planner`

---

## Task 4: 记忆长廊与长期记忆语义整合

**目标:** 保留“状态河流里长出里程碑”的产品表达，但工程上复用长期记忆类型化方案，不另建分类体系。

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/MemoryCandidateSemanticMapper.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/HoloMemoryPromotionPolicy.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/AI/HoloMemoryCandidateCard.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/AI/HoloMemoryCenterView.swift`
- Modify if needed: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryViewModel.swift`
- Test: add or extend memory semantic mapper / promotion policy tests

### Step 1: 建立产品语言到工程语义的映射

不要新增 `流水/异常/高光/里程碑` enum。使用映射表：

| 产品语言 | 工程语义 |
| --- | --- |
| 流水 | 不进入长期记忆；仅保留在原始模块记录 |
| 异常 | `driftSignal` 或普通 anomaly card，不默认长期保留 |
| 高光 | `stablePattern` / `lifeEvent` / `phaseShift` 的短期展示 |
| 里程碑 | `phaseShift` / `statMilestone` |
| 人生节点 | `lifeEvent` |

### Step 2: 使用四条件作为晋升规则，不作为新分类

四条件：

- 阶段性。
- 稳定性。
- 用户相关性。
- 可证据化。

它们用于 `HoloMemoryPromotionPolicy` 判断：

```text
phaseShift: 必须满足阶段性 + 可证据化，财务/健康/职业高影响领域需要确认
stablePattern: 必须满足稳定性 + 可证据化，低敏可静默
driftSignal: 必须满足用户相关性 + 可证据化，默认过期，默认待确认
lifeEvent: 必须用户相关 + 可证据化，默认待确认
statMilestone: 可证据化即可，但 useScope 默认 displayOnly
```

### Step 3: 防止冷数据抢主叙事

在 `MemoryCandidateSemanticMapper` 或 prompt 约束中强化：

- 单纯“记录了第 N 笔”只能是 `statMilestone`，默认 `displayOnly`。
- 单日消费突增不能直接变成 `phaseShift`。
- 混合语义必须拆分：如“任务清零，支出偏高”不能变成一条候选。
- `crossDomain` 默认不晋升，除非能拆成单一主语义。

### Step 4: 展示层保留用户能懂的名称

UI 可以展示：

| semanticType | 用户文案 |
| --- | --- |
| phaseShift | 阶段变化 |
| stablePattern | 稳定节奏 |
| driftSignal | 需要留意 |
| lifeEvent | 人生节点 |
| statMilestone | 轻量记录 |

不要展示 “phaseShift” 这类工程词。

### Step 5: 测试

覆盖：

1. `statMilestone` 不进入 core context。
2. `driftSignal` 有默认过期时间。
3. `phaseShift` 高影响领域要求确认。
4. 混合语义被拒绝或拆分。
5. 旧数据 `semanticType=nil` 仍能显示，不崩溃。

---

## Task 5: Daily Sense 状态摘要扩展

**目标:** 最终允许 Holo 识别“压力偏高”和“新阶段出现”，但不破坏现有 3 状态 UI。最佳方案采用“3 个主状态 + 2 个状态标签”。

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Models/DailySenseSnapshot.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/DailySenseStateBuilder.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/DailySenseStatusCard.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryViewModel.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Models/DailySenseSnapshotTests.swift`

### Step 1: 不扩主状态 enum

保留：

```swift
enum DailySenseState: String, Codable {
    case stable
    case atRisk
    case recovering
}
```

新增标签：

```swift
enum DailySenseTag: String, Codable, CaseIterable {
    case highPressure
    case newStage
}
```

在 `DailySenseSnapshot` 增加：

```swift
let tags: [DailySenseTag]
```

使用 `decodeIfPresent`，旧缓存缺失时默认为 `[]`。这需要 `schemaVersion = 3`。

### Step 2: highPressure 规则

`highPressure` 不是人格判断，而是多信号并发标签。规则：

满足以下至少 3 个独立信号，才允许出现：

- task: 逾期或临近截止明显集中。
- expense: 餐饮/咖啡/外卖/交通等可调整支出显著偏离。
- habit: 关键习惯断连或恢复失败。
- health: 睡眠 < 6h 或步数显著偏少。
- thought: 暂不接入 Daily Sense 主模型；如要使用，必须先有结构化 thought signal。

展示文案必须是：

> “这几个信号像是一起偏紧，先不用过度解读。”

禁止：

- “你压力很大。”
- “你焦虑了。”
- “消费变多是因为压力。”

### Step 3: newStage 规则

`newStage` 必须来自已确认或高置信的长期记忆/候选：

- `phaseShift`
- `lifeEvent`
- 高质量 `statMilestone`，但只作为轻量展示

不要仅凭单日数据生成 `newStage`。

### Step 4: UI 表达

主标题仍然使用 3 状态：

- 节奏不错。
- 节奏有点乱。
- 节奏在找回。

标签只作为副文案或 chip：

- `highPressure` -> “信号偏紧”
- `newStage` -> “出现新阶段”

### Step 5: AI 失败降级

Daily Sense 第一版仍用规则引擎。后续如引入 LLM 辅助判断，必须：

- 规则引擎先给 snapshot。
- LLM 只能补 tags 或文案建议。
- LLM 失败时展示规则结果。
- LLM 不允许改写事实数据。

### Step 6: 测试

更新 `DailySenseSnapshotTests.swift`：

1. v3 round trip 包含 tags。
2. v2 JSON 解码 tags 为空。
3. `highPressure` 至少 3 个信号才出现。
4. 单一 finance spike 不会出现 `highPressure`。
5. `newStage` 不从单日普通数据生成。

---

## Task 6: 跨模块观察补齐 Health 与缺失模块降级

**目标:** 让“生活状态”判断真的基于多模块，而不是靠文案假装联动。

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/CrossModuleCorrelator.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/MemoryInsightContextBuilder.swift`
- Modify if needed: `Holo/Holo APP/Holo/Holo/Models/MemoryInsightModels.swift`
- Test: add or extend `CrossModuleCorrelator` tests

### Step 1: 增加 health 输入

当前 `CrossModuleCorrelator.detect()` 接收 finance/habits/tasks/thoughts。最佳方案扩展为：

```swift
static func detect(
    finance: MemoryInsightFinanceContext,
    habits: MemoryInsightHabitContext,
    tasks: MemoryInsightTaskContext,
    thoughts: MemoryInsightThoughtContext,
    health: MemoryInsightHealthContext?
) -> [CrossModuleCorrelation]
```

如果 `MemoryInsightHealthContext` 尚未完整存在，先接入已有 health summary，不要为了本任务重构健康模块。

### Step 2: 新增 health 相关并发模式

首版只做 3 个保守模式：

| patternType | 条件 | 表达 |
| --- | --- | --- |
| `sleep_task_pressure` | 睡眠偏少 + 任务逾期/堆积 | “休息偏少和任务压力在同一段时间出现” |
| `sleep_habit_break` | 睡眠偏少 + 习惯断连 | “休息偏少时，习惯节奏也有中断” |
| `low_activity_recovery` | 步数低 + 恢复中状态 | “活动量偏低，但其他节奏有恢复迹象” |

禁止因果词。

### Step 3: 部分模块降级

如果只有 1 个模块有数据：

- 不生成 crossModule correlation。
- Daily Sense 只展示该模块信号。
- AI 文案使用“单一信号”，不能归纳生活状态。

如果有 2 个模块：

- 只允许“并发观察”，不允许 `highPressure`。

如果有 3 个以上模块：

- 才允许 `highPressure` 标签。

### Step 4: 测试

1. 无 health 时旧逻辑不变。
2. 有 sleep + tasks 时生成 `sleep_task_pressure`。
3. 单一模块不会生成 cross module。
4. 输出 summary 不含 “导致/因为/说明/证明”。

---

## Task 7: 表达强度系统

**目标:** 把 Sense Loop 的真正增量能力落地：Holo 不只是知道内容，还知道该用什么强度表达。

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Models/AI/HoloExpressionModels.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/HoloExpressionDecisionEngine.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/AIUserContextMessageBuilder.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/MemoryInsightContextBuilder.swift` or insight generation context assembly
- Test: add `Holo/Holo APP/Holo/HoloTests/Services/AI/HoloExpressionDecisionEngineTests.swift`

### Step 1: 新增模型

```swift
enum HoloExpressionLevel: String, Codable {
    case observe       // 看见
    case summarize     // 归纳
    case remind        // 提醒
    case suggestAction // 行动建议
    case celebrate     // 庆祝
}

struct HoloExpressionDecision: Codable, Equatable {
    let level: HoloExpressionLevel
    let confidence: Double
    let evidenceCount: Int
    let allowedVerbs: [String]
    let bannedPhrases: [String]
    let reason: String
}
```

### Step 2: 决策规则

| level | 条件 | 表达限制 |
| --- | --- | --- |
| observe | 1 个弱信号 | 只说“看到”，不建议 |
| summarize | ≥3 个独立信号，且无强敏感 | 必须用“可能/像是/值得留意” |
| remind | 与用户目标或 HoloProfile 当前关注相关 | 只给一个小提醒 |
| suggestAction | 用户明确求助，或反馈显示此类建议有用 | 只给一个最小动作 |
| celebrate | 已确认里程碑或明确阶段进展 | 只说具体证据，不空泛夸奖 |

### Step 3: 归纳安全边界

`summarize` 必须满足：

- `evidenceCount >= 3`
- 至少来自 3 个独立维度或 2 个维度 + 已确认长期记忆
- 不能涉及医疗、心理、人格判断
- 输出必须带不确定词

### Step 4: 接入 Prompt

不要让 LLM 自己猜表达强度。把 decision 作为结构化上下文传入：

```text
本次表达强度：summarize
允许：用“可能/像是/值得留意”做轻归纳
禁止：说“导致/证明/你就是”
证据数量：3
```

### Step 5: 测试

1. 单一消费异常 -> `.observe`
2. 三个独立信号 -> `.summarize`
3. 与戒烟目标相关 -> `.remind`
4. 用户明确“怎么办” -> `.suggestAction`
5. confirmed `phaseShift` -> `.celebrate`
6. 健康敏感信号不会进入强判断。

---

## Task 8: 冷启动、部分模块、LLM 失败降级

**目标:** 防止 Holo 在数据不足时装懂。

**Files:**

- Modify: `DailySenseStateBuilder.swift`
- Modify: `MemoryInsightContextBuilder.swift`
- Modify: `AIUserContextMessageBuilder.swift`
- Modify: `MemoryInsightService.swift`
- Test: relevant builder tests

### Step 1: 冷启动规则

无数据或数据极少时：

- Daily Sense 不显示“状态判断”，只显示“开始记录后，我会帮你看节奏”。
- HoloAI 不生成生活模式判断。
- 记忆长廊不生成里程碑。
- 洞察卡片最多输出 onboarding-style overview，不输出 anomaly。

### Step 2: 部分模块规则

只启用单模块时：

- 可以输出模块内观察。
- 不输出跨模块归纳。
- 不输出 `highPressure`。

### Step 3: LLM 失败规则

Memory Insight 生成失败：

- 保留现有 generating/failed 状态。
- UI 显示可重试。
- 不保存半成品洞察。
- 不消费反馈。

Daily Sense LLM 辅助失败：

- 直接回退规则 snapshot。

Prompt 拉取失败：

- iOS 使用 `PromptManager` fallback。
- 后端健康验证必须确认 prompt source/version。

### Step 4: 已有用户过渡

- 旧 `DailySenseSnapshot` 正常解码，缺 tags 默认 `[]`。
- 旧 `InsightPreferenceProfile` 正常解码，新字段默认值。
- 旧 `MemoryInsightFeedback` 正常聚合，不要求补字段。
- 用户之前的反馈不迁移为“没感觉/少提醒”，只影响后续新反馈。

---

## Task 9: 生活模式模型

**目标:** 最终形成 Holo 的长期壁垒：知道用户什么时候容易波动、怎样恢复、什么建议对这个人有效。

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Models/AI/HoloLifePatternModel.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/HoloLifePatternService.swift`
- Modify: `AIUserContextMessageBuilder.swift`
- Modify: `MemoryInsightContextBuilder.swift`
- Test: `HoloLifePatternServiceTests.swift`

### Step 1: 模型字段

```swift
struct HoloLifePatternModel: Codable, Equatable {
    var schemaVersion: Int
    var pressurePatterns: [LifePatternEntry]
    var recoveryPatterns: [LifePatternEntry]
    var effectiveInterventionStyles: [LifePatternEntry]
    var lowValueTopics: [LifePatternEntry]
    var updatedAt: Date
}

struct LifePatternEntry: Codable, Equatable {
    let key: String
    var summary: String
    var evidenceCount: Int
    var confidence: Double
    var lastSeenAt: Date
    var source: LifePatternSource
}
```

### Step 2: 输入来源

只允许稳定信号进入：

- 连续多次 Daily Sense 标签。
- 用户多次反馈“有用/没感觉/少提醒”。
- 用户确认的长期记忆。
- 多周期 Memory Insight。

不允许：

- 单次聊天猜测。
- 单次消费异常。
- 未确认敏感记忆。

### Step 3: 注入规则

Life Pattern 只在以下场景注入：

- 用户问“我最近怎么样”。
- 记忆洞察生成。
- 年度/月度回顾。
- 用户明确求建议。

不注入：

- 意图识别。
- 记账/任务创建等执行型操作。
- flexible query planner 的硬查询规划。

### Step 4: 测试

1. 单次信号不会形成 pattern。
2. 多次 highPressure + feedback 有用才形成 pressure pattern。
3. 用户选择“少提醒这个”会进入 lowValueTopics。
4. intentRecognition 不注入 life pattern。

---

## Task 10: 验收与发布

**目标:** 确保实施后是真的更懂用户，而不是只是代码变多。

### Step 1: 自动化验证

iOS：

```bash
xcodebuild -project "/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

如 Test action 可用：

```bash
xcodebuild -project "/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' test
```

后端：

```bash
cd /Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend
npm test
```

### Step 2: 手工验收用例

| 用例 | 输入/状态 | 预期 |
| --- | --- | --- |
| 冷启动 | 无数据 | 不生成生活判断，只引导开始记录 |
| 单模块 | 只有记账 | 只说财务观察，不做生活状态归纳 |
| 多信号 | 睡眠少 + 任务堆积 + 外卖咖啡增加 | 可以说“信号偏紧”，不能说“你压力大导致花钱” |
| 戒烟目标 | HoloProfile 写明戒烟，今天记录抽烟 | 按负向习惯理解，不说“完成更多” |
| 没感觉反馈 | 对冷数据消费卡点“没感觉” | 同类 pattern 后续降权 |
| 少提醒反馈 | 对某类建议点“少提醒这个” | 后续建议减少，preferredTone 可变为 fewerSuggestions |
| 里程碑 | 连续控制抽烟 7 天 | 可庆祝具体证据，不空泛夸人格 |
| 当前输入冲突 | Profile 关注咖啡，但用户问烟花消费 | 以当前输入为准，不误判成咖啡 |

### Step 3: 公测指标

必须埋点或至少可本地统计：

- 洞察反馈提交率。
- `accurate/inaccurate` 比例。
- `useful/notUseful/notMeaningful` 比例。
- `tooFrequent` 次数。
- 洞察卡片 rerank 后用户反馈是否改善。
- Daily Sense 标签出现频率。
- 失败/回退次数。

### Step 4: CHANGELOG

完成后更新：

- `CHANGELOG.md`
- `docs/CHANGELOG.md`（如果当前仓库惯例要求）

建议条目：

```markdown
- HoloAI Sense Loop: 复用现有 Sense Layer、HoloProfile、长期记忆语义类型和洞察反馈体系，补齐反馈信号、Prompt 表达边界、Daily Sense 状态标签、跨模块健康信号和表达强度决策。
```

### Step 5: Commit 策略

建议至少分 5 个提交：

1. `feat: expand insight feedback signals`
2. `feat: align AI expression guardrails`
3. `feat: integrate memory semantics into sense loop`
4. `feat: extend daily sense tags and health correlations`
5. `feat: add expression decision layer`

后端 prompt 改动必须单独标注，并在最终说明中区分：

- GitHub 是否已 push。
- 后端是否已部署。
- 线上 prompt 是否已验证。

---

## 最终实施顺序

不要跳过前置闭环。推荐顺序：

1. Task 1：基线与保护。
2. Task 2：反馈入口补齐。
3. Task 3：Prompt 表达原则对齐。
4. Task 4：记忆语义整合。
5. Task 8：冷启动与降级策略。
6. Task 5：Daily Sense 状态标签扩展。
7. Task 6：Health 跨模块观察。
8. Task 7：表达强度系统。
9. Task 9：生活模式模型。
10. Task 10：验收、changelog、commit、后端发版。

这样实施的原因：

- 先收反馈，公测第一天就能学习。
- 先对齐 Prompt，立刻降低“AI 自作聪明”的风险。
- 先复用语义类型，避免记忆系统重复分类。
- 再扩状态和表达强度，确保新增智能建立在真实信号上。
- 最后做生活模式模型，把短期反馈沉淀成长期理解。
