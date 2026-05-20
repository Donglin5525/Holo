# 观点语音智能总结功能设计

日期：2026-05-18
最后更新：2026-05-18（对抗性审查后修订）

## 背景

观点模块当前支持在编辑器中通过语音输入识别文本，并将 ASR 结果插入到观点内容。现有流程更接近"语音直出"，会保留口语中的重复、停顿和语序绕路。用户希望在观点模块中增加类似 Typeless 的体验：语音说完后，系统直接把内容整理成顺畅、可保存的观点记录。

本设计只覆盖观点模块的语音输入，不改变 HoloAI 对话、任务、财务等其他模块的语音输入默认行为。

## 目标

1. 在观点编辑器语音入口增加「智能总结」开关。
2. 智能总结默认开启，并记住用户上次选择。
3. 开启时，录音完成后直接展示已总结的文本，而不是先展示 ASR 原文再让用户手动总结。
4. 用户可以查看或还原 ASR 原文，避免 AI 总结误改原意后无法恢复。
5. 关闭时保持现有语音直出体验。
6. 总结失败时不阻塞记录，自动回退到 ASR 原文。

## 非目标

1. 不为所有语音输入统一增加智能总结。
2. 不新增 Core Data 字段保存原始语音或总结历史。
3. 不在本阶段支持多种总结模板、标题生成、标签自动提取或结构化大纲。
4. 不把 ASR 接口和总结接口合并成一个接口。

## 用户体验

### 入口状态

观点编辑器右下角保留现有麦克风按钮，并在麦克风旁增加小型「智能总结」开关。

- 默认状态：开启。
- 用户关闭后：保存为观点语音输入的用户偏好，下次打开观点语音仍保持关闭。
- 用户重新开启后：后续观点语音继续默认开启。
- 每次打开 VoiceInputSheet 时读取 UserDefaults 最新值，支持同一个编辑会话内多次切换。

### 开启智能总结

用户点击麦克风并完成录音后，流程为：

1. ASR 转写语音，得到原文。
2. iOS 调用独立「观点语音总结」能力处理原文。
3. 底部卡片直接展示总结后的文字。
4. 标题显示「智能总结完成」。
5. 副标题提示「已整理成更适合观点记录的表达」。
6. 主文本框内容为总结结果，仍允许用户手动编辑。
7. 操作按钮包含「重录」「查看原文 / 还原原文」「插入」。

「查看原文」展示 ASR 原文。若用户选择还原，文本框内容切换为 ASR 原文，插入时使用原文。

### 原文/总结切换的完整状态管理

文本框内维护三份文本：

| 字段 | 说明 | 可变性 |
|------|------|--------|
| `originalTranscript` | ASR 原文，不可变 | 只读 |
| `summaryTranscript` | 总结结果，不可变 | 只读 |
| `editableText` | 当前文本框内容，用户可编辑 | 可变 |

初始状态：`editableText = summaryTranscript`。

按钮行为：

| 当前 `editableText` 来源 | 按钮文案 | 点击后行为 |
|--------------------------|----------|------------|
| `summaryTranscript`（未编辑） | 「查看原文」 | `showOriginalTranscript()` → `editableText = originalTranscript` |
| `summaryTranscript`（已编辑） | 「查看原文」 | `showOriginalTranscript()` → `editableText = originalTranscript`，**用户编辑的总结内容不保留**（因为文本框是单实例，切换即替换） |
| `originalTranscript`（未编辑） | 「还原总结」 | `restoreSummaryTranscript()` → `editableText = summaryTranscript` |
| `originalTranscript`（已编辑） | 「还原总结」 | `restoreSummaryTranscript()` → `editableText = summaryTranscript`，用户编辑的原文内容不保留 |

> **设计决策**：不保留中间编辑态。用户在原文和总结之间切换时，文本框恢复为原始版本。这是为了简化状态管理，避免出现"既不是原文也不是总结"的混乱状态。如果用户需要混合内容，可以在最终 `editableText` 上手动编辑。

插入时：无论 `editableText` 来源是什么（总结、原文、用户编辑后），一律插入 `editableText` 的当前值。

### 关闭智能总结

用户关闭开关后，语音输入沿用现有流程：

1. ASR 转写语音。
2. 结果页标题显示「识别结果」。
3. 文本框内容为 ASR 原文。
4. 用户编辑后点击「插入」。

### 失败兜底

如果 ASR 成功但智能总结失败：

1. 自动回退到 ASR 原文。
2. 结果页仍允许编辑和插入。
3. 提示「智能总结失败，已保留原文」。
4. 页面状态不进入阻塞错误态。

如果 ASR 本身失败，则沿用现有语音识别失败逻辑。

### 总结中的用户体验

总结进行中（LLM 调用期间），UI 展示：

- 旋转动画 + 文字「正在智能总结」
- 「重录」按钮可见，允许用户放弃等待
- 总结超时阈值：**15 秒**。超时后按总结失败处理，回退到 ASR 原文
- 不采用 streaming 返回，因为总结文本通常较短（100-500 字），全量返回延迟可接受，且避免了 streaming UI 的复杂度

## 总结规则

智能总结采用「观点记录风格」：

1. 保留第一人称表达，不改成客观第三方摘要。
2. 保留用户的判断、倾向、情绪和关键细节。
3. 去掉口癖、重复、无意义停顿和明显绕路表达。
4. 调整语序，让内容成为可以直接保存的顺畅观点。
5. 不替用户扩写不存在的事实、结论、行动项或理由。
6. 短语音以润色为主，尽量不压缩。
7. 长语音轻度压缩到原文约 50%-70%，优先保留观点链路和关键细节。

### 总结结果质量兜底

LLM 返回结果后，做轻量校验：

| 条件 | 处理 |
|------|------|
| 返回空字符串 | 按总结失败处理，回退 ASR 原文 |
| 结果长度 < 原文的 10% | 可能过度压缩，**仍展示结果**，但在副标题加提示「总结较原文大幅缩短，可查看原文确认」 |
| 结果长度 > 原文的 150% | 可能存在幻觉扩写，**仍展示结果**，副标题加提示「总结内容较原文更长，建议查看原文对比」 |
| 其他情况 | 正常展示 |

> 不自动拒绝展示 LLM 结果——因为"过度压缩"或"扩写"的判断需要人工确认。副标题提示足以让用户意识到异常并选择查看原文。

示例：

ASR 原文：

> 我觉得今天这个事情吧，主要是我们不能再把所有东西都塞到一个版本里面了，真的很乱，然后应该先把那个最影响留存的入口先做好，再看看数据。

总结结果：

> 我觉得产品节奏不应该把所有事项都塞进同一个版本。下一步应优先打磨最影响留存的核心入口，并用真实数据判断是否继续扩展。

## 技术方案

### iOS 侧

#### 架构策略：受控扩展共享语音组件

`VoiceInputSheet` 和 `VoiceInputViewModel` 是共享组件，同时服务于 ChatView（聊天）和 ThoughtEditorView（观点）。本功能会对共享组件做受控扩展，但所有新增能力都通过可选参数启用；未传入智能总结配置时，ChatView 等既有调用方保持现有行为。

具体方式：

1. **受控扩展 `VoiceInputViewModel`**：把 ASR 原文、总结结果、当前可编辑文本、总结中状态放进同一个 ViewModel，避免 Sheet 和外部 Coordinator 各自持有一份文本。
2. **通过可选配置保持共享组件兼容**：`VoiceInputViewModel` 默认不启用总结处理器；ChatView 不传总结配置，因此行为保持现状。
3. **在 ThoughtEditorView 侧新建 `ThoughtVoiceSummaryProcessor`**：只负责调用后端总结 API，不持有 UI 文本状态。
4. **VoiceInputSheet 扩展配置能力**：通过新增可选参数（而非硬编码逻辑）支持自定义结果页标题、副标题和原文/总结切换按钮。未配置时保持现有行为。

> **架构代价**：VoiceInputViewModel 新增 6 个属性（`originalTranscript`、`summaryTranscript`、`transcriptDisplayMode`、`summaryNotice`、`summaryTask`、`postProcessor`），全部为可选/nil 默认值。ChatView 使用路径不传入总结配置，这些属性始终为 nil，运行时零开销。选择在 ViewModel 内扩展而非外部 Coordinator，是为了避免 Sheet 和 Coordinator 各持有一份 `editableTranscript` 导致双数据源同步问题。

```
ThoughtEditorView
  ├── ThoughtVoiceSummaryProcessor（新增）
  │     └── summarize(_ text: String) async throws -> String
  └── VoiceInputSheet
        └── VoiceInputViewModel
              ├── originalTranscript: String?
              ├── summaryTranscript: String?
              ├── editableTranscript: String
              ├── transcriptDisplayMode: summary | original
              └── toggleOriginal() / restoreSummary()
```

#### VoiceInputSheet 配置扩展

在现有 `init` 参数基础上，增加可选的配置参数：

```swift
struct VoiceResultConfig {
    var title: String = "识别结果"          // 默认标题
    var subtitle: String? = nil            // 可选副标题
    var warningSubtitle: String? = nil     // 质量异常提示
    var showsOriginalToggle: Bool = false  // 是否展示原文/总结切换按钮
}
```

ThoughtEditorView 传入自定义配置和 `ThoughtVoiceSummaryProcessor`，ChatView 不传（使用默认值）。VoiceInputSheet 根据 config 渲染标题、副标题和切换按钮，但文本状态只从 `VoiceInputViewModel` 读取和更新，避免双数据源。

#### 文本状态单一来源

`VoiceInputViewModel` 是语音结果文本的唯一状态来源：

| 字段 | 说明 |
|------|------|
| `originalTranscript` | ASR 原文。ASR 成功后写入，后续不随用户编辑变化 |
| `summaryTranscript` | 智能总结结果。总结成功后写入，后续不随用户编辑变化 |
| `editableTranscript` | 文本框绑定值。用户最终插入的内容 |
| `transcriptDisplayMode` | 当前展示来源：`.summary` 或 `.original` |
| `summaryNotice` | 总结失败、超时、长度异常等非阻塞提示 |

切换行为由 ViewModel 方法完成：

```swift
func showOriginalTranscript() {
    guard let originalTranscript else { return }
    editableTranscript = originalTranscript
    transcriptDisplayMode = .original
}

func restoreSummaryTranscript() {
    guard let summaryTranscript else { return }
    editableTranscript = summaryTranscript
    transcriptDisplayMode = .summary
}
```

这样 `VoiceInputSheet` 的 TextField 继续绑定 `viewModel.editableTranscript`，原文/总结切换不会引入外部 binding 或第二份 `editableText`。

#### 状态机扩展

`VoiceInputState` 新增枚举 case：

```swift
enum VoiceInputState {
    // ... 现有状态
    case summarizing(String)   // 新增：正在总结，携带 ASR 原文
}
```

状态转换变为：

```
.transcribing → .summarizing(asrText)  // ASR 成功 + 智能总结开启
.transcribing → .transcriptReady(text) // ASR 成功 + 智能总结关闭（现有路径）
.summarizing → .transcriptReady(summaryText)  // 总结成功
.summarizing → .transcriptReady(asrText)       // 总结失败，回退原文
```

ViewModel 在进入 `.summarizing(asrText)` 后，使用注入的可选 `VoiceTranscriptPostProcessor` 触发异步总结调用。ViewModel 同时管理一个 `summaryTask` 引用，在用户重录、取消或关闭 Sheet 时通过 `task.cancel()` 取消飞行中的请求。

> **为什么用枚举 case 而非 bool flag**：避免 `.transcribing` + `isSummarizing = true/false` 的隐式组合态。枚举 case 让 switch 穷举覆盖所有情况，编译器强制处理新状态。

#### 总结调用链路

```
VoiceInputViewModel.finishStreamingTranscription()
  → editableTranscript = asrText
  → state = .summarizing(asrText)
  → ViewModel 调用 postProcessor.process(asrText)
    → ThoughtVoiceSummaryProcessor
      → HoloBackendAIProvider.chat(
        purpose: .thoughtVoiceSummary,
        messages: [system: prompt, user: asrText]
      )
    → 成功: originalTranscript = asrText, summaryTranscript = summary, editableTranscript = summary, state = .transcriptReady(summary)
    → 失败/超时: originalTranscript = asrText, editableTranscript = asrText, state = .transcriptReady(asrText), summaryNotice = 失败提示
```

#### 超时与取消

```swift
private var summaryTask: Task<Void, Never>?

private func startSummary(_ asrText: String) {
    summaryTask = Task {
        do {
            let result = try await withTimeout(seconds: 15) {
                try await postProcessor.process(asrText)
            }
            // 处理结果...
        } catch is CancellationError {
            // Task 被 cancel，不更新状态
        } catch {
            // 超时或其他错误，回退原文
        }
    }
}

func cancelSummary() {
    summaryTask?.cancel()
    summaryTask = nil
}
```

在 `cancel()`、`reRecord()`、`cleanupAfterDismiss()` 和开始新一次 `startRecording()` 前调用 `cancelSummary()`。VoiceInputSheet 的 `onDisappear` 继续调用 `viewModel.cleanupAfterDismiss()`，由 ViewModel 统一清理飞行中的总结请求。

#### 用户偏好

使用 `UserDefaults` 保存，键名：

```text
com.holo.thought.voice.smartSummary.enabled
```

默认值为 `true`。每次 VoiceInputSheet 呈现时从 UserDefaults 读取最新值，不缓存到内存，确保同一编辑会话内多次切换语音时偏好一致。

#### 涉及文件

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `Views/Chat/Voice/VoiceInputViewModel.swift` | 修改 | 新增 `.summarizing(String)` 状态、原文/总结状态、post processor 注入 |
| `Views/Chat/Voice/VoiceInputSheet.swift` | 修改 | 新增 `VoiceResultConfig` 配置参数，渲染自定义标题/切换按钮 |
| `Views/Thoughts/ThoughtEditorView.swift` | 修改 | 传入智能总结开关、结果页配置和总结 processor |
| `Views/Thoughts/ThoughtVoiceSummaryProcessor.swift` | **新增** | 调用后端观点语音总结能力 |
| `Services/AI/HoloBackendAIProvider.swift` | 修改 | 新增 `thought_voice_summary` purpose |
| `Services/AI/PromptManager.swift` | 修改 | 新增本地兜底 Prompt 类型 |

### 后端侧

#### 新增路由配置

在 `config.routes` 中新增：

```javascript
"thought_voice_summary": {
  provider: process.env.HOLO_THOUGHT_VOICE_SUMMARY_PROVIDER
    ?? process.env.HOLO_CHAT_PROVIDER
    ?? "mock",
  model: process.env.HOLO_THOUGHT_VOICE_SUMMARY_MODEL
    ?? process.env.HOLO_CHAT_MODEL
    ?? "holo-mock",
  temperature: Number(process.env.HOLO_THOUGHT_VOICE_SUMMARY_TEMPERATURE ?? 0.3),
  maxTokens: Number(process.env.HOLO_THOUGHT_VOICE_SUMMARY_MAX_TOKENS ?? 1024),
}
```

请求中的 `purpose` 字符串为 `thought_voice_summary`，因此 route key 也应直接使用 `"thought_voice_summary"`，以匹配当前后端 `config.routes[purpose]` 的读取方式。provider/model 必须通过环境变量 fallback 到 chat 配置，不能写成 `undefined`。

#### 新增 Prompt 类型

在 `defaultPrompts.json` 中新增 `thought_voice_summary` 条目。Prompt 模板：

```text
你是一个语音记录整理助手。用户通过语音表达了一个或多个观点，ASR 转写结果包含口语化的重复、停顿和语序混乱。请将内容整理成适合保存的观点记录。

规则：
1. 保留第一人称表达，不要改成客观第三方摘要。
2. 保留用户的判断、倾向、情绪和关键细节。
3. 去掉口癖（如「然后」「就是说」）、重复、无意义停顿和明显绕路表达。
4. 调整语序，使内容成为可以直接保存的顺畅观点。
5. 不要替用户扩写不存在的事实、结论、行动项或理由。如果原文没有说，就不要加。
6. 短文本（100字以内）以润色为主，尽量不压缩长度。
7. 长文本轻度压缩到原文约 50%-70%，优先保留观点推理链路和关键细节。
8. 只输出整理后的文本，不要加标题、标签、解释或格式标记。

直接输出整理结果：
```

#### iOS 本地兜底 Prompt

在 `PromptManager.swift` 的 `templates` 中新增同等内容，确保后端不可用时本地有后备。

Prompt 版本号：`promptVersions["thought_voice_summary"] = 1`

#### 请求格式

```text
system: thought_voice_summary Prompt
user: ASR 原文
```

返回内容为纯文本，不返回 JSON。`response_format` 不设置 `json_object`。

### 日志与限流

`thought_voice_summary` 使用 chat completion 链路的设备级限流和调用日志。日志 purpose 记录为 `thought_voice_summary`，便于后台区分。限流复用现有 `chatRequestsPerMinute` / `chatRequestsPerDay` 配额，不单独设限。

### 长语音 token 预算

300 秒语音的 ASR 输出约 3000-5000 字（约 4000-7000 tokens）。当前模型 context 窗口（64K+）足以容纳。如果未来接入小窗口模型，需在 iOS 侧加截断逻辑：原文超过 4000 字时截断并提示用户。本阶段不实现截断，记录为已知限制。

## 错误处理

| 场景 | 处理 |
|------|------|
| ASR 失败 | 沿用现有错误页和重试逻辑 |
| 总结超时（>15 秒） | 自动回退 ASR 原文，提示「智能总结超时，已保留原文」 |
| 总结网络失败 | 自动回退 ASR 原文，提示「智能总结失败，已保留原文」 |
| 总结后端错误（4xx/5xx） | 自动回退 ASR 原文，提示「智能总结失败，已保留原文」 |
| 总结返回空字符串 | 按总结失败处理 |
| 用户总结中重录 | `Task.cancel()` 取消飞行请求，清空原文和总结 |
| 用户总结中关闭 Sheet | `Task.cancel()` 取消飞行请求，不触发任何回调 |
| 还原原文后插入 | 插入 `editableText` 当前值（可能是编辑后的原文） |

## 测试计划

### iOS 单元测试

1. `ThoughtVoiceSummaryProcessorTests`
   - ASR 文本传入后触发总结 API 调用。

2. `VoiceInputViewModelTests`
   - 总结成功时 `editableText` 为总结结果，`originalTranscript` 保留原文。
   - 总结失败/超时时 `editableText` 回退为 ASR 原文。
   - `showOriginalTranscript()` 切换 `editableTranscript` 到原文，`restoreSummaryTranscript()` 切换回总结。
   - 用户编辑 `editableTranscript` 后切换到原文，再切回总结时，`editableTranscript` 恢复为原始 `summaryTranscript`（不保留中间编辑）。
   - `cancelSummary()` 能取消正在进行的异步 Task。
   - 质量兜底：结果 < 原文 10% 时生成警告文案。
   - 新增 `.summarizing` 状态的转换覆盖。
   - `.summarizing` → `.transcriptReady` 的正常和异常路径。
   - 关闭总结功能时不进入 `.summarizing` 状态，直接到 `.transcriptReady`。

3. `VoiceInputSheet` 轻量 UI 测试或预览验证
   - ChatView 未传 `VoiceResultConfig` 时仍显示原有「识别结果」和「发送」。
   - ThoughtEditorView 传入配置时显示「智能总结完成」和原文/总结切换按钮。

4. `ThoughtVoiceTranscriptInsertionTests`
   - 插入总结文本和插入原文均使用同一插入规则。
   - 插入用户编辑后的文本正常工作。

### 后端测试

1. `prompts.test.js`
   - `thought_voice_summary` 出现在 Prompt 列表和元数据中。
   - 默认 Prompt 可读取并进入版本体系。

2. `chat.test.js`
   - `purpose=thought_voice_summary` 能路由到配置模型。
   - 未知 purpose 仍返回错误。
   - 日志记录 purpose 为 `thought_voice_summary`。

### 验证命令

实施完成后至少运行：

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' test
```

```bash
npm test --prefix HoloBackend
```

## 验收标准

1. 观点编辑器中可以看到「智能总结」开关，默认开启。
2. 开启状态下录音完成后，主结果直接是总结后的观点文本。
3. 用户可以查看并还原 ASR 原文，切换时不保留中间编辑。
4. 关闭开关后，观点语音输入完全保持现有直出体验。
5. 总结失败/超时不会丢内容，能自动回退原文并继续插入。
6. 总结超过 15 秒自动超时回退。
7. 后端 Prompt 管理中能看到并维护 `thought_voice_summary`。
8. VoiceInputSheet 不包含观点模块硬编码逻辑，通过配置参数注入 UI 差异。
9. 相关 iOS 和后端测试通过。
10. ChatView 的语音输入行为不受影响。

## 已知限制

1. 300 秒长语音的 ASR 输出可能很长，LLM 消耗 input tokens 较多，但不做截断。
2. 不支持 streaming 总结（全量返回），长语音等待时间可能达 10-15 秒。
3. 不保留用户在原文和总结之间切换时的中间编辑。
4. 不做 LLM 幻觉的语义级检测，仅做长度异常的轻量校验。
5. 总结调用共享 chat 限流配额，高频使用可能触发限流。
