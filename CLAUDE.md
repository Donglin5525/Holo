# HOLO - 个人数据资产 + AI 规划 iOS 应用

**技术栈**：SwiftUI, Swift 5+, MVVM, Core Data
**核心模块**：记账 ✅ | 习惯追踪 ✅ | 待办 🚧 | 健康 ✅ | 观点 📋 | AI 对话 ✅

---

## 协作规则

| 规则 | 说明 |
|------|------|
| 全局中文回复 | 所有回复使用中文 |
| 称呼东林 | 每次回答前先称呼名字 |
| 禁止兼容性代码 | 除非东林主动要求 |
| 需求模糊时 | 先提问澄清再写代码 |
| 修改 >3 个文件 | 先拆成小任务 |
| 出 Bug 时 | 先写能重现的测试再修复 |
| 被纠正后 | 反思并制定不再犯的计划 |

---

## 开发前必读

| 文档 | 用途 |
|------|------|
| `docs/_common/HoloPRD.md` | 产品需求文档 |
| `docs/_common/开发规范.md` | 开发规范与踩坑总结（编码约定、布局、Core Data 等） |
| `docs/_common/notes/` | 历史问题解决方案（含 Core Data 调试） |
| `docs/*/plans/` | 各模块实施计划（含已完成和待开发） |

> `docs/todo/` 是**待办模块的文档目录**，不是项目级待办。东林说"更新 TODO"指的是根目录 `TODO.md`。

---

## 开发流程

新功能或非平凡重构前，按以下流程推进：

| 阶段 | 说明 |
|------|------|
| 写方案 | 在 `docs/*/plans/` 下写实施计划，明确范围、数据结构、涉及文件 |
| 对抗评审 | 方案完成后做对抗性审查：检查边界遗漏、技术可行性、与现有代码冲突 |
| 实施 | 评审通过后按步骤实施，多步任务用 TaskCreate 追踪进度 |

---

## 编码约定

| 规则 | 说明 |
|------|------|
| 禁止 `!` | 用 `if let` / `guard let` |
| 禁止 `print()` | 用 `Logger` |
| 错误处理 | 必须 `try-catch` |
| ScrollView | 必须隐藏滚动条 `showsIndicators: false` |
| DatePicker | 必须中文 locale `.environment(\.locale, Locale(identifier: "zh_CN"))` |
| 日期显示 | 禁止 `Text(date, style:)` 和 `date.formatted()`，必须用 `DateFormatter` + `zh_CN` |
| 右滑返回 | fullScreenCover 加 `.swipeBackToDismiss`，push/sheet 系统自带 |
| ScrollView 手势 | 禁止 SwiftUI `DragGesture`，用 `UIViewRepresentable` + `UIPanGestureRecognizer`。方向判定**必须**复用 `HorizontalGestureLock`（见开发规范第 15 节），禁止自定义方向判断逻辑 |
| SF Symbol | 新增/修改名称时**必须先验证存在**（`NSImage(systemSymbolName:) != nil`），无效名称渲染为空白 |
| 金额显示（空间受限） | 必须用 `NumberFormatter.compactCurrency()`（万/亿单位），禁止 `fixedSize`，改用 `minimumScaleFactor(0.7)` + `lineLimit(1)` |
| 金额显示（空间充足） | 用 `NumberFormatter.currency` 完整格式，仍需加 `minimumScaleFactor(0.7)` + `lineLimit(1)` 防溢出 |
| 自定义导航栏 | HStack 必须加 `.frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)` 固定高度，仅靠 padding 无法约束 |
| Swift Charts 坐标 | `proxy.position(forX:)` 返回 **plot area 局部坐标**，不是全局坐标。触摸转换：`touch - plotFrame.minX`；Tooltip 定位：`plotFrame.minX + proxyX`。**禁止用 `proxy.value(atX:)`** 查分类轴（不可靠），改用 `proxy.position(forX:)` + 手动最近点（详见开发规范第 11 节） |

### UIImagePickerController + fullScreenCover

1. 在 `imagePickerController(_:didFinishPickingMediaWithInfo:)` 回调中立即将 UIImage 转为 Data，不要持有 UIImage 引用（其生命周期绑定 UIImagePickerController）
2. dismiss 与数据处理解耦 — 用 `onDismiss` 或 `onChange` 处理数据，不要在 dismiss 闭包中做重操作
3. 图片保存必须走后台队列，禁止在主线程做 NSData 编码

### Core Data 关系与数据刷新

- 关系**必须有反向**，缺反向 save 会卡死
- `denyDeleteRule` 放 to-many 侧（反向），to-one 侧用 `nullifyDeleteRule`
- 禁止 `refreshAllObjects()`，改为重新 fetch
- 数据变更后用 `await` 刷新，禁止 fire-and-forget
- 详见 `docs/_common/开发规范.md` 第 13 节

### CoreData 线程安全

- NSManagedObjectContext 不是线程安全的，每个线程/队列用自己的 context
- 用 `NSManagedObjectID` 跨线程传递引用，不要直接传 NSManagedObject

### SwiftUI 生命周期

- `fullScreenCover` 的 `onDismiss` 只负责 UI 状态重置，不处理业务逻辑
- 异步操作用 `Task {}` 包裹，不要在 View body 中直接触发

### 修复策略

- 同一 bug 修两次未果 → **停下来找根因**，禁止叠补丁；先查 `docs/_common/开发规范.md` 对应章节，看是否已有同类踩坑记录
- 黑屏/卡死 / 启动阻塞 → **先查 `docs/_common/开发规范.md` 第 10 节**（首次启动卡死排查规范），按 Checklist 逐项排查，不能只盯 CoreDataStack
- "位置对不上" → 先检查是否存在两套独立的坐标/角度计算逻辑
- Repository `init()` 必须零 I/O（`@StateObject` 在 body 求值时同步创建，早于 `.task`）
- 启动阻塞的解法是「默认值先渲染 + 后台补数据」，不是「异步优化」
- 数据变更后页面不更新 → 查开发规范第 13 节 Checklist

---

## 提交规范

**Scope**：`iOS` / `icon` / `docs`
**格式**：`feat(iOS): 描述` / `fix(iOS): 描述` / `docs: 描述`

**提交流程**：`git add` → `git commit` → 更新 `CHANGELOG.md` + `TODO.md` → `git push`

**提交前**：编译通过 | 无 `print()` / force unwrap | CHANGELOG 已更新

---

## 模块文档

编辑某模块的 Models / Repository / Service 前，先读对应 CLAUDE.md：

| 模块 | 路径 |
|------|------|
| AI 对话 | `docs/_common/Chat模块文档.md` |
| 财务 | `Views/Finance/CLAUDE.md` |
| 待办 | `Views/Tasks/CLAUDE.md` |
| 习惯 | `Views/Habits/CLAUDE.md` |
| 健康 | `Views/Health/CLAUDE.md` |
| 观点 | `Views/Thoughts/CLAUDE.md` |
| 记忆画廊 | `Views/MemoryGallery/CLAUDE.md` |

---

## 后端网关架构

Holo 的 AI/ASR 调用已从客户端直连大模型改为经阿里云后端网关统一代理，客户端不再持有 API Key。

**架构**：`iOS App → Holo AI Gateway (阿里云 ECS 123.56.104.9:8787) → LLM / DashScope ASR`

**方案文档**：`docs/_common/plans/HoloAI商用后端网关MVP方案.md`

### 后端代码（HoloBackend/）

| 文件 | 说明 |
|------|------|
| `src/app.js` | Hono 路由，4 组端点 |
| `src/config.js` | 模型路由配置（chat/intent/insight 各自独立 provider/model/temperature） |
| `src/server.js` | Node 服务入口 |
| `src/errors.js` | GatewayError，中文错误消息 |
| `src/providers/dashScopeAsrProvider.js` | DashScope ASR WebSocket 转写 |
| `src/providers/openAICompatibleProvider.js` | 通用 LLM 转发 |
| `src/usage/inMemoryUsageStore.js` | 设备级内存限流 |

**API 端点**：`/v1/health` | `/v1/app-attest/challenge` | `/v1/ai/chat/completions` | `/v1/asr/transcriptions`

**部署**：Docker Compose + Nginx，配置在 `HoloBackend/deploy/`

### HoloBackend 管理后台

HoloBackend 内置内部管理后台，供开发者调试 AI 调用、查看日志和管理 Prompt，不面向普通 App 用户开放。

| 入口 | 说明 |
|------|------|
| `/admin/login` | 管理后台登录 |
| `/admin/logs` | AI 调用日志、测试调用、请求/响应明细 |
| `/admin/prompts` | Prompt 管理列表 |
| `/admin/prompts/:type` | Prompt 查看、编辑、保存、恢复默认 |

鉴权：
- 使用 `HOLO_ADMIN_USERNAME` / `HOLO_ADMIN_PASSWORD` 登录
- 登录后使用 HttpOnly Cookie
- `HOLO_ADMIN_TOKEN` 仅保留给脚本或 curl 调试
- 禁止将真实密码、session secret、API Key、用户日志写入文档或提交到 git

Prompt 管理：
- 默认 Prompt 来源：`HoloBackend/src/prompts/defaultPrompts.json`
- 后台编辑后的 Prompt 写入：`HoloBackend/src/prompts/managedPrompts.json`
- `/v1/prompts/:type` 优先返回 managed 版本，无 managed 版本则回退 default
- App 普通用户不能手动调整 Prompt；管理后台仅供开发者内部调试和发布前校准

### Prompt 双端同步（重要）

**Prompt 加载优先级**：`HoloBackendAIProvider.loadManagedPrompt` 优先后端 API，失败才回退本地 `PromptManager`。因此 **iOS 端 PromptManager.swift 的模板只是后备**，实际运行时以后端为准。

**修改 Prompt 的完整流程**：
1. 修改 iOS 端 `PromptManager.swift` 内嵌模板（后备）
2. 同步修改后端 `HoloBackend/src/prompts/defaultPrompts.json`（生效端）
3. 升级 `PromptManager.promptVersions` 版本号
4. **必须重新部署后端**：`ssh root@123.56.104.9` → `cd /root/Holo/HoloBackend/deploy` → `docker compose build --no-cache && docker compose up -d`
5. 部署后验证：`curl http://localhost:8787/v1/prompts/intent_recognition` 确认版本和内容

**常见陷阱**：
- 只改 iOS 端 PromptManager 不改后端 → 不生效（后端优先）
- 改了后端源文件但没重建 Docker 镜像 → 不生效（源码 baked 进镜像，非 volume 挂载）
- Docker compose restart 不够 → 需 `build --no-cache` 重建镜像
- iOS 端 `HoloBackendPromptService` 有 2 分钟 metaTTL 缓存 → 部署后杀掉 App 重开

日志：
- `/admin/logs` 记录 `/v1/ai/chat/completions` 的请求、响应、provider、model、耗时和错误
- 日志当前仅保存在后端进程内存中，服务重启后清空
- 当前不记录 ASR 音频二进制内容
- 真机 App 默认后端为 `HoloBackendEnvironment.baseURL`，若要在本地后台看真机日志，需让真机临时连接电脑局域网地址，例如 `http://<Mac局域网IP>:8787`

### iOS 集成

| 文件 | 说明 |
|------|------|
| `Services/AI/HoloBackendEnvironment.swift` | DEBUG/Release 环境切换，默认后端地址 |
| `Services/AI/HoloBackendAIProvider.swift` | 替代 OpenAICompatibleProvider，走后端网关 |
| `Services/Speech/HoloBackendSpeechRecognitionProvider.swift` | 录音上传到后端转写 |

- Debug 环境已默认接入后端；Release 暂未启用
- `AliyunQwenASRRealtimeProvider.swift`（客户端直连方案）将在后端方案上线后废弃

> 涉及 AI/ASR 的改动需同时考虑 iOS 端和后端两侧。后端代码在 `HoloBackend/`，iOS 集成在 `Services/AI/HoloBackend*.swift`。后端待完成项见 `TODO.md`「后端网关」章节。

---

## HoloAI 智能系统

**全景文档**：`docs/_common/AI能力全景(A+B+C).md`

**主动交互（5 类）**：对话助手（15 种意图）| 数据分析（5 域）| 记忆洞察回放（8 种卡片）| 个性化配置（Provider/Prompt/Profile）| 智能分类学习

**被动交互（5 类）**：后台自动生成 | 定时通知 | 异常检测 | 跨域关联 | 去重缓存

**核心文件**：`Services/AI/`（27 文件）| `Models/AI/`（7 文件）| `Views/Chat/`（11 文件）| `Views/MemoryGallery/`（17 文件）| `Views/Settings/`（6 文件）| `HoloBackend/`（后端网关）

---

## 禁止操作

- 修改 Xcode 项目配置（签名和 Bundle ID）
- Force push 到 main
- 删除整个目录
