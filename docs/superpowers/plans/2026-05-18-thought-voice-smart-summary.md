# Thought Voice Smart Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add default-on intelligent summarization for Thought voice input, with ASR original fallback, reversible original/summary switching, and an independent backend `thought_voice_summary` purpose.

**Architecture:** Extend the shared voice input components in a controlled, optional way. `VoiceInputViewModel` owns all voice result text state to avoid double sources of truth; Thought-specific code injects a `VoiceTranscriptPostProcessor` while Chat keeps the default ASR-only path.

**Tech Stack:** SwiftUI, XCTest, Core app `AIProvider`/HoloBackend gateway, Node test runner, HoloBackend prompt registry.

---

## Scope Notes

This plan implements one feature across two coupled layers:

- HoloBackend: new route purpose and managed prompt type.
- iOS: Thought voice input smart-summary post-processing, UI switch, original/summary switching, and tests.

Do not refactor unrelated voice input, chat, prompt admin, or Thought editor behavior. The workspace may contain unrelated dirty files; commit only files listed in each task.

## Files

### Create

- `Holo/Holo APP/Holo/Holo/Views/Chat/Voice/VoiceTranscriptPostProcessor.swift`  
  Protocol shared by voice input and Thought-specific summary processor.
- `Holo/Holo APP/Holo/Holo/Views/Thoughts/ThoughtVoiceSummaryProcessor.swift`  
  Thought-specific post processor that calls `AIProvider.summarizeThoughtVoiceTranscript`.

### Modify

- `Holo/Holo APP/Holo/Holo/Views/Chat/Voice/VoiceInputViewModel.swift`  
  Add optional post processor, `.summarizing`, original/summary/current text state, cancellation, and switching methods.
- `Holo/Holo APP/Holo/Holo/Views/Chat/Voice/VoiceInputSheet.swift`  
  Add `VoiceResultConfig`, summarizing UI, configurable result title/subtitle, and original/summary toggle button.
- `Holo/Holo APP/Holo/Holo/Views/Thoughts/ThoughtEditorView.swift`  
  Add smart-summary toggle UI, preference persistence, and Thought processor injection.
- `Holo/Holo APP/Holo/Holo/Services/AI/AIProvider.swift`  
  Add `summarizeThoughtVoiceTranscript(_:)`.
- `Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift`  
  Implement `thought_voice_summary` purpose call.
- `Holo/Holo APP/Holo/Holo/Services/AI/MockAIProvider.swift`  
  Add deterministic mock summary support.
- `Holo/Holo APP/Holo/Holo/Services/AI/OpenAICompatibleProvider.swift`  
  Add fallback implementation through regular chat if needed for local/custom provider path.
- `Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift`  
  Add `.thoughtVoiceSummary` prompt type and local fallback prompt.
- `Holo/Holo APP/Holo/HoloTests/Services/Speech/VoiceInputViewModelTests.swift`  
  Add summarization state tests.
- `Holo/Holo APP/Holo/HoloTests/Views/Thoughts/ThoughtVoiceTranscriptInsertionTests.swift`  
  Add insertion regression for summary/original edited text.
- `HoloBackend/src/config.js`  
  Add `thought_voice_summary` route.
- `HoloBackend/src/prompts/defaultPrompts.json`  
  Add `thought_voice_summary` prompt.
- `HoloBackend/src/prompts/promptRegistry.js`  
  Add prompt version entry.
- `HoloBackend/tests/chat.test.js`  
  Add route and logging tests.
- `HoloBackend/tests/prompts.test.js`  
  Add prompt registry tests.

---

### Task 1: Backend Purpose And Prompt

**Files:**
- Modify: `HoloBackend/src/config.js`
- Modify: `HoloBackend/src/prompts/defaultPrompts.json`
- Modify: `HoloBackend/src/prompts/promptRegistry.js`
- Test: `HoloBackend/tests/chat.test.js`
- Test: `HoloBackend/tests/prompts.test.js`

- [ ] **Step 1: Add failing backend tests**

Add these tests to `HoloBackend/tests/chat.test.js`:

```javascript
test("POST /v1/ai/chat/completions supports thought voice summary purpose", async () => {
  const app = createTestApp({
    routes: {
      thought_voice_summary: {
        provider: "mock",
        model: "holo-mock",
        temperature: 0.3,
        maxTokens: 1024,
      },
    },
  });

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "thought-summary-device",
    },
    body: JSON.stringify({
      purpose: "thought_voice_summary",
      stream: false,
      messages: [{ role: "user", content: "我觉得这个版本不能再塞太多东西" }],
    }),
  });

  assert.equal(response.status, 200);
  const json = await response.json();
  assert.equal(json.provider, "mock");
  assert.equal(json.model, "holo-mock");
  assert.match(json.choices[0].message.content, /我觉得这个版本不能再塞太多东西/);
});

test("AI call logs record thought voice summary purpose", async () => {
  const adminLogStore = createRecordingAdminLogStore();
  const app = createTestApp({
    adminLogStore,
    routes: {
      thought_voice_summary: {
        provider: "mock",
        model: "holo-mock",
        temperature: 0.3,
        maxTokens: 1024,
      },
    },
  });

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "thought-summary-log",
    },
    body: JSON.stringify({
      purpose: "thought_voice_summary",
      stream: false,
      messages: [{ role: "user", content: "整理这个观点" }],
    }),
  });

  assert.equal(response.status, 200);
  assert.equal(adminLogStore.entries.length, 1);
  assert.equal(adminLogStore.entries[0].purpose, "thought_voice_summary");
});
```

Add this test to `HoloBackend/tests/prompts.test.js`:

```javascript
test("thought_voice_summary 默认 Prompt 可读取并出现在元数据中", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/thought_voice_summary");
  assert.equal(response.status, 200);
  const prompt = await response.json();

  assert.equal(prompt.type, "thought_voice_summary");
  assert.equal(prompt.version, 1);
  assert.match(prompt.content, /语音记录整理助手/);
  assert.match(prompt.content, /只输出整理后的文本/);

  const metaResponse = await app.request("/v1/prompts/meta");
  const meta = await metaResponse.json();
  assert.ok(meta.prompts.some((item) => item.type === "thought_voice_summary"));
});
```

- [ ] **Step 2: Run backend tests and verify failure**

Run:

```bash
npm test --prefix HoloBackend -- tests/chat.test.js tests/prompts.test.js
```

Expected: FAIL because `thought_voice_summary` route and prompt are not registered yet.

- [ ] **Step 3: Add backend route**

In `HoloBackend/src/config.js`, add a route inside `DEFAULT_CONFIG.routes`:

```javascript
    thought_voice_summary: {
      provider: process.env.HOLO_THOUGHT_VOICE_SUMMARY_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
      model: process.env.HOLO_THOUGHT_VOICE_SUMMARY_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
      temperature: Number(process.env.HOLO_THOUGHT_VOICE_SUMMARY_TEMPERATURE ?? 0.3),
      maxTokens: Number(process.env.HOLO_THOUGHT_VOICE_SUMMARY_MAX_TOKENS ?? 1024),
    },
```

- [ ] **Step 4: Add backend prompt**

In `HoloBackend/src/prompts/defaultPrompts.json`, add a top-level key:

```json
  "thought_voice_summary": "你是一个语音记录整理助手。用户通过语音表达了一个或多个观点，ASR 转写结果包含口语化的重复、停顿和语序混乱。请将内容整理成适合保存的观点记录。\n\n规则：\n1. 保留第一人称表达，不要改成客观第三方摘要。\n2. 保留用户的判断、倾向、情绪和关键细节。\n3. 去掉口癖（如「然后」「就是说」）、重复、无意义停顿和明显绕路表达。\n4. 调整语序，使内容成为可以直接保存的顺畅观点。\n5. 不要替用户扩写不存在的事实、结论、行动项或理由。如果原文没有说，就不要加。\n6. 短文本（100字以内）以润色为主，尽量不压缩长度。\n7. 长文本轻度压缩到原文约 50%-70%，优先保留观点推理链路和关键细节。\n8. 只输出整理后的文本，不要加标题、标签、解释或格式标记。\n\n直接输出整理结果："
```

Keep the JSON valid: add a comma before this entry if it is not the first key.

- [ ] **Step 5: Add prompt version**

In `HoloBackend/src/prompts/promptRegistry.js`, update `PROMPT_VERSIONS`:

```javascript
const PROMPT_VERSIONS = {
  intent_recognition: 7,
  memory_insight_generation: 5,
  annual_review: 1,
  thought_voice_summary: 1,
};
```

- [ ] **Step 6: Run backend tests and verify pass**

Run:

```bash
npm test --prefix HoloBackend -- tests/chat.test.js tests/prompts.test.js
```

Expected: PASS for the new route and prompt tests.

- [ ] **Step 7: Commit backend route and prompt**

Run:

```bash
git add HoloBackend/src/config.js HoloBackend/src/prompts/defaultPrompts.json HoloBackend/src/prompts/promptRegistry.js HoloBackend/tests/chat.test.js HoloBackend/tests/prompts.test.js
git commit -m "feat(backend): add thought voice summary purpose"
```

---

### Task 2: iOS AI Provider And Prompt Support

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/AIProvider.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/MockAIProvider.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/OpenAICompatibleProvider.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift`
- Create: `Holo/Holo APP/Holo/Holo/Views/Chat/Voice/VoiceTranscriptPostProcessor.swift`
- Create: `Holo/Holo APP/Holo/Holo/Views/Thoughts/ThoughtVoiceSummaryProcessor.swift`

- [ ] **Step 1: Add shared post processor protocol**

Create `Holo/Holo APP/Holo/Holo/Views/Chat/Voice/VoiceTranscriptPostProcessor.swift`:

```swift
//
//  VoiceTranscriptPostProcessor.swift
//  Holo
//
//  Optional post-ASR processor for voice input results
//

import Foundation

protocol VoiceTranscriptPostProcessor {
    func process(_ transcript: String) async throws -> String
}
```

- [ ] **Step 2: Add AIProvider API**

In `AIProvider.swift`, add to `protocol AIProvider`:

```swift
    /// 整理观点模块语音 ASR 原文
    func summarizeThoughtVoiceTranscript(_ transcript: String) async throws -> String
```

Add default implementation in `extension AIProvider`:

```swift
    func summarizeThoughtVoiceTranscript(_ transcript: String) async throws -> String {
        let messages: [ChatMessageDTO] = [.user(transcript)]
        return try await chat(messages: messages, userContext: .empty)
    }
```

- [ ] **Step 3: Add PromptManager type and template**

In `PromptManager.PromptType`, add:

```swift
case thoughtVoiceSummary = "thought_voice_summary"
```

Update `displayName`, `displayDescription`, and `icon`:

```swift
case .thoughtVoiceSummary: return "观点语音智能总结"
case .thoughtVoiceSummary: return "整理观点模块语音输入的 ASR 原文"
case .thoughtVoiceSummary: return "text.bubble.fill"
```

Add version:

```swift
.thoughtVoiceSummary: 1
```

Add template entry matching backend prompt:

```swift
.thoughtVoiceSummary: """
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
""",
```

- [ ] **Step 4: Implement HoloBackendAIProvider summary purpose**

In `HoloBackendAIProvider.swift`, add:

```swift
    func summarizeThoughtVoiceTranscript(_ transcript: String) async throws -> String {
        let prompt = await loadManagedPrompt(.thoughtVoiceSummary)
        let messages: [ChatMessageDTO] = [
            .system(prompt),
            .user(transcript)
        ]
        let request = buildRequest(
            purpose: .thoughtVoiceSummary,
            messages: messages
        )
        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

Update `HoloBackendPurpose`:

```swift
case thoughtVoiceSummary = "thought_voice_summary"
```

- [ ] **Step 5: Implement mock/custom provider behavior**

In `MockAIProvider.swift`, add:

```swift
    func summarizeThoughtVoiceTranscript(_ transcript: String) async throws -> String {
        "整理后的观点：\(transcript.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
```

In `OpenAICompatibleProvider.swift`, either rely on the default `AIProvider` extension or add an explicit method that calls `chat(messages:userContext:)`. Prefer the default if it compiles cleanly.

- [ ] **Step 6: Add Thought processor**

Create `Holo/Holo APP/Holo/Holo/Views/Thoughts/ThoughtVoiceSummaryProcessor.swift`:

```swift
//
//  ThoughtVoiceSummaryProcessor.swift
//  Holo
//
//  观点模块语音智能总结处理器
//

import Foundation

final class ThoughtVoiceSummaryProcessor: VoiceTranscriptPostProcessor {
    private let provider: AIProvider

    init(provider: AIProvider = HoloBackendEnvironment.makeDefaultProvider()) {
        self.provider = provider
    }

    func process(_ transcript: String) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return try await provider.summarizeThoughtVoiceTranscript(trimmed)
    }
}
```

- [ ] **Step 7: Compile iOS provider changes**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit provider layer**

Run:

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/AIProvider.swift" "Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift" "Holo/Holo APP/Holo/Holo/Services/AI/MockAIProvider.swift" "Holo/Holo APP/Holo/Holo/Services/AI/OpenAICompatibleProvider.swift" "Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift" "Holo/Holo APP/Holo/Holo/Views/Chat/Voice/VoiceTranscriptPostProcessor.swift" "Holo/Holo APP/Holo/Holo/Views/Thoughts/ThoughtVoiceSummaryProcessor.swift"
git commit -m "feat(iOS): add thought voice summary provider"
```

---

### Task 3: VoiceInputViewModel Summary State

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/Voice/VoiceInputViewModel.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/Speech/VoiceInputViewModelTests.swift`

- [ ] **Step 1: Add failing ViewModel tests**

Add this fake processor to `VoiceInputViewModelTests.swift`:

```swift
private final class FakeVoiceTranscriptPostProcessor: VoiceTranscriptPostProcessor {
    var result = "整理后的观点"
    var error: Error?
    var processCallCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func process(_ transcript: String) async throws -> String {
        processCallCount += 1
        continuation?.resume()
        continuation = nil
        if let error { throw error }
        return result
    }

    func waitForProcess() async {
        guard processCallCount == 0 || continuation != nil else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
```

Add tests:

```swift
func testSummaryProcessorRunsAfterTranscriptReady() async {
    let recorder = FakeVoiceRecordingService()
    recorder.currentTime = 2.0
    let provider = FakeSpeechRecognitionProvider()
    provider.result = SpeechRecognitionResult(text: "我觉得这个版本不能再塞功能", duration: 2, confidence: nil)
    let processor = FakeVoiceTranscriptPostProcessor()
    processor.result = "我觉得这个版本不应继续堆功能。"
    let viewModel = VoiceInputViewModel(
        speechProvider: provider,
        recordingService: recorder,
        postProcessor: processor
    )

    await viewModel.startRecording()
    await viewModel.finishRecording()
    await provider.streamingSession.waitForFinish()
    await processor.waitForProcess()

    XCTAssertEqual(processor.processCallCount, 1)
    XCTAssertEqual(viewModel.originalTranscript, "我觉得这个版本不能再塞功能")
    XCTAssertEqual(viewModel.summaryTranscript, "我觉得这个版本不应继续堆功能。")
    XCTAssertEqual(viewModel.editableTranscript, "我觉得这个版本不应继续堆功能。")
    XCTAssertEqual(viewModel.state, .transcriptReady("我觉得这个版本不应继续堆功能。"))
}

func testSummaryFailureFallsBackToOriginalTranscript() async {
    let recorder = FakeVoiceRecordingService()
    recorder.currentTime = 2.0
    let provider = FakeSpeechRecognitionProvider()
    provider.result = SpeechRecognitionResult(text: "原始观点", duration: 2, confidence: nil)
    let processor = FakeVoiceTranscriptPostProcessor()
    processor.error = APIError.networkUnavailable
    let viewModel = VoiceInputViewModel(
        speechProvider: provider,
        recordingService: recorder,
        postProcessor: processor
    )

    await viewModel.startRecording()
    await viewModel.finishRecording()
    await provider.streamingSession.waitForFinish()
    await processor.waitForProcess()

    XCTAssertEqual(viewModel.originalTranscript, "原始观点")
    XCTAssertNil(viewModel.summaryTranscript)
    XCTAssertEqual(viewModel.editableTranscript, "原始观点")
    XCTAssertEqual(viewModel.state, .transcriptReady("原始观点"))
    XCTAssertEqual(viewModel.summaryNotice, "智能总结失败，已保留原文")
}

func testOriginalAndSummarySwitchingReplacesEditableText() async {
    let viewModel = VoiceInputViewModel(
        speechProvider: FakeSpeechRecognitionProvider(),
        recordingService: FakeVoiceRecordingService()
    )

    viewModel.applyTranscriptResultForTesting(
        original: "原文",
        summary: "总结"
    )
    viewModel.editableTranscript = "用户编辑后的总结"

    viewModel.showOriginalTranscript()
    XCTAssertEqual(viewModel.editableTranscript, "原文")

    viewModel.editableTranscript = "用户编辑后的原文"
    viewModel.restoreSummaryTranscript()
    XCTAssertEqual(viewModel.editableTranscript, "总结")
}
```

If exposing `applyTranscriptResultForTesting` is undesirable, make it `internal` and clearly mark it test-only:

```swift
func applyTranscriptResultForTesting(original: String, summary: String) {
    originalTranscript = original
    summaryTranscript = summary
    editableTranscript = summary
    transcriptDisplayMode = .summary
    state = .transcriptReady(summary)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoloTests/VoiceInputViewModelTests test
```

Expected: FAIL because the new initializer, properties, and methods do not exist yet.

- [ ] **Step 3: Implement ViewModel state and processor**

In `VoiceInputViewModel.swift`, update `VoiceInputState`:

```swift
case summarizing(String)
```

Add enum and properties:

```swift
enum VoiceTranscriptDisplayMode: Equatable {
    case summary
    case original
}

@Published private(set) var originalTranscript: String?
@Published private(set) var summaryTranscript: String?
@Published private(set) var transcriptDisplayMode: VoiceTranscriptDisplayMode = .original
@Published private(set) var summaryNotice: String?

private let postProcessor: VoiceTranscriptPostProcessor?
private var summaryTask: Task<Void, Never>?
```

Update init signature:

```swift
init(
    speechProvider: SpeechRecognitionProvider,
    recordingService: VoiceRecordingServiceProviding? = nil,
    minimumDuration: TimeInterval = 0.8,
    maximumDuration: TimeInterval = 60,
    postProcessor: VoiceTranscriptPostProcessor? = nil
) {
    self.speechProvider = speechProvider
    self.recordingService = recordingService ?? VoiceRecordingService()
    self.minimumDuration = minimumDuration
    self.maximumDuration = maximumDuration
    self.postProcessor = postProcessor
    ...
}
```

Add helper methods:

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

private func prepareTranscript(_ text: String) {
    originalTranscript = text
    summaryTranscript = nil
    summaryNotice = nil
    transcriptDisplayMode = .original

    guard let postProcessor else {
        editableTranscript = text
        state = .transcriptReady(text)
        return
    }

    state = .summarizing(text)
    startSummary(for: text, processor: postProcessor)
}

private func startSummary(for text: String, processor: VoiceTranscriptPostProcessor) {
    summaryTask?.cancel()
    summaryTask = Task { [weak self] in
        guard let self else { return }
        do {
            let summary = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await processor.process(text)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw VoiceInputError.serverMessage("智能总结超时")
                }
                let value = try await group.next() ?? ""
                group.cancelAll()
                return value
            }

            guard !Task.isCancelled else { return }
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                self.fallbackToOriginalAfterSummaryFailure(text, notice: "智能总结失败，已保留原文")
                return
            }

            self.summaryTranscript = trimmed
            self.editableTranscript = trimmed
            self.transcriptDisplayMode = .summary
            self.summaryNotice = self.qualityNotice(original: text, summary: trimmed)
            self.state = .transcriptReady(trimmed)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? VoiceInputError) == .serverMessage("智能总结超时")
                ? "智能总结超时，已保留原文"
                : "智能总结失败，已保留原文"
            self.fallbackToOriginalAfterSummaryFailure(text, notice: message)
        }
    }
}

private func fallbackToOriginalAfterSummaryFailure(_ text: String, notice: String) {
    summaryTranscript = nil
    editableTranscript = text
    transcriptDisplayMode = .original
    summaryNotice = notice
    state = .transcriptReady(text)
}

private func qualityNotice(original: String, summary: String) -> String? {
    guard !original.isEmpty else { return nil }
    if summary.count < max(1, original.count / 10) {
        return "总结较原文大幅缩短，可查看原文确认"
    }
    if summary.count > Int(Double(original.count) * 1.5) {
        return "总结内容较原文更长，建议查看原文对比"
    }
    return nil
}

private func cancelSummary() {
    summaryTask?.cancel()
    summaryTask = nil
}
```

In both transcription success paths, replace:

```swift
self.editableTranscript = text
self.state = .transcriptReady(text)
```

with:

```swift
self.prepareTranscript(text)
```

In `startRecording()`, `cancel()`, `reRecord()`, and `cleanupAfterDismiss()`, call:

```swift
cancelSummary()
originalTranscript = nil
summaryTranscript = nil
summaryNotice = nil
transcriptDisplayMode = .original
```

- [ ] **Step 4: Update switches for `.summarizing`**

Update all `switch viewModel.state` use sites in `VoiceInputSheet.swift` and tests to include `.summarizing`. Minimum expected behavior:

```swift
case .summarizing:
    return "正在智能总结"
```

For loading:

```swift
isLoading: viewModel.state == .transcribing || {
    if case .summarizing = viewModel.state { return true }
    return false
}()
```

- [ ] **Step 5: Run ViewModel tests**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoloTests/VoiceInputViewModelTests test
```

Expected: PASS.

- [ ] **Step 6: Commit ViewModel state**

Run:

```bash
git add "Holo/Holo APP/Holo/Holo/Views/Chat/Voice/VoiceInputViewModel.swift" "Holo/Holo APP/Holo/HoloTests/Services/Speech/VoiceInputViewModelTests.swift"
git commit -m "feat(iOS): summarize voice transcripts in view model"
```

---

### Task 4: Voice Sheet UI And Thought Editor Integration

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/Voice/VoiceInputSheet.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Thoughts/ThoughtEditorView.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Views/Thoughts/ThoughtVoiceTranscriptInsertionTests.swift`

- [ ] **Step 1: Add insertion regression tests**

In `ThoughtVoiceTranscriptInsertionTests.swift`, add:

```swift
func testInsertionUsesFinalEditableSummaryText() {
    let result = ThoughtVoiceTranscriptInsertion.makeInsertionText(
        transcript: "我觉得版本节奏应该更聚焦",
        currentContent: "今天的判断：",
        selectedRange: NSRange(location: 6, length: 0)
    )

    XCTAssertEqual(result, "我觉得版本节奏应该更聚焦")
}

func testInsertionUsesFinalEditableOriginalTextAfterRestore() {
    let result = ThoughtVoiceTranscriptInsertion.makeInsertionText(
        transcript: "嗯我觉得这个版本先不要塞太多",
        currentContent: "",
        selectedRange: NSRange(location: 0, length: 0)
    )

    XCTAssertEqual(result, "嗯我觉得这个版本先不要塞太多")
}
```

- [ ] **Step 2: Run insertion tests**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoloTests/ThoughtVoiceTranscriptInsertionTests test
```

Expected: PASS; this verifies existing insertion behavior remains compatible.

- [ ] **Step 3: Add VoiceResultConfig and summarizing UI**

In `VoiceInputSheet.swift`, add near the top:

```swift
struct VoiceResultConfig {
    var title: String = "识别结果"
    var subtitle: String? = nil
    var showsOriginalToggle: Bool = false
}
```

Add property and initializer parameter:

```swift
let resultConfig: VoiceResultConfig

init(
    speechProvider: SpeechRecognitionProvider = MockSpeechRecognitionProvider(),
    recordingService: VoiceRecordingServiceProviding? = nil,
    maximumDuration: TimeInterval = 60,
    readySubtitle: String = "确认后再发送给 HoloAI",
    submitButtonTitle: String = "发送",
    resultConfig: VoiceResultConfig = VoiceResultConfig(),
    postProcessor: VoiceTranscriptPostProcessor? = nil,
    onSendTranscript: @escaping (String) -> Void
) {
    _viewModel = StateObject(
        wrappedValue: VoiceInputViewModel(
            speechProvider: speechProvider,
            recordingService: recordingService,
            maximumDuration: maximumDuration,
            postProcessor: postProcessor
        )
    )
    self.readySubtitle = readySubtitle
    self.submitButtonTitle = submitButtonTitle
    self.resultConfig = resultConfig
    self.onSendTranscript = onSendTranscript
}
```

In `content`, add:

```swift
case .summarizing:
    VStack(spacing: 16) {
        ProgressView()
            .tint(.holoPrimary)
        Button("重录") {
            VoiceInputHaptics.selection()
            viewModel.reRecord()
        }
        .buttonStyle(VoiceSecondaryButtonStyle())
    }
```

Update title/subtitle:

```swift
case .summarizing:
    return "正在智能总结"
case .transcriptReady:
    return resultConfig.title
```

```swift
case .summarizing:
    return "正在整理成更适合观点记录的表达"
case .transcriptReady:
    return viewModel.summaryNotice ?? resultConfig.subtitle ?? readySubtitle
```

In `transcriptEditor`, add toggle button when enabled:

```swift
if resultConfig.showsOriginalToggle,
   viewModel.originalTranscript != nil,
   viewModel.summaryTranscript != nil {
    Button(viewModel.transcriptDisplayMode == .summary ? "查看原文" : "还原总结") {
        VoiceInputHaptics.selection()
        if viewModel.transcriptDisplayMode == .summary {
            viewModel.showOriginalTranscript()
        } else {
            viewModel.restoreSummaryTranscript()
        }
    }
    .buttonStyle(VoiceSecondaryButtonStyle())
}
```

- [ ] **Step 4: Add Thought smart-summary preference and toggle UI**

In `ThoughtEditorView.swift`, add state and constants:

```swift
@State private var isSmartSummaryEnabled: Bool = Self.defaultSmartSummaryEnabled

private static let smartSummaryUserDefaultsKey = "com.holo.thought.voice.smartSummary.enabled"
private static var defaultSmartSummaryEnabled: Bool {
    if UserDefaults.standard.object(forKey: smartSummaryUserDefaultsKey) == nil {
        return true
    }
    return UserDefaults.standard.bool(forKey: smartSummaryUserDefaultsKey)
}
```

Add toggle view beside the mic button:

```swift
private var smartSummaryToggle: some View {
    Button {
        isSmartSummaryEnabled.toggle()
        UserDefaults.standard.set(isSmartSummaryEnabled, forKey: Self.smartSummaryUserDefaultsKey)
        HapticManager.selection()
    } label: {
        HStack(spacing: 6) {
            Circle()
                .fill(isSmartSummaryEnabled ? Color.holoSuccess : Color.holoTextSecondary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text("智能总结")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSmartSummaryEnabled ? .holoPrimary : .holoTextSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.holoCardBackground.opacity(0.92))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(Color.holoBorder, lineWidth: 1)
        )
    }
    .accessibilityLabel("智能总结")
    .accessibilityValue(isSmartSummaryEnabled ? "已开启" : "已关闭")
}
```

Place it near `voiceInputButton`:

```swift
HStack(spacing: 10) {
    smartSummaryToggle
    voiceInputButton
}
.padding(.trailing, 18)
.padding(.bottom, 18)
```

- [ ] **Step 5: Inject processor into Thought VoiceInputSheet**

Update the sheet creation:

```swift
VoiceInputSheet(
    speechProvider: SpeechRecognitionProviderFactory.makeConfiguredProvider(),
    maximumDuration: 300,
    readySubtitle: "确认后插入到观点内容",
    submitButtonTitle: "插入",
    resultConfig: VoiceResultConfig(
        title: isSmartSummaryEnabled ? "智能总结完成" : "识别结果",
        subtitle: isSmartSummaryEnabled ? "已整理成更适合观点记录的表达" : "确认后插入到观点内容",
        showsOriginalToggle: isSmartSummaryEnabled
    ),
    postProcessor: isSmartSummaryEnabled ? ThoughtVoiceSummaryProcessor() : nil
) { transcript in
    pendingVoiceTranscriptToInsert = transcript
    showVoiceInput = false
}
```

In `.onAppear`, refresh preference:

```swift
isSmartSummaryEnabled = Self.defaultSmartSummaryEnabled
```

- [ ] **Step 6: Build iOS UI changes**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit UI integration**

Run:

```bash
git add "Holo/Holo APP/Holo/Holo/Views/Chat/Voice/VoiceInputSheet.swift" "Holo/Holo APP/Holo/Holo/Views/Thoughts/ThoughtEditorView.swift" "Holo/Holo APP/Holo/HoloTests/Views/Thoughts/ThoughtVoiceTranscriptInsertionTests.swift"
git commit -m "feat(iOS): add thought voice smart summary UI"
```

---

### Task 5: Final Verification And Documentation

**Files:**
- Modify: `CHANGELOG.md`
- Verify: full iOS and backend test suites

- [ ] **Step 1: Add changelog entry**

In `CHANGELOG.md`, add under the latest unreleased section:

```markdown
- 新增观点模块语音「智能总结」：默认开启，可关闭并记住偏好；录音完成后自动整理成顺畅观点文本，并支持查看/还原 ASR 原文。
```

- [ ] **Step 2: Run backend tests**

Run:

```bash
npm test --prefix HoloBackend
```

Expected: PASS.

- [ ] **Step 3: Run focused iOS tests**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoloTests/VoiceInputViewModelTests -only-testing:HoloTests/ThoughtVoiceTranscriptInsertionTests test
```

Expected: PASS.

- [ ] **Step 4: Run full iOS test suite**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Expected: PASS. If unrelated tests fail, capture the failure names and logs before deciding whether to fix or report.

- [ ] **Step 5: Manual smoke test in simulator**

Use the app manually:

1. Open Thought editor.
2. Confirm the mic area shows 「智能总结」 enabled by default.
3. Tap mic, speak a short thought, finish.
4. Confirm result page title is 「智能总结完成」.
5. Confirm text is summary output.
6. Tap 「查看原文」 and confirm ASR original appears.
7. Tap 「还原总结」 and confirm summary returns.
8. Close and reopen Thought editor, toggle smart summary off, record again.
9. Confirm result page uses ASR original and no original/summary toggle is shown.

- [ ] **Step 6: Commit docs/changelog and verification notes**

Run:

```bash
git add CHANGELOG.md
git commit -m "docs: record thought voice smart summary change"
```

- [ ] **Step 7: Final status check**

Run:

```bash
git status --short
git log --oneline -5
```

Expected: only unrelated pre-existing files remain dirty; recent commits include the four feature commits from this plan.

---

## Self-Review Checklist

- Spec goal covered: default-on Thought voice smart summary with user preference.
- Original/summary switching covered: ViewModel owns `originalTranscript`, `summaryTranscript`, `editableTranscript`.
- Failure fallback covered: summary failures return ASR original with `summaryNotice`.
- Backend covered: route, prompt registry, tests, logs.
- Non-goals preserved: no Core Data schema change, no global voice summary rollout, no ASR endpoint coupling.
- Verification covered: backend tests, focused iOS tests, full iOS tests, manual simulator smoke.
