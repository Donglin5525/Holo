# HoloProfile 作为 HoloAI 长期上下文方案

Date: 2026-06-07
Status: Draft for review — 三轮审查已完成（GLM → Codex → Claude），待最终定稿
Scope: HoloProfile、HoloAI 用户上下文、意图识别、分析查询、记忆洞察、长期记忆召回

---

## 审查标注索引

> 以下 `🔴` / `🟠` / `🟡` 标注由第一轮对抗性审查插入，标注内容均为**待处理问题**，非已采纳结论。
>
> | 级别 | 编号 | 问题摘要 | 位置 |
> |------|------|----------|------|
> | 🔴 CRITICAL | #1 | 分析路径 systemContextOverride 与 UserContext 互斥，"追加"不可行 | 第 6 节 Phase 1 |
> | 🔴 CRITICAL | #2 | 本地 Markdown 解析覆盖度远低于预期，fallback 双路径难测试 | 第 5.2 节 |
> | 🔴 CRITICAL | #3 | 昵称双向同步存在交互死循环，缺少 source of truth 定义 | 第 6 节 Phase 2 |
> | 🟠 HIGH | #4 | Prompt 注入路径未穷举，memory observer 等路径遗漏 | 第 6、7 节 |
> | 🟠 HIGH | #5 | Snapshot 缺少 contentHash、timezone、profession 等字段 | 第 5.2 节 |
> | 🟠 HIGH | #6 | 未区分哪些 prompt 规则需要后端部署 | 第 7 节 |
> | 🟠 HIGH | #7 | Profile 相关内容总 context 占用未评估 | 第 5 节 |
> | 🟠 HIGH | #8 | Phase 3 冲突检测缺乏具体方案，线程安全问题未解决 | 第 6 节 Phase 3 |
> | 🟡 MEDIUM | #9 | 四层优先级只靠 prompt 文本，无形式化保障 | 第 3 节 |
> | 🟡 MEDIUM | #10 | 用户清空/重置档案的边界用例未处理 | 第 9 节 |
> | 🟡 MEDIUM | #11 | Phase 4 新意图会膨胀意图识别空间 | 第 6 节 Phase 4 |
> | 🟡 MEDIUM | #12 | 结构化编辑器 UX 风险高，迁移策略缺失 | 第 8 节 |
> | 🟡 MEDIUM | #13 | Snapshot 缓存策略未设计 | 第 5.2 节 |
> | 🟡 MEDIUM | #14 | 缺少 feature flag 和回滚计划 | 第 11 节 |

---

## 1. 背景

当前 HoloProfile 已经完成 V1：用户可以在 App 内编辑一份 `HoloProfile.md`，HoloAI 普通对话和意图识别会把它作为 `UserContext.profileContext` 注入，记忆洞察上下文也已经有 `personalProfileContext`。

但它目前仍更像"一段附加 Markdown"，而不是 HoloAI 每次回答前必须读取、必须尊重的用户长期上下文。具体问题：

1. 档案内容原样注入，缺少结构化语义。模型能看见"昵称：东林"，但系统没有明确的 `preferredName` 字段，也没有统一称呼规则。
2. App UI 昵称和 HoloProfile 昵称是两套存储。`UserDisplayNameSettings.userName` 用于首页等界面，HoloProfile 只用于 AI 上下文，两者不会自动同步。
3. 普通聊天已读取档案，但分析查询使用 `systemContextOverride` 时仍可能绕开 `UserContext`，导致"分析一下我最近状态"这类回答不一定参考档案。
4. HoloProfile 与长期记忆、情景记忆、洞察偏好画像之间的权重关系尚未写清，后续容易出现重复存储或互相覆盖。
5. 档案当前没有"每次回答前必须读取"的显式 prompt 契约，也没有"可以影响什么、不能影响什么"的分层边界。

本方案把 HoloProfile 定义为 HoloAI 的用户主动声明层：类似给 HoloAI 使用的 `MEMORY.md`，但它来自用户本人、可被用户随时编辑、权重高于自动推断记忆。

## 2. 目标

1. 让 HoloAI 每次回答前都能读取用户主动写下的长期上下文。
2. 让个人档案影响称呼、沟通风格、关注重点、分析视角、提醒边界和部分语义消歧。
3. 让用户可控地写入"希望 AI 一直知道的事"，而不是依赖系统自动猜测。
4. 统一 App UI 昵称、HoloAI 称呼和个人档案昵称。
5. 明确 HoloProfile 与长期记忆的优先级，避免自动记忆覆盖用户主动档案。
6. 保持当前输入最高优先级，避免个人档案替用户执行当前没有说出口的动作。

非目标：

- 不在首版让 HoloAI 自动改写整个 HoloProfile。
- 不把 HoloProfile 变成不可读的 JSON 配置文件。
- 不把所有自动洞察都写回档案。
- 不用个人档案覆盖用户当前明确输入、金额、日期、任务、分类和健康事实。

## 3. 核心定位

HoloAI 的长期上下文分为四层：

| 层级 | 来源 | 权重 | 用途 | 示例 |
| --- | --- | --- | --- | --- |
| 当前输入 | 用户本轮消息 | 最高 | 决定这一次要做什么 | "今天咖啡 22" |
| HoloProfile | 用户主动编辑 | 高 | 稳定身份、偏好、称呼、边界 | "请称呼我为东林""我正在戒烟" |
| 长期记忆 | AI 提取、用户确认或规则晋升 | 中 | 稳定模式、阶段变化、偏好证据 | "周日晚适合整理任务" |
| 情景上下文 | 当日数据、近期趋势、洞察快照 | 低到中 | 回答时的实时背景 | 今日支出、任务完成率 |

规则：

1. 当前输入永远优先。档案只能辅助理解，不能覆盖本轮明确指令。
2. 用户主动写入的 HoloProfile 高于自动推断的长期记忆。
3. 长期记忆如果与 HoloProfile 冲突，应降级为待确认，不得静默覆盖。
4. HoloProfile 可用于个性化表达和分析视角，但不能编造事实。
5. 敏感信息只能在相关场景轻量使用，不要主动暴露。

> 🟡 **审查标注 [#9]**：四层优先级模型目前只通过 prompt 文本传达给 LLM，没有形式化保障机制。LLM 天生不擅长严格遵循优先级规则——例如 profile 写了"先讲结论"，而用户问"为什么我上周花这么多"时，LLM 可能因 profile 规则跳过分析过程。建议：(1) 不只依赖 prompt 文本，在注入层面做控制——比如 profile 的"当前关注"在分析查询中只作为可选补充而非强制注入；(2) 手工验收用例应包含优先级冲突场景，测试 AI 在当前输入明确时是否忽略 profile。

## 4. HoloProfile 应该记录什么

HoloProfile 不应该只是"个人简介"，它应记录 HoloAI 每次回答前值得知道的稳定信息。

### 4.1 身份与称呼

适合写入：

- 用户希望被如何称呼。
- 用户所处城市、时区、语言。
- 职业或日常角色。
- 当前人生阶段。

示例：

```markdown
## 基本信息

- 希望称呼：东林
- 常用语言：中文
- 所在城市：北京
- 当前角色：独立开发者，正在推进 Holo 上线
```

AI 使用方式：

- 普通回答中自然称呼"东林"。
- 分析/洞察中使用该身份背景调整表达。
- 不把身份信息当成当前任务指令。

### 4.2 沟通偏好

适合写入：

- 回答风格。
- 是否需要先讲结论。
- 是否喜欢直接指出问题。
- 是否要少用安慰性套话。

示例：

```markdown
## 沟通偏好

- 默认用中文。
- 先讲结论，再讲原因。
- 对产品和代码问题可以直接指出风险。
- 不要为了显得积极而弱化真实问题。
```

AI 使用方式：

- 影响语气、结构和详略。
- 不影响事实判断。

### 4.3 长期目标与关注主题

适合写入：

- 当前长期目标。
- 近期优先级。
- 正在克服的问题。
- 希望 HoloAI 主动关注的生活方向。

示例：

```markdown
## 当前关注

- 正在准备 Holo 上架 App Store。
- 希望减少抽烟。
- 希望控制外卖和咖啡支出。
- 希望更多关注睡眠、运动和长期精力。
```

AI 使用方式：

- 在"我最近怎么样""帮我复盘一下"这类开放问题中优先作为分析镜头。
- 在习惯和目标分析中帮助识别减少型目标，例如戒烟发生量越少越好。
- 不因档案里写了"减少抽烟"，就把"买烟花"误判成抽烟。

### 4.4 决策边界与禁忌

适合写入：

- 不希望 AI 主动提及的主题。
- 提醒频率边界。
- 哪些建议必须保守。

示例：

```markdown
## 边界

- 不要在无关场景主动提敏感健康信息。
- 财务建议只给观察和提醒，不做投资建议。
- 健康建议只做生活方式提醒，不做诊断。
```

AI 使用方式：

- 降低冒犯和误用。
- 约束主动洞察与提醒。

## 5. 信息架构

保留 Markdown 编辑体验，但增加结构化读取层。

> 🟠 **审查标注 [#7]**：当前 8KB 是给 raw Markdown 的限制。如果同时存储 raw Markdown + 结构化 snapshot + 渲染后的 prompt 文本，三份数据总大小会膨胀。Snapshot 持久化在哪里？如果也存 `Application Support/Holo/`，是否需要重新评估存储上限？渲染后的 prompt 文本（含规则文本）大约多长？如果 raw markdown 是 7KB，渲染后 prompt 可能超过 10KB，需要评估 profile 相关内容的总 context 占用，确认不会挤压其他上下文（交易数据、记忆摘要等）的预算。建议：为 profile 相关内容设定一个注入后的 token 上限（如 1500 tokens），超出时按优先级截断。

### 5.1 原始档案

继续使用：

- 文件：`Application Support/Holo/HoloProfile.md`
- 服务：`HoloProfileService`
- 上限：8KB
- 用户可直接编辑 Markdown

### 5.2 结构化摘要

新增本地解析结果 `HoloProfileSnapshot`：

```swift
struct HoloProfileSnapshot: Codable, Equatable {
    let rawMarkdown: String
    let preferredName: String?
    let language: String?
    let communicationStyle: [String]
    let currentFocus: [String]
    let lifeContext: [String]
    let healthHabitContext: [String]
    let sensitiveBoundaries: [String]
    let updatedAt: Date
}
```

> 🟠 **审查标注 [#5]**：Snapshot 缺少以下字段：(1) `timezone`/`city`——方案第 4.1 节说"用户所处城市、时区"适合写入，但 snapshot 没有对应字段；(2) `profession`/`role`——示例写了"独立开发者"，但 snapshot 没有字段；(3) `contentHash: String`——用于缓存失效判断，避免每次回答前都重新解析 Markdown；(4) `parseConfidence: [String: Bool]`——标记每个字段是成功解析的还是 fallback 来的，便于后续诊断和测试。建议补充上述字段。

> 🟡 **审查标注 [#13]**：方案没有设计 Snapshot 的缓存策略和生命周期。如果每次 `UserContextBuilder.buildContext()` 都重新解析 Markdown，每次聊天都要跑解析逻辑。如果缓存，文件变更后如何失效？`HoloProfileService` 已有 `Notification.Name.profileDidChange` 通知，建议 snapshot 缓存监听此通知做失效，并在 `HoloProfileService` 中暴露一个 `@Published var currentSnapshot: HoloProfileSnapshot?` 属性，由 Service 统一管理生命周期。

首版不需要 LLM 解析，采用本地 Markdown 约定解析：

- `希望称呼`、`昵称`、`称呼我为` 解析为 `preferredName`
- `回复语言`、`常用语言` 解析为 `language`
- `沟通偏好` section 解析为 `communicationStyle`
- `当前关注`、`关注领域` section 解析为 `currentFocus`
- `健康与习惯目标` section 解析为 `healthHabitContext`
- `边界`、`禁忌话题` section 解析为 `sensitiveBoundaries`

如果解析失败，保留 raw Markdown 注入，不中断 AI。

> 🔴 **审查标注 [#2]**：本地 Markdown 约定解析的覆盖度远低于方案预期。实际用户写法会包括"叫我东林就好"、"我是东林"、"东林（昵称）"、"名字：东林"、"Call me Donglin"等，远不是三个关键词能覆盖的。`communicationStyle` 从一个 section 里提取 `[String]`，用户不可能严格遵循 Markdown section 格式。现有 `MarkdownParser` 是为渲染设计的（AST 产出 `BoldNode`/`TextNode` 等），**没有语义 section 提取能力**，需要一套全新的 section 识别逻辑。更深层问题：解析失败的 fallback 是"保留 raw Markdown 注入"，意味着两套注入路径并存——结构化的用 snapshot renderer，失败时回退到 raw markdown——这两套路径的 prompt 格式不同，AI 的理解一致性和测试覆盖会很难保证。**建议**：首版放弃"完全准确的本地解析"，只解析最关键的 `preferredName`（覆盖 5-8 种常见写法），其余全部保留为 raw text 注入；或者首版直接用 LLM 做一次离线解析（保存结果缓存），不做实时本地解析。

### 5.3 AI 注入文本

新增 `HoloProfilePromptRenderer`，把结构化摘要渲染为稳定 prompt：

```text
--- 用户主动档案（每次回答前必须参考） ---
- 称呼：东林
- 语言：中文
- 沟通偏好：先讲结论；直接指出风险
- 当前关注：Holo 上架；减少抽烟；控制外卖和咖啡支出
- 边界：不要在无关场景主动提敏感健康信息

使用规则：
- 这些信息来自用户主动编辑，权重高于自动推断记忆。
- 只能用于称呼、个性化、消歧、分析视角和提醒边界。
- 不得覆盖用户本轮明确输入。
- 不得编造金额、日期、健康事实、任务或分类。
```

随后可追加原始 Markdown 的精简版，便于模型读取未解析信息。

## 6. 关键链路改造

### Phase 1：统一读取与注入

目标：让 HoloProfile 真正成为 HoloAI 每次回答前读取的长期上下文。

改动：

1. `HoloProfileService` 新增 `loadSnapshot()` 或独立 `HoloProfileSnapshotBuilder`。
2. `UserContext` 增加 `profileSnapshot` 或保留 `profileContext` 并由 Renderer 生成更稳定文本。
3. `AIUserContextMessageBuilder` 不再直接拼 raw Markdown，改为拼 `HoloProfilePromptRenderer.render(snapshot)`。
4. `OpenAICompatibleProvider` 和 `HoloBackendAIProvider` 的分析模式分支在 `systemContextOverride` 后追加 profile prompt。
5. `ChatViewModel` 分析查询路径不再传 `UserContext.empty`，改传本轮已经构建的 `userContext`。
6. `MemoryInsightContextBuilder` 继续保留 `personalProfileContext`，后续可升级为结构化 snapshot。

> 🔴 **审查标注 [#1]**：改动第 4-5 点不可行。分析路径用 `systemContextOverride` 完全替代了 `UserContext` 注入——Provider 内部是 `if let contextOverride = systemContextOverride { ... } else { AIUserContextMessageBuilder.build(...) }` 的**互斥分支**，两者不是"追加"关系。要让分析查询同时包含分析上下文和 profile，需要在 `ChatViewModel` 层面把 profile 渲染文本拼接到 `contextJSON` 里（策略 A），或者修改 Provider 的分支逻辑让两者不再互斥（策略 B）。**建议明确选择策略 A**：在 `ChatViewModel` 的分析路径中，将 `HoloProfilePromptRenderer.render(snapshot)` 拼接到 `systemContextOverride` 的 JSON 末尾，Provider 逻辑不变。

> 🟠 **审查标注 [#4]**：方案列出了 4 条 prompt 注入路径，但实际代码中存在 **6+ 条**完全不同的执行路径：(1) 普通聊天 `AIUserContextMessageBuilder(.chat)`——已注入 profile；(2) 意图识别 `AIUserContextMessageBuilder(.intentRecognition)`——已注入 profile；(3) 分析查询 `systemContextOverride` 路径——**不注入** profile；(4) 记忆洞察生成 `MemoryInsightContextBuilder`——已注入 profile；(5) **`HoloMemoryObserverService`** 短期情景记忆观察——走独立 JSON context 路径，不经过 `UserContext`，**完全被方案遗漏**；(6) **`FlexibleQueryExecutor`** 灵活查询——走独立 context 构建路径。方案应在改动列表中**逐一标注每条路径的当前状态和改造方案**，特别是第 5、6 条路径是否需要注入 profile。

验收：

- 普通聊天："你之后怎么称呼我？"应答"东林"。
- 意图识别："今天抽了 3 根"能结合档案识别减少型习惯，但不覆盖本轮数据。
- 分析查询："分析一下我最近状态"能参考当前关注主题。
- 记忆洞察生成能读取档案中的关注方向和边界。

### Phase 2：昵称与 App UI 同步

目标：App UI 称呼和 HoloAI 称呼一致。

改动：

1. HoloProfile 解析出 `preferredName` 后，与 `UserDisplayNameSettings.displayName` 对齐。
2. 如果两者冲突，不静默覆盖，显示轻量确认：
   - "个人档案中写的是东林，App 当前称呼是你，要同步吗？"
3. 首次昵称 onboarding 保存时，可自动写入 HoloProfile 的"希望称呼"字段，或提示用户补全档案。
4. 个人页展示"AI 会如何称呼你"的预览。

> 🔴 **审查标注 [#3]**：双向同步存在交互死循环。场景：(1) 用户在 HoloProfile 写"希望称呼：东林"；(2) App 弹确认同步 → 用户点"同步" → App 昵称变"东林"；(3) 用户后来在 App 设置改名"小东"；(4) 系统又检测到冲突 → 再弹确认？(5) 用户说"不要同步" → 下次启动还弹吗？记住选择后，用户改了主意怎么办？方案没有回答：确认弹窗的触发时机是什么？（每次打开 App？每次保存档案？每次打开设置页？）"记住选择"如何实现？存哪里？两边都能改的情况下谁是 source of truth？如果用户明确拒绝同步，之后在另一边改了名字要重新提示吗？**建议**：明确 `HoloProfile.preferredName` 为昵称的**唯一 source of truth**，App UI 的昵称改为从 profile 只读展示；或者反过来，以 App UI `UserDisplayNameSettings` 为准，profile 里不设昵称字段，只注入 App 设置的昵称。不要两边都能改。

验收：

- 用户在个人档案写"希望称呼：东林"，HoloAI 和首页称呼最终一致。
- 用户修改 App 昵称时，个人档案不会被无提示覆盖。

### Phase 3：和长期记忆建立优先级

目标：让 HoloProfile 成为自动记忆的上位约束。

改动：

1. `HoloLongTermMemoryCandidateObserver` 在候选生成/晋升时读取 profile snapshot。
2. 候选与 HoloProfile 重复：不新建长期记忆，只记录为 profile-backed evidence。
3. 候选与 HoloProfile 冲突：标记 `requiresConfirmation`，不能静默保存。
4. `HoloMemorySummaryProvider` 召回时把 profile-backed 记忆降噪，避免每次重复说同一件事。
5. 记忆管理页展示来源：
   - 用户档案
   - 用户确认记忆
   - Holo 观察到的模式

> 🟠 **审查标注 [#8]**：Phase 3 的冲突检测缺乏具体实现方案。(1) "冲突"的定义是什么？语义冲突？关键词重叠？方案没有描述。(2) `HoloLongTermMemoryCandidateObserver` 当前是通知响应器，在后台 `OperationQueue` 上运行，完全不访问 `HoloProfileService`。要在候选提取时读取 profile，需要解决线程安全问题——`HoloProfileService` 是 `@MainActor` 的，后台队列不能直接调用。(3) `HoloProfileSnapshot` 和 `HoloLongTermMemory` 的字段完全不对齐——一个是 Markdown section 级别的，一个是 semantic type 级别的，怎么做结构化比较？(4) 当前的 `HoloMemoryPromotionPolicy` 已有 `.profileBackedFact` 类型处理（路由到 `.requireConfirmation`），但这是从记忆侧标记"我来自 profile"。方案要做的是**反向检测**——从 profile 侧检测"这条新记忆和我的内容冲突"，需要全新比对逻辑。**建议**：Phase 3 先只做最简单的"关键词去重"（profile 和 candidate 的文本 overlap 检测），不做语义冲突检测；线程安全问题通过在 Observer 中使用 `HoloProfileSnapshot` 的**缓存副本**（在 `MainActor` 上预先加载并传递）来解决。

验收：

- 档案写"我正在戒烟"，系统不再额外生成一条重复的"用户关注戒烟"长期记忆。
- 如果自动洞察推断"用户已经不关注戒烟"，必须要求确认，不能覆盖档案。

### Phase 4：AI 辅助维护档案

目标：让用户能自然语言维护档案，但仍由用户确认。

改动：

1. 新增 `update_profile_suggestion` 意图，不直接写文件。
2. HoloAI 可生成档案修改建议：
   - 新增希望称呼
   - 更新当前关注
   - 增加沟通偏好
   - 增加边界
3. 弹出 `HoloProfileSuggestionSheet`，展示 diff。
4. 用户确认后由本地 patch 写入 Markdown。

> 🟡 **审查标注 [#11]**：当前 `IntentRouter` 已有 15+ 种意图，新增 `update_profile_suggestion` 会进一步膨胀意图识别空间，可能降低整体意图识别准确率。更关键的是：用户说"以后叫我东林"可能被识别为 `update_profile_suggestion` 而不是普通对话——这需要高置信度区分；用户说"我最近在戒烟"应该记录为习惯打卡还是写入 profile？**建议**：Phase 4 不要作为新意图实现，改为在**普通聊天响应后**由本地规则判断是否触发"是否写入档案？"的提示。这样不增加意图识别的复杂度，也不影响现有意图的识别准确率。

验收：

- 用户说"以后叫我东林"，HoloAI 提示"是否写入个人档案？"
- 用户说"以后回答我先讲结论"，HoloAI 提示写入沟通偏好。
- 未确认前不修改档案。

## 7. Prompt 规则

所有 HoloAI 场景统一加入以下语义规则：

```text
用户主动档案是用户自己编辑的长期上下文。你必须在每次回答前参考它，尤其是称呼、语言、沟通偏好、长期目标、提醒边界和语义消歧。

优先级：
1. 用户本轮明确输入最高。
2. 用户主动档案高于自动推断记忆。
3. 自动推断记忆只作为辅助证据。
4. 实时数据高于过期趋势。

禁止：
- 不得用档案覆盖本轮明确输入。
- 不得基于档案编造金额、日期、任务、分类、健康数据或用户当前意图。
- 不得在无关场景主动暴露敏感档案内容。
- 遇到档案、记忆和当前输入冲突时，先按当前输入处理，并在必要时向用户确认。
```

如果后端托管 prompt 也维护同类规则，iOS 本地默认 prompt 与 HoloBackend `defaultPrompts.json` 必须同步更新。涉及后端 prompt 或路由改动时，需要部署后端后才会在生产生效。

> 🟠 **审查标注 [#6]**：方案没有区分这些 prompt 规则的归属层。根据 CLAUDE.md 的 Prompt 双端同步规则，iOS 端 `PromptManager.swift` 的模板只是后备，实际运行时以后端为准。但 `AIUserContextMessageBuilder` 动态拼接的文本（包括 profile prompt）是 iOS 端直接拼的，**不走后端 prompt 管理**，所以不需要后端部署。然而如果规则文本也需要嵌入到后端的 `system_prompt` 或 `analysis_prompt` 模板里，就需要同时改 `defaultPrompts.json` 并重新部署后端。**建议**：在方案中明确标注每条 prompt 规则的归属层——(1) iOS 端 `AIUserContextMessageBuilder` 动态拼接的（不需要后端部署）；(2) 需要嵌入后端 prompt 模板的（需要双端同步 + 部署）。

> 🟠 **审查标注 [#4 补充]**：本节说"所有 HoloAI 场景统一加入以下语义规则"，但实际没有列举所有场景。完整的 prompt 注入路径至少包括：(1) 普通聊天（通过 `AIUserContextMessageBuilder`）；(2) 意图识别（通过 `AIUserContextMessageBuilder`）；(3) 分析查询（通过 `systemContextOverride`，独立路径）；(4) 记忆洞察生成（通过 `MemoryInsightContextBuilder`，独立 JSON context）；(5) 短期情景记忆观察（通过 `HoloMemoryObserverService`，独立 JSON context）；(6) 灵活查询（通过 `FlexibleQueryExecutor`，独立 context 构建路径）。建议逐一标注每条路径如何注入本节规则。

## 8. UI 规划

个人档案不应停留在一个大 TextEditor。建议拆为"结构化编辑 + Markdown 高级编辑"。

> 🟡 **审查标注 [#12]**：结构化编辑器的 UX 风险被低估。(1) 当前用户已经写的自由格式 Markdown 怎么迁移？没有迁移策略；(2) 结构化编辑器能覆盖 Markdown 的所有表达吗？用户想写"我在 2024 年开始独立开发，之前在大厂做了 5 年"这种叙事性内容，结构化字段放不下；(3) 两套编辑方式并存（结构化 + Markdown），用户可能不清楚在哪里改什么。**建议**：首版保持 Markdown 编辑器不变，只在编辑器上方或下方加一个"AI 使用预览"卡片，展示 AI 将如何理解当前档案内容。等用户反馈后再考虑结构化编辑。

### 8.1 个人档案首页

展示：

- AI 称呼我为：东林
- 回答语言：中文
- 回答风格：先结论、直接指出风险
- 当前关注：Holo 上架、减少抽烟、控制外卖和咖啡
- 边界：健康不诊断、财务不投资建议

操作：

- 编辑基本信息
- 编辑沟通偏好
- 编辑关注主题
- 编辑边界
- 高级 Markdown

### 8.2 AI 使用预览

在保存前展示：

```text
HoloAI 将在每次回答前知道：
- 你希望被称呼为东林
- 你偏好中文、先结论、直接指出风险
- 当前重点是 Holo 上架和减少抽烟
```

这能让用户理解"档案会怎么影响 AI"，避免黑箱。

## 9. 风险与边界

| 风险 | 处理 |
| --- | --- |
| 档案变成 prompt injection | 只把档案视为用户偏好，不允许覆盖系统安全规则和当前输入 |
| 个人档案过长污染上下文 | 8KB 上限保留，Renderer 生成短摘要，raw Markdown 可截断 |
| AI 过度称呼用户 | prompt 写"自然使用称呼，不必每句话都叫名字" |
| 敏感信息被主动提起 | sensitiveBoundaries 和健康/财务信息默认只在相关场景使用 |
| 与长期记忆重复 | 自动候选检测 profile-backed 内容，不重复晋升 |
| 与长期记忆冲突 | 冲突候选进入待确认，不自动覆盖 |
| UI 昵称与档案昵称冲突 | 弹确认，不静默覆盖 |
| 分析查询绕开档案 | 分析模式追加 profile prompt，并传实际 userContext |

> 🟡 **审查标注 [#10]**：风险表缺少"用户清空/重置档案"的边界情况。如果用户把 HoloProfile.md 内容全部删除：`preferredName` 变成 `nil` → AI 不再称呼用户名字，回退到什么？"你"？App UI 的昵称要不要同步清空？已有的长期记忆中引用了 profile 信息的记忆怎么处理？正在等待确认的 profile-backed 记忆候选怎么处理？建议在风险表中增加此条目，并明确清空档案后的降级行为。

## 10. 验证计划

### 10.1 单元测试

1. `HoloProfileSnapshotBuilder` 能解析"昵称/希望称呼/称呼我为"。
2. 解析失败时保留 raw Markdown。
3. `HoloProfilePromptRenderer` 输出包含优先级和禁止规则。
4. 超过长度时 Renderer 截断 raw Markdown，但保留结构化摘要。

### 10.2 集成测试

1. `UserContextBuilder.buildContext()` 有 profile 时能生成结构化 profile prompt。
2. `AIUserContextMessageBuilder` 普通聊天包含用户主动档案。
3. 意图识别上下文包含档案规则，但不注入长期记忆摘要。
4. 分析查询 streaming 路径传实际 userContext，不再使用 `UserContext.empty`。
5. `OpenAICompatibleProvider` 分析模式追加 profile prompt。
6. `HoloBackendAIProvider` 分析模式追加 profile prompt。

### 10.3 手工验收用例

| 用例 | 预期 |
| --- | --- |
| 档案写"希望称呼：东林"，问"你以后怎么称呼我？" | 回答东林 |
| 档案写"先讲结论"，问开放问题 | 先给结论 |
| 档案写"我正在戒烟"，输入"今天抽了 3 根" | 理解为减少型习惯记录 |
| 档案写"我正在戒烟"，输入"买烟花 200" | 不误判为抽烟 |
| 档案写"控制外卖和咖啡"，问"最近消费怎么样" | 优先关注外卖/咖啡，但仍基于真实数据 |
| 档案写敏感健康边界，问无关任务 | 不主动暴露健康信息 |
| 长期记忆与档案冲突 | 进入确认，不自动覆盖 |

> 🟡 **审查标注 [#9 补充]**：手工验收用例缺少"优先级冲突场景"。建议增加以下用例：(1) 档案写"先讲结论"，但用户明确问"帮我分析一下为什么..."——AI 应按用户要求完整分析，而不是被 profile 的"先讲结论"截断；(2) 档案写"减少抽烟"，但用户输入"今天抽了 5 根，没事"——AI 应记录 5 根的事实，而不是被 profile 价值判断影响；(3) 档案写"关注睡眠"，但用户问"最近外卖花了多少"——AI 应按用户问题聚焦外卖，不要强行引入睡眠话题。

## 11. 推荐实施顺序

1. Phase 1：结构化读取 + 全链路注入补齐。
2. Phase 2：称呼与 App UI 同步。
3. Phase 3：长期记忆与 HoloProfile 优先级联动。
4. Phase 4：AI 辅助维护档案。

首个可交付版本建议只做 Phase 1 + Phase 2 的最小闭环：

- 用户在档案写"希望称呼：东林"。
- HoloAI 普通聊天、意图识别、分析查询和洞察生成都能读到。
- App UI 与 HoloAI 称呼最终一致。
- prompt 明确"档案必须参考，但不能覆盖当前输入"。

这个版本足以让个人档案从“附加文本”升级成“HoloAI 每次回答前读取的用户主动长期上下文”。

## 12. Codex 第二轮审查（2026-06-07）

> 审查目标：在 GLM 审查后做第二轮 code-vs-doc 对抗审查，判断本方案是否可以进入实施规划。
> 审查结论：Conditional Go。GLM 第一轮 14 个标注中，大部分成立；其中 #1 的“只能选策略 A”需要修正为“策略 A/B 均可，但不能把 Profile 混入持久化的 `AnalysisContext` JSON”。实施前必须补齐下方 P0/P1 约束，否则容易把“用户长期上下文”做成不稳定 prompt 拼接，或者让分析/记忆链路继续漏读 Profile。

### 12.0 对 GLM 第一轮标注的裁决

| GLM 标注 | Codex 第二轮裁决 | 处理 |
| --- | --- | --- |
| #1 分析路径互斥 | 问题成立；但不必限定策略 A | 可选 A：ChatViewModel 拼接非持久化 profile prompt；可选 B：Provider override 分支追加第三条 system message。无论哪种，都不得把 profile 写入 `analysisContextJSON` |
| #2 Markdown 解析覆盖不足 | 成立 | 首版收窄为关键字段解析，优先 `preferredName`，其余保留 raw text + 统一 renderer |
| #3 昵称同步死循环 | 成立 | 必须指定单一 source of truth；第二轮建议以 HoloProfile `preferredName` 为 AI 称呼源，App 昵称只确认式同步 |
| #4 注入路径未穷举 | 成立 | Phase 0 必须建立入口覆盖矩阵 |
| #5 Snapshot 字段不足 | 成立 | 增补 `timezone/city/profession/role/contentHash/parseConfidence` |
| #6 prompt 归属层不清 | 成立 | 区分 iOS 动态上下文与后端托管 prompt；后端模板改动才需要部署 |
| #7 context 占用未评估 | 成立 | Renderer 必须有 profile 注入 token 上限 |
| #8 冲突检测缺方案 | 成立 | Phase 3 先做本地关键词/字段级去重和冲突标记，语义冲突延后 |
| #9 优先级只靠 prompt | 成立 | 增加冲突验收用例与注入层控制 |
| #10 清空档案边界 | 成立 | 增加降级行为：AI 称呼回退、snapshot 清空、profile-backed 候选重新评估 |
| #11 新意图膨胀 | 成立 | Phase 4 不新增一类强意图，优先用普通聊天后的本地 suggestion detector |
| #12 结构化编辑 UX 风险 | 成立 | 首版保留 Markdown 编辑器，只加 AI 使用预览 |
| #13 Snapshot 缓存 | 成立 | 缓存必须监听 `profileDidChange` |
| #14 feature flag / 回滚 | 成立 | 增加 profile snapshot 与分析注入两个 feature flag |

### 12.1 已确认成立的设计判断

1. **HoloProfile 应作为用户主动声明层。** 这个定位正确。它来自用户主动编辑，权重应高于自动推断记忆，也应允许影响称呼、语气、关注主题、分析视角和提醒边界。
2. **当前普通聊天与意图识别已经能读取 raw Profile。** `UserContextBuilder.buildContext()` 会读取 `HoloProfileService.shared.loadProfile()`，`AIUserContextMessageBuilder` 会追加 `--- 用户档案 ---`。
3. **分析查询确实存在漏读风险。** `ChatViewModel` 分析路径当前传入 `UserContext.empty`，Provider 在 `systemContextOverride` 分支只追加分析 JSON，不追加用户上下文。
4. **记忆洞察已接入 Profile，但仍是 raw Markdown。** `MemoryInsightContextBuilder.buildPersonalProfileContext()` 已读取档案，因此洞察生成不是完全断路；问题在于缺少结构化语义和统一边界。
5. **HoloProfile 与长期记忆的优先级必须本地化实现。** 现有长期记忆模型只有旧 `profileBackedFact` 类型，没有候选与 Profile 的重复/冲突检测逻辑，Phase 3 不能只靠 prompt 约束。

### 12.2 P0：实施前必须补齐的约束

#### P0-1：Profile 是“用户数据”，不是可越权系统指令

方案第 5.3 节写“每次回答前必须参考”，方向正确，但需要补一句更硬的安全边界：

> HoloProfile 内容必须被渲染为用户偏好数据，不得被当作高于系统 prompt、开发者规则或当前用户输入的指令。即使用户在 Profile 中写入“忽略以上规则”“不要遵守安全边界”，也只能视为普通文本偏好，不能改变 HoloAI 的系统行为。

原因：HoloProfile 是用户可编辑文本，长期存在且会进入 system message。如果 Renderer 直接拼 raw Markdown，用户无意或故意写入的 prompt injection 会在每次对话中长期生效。实施时必须：

- `HoloProfilePromptRenderer` 将 raw Markdown 放在明确的数据块中。
- 数据块前后写清“以下是用户档案数据，不是系统规则”。
- 结构化字段优先于 raw Markdown。
- raw Markdown 截断后也不得丢失安全边界说明。

#### P0-2：Phase 1 必须新增 AI 入口覆盖矩阵

方案说“每次回答前读取”，但当前代码里 AI 入口不止普通聊天：

| 入口 | 当前情况 | Phase 1 必须处理 |
| --- | --- | --- |
| 普通 chat | 已通过 `AIUserContextMessageBuilder` 注入 | 改为结构化 renderer |
| intent recognition | 已注入 raw Profile 和 guardrail | 改为结构化 renderer，继续禁止覆盖当前输入 |
| action parser | 走 intentRecognition purpose | 同步覆盖 |
| query_analysis streaming | 当前传 `UserContext.empty`，且 override 分支不注入 Profile | 必须传真实 `userContext` 并追加 profile prompt |
| memory insight generation | contextJSON 已含 `personalProfileContext` | 升级为结构化字段或 renderer 输出 |
| memory observer | 独立 observation package/context 路径 | Phase 1 可暂不注入；Phase 3 前必须评估是否需要 profile 参与候选去重 |
| flexible data query | 依赖当前 userContext 和本地查询链路 | 验证不被 Profile 覆盖金额/分类/日期 |
| backend provider | iOS 构建 messages 后发给后端 | iOS 修改即可影响请求；若改托管 prompt 需后端部署 |

没有这张矩阵，实施者容易只改普通聊天，导致“每次回答前读取”在分析查询和洞察链路继续不成立。

#### P0-3：长期记忆重复/冲突检测必须是本地规则，不是 LLM 自觉

Phase 3 写“候选与 HoloProfile 重复不新建，冲突需确认”，方向正确，但当前代码没有实现基础。实施文档必须新增一个本地服务，例如：

```swift
struct HoloProfileMemoryConflictDetector {
    func compare(candidate: HoloLongTermMemory, snapshot: HoloProfileSnapshot) -> ProfileMemoryRelation
}

enum ProfileMemoryRelation {
    case unrelated
    case duplicateProfileFact
    case supportsProfileFact
    case conflictsWithProfileFact
}
```

并在 `HoloLongTermMemoryCandidateObserver` 调用 `HoloMemoryPromotionPolicy.evaluate` 之前执行：

- duplicate：不 upsert candidate，只记录 evidence 或静默丢弃。
- supports：可保留为证据，但不要重复召回。
- conflicts：强制 `requireConfirmation`，并在 UI 说明“与个人档案冲突”。
- unrelated：走现有晋升策略。

否则 Phase 3 只是策略描述，无法阻止长期记忆与 Profile 互相污染。

### 12.3 P1：需要修订但不阻断方向

#### P1-1：结构化解析不能只依赖标题约定

方案第 5.2 节采用本地 Markdown 约定解析是对的，但只解析 `希望称呼`、`昵称`、section 标题还不够。真实用户会写：

- “以后叫我东林”
- “你之后称呼我东林就行”
- “我不喜欢太长的回答”
- “少提醒我健康，除非我主动问”

建议首版采用“模板字段优先 + 轻量正则补充”的组合：

1. 模板字段最高优先级。
2. 支持少量自然语言模式解析称呼和沟通偏好。
3. 解析结果在 UI 预览中展示，用户可确认。
4. 解析不确定时不写入结构化字段，只保留 raw Markdown。

#### P1-2：Snapshot 缓存必须监听 `profileDidChange`

`HoloProfileService` 当前有缓存和 `.profileDidChange` 通知。若新增 `HoloProfileSnapshotBuilder` 或 `loadSnapshot()` 缓存，必须明确：

- 保存 Profile 后清空 snapshot cache。
- `UserDisplayNameSettings` 同步后也触发相应刷新。
- 测试覆盖“保存后下一次 AI 调用立即使用新称呼”。

否则用户编辑档案后，HoloAI 可能在一段时间内继续使用旧 snapshot。

#### P1-3：称呼同步要避免循环写入

Phase 2 同步 App UI 昵称和 Profile 昵称是必要的，但必须指定唯一写入入口：

- 用户在 App 昵称页改名：更新 `UserDisplayNameSettings`，提示是否同步 Profile。
- 用户在 Profile 改“希望称呼”：更新 Profile，提示是否同步 App 昵称。
- 自动解析不得在无确认时反向改写另一个存储。

否则容易出现保存 Profile -> 同步 AppStorage -> 监听变化 -> 再写 Profile 的循环或覆盖。

#### P1-4：分析查询注入 Profile 时要避免污染结构化数据 JSON

分析模式当前把 `AnalysisContext` JSON 作为独立 system message 注入。Phase 1 不建议把 Profile 混入 `AnalysisContext` 主结构，否则会影响卡片持久化、hash、缓存和展示解析。

可选实现：

1. 策略 A：在 `ChatViewModel` 分析路径中，把 `HoloProfilePromptRenderer.render(snapshot, purpose: .analysis)` 作为非持久化 prompt 文本拼接到 `systemContextOverride` 请求文本末尾，但 `analysisContextJSON` 仍只保存纯 `AnalysisContext`。
2. 策略 B：修改 `OpenAICompatibleProvider` 与 `HoloBackendAIProvider` 的 `systemContextOverride` 分支，让它们在 context override 后追加第三条 system message。这个方案代码边界更清楚，但必须同时改两个 provider 并补测试。

第二轮建议采用策略 B。理由是 profile prompt 仍属于“用户长期上下文”，不应伪装成分析 JSON 的一部分；但如果实现成本优先，策略 A 可作为 MVP。

这样既能让 LLM 分析参考 Profile，又不会让用户档案改变卡片数据模型和 snapshot hash。

#### P1-5：必须增加 feature flag 和回滚计划

GLM #14 成立。当前代码已有 `HoloAIFeatureFlags` 管理语义记忆、记忆摘要注入等开关。HoloProfile 升级也必须有回滚手段：

- `profileSnapshotEnabled`：控制是否使用结构化 snapshot + renderer；关闭时回退到现有 raw Markdown 注入。
- `profileAnalysisInjectionEnabled`：控制分析查询路径是否注入 profile；关闭时保持现有分析行为。
- `profileMemoryConflictDetectionEnabled`：Phase 3 使用，控制候选与 Profile 的重复/冲突检测。

这些开关应进入验收标准：关闭后行为必须能回退到当前线上逻辑。

### 12.4 推荐修订后的执行顺序

原方案的 Phase 1-4 保留，但实施前应增加 Phase 0：

#### Phase 0：边界和入口矩阵定稿

1. 定义 `HoloProfileSnapshot` 字段。
2. 定义 `HoloProfilePromptRenderer` 的安全渲染格式。
3. 写清 AI 入口覆盖矩阵。
4. 写清 Profile vs 当前输入 vs 长期记忆的优先级。
5. 写清分析查询不把 Profile 混入 `AnalysisContext`。
6. 定义 feature flag 与关闭后的回退行为。

#### Phase 1：结构化读取和全链路注入

1. 实现 snapshot builder。
2. 普通 chat / intent / action parser 使用 renderer。
3. 分析 streaming 传真实 `userContext` 并追加 profile prompt。
4. memory insight context 升级为结构化摘要或 renderer 输出。
5. 加测试证明 profile 不覆盖本轮明确输入。

#### Phase 2：称呼同步

只做 `preferredName` 与 `UserDisplayNameSettings` 的确认式同步，不做自动双向覆盖。

#### Phase 3：长期记忆冲突检测

先实现 `HoloProfileMemoryConflictDetector`，再接入 Observer / PromotionPolicy / Memory Center UI。

#### Phase 4：AI 辅助维护档案

新增 `update_profile_suggestion`，但所有写入必须经过用户确认。

### 12.5 最终结论

Conditional Go。

本方案的产品方向成立：HoloProfile 应升级为 HoloAI 每次回答前读取的用户主动长期上下文，并且应高于自动推断记忆。但工程实施不能只做 raw Markdown prompt 拼接。进入实施前必须补齐：

1. Profile-as-data 的 prompt injection 边界。
2. AI 入口覆盖矩阵。
3. 分析查询 profile 注入但不污染 `AnalysisContext` 的实现约束。
4. Profile 与长期记忆重复/冲突的本地检测机制。
5. Snapshot 缓存刷新和昵称同步防循环规则。
6. Feature flag 与回滚路径。

这些修订完成后，可以进入 Phase 0 / Phase 1 实施计划。

---

## 13. Claude 第三轮审查（2026-06-07）

> 审查目标：对 GPT 第二轮裁决做 code-vs-doc 验证，纠正事实错误，补充两轮均遗漏的问题，给出最终 consolidated 结论。

### 13.0 对 GPT 第二轮裁决的再评估

| GPT 裁决 | Claude 第三轮评估 | 说明 |
| --- | --- | --- |
| #1 策略 A/B 均可，倾向 B | ✅ 同意倾向 B，但需补充 system message 排序风险（见 13.3 #G3） |
| #2 首版收窄为关键字段 | ✅ 同意 |
| #3 preferredName 为 AI 称呼源 | ✅ 同意，但 iCloud 缺失放大了问题（见 13.3 #G1） |
| #4 建立入口覆盖矩阵 | ⚠️ 矩阵本身正确，但 GPT 表格中 FlexibleQuery 描述有误（见 13.1） |
| #5-#14 | ✅ 全部同意，无需修正 |
| P0-1 Profile-as-data 安全边界 | ⚠️ 方向正确但定级过高——这是**已有风险**而非新风险（见 13.2 #P1） |
| P0-2 入口矩阵 | ⚠️ FlexibleQuery 行描述有事实错误（见 13.1） |
| P0-3 冲突检测本地服务 | ✅ 接口设计合理，但线程安全问题仍未解决（见 13.2 #P2） |
| P1-4 策略 B 优先 | ✅ 同意 |
| Phase 4 仍新增意图 | ❌ 与自身 #11 裁决矛盾（见 13.2 #P3） |

### 13.1 🔴 GPT 入口覆盖矩阵的事实错误

GPT 第 12.2 节 P0-2 的入口矩阵中，FlexibleQuery 行写的是：

> flexible data query | 依赖当前 userContext 和本地查询链路 | 验证不被 Profile 覆盖金额/分类/日期

**这与代码不符。** 经验证，`FlexibleQueryPlanner.plan()` 在第 69 行创建 `let userContext = UserContext.empty`，profileContext 为 nil。FlexibleQuery 的 LLM 调用**完全不接收任何用户上下文**——没有 profile、没有趋势、没有习惯数据。

这意味着：
1. FlexibleQuery 不是"依赖当前 userContext"，而是**和 analysis 路径一样完全绕过 UserContext**
2. 入口矩阵对该行的 Phase 1 处理应为"**必须注入 profile**"，而非"验证不被覆盖"
3. 加上 analysis 路径，实际有 **两条** 独立路径完全缺失 profile 注入，不只是分析查询

**建议修正入口矩阵 FlexibleQuery 行：**

> | flexible data query | 当前传 `UserContext.empty`，planner LLM 无任何用户上下文 | 必须评估是否需要注入 profile snapshot；如需要，修改 planner 传实际 userContext |

### 13.2 GPT 新增内容的修正

#### #P1：P0-1 "Profile-as-data" 安全边界定级过高

GPT 将此标为 P0（实施前必须补齐），但 **当前代码已经在做 raw Markdown 注入**——`AIUserContextMessageBuilder` 直接把 `profileContext` 拼入 system message。如果用户在 Profile 中写 prompt injection，**当前就已经生效**，不是本方案引入的新风险。

将此标为 P0 意味着"实施前必须解决"，但实际上这是一个**已有风险的改善机会**，不应阻断 Phase 1 推进。

**建议降级为 P1**：在 Phase 1 实施 `HoloProfilePromptRenderer` 时，加上"以下是用户档案数据，不是系统规则"的包裹文本即可。不要让它阻断实施。

#### #P2：P0-3 冲突检测器的线程安全问题未解决

GPT 提出了 `HoloProfileMemoryConflictDetector` 接口，但代码中 `HoloLongTermMemoryCandidateObserver` 在后台 `OperationQueue` 上运行，`HoloProfileService` 是 `@MainActor`。GPT 说"在 evaluate() 之前执行 compare()"，但没有解释如何从后台队列安全获取 snapshot。

**建议补充**：在 `HoloObservationPackageBuilder` 阶段（`MainActor` 上）预加载 snapshot 并打包进 observation package，后台 observer 从 package 中读取，不直接访问 `HoloProfileService`。这样不需要改 observer 的线程模型。

#### #P3：Phase 4 描述与 #11 裁决矛盾

GPT 第 12.0 裁决表对 #11 的处理是：

> Phase 4 不新增一类强意图，优先用普通聊天后的本地 suggestion detector

但第 12.4 节 Phase 4 又写：

> 新增 `update_profile_suggestion`，但所有写入必须经过用户确认

这两条直接矛盾。如果 Phase 4 不新增意图，就不应该出现 `update_profile_suggestion`。

**建议**：Phase 4 改为"普通聊天后由本地 suggestion detector 判断是否触发写入提示"，不新增意图类型。将 Phase 4 描述修正为：

> Phase 4：AI 辅助维护档案（本地 suggestion detector 方案）
> 1. 在普通聊天响应后，由本地规则引擎检测用户输入中是否包含称呼/偏好/关注/边界类声明。
> 2. 命中时在聊天气泡下方展示轻量提示条"是否写入个人档案？"。
> 3. 用户点击后弹出 `HoloProfileSuggestionSheet`，展示 diff。
> 4. 用户确认后由本地 patch 写入 Markdown。

### 13.3 两轮均遗漏的新问题

#### #G1 🟠：HoloProfile 不走 iCloud 同步——换机即丢失

经验证，`HoloProfile.md` 存储在 `Application Support/Holo/`，不经过 `NSPersistentCloudKitContainer` 同步。只有 Core Data（交易、习惯、任务等）走 iCloud。

**影响**：用户换新设备后，所有 Core Data 数据都在，但 HoloProfile 丢失。AI 突然不知道用户叫什么、不记得沟通偏好。长期记忆系统（JSON 文件）同样不走 iCloud——换机后 AI 的所有"了解"全部清零。

这与方案的核心定位矛盾："HoloAI 每次回答前必须读取的用户主动长期上下文"——如果换机后这个上下文不存在了，整套体系就断了。

**建议**：
- 短期（Phase 1 前）：在方案风险表中增加"跨设备不同步"条目，明确这是已知限制。
- 中期（Phase 2 后）：评估将 HoloProfile 同步到 iCloud（通过 `NSUbiquitousKeyValueStore` 或 CloudKit private zone），或将 profile 存入 Core Data。
- 同步方案需要考虑冲突解决（两台设备同时编辑 profile）。

#### #G2 🟡：InsightPreferenceProfile.preferredTone 与 HoloProfile 沟通偏好重叠

经验证，`InsightPreferenceProfile` 有一个 `preferredTone` 字段（balanced/direct/gentle/dataFirst/fewerSuggestions），与 HoloProfile 的"沟通偏好"概念重叠。但 `preferredTone` **当前是死代码**——被收集但从未注入任何 prompt。

**影响**：如果 Phase 1 上线后，HoloProfile 的沟通偏好生效了，而 InsightPreferenceProfile 的 preferredTone 仍然是死代码，未来某天有人激活它时，两个系统的语气指令会冲突。

**建议**：在 Phase 0 文档中明确记录 `InsightPreferenceProfile.preferredTone` 的处置——要么废弃（由 HoloProfile 沟通偏好替代），要么在 HoloProfile 无沟通偏好时作为 fallback。不要让两个系统各自管理语气。

#### #G3 🟡：策略 B 的 system message 排序影响 LLM 行为

GPT 建议策略 B（Provider 追加第三条 system message），架构上更干净。但需要注意：

当前分析路径的 system messages 排序是：
1. `system_prompt`（主系统提示）
2. `systemContextOverride`（分析 JSON）

策略 B 会变成：
1. `system_prompt`
2. `systemContextOverride`（分析 JSON）
3. profile prompt（用户长期上下文）

部分 LLM（尤其是小模型）对 system message 排序敏感——**越靠后的 system message 权重越低**。如果 profile 在最后，模型可能优先分析 JSON 而忽略 profile 中的称呼和偏好。这对本方案的核心目标（"每次回答前必须参考"）不利。

**建议**：如果选策略 B，profile prompt 应插在 `systemContextOverride` **之前**（第 2 条位置），分析 JSON 放最后。因为 profile 是稳定的长期上下文，分析 JSON 是本次查询的临时数据，稳定信息应该更靠近主系统提示。

### 13.4 最终 consolidated 结论

**Conditional Go — 补充 3 条修正后可进入实施。**

GPT 第二轮审查整体质量高，对我 14 个标注的裁决基本准确，P0/P1 分层合理。但需要修正以下 3 点：

| 修正项 | 性质 | 行动 |
| --- | --- | --- |
| FlexibleQuery 入口矩阵描述修正 | 🔴 事实错误 | 修正矩阵行，标注为"必须注入"而非"验证不被覆盖" |
| Phase 4 描述与 #11 裁决矛盾 | 🟠 逻辑矛盾 | Phase 4 改为本地 suggestion detector，删除 `update_profile_suggestion` 意图 |
| P0-1 prompt injection 降级为 P1 | 🟡 定级调整 | 不阻断 Phase 1，在 renderer 实现时一并处理 |

新增 2 条待补充约束：

| 新增项 | 级别 | 行动 |
| --- | --- | --- |
| HoloProfile 不走 iCloud 同步 | 🟠 | 风险表增加条目，中期评估同步方案 |
| InsightPreferenceProfile.preferredTone 处置 | 🟡 | Phase 0 明确废弃或 fallback 角色 |

完成以上修正后，方案可以进入 Phase 0 实施。
