# Holo Release Sensitive Information Hardening Implementation Plan

> 实施状态：Task 1-9 已完成并通过后端 101 项测试、7 组 iOS standalone 与 Release 构建；Task 10 进入生产部署和真机验收。

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task in the existing Holo working copy. Do not use subagents.

**Goal:** 收口 Holo 正式版的模型、Prompt、配置和原始日志暴露面，同时让东林通过后端验证的 Apple 身份在真机安全查看完整 AI 调用日志。

**Architecture:** HoloBackend 验证 Apple identity token 并签发带 `internalDiagnostics` 声明的短期 Holo 会话令牌；Prompt 由服务端根据 `purpose` 注入。普通 iOS 用户不再生成或持久化原始日志，内部账号在调用完成后凭 `requestId` 立即拉取热缓存日志，保存到受文件保护且不进 iCloud 的 7 天本机诊断仓库。

**Tech Stack:** Swift 5、SwiftUI、AuthenticationServices、Keychain、URLSession/SSE、Core Data/CloudKit、Hono、Node.js、jose、SQLite、node:test、Xcode Release build。

---

## 实施约束

- 直接使用 `/Users/tangyuxuan/Desktop/Claude/HOLO`，不创建 worktree。
- 所有 git 命令使用 `git -C /Users/tangyuxuan/Desktop/Claude/HOLO ...`。
- 工作区已有其他修改，只 scoped staging 本计划文件和本轮实际修改。
- iOS 注释使用中文，标识符使用英文。
- 每个任务先写失败测试，再做最小实现，再运行相关测试。
- 修改 `HoloBackend/` 后必须部署 ECS，并完成生产接口验收。

### Task 1: 后端 Apple 身份验证与 Holo 会话令牌

**Files:**
- Modify: `HoloBackend/package.json`
- Modify: `HoloBackend/package-lock.json`
- Modify: `HoloBackend/src/config.js`
- Create: `HoloBackend/src/auth/appleIdentityVerifier.js`
- Create: `HoloBackend/src/auth/holoSession.js`
- Test: `HoloBackend/tests/appleAuth.test.js`
- Modify: `HoloBackend/.env.example`

**Step 1: 写 Apple JWT 与会话令牌失败测试**

覆盖：合法 `iss/aud/sub/exp`、错误 audience、过期 token、未知 `kid`、内部白名单、普通账号、篡改 Holo 会话令牌、过期 Holo 会话令牌。测试注入本地 JWK 和固定时钟，不请求 Apple 网络。

**Step 2: 运行 RED**

Run: `npm test -- --test-name-pattern="Apple identity|Holo session"`

Expected: FAIL，模块尚不存在。

**Step 3: 安装并锁定 jose**

Run: `npm install jose`

Expected: `package.json` 与 lockfile 只增加 JWT/JWK 验证依赖。

**Step 4: 实现验证与签发接口**

核心接口：

```js
export function createAppleIdentityVerifier({ clientIds, jwks, issuer, now })
export function createHoloSessionService({ secret, issuer, audience, ttlSeconds, now })
```

`verifyAppleIdentity(identityToken)` 返回验证后的 `sub`，不信任客户端单独提交的 user identifier。`issue({ sub, internalDiagnostics })` 使用 HS256/256-bit 以上服务端密钥签发短期令牌；`verify(token)` 固定校验算法、issuer、audience、expiry。

配置新增：

- `HOLO_APPLE_CLIENT_IDS`
- `HOLO_INTERNAL_DIAGNOSTICS_APPLE_SUBS`
- `HOLO_SESSION_SECRET`
- `HOLO_SESSION_TTL_SECONDS`

数组按逗号拆分、trim、去空；生产缺少 session secret 时内部权限默认拒绝。

**Step 5: 运行 GREEN 与全量后端测试**

Run: `npm test -- --test-name-pattern="Apple identity|Holo session"`

Expected: PASS。

Run: `npm test`

Expected: 全部测试 PASS。

**Step 6: Commit**

```bash
git add HoloBackend/package.json HoloBackend/package-lock.json HoloBackend/src/config.js HoloBackend/src/auth HoloBackend/tests/appleAuth.test.js HoloBackend/.env.example
git commit -m "feat: 增加 Apple 身份与内部会话验证"
```

### Task 2: 后端内部诊断接口与 requestId 契约

**Files:**
- Modify: `HoloBackend/src/app.js`
- Modify: `HoloBackend/src/admin/adminLogStore.js`
- Create: `HoloBackend/src/auth/internalDiagnosticsAuth.js`
- Test: `HoloBackend/tests/internalDiagnostics.test.js`
- Modify: `HoloBackend/tests/chat.test.js`

**Step 1: 写失败测试**

覆盖：

- `POST /v1/auth/apple/session` 只接受验证后的 Apple token；
- 白名单账号返回 `internalDiagnostics: true`；
- 普通账号返回 false；
- AI 普通和流式响应包含 `X-Holo-Request-Id`；
- 普通、Plus、过期、伪造令牌访问 `/v1/internal/ai-logs/:requestId` 返回 401/403；
- 内部令牌只能读取存在于热缓存的日志；
- 不存在或已淘汰的 requestId 返回 404；
- 内部接口响应有大小上限并禁止缓存。

**Step 2: 运行 RED**

Run: `npm test -- --test-name-pattern="internal diagnostics|request id"`

Expected: FAIL，路由和响应头尚不存在。

**Step 3: 实现路由与鉴权**

新增：

```text
POST /v1/auth/apple/session
GET  /v1/internal/ai-logs/:requestId
```

内部接口只读 `Authorization: Bearer <holo-session>`，不接受设备 ID、Plus 状态、query token 或管理员 Cookie 替代。响应增加 `Cache-Control: no-store`。

`adminLogStore.startAiCall()` 生成的 UUID 作为 requestId；App 在创建上游调用日志后立刻把该 ID 放入普通响应头和 SSE 初始响应头。

**Step 4: 运行 GREEN**

Run: `npm test -- --test-name-pattern="internal diagnostics|request id"`

Expected: PASS。

Run: `npm test`

Expected: 全部测试 PASS。

**Step 5: Commit**

```bash
git add HoloBackend/src/app.js HoloBackend/src/admin/adminLogStore.js HoloBackend/src/auth/internalDiagnosticsAuth.js HoloBackend/tests/internalDiagnostics.test.js HoloBackend/tests/chat.test.js
git commit -m "feat: 增加仅内部账号可读的 AI 调用日志"
```

### Task 3: Prompt 服务端注入与公网 Prompt 关闭

**Files:**
- Modify: `HoloBackend/src/app.js`
- Create: `HoloBackend/src/prompts/purposePromptResolver.js`
- Modify: `HoloBackend/tests/prompts.test.js`
- Modify: `HoloBackend/tests/chat.test.js`
- Modify: `HoloBackend/tests/healthInsight.test.js`
- Modify: `HoloBackend/tests/security-and-asr.test.js`

**Step 1: 写 purpose → Prompt 契约失败测试**

为所有生产 purpose 建立显式映射，包括 `chat`、`intent`、`flexible_query_planner`、`insight`、`health_insight_generation`、`thought_voice_summary`、`memory_observer`、`finance_action_parser`、`task_action_parser`、`thought_organization`、`thought_tag_convergence`、`agent_loop`。

验证后端固定按以下顺序构造消息：托管 system Prompt → 客户端结构化 context → 用户/助手历史；客户端 system message 不能覆盖首条托管 Prompt。

**Step 2: 写公网接口失败测试**

验证普通公网请求：

- `GET /v1/prompts` 返回 404；
- `GET /v1/prompts/:type` 返回 404；
- `GET /v1/prompts/meta` 返回 404；
- 管理端 Prompt 页面和管理员接口继续可用。

**Step 3: 运行 RED**

Run: `npm test -- --test-name-pattern="server managed prompt|public prompt"`

Expected: FAIL。

**Step 4: 实现服务端注入**

`purposePromptResolver` 只接受 allowlist purpose，读取 `getPrompt()` 当前版本。`/v1/ai/chat/completions` 在验证请求后服务端注入 Prompt；日志记录真实 `promptType/promptVersion`。

旧客户端仍可发送已有 system messages，但后端把它们降级为客户端 context，永远不能替代第一条托管 Prompt。公网 Prompt 正文路由删除；旧客户端拉取失败后仍可依靠当前本地 fallback 工作，避免已安装版本立即中断。

**Step 5: 运行 GREEN 与全量测试**

Run: `npm test -- --test-name-pattern="server managed prompt|public prompt"`

Expected: PASS。

Run: `npm test`

Expected: 全部测试 PASS。

**Step 6: Commit**

```bash
git add HoloBackend/src/app.js HoloBackend/src/prompts/purposePromptResolver.js HoloBackend/tests
git commit -m "refactor: 将生产 Prompt 迁移到后端注入"
```

### Task 4: 收缩公网发布状态并保留鉴权验收

**Files:**
- Modify: `HoloBackend/src/app.js`
- Modify: `HoloBackend/src/admin/adminRoutes.js`
- Modify: `HoloBackend/tests/releaseStatus.test.js`
- Modify: `HoloBackend/scripts/verify-production-release.sh`
- Modify: `HoloBackend/tests/releaseVerificationScript.test.js`

**Step 1: 写失败测试**

公网 `/v1/release/status` 只允许 `ok/service/release` 最小字段，不含 routes、prompts、database、provider、model、temperature、maxTokens。新增管理员鉴权的 `/v1/admin/release/status` 返回部署验收所需完整信息。

**Step 2: 运行 RED**

Run: `npm test -- --test-name-pattern="release status|verification script"`

Expected: FAIL。

**Step 3: 实现与更新验收脚本**

`verify:prod` 从 `HOLO_ADMIN_TOKEN` 读取凭证访问管理员状态接口；缺少凭证时明确失败，不降级到公开完整状态，也不在输出中打印 token。

**Step 4: 运行 GREEN**

Run: `npm test -- --test-name-pattern="release status|verification script"`

Expected: PASS。

Run: `npm test`

Expected: 全部测试 PASS。

**Step 5: Commit**

```bash
git add HoloBackend/src/app.js HoloBackend/src/admin/adminRoutes.js HoloBackend/tests/releaseStatus.test.js HoloBackend/scripts/verify-production-release.sh HoloBackend/tests/releaseVerificationScript.test.js
git commit -m "fix: 收缩公网运行配置暴露"
```

### Task 5: iOS 内部身份会话

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/Auth/HoloAuthSession.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/Auth/AppleSignInAuthService.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/Security/KeychainService.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/Auth/HoloInternalAccessService.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/Auth/HoloInternalAccessPolicy.swift`
- Create: `Holo/Holo APP/Holo/Holo/Models/Auth/HoloBackendSession.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/Auth/HoloInternalAccessStandaloneTests.swift`

**Step 1: 写 standalone 失败测试**

覆盖 Holo 会话解码、expiry、`internalDiagnostics`、默认拒绝、退出清理、Apple 凭证撤销清理。协议抽象网络交换和 Keychain，测试不访问真实 Apple/后端。

**Step 2: 运行 RED**

Run: `swiftc "Holo/Holo APP/Holo/Holo/Models/Auth/HoloBackendSession.swift" "Holo/Holo APP/Holo/Holo/Services/Auth/HoloInternalAccessPolicy.swift" "Holo/Holo APP/Holo/HoloTests/Services/Auth/HoloInternalAccessStandaloneTests.swift" -o /tmp/holo_internal_access_tests && /tmp/holo_internal_access_tests`

Expected: 编译或断言失败，类型尚不存在。

**Step 3: 实现登录交换**

Apple 登录成功后读取非空 `identityToken`、`authorizationCode`，调用 `/v1/auth/apple/session`。普通 Apple 本地登录即使后端交换失败仍可成立，但内部权限默认 false。

`HoloInternalAccessService.canViewAILogs` 仅在 Apple 登录有效且 Holo 会话未过期时为 true。Keychain 保存 token 和 expiry，不保存到 Core Data/UserDefaults。

退出登录、账号删除、credential revoked 时同步清除内部会话和内部日志仓库。

**Step 4: 运行 GREEN**

Run: `swiftc "Holo/Holo APP/Holo/Holo/Models/Auth/HoloBackendSession.swift" "Holo/Holo APP/Holo/Holo/Services/Auth/HoloInternalAccessPolicy.swift" "Holo/Holo APP/Holo/HoloTests/Services/Auth/HoloInternalAccessStandaloneTests.swift" -o /tmp/holo_internal_access_tests && /tmp/holo_internal_access_tests`

Expected: 所有断言 PASS。

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/Auth" "Holo/Holo APP/Holo/Holo/Models/Auth" "Holo/Holo APP/Holo/Holo/Services/Security/KeychainService.swift" "Holo/Holo APP/Holo/HoloTests/Services/Auth/HoloInternalAccessStandaloneTests.swift"
git commit -m "feat: 接入 Apple 验证的内部诊断权限"
```

### Task 6: 正式 AI 授权页与开发设置隔离

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Views/Settings/AIDataProcessingConsentView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/WeeklyObservationCard.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Settings/SettingsView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Settings/AISettingsView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Personal/PersonalView.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Views/Settings/ReleaseSettingsSurfaceStandaloneTests.swift`

**Step 1: 写静态契约失败测试**

验证正式授权路径只引用 `AIDataProcessingConsentView`；`AISettingsView`、Prompt 工坊、语音模型配置、Agent 灰度和调试入口没有 Release 导航路径；关于页面版本来自 Bundle。

**Step 2: 运行 RED**

Run: `swift "Holo/Holo APP/Holo/HoloTests/Views/Settings/ReleaseSettingsSurfaceStandaloneTests.swift" "/Users/tangyuxuan/Desktop/Claude/HOLO"`

Expected: FAIL，聊天仍打开完整 AISettings。

**Step 3: 实现最小正式授权页**

页面只包含授权开关、必要数据说明、关闭影响、隐私政策入口。聊天弹窗和观察卡统一跳转该页。

完整开发设置整体放入 DEBUG 编译边界；删除 PersonalView 中未使用的 Prompt 工坊死代码，防止未来误接入。

关于版本显示：

```swift
Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
```

**Step 4: 运行 GREEN**

Run: `swift "Holo/Holo APP/Holo/HoloTests/Views/Settings/ReleaseSettingsSurfaceStandaloneTests.swift" "/Users/tangyuxuan/Desktop/Claude/HOLO"`

Expected: PASS。

**Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/Settings" "Holo/Holo APP/Holo/Holo/Views/Chat" "Holo/Holo APP/Holo/Holo/Views/Personal/PersonalView.swift" "Holo/Holo APP/Holo/HoloTests/Views/Settings/ReleaseSettingsSurfaceStandaloneTests.swift"
git commit -m "fix: 隔离正式版 AI 授权与开发配置"
```

### Task 7: iOS requestId 传递与本机内部日志仓库

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/Network/APIClient.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/Diagnostics/HoloInternalLogStore.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/Diagnostics/HoloInternalLogService.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Models/AI/LLMCallLog.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/Diagnostics/HoloInternalLogStoreStandaloneTests.swift`

**Step 1: 写失败测试**

覆盖：requestId 从普通和 SSE 响应头传出；7 天清理；退出清空；损坏 JSON 安全恢复；文件保护属性；存储路径不在共享容器；普通权限不创建文件。

**Step 2: 运行 RED**

Run: `swiftc "Holo/Holo APP/Holo/Holo/Models/AI/AIModels.swift" "Holo/Holo APP/Holo/Holo/Models/AI/LLMCallLog.swift" "Holo/Holo APP/Holo/Holo/Services/Diagnostics/HoloInternalLogStore.swift" "Holo/Holo APP/Holo/HoloTests/Services/Diagnostics/HoloInternalLogStoreStandaloneTests.swift" -o /tmp/holo_internal_log_tests && /tmp/holo_internal_log_tests`

Expected: FAIL。

**Step 3: 扩展网络结果契约**

普通请求新增可返回 `HTTPURLResponse` 元数据的 API；SSE 使用事件/回调把首个成功响应头的 `X-Holo-Request-Id` 传给 Provider，不改变现有字符串 chunk 消费方式。

**Step 4: 实现本机仓库**

目录使用 Application Support 下独立子目录，设置 `URLResourceKey.isExcludedFromBackupKey = true`，文件写入使用 `.completeFileProtection`。每条记录含 messageId、requestId、capturedAt、LLMLog；启动、读取、写入时执行 7 天清理。

**Step 5: 运行 GREEN**

Run: `swiftc "Holo/Holo APP/Holo/Holo/Models/AI/AIModels.swift" "Holo/Holo APP/Holo/Holo/Models/AI/LLMCallLog.swift" "Holo/Holo APP/Holo/Holo/Services/Diagnostics/HoloInternalLogStore.swift" "Holo/Holo APP/Holo/HoloTests/Services/Diagnostics/HoloInternalLogStoreStandaloneTests.swift" -o /tmp/holo_internal_log_tests && /tmp/holo_internal_log_tests`

Expected: PASS。

**Step 6: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/Network/APIClient.swift" "Holo/Holo APP/Holo/Holo/Services/Diagnostics" "Holo/Holo APP/Holo/Holo/Models/AI/LLMCallLog.swift" "Holo/Holo APP/Holo/HoloTests/Services/Diagnostics/HoloInternalLogStoreStandaloneTests.swift"
git commit -m "feat: 保存仅内部账号可见的本机 AI 日志"
```

### Task 8: 聊天日志权限接入与 rawLog 迁移

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/MessageBubbleView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Models/ChatMessageViewData.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Data/Repositories/ChatMessageRepository.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/Migrations/SensitiveDebugDataMigration.swift`
- Modify: `Holo/Holo APP/Holo/HoloApp.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/Diagnostics/HoloInternalLogVisibilityStandaloneTests.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/Migrations/SensitiveDebugDataMigrationStandaloneTests.swift`

**Step 1: 写失败测试**

验证普通/Plus 用户没有日志菜单且 finalizeMessage 不再写 rawLog；内部用户有本机日志才显示菜单；权限失效后立即隐藏；迁移只清 rawLogJSON，不删除聊天正文、卡片和仍有业务用途的 analysisContext。

**Step 2: 运行 RED**

Run: `swift "Holo/Holo APP/Holo/HoloTests/Services/Diagnostics/HoloInternalLogVisibilityStandaloneTests.swift" "/Users/tangyuxuan/Desktop/Claude/HOLO"`

Run: `swift "Holo/Holo APP/Holo/HoloTests/Services/Migrations/SensitiveDebugDataMigrationStandaloneTests.swift" "/Users/tangyuxuan/Desktop/Claude/HOLO"`

Expected: FAIL。

**Step 3: 停止生产 rawLog 持久化**

ChatViewModel 不再把 Provider `lastCallLog` 编码进 Core Data。内部账号调用完成后按 requestId 立即拉取后端热日志，成功后写内部仓库；失败只写脱敏 Logger，不影响聊天结果。

MessageBubbleView 的日志菜单条件改为内部权限有效且本机仓库存在该 messageId。ChatLogView 保持现有阅读和复制体验。

**Step 4: 实现幂等迁移**

应用启动异步批量清空历史 `rawLogJSON`，迁移标记只在保存成功后写入。同步删除旧 AI/语音 Keychain 配置和 Prompt 自定义缓存；失败下次启动重试。

**Step 5: 运行 GREEN**

Run: `swift "Holo/Holo APP/Holo/HoloTests/Services/Diagnostics/HoloInternalLogVisibilityStandaloneTests.swift" "/Users/tangyuxuan/Desktop/Claude/HOLO"`

Run: `swift "Holo/Holo APP/Holo/HoloTests/Services/Migrations/SensitiveDebugDataMigrationStandaloneTests.swift" "/Users/tangyuxuan/Desktop/Claude/HOLO"`

Expected: PASS。

**Step 6: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift" "Holo/Holo APP/Holo/Holo/Views/Chat" "Holo/Holo APP/Holo/Holo/Models/ChatMessageViewData.swift" "Holo/Holo APP/Holo/Holo/Data/Repositories/ChatMessageRepository.swift" "Holo/Holo APP/Holo/Holo/Services/Migrations" "Holo/Holo APP/Holo/Holo/HoloApp.swift" "Holo/Holo APP/Holo/HoloTests/Services"
git commit -m "fix: 阻止正式用户持久化原始 AI 日志"
```

### Task 9: iOS 停止下载生产 Prompt 与统一用户错误

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendPromptService.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/Thoughts/ThoughtTagConvergenceJob.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/ThoughtOrganizationService.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/HoloAIUserErrorMapper.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/HoloBackendPromptBoundaryStandaloneTests.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/HoloAIUserErrorMapperStandaloneTests.swift`

**Step 1: 写失败测试**

验证生产 Provider 不调用 `/v1/prompts*`、请求不携带托管 Prompt 正文；Debug 可保留测试模板；用户错误不包含 provider/model/base URL/HTTP/JSON 解码原文。

**Step 2: 运行 RED**

Run: `swift "Holo/Holo APP/Holo/HoloTests/Services/AI/HoloBackendPromptBoundaryStandaloneTests.swift" "/Users/tangyuxuan/Desktop/Claude/HOLO"`

Run: `swiftc "Holo/Holo APP/Holo/Holo/Services/Network/APIError.swift" "Holo/Holo APP/Holo/Holo/Services/AI/HoloAIUserErrorMapper.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/HoloAIUserErrorMapperStandaloneTests.swift" -o /tmp/holo_ai_error_mapper_tests && /tmp/holo_ai_error_mapper_tests`

Expected: FAIL。

**Step 3: 实现客户端 Prompt 边界**

后端 Provider 只发送 purpose、业务消息和结构化 context。PromptManager 的完整生产后备模板放入 DEBUG 编译边界或移出 Release 可达路径；所有依赖托管 Prompt 的后台服务改为服务端 purpose 调用。

**Step 4: 实现用户错误映射**

将 APIError、URLError、授权错误映射为固定产品文案；`localizedDescription` 只写 Logger，不拼入聊天气泡和可见卡片。

**Step 5: 运行 GREEN**

Run: `swift "Holo/Holo APP/Holo/HoloTests/Services/AI/HoloBackendPromptBoundaryStandaloneTests.swift" "/Users/tangyuxuan/Desktop/Claude/HOLO"`

Run: `swiftc "Holo/Holo APP/Holo/Holo/Services/Network/APIError.swift" "Holo/Holo APP/Holo/Holo/Services/AI/HoloAIUserErrorMapper.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/HoloAIUserErrorMapperStandaloneTests.swift" -o /tmp/holo_ai_error_mapper_tests && /tmp/holo_ai_error_mapper_tests`

Expected: PASS。

**Step 6: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI" "Holo/Holo APP/Holo/Holo/Services/Thoughts/ThoughtTagConvergenceJob.swift" "Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI"
git commit -m "refactor: 将生产 Prompt 与错误细节移出客户端"
```

### Task 10: 全量验证、文档与生产部署

**Files:**
- Modify: `CHANGELOG.md`
- Modify if needed: `docs/privacy-policy.html`
- Modify if needed: `Holo/Holo APP/Holo/Holo/Views/Settings/LegalDocumentSheet.swift`
- Modify: `docs/_common/plans/2026-07-13-release-sensitive-information-hardening-design.md`
- Modify: `docs/_common/plans/2026-07-13-release-sensitive-information-hardening-implementation.md`

**Step 1: 后端全量测试**

Run: `npm test`

Expected: 所有测试 PASS，不能只有 runner 成功而没有测试。

**Step 2: iOS targeted/standalone 测试矩阵**

Run: 本计划 Task 5-9 的全部 standalone commands。

Expected: 所有断言 PASS。

若 Xcode test target 可用，再运行 `test_sim`；必须确认实际执行测试数不为 0。

**Step 3: Release 构建**

Run: `xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED`。

**Step 4: Release 产物敏感字符串扫描**

扫描并确认正式 UI 不含 API Key、模型配置、温度、最大 Token、Prompt 工坊、Agent 调试、Mock Job、刷新后端 Prompt 等入口文案。Prompt 正文特征不得出现在 Release 可执行产物；后端域名允许存在。

**Step 5: 隐私文案对账**

确认普通用户不再持久化完整 AI 请求/响应；内部账号 7 天本机诊断存储和后端脱敏摘要策略与隐私政策一致。需要修改时同步更新网页与 App 内文案。

**Step 6: Changelog 与 scoped commit**

只 staged 本轮改动，检查 `git diff --cached --check`，提交剩余文档和验证收尾。

**Step 7: 核对远端并 push**

Run: `git -C /Users/tangyuxuan/Desktop/Claude/HOLO remote get-url origin`

Expected: `git@github.com:Donglin5525/Holo.git`。

Push 当前 main 前再次核对 scoped commit 列表。

**Step 8: 部署 HoloBackend**

按照项目 `holo-backend-deploy` 流程：本地测试和版本确认、rsync、ECS 锁、SQLite 备份、关闭 BuildKit 重建、服务器本机健康验证、再做公网验证。

生产环境必须配置：

- Apple client IDs；
- 东林 Apple subject 白名单；
- Holo session secret；
- verify:prod 管理员凭证。

不得把任何真实值写入仓库或命令输出。

**Step 9: 生产安全验收**

验证：

- `/v1/health` 正常；
- 公网 `/v1/prompts*` 不返回正文；
- 公网 `/v1/release/status` 不含 routes/prompts/model/temperature/maxTokens；
- 管理员 release status 与 Prompt 版本验收通过；
- 伪造/普通会话无法读取内部日志；
- 东林重新 Apple 登录后内部权限为 true；
- 真机发起真实 AI 请求后能长按查看完整日志；
- 退出登录后入口立即消失。

**Step 10: 最终状态**

确认工作区只剩用户原有无关修改，汇报 commit、测试数、Release build、部署版本、生产接口证据以及仍需东林真机完成的最后一步。
