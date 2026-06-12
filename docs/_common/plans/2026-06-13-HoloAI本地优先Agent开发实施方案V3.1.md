# HoloAI 本地优先 Agent V3.1 开发实施方案

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 把 V3 的 Local-first Full Agent 架构落成一条可开发、可测试、可灰度的工程路线，让 HoloAI 从浅摘要升级为基于本地证据、多轮工具调用、可恢复任务和本地校验的可信洞察能力。

**Architecture:** V3.1 采纳 GLM 对抗性审查的关键修正：保留完整 Agent 能力，但将 `agent_planner` / `agent_reasoner` 合并为单一 `agent_loop` purpose；Agent 编排、工具执行、Evidence Ledger、Checkpoint、Verifier、Critic、Memory Curator 均在 iOS 本地执行。后端只做无状态 LLM 网关、prompt 管理和 Agent JSON 响应校验，不保存用户完整生活数据库。

**Tech Stack:** Swift / SwiftUI / Codable JSON Store / XCTest / Core Data 读取层 / HoloBackend Node.js Hono / OpenAI-compatible Chat Completions / Node test runner。

---

## 0. 最终 Gate 结论

本方案对 V3 的结论是 **Conditional Go**。

可以进入开发：

- Phase 0：旧记忆止血、feature flag、debug 导出、V3.1 schema 固化。
- Phase 1：Agent Job / Checkpoint / Result Store / mock runtime。
- Phase 2：Tool Registry / Evidence Ledger / 首批本地工具骨架。

暂不直接全量上线：

- 真正用户可见的 Deep Agent 入口。
- Observer Tier 2 自动触发。
- 记忆长廊正式改用 Agent Result。
- 后端 agent purpose 生产生效。

原因：V3 方向正确，但 GLM 审查指出的 Agent Loop 内部协议缺口必须先补齐，否则 Phase 3 会卡在多轮恢复、工具错误、JSON 格式和 planner/reasoner 切换上。

---

## 1. 本方案采纳的关键决策

### 1.1 采用 `agent_loop`，不拆 `agent_planner` / `agent_reasoner`

V3 原文计划新增两个 purpose：

- `agent_planner`
- `agent_reasoner`

V3.1 改为一个 purpose：

```text
agent_loop
```

理由：

- Agent 每一轮都需要同时具备规划和推理能力。
- 两个 purpose 会让 iOS 端承担“这一轮该调谁”的复杂状态判断。
- 两个 prompt 容易出现 Planner 说够了、Reasoner 又说不够的循环。
- 一个 `agent_loop` 通过 `status` 字段表达下一步，既保留 Agent 自主性，又减少后端和 iOS 协议面。

### 1.2 不依赖 background URLSession 承接 LLM 请求

V3 曾提到非流式 LLM 请求可尝试交给 background URLSession。V3.1 不把它作为 MVP 依赖。

MVP 策略：

```text
App 退后台
-> beginBackgroundTask 争取短时收尾
-> 当前 step 如果能完成则保存结果
-> LLM 请求未返回则取消并保存 checkpoint
-> 前台恢复后用 conversationState 重试同一请求
```

这比后台 URLSession 简单、可控，也符合 HoloBackend 无状态的事实。

### 1.3 LLM 中断后只重试，不查询结果

后端目前不保存 LLM 响应、没有 request result 查询 API，因此恢复时不能“查询上次请求结果”。

恢复原则：

```text
LLM 请求中断 = 使用 checkpoint 中的 conversationState 重试
工具执行中断 = 跳过已完成 toolRequestID，重跑未完成工具
写入中断 = 用 dedupeKey / idempotent ID 重试
```

### 1.4 Pattern Miner 是本地规则引擎，不是 Agent 降级

Pattern Miner 负责从工具输出里确定性生成趋势信号，例如：

- frequency_change
- goal_conflict
- streak_break
- amount_shift
- time_distribution_shift
- category_concentration
- backlog_pressure

它不替代 Agent，只给 LLM 更干净的证据输入。LLM 仍决定是否继续查工具、如何组织 claims、哪些结论值得解释。

### 1.5 Phase 0/1 不接用户主入口

前两个阶段只允许 mock job / debug 入口验证，不改变现有 HoloAI 对话和记忆长廊用户链路。

这样做是为了避免半成品 Agent 污染现有聊天、记忆候选和长期记忆。

---

## 2. 当前代码事实

### 2.1 iOS 可复用模块

- `Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift`
  - 已有非流式 `chat(messages:purpose:)` 能力。
  - `HoloBackendPurpose` 目前没有 `agent_loop`。
- `Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift`
  - 已有 prompt 类型、版本和 UserDefaults 自定义机制。
  - 目前没有 `agent_loop` prompt type。
- `Holo/Holo APP/Holo/Holo/Models/AI/HoloAICapability.swift`
  - `HoloMemorySettings` 和 `HoloAIFeatureFlags` 是现有 AI/记忆开关入口。
- `Holo/Holo APP/Holo/Holo/Services/AI/HoloLongTermMemoryStore.swift`
  - 已有长期记忆 JSON Store，可复用其原子写入、损坏回退思路。
- `Holo/Holo APP/Holo/Holo/Services/AI/HoloEpisodicMemoryStore.swift`
  - 已有短期情景记忆 Store、过期清理、suppression rule。
- `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/`
  - 已有 planner / executor / structured model 的模式，可参考结构化 JSON 解析和本地执行边界。
- `Holo/Holo APP/Holo/Holo/Services/AI/MemorySignals/`
  - 已有 `HabitMemorySignalBuilder`、`GoalMemorySignalBuilder`，可迁移部分趋势规则。
- `Holo/Holo APP/Holo/Holo/Services/AI/MemoryObserver/`
  - 已有 observer response parser / validator / applier，可参考 schema validation。

### 2.2 后端现状

- `HoloBackend/src/config.js`
  - routes 里目前有 `chat`、`intent`、`insight`、`memory_observer` 等，没有 `agent_loop`。
- `HoloBackend/src/app.js`
  - 目前只按 purpose 找 route，再透传给 provider。
  - 没有 agent 专用 JSON schema 校验。
- `HoloBackend/src/providers/openAICompatibleProvider.js`
  - 只透传 `messages`、`temperature`、`max_tokens`、`response_format`、`stream`。
  - 不支持原生 tool calling；V3.1 使用 Holo 自定义 JSON tool protocol。
- `HoloBackend/src/prompts/defaultPrompts.json`
  - 没有 `agent_loop` prompt。

### 2.3 测试现状

- iOS 测试目录：`Holo/Holo APP/Holo/HoloTests/`
- 现有相关测试：
  - `Models/AI/HoloLongTermMemoryStoreTests.swift`
  - `Models/AI/HoloEpisodicMemoryStoreTests.swift`
  - `Models/AI/MemoryObserverOutputValidatorTests.swift`
  - `Services/AI/AIUserContextMessageBuilderStandaloneTests.swift`
- 后端测试目录：`HoloBackend/tests/`
- 后端测试命令：`npm test`
- iOS 当前可稳定用 build 验证；历史记录显示 scheme 的 test action 可能不可用，所以本方案要求新增 XCTest，但最终验证仍以 `xcodebuild build` 为硬门槛。

### 2.4 Xcode 工程注意

`Holo.xcodeproj` 使用 `PBXFileSystemSynchronizedRootGroup`，新 Swift 文件通常不需要手动改 `project.pbxproj`。如果后续编译发现新文件没有进入 target，再补 project 配置。

---

## 3. 目标目录与文件布局

### 3.1 iOS 新增目录

```text
Holo/Holo APP/Holo/Holo/Models/AI/Agent/
Holo/Holo APP/Holo/Holo/Services/AI/Agent/
Holo/Holo APP/Holo/Holo/Services/AI/Agent/Persistence/
Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/
Holo/Holo APP/Holo/Holo/Services/AI/Agent/PatternMining/
Holo/Holo APP/Holo/Holo/Services/AI/Agent/Verification/
Holo/Holo APP/Holo/Holo/Services/AI/Agent/Presentation/
```

### 3.2 iOS 新增测试目录

```text
Holo/Holo APP/Holo/HoloTests/Models/AI/Agent/
Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/
```

### 3.3 后端新增或修改文件

```text
HoloBackend/src/config.js
HoloBackend/src/app.js
HoloBackend/src/prompts/defaultPrompts.json
HoloBackend/tests/chat.test.js
HoloBackend/tests/prompts.test.js
```

如果 agent 校验逻辑变复杂，可以新增：

```text
HoloBackend/src/agentResponseValidator.js
HoloBackend/tests/agent-response-validator.test.js
```

---

## 4. V3.1 核心 Schema

### 4.1 Agent Job

文件：

```text
Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentJobModels.swift
```

目标模型：

```swift
import Foundation

enum HoloAgentJobType: String, Codable, CaseIterable, Sendable {
    case deepAnalysis
    case memoryGallerySummary
    case observerInspection
    case memoryCuration
    case debugMock
}

enum HoloAgentTrigger: String, Codable, CaseIterable, Sendable {
    case userQuestion
    case memoryGalleryRefresh
    case observerTier2
    case debug
}

enum HoloAgentJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case waitingForLLM
    case retrying
    case waitingForForeground
    case paused
    case completed
    case failed
    case cancelled
}

enum HoloAgentStep: String, Codable, CaseIterable, Sendable {
    case plan
    case executeTools
    case minePatterns
    case integrateResults
    case continueOrConclude
    case verifyClaims
    case critique
    case curateMemory
    case render
    case persistResult
}

struct HoloAgentJob: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var type: HoloAgentJobType
    var userQuestion: String?
    var trigger: HoloAgentTrigger
    var state: HoloAgentJobState
    var currentStep: HoloAgentStep
    var createdAt: Date
    var updatedAt: Date
    var lastForegroundRunAt: Date?
    var timeRange: HoloAgentTimeRange?
    var budget: HoloAgentBudget
    var checkpointID: String?
    var resultID: String?
    var errorSummary: String?
    var deviceID: String?
}
```

### 4.2 Budget

同文件：

```swift
struct HoloAgentBudget: Codable, Equatable, Sendable {
    var maxLLMRounds: Int
    var maxToolBatches: Int
    var maxInputTokens: Int
    var maxOutputTokens: Int
    var maxWallTimeSeconds: Int
    var consumedLLMRounds: Int
    var consumedToolBatches: Int
    var consumedInputTokens: Int
    var consumedOutputTokens: Int
    var startedAt: Date
    var updatedAt: Date

    var isExhausted: Bool {
        consumedLLMRounds >= maxLLMRounds ||
        consumedToolBatches >= maxToolBatches ||
        consumedInputTokens >= maxInputTokens ||
        consumedOutputTokens >= maxOutputTokens ||
        Date().timeIntervalSince(startedAt) >= TimeInterval(maxWallTimeSeconds)
    }
}

extension HoloAgentBudget {
    static func normalDeep(now: Date = Date()) -> HoloAgentBudget {
        HoloAgentBudget(
            maxLLMRounds: 3,
            maxToolBatches: 3,
            maxInputTokens: 10_000,
            maxOutputTokens: 4_000,
            maxWallTimeSeconds: 120,
            consumedLLMRounds: 0,
            consumedToolBatches: 0,
            consumedInputTokens: 0,
            consumedOutputTokens: 0,
            startedAt: now,
            updatedAt: now
        )
    }

    static func extendedDeep(now: Date = Date()) -> HoloAgentBudget {
        HoloAgentBudget(
            maxLLMRounds: 5,
            maxToolBatches: 5,
            maxInputTokens: 20_000,
            maxOutputTokens: 8_000,
            maxWallTimeSeconds: 300,
            consumedLLMRounds: 0,
            consumedToolBatches: 0,
            consumedInputTokens: 0,
            consumedOutputTokens: 0,
            startedAt: now,
            updatedAt: now
        )
    }

    static func observerFollowUp(now: Date = Date()) -> HoloAgentBudget {
        HoloAgentBudget(
            maxLLMRounds: 2,
            maxToolBatches: 2,
            maxInputTokens: 6_000,
            maxOutputTokens: 2_000,
            maxWallTimeSeconds: 60,
            consumedLLMRounds: 0,
            consumedToolBatches: 0,
            consumedInputTokens: 0,
            consumedOutputTokens: 0,
            startedAt: now,
            updatedAt: now
        )
    }
}
```

### 4.3 Agent Message / Checkpoint

文件：

```text
Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentCheckpointModels.swift
```

目标模型：

```swift
import Foundation

enum HoloAgentMessageRole: String, Codable, CaseIterable, Sendable {
    case system
    case user
    case assistant
    case toolResult
}

struct HoloAgentMessage: Codable, Equatable, Sendable {
    var role: HoloAgentMessageRole
    var content: String
    var toolRequestID: String?
    var toolName: String?
    var timestamp: Date
    var tokenEstimate: Int?
}

struct HoloAgentCheckpoint: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var jobID: String
    var step: HoloAgentStep
    var completedSteps: [HoloAgentStep]
    var conversationState: [HoloAgentMessage]
    var pendingToolRequests: [HoloToolRequest]
    var completedToolResults: [HoloDataToolResult]
    var patternSignals: [HoloPatternSignal]
    var evidenceRecordIDs: [String]
    var validatedClaimIDs: [String]
    var memoryCandidateIDs: [String]
    var retryCountByStep: [String: Int]
    var createdAt: Date
    var updatedAt: Date
}
```

`llmRequestID` 不进入 MVP，因为后端无状态，无法查询请求结果。

### 4.4 Tool Protocol

文件：

```text
Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentToolModels.swift
```

目标模型：

```swift
import Foundation

struct HoloToolRequest: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var tool: String
    var query: String
    var timeRange: HoloAgentTimeRange?
    var baseline: HoloAgentTimeRange?
    var requiredMetrics: [String]
    var parameters: [String: String]
}

enum HoloToolResultStatus: String, Codable, CaseIterable, Sendable {
    case success
    case empty
    case partial
    case error
    case unavailable
    case timeout
}

struct HoloToolError: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var recoverable: Bool
}

struct HoloDataToolResult: Codable, Equatable, Sendable {
    var toolRequestID: String
    var tool: String
    var status: HoloToolResultStatus
    var coverage: HoloDataCoverage?
    var metrics: [HoloMetric]
    var events: [HoloEvidenceEvent]
    var warnings: [HoloToolWarning]
    var error: HoloToolError?
}
```

### 4.5 Evidence Ledger

文件：

```text
Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloEvidenceModels.swift
```

目标模型：

```swift
import Foundation

enum HoloEvidenceSourceModule: String, Codable, CaseIterable, Sendable {
    case finance
    case habit
    case task
    case goal
    case thought
    case health
    case memory
    case profile
    case agent
}

enum HoloEvidenceStatus: String, Codable, CaseIterable, Sendable {
    case active
    case partial
    case orphaned
    case archived
}

enum HoloEvidenceSensitivity: String, Codable, CaseIterable, Sendable {
    case normal
    case highImpact
    case sensitive
}

struct HoloEvidenceRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var dedupeKey: String
    var sourceModule: HoloEvidenceSourceModule
    var sourceID: String?
    var sourceKind: String
    var timeRange: HoloAgentTimeRange?
    var occurredAt: Date?
    var metricKey: String
    var metricValue: Double?
    var unit: String?
    var baselineValue: Double?
    var comparison: String?
    var excerpt: String
    var redactedExcerpt: String
    var sensitivity: HoloEvidenceSensitivity
    var confidence: Double
    var status: HoloEvidenceStatus
    var generatedBy: String
    var generatedAt: Date
    var referencedByJobIDs: [String]
    var referencedByMemoryIDs: [String]
    var deviceID: String?
}
```

### 4.6 Agent Output

文件：

```text
Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentOutputModels.swift
```

目标模型：

```swift
import Foundation

enum HoloAgentOutputStatus: String, Codable, CaseIterable, Sendable {
    case needTools = "need_tools"
    case needMoreAnalysis = "need_more_analysis"
    case finalClaims = "final_claims"
}

struct HoloAgentOutput: Codable, Equatable, Sendable {
    var status: HoloAgentOutputStatus
    var reasoning: String
    var toolRequests: [HoloToolRequest]
    var claims: [HoloAgentClaim]
    var nextStep: String?
    var warnings: [String]
}

struct HoloAgentClaim: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var type: String
    var displayText: String
    var metricAssertions: [HoloMetricAssertion]
    var evidenceIDs: [String]
    var prohibitedInferences: [String]
    var confidence: Double
}

struct HoloMetricAssertion: Codable, Equatable, Sendable {
    var metricKey: String
    var value: Double?
    var baselineValue: Double?
    var unit: String?
    var comparison: String?
    var evidenceIDs: [String]
}
```

### 4.7 Pattern Signal

文件：

```text
Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloPatternModels.swift
```

目标模型：

```swift
import Foundation

enum HoloPatternType: String, Codable, CaseIterable, Sendable {
    case frequencyChange = "frequency_change"
    case goalConflict = "goal_conflict"
    case streakBreak = "streak_break"
    case amountShift = "amount_shift"
    case timeDistributionShift = "time_distribution_shift"
    case categoryConcentration = "category_concentration"
    case backlogPressure = "backlog_pressure"
    case recoverySignal = "recovery_signal"
}

enum HoloPatternSeverity: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case critical
}

struct HoloPatternSignal: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var type: HoloPatternType
    var title: String
    var metricKey: String
    var value: Double?
    var baselineValue: Double?
    var severity: HoloPatternSeverity
    var evidenceIDs: [String]
    var reason: String
    var generatedAt: Date
}
```

### 4.8 Time Range

文件：

```text
Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentTimeRange.swift
```

目标模型：

```swift
import Foundation

struct HoloAgentTimeRange: Codable, Equatable, Sendable {
    var label: String
    var start: Date?
    var end: Date?
}
```

---

## 5. 分阶段实施

## Phase 0：旧记忆止血与 V3.1 开关

目标：不让旧浅摘要继续污染用户信任，同时为 V3.1 地基加 feature flag 和 debug 可观测性。

### Task 0.1：新增 Agent Feature Flags

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Models/AI/HoloAICapability.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/HoloMemorySettingsStandaloneTests.swift`

**Step 1: 写失败测试**

新增断言：

```swift
func testAgentFeatureFlags_默认关闭() {
    let settings = HoloMemorySettings.shared

    XCTAssertFalse(settings.agentRuntimeEnabled)
    XCTAssertFalse(settings.agentDebugModeEnabled)
    XCTAssertFalse(settings.agentMemoryGalleryEnabled)
    XCTAssertFalse(settings.agentObserverTier2Enabled)
    XCTAssertFalse(HoloAIFeatureFlags.agentRuntimeEnabled)
}
```

**Step 2: 运行构建，确认失败**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase0 CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
error: value of type 'HoloMemorySettings' has no member 'agentRuntimeEnabled'
```

**Step 3: 实现最小代码**

在 `HoloMemorySettings.Keys` 增加：

```swift
static let agentRuntimeEnabled = "holo_agent_runtimeEnabled"
static let agentDebugModeEnabled = "holo_agent_debugModeEnabled"
static let agentMemoryGalleryEnabled = "holo_agent_memoryGalleryEnabled"
static let agentObserverTier2Enabled = "holo_agent_observerTier2Enabled"
```

新增 published settings：

```swift
@Published var agentRuntimeEnabled: Bool {
    didSet { defaults.set(agentRuntimeEnabled, forKey: Keys.agentRuntimeEnabled) }
}

@Published var agentDebugModeEnabled: Bool {
    didSet { defaults.set(agentDebugModeEnabled, forKey: Keys.agentDebugModeEnabled) }
}

@Published var agentMemoryGalleryEnabled: Bool {
    didSet { defaults.set(agentMemoryGalleryEnabled, forKey: Keys.agentMemoryGalleryEnabled) }
}

@Published var agentObserverTier2Enabled: Bool {
    didSet { defaults.set(agentObserverTier2Enabled, forKey: Keys.agentObserverTier2Enabled) }
}
```

在 `init()` 默认全部 false。

在 `HoloAIFeatureFlags` 增加：

```swift
static var agentRuntimeEnabled: Bool {
    HoloMemorySettings.shared.agentRuntimeEnabled
}

static var agentDebugModeEnabled: Bool {
    HoloMemorySettings.shared.agentDebugModeEnabled
}

static var agentMemoryGalleryEnabled: Bool {
    HoloMemorySettings.shared.agentMemoryGalleryEnabled
}

static var agentObserverTier2Enabled: Bool {
    HoloMemorySettings.shared.agentObserverTier2Enabled
}
```

**Step 4: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase0 CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Models/AI/HoloAICapability.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/HoloMemorySettingsStandaloneTests.swift"
git commit -m "feat(iOS): add HoloAI agent feature flags"
```

### Task 0.2：旧格式记忆候选标记为 legacy

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/HoloLongTermMemoryCandidateObserver.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/HoloMemoryPromotionPolicy.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Models/AI/HoloLongTermMemoryStoreTests.swift`

**Step 1: 写失败测试**

测试目标：旧 card title 如“任务清零，节奏好转”“任务完成不错，积压仍在”不应进入高优长期候选。

测试可以构造 `HoloLongTermMemory`，验证 promotion policy 对 legacy 标记降权或拒绝。

建议测试名：

```swift
func testLegacyShallowMemoryCandidate_被降权或拒绝()
```

**Step 2: 实现 legacy 判断**

新增 legacy 标记规则：

- title 或 summary 包含以下系统词，且 evidence 数量少于 2，标记为 legacy shallow：
  - 闭环
  - 清零
  - 积压仍在
  - 节奏好转
  - 支出偏高
  - 支出偏低
  - 任务完成不错
- legacy shallow 不进入 `longTermCandidate`。
- legacy shallow 可作为 `displayOnly` 或直接忽略。

**Step 3: 验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase0-legacy CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/HoloLongTermMemoryCandidateObserver.swift" "Holo/Holo APP/Holo/Holo/Services/AI/HoloMemoryPromotionPolicy.swift" "Holo/Holo APP/Holo/HoloTests/Models/AI/HoloLongTermMemoryStoreTests.swift"
git commit -m "fix(iOS): demote legacy shallow memory candidates"
```

### Task 0.3：新增 Agent Debug Export

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentDebugExporter.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentDebugExporterTests.swift`

**Step 1: 写失败测试**

```swift
func testDebugExport_包含MemoryAndAgentSections() throws {
    let export = HoloAgentDebugExporter.makeSnapshot(
        jobs: [],
        checkpoints: [],
        results: [],
        evidence: []
    )

    XCTAssertTrue(export.contains("agentJobs"))
    XCTAssertTrue(export.contains("agentCheckpoints"))
    XCTAssertTrue(export.contains("evidenceLedger"))
    XCTAssertTrue(export.contains("longTermMemoryCount"))
    XCTAssertTrue(export.contains("episodicMemoryCount"))
}
```

**Step 2: 实现 exporter**

输出 JSON string，字段包括：

- `generatedAt`
- `featureFlags`
- `agentJobs`
- `agentCheckpoints`
- `agentResults`
- `evidenceLedger`
- `longTermMemoryCount`
- `episodicMemoryCount`
- `suppressionRuleCount`

**Step 3: 验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase0-debug CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentDebugExporter.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentDebugExporterTests.swift"
git commit -m "feat(iOS): add HoloAI agent debug export"
```

---

## Phase 1：Agent Job / Checkpoint / Result 地基

目标：先让 Agent 任务可创建、可保存、可恢复、可取消。此阶段不接真实 LLM，不接真实用户入口。

### Task 1.1：新增 Agent 基础模型

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentTimeRange.swift`
- Create: `Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentJobModels.swift`
- Create: `Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentToolModels.swift`
- Create: `Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloEvidenceModels.swift`
- Create: `Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloPatternModels.swift`
- Create: `Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentCheckpointModels.swift`
- Create: `Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentOutputModels.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Models/AI/Agent/HoloAgentModelCodableTests.swift`

**Step 1: 写 Codable round-trip 测试**

至少覆盖：

- `HoloAgentJob`
- `HoloAgentCheckpoint`
- `HoloDataToolResult(status: .empty)`
- `HoloEvidenceRecord`
- `HoloAgentOutput(status: .needTools)`
- `HoloPatternSignal`

测试示例：

```swift
func testAgentCheckpoint_CodableRoundTrip() throws {
    let checkpoint = HoloAgentCheckpoint(
        id: "cp-1",
        jobID: "job-1",
        step: .executeTools,
        completedSteps: [.plan],
        conversationState: [
            HoloAgentMessage(
                role: .user,
                content: "我最近是不是状态不太对？",
                toolRequestID: nil,
                toolName: nil,
                timestamp: Date(timeIntervalSince1970: 1_000),
                tokenEstimate: 20
            )
        ],
        pendingToolRequests: [],
        completedToolResults: [],
        patternSignals: [],
        evidenceRecordIDs: ["ev-1"],
        validatedClaimIDs: [],
        memoryCandidateIDs: [],
        retryCountByStep: [:],
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )

    let data = try JSONEncoder().encode(checkpoint)
    let decoded = try JSONDecoder().decode(HoloAgentCheckpoint.self, from: data)

    XCTAssertEqual(decoded.id, checkpoint.id)
    XCTAssertEqual(decoded.step, .executeTools)
    XCTAssertEqual(decoded.conversationState.first?.role, .user)
}
```

**Step 2: 运行构建，确认失败**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase1-models CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
error: cannot find type 'HoloAgentCheckpoint' in scope
```

**Step 3: 实现模型文件**

按第 4 节 schema 创建所有模型。保持：

- `Codable`
- `Equatable`
- `Sendable`
- enum rawValue 使用稳定 snake_case 或 lowerCamelCase。

**Step 4: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase1-models CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Models/AI/Agent" "Holo/Holo APP/Holo/HoloTests/Models/AI/Agent/HoloAgentModelCodableTests.swift"
git commit -m "feat(iOS): add HoloAI agent core models"
```

### Task 1.2：新增 JSON Store 通用基类

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Persistence/HoloAgentJSONStore.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentJSONStoreTests.swift`

**Step 1: 写失败测试**

覆盖：

- 文件不存在返回空数组。
- 保存后可读取。
- 损坏 JSON 备份并返回空数组。
- 原子写入不留下 temp 文件。

**Step 2: 实现 Store**

要求：

- 使用 `Application Support/Holo/Memory/Agent/`。
- JSONEncoder 使用 `.iso8601`。
- JSONDecoder 使用 `.iso8601`。
- 写入使用 temp file + replace。
- 损坏文件备份到 `*.backup.json`。
- Store 使用 `actor` 或串行 queue，V3.1 推荐 `actor`。

参考实现：

```swift
actor HoloAgentJSONStore<Element: Codable> {
    private let fileManager: FileManager
    private let fileURL: URL
    private let backupURL: URL

    init(fileName: String, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo/Memory/Agent", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent(fileName)
        self.backupURL = dir.appendingPathComponent(fileName + ".backup.json")
    }

    func load() async -> [Element] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Element].self, from: data)
        } catch {
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }
            try? fileManager.copyItem(at: fileURL, to: backupURL)
            return []
        }
    }

    func save(_ values: [Element]) async throws {
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(values)

        let tempURL = dir.appendingPathComponent(fileURL.lastPathComponent + ".tmp")
        try data.write(to: tempURL, options: .atomic)
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
    }
}
```

**Step 3: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase1-store CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Persistence/HoloAgentJSONStore.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentJSONStoreTests.swift"
git commit -m "feat(iOS): add reusable agent JSON store"
```

### Task 1.3：新增 Job / Checkpoint / Result Store

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentResultModels.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Persistence/HoloAgentJobStore.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Persistence/HoloAgentCheckpointStore.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Persistence/HoloAgentResultStore.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentPersistenceStoreTests.swift`

**Step 1: 写失败测试**

覆盖：

- `upsert(job)` 后 `load()` 能读到。
- `updateState(jobID,to:)` 更新时间。
- `save(checkpoint)` 后能按 `jobID` 查最新 checkpoint。
- `completed / failed / cancelled` job 可按 retention policy 清理。

**Step 2: 实现模型**

```swift
struct HoloAgentResult: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var jobID: String
    var title: String
    var summary: String
    var claims: [HoloAgentClaim]
    var evidenceIDs: [String]
    var memoryCandidateIDs: [String]
    var status: String
    var generatedAt: Date
    var updatedAt: Date
}

struct HoloJobCleanupPolicy: Codable, Equatable, Sendable {
    var completedRetentionDays: Int = 30
    var failedRetentionDays: Int = 7
    var cascadeCheckpoint: Bool = true
    var cascadeResult: Bool = true
    var preserveReferencedEvidence: Bool = true
}
```

**Step 3: 实现 stores**

文件名：

- `agentJobs.json`
- `agentCheckpoints.json`
- `agentResults.json`

所有写入保持 upsert 语义。

**Step 4: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase1-stores CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Models/AI/Agent/HoloAgentResultModels.swift" "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Persistence" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentPersistenceStoreTests.swift"
git commit -m "feat(iOS): persist HoloAI agent jobs and checkpoints"
```

### Task 1.4：新增 Agent Persistence Manager

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Persistence/HoloAgentPersistenceManager.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentPersistenceManagerTests.swift`

**Step 1: 写失败测试**

测试场景：

- `saveProgress(evidence:checkpoint:)` 先写 evidence，再写 checkpoint。
- checkpoint 引用不存在 evidence 时，`validateCheckpoint` 返回 false。
- orphaned evidence 超过 7 天可被清理。

**Step 2: 实现 Manager**

先定义 protocol，避免 Phase 1 直接依赖 Phase 2 才实现的真实 `HoloEvidenceLedger`：

```swift
protocol HoloEvidenceLedgerProtocol: Sendable {
    func load() async -> [HoloEvidenceRecord]
    func upsert(_ records: [HoloEvidenceRecord]) async throws
}

actor HoloAgentPersistenceManager {
    let evidenceLedger: HoloEvidenceLedgerProtocol
    let checkpointStore: HoloAgentCheckpointStore
    let jobStore: HoloAgentJobStore
    let resultStore: HoloAgentResultStore

    func saveProgress(
        job: HoloAgentJob,
        evidence: [HoloEvidenceRecord],
        checkpoint: HoloAgentCheckpoint
    ) async throws {
        try await evidenceLedger.upsert(evidence)
        try await checkpointStore.upsert(checkpoint)
        try await jobStore.upsert(job)
    }

    func validateCheckpoint(_ checkpoint: HoloAgentCheckpoint) async -> Bool {
        let evidenceIDs = Set(await evidenceLedger.load().map(\.id))
        return checkpoint.evidenceRecordIDs.allSatisfy { evidenceIDs.contains($0) }
    }
}
```

Task 1.4 的测试使用 in-memory mock：

```swift
actor HoloInMemoryEvidenceLedger: HoloEvidenceLedgerProtocol {
    private var records: [HoloEvidenceRecord] = []

    func load() async -> [HoloEvidenceRecord] {
        records
    }

    func upsert(_ records: [HoloEvidenceRecord]) async throws {
        for record in records {
            if let index = self.records.firstIndex(where: { $0.dedupeKey == record.dedupeKey }) {
                self.records[index] = record
            } else {
                self.records.append(record)
            }
        }
    }
}
```

`HoloEvidenceLedger` 在 Phase 2 实现，并 conform `HoloEvidenceLedgerProtocol`。

**Step 3: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase1-manager CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Persistence/HoloAgentPersistenceManager.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentPersistenceManagerTests.swift"
git commit -m "feat(iOS): coordinate agent persistence writes"
```

### Task 1.5：新增 Mock Agent Runtime

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentRuntimeFactory.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloLocalAgentRuntimeTests.swift`

**Step 1: 写失败测试**

覆盖：

- 创建 mock job 后状态从 `queued` 变为 `running`。
- 完成 `plan` step 后写 checkpoint。
- 模拟 app 重启后从 checkpoint 恢复到下一 step。
- cancel 后状态为 `cancelled`，不继续执行。

**Step 2: 实现 runtime 骨架**

```swift
actor HoloLocalAgentRuntime {
    private let persistence: HoloAgentPersistenceManager

    func startMockJob(question: String) async throws -> HoloAgentJob {
        // create job
        // write initial checkpoint
        // simulate plan -> executeTools -> persistResult
    }

    func resume(jobID: String) async throws {
        // load latest checkpoint
        // continue from checkpoint.step
    }

    func cancel(jobID: String) async throws {
        // update job state
    }
}
```

Phase 1 runtime 不调用 LLM，不调用真实 tool，只写 mock messages 和 mock checkpoint。

**Step 3: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase1-runtime CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift" "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentRuntimeFactory.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloLocalAgentRuntimeTests.swift"
git commit -m "feat(iOS): add resumable mock agent runtime"
```

---

## Phase 2：Tool Registry + Evidence Ledger + Pattern Miner

目标：让 Agent 有本地工具协议、证据账本和确定性 pattern 信号。此阶段仍不接真实 LLM。

### Task 2.1：新增 Evidence Ledger

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Persistence/HoloEvidenceLedger.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloEvidenceLedgerTests.swift`

**Step 1: 写失败测试**

覆盖：

- 相同 `dedupeKey` upsert 不重复。
- 新 evidence 会追加。
- `referencedByJobIDs` 合并去重。
- `markOrphaned` 能标记没有引用的 evidence。

**Step 2: 实现 ledger**

文件：

```text
Application Support/Holo/Memory/Agent/evidenceLedger.json
```

核心 API：

```swift
actor HoloEvidenceLedger {
    func load() async -> [HoloEvidenceRecord]
    func upsert(_ records: [HoloEvidenceRecord]) async throws
    func find(ids: [String]) async -> [HoloEvidenceRecord]
    func markOrphaned(olderThan date: Date) async throws
}
```

**Step 3: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase2-ledger CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Persistence/HoloEvidenceLedger.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloEvidenceLedgerTests.swift"
git commit -m "feat(iOS): add HoloAI evidence ledger"
```

### Task 2.2：新增 Tool Registry / Executor

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloDataTool.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloToolRegistry.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloToolExecutor.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloToolRegistryTests.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloToolExecutorTests.swift`

**Step 1: 写失败测试**

覆盖：

- Registry 可以注册工具并生成 prompt 描述。
- 请求不存在工具返回 `.error` + `TOOL_NOT_FOUND`。
- 参数非法返回 `.error` + `INVALID_PARAMS`。
- 工具空结果返回 `.empty`。
- 工具抛错返回 `.error` + recoverable。

**Step 2: 实现协议**

```swift
protocol HoloDataTool: Sendable {
    var descriptor: HoloToolDescriptor { get }
    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult
    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult
}

struct HoloToolDescriptor: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var supportedQueries: [String]
    var supportedTimeRanges: [String]
    var outputMetrics: [String]
    var sensitivityPolicy: String
}

enum HoloToolValidationResult: Equatable, Sendable {
    case valid
    case invalid(reason: String)
}
```

**Step 3: 实现 executor**

Executor 必须统一包装错误，不让 Agent loop 因 throw 直接崩掉。

**Step 4: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase2-tools CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloToolRegistryTests.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloToolExecutorTests.swift"
git commit -m "feat(iOS): add HoloAI local tool registry"
```

### Task 2.3：实现 MemoryTool

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloMemoryTool.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloMemoryToolTests.swift`

**Step 1: 写失败测试**

覆盖：

- 能读取 long-term confirmed memories。
- 能读取 episodic suggested / active memories。
- 能读取 suppression rules 摘要。
- 无记忆时返回 `.empty`。

**Step 2: 实现 MemoryTool**

复用：

- `HoloLongTermMemoryStore`
- `HoloEpisodicMemoryStore`
- `HoloMemorySummaryProvider`

支持 query：

- `recall_summary`
- `suppression_summary`
- `recent_episodic`

输出 metric：

- `memory.long_term.count`
- `memory.episodic.active_count`
- `memory.suppression.active_count`

**Step 3: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase2-memorytool CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloMemoryTool.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloMemoryToolTests.swift"
git commit -m "feat(iOS): add memory tool for local agent"
```

### Task 2.4：实现 HabitTool MVP

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloHabitTool.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloHabitToolTests.swift`

**Step 1: 写失败测试**

覆盖用户最关键 case：

```text
负向习惯最近 3 天发生量：8 -> 12 -> 20
目标：每天不超过 8
```

期望：

- 输出 `habit.negative.frequency_change`
- direction 为 increasing。
- 输出 `habit.negative.goal_conflict_days`
- 不使用“完成更多”之类正向表达。
- evidence 至少包含 3 天记录。

**Step 2: 实现 HabitTool**

首批 query：

- `trend_summary`
- `negative_habit_control`
- `goal_conflict`

首批 metrics：

- `habit.negative.frequency_change`
- `habit.negative.over_limit_days`
- `habit.negative.control_rate`
- `habit.positive.completion_rate`
- `habit.streak_break_days`

复用或迁移：

- `HabitMemorySignalBuilder`
- `MemorySignalDataAdapter`
- 现有 habit repository / stats builder。

**Step 3: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase2-habittool CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloHabitTool.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloHabitToolTests.swift"
git commit -m "feat(iOS): add habit trend tool for local agent"
```

### Task 2.5：实现 FinanceTool MVP

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloFinanceTool.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloFinanceToolTests.swift`

**Step 1: 写失败测试**

覆盖：

- 晚间餐饮频次相对 baseline 增加。
- 分类集中度输出 top category。
- 无财务记录时返回 `.empty`。

示例：

```text
last_14_days 晚间餐饮次数 4
previous_14_days 晚间餐饮次数 1
```

期望 metric：

- `finance.meal.nighttime_count`
- `finance.category.concentration`
- `finance.amount.change`

**Step 2: 实现 FinanceTool**

首批 query：

- `spending_pattern`
- `meal_time_distribution`
- `category_concentration`

复用：

- `FinanceAnalysisContextBuilder`
- `CategoryCandidateResolver` 中已有餐饮子分类时段语义。
- `FlexibleQueryExecutor` 的本地查询思路。

**Step 3: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase2-financetool CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloFinanceTool.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloFinanceToolTests.swift"
git commit -m "feat(iOS): add finance pattern tool for local agent"
```

### Task 2.6：实现 Pattern Miner

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/PatternMining/HoloPatternMiner.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloPatternMinerTests.swift`

**Step 1: 写失败测试**

覆盖：

- `habit.negative.frequency_change` 8 -> 12 -> 20 生成 `.frequencyChange` + `.high`。
- `habit.negative.over_limit_days` > 0 生成 `.goalConflict`。
- `finance.meal.nighttime_count` 4 vs 1 生成 `.timeDistributionShift`。
- 无显著变化时不生成 high pattern。

**Step 2: 实现 Miner**

```swift
struct HoloPatternMiner {
    func mine(toolResults: [HoloDataToolResult]) -> [HoloPatternSignal] {
        // deterministic rules only
    }
}
```

规则：

- 不输出自然语言人生判断。
- 只基于 metrics / evidenceIDs。
- 每条 pattern 必须有 evidenceIDs。
- severity 可由变化幅度和用户目标冲突决定。

**Step 3: 接入 mock runtime**

Mock runtime 从：

```text
executeTools -> integrateResults
```

改为：

```text
executeTools -> minePatterns -> integrateResults
```

**Step 4: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase2-patterns CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/PatternMining/HoloPatternMiner.swift" "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloPatternMinerTests.swift"
git commit -m "feat(iOS): mine deterministic agent pattern signals"
```

---

## Phase 3：Agent Loop LLM 协议

目标：跑通非流式、多轮、可重试的 `agent_loop`，但先只在 debug / internal 入口使用。

### Task 3.1：后端新增 `agent_loop` route 和 prompt

**Files:**

- Modify: `HoloBackend/src/config.js`
- Modify: `HoloBackend/src/prompts/defaultPrompts.json`
- Modify: `HoloBackend/tests/prompts.test.js`
- Modify: `HoloBackend/tests/chat.test.js`

**Step 1: 写失败测试**

在 `prompts.test.js` 中验证：

- `agent_loop` prompt 存在。
- prompt 包含 `need_tools`、`need_more_analysis`、`final_claims`。
- prompt 明确只输出 JSON。

在 `chat.test.js` 中验证：

- purpose `agent_loop` 被接受。
- route config 存在。
- 非流式 JSON 请求能返回 mock JSON。

**Step 2: 修改 config**

在 `routes` 中新增：

```javascript
agent_loop: {
  provider: process.env.HOLO_AGENT_LOOP_PROVIDER ?? process.env.HOLO_CHAT_PROVIDER ?? "mock",
  model: process.env.HOLO_AGENT_LOOP_MODEL ?? process.env.HOLO_CHAT_MODEL ?? "holo-mock",
  temperature: Number(process.env.HOLO_AGENT_LOOP_TEMPERATURE ?? 0.1),
  maxTokens: Number(process.env.HOLO_AGENT_LOOP_MAX_TOKENS ?? 2048),
}
```

**Step 3: 新增 prompt**

`defaultPrompts.json` 新增 `agent_loop`，核心约束：

```text
你是 HoloAI 的本地 Agent Loop 推理器。
你不能直接查询数据，只能请求 iOS 本地工具。
你会收到可用工具描述、用户问题、conversationState、toolResults、patternSignals、evidenceRefs。
你必须只输出 JSON。

status 只能是：
- need_tools
- need_more_analysis
- final_claims

每个 claim 必须有 metricAssertions 和 evidenceIDs。
不得输出没有 evidence 的事实。
不得把相关写成因果。
不得做心理、医疗、人格判断。
```

**Step 4: 跑后端测试**

Run:

```bash
cd HoloBackend
npm test
```

Expected:

```text
pass
```

**Step 5: Commit**

```bash
git add HoloBackend/src/config.js HoloBackend/src/prompts/defaultPrompts.json HoloBackend/tests/prompts.test.js HoloBackend/tests/chat.test.js
git commit -m "feat(backend): add HoloAI agent loop prompt route"
```

**Deployment note:** 这是后端改动。合并后必须部署 HoloBackend，否则生产环境没有 `agent_loop` purpose。

### Task 3.2：后端新增 Agent JSON 校验

**Files:**

- Create: `HoloBackend/src/agentResponseValidator.js`
- Modify: `HoloBackend/src/app.js`
- Create: `HoloBackend/tests/agent-response-validator.test.js`
- Modify: `HoloBackend/tests/chat.test.js`

**Step 1: 写失败测试**

验证：

- 缺少 `status` 返回 validator invalid。
- status 不在枚举内返回 invalid。
- `need_tools` 但 `toolRequests` 不是数组返回 invalid。
- `final_claims` 但 `claims` 不是数组返回 invalid。
- 合法 JSON 返回 valid。

**Step 2: 实现 validator**

```javascript
const AGENT_STATUSES = new Set(["need_tools", "need_more_analysis", "final_claims"]);

export function validateAgentLoopContent(content) {
  let parsed;
  try {
    parsed = JSON.parse(content);
  } catch (error) {
    return { valid: false, error: `Invalid JSON: ${error.message}` };
  }

  if (!AGENT_STATUSES.has(parsed.status)) {
    return { valid: false, error: "Invalid or missing status" };
  }

  if (parsed.status === "need_tools" && !Array.isArray(parsed.toolRequests)) {
    return { valid: false, error: "need_tools requires toolRequests array" };
  }

  if (parsed.status === "final_claims" && !Array.isArray(parsed.claims)) {
    return { valid: false, error: "final_claims requires claims array" };
  }

  return { valid: true, parsed };
}
```

**Step 3: 接入 app.js**

非流式 result 返回前：

```javascript
if (purpose === "agent_loop") {
  const content = result?.choices?.[0]?.message?.content;
  const validation = validateAgentLoopContent(content ?? "");
  if (!validation.valid) {
    throw new GatewayError("INVALID_AGENT_JSON", validation.error, 502);
  }
}
```

**Step 4: 跑测试**

Run:

```bash
cd HoloBackend
npm test
```

Expected:

```text
pass
```

**Step 5: Commit**

```bash
git add HoloBackend/src/app.js HoloBackend/src/agentResponseValidator.js HoloBackend/tests/agent-response-validator.test.js HoloBackend/tests/chat.test.js
git commit -m "feat(backend): validate agent loop JSON responses"
```

**Deployment note:** 这是后端改动。合并后必须部署 HoloBackend。

### Task 3.3：iOS 新增 `agentLoop` purpose 和 prompt type

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/AIUserContextMessageBuilderStandaloneTests.swift`

**Step 1: 写失败测试**

验证：

- `HoloBackendPurpose.agentLoop.rawValue == "agent_loop"`。
- `PromptManager.PromptType.agentLoop.rawValue == "agent_loop"`。
- prompt displayName 是 “Agent Loop” 或中文等价名称。

**Step 2: 修改 purpose**

```swift
enum HoloBackendPurpose: String {
    case chat
    case intent
    case insight
    case thoughtVoiceSummary = "thought_voice_summary"
    case memoryObserver = "memory_observer"
    case financeActionParser = "finance_action_parser"
    case taskActionParser = "task_action_parser"
    case thoughtOrganization = "thought_organization"
    case agentLoop = "agent_loop"
}
```

**Step 3: 修改 PromptManager**

新增：

```swift
case agentLoop = "agent_loop"
```

新增 displayName / description / icon / version / default template。

**Step 4: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase3-purpose CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift" "Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/AIUserContextMessageBuilderStandaloneTests.swift"
git commit -m "feat(iOS): add agent loop backend purpose"
```

### Task 3.4：iOS 新增 Agent LLM Client 和 parser

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentLLMClient.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentResponseParser.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentPromptBuilder.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentResponseParserTests.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentPromptBuilderTests.swift`

**Step 1: 写失败测试**

Parser 覆盖：

- 纯 JSON 解析成功。
- markdown code block 包裹 JSON 解析成功。
- 缺 status 抛出 `outputParseFailure(needsRetry: true)`。
- 超过重试次数后 `needsRetry: false`。

PromptBuilder 覆盖：

- 包含 tool descriptions。
- 包含 redacted evidence。
- 不包含完整 sensitive excerpt。
- 包含 conversationState。

**Step 2: 实现 Parser**

```swift
enum HoloAgentError: Error, Equatable {
    case outputParseFailure(needsRetry: Bool)
    case budgetExhausted
    case cancelled
}

struct HoloAgentResponseParser {
    static func parse(_ raw: String, remainingRetries: Int) throws -> HoloAgentOutput {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let output = try? JSONDecoder().decode(HoloAgentOutput.self, from: data) else {
            throw HoloAgentError.outputParseFailure(needsRetry: remainingRetries > 0)
        }

        return output
    }
}
```

**Step 3: 实现 Client**

Client 使用：

```swift
provider.chat(messages: messages, purpose: .agentLoop)
```

要求：

- 非流式。
- JSON object response format。
- 不走普通聊天 fallback clarification。
- 解析失败只反馈给 Agent Runtime 重试。

**Step 4: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase3-client CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentLLMClient.swift" "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentResponseParser.swift" "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentPromptBuilder.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentResponseParserTests.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentPromptBuilderTests.swift"
git commit -m "feat(iOS): add agent loop LLM client"
```

### Task 3.5：把 Runtime 从 mock loop 升级为多轮 loop

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloLocalAgentRuntimeTests.swift`

**Step 1: 写失败测试**

使用 fake LLM client：

第 1 轮返回：

```json
{"status":"need_tools","reasoning":"需要查习惯","toolRequests":[...],"claims":[],"warnings":[]}
```

工具执行后第 2 轮返回：

```json
{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[...],"warnings":[]}
```

断言：

- Runtime 调用 LLM 两轮。
- 工具结果进入 conversationState。
- checkpoint 在每个 step 后保存。
- budget consumedLLMRounds = 2。

**Step 2: 实现 loop**

伪代码：

```swift
while !job.budget.isExhausted {
    try Task.checkCancellation()
    job.state = .waitingForLLM
    try await persistence.saveProgress(...)

    let output = try await llmClient.next(checkpoint: checkpoint)
    job.budget.consumedLLMRounds += 1

    switch output.status {
    case .needTools:
        checkpoint.pendingToolRequests = output.toolRequests
        checkpoint.step = .executeTools
        let results = await toolExecutor.executeBatch(output.toolRequests)
        checkpoint.completedToolResults.append(contentsOf: results)
        let evidence = evidenceBuilder.records(from: results, jobID: job.id)
        let patterns = patternMiner.mine(toolResults: results)
        checkpoint.patternSignals.append(contentsOf: patterns)
        checkpoint.conversationState.append(toolResultMessage(results))
        try await persistence.saveProgress(job: job, evidence: evidence, checkpoint: checkpoint)

    case .needMoreAnalysis:
        checkpoint.conversationState.append(assistantMessage(output))
        checkpoint.step = .continueOrConclude
        try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)

    case .finalClaims:
        checkpoint.conversationState.append(assistantMessage(output))
        checkpoint.step = .verifyClaims
        try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)
        return
    }
}
```

**Step 3: 实现 parse failure retry**

规则：

- parse failure 且 `needsRetry = true`：job.state = `.retrying`，同一 conversationState 重试。
- 超过 retry：job.state = `.failed`，保存 errorSummary。

**Step 4: 运行构建**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase3-runtime CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloLocalAgentRuntimeTests.swift"
git commit -m "feat(iOS): run multi-round local agent loop"
```

---

## Phase 4：Verifier / Critic / Curator

目标：保证 Agent 的输出不是“会说话的总结”，而是能被本地证据校验、能过滤空话、能正确路由到记忆系统的可信结果。

### Task 4.1：实现 Claim Verifier

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Verification/HoloClaimVerifier.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloClaimVerifierTests.swift`

**Step 1: 写失败测试**

覆盖：

- evidenceID 不存在时 claim rejected。
- metricKey 不匹配时 rejected。
- value 与 evidence metricValue 不一致时 rejected。
- claim 包含因果词“导致/证明/说明一定因为”时 rejected 或 flagged。
- 合法 metric assertion accepted。

**Step 2: 实现 verifier**

```swift
struct HoloClaimVerificationResult: Equatable {
    var acceptedClaims: [HoloAgentClaim]
    var rejectedClaims: [HoloRejectedClaim]
}

struct HoloClaimVerifier {
    func verify(claims: [HoloAgentClaim], evidence: [HoloEvidenceRecord]) -> HoloClaimVerificationResult {
        // deterministic checks only
    }
}
```

Verifier 只校验 `metricAssertions`，不从自然语言里抽数字。

**Step 3: 接入 Runtime**

`final_claims` 后进入 `verifyClaims` step。

**Step 4: 构建验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase4-verifier CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Verification/HoloClaimVerifier.swift" "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloClaimVerifierTests.swift"
git commit -m "feat(iOS): verify agent claims against evidence"
```

### Task 4.2：实现 Insight Critic

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Verification/HoloInsightCritic.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloInsightCriticTests.swift`

**Step 1: 写失败测试**

过滤：

- “继续保持”
- “注意控制”
- “节奏不错”
- 没有 evidence 的 claim
- 只有任务数量但无变化、无风险、无用户目标冲突的 claim

保留：

- 负向习惯发生量连续上升。
- 晚间餐饮次数相对 baseline 明显增加。
- 高优任务积压。

**Step 2: 实现 critic**

```swift
struct HoloInsightCritic {
    func filter(_ claims: [HoloAgentClaim], patterns: [HoloPatternSignal]) -> [HoloAgentClaim] {
        // remove low-value claims
    }
}
```

**Step 3: 接入 Runtime**

Verifier 后进入 `critique` step。

**Step 4: 构建验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase4-critic CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Verification/HoloInsightCritic.swift" "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloInsightCriticTests.swift"
git commit -m "feat(iOS): filter low-value agent insights"
```

### Task 4.3：实现 Memory Curator

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloMemoryCurator.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloMemoryCuratorTests.swift`

**Step 1: 写失败测试**

覆盖：

- `goalConflict + high severity` -> `episodicMemory` candidate。
- 多周期命中的 stable pattern -> `longTermCandidate`，但需要用户确认。
- 低价值任务完成统计 -> `responseOnly`。
- 用户 suppression 命中 -> 不生成记忆候选。

**Step 2: 实现 curator**

```swift
enum HoloAgentMemoryRoute: String, Codable {
    case responseOnly
    case evidenceOnly
    case episodicMemory
    case longTermCandidate
    case displayOnly
    case suppressionRule
}

struct HoloCuratedAgentMemory: Codable, Equatable {
    var claimID: String
    var route: HoloAgentMemoryRoute
    var title: String
    var summary: String
    var evidenceIDs: [String]
    var expiresInDays: Int?
}
```

第一阶段只生成 curator output，不直接写入 `HoloEpisodicMemoryStore` / `HoloLongTermMemoryStore`，避免污染现有系统。下一 task 再接入写入。

**Step 3: 构建验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase4-curator CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloMemoryCurator.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloMemoryCuratorTests.swift"
git commit -m "feat(iOS): route agent insights to memory destinations"
```

### Task 4.4：实现 Agent Result Renderer

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Presentation/HoloAgentResultRenderer.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentResultRendererTests.swift`

**Step 1: 写失败测试**

覆盖：

- claim + evidence 渲染成手机可读短文。
- 包含“证据”引用摘要。
- 不输出 Markdown 表格。
- 敏感 evidence 默认使用 `redactedExcerpt`。

**Step 2: 实现 renderer**

输出结构：

```swift
struct HoloRenderedAgentResult: Codable, Equatable {
    var title: String
    var summary: String
    var sections: [HoloRenderedAgentSection]
    var evidenceReferences: [HoloRenderedEvidenceReference]
}
```

**Step 3: Runtime 持久化 Result**

`persistResult` step 写 `HoloAgentResultStore`。

**Step 4: 构建验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase4-render CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/Presentation/HoloAgentResultRenderer.swift" "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloAgentResultRendererTests.swift"
git commit -m "feat(iOS): render verified agent results"
```

---

## Phase 5：后台短时续跑和恢复

目标：适配 iOS 生命周期。用户回桌面后尽量收尾；被挂起或杀掉后，下次前台恢复从 checkpoint 继续。

### Task 5.1：新增 Background Continuation Manager

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloBackgroundContinuationManager.swift`
- Modify: `Holo/Holo APP/Holo/Holo/HoloApp.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloBackgroundContinuationManagerTests.swift`

**Step 1: 写失败测试**

覆盖：

- `appDidEnterBackground()` 通知 runtime 保存 checkpoint。
- 正在 LLM 请求时标记为可重试。
- `appWillEnterForeground()` 查找 unfinished jobs 并 resume。

**Step 2: 实现 manager**

```swift
@MainActor
final class HoloBackgroundContinuationManager {
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let runtime: HoloLocalAgentRuntime

    func appDidEnterBackground() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            Task {
                await self.runtime.pauseForBackground()
                await MainActor.run { self.endBackgroundTask() }
            }
        }

        Task {
            await runtime.prepareForBackground()
            await MainActor.run { self.endBackgroundTask() }
        }
    }

    func appWillEnterForeground() {
        Task {
            try? await runtime.resumeUnfinishedJobs()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
```

**Step 3: 接入 App lifecycle**

只在 `HoloAIFeatureFlags.agentRuntimeEnabled` 为 true 时启动。

**Step 4: 构建验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase5-bg CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloBackgroundContinuationManager.swift" "Holo/Holo APP/Holo/Holo/HoloApp.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloBackgroundContinuationManagerTests.swift"
git commit -m "feat(iOS): resume agent jobs across app lifecycle"
```

### Task 5.2：完善恢复语义

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloLocalAgentRuntimeTests.swift`

**Step 1: 写失败测试**

覆盖：

- checkpoint.step = `.continueOrConclude` 时重试 LLM。
- checkpoint.step = `.executeTools` 时跳过已完成 toolRequestID。
- checkpoint 引用缺失 evidence 时重跑上一步。
- budget exhausted 时生成 partial result。

**Step 2: 实现恢复规则**

规则表：

| step | 恢复动作 |
| --- | --- |
| plan | 重试 agent_loop |
| executeTools | 执行 pending 中未完成工具 |
| minePatterns | 用 completedToolResults 重跑 Pattern Miner |
| integrateResults | 重试 agent_loop |
| continueOrConclude | 重试 agent_loop |
| verifyClaims | 用已保存 claims 重新校验 |
| critique | 用 verified claims 重新过滤 |
| curateMemory | 幂等重跑 curator |
| render | 幂等重跑 renderer |
| persistResult | 用 resultID 幂等 upsert |

**Step 3: 构建验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase5-resume CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloLocalAgentRuntimeTests.swift"
git commit -m "feat(iOS): make agent checkpoints resumable"
```

---

## Phase 6：内部入口、记忆长廊和 Observer 接入

目标：把 Agent 能力接到产品体验，但先以内部/debug/灰度方式上线。

### Task 6.1：新增内部 Deep Agent 调试入口

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Views/Settings/AISettingsView.swift`
- Create: `Holo/Holo APP/Holo/Holo/Views/AI/HoloAgentDebugView.swift`
- Test: build only

**Step 1: 新增入口**

仅当：

```swift
HoloAIFeatureFlags.agentDebugModeEnabled
```

为 true 时展示。

功能：

- 输入测试问题。
- 启动 mock / real agent job。
- 查看 job state。
- 查看 checkpoint。
- 查看 evidence。
- 查看 rendered result。

**Step 2: 构建验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase6-debugui CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 3: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/Settings/AISettingsView.swift" "Holo/Holo APP/Holo/Holo/Views/AI/HoloAgentDebugView.swift"
git commit -m "feat(iOS): add internal HoloAI agent debug view"
```

### Task 6.2：接入 HoloAI 主动深度分析入口

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/ConversationCoordinator.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/ConversationCoordinatorTests.swift` if test target supports it, otherwise build only.

**Step 1: 分流规则**

只有同时满足：

- `agentRuntimeEnabled == true`
- intent 为 `query_analysis` 或用户显式选择“深度分析”
- 不是记账/创建任务/打卡等执行动作

才进入 Agent Job。

否则保持现有路径。

**Step 2: UI 表达**

聊天里展示任务状态：

```text
正在深度分析
已完成：读取本地数据
进行中：请求 AI 推理
你可以先离开，回来后会继续
```

**Step 3: 构建验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase6-chat CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/ConversationCoordinator.swift" "Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift"
git commit -m "feat(iOS): route deep analysis to local agent"
```

### Task 6.3：记忆长廊读取 Agent Result

**Files:**

- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryViewModel.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/MemoryInsightService.swift`
- Test: build only, plus existing memory tests.

**Step 1: 接入规则**

只有：

```swift
HoloAIFeatureFlags.agentMemoryGalleryEnabled
```

为 true 时，记忆长廊读取 Agent Result。

旧 `MemoryInsightService` 保留 fallback。

**Step 2: 展示规则**

记忆长廊优先展示：

- verified claims
- evidence references
- displayOnly / episodicMemory 路由结果

不展示：

- rejected claims
- low-value task summary
- suppression 命中项

**Step 3: 构建验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase6-gallery CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryViewModel.swift" "Holo/Holo APP/Holo/Holo/Services/AI/MemoryInsightService.swift"
git commit -m "feat(iOS): let memory gallery read verified agent results"
```

### Task 6.4：Observer Tier 1 / Tier 2 触发策略

**Files:**

- Create: `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloObserverTriggerPolicy.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/HoloMemoryObserverService.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloObserverTriggerPolicyTests.swift`

**Step 1: 写失败测试**

覆盖：

- high severity pattern 触发 Tier 2。
- goalConflict 触发 Tier 2。
- cooldown 未过不触发。
- 用户手动触发无视 cooldown。

**Step 2: 实现策略**

```swift
struct HoloObserverTriggerPolicy {
    var tier2CooldownMinutes: Int = 360

    func shouldTriggerTier2(
        patterns: [HoloPatternSignal],
        lastTier2RunAt: Date?,
        now: Date,
        userRequested: Bool
    ) -> Bool {
        if userRequested { return true }
        if let lastTier2RunAt,
           now.timeIntervalSince(lastTier2RunAt) < TimeInterval(tier2CooldownMinutes * 60) {
            return false
        }
        return patterns.contains { $0.severity == .high || $0.severity == .critical || $0.type == .goalConflict }
    }
}
```

**Step 3: 接入 observer**

只有：

```swift
HoloAIFeatureFlags.agentObserverTier2Enabled
```

为 true 时触发 Tier 2 Agent。

**Step 4: 构建验证**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-phase6-observer CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloObserverTriggerPolicy.swift" "Holo/Holo APP/Holo/Holo/Services/AI/HoloMemoryObserverService.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/Agent/HoloObserverTriggerPolicyTests.swift"
git commit -m "feat(iOS): gate observer tier two agent runs"
```

---

## 6. 端到端验收用例

### Case A：负向习惯趋势

输入数据：

```text
用户目标：控制某负向习惯，每日不超过 8
6月1日：8
6月2日：12
6月3日：20
```

期望：

- HabitTool 输出 frequency_change 和 goal_conflict。
- Pattern Miner 生成 high severity pattern。
- Agent 输出 claim：“发生量连续上升，并超过目标”。
- Verifier 校验 evidenceIDs 和数字。
- Critic 不过滤。
- Curator 路由到 `episodicMemory`，长期记忆仍需用户确认。

禁止：

- 说“习惯完成不错”。
- 说“你没有自控力”。
- 推断心理状态。

### Case B：晚间餐饮增加

输入数据：

```text
最近14天晚间餐饮 4 次
前14天晚间餐饮 1 次
```

期望：

- FinanceTool 输出 `finance.meal.nighttime_count`。
- Pattern Miner 生成 timeDistributionShift。
- Agent 输出“晚间餐饮频次增加”。
- Verifier 校验 4 vs 1。

禁止：

- 推断压力大。
- 推断熬夜。
- 没有证据时给健康建议。

### Case C：低价值任务摘要

输入数据：

```text
本周完成 5 个任务
逾期 0 个
没有高优任务
没有 backlog
没有目标冲突
```

期望：

- 可以作为页面摘要。
- Critic 不允许进入长期记忆候选。
- 不在记忆中心反复出现。

### Case D：LLM JSON 错误

模拟：

```text
第一次返回非 JSON
第二次返回合法 JSON
```

期望：

- Runtime 状态进入 `retrying`。
- conversationState 不丢。
- 第二次成功后继续。
- 不给用户展示“我没完全理解”。

### Case E：App 后台恢复

步骤：

1. 发起 deep agent。
2. 完成 tool execution。
3. 进入 LLM 请求前保存 checkpoint。
4. App 进入后台。
5. 前台恢复。

期望：

- 不重复执行已完成工具。
- 用相同 conversationState 重试 LLM。
- result 最终完成。

---

## 7. 全局验证命令

### iOS Build

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-agent-final CODE_SIGNING_ALLOWED=NO build
```

Expected:

```text
** BUILD SUCCEEDED **
```

### 后端测试

Run:

```bash
cd HoloBackend
npm test
```

Expected:

```text
pass
```

### 手工验证

1. 打开 Agent debug mode。
2. 发起 mock job，确认 job / checkpoint / result 写入。
3. 发起 fake LLM job，确认 need_tools -> tool result -> final_claims。
4. 切后台再回来，确认 job resume。
5. 用负向习惯 case 验证不再输出“完成更多”。
6. 用低价值任务 case 验证不会进入记忆候选。

---

## 8. Changelog 与发布要求

每个阶段完成后更新：

```text
CHANGELOG.md
```

格式建议：

```markdown
## 2026-06-13

### Added
- 新增 HoloAI Agent Job / Checkpoint / Evidence Ledger 地基。

### Changed
- HoloAI 深度分析新增本地 Agent feature flag，默认关闭。

### Verified
- iOS Debug build 通过：`xcodebuild ... build`
- 后端测试通过：`npm test`
```

后端相关 task 包括：

- Task 3.1
- Task 3.2

这些改动合并后必须部署 HoloBackend。只本地提交或 push 不会让生产环境支持 `agent_loop`。

---

## 9. 风险控制

### 风险 1：半成品 Agent 污染现有 HoloAI

控制：

- 所有 Agent 入口默认 feature flag false。
- Phase 0/1/2 只 debug，不接主入口。
- Phase 6 才允许灰度接入。

### 风险 2：本地 JSON Store 增长过快

控制：

- evidence 用 dedupeKey upsert。
- orphaned evidence 定期清理。
- completed job 保留 30 天。
- failed / cancelled job 保留 7 天。
- 超过 10000 条 evidence 再迁移 SQLite 或 Core Data。

### 风险 3：LLM 格式错误导致卡死

控制：

- 后端校验 `agent_loop` JSON。
- iOS parser 清理 markdown code block。
- Runtime 支持 retrying 状态。
- 超过重试次数进入 failed，不展示错误 JSON 给用户。

### 风险 4：敏感数据上传过多

控制：

- Evidence Ledger 保存完整 `excerpt` 和 `redactedExcerpt`。
- LLM packager 默认发 `redactedExcerpt`。
- Verifier 本地使用完整 evidence。
- 用户可选择数据分享精细度。

### 风险 5：Agent 成本失控

控制：

- `HoloAgentBudget` 限制 LLM 轮次、tool batch、token、wall time。
- Observer Tier 2 有 cooldown。
- 默认 deep analysis 3 轮，extended 需要用户主动继续。

---

## 10. 开发顺序总表

| 阶段 | 可以并行吗 | 是否用户可见 | 是否涉及后端 | Gate |
| --- | --- | --- | --- | --- |
| Phase 0 | 部分可并行 | 否 | 否 | 旧记忆止血、开关默认关闭 |
| Phase 1 | 不建议并行 | 否 | 否 | mock job 可恢复 |
| Phase 2 | 工具可并行 | 否 | 否 | evidence 和 pattern 可测试 |
| Phase 3 | 前后端可并行 | debug only | 是 | agent_loop 多轮跑通 |
| Phase 4 | 可并行 | debug only | 否 | claims 可校验、空话可过滤 |
| Phase 5 | 不建议并行 | debug only | 否 | 后台恢复可验证 |
| Phase 6 | 分入口灰度 | 是 | 可能 | 深度分析和记忆长廊灰度 |

---

## 11. 最小可交付版本

如果需要一个最小闭环，不要做到 Phase 6 全部才验收。最小版本是：

```text
Phase 0 + Phase 1 + Phase 2 MemoryTool/HabitTool + Phase 3 agent_loop + Phase 4 Verifier/Critic + Debug UI
```

它应该能在 debug 入口跑通：

```text
用户问题
-> agent_loop 请求 HabitTool
-> 本地 HabitTool 生成 evidence
-> Pattern Miner 发现负向习惯上升
-> agent_loop 输出 final_claims
-> Verifier 校验
-> Critic 保留
-> Renderer 展示带证据的结果
```

这个闭环跑通后，再接 FinanceTool、Memory Gallery、Observer。

---

## 12. 不做事项

V3.1 不做：

- 不做后端全量 AI Data Vault。
- 不上传完整交易流水、习惯历史、任务列表、想法原文、健康记录。
- 不使用规则规划替代 Agent。
- 不承诺 App 回桌面后一定完整跑完。
- 不把 Agent 半成品接入默认 HoloAI 聊天入口。
- 不把未经 Verifier 的 claim 写入长期记忆。
- 不在 MVP 做多设备 Agent Job 同步。

---

## 13. 执行提醒

执行本方案时，每个 task 都按以下节奏：

1. 先写失败测试。
2. 实现最小代码。
3. 跑对应构建或后端测试。
4. 更新 changelog。
5. scoped staging。
6. 单独 commit。

不要把 Phase 0/1/2 和 Phase 6 混在一个提交里。Agent 系统的风险主要来自边界不清，提交也要按边界拆。

后端改动完成后，必须安排 HoloBackend 发版；否则 iOS 即使合并了 `agent_loop` client，生产环境仍会返回 unsupported purpose。
