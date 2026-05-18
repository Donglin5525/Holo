# 观点语音智能总结功能设计

日期：2026-05-18

## 背景

观点模块当前支持在编辑器中通过语音输入识别文本，并将 ASR 结果插入到观点内容。现有流程更接近“语音直出”，会保留口语中的重复、停顿和语序绕路。用户希望在观点模块中增加类似 Typeless 的体验：语音说完后，系统直接把内容整理成顺畅、可保存的观点记录。

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

## 总结规则

智能总结采用「观点记录风格」：

1. 保留第一人称表达，不改成客观第三方摘要。
2. 保留用户的判断、倾向、情绪和关键细节。
3. 去掉口癖、重复、无意义停顿和明显绕路表达。
4. 调整语序，让内容成为可以直接保存的顺畅观点。
5. 不替用户扩写不存在的事实、结论、行动项或理由。
6. 短语音以润色为主，尽量不压缩。
7. 长语音轻度压缩到原文约 50%-70%，优先保留观点链路和关键细节。

示例：

ASR 原文：

> 我觉得今天这个事情吧，主要是我们不能再把所有东西都塞到一个版本里面了，真的很乱，然后应该先把那个最影响留存的入口先做好，再看看数据。

总结结果：

> 我觉得产品节奏不应该把所有事项都塞进同一个版本。下一步应优先打磨最影响留存的核心入口，并用真实数据判断是否继续扩展。

## 技术方案

### iOS 侧

在现有语音输入链路上增加一个可选的 post-ASR 文本处理阶段。

涉及现有位置：

- `Views/Thoughts/ThoughtEditorView.swift`：观点编辑器语音入口、开关偏好、插入结果。
- `Views/Chat/Voice/VoiceInputSheet.swift`：结果页状态、总结结果和原文切换。
- `Views/Chat/Voice/VoiceInputViewModel.swift`：ASR 完成后的可选总结状态机。
- `Services/AI/HoloBackendAIProvider.swift`：新增 `thought_voice_summary` purpose 调用。
- `Services/AI/PromptManager.swift`：新增本地兜底 Prompt 类型。

建议新增抽象：

```swift
protocol VoiceTranscriptPostProcessor {
    func process(_ transcript: String) async throws -> String
}
```

观点模块传入 `ThoughtVoiceSummaryProcessor`。非观点模块不传入处理器，因此保持现有行为。

`VoiceInputViewModel` 需要保留两份文本：

- `originalTranscript`：ASR 原文。
- `editableTranscript`：当前展示和最终插入的文本，可能是总结结果或原文。

状态上可在现有 `.transcribing` 和 `.transcriptReady` 之间增加内部处理阶段，UI 文案展示为「正在智能总结」。如果总结失败，将 `editableTranscript` 设置为 `originalTranscript`，并暴露非阻塞提示信息。

用户偏好使用 `UserDefaults` 保存，键名建议为：

```text
com.holo.thought.voice.smartSummary.enabled
```

默认值为 `true`。

### 后端侧

新增独立 purpose：

```text
thought_voice_summary
```

后端 `/v1/ai/chat/completions` 继续作为统一入口，但 `config.routes` 增加 `thought_voice_summary` 路由，配置独立模型参数、温度和 token 上限。

Prompt 管理新增类型：

```text
thought_voice_summary
```

该 Prompt 进入现有 `defaultPrompts.json`、`promptRegistry.js`、SQLite prompt_versions 和后台 Prompt 管理页。由于项目已有 Prompt 双端同步规则，后续部署时必须同步 iOS 本地兜底 Prompt 和 HoloBackend 默认/托管 Prompt。

请求消息建议：

```text
system: thought_voice_summary Prompt
user: ASR 原文
```

返回内容为纯文本，不返回 JSON。

### 日志与限流

`thought_voice_summary` 使用 chat completion 链路的设备级限流和调用日志。日志 purpose 应记录为 `thought_voice_summary`，便于后台区分普通聊天、意图识别、记忆洞察和观点语音总结。

## 错误处理

1. ASR 失败：沿用现有错误页和重试逻辑。
2. 总结超时、网络失败、后端错误：自动回退 ASR 原文，提示「智能总结失败，已保留原文」。
3. 总结返回空字符串：按总结失败处理。
4. 用户取消或重录：清空当前原文和总结结果。
5. 用户还原原文后再插入：插入原文，不再自动重新总结。

## 测试计划

### iOS 单元测试

1. `VoiceInputViewModelTests`
   - 智能总结开启时，ASR 成功后自动调用 post processor。
   - post processor 成功时，`editableTranscript` 为总结结果。
   - post processor 失败时，`editableTranscript` 回退为 ASR 原文。
   - 关闭智能总结或不传 post processor 时，保持 ASR 原文直出。
   - 支持从总结结果还原到原文。

2. `ThoughtVoiceTranscriptInsertionTests`
   - 继续验证插入规则不被智能总结改动破坏。
   - 插入总结文本和插入原文均使用同一插入规则。

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
3. 用户可以查看并还原 ASR 原文。
4. 关闭开关后，观点语音输入完全保持现有直出体验。
5. 总结失败不会丢内容，能自动回退原文并继续插入。
6. 后端 Prompt 管理中能看到并维护 `thought_voice_summary`。
7. 相关 iOS 和后端测试通过。
