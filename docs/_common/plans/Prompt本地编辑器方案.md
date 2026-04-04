# Prompt 本地编辑器实现方案

> 创建时间：2026-04-04
> 状态：待实施

## 背景

AI 对话模块已上线，6 个 prompt 硬编码在 `PromptManager.swift`。需要能在 App 内查看、编辑、测试 prompt 的工具，以便快速调优 AI 对话效果。不做 Web 后台，纯本地方案。

## 文件变更

| 文件 | 操作 | 说明 |
|------|------|------|
| `Services/AI/PromptManager.swift` | 修改 | 增加 UserDefaults 读写、PromptType UI 元数据 |
| `Views/Settings/PromptEditorViewModel.swift` | 新建 | 编辑器 ViewModel（保存/重置/测试） |
| `Views/Settings/PromptEditorView.swift` | 新建 | Prompt 编辑器页面 |
| `Views/Settings/PromptTestSheet.swift` | 新建 | Prompt 测试弹窗 |
| `Views/Settings/AISettingsView.swift` | 修改 | 添加 Prompt 列表入口 |

## 实现步骤

### Step 1: 修改 PromptManager.swift

**1a. PromptType 添加 UI 元数据**

```swift
var displayName: String      // "系统提示词"、"意图识别" 等
var displayDescription: String  // 一句话描述用途
var icon: String             // SF Symbol 名称
```

**1b. loadPrompt 支持 UserDefaults 覆盖**

修改 `loadPrompt` 方法：先查 UserDefaults，再 fallback 到硬编码 templates：

```swift
let raw = UserDefaults.standard.string(forKey: key) ?? templates[type]
```

**1c. 新增公开方法**

| 方法 | 用途 |
|------|------|
| `loadRawTemplate(_:)` | 返回未替换变量的原始文本（编辑器显示用） |
| `loadDefaultTemplate(_:)` | 返回硬编码默认值（对比/恢复用） |
| `saveCustomPrompt(_:content:)` | 写入 UserDefaults + 清缓存 |
| `resetCustomPrompt(_:)` | 删除 UserDefaults key + 清缓存 |
| `isCustomized(_:)` | 检查是否有自定义覆盖 |
| `static currentVariableValues()` | 返回 `{{todayDate}}` 等变量的当前解析值 |

UserDefaults key 格式：`com.holo.prompt.custom.{rawValue}`

### Step 2: 创建 PromptEditorViewModel.swift

参照 `AIConfigViewModel` 的模式：

| 属性 | 说明 |
|------|------|
| `@Published editedContent` | 编辑中的文本 |
| `@Published testInput / testResult / testError / isTesting` | 测试状态 |
| `hasUnsavedChanges` | 对比 editedContent 与初始加载内容 |
| `isCustomized` | 是否有自定义覆盖 |

| 方法 | 说明 |
|------|------|
| `save()` | 调用 PromptManager.saveCustomPrompt |
| `reset()` | 调用 PromptManager.resetCustomPrompt，更新 editedContent |
| `runTest()` | 通过 KeychainService 加载 AI 配置，用 APIClient 发送测试请求 |

测试逻辑：构建 `[systemMessage(editedPrompt), userMessage(testInput)]` 发送到 LLM，直接用 APIClient.send，复用 ChatCompletionResponse 解码。

### Step 3: 创建 PromptEditorView.swift

参照 `ThoughtEditorView` 的 UI 模式：

- NavigationView + ScrollView(showsIndicators: false)
- **信息头部**：prompt 名称 + 描述 + "已自定义"标签
- **文本编辑区**：TextEditor，卡片样式（holoCardBackground + holoRadius）
- **变量预览卡片**：显示 `{{todayDate}}` → "2026年4月4日 星期六"
- **Toolbar**：取消 / 保存 / "..."菜单（恢复默认、测试 Prompt）
- **Alert**：恢复默认确认弹窗
- **Sheet**：PromptTestSheet

### Step 4: 创建 PromptTestSheet.swift

轻量测试弹窗：

- TextField 输入测试文本
- "发送测试" 按钮
- ScrollView 显示 LLM 响应或错误信息
- `.presentationDetents([.medium])`

### Step 5: 修改 AISettingsView.swift

在 `dangerSection` 之前添加 `promptSection`：

- Section header: "Prompt 模板"
- ForEach 6 个 PromptType，每行 NavigationLink 到 PromptEditorView
- 每行显示：SF Symbol 图标 + 名称 + 描述 + "已自定义"角标

NavigationLink 可行性：AISettingsView 在 ChatView 和 SettingsView 中均被 NavigationStack 包裹，push 导航正常。

## 数据流

```
用户编辑 prompt → PromptEditorViewModel.save()
  → PromptManager.saveCustomPrompt(type, content)
    → UserDefaults 写入 + 缓存清除

AI 对话时 → PromptManager.loadPrompt(type)
  → 缓存命中？返回
  → UserDefaults 有自定义？用自定义
  → 否则用硬编码 templates[type]
  → 变量替换 → 缓存 → 返回
```

## 验证清单

- [ ] 编译运行，进入设置 → AI 设置 → Prompt 模板
- [ ] 查看每个 prompt 的默认内容，确认变量预览正确
- [ ] 编辑一个 prompt（如 systemPrompt），保存
- [ ] 返回列表确认"已自定义"标签显示
- [ ] 进入聊天页发送消息，验证自定义 prompt 生效
- [ ] 点击"恢复默认"，确认 UserDefaults 被清除
- [ ] 点击"测试 Prompt"，输入测试文本，确认 LLM 响应正常显示
