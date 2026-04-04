# HOLO AI 联网接入规划

> **创建日期**：2026-04-02
> **状态**：✅ 已完成（2026-04-04）

---

## Context

HOLO 目前已实现记账、习惯打卡、待办、观点等模块（本地 Core Data 存储），AI 对话标签页是占位状态（"功能开发中..."）。东林准备开始接入大模型，需要明确准备工作、是否需要后台管理提示词、以及整体架构设计。

---

## 一、关于「是否需要后台」的结论

**当前阶段：不需要后台，本地 JSON 文件管理提示词即可。**

理由：
1. PRD 已明确："Prompt 模板存储在本地配置文件中，支持远程更新（预留）"
2. App 目前是纯本地架构（无用户系统、无服务端），为提示词单独建后台是架构异常
3. 提示词迭代可通过 App 发版完成（JSON 文件独立于代码，改 JSON 即可）
4. 6 种提示词类型属于静态模板，不需要实时变更

**什么时候需要后台：**
- 需要 A/B 测试不同提示词版本时
- 需要每天/每周动态更新提示词时（如季节性文案）
- Phase 2 上线用户账户+云端同步时，自然引入后端

**推荐策略：** 本地 JSON 存提示词 + 预留 `PromptVersion` 远程检查接口（Phase 3 再实现）

---

## 二、准备工作清单（写代码前必须完成）

| # | 准备项 | 说明 |
|---|--------|------|
| 1 | 注册大模型 API 账号 | 推荐先从 OpenAI 开始（SSE 格式最简单、文档最好） |
| 2 | 获取 API Key 并用 curl 测试 | 验证 API 可用、测试流式响应格式 |
| 3 | 确定首发支持的 Provider | 建议首发 OpenAI（gpt-4o-mini 做意图识别，成本低），后续加 Anthropic |
| 4 | 创建 `docs/chat/plans/` 目录 | 存放 AI 相关规划文档 |
| 5 | 设计提示词 JSON 格式 | 确定 JSON schema，方便后续独立迭代提示词 |

---

## 三、整体架构设计

在现有 MVVM + Repository 基础上，新增 3 个子层：

```
┌─────────────────────────────────────────────────────┐
│  Views / Chat/          ← 对话 UI 层（新增）         │
│  ChatView, MessageBubble, StreamingText, ChatInput  │
├─────────────────────────────────────────────────────┤
│  ViewModels/            ← 对话 ViewModel（新增）     │
│  ChatViewModel, AIConfigViewModel                   │
├─────────────────────────────────────────────────────┤
│  Services / AI/         ← AI 服务层（新增）          │
│  AIProvider协议, OpenAIProvider, PromptManager,      │
│  UserContextBuilder, IntentRouter                    │
├─────────────────────────────────────────────────────┤
│  Services / Network/    ← 网络层（新增）             │
│  APIClient, APIError, APIRequest, SSEParser         │
├─────────────────────────────────────────────────────┤
│  Services / Security/   ← 安全层（新增）             │
│  KeychainService                                     │
├─────────────────────────────────────────────────────┤
│  Data / Repositories/   ← 数据持久层（扩展）         │
│  ChatMessageRepository, OfflineQueueRepository (新增)│
├─────────────────────────────────────────────────────┤
│  Models / AI/           ← AI 模型定义（新增）        │
│  AIModels, AIConfiguration, ChatMessage+CoreData     │
├─────────────────────────────────────────────────────┤
│  Resources / Prompts/   ← 提示词模板（新增）         │
│  intent_recognition.json, daily_summary.json, ...    │
└─────────────────────────────────────────────────────┘
```

**数据流：** View → ViewModel → AI Service → Network Client → LLM API
**不跨层：** ViewModel 不直接访问网络层，全部通过 Service 对象中转

---

## 四、关键技术决策

| 决策项 | 选择 | 理由 |
|--------|------|------|
| 流式响应 | SSE（Server-Sent Events） | OpenAI/Anthropic 都用 SSE 流式，标准 HTTPS 即可，无需 WebSocket |
| API Key 存储 | Keychain（Security 框架） | iOS 安全存储标准，不能存 UserDefaults |
| 网络库 | 原生 URLSession + async/await | 与 PRD 一致，无第三方依赖 |
| 提示词存储 | 本地 JSON 文件 | 随 App 分发，独立于代码更新 |
| 多 Provider | Protocol 抽象 | AIProvider 协议，OpenAI/Anthropic 各自实现 |
| 对话历史 | Core Data 新实体 ChatMessage | 与现有数据层一致 |
| 离线处理 | Core Data OfflineQueue + NWPathMonitor | 无网络时入队，恢复后自动重试 |

---

## 五、新增文件清单

```
Holo/Holo APP/Holo/Holo/
├── Services/
│   └── AI/                              ** 新增目录 **
│       ├── AIProvider.swift             协议定义 + 共享类型
│       ├── OpenAIProvider.swift         OpenAI Chat Completions 实现
│       ├── PromptManager.swift          加载/缓存/变量替换提示词
│       ├── UserContextBuilder.swift      从各 Repository 组装用户上下文
│       └── IntentRouter.swift           解析结果 → 调用对应 Repository 操作
│   └── Network/                         ** 新增目录 **
│       ├── APIClient.swift              URLSession 基础客户端
│       ├── APIError.swift               错误类型定义
│       ├── APIRequest.swift             请求构建
│       └── SSEParser.swift              SSE 流式解析器
│   └── Security/                        ** 新增目录 **
│       └── KeychainService.swift        Keychain CRUD
│
├── Data/Repositories/
│   ├── ChatMessageRepository.swift      ** 新增 **
│   └── OfflineQueueRepository.swift     ** 新增 **
│
├── Models/AI/                           ** 新增目录 **
│   ├── AIModels.swift                   ParsedResult, UserContext 等
│   ├── AIConfiguration.swift            Provider/Model/Temperature 配置
│   ├── ChatMessage+CoreDataClass.swift
│   ├── ChatMessage+CoreDataProperties.swift
│   ├── OfflineQueue+CoreDataClass.swift
│   └── OfflineQueue+CoreDataProperties.swift
│
├── ViewModels/                          ** 新增目录 **
│   ├── ChatViewModel.swift              对话状态管理 + 流式处理
│   └── AIConfigViewModel.swift          AI 设置管理
│
├── Views/Chat/                          ** 新增目录 **
│   ├── ChatView.swift                   对话主界面
│   ├── MessageBubbleView.swift          消息气泡
│   ├── StreamingTextView.swift          流式文本渲染
│   ├── QuickActionBar.swift             快捷模板栏
│   └── ChatInputView.swift              输入框 + 发送
│
├── Views/Settings/
│   └── AISettingsView.swift             ** 新增 ** AI 设置页
│
└── Resources/Prompts/                   ** 新增目录 **
    ├── intent_recognition.json          意图识别提示词
    ├── daily_summary.json               每日总结提示词
    ├── weekly_review.json               每周复盘提示词
    ├── mood_analysis.json               情绪分析提示词
    ├── planning_advice.json             规划建议提示词
    └── casual_chat.json                 闲聊对话提示词
```

**需修改的现有文件：**
- `CoreDataStack.swift` — 添加 ChatMessage、OfflineQueue 实体定义
- `ContentView.swift` — `.holo` tab 从 PlaceholderView 改为 ChatView

---

## 六、实施阶段

### Phase 1：基础网络层（3-4 天）

目标：能调用大模型 API 并获得响应

| 步骤 | 文件 | 内容 |
|------|------|------|
| 1.1 | `AIModels.swift` | 所有 AI 相关类型定义（UserIntent, ParsedResult, UserContext 等） |
| 1.2 | `KeychainService.swift` | Keychain 增删改查，安全存 API Key |
| 1.3 | `APIError.swift` | 网络错误类型（无网络、限流、服务端错误、流中断等） |
| 1.4 | `APIRequest.swift` | HTTP 方法、Header 构建、JSON Body 编码 |
| 1.5 | `APIClient.swift` | URLSession 请求执行 + 指数退避重试（最多 3 次） |
| 1.6 | `SSEParser.swift` | SSE 字节流解析，处理 chunk 边界问题 |
| 1.7 | `AIProvider.swift` | 协议：parseUserInput / chat / chatStreaming |
| 1.8 | `OpenAIProvider.swift` | 首个具体实现，调 OpenAI API |

**验证：** 写一个测试函数，输入字符串 → 调 OpenAI API → 打印解析结果

### Phase 2：提示词 + 配置管理（2 天）

目标：提示词可加载、可注入用户数据

| 步骤 | 文件 | 内容 |
|------|------|------|
| 2.1 | 6 个 Prompt JSON 文件 | 按 schema 编写 6 种提示词模板 |
| 2.2 | `PromptManager.swift` | 从 Bundle 加载 JSON + 变量替换 + 缓存 |
| 2.3 | `AIConfiguration.swift` | Provider/Model/Temperature/MaxTokens 配置结构 |
| 2.4 | `AIConfigViewModel.swift` | 管理 AI 设置，持久化到 Keychain + UserDefaults |
| 2.5 | `UserContextBuilder.swift` | 从 Finance/Todo/Habit/Thought/Health Repo 收集上下文 |

**验证：** 单元测试 — 加载提示词、替换变量、UserContextBuilder 能收集真实数据

### Phase 3：Core Data 扩展（2 天）

目标：对话历史和离线队列可持久化

| 步骤 | 文件 | 内容 |
|------|------|------|
| 3.1 | `CoreDataStack.swift` (改) | 添加 ChatMessage 实体（8 个属性） |
| 3.2 | `ChatMessage+CoreData*.swift` | NSManagedObject 子类 |
| 3.3 | `CoreDataStack.swift` (改) | 添加 OfflineQueue 实体（8 个属性） |
| 3.4 | `OfflineQueue+CoreData*.swift` | NSManagedObject 子类 |
| 3.5 | `ChatMessageRepository.swift` | CRUD + 分页 + 最新 N 条 |
| 3.6 | `OfflineQueueRepository.swift` | 入队/出队/按状态查询 |
| 3.7 | 迁移测试 | 确认现有数据不受影响 |

**验证：** App 正常启动，新实体可 CRUD，已有数据完好

### Phase 4：AI 服务层（4-5 天）

目标：完整的意图识别 → 数据创建管道

| 步骤 | 文件 | 内容 |
|------|------|------|
| 4.1 | `IntentRouter.swift` | ParsedResult → 调用对应 Repository 创建记录 |
| 4.2 | `OfflineQueueService.swift` | NWPathMonitor 监听网络 + 队列处理 |
| 4.3 | `ChatViewModel.swift` | 对话状态 + 发消息 + 流式接收 + 触发 IntentRouter |
| 4.4 | 多轮对话上下文 | 维护内存中的 ChatMessage 历史，API 调用时带上 |
| 4.5 | 洞察生成 | 每日总结：PromptManager + UserContextBuilder + Provider |
| 4.6 | 各模块串联 | IntentRouter 实际创建 Transaction / Task / HabitRecord |

**验证：** 输入"午饭花了35块" → AI 识别为支出 → 创建 Transaction → 返回确认消息

### Phase 5：UI 集成（4-5 天）

目标：可用的对话界面替换占位符

| 步骤 | 文件 | 内容 |
|------|------|------|
| 5.1 | `ChatView.swift` | 主对话布局（消息列表 + 底部输入栏） |
| 5.2 | `MessageBubbleView.swift` | 用户/AI 消息区分，支持确认卡片 |
| 5.3 | `StreamingTextView.swift` | 实时 token 渲染 |
| 5.4 | `ChatInputView.swift` | 输入框 + 发送按钮 |
| 5.5 | `QuickActionBar.swift` | 快捷模板横滚栏（记一笔/新任务/记心情/记体重/打卡） |
| 5.6 | `ContentView.swift` (改) | `.holo` → ChatView |
| 5.7 | `AISettingsView.swift` | Provider 选择、API Key 输入、模型/温度设置 |
| 5.8 | `SettingsView.swift` (改) | 添加 AI 设置入口 |

**验证：** 打开对话 Tab → 输入自然语言 → 看到流式 AI 回复 → 数据实际落库

---

## 七、风险与应对

| 风险 | 应对策略 |
|------|---------|
| SSE 解析在 chunk 边界断裂 | 解析器按字节缓冲，按 `\n\n` 分割事件，处理 UTF-8 跨 chunk |
| 意图识别准确率不够 | 快捷模板作兜底、置信度 < 0.7 时追问、创建前显示确认卡片 |
| API 成本过高 | 意图识别用 gpt-4o-mini、洞察生成用大模型、设每日 token 上限 |
| Core Data 迁移出问题 | 新实体与旧实体无关联，轻量迁移已启用，安全 |
| 流式渲染卡顿 | token 批量更新（50ms/次）、LazyVStack、禁用逐 token 动画 |

---

## 八、参考实现

现有项目中需参考的关键文件：

| 文件 | 参考目的 |
|------|---------|
| `FinanceRepository.swift` | @MainActor 单例 Repository 模式参考 |
| `CategoryMatcherService.swift` | Service 单例模式参考 |
| `CoreDataStack.swift` | 编程式 Core Data 实体定义参考 |
| `ThoughtRepository.swift` | 较新的 Repository 写法参考 |
| `ContentView.swift` | Tab 路由修改点 |
| `docs/_common/HoloPRD.md` §3.8 | AIProvider 协议、数据结构权威定义 |
