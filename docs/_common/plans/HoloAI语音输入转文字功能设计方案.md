# HoloAI 语音输入转文字功能设计方案

> 日期：2026-05-11（v2 — 工程评审修订版）
> 范围：HoloAI 聊天输入区新增语音输入能力
> 决策组合：录完后识别、确认后发送、底部半屏卡片、真实声波、暂停续录、独立 SpeechRecognitionProvider、临时音频文件、MVP 第一版

## 1. 背景与目标

HoloAI 当前主要通过文本输入理解用户意图，并进一步完成记账、任务、习惯、健康记录、查询分析等动作。语音输入转文字能力的目标，是给用户新增一种更自然、更低摩擦的输入方式：用户可以直接说出"今天午饭花了 32 元""明天提醒我交房租""分析我四月份的账单"等自然语言，由系统先识别成文本，再交给现有 HoloAI 文本理解链路处理。

第一版不追求实时语音助手，也不做自动执行。语音能力只负责把音频稳定地转换成文本，用户确认后再发送。这样既能复用现有 `ChatViewModel.sendMessage()`、`ConversationCoordinator`、`AIProvider`、卡片化消息等成熟链路，也能避免语音误识别直接触发真实数据写入。

### 1.1 产品目标

- 在 HoloAI 输入框旁增加语音按钮。
- 点击后唤起底部语音输入卡片。
- 录音中显示真实音量驱动的声波和计时。
- 支持暂停、继续、取消、完成录音。
- 完成后上传临时音频文件进行语音识别。
- 识别完成后展示可编辑确认卡片。
- 用户确认后再发送给 HoloAI。

### 1.2 非目标

- 第一版不做实时转写。
- 第一版不做语音唤醒词。
- 第一版不保存历史语音文件。
- 第一版不支持多轮语音对话模式。
- 第一版不自动发送识别结果。
- 第一版不做离线语音识别。

## 2. 用户体验方案

### 2.1 入口

在 `ChatInputView` 的输入框旁增加麦克风按钮。推荐位置是输入框右侧、发送按钮左侧：

```text
[ 输入消息...                         ] [mic] [send/stop]
```

原因：

- 不破坏现有输入框和发送按钮的主要位置。
- 麦克风按钮与输入框语义接近，表示"另一种输入方式"。
- 发送按钮继续保留最右侧，避免用户误把语音按钮当作发送。

当 `ChatViewModel.isStreaming == true` 时，语音按钮应禁用或隐藏。因为此时 HoloAI 正在生成结果，继续录音会让输入状态和停止生成状态混在一起。

**已有组件**：项目中 `VoiceAssistantButton.swift`（Components/）是纯视觉组件（渐变圆 + mic 图标 + 发光环），目前用在首页。聊天输入栏的 mic 按钮风格应与之一致（使用相同的 SF Symbol `mic.circle.fill`），但不需要发光动画——输入栏按钮应保持简洁，与发送按钮视觉权重对等。

### 2.2 底部语音卡片

点击麦克风按钮后，从底部弹出半屏语音输入卡片。使用 `presentationDetent` 控制高度，与项目中 20+ 个已有的半屏 sheet 保持一致。

卡片以当前聊天页为背景，不跳出 HoloAI 语境。

录音中状态：

```text
┌──────────────────────────────┐
│            正在聆听           │
│             00:08            │
│                              │
│      ▁▃▆█▆▃▂▁▂▅█▇▃▁          │
│                              │
│   取消        暂停        完成 │
└──────────────────────────────┘
```

暂停状态：

```text
┌──────────────────────────────┐
│            已暂停             │
│             00:14            │
│                              │
│      ▁▃▆█▆▃▂▁▂▅█▇▃▁          │
│                              │
│   取消        继续        完成 │
└──────────────────────────────┘
```

识别中状态：

```text
┌──────────────────────────────┐
│            正在识别           │
│         正在整理你的语音       │
│                              │
│      ▁▂▃▅▇▅▃▂▁▂▃▅▇▅          │
│                              │
│             取消              │
└──────────────────────────────┘
```

确认状态（内嵌可编辑文本，不需要独立 View 文件）：

```text
┌──────────────────────────────┐
│          识别结果             │
│ ┌──────────────────────────┐ │
│ │ 今天午饭花了 32 元        │ │
│ └──────────────────────────┘ │
│                              │
│       重录             发送   │
└──────────────────────────────┘
```

### 2.3 文案

推荐文案：

| 场景 | 文案 |
| --- | --- |
| 麦克风权限请求前 | 需要使用麦克风来记录你的语音 |
| 录音中标题 | 正在聆听 |
| 暂停标题 | 已暂停 |
| 录音被中断（来电等） | 录音被中断，点击继续或完成 |
| 识别中标题 | 正在识别 |
| 识别中说明 | 正在整理你的语音 |
| 识别为空 | 没听清楚，可以再说一次 |
| 录音过短 | 说得有点短，可以再试一次 |
| 网络失败 | 识别失败，请检查网络后重试 |
| 权限拒绝 | 麦克风权限未开启 |

### 2.4 确认后发送

识别完成后不自动发送，而是进入确认态。确认态文本可编辑。用户点击"发送"后：

1. 将识别文本暂存到 `pendingVoiceTranscriptToSend`。
2. 关闭语音卡片。
3. 在 sheet 的 `onDismiss` 回调中确认存在待发送语音文本，再写入 `ChatViewModel.inputText` 并调用 `ChatViewModel.sendMessage()`。

这样保证语音输入与手动文本输入在 HoloAI 后续链路中完全一致。

使用 `onDismiss` 而非 `Task.yield()` 来串联关闭和发送。`onDismiss` 在 sheet 完成消失动画后由 SwiftUI 确保调用，时序可靠。

注意：不能用 `viewModel.inputText.isEmpty` 作为是否发送的判断条件。用户可能在打开语音 sheet 前已经手动输入了文本，如果下滑关闭 sheet，此时 `inputText` 非空但并不代表确认了语音发送，会造成误发送。必须使用专门的待发送标记。

推荐实现：

```swift
// ChatView 中
@State private var pendingVoiceTranscriptToSend: String?

.sheet(isPresented: $isVoiceInputPresented, onDismiss: {
    guard let transcript = pendingVoiceTranscriptToSend?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !transcript.isEmpty else {
        pendingVoiceTranscriptToSend = nil
        return
    }

    pendingVoiceTranscriptToSend = nil
    viewModel.inputText = transcript
    Task { await viewModel.sendMessage() }
}) {
    VoiceInputSheet { transcript in
        pendingVoiceTranscriptToSend = transcript
        isVoiceInputPresented = false  // 触发 onDismiss
    }
}
```

用户通过下滑手势关闭 sheet 时，`pendingVoiceTranscriptToSend == nil`，不会触发发送。

### 2.5 失败态卡片

识别失败不应直接关闭卡片。失败态需要给用户明确恢复路径：

```text
┌──────────────────────────────┐
│          识别失败             │
│      识别失败，请检查网络后重试 │
│                              │
│      取消      重录      重试识别 │
└──────────────────────────────┘
```

按钮语义：

| 按钮 | 行为 |
| --- | --- |
| 取消 | 关闭 sheet，删除临时音频文件 |
| 重录 | 删除旧临时文件，重新开始录音 |
| 重试识别 | 保留当前音频文件，再次调用 `SpeechRecognitionProvider.transcribe` |

如果失败原因是录音过短或识别为空，则不展示"重试识别"，只保留"重录"和"取消"。因为这类错误通常不是网络或服务端临时失败，重复上传同一段音频价值不高。

## 3. 技术架构

### 3.1 总体架构

```text
┌─────────────┐    tap     ┌──────────────────┐
│ ChatInputView│──────────►│   ChatView       │
│   [mic]      │           │ .sheet(...)      │
└─────────────┘           └───────┬──────────┘
                                  │ presents
                                  ▼
                    ┌──────────────────────────┐
                    │    VoiceInputSheet       │
                    │  ┌────────────────────┐  │
                    │  │ VoiceInputViewModel│  │
                    │  │   - state machine  │  │
                    │  │   - speechProvider │  │
                    │  └───────┬────────────┘  │
                    │          │               │
                    │    ┌─────┴─────┐         │
                    │    ▼           ▼         │
                    │ Recording   SpeechRec-   │
                    │  Service    ognitionProv. │
                    │    │           │         │
                    │    ▼           ▼         │
                    │ tmp/xxx.m4a  Remote API  │
                    └──────────────────────────┘
                                  │ onSendTranscript
                                  ▼
                    ChatViewModel.inputText
                                  │
                                  ▼ onDismiss
                    ChatViewModel.sendMessage()
```

### 3.2 模块拆分

新增 6 个文件（已合并可复用的部分）：

```text
Holo/Services/Speech/
├── SpeechRecognitionProvider.swift    ← 协议 + Result 类型 + Error 枚举
├── RemoteSpeechRecognitionProvider.swift
└── VoiceRecordingService.swift       ← 录音 + 临时文件管理（合并了 TemporaryAudioFileStore）

Holo/Views/Chat/Voice/
├── VoiceInputSheet.swift             ← 包含确认态编辑（合并了 VoiceTranscriptEditorView）
├── VoiceInputViewModel.swift
└── RecordingWaveformView.swift       ← 内部自管 metering，不冒泡到 ViewModel
```

修改：

```text
Holo/Views/Chat/ChatInputView.swift   ← 新增 mic 按钮 + onVoiceInputTap 回调
Holo/Views/Chat/ChatView.swift        ← 新增 ChatSheet 枚举统一管理弹层
Info.plist                            ← NSMicrophoneUsageDescription
```

可选修改（Phase 3）：

```text
Holo/Services/AI/AIConfiguration.swift ← 仅在语音 API Key 需要复用 AI 设置页时
```

**合并理由**：

- `TemporaryAudioFileStore` 只做两件事（生成临时路径 + 删除文件），一个 struct 内的 2 个方法就够，不值得独立文件。合并进 `VoiceRecordingService`。
- `VoiceTranscriptEditorView` 的确认态就是一个 `TextField` + 两个按钮，放在 `VoiceInputSheet` 内按 `VoiceInputState` 分支渲染即可。
- `MockSpeechRecognitionProvider` 默认放在测试 target 中，不进主工程。若 SwiftUI Preview 或 Debug 手动演示需要，也可以用 `#if DEBUG` 提供一个仅 Debug 可见的 mock 实现，但不能进入 Release 行为路径。

### 3.3 Sheet 归属 — 统一枚举管理

`ChatView` 当前已挂 4 个 sheet/cover（AI 设置、交易编辑、日志查看、分析详情）。再加语音 sheet 会到 5 个，SwiftUI 多 `.sheet` 的冲突风险在 iOS 16/17 上已知。

建议引入 `enum ChatSheet` 统一管理，但要把它视为一次真实重构，而不是零成本改动。`ChatView` 当前已经管理 AI 设置、交易编辑、日志查看、分析详情等弹层，统一 sheet 会触碰这些现有路径。实施时应单独提交或至少单独验证，避免把语音功能 bug 和弹层重构 bug 混在一起。

目标形态：

```swift
enum ChatSheet: Identifiable {
    case aiSettings
    case editTransaction(Transaction)
    case viewLog(String)
    case analysisDetail(AnalysisMessage)
    case voiceInput

    var id: String {
        switch self {
        case .aiSettings: return "aiSettings"
        case .editTransaction: return "editTransaction"
        case .viewLog: return "viewLog"
        case .analysisDetail: return "analysisDetail"
        case .voiceInput: return "voiceInput"
        }
    }
}
```

`ChatView` 中只保留一个 `.sheet(item:)`：

```swift
@State private var activeSheet: ChatSheet?
@State private var pendingVoiceTranscriptToSend: String?

.sheet(item: $activeSheet) { sheet in
    switch sheet {
    case .voiceInput:
        VoiceInputSheet { transcript in
            pendingVoiceTranscriptToSend = transcript
            activeSheet = nil  // 触发 onDismiss
        }
    // ... 其他 case
    }
} onDismiss: {
    guard let transcript = pendingVoiceTranscriptToSend?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !transcript.isEmpty else {
        pendingVoiceTranscriptToSend = nil
        return
    }

    pendingVoiceTranscriptToSend = nil
    viewModel.inputText = transcript
    Task { await viewModel.sendMessage() }
}
```

注意：`onDismiss` 只在 sheet 确实被 dismiss 时触发（包括 `activeSheet = nil` 和用户下滑关闭）。必须用 `pendingVoiceTranscriptToSend` 区分"确认发送后关闭"和"用户主动关闭"，不要用 `inputText` 非空判断。

### 3.4 与现有 VoiceAssistantButton 的关系

`VoiceAssistantButton.swift`（Components/）是纯视觉组件，用在首页。聊天输入栏的 mic 按钮不复用这个组件（因为它带发光动画，不适合输入栏），但视觉风格保持一致：

- 使用相同 SF Symbol：`mic.circle.fill`
- 颜色跟随 `ChatInputView` 现有按钮色（secondary/symbol）
- 不做发光动画

## 4. 核心协议设计

### 4.1 SpeechRecognitionProvider

语音识别独立于现有 `AIProvider`。原因是文本意图理解和音频转写是两个不同能力，生命周期、输入格式、错误处理、供应商选择都不同。

```swift
protocol SpeechRecognitionProvider {
    func transcribe(
        audioFileURL: URL,
        locale: String?
    ) async throws -> SpeechRecognitionResult
}
```

### 4.2 SpeechRecognitionResult

```swift
struct SpeechRecognitionResult {
    let text: String
    let duration: TimeInterval?
    let confidence: Double?
}
```

字段说明：

| 字段 | 说明 |
| --- | --- |
| `text` | 识别出的文本，必须有值才进入确认态 |
| `duration` | 服务端返回的音频时长，可选 |
| `confidence` | 服务端置信度，可选 |

移除了 `rawResponse: Data?` 字段。Debug 阶段用 Console 日志输出原始响应即可，不需要在数据模型里保留。

### 4.3 Provider 实现

`RemoteSpeechRecognitionProvider` 负责真实 API 请求。由于 API 细节待用户提供，先预留三类兼容能力：

- `multipart/form-data` 上传音频文件。
- `application/json` + base64 音频。
- 直接二进制上传。

### 4.4 Provider 注入策略

MVP 阶段先采用构造函数注入：

```swift
@MainActor
final class VoiceInputViewModel: ObservableObject {
    private let speechProvider: SpeechRecognitionProvider
    private let recordingService: VoiceRecordingService

    init(
        speechProvider: SpeechRecognitionProvider,
        recordingService: VoiceRecordingService = VoiceRecordingService()
    ) {
        self.speechProvider = speechProvider
        self.recordingService = recordingService
    }
}
```

Phase 1 和 Phase 2 使用 mock provider 完成 UI 与状态机闭环。Phase 3 拿到真实 API 后，再决定是否复用现有 AI 设置页。

## 5. 录音服务设计

### 5.1 VoiceRecordingService

职责：

- 保存和恢复原始 AVAudioSession 配置。
- 请求和检查麦克风权限。
- 创建临时音频文件（合并了 TemporaryAudioFileStore）。
- 开始录音。
- 暂停录音。
- 继续录音。
- 完成录音。
- 取消录音并删除文件。
- 监听音频中断和前后台切换，自动暂停。

临时文件管理（合并自 TemporaryAudioFileStore）：

```swift
struct VoiceRecordingService {
    private let fileManager = FileManager.default

    func createTempFileURL() -> URL {
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("holo-voice-input", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).m4a")
    }

    func deleteTempFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    /// 惰性清理历史临时音频，在首次录音时调用，不在 App 启动时做
    func cleanupStaleTempFiles() {
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("holo-voice-input", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }
}
```

建议使用 `AVAudioRecorder`。MVP 不需要直接上 `AVAudioEngine`，因为当前选择是录完后识别，`AVAudioRecorder` 对暂停/继续和 metering 足够。

### 5.2 AVAudioSession 策略

录音前必须显式配置 `AVAudioSession`。关键：**保存原始配置，录音结束后恢复**。

```swift
private var savedCategory: AVAudioSession.Category?
private var savedOptions: AVAudioSession.CategoryOptions?
private var savedMode: AVAudioSession.Mode?

func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    // 保存原始配置
    savedCategory = session.category
    savedOptions = session.categoryOptions
    savedMode = session.mode

    try session.setCategory(
        .playAndRecord,
        mode: .spokenAudio,
        options: [.defaultToSpeaker, .allowBluetooth]
    )
    try session.setActive(true)
}

func restoreAudioSession() {
    let session = AVAudioSession.sharedInstance()
    if let category = savedCategory {
        try? session.setCategory(category, mode: savedMode ?? .default, options: savedOptions ?? [])
    }
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
    savedCategory = nil
    savedOptions = nil
    savedMode = nil
}
```

选择理由：

- `.playAndRecord` 兼容录音期间可能存在的系统音频路由。
- `.spokenAudio` 更符合语音输入场景。
- `.defaultToSpeaker` 避免录音结束或 UI 提示时走听筒。
- `.allowBluetooth` 支持蓝牙耳机麦克风。
- **保存/恢复原始配置**，不破坏 App 其他模块可能的音频使用。

不要在 View 里直接操作 `AVAudioSession`，全部封装在 `VoiceRecordingService` 内。

### 5.3 音频格式

录音格式设计为可配置（不硬编码 m4a），等 API 确认后再定默认值：

```swift
struct VoiceRecordingConfiguration {
    let fileExtension: String       // 默认 "m4a"，API 要求 wav 时改为 "wav"
    let codec: String?             // 对应 AVAudioRecorder 的 AVFormatIDKey
    let sampleRate: Double         // 默认 16000
    let channels: UInt32           // 默认 1
    let quality: AVAudioQuality    // 默认 .medium

    static let `default` = VoiceRecordingConfiguration(
        fileExtension: "m4a",
        codec: nil,  // nil = 使用系统默认（AAC for m4a）
        sampleRate: 16000,
        channels: 1,
        quality: .medium
    )
}
```

`VoiceRecordingService` 的 `init` 接受 `configuration` 参数。MVP 用 `.default`，Phase 3 接入真实 API 时按需调整。

明确风险：部分语音识别 API 只接受 wav、pcm 或固定 16k mono。可配置设计让 Phase 1/2 不需要返工，只需改 configuration。

### 5.4 声波数据

**关键设计：metering 的刷新节奏和波形渲染都在 `RecordingWaveformView` 内部完成，不通过 `@Published` 冒泡到 ViewModel。**

`RecordingWaveformView` 接受的绑定：

```swift
struct RecordingWaveformView: View {
    let isRecording: Bool       // 控制采样开始/停止
    let isFrozen: Bool          // 暂停时冻结波形
    let isLoading: Bool         // 识别中显示 loading 动画波形
}
```

`RecordingWaveformView` 不直接持有或操作 `AVAudioRecorder`。录音器仍由 `VoiceRecordingService` 持有，波形视图只在内部定时调用 service 暴露的只读方法获取当前音量。这样既避免 ViewModel 高频刷新，也避免把底层音频对象泄漏到 View 层。

```swift
// VoiceRecordingService
func currentPowerLevel() -> Float {
    recorder?.updateMeters()
    return recorder?.averagePower(forChannel: 0) ?? -160
}

// RecordingWaveformView 内部定时采样
func samplePowerLevel() {
    let power = recordingService.currentPowerLevel()
    let normalized = max(0, min(1, (power + 60) / 60))
    samples.append(normalized)
    if samples.count > 35 { samples.removeFirst() }
}
```

这样 ViewModel 不会被 metering 数据高频更新（10-20次/秒），SwiftUI re-render 范围限定在波形视图内部，同时 `AVAudioRecorder` 的生命周期仍由 service 管理。

### 5.5 音频中断处理

监听 `AVAudioSession.interruptionNotification`，中断时自动暂停：

```swift
func observeInterruptions() {
    NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: nil,
        queue: .main
    ) { [weak self] notification in
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // 中断开始：暂停录音，通知 ViewModel
            self?.pauseDueToInterruption()
        case .ended:
            // 中断结束：不自动恢复，等用户操作
            break
        @unknown default:
            break
        }
    }
}
```

ViewModel 收到中断通知后进入 `interrupted` 状态（见状态机 6.1），UI 显示"录音被中断，点击继续或完成"。

### 5.6 前后台切换处理

监听 `scenePhase` 变化，进入后台时自动暂停：

```swift
// VoiceInputViewModel 中
func handleScenePhaseChange(_ newPhase: ScenePhase) {
    switch newPhase {
    case .background:
        if state == .recording {
            pauseRecording(reason: .backgroundTransition)
        }
    case .active:
        // 不自动恢复，等用户操作
        break
    default:
        break
    }
}
```

在 `VoiceInputSheet` 中注入 `@Environment(\.scenePhase)`，变化时通知 ViewModel。

## 6. 状态机

### 6.1 VoiceInputState

```swift
enum VoiceInputState: Equatable {
    case idle
    case requestingPermission
    case recording
    case paused
    case interrupted      // 新增：音频中断（来电、闹钟等）
    case transcribing
    case transcriptReady(String)
    case failed(VoiceInputError)
}

enum VoiceInputError: Equatable {
    case microphonePermissionDenied
    case recordingTooShort
    case recordingFailed(String)
    case transcriptionTimedOut
    case emptyTranscript
    case networkFailure
    case interrupted      // 新增：中断导致失败（可选，中断≠失败）
    case serverMessage(String)
}
```

### 6.2 状态流转

| 当前状态 | 用户动作/系统事件 | 下一状态 |
| --- | --- | --- |
| `idle` | 点击麦克风 | `requestingPermission` |
| `idle` | 点击麦克风（权限已有） | `recording` |
| `requestingPermission` | 权限通过并开始录音 | `recording` |
| `requestingPermission` | 权限拒绝 | `failed(.microphonePermissionDenied)` |
| `recording` | 点击暂停 | `paused` |
| `recording` | 音频中断（来电等） | `interrupted` |
| `recording` | 进入后台 | `paused` |
| `paused` | 点击继续 | `recording` |
| `interrupted` | 点击继续 | `recording` |
| `interrupted` | 点击完成 | `transcribing` |
| `recording` | 点击完成且时长有效 | `transcribing` |
| `paused` | 点击完成且时长有效 | `transcribing` |
| `recording` / `paused` | 录音 >= 60 秒 | 自动完成 → `transcribing` |
| `recording` / `paused` | 点击取消 | `idle` |
| `transcribing` | 识别成功且文本非空 | `transcriptReady` |
| `transcribing` | 识别失败（网络） | `failed(.networkFailure)` |
| `transcribing` | 识别失败（超时） | `failed(.transcriptionTimedOut)` |
| `transcribing` | 识别成功但文本为空 | `failed(.emptyTranscript)` |
| `transcriptReady` | 点击发送 | 关闭 sheet，触发 onDismiss → sendMessage |
| `transcriptReady` | 点击重录 | `recording` |
| `failed(.networkFailure)` | 点击重试识别 | `transcribing` |
| `failed` | 点击重录 | `recording` |
| 任意状态 | sheet 被关闭（下滑/取消） | 清理临时资源并回到 `idle` |

### 6.3 并发与取消

`VoiceInputViewModel` 持有的异步任务：

```swift
private var transcriptionTask: Task<Void, Never>?
```

注意：metering 任务在 `RecordingWaveformView` 内部管理（见 5.4），不在 ViewModel 层。计时任务也类似，可以用 `Timer.publish` 或 `CADisplayLink` 在 View 层驱动，ViewModel 只暴露 `recordingDuration: TimeInterval` 供 View 读取。

取消规则：

| 场景 | 必须取消 |
| --- | --- |
| 点击取消 | transcriptionTask |
| sheet 关闭 | transcriptionTask + 清理录音器 + 恢复 audio session |
| 识别中点击取消 | transcriptionTask |
| 重录 | 旧 transcriptionTask + 删除旧临时文件 |

所有 async 回写 UI 状态前检查取消：

```swift
guard !Task.isCancelled else { return }
```

如果网络请求已返回但 sheet 已关闭（`activeSheet` 不再是 `.voiceInput`），不允许再把状态写回。通过 ViewModel 的 `deinit` 或 `reset()` 取消所有任务。

### 6.4 时长规则

- 最短录音：0.8 秒。低于此值进入 `failed(.recordingTooShort)`，不调 API。
- 最长录音：60 秒。超过自动完成并进入 `transcribing`。
- 暂停期间不计入录音时长（`AVAudioRecorder.currentTime` 自动处理）。

### 6.5 locale 传递

MVP 不增加独立的语言设置，使用设备当前语言：

```swift
var currentLocale: String {
    Locale.current.language.languageCode?.identifier ?? "zh"
}
```

传给 `SpeechRecognitionProvider.transcribe(locale:)`。如果后续需要支持指定语言（如用户用日语说话但设备是中文），再扩展为用户可配置项。

## 7. Chat 集成方案

### 7.1 ChatInputView

`ChatInputView` 新增：

- 语音按钮。
- `onVoiceInputTap` 回调（不持有 sheet 状态）。
- 当 `viewModel.isStreaming` 为 `true` 时禁用语音按钮。

```swift
struct ChatInputView: View {
    @ObservedObject var viewModel: ChatViewModel
    let onVoiceInputTap: () -> Void

    var body: some View {
        HStack {
            // ... 现有 TextField
            Button {
                onVoiceInputTap()
            } label: {
                Image(systemName: "mic.circle.fill")
            }
            .disabled(viewModel.isStreaming)
            // ... 现有 send/stop 按钮
        }
    }
}
```

### 7.2 ChatView 统一 Sheet 管理

```swift
// ChatView 中
@State private var activeSheet: ChatSheet?

// ChatInputView 回调
ChatInputView(
    viewModel: viewModel,
    onVoiceInputTap: { activeSheet = .voiceInput }
)

// 统一 sheet
.sheet(item: $activeSheet) { sheet in
    switch sheet {
    case .voiceInput:
        VoiceInputSheet(
            speechProvider: speechProvider,  // 从环境或依赖容器传入
            onSendTranscript: { transcript in
                pendingVoiceTranscriptToSend = transcript
                activeSheet = nil
            }
        )
    // ... 其他 case
    }
} onDismiss: {
    guard let transcript = pendingVoiceTranscriptToSend?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !transcript.isEmpty else {
        pendingVoiceTranscriptToSend = nil
        return
    }

    pendingVoiceTranscriptToSend = nil
    viewModel.inputText = transcript
    Task { await viewModel.sendMessage() }
}
```

### 7.3 发送时序保证

用户点"发送"：
1. `VoiceInputSheet.onSendTranscript` 写入 `pendingVoiceTranscriptToSend` 并设 `activeSheet = nil`
2. Sheet 开始 dismiss 动画
3. 动画完成后 SwiftUI 调用 `onDismiss`
4. `onDismiss` 中检查 `pendingVoiceTranscriptToSend` 非空，再写入 `inputText` 并调用 `sendMessage()`

这比 `Task.yield()` 更可靠，因为 `onDismiss` 的时序由 SwiftUI 框架保证。

不要把“`inputText` 非空”作为发送条件。`inputText` 属于聊天输入框全局状态，可能来自用户手动输入、预填文本或其他入口，不等价于“语音确认发送”。

## 8. 权限、隐私与存储

### 8.1 Info.plist

新增：

```text
NSMicrophoneUsageDescription = Holo 需要使用麦克风来记录你的语音输入。
```

暂不需要 `NSSpeechRecognitionUsageDescription`，因为第一版不使用 Apple Speech Framework。

### 8.2 临时文件

临时文件路径：`tmp/holo-voice-input/<uuid>.<ext>`

删除规则：

| 场景 | 删除策略 |
| --- | --- |
| 用户取消 | 立即删除 |
| 识别成功并发送 | 立即删除 |
| 识别成功但重录 | 删除旧文件 |
| 识别失败 | 暂时保留，允许重试 |
| sheet 关闭 | 删除 |
| 首次录音时 | 惰性清理历史临时文件（不在 App 启动时） |

### 8.3 隐私原则

- 不长期保存用户原始音频。
- Debug 日志不输出完整识别文本和音频路径，除非本地调试明确需要。

## 9. 错误处理

| 错误 | 用户表现 | 技术处理 |
| --- | --- | --- |
| 麦克风权限拒绝 | 显示权限提示和去设置入口 | 不创建录音器 |
| 录音过短（<0.8s） | 提示"说得有点短" | 删除临时文件，允许重录 |
| 录音器初始化失败 | 提示"暂时无法录音" | 记录错误，不进入录音态 |
| 音频中断（来电等） | 提示"录音被中断" | 自动暂停，用户可继续或完成 |
| 前后台切换 | 无提示（自动暂停） | 进入后台自动暂停 |
| 网络失败 | 提示"识别失败，请检查网络后重试" | 保留音频，允许重试 |
| API 超时 | 提示"识别超时" | 取消请求，允许重试 |
| 识别为空 | 提示"没听清楚" | 允许重录 |
| 用户取消 | 关闭 sheet | 取消任务、删除临时文件、恢复 audio session |

## 10. API 接入预留

待用户提供 API 后，需要补齐：

- Endpoint。
- 鉴权方式。
- 请求格式。
- 音频字段名。
- 支持音频格式。
- 最大文件大小。
- 超时时间。
- 响应 JSON schema。
- 错误码含义。

Provider 预期形态：

```swift
final class RemoteSpeechRecognitionProvider: SpeechRecognitionProvider {
    private let config: VoiceRecognitionAPIConfig

    func transcribe(
        audioFileURL: URL,
        locale: String?
    ) async throws -> SpeechRecognitionResult {
        // 1. 构造请求
        // 2. 上传音频
        // 3. 解析响应
        // 4. 映射错误
    }
}
```

错误类型：

```swift
enum SpeechRecognitionError: LocalizedError {
    case transcriptionTimedOut
    case emptyTranscript
    case networkFailure
    case serverMessage(String)
}
```

注意：录音阶段的错误（权限、录音器失败、录音过短）由 `VoiceRecordingService` 和 `VoiceInputViewModel` 直接处理，不经过 `SpeechRecognitionError`。只有识别 API 调用阶段的错误走这个枚举。

## 11. 测试计划

### 11.1 覆盖图

```
CODE PATHS                                              TEST COVERAGE
[+] VoiceInputViewModel 状态机
  ├── startRecording()
  │   ├── [TEST]  权限已有 → recording
  │   ├── [TEST]  权限拒绝 → failed(.microphonePermissionDenied)
  │   └── [TEST]  录音器初始化失败 → failed(.recordingFailed)
  ├── pauseRecording()
  │   ├── [TEST]  recording → paused
  │   └── [TEST]  后台切换 → paused
  ├── resumeRecording()
  │   └── [TEST]  paused → recording
  ├── handleInterruption()
  │   ├── [TEST]  recording → interrupted
  │   └── [TEST]  interrupted → 点击继续 → recording
  ├── stopRecording()
  │   ├── [TEST]  时长 < 0.8s → failed(.recordingTooShort)
  │   ├── [TEST]  时长 >= 0.8s → transcribing
  │   └── [TEST]  时长 >= 60s 自动完成 → transcribing
  ├── transcribe()
  │   ├── [TEST]  成功 + 文本非空 → transcriptReady
  │   ├── [TEST]  成功 + 文本为空 → failed(.emptyTranscript)
  │   ├── [TEST]  网络错误 → failed(.networkFailure)
  │   └── [TEST]  超时 → failed(.transcriptionTimedOut)
  ├── sendTranscript()
  │   ├── [TEST]  写入 inputText + 设 activeSheet = nil
  │   └── [TEST]  空文本不触发发送
  ├── cancel()
  │   ├── [TEST]  取消 transcription task
  │   └── [TEST]  删除临时文件 + 恢复 audio session
  ├── reRecord()
  │   └── [TEST]  删除旧文件 → recording
  └── retryTranscription()
      └── [TEST]  保留音频文件 → transcribing

[+] VoiceRecordingService
  ├── [TEST]  临时文件路径正确
  ├── [TEST]  删除临时文件
  └── [TEST]  惰性清理历史文件

[+] 并发安全
  ├── [TEST]  Sheet 关闭时 transcription 还在跑 → task 被取消
  └── [TEST]  快速连续点击 mic → 状态不混乱

USER FLOWS
  ├── [TEST]  完整路径：录音 → 识别 → 确认 → 发送
  ├── [TEST]  录音 → 取消 → 再录音
  ├── [TEST]  识别失败 → 重试识别 → 成功
  ├── [TEST]  识别失败 → 重录 → 识别 → 发送
  ├── [TEST]  isStreaming=true 时 mic 按钮禁用
  ├── [TEST]  确认态编辑文本后发送
  └── [MANUAL]  真机：来电中断 → 继续 → 完成

TARGET: 覆盖上述 28 条路径。实际覆盖率以测试实现和 CI 结果为准，不在设计阶段宣称已达到 100%。
```

### 11.2 单元测试文件

```text
HoloTests/Services/Speech/
├── VoiceInputViewModelTests.swift    ← 状态机 + 所有状态流转
├── VoiceRecordingServiceTests.swift  ← 临时文件管理
└── MockSpeechRecognitionProvider.swift ← 测试专用 mock
```

### 11.3 手动真机验证

模拟器对麦克风和音频 session 的行为不完全可靠，必须真机验证：

- 第一次点击麦克风权限弹窗。
- 录音中声波随声音变化。
- 暂停后计时和声波停止。
- 继续后计时和声波恢复。
- 来电/闹钟中断后正确暂停并可恢复。
- 前后台切换后正确暂停。
- 完成后能上传识别。
- 识别文本可编辑。
- 点击发送后进入现有 HoloAI 消息链路。
- 取消/关闭后再次打开可以正常录音。
- 60 秒自动完成触发正确。
- 深色模式显示正常。

### 11.4 UI 验收

- 语音按钮在 `isStreaming == true` 时禁用或隐藏。
- 录音卡片在小屏设备上不遮挡关键按钮。
- 识别结果编辑框支持多行文本。
- 识别结果为空时不能发送。
- 失败态区分"重试识别"和"重录"。
- 深色模式下声波、按钮、输入框对比度足够。
- 动态字体放大后按钮文案不互相挤压。
- 键盘弹出编辑识别文本时，确认按钮仍可触达。

## 12. 实施计划

### Phase 1：录音与 UI 闭环

- 新增 `VoiceInputSheet`。
- 新增 `RecordingWaveformView`（含内部 metering）。
- 新增 `VoiceInputViewModel`。
- 新增 `VoiceRecordingService`（含临时文件管理 + 中断监听）。
- 重构 `ChatView` 的 sheet 为 `ChatSheet` 枚举。
- 在 `ChatInputView` 增加麦克风入口。
- 新增麦克风权限文案。

验收标准：

- 可以打开语音卡片。
- 真机上可以录音。
- 声波随声音变化。
- 暂停、继续、取消、完成可用。
- 来电中断后正确暂停。
- 前后台切换后正确暂停。

### Phase 2：Mock 识别与确认卡片

- 新增 `SpeechRecognitionProvider` 协议。
- 新增 `MockSpeechRecognitionProvider`（测试 target）。
- 完成后进入识别中，再展示固定识别文本。
- 确认文本可编辑（在 VoiceInputSheet 内按状态分支渲染）。
- 点击发送后通过 onDismiss 复用 `ChatViewModel.sendMessage()`。

验收标准：

- 无真实 API 时也能完成端到端交互。
- 发送后与手动输入行为一致。

### Phase 3：真实 API 接入

- 根据用户提供 API 实现 `RemoteSpeechRecognitionProvider`。
- 确认音频格式要求，调整 `VoiceRecordingConfiguration`。
- 支持真实音频上传。
- 完成响应解析和错误映射。
- 增加超时和重试策略。

验收标准：

- 真机录音后可得到真实识别文本。
- 网络错误、空文本、超时均有可理解提示。

### Phase 4：体验打磨

- 优化动画、触感反馈（录音开始/结束/暂停加 Haptic）、按钮状态。
- 优化最长录音自动完成。
- 深浅色适配。
- 补充 CHANGELOG。

验收标准：

- 交互无卡顿。
- 临时文件无泄漏。
- 视觉风格与 HoloAI 当前聊天界面一致。

## 13. 架构决策记录

### ADR-001：语音识别独立于 AIProvider

决定：新增 `SpeechRecognitionProvider`，不把语音转写塞入现有 `AIProvider`。

原因：

- `AIProvider` 当前职责是文本理解、批处理解析、聊天流式生成。
- 语音转写输入是音频文件，错误类型和网络请求形式不同。
- 独立协议便于替换供应商，也便于 Mock 测试。

代价：

- 新增一组服务文件和配置入口。
- 如果供应商与文本大模型相同，会有少量配置复用问题。

### ADR-002：识别完成后确认，不自动发送

决定：识别完成后展示可编辑确认卡片，用户点击发送后才进入 HoloAI。

原因：

- HoloAI 可能触发真实写入动作，例如记账、建任务、打卡。
- 语音识别存在误差，自动发送会放大误操作风险。
- 确认卡片提供编辑和重录，容错更好。

代价：

- 比自动发送多一步操作。

### ADR-003：MVP 不做实时转写

决定：第一版采用录完后一次性上传识别。

原因：

- 实时转写需要处理流式音频、局部结果、断句、取消和合并。
- 当前目标是尽快形成稳定闭环。
- 录完后识别足以覆盖大部分 HoloAI 快速输入场景。

代价：

- 用户不能边说边看到文字。
- 长句识别反馈会稍慢。

### ADR-004：波形 metering 内聚在 View 层

决定：metering 的刷新节奏和波形渲染都在 `RecordingWaveformView` 内部完成，不通过 `@Published` 冒泡到 ViewModel；但 `AVAudioRecorder` 生命周期仍归 `VoiceRecordingService` 管理，View 只通过只读方法获取当前音量。

原因：

- metering 10-20 次/秒的频率如果走 `@Published`，每次都会触发 VoiceInputSheet 全体 re-render。
- 波形数据只用于绘制，ViewModel 不需要关心。
- View 不直接持有 recorder，避免底层音频对象泄漏到 UI 层。
- 内聚后 re-render 范围限定在波形视图内部，性能更好。

### ADR-005：ChatView sheet 统一枚举管理

决定：引入 `ChatSheet` 枚举统一管理 `ChatView` 弹层，但实施时把它视为独立重构风险点，需要单独验证现有 AI 设置、交易编辑、日志查看、分析详情路径。

原因：

- ChatView 已有 4 个 sheet/cover，再加 1 个到 5 个。
- SwiftUI 多 `.sheet` 在 iOS 16/17 有已知冲突 bug。
- 枚举收敛可以消除一整类 sheet 冲突 bug。
- 代价是会触碰现有弹层路径，不能和语音主流程混在一起无验证地提交。

### ADR-006：录音格式可配置

决定：`VoiceRecordingService` 通过 `VoiceRecordingConfiguration` 接受录音格式参数，不硬编码 m4a。

原因：

- API 支持的音频格式尚未确定。
- 硬编码 m4a 可能导致 Phase 1/2 的录音在 Phase 3 需要返工。
- 可配置设计零额外成本（一个 struct 参数），但消除了返工风险。

## 14. 待 API 提供后补充

拿到 API 后需要更新本文档：

- 请求示例。
- 响应示例。
- 错误码映射表。
- 音频格式最终参数（更新 `VoiceRecordingConfiguration.default`）。
- 鉴权配置位置。
- 超时与重试策略。
- 是否需要音频转码。
- 服务端是否支持中文标点、数字规范化和中英混合识别。

## 15. 第一版完成定义

第一版完成必须满足：

- 语音按钮出现在 HoloAI 输入区。
- 底部语音卡片可录音、暂停、继续、取消、完成。
- 声波由真实麦克风音量驱动（metering 内聚在 View 层）。
- 来电/闹钟中断时自动暂停，可恢复。
- 前后台切换时自动暂停。
- 音频只保存为临时文件。
- 录音 60 秒自动完成。
- 识别完成后展示可编辑文本确认态。
- 用户确认后通过 onDismiss 复用现有 HoloAI 文本发送链路。
- 取消、失败、关闭时能正确清理资源（临时文件 + audio session 恢复）。
- 真机验证通过。
