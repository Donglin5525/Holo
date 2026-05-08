# HoloProfile.md 个人档案系统实现方案

## Context

HOLO 的 AI 系统当前是**无状态的**——每次对话都通过 `UserContextBuilder` 从实时数据重建上下文，没有持久的用户偏好/个性配置。这导致 AI 无法记住用户的沟通风格、职业背景、关注领域等个性化信息。

**目标**：添加一个轻量级的 `HoloProfile.md` 文件，作为用户的个人档案，所有 AI 功能（对话、报告、分析）都能读取它来实现个性化。

**方案**：V1 手动编辑 + AI 读取。存储在 app Application Support 目录，最大 8KB，UI 入口在设置页。

---

## HoloProfile.md 文件结构

存储路径：`Application Support/Holo/HoloProfile.md`，约 60-80 行，最大 8KB。

```markdown
# 关于我

- 昵称：
- 所在城市：
- 时区：Asia/Shanghai

## 角色与身份

- 职业：
- 日常角色：

## 生活节奏

- 工作日作息：9:00 - 22:00
- 周末偏好：

## 关注领域

（每行一个关注领域）

## 消费习惯

- 常见餐饮：
- 交通方式：
- 月度预算关注：

## 沟通偏好

- 回复语言：中文
- 回复风格：简洁友好
- 禁忌话题：无

## 健康与习惯目标

- 关注的习惯：
- 健康提醒偏好：当发现不健康的消费模式时，温和地提出改善建议
```

---

## 文件变更清单（V1 范围）

### 新建文件（2 个）

| 文件 | 说明 | 预估行数 |
|------|------|---------|
| `Services/AI/HoloProfileService.swift` | 核心 service：读写文件、缓存、大小校验、通知 | ~120 行 |
| `Views/Settings/HoloProfileEditorView.swift` | Markdown 编辑器 + 大小指示器 + 保存/恢复模板 | ~100 行 |

### 修改文件（4 个）

| 文件 | 变更 | 影响范围 |
|------|------|---------|
| `Models/AI/AIModels.swift` | `UserContext` 加 `profileContext: String?` | 1 行新增 |
| `Services/AI/UserContextBuilder.swift` | `buildContext()` 加载 profile 传入 UserContext | ~3 行 |
| `Services/AI/OpenAICompatibleProvider.swift` | `buildContextMessage(_:)` 末尾追加 profile 内容 | ~4 行 |
| `Views/Settings/SettingsView.swift` | "通用" section 加 "个人档案" 行 + sheet | ~10 行 |

### 编译修复（1 个）

| 文件 | 变更 |
|------|------|
| `Views/Settings/AIConfigViewModel.swift:115` | `UserContext` 构造补 `profileContext: nil` |

---

## 实现步骤

### Step 1: HoloProfileService（新建）

**路径**: `Services/AI/HoloProfileService.swift`

```swift
@MainActor
final class HoloProfileService: ObservableObject {
    static let shared = HoloProfileService()
    static let maxFileSize = 8192  // 8KB

    @Published private(set) var profileContent: String = ""
    @Published private(set) var isLoaded: Bool = false

    var hasProfile: Bool { !profileContent.isEmpty }
    func loadProfile() -> String
    func saveProfile(_ content: String) throws
    func resetToTemplate() throws
}
```

关键实现：
- `profileURL`: `FileManager.default.urls(for: .applicationSupportDirectory, ...).first!/Holo/HoloProfile.md`
- `loadProfile()`: 先查缓存 → 读磁盘 → 无文件则返回空字符串（首次不自动创建文件）
- `saveProfile(_:)`: 确保 `Holo/` 目录存在 → 校验 ≤ 8KB → 写磁盘 → 更新缓存 → 发 `Notification.Name.profileDidChange`
- 默认模板为 inline 常量（与 PromptManager 模式一致），仅在 `resetToTemplate()` 时使用

### Step 2: AIModels.swift（修改）

`AIModels.swift:205` — `UserContext` struct 加字段：
```swift
struct UserContext {
    let todayDate: String
    let transactions: TransactionSummary
    let habits: HabitSummary
    let tasks: TaskSummary
    let thoughts: ThoughtSummary
    let profileContext: String?  // 新增
}
```

同步修改 `AIConfigViewModel.swift:115` — 补 `profileContext: nil`。

### Step 3: UserContextBuilder（修改）

`UserContextBuilder.swift:33` — 在 `buildContext()` 中加载 profile：
```swift
let profileContext = HoloProfileService.shared.loadProfile()

return UserContext(
    todayDate: todayDate,
    transactions: transactions,
    habits: habits,
    tasks: tasks,
    thoughts: thoughts,
    profileContext: profileContext.isEmpty ? nil : profileContext
)
```

### Step 4: OpenAICompatibleProvider（修改）

`OpenAICompatibleProvider.swift:141` — 在 `buildContextMessage(_:)` 末尾追加：
```swift
private func buildContextMessage(_ context: UserContext) -> String {
    var message = """
    当前用户上下文：
    - 日期：\(context.todayDate)
    ...（现有内容不变）...
    """

    if let profile = context.profileContext, !profile.isEmpty {
        message += "\n\n--- 用户档案 ---\n\(profile)"
    }

    return message
}
```

### Step 5: SettingsView（修改）

`SettingsView.swift:202` — 在 "AI 助手" 行之前加 "个人档案" 行：
```swift
@State private var showProfileEditor = false

// 在 otherSettingsSection 的 VStack 中，AI 设置行之前：
settingsRow(
    icon: "person.text.rectangle",
    iconColor: .holoPrimary,
    title: "个人档案",
    subtitle: HoloProfileService.shared.hasProfile ? "已配置" : "未配置"
) {
    showProfileEditor = true
}
.sheet(isPresented: $showProfileEditor) {
    NavigationStack {
        HoloProfileEditorView()
    }
}
```

### Step 6: HoloProfileEditorView（新建）

**路径**: `Views/Settings/HoloProfileEditorView.swift`

- NavigationBar: 标题 "个人档案"，trailing 菜单（恢复模板）
- TextEditor 绑定 `@State var editedContent`
- 底部显示大小指示器："已用 X.X KB / 8.0 KB"
- 保存按钮（与 PromptEditorView 一致的模式）
- 未保存变更检测（比较初始内容与当前内容）

---

## AI 交互流程

### 读取流程（每次 AI 调用自动触发）
```
用户发消息 → ChatViewModel → UserContextBuilder.buildContext()
                              ↓
              HoloProfileService.loadProfile() → HoloProfile.md 内容
                              ↓
              UserContext(profileContext: "...") → OpenAICompatibleProvider
              ↓
              buildContextMessage() 追加 "--- 用户档案 ---" 块
              ↓
              AI 收到完整上下文（实时数据 + 个人档案）
```

---

## 安全与边界

| 关注点 | 处理方式 |
|--------|---------|
| 文件大小爆炸 | `saveProfile` 时硬性校验 ≤ 8KB |
| 文件损坏 | `loadProfile` 捕获错误，返回缓存值或空字符串 |
| 并发访问 | `@MainActor` 单例，所有操作主线程串行 |
| 上下文窗口压力 | 8KB ≈ 2000-3000 中文字符 ≈ ~1500 tokens，在中文 LLM 8K+ 上下文内安全 |
| 首次使用 | 无文件时 `profileContext` 为 nil，不注入上下文，行为与现在一致 |
| 目录不存在 | `saveProfile` 时 `createDirectory(withIntermediateDirectories:)` |

---

## 验证方式

1. **编译验证**: 确保所有修改文件编译通过
2. **功能验证**:
   - 设置 → 个人档案 → 编辑 → 保存 → 确认文件在 Application Support 目录
   - AI 对话 → 确认系统消息中包含档案内容
   - 修改档案 → 再次对话 → 确认 AI 响应风格变化
3. **边界验证**:
   - 输入超过 8KB → 确认保存被拒绝并提示
   - 无档案 → 确认 AI 行为与修改前一致
   - 恢复模板 → 确认回到默认内容

### 测试计划（8 条路径）

| # | 测试 | 类型 | 断言 |
|---|------|------|------|
| 1 | `loadProfile()` 无文件 | Unit | 返回空字符串 |
| 2 | `loadProfile()` 有文件 | Unit | 返回文件内容 |
| 3 | `saveProfile()` 正常 | Unit | 文件存在且内容匹配 |
| 4 | `saveProfile()` 超 8KB | Unit | 抛出错误，文件不变 |
| 5 | `buildContext()` 有 profile | Integration | profileContext 非空 |
| 6 | `buildContextMessage()` 有 profile | Integration | 包含 "--- 用户档案 ---" |
| 7 | 编辑器保存流程 | UI | 保存成功，大小指示器更新 |
| 8 | 编辑器恢复模板 | UI | 内容回到默认模板 |

---

## V2 延后项

| 功能 | 说明 | 额外文件 |
|------|------|---------|
| AI 写回能力 | IntentRouter + PromptManager + MockAIProvider 增加 `update_profile` 意图 | 3 个文件 |
| AI 学习笔记区 | AI 自动在 "AI 学习笔记" section 补充偏好观察 | applyPatch 方法 |
| HoloProfileSuggestionSheet | 确认卡片 UI | 1 个新文件 |
