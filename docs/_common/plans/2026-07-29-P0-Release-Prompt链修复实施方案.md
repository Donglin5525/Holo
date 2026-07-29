# P0：Release Prompt 获取链修复 实施方案

- 状态：实施中
- 日期：2026-07-29
- 适用范围：Release configuration 下的全部 AI / Agent 功能
- 来源：连续追问方案第三轮对抗性审查（23.3.3 商榷 1）挖出的独立生产阻塞
- 关联文档：
  - `docs/_common/plans/2026-07-29-Holo-Agent连续追问完整产品与技术方案.md`（13.3 节、23.3.3 节）
  - `docs/_common/Holo-Agent研发与验收规范.md`

## 1. 背景：为什么这是 P0

第三轮审查在核实"连续追问现有基础"时，发现一个与连续追问无关、但更紧急的缺陷：

**Release 包里，整个 AI 功能链路是断的。**

具体来说：

- `PromptManager` 整个类被 `#if DEBUG` 包裹（`PromptManager.swift:12`）。Release 下的 stub（`:1467-1505`）只保留 `PromptType` 枚举和四个空方法，**没有 `loadRawTemplate` 成员**。
- `HoloBackendPromptService` 整个文件也是 `#if DEBUG`（`:8-175`）。
- 但前台 Agent（`HoloAgentAnalysisService.swift:209`）和后台恢复（`HoloBackgroundContinuationManager.swift:171`）**无条件调用** `PromptManager.shared.loadRawTemplate(.agentLoop)`——这两处没有 `#if DEBUG` 保护。

这造成两个后果：

1. **Release 包编译不过**：两处 `value of type 'PromptManager' has no member 'loadRawTemplate'`。
2. **即使绕过编译，AI 功能在 Release 下也会崩**：`OpenAICompatibleProvider.swift` 有 6 处 `PromptManager.shared.loadPrompt(...)`（第 42/72/97/121/162/227 行），覆盖意图识别、记忆生成、系统提示、人格层等所有对话主路径。Release stub 的 `loadPrompt` 直接 `throw PromptError.unavailableInRelease`（`:1499`），而调用方用 `try` 且无兜底。

**换句话说：当前 Release 配置下，无论是连续追问还是最基本的聊天，AI 功能都不可用。这是一个独立于连续追问的生产阻塞，必须立即修复。**

## 2. 根因分析

核实代码后发现，Release 阻塞的范围比文档 13.3 原描述的更窄，也更清晰：

**只有 Agent 的两个入口是真正的编译阻塞。** `OpenAICompatibleProvider` 虽然有 6 处 `PromptManager.shared.loadPrompt(...)`，但它整个类是 `#if DEBUG`（`:12`），Release 下不存在。Release 下所有非 Agent 的 AI 调用走 `HoloBackendAIProvider`，它调用 `/v1/ai/chat/completions` 只传 `purpose`，**prompt 正文由后端 `injectServerPrompt` 注入**（`serverPromptPolicy.js:34-60`），客户端不需要拿 prompt 正文。

所以真正的阻塞是：
- `HoloAgentAnalysisService.swift:209` 和 `HoloBackgroundContinuationManager.swift:171` 无条件调用 `PromptManager.shared.loadRawTemplate(.agentLoop)`；
- `loadRawTemplate` 在 Release stub 里不存在 → Release 编译失败。

**后端已为 agent_loop 注入 system prompt。** 后端 `injectServerPrompt`（`serverPromptPolicy.js:55-58`）会把它组装的 system prompt（含人格层 + agentLoop 正文 + 变量渲染）插到 messages 最前面。客户端 `HoloAgentPromptBuilder` 组装的 system message（来自 `loadRawTemplate`）传到后端后，会排在后端注入的 system prompt 之后，形成两条 system message。

也就是说：**客户端传的 systemTemplate 在正常后端链路下是冗余的**——后端版本在前且更完整（含人格层和最新 contract appendix）。客户端那条只是重复内容，不造成功能错误，只浪费少量 token。

这给了我们一个干净、低风险的修复方向：让 Agent 路径不再依赖 `loadRawTemplate`，但保留一个不烘焙商业正文的本地兜底（供 Debug 离线和后端异常诊断用）。

## 3. 设计：Agent systemTemplate 的全配置兜底

### 3.1 核心思路

既然后端已经为 `agent_loop` 注入了完整 system prompt，客户端的 `systemTemplate` 在正常链路下是冗余的。但它作为"本地 Runtime 组装 messages 时的占位 system message"仍有意义（保持消息结构完整，并在后端异常时提供基本协议约束）。

因此修复方向是：**让 Agent 路径在 Debug/Release 都能拿到一份非空、安全的 agentLoop 正文**，而不是依赖 Release 下不存在的 `loadRawTemplate`。

### 3.2 方案：全配置可见的 Provider + Debug 本地正文 / Release 安全占位

新建 `HoloAgentPromptProvider.swift`（**无 `#if DEBUG`，全配置编译**），提供：

```swift
/// Agent systemTemplate 的统一获取入口。Debug/Release 都编译。
enum HoloAgentPromptProvider {
    /// 获取 agentLoop 的 systemTemplate。
    /// - Debug：优先后端拉取，失败回退本地内嵌模板（开发断网可用）。
    /// - Release：优先后端拉取，失败返回安全占位（不烘焙商业 Prompt 正文）。
    /// 返回的正文已渲染运行时变量（{{todayDate}} 等）。
    static func agentLoopSystemTemplate() async -> String
}
```

**Debug 分支**：优先调 `HoloBackendPromptService` 拉取后端正文；失败时回退到 `PromptManager.shared` 的本地 agentLoop 模板（DEBUG-only，内嵌完整正文）。

**Release 分支**：优先调一个 Release 可见的轻量后端拉取（复用 `APIClient` + `HoloBackendEnvironment` + `HoloBackendDeviceIdentity`，直接 GET `/v1/prompts/agent_loop`）；失败时返回**安全占位**——一段不含商业逻辑的最小协议提示（"你是一个 JSON 推理器，只输出 JSON"），仅保证消息结构完整，真正约束由后端注入提供。

**为什么不把完整商业正文烘焙进 Release**：商业 Prompt 是核心资产，且后端已有 `injectServerPrompt` 保证权威正文。客户端只需一个"消息结构占位 + 异常兜底"，不需要也不应该持有完整正文。

### 3.3 后端拉取的 Release 可见实现

`HoloBackendPromptService` 整文件 DEBUG-only，不能直接复用。但它的核心逻辑很简单（一个 GET 请求 + 变量渲染）。在 `HoloAgentPromptProvider` 的 Release 分支内联实现：

- `APIClient.shared.send(APIRequest(path: "/v1/prompts/agent_loop", headers: [deviceId]))` ；
- 解析 `HoloBackendPromptResponse`（`{type, version, content}`）；
- 用共享的 `HoloPromptVariableRenderer` 渲染 `{{todayDate}}` 等变量；
- 失败 catch 后返回安全占位。

### 3.4 调用方改造

| 文件 | 现状 | 改造后 |
|---|---|---|
| `HoloAgentAnalysisService.swift:209` | `PromptManager.shared.loadRawTemplate(.agentLoop)`（同步） | `await HoloAgentPromptProvider.agentLoopSystemTemplate()`（异步） |
| `HoloBackgroundContinuationManager.swift:171` | 同上 | 同上 |

两处调用从同步改为异步（`runAnalysis` 和 `resumeAndSyncRecoveredJobs` 本身已经是 async，无影响）。

### 3.5 不改动的部分

- `PromptManager`（含 DEBUG 内嵌模板和 Release stub）：不动，继续服务编辑器 UI。
- `HoloBackendPromptService`：不动，继续服务 Debug 下编辑器刷新。
- `OpenAICompatibleProvider`：它是 DEBUG-only，Release 下不存在，无需改。
- `PromptEditorView` / `PromptEditorViewModel` / `AISettingsView`：DEBUG-only 编辑器，继续直接用 `PromptManager`。

## 4. 实施步骤（实际落地）

### Step 1：新建共享变量渲染工具
- 新建 `Services/AI/HoloPromptVariableRenderer.swift`（全配置编译）；
- 提供 `renderVariables(in:now:)`，渲染 `{{todayDate}}` / `{{todayISODate}}` / `{{thirtyDaysAgoDate}}` / `{{currentYear}}` / `{{currentTime}}`；
- 供 Provider 和未来其他 Release 链路复用。

### Step 2：新建 Release 安全占位
- 新建 `Services/AI/Agent/HoloAgentPromptFallbacks.swift`（全配置编译）；
- 提供 `agentLoopSafePlaceholder`——最小协议提示，不含商业正文。

### Step 3：新建 Provider
- 新建 `Services/AI/Agent/HoloAgentPromptProvider.swift`（全配置编译）；
- `agentLoopSystemTemplate()` 方法：
  - 全配置可见的后端拉取逻辑（复用 `APIClient` / `APIRequest` / `HoloBackendDeviceIdentity`）；
  - `#if DEBUG` 分支：回退到 `PromptManager.shared.loadRawTemplate(.agentLoop)` + 变量渲染；
  - `#else` 分支：回退到 `HoloAgentPromptFallbacks.agentLoopSafePlaceholder`。

### Step 4：改造调用方
- `HoloAgentAnalysisService.swift:209`：`PromptManager.shared.loadRawTemplate(.agentLoop)` → `await HoloAgentPromptProvider.agentLoopSystemTemplate()`；
- `HoloBackgroundContinuationManager.swift:171`：同上；
- `OpenAICompatibleProvider` 不改（DEBUG-only，Release 下不存在）。

### Step 5：Release configuration 编译验证
- `xcodebuild -configuration Release` 验证编译通过；
- 确认不再出现 `no member 'loadRawTemplate'`。

### Step 6：补测试
- `HoloAgentPromptProviderTests.swift`：后端成功返回正文、后端失败回退非空、变量渲染、Debug/Release 分支差异。

## 5. 验收标准（今晚 DoD）

- [x] Release configuration 编译通过，不再出现 `no member 'loadRawTemplate'`；
      （`xcodebuild -configuration Release` BUILD SUCCEEDED，0 error）
- [x] 前台 Agent 和后台恢复走 Provider，不直接调 DEBUG-only API；
      （`HoloAgentAnalysisService` 和 `HoloBackgroundContinuationManager` 已改为 `await HoloAgentPromptProvider.agentLoopSystemTemplate()`，grep 确认无 `loadRawTemplate` 残留）
- [x] Debug 配置编译通过；
      （`xcodebuild -configuration Debug` Holo app target BUILD SUCCEEDED）
- [x] Release 二进制不含商业 Prompt 正文；
      （扫描 Release 产物，agentLoop 完整正文和 persona preamble 特征词均未命中）
- [x] 不涉及后端发版；
      （后端 `/v1/prompts/agent_loop` 接口已存在，本方案只改客户端获取链路）
- [~] Provider 有单元测试覆盖核心路径；
      （测试代码已写：`HoloAgentPromptProviderTests.swift`，覆盖后端成功/失败回退/变量渲染/Debug-Release 分支差异。但 HoloTests target 因 **预先存在的 `@main` 冲突问题**——几十个 standalone 测试文件都标了 `@main`，与标准 XCTest 混编导致 `'main' attribute can only apply to one type in a module`——无法在 `xcodebuild test` 下运行。此问题与本次改动无关，移除本次全部改动后仍存在。）

## 6. 不在本次范围

- 连续追问主链路（lineage、Context Snapshot、AnchorResolver 等）：本次只修 Prompt 链，连续追问按原方案 Phase 0 后续推进。
- 后端 Prompt 接口本身：已存在且可用，本次不改。
- Prompt 编辑器 UI：DEBUG-only，不在 Release 链路，不改。
