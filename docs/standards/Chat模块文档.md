# AI 对话模块

## 架构概览

```
用户输入 → ChatViewModel → AIProvider.parseUserInput() → ParsedResult
                                                        │
                                            高置信度 ────┤
                                            │            └── IntentRouter.route() → 本地 CRUD
                                            └── 低置信度/unknown → 追问提示
                                            └── query → AIProvider.chatStreaming() → 流式文本
```

## 文件清单

### Views/Chat/
| 文件 | 职责 |
|------|------|
| `ChatView.swift` | 对话主界面，卡片点击导航，实体跳转 |
| `ChatViewModel.swift` | 消息收发、意图识别、路由分发、QuickAction 定义 |
| `MessageBubbleView.swift` | 消息气泡渲染，意图标签（图标+文案），卡片视图集成 |
| `ChatInputView.swift` | 多行输入框 + 发送/停止按钮 |
| `QuickActionBar.swift` | 横向滚动快捷操作栏（8 个按钮） |
| `StreamingTextView.swift` | 流式文本渲染（纯文本 → Markdown 切换） |
| `Cards/` | 5 种卡片视图：Transaction、Task、HabitCheckIn、Mood、Weight |

### Models/AI/
| 文件 | 职责 |
|------|------|
| `AIModels.swift` | AIIntent（14 个）、ParsedResult、LinkedEntity、UserContext、DTO |
| `AIConfiguration.swift` | AIProviderType（5 个 Provider）、AIProviderConfig |
| `ChatCardData.swift` | 卡片数据工厂、CategorySFSymbolMapper |

### Services/AI/
| 文件 | 职责 |
|------|------|
| `IntentRouter.swift` | 意图路由器：RouteResult（双写）、12 个 handler、任务搜索匹配 |
| `PromptManager.swift` | 提示词管理（内嵌模板 + UserDefaults 自定义覆盖） |
| `UserContextBuilder.swift` | 从各 Repository 构建用户上下文 |
| `AIProvider.swift` | Provider 协议定义 |
| `OpenAICompatibleProvider.swift` | OpenAI 兼容 API 实现 |
| `MockAIProvider.swift` | 开发调试 Mock |

## AIIntent 意图列表（14 个）

| 类别 | 意图 | rawValue |
|------|------|----------|
| 记账 | recordExpense | record_expense |
| 记账 | recordIncome | record_income |
| 任务 | createTask | create_task |
| 任务 | completeTask | complete_task |
| 任务 | updateTask | update_task |
| 任务 | deleteTask | delete_task |
| 习惯 | checkIn | check_in |
| 笔记 | createNote | create_note |
| 健康 | recordMood | record_mood |
| 健康 | recordWeight | record_weight |
| 查询 | queryTasks | query_tasks |
| 查询 | queryHabits | query_habits |
| 查询 | query | query |
| 兜底 | unknown | unknown |

## 实体链接系统

**双写策略**：所有操作同时写入旧字段（transactionId/taskId/habitId/thoughtId）和新格式（entityType+entityId）。

- `RouteResult.linkedEntity` — 路由时设置
- `ChatMessage.linkedEntity` — 从 extractedDataJSON 解析（新格式优先，旧格式兜底）
- `ChatMessage.linkedTransactionId` / `linkedTaskId` — 旧格式，保留兼容

## 任务搜索匹配算法

三级优先排序：
1. 标题精确匹配（忽略大小写）
2. 标题包含关键词
3. 备注包含关键词

同优先级按创建时间倒序。仅搜索未完成且未软删除的活跃任务。

## 修改此模块时注意

- 修改 `AIIntent` 枚举后必须同步更新：`IntentRouter.route()` switch、`ChatCardData.from()` switch、`MessageBubbleView` intentIcon/intentLabel、`MockAIProvider` 关键词
- `PromptManager` 有 UserDefaults 缓存覆盖机制，修改模板后需要重置缓存
- `ChatViewModel` 中 `// ENERGY:` 标记为 Phase 5 能量系统预留位
- 卡片数据来自 `extractedDataJSON` 快照，不实时查询 Repository
