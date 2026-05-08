# HoloAI 优化：分类同步 + HoloProfile 扩展

## Context

HoloAI 的意图识别 prompt 中分类科目表是硬编码的（88 个二级分类），用户新增自定义分类后 AI 无法感知。同时 HoloProfile 个人档案仅在普通对话中注入，分析查询和记忆洞察生成中不使用。这两个问题导致 AI 对用户个性化数据的理解不完整。

---

## 问题一：自定义分类同步到 AI 意图识别

### 方案：PromptManager 变量替换动态注入

将 `intentRecognition` 模板中硬编码的分类表替换为 `{{expenseCategories}}` / `{{incomeCategories}}` 占位符，在 `replaceVariables` 中从 Core Data 实时读取用户分类并注入。

### 步骤

#### 步骤 1：PromptManager 新增分类变量替换

**文件**：`Services/AI/PromptManager.swift`

1. `replaceVariables` 方法（第 673 行）中新增：
   - 从 `FinanceRepository` 读取用户实际的一级/二级分类
   - 格式化为 Markdown 表格文本（与当前硬编码格式一致）
   - 替换 `{{expenseCategories}}` 和 `{{incomeCategories}}`
   - 如果模板中没有这两个占位符（用户自定义了 prompt），跳过替换（向后兼容）

2. 分类读取方法：新增 `private func buildCategoryTable(type: TransactionType) -> String`
   - 调用 `FinanceRepository.shared.getCategories(by: type)` 读取 Core Data 分类
   - 按一级分组，生成 `| 一级 | 二级 |` 格式的 Markdown 表格
   - 注意：需要在 MainActor 上下文中调用（`loadPrompt` 的调用链都在 MainActor 上）

#### 步骤 2：替换模板中的硬编码分类表

**文件**：`Services/AI/PromptManager.swift`

将第 235-254 行的硬编码分类表替换为：

```
### 支出
{{expenseCategories}}

### 收入
{{incomeCategories}}
```

保留第 231-234 行的说明文字和第 256 行之后的输出格式不变。

#### 步骤 3：分类变更时清除 PromptManager 缓存

**文件**：`Models/FinanceRepository+Categories.swift`

1. `addCategory` 方法（第 66 行 `context.save()` 之后）：新增发通知
2. `updateCategory` 方法（第 169 行 `context.save()` 之后）：新增发通知
3. `deleteCategory`（第 202 行）：已有通知，无需修改

建议复用现有的 `.financeDataDidChange` 通知（避免新增通知类型）。

**文件**：`Services/AI/PromptManager.swift`

1. `init()` 中监听 `.financeDataDidChange` 通知
2. 回调中调用 `clearCache()` 使缓存失效
3. 下次 `loadPrompt(.intentRecognition)` 时重新执行 `replaceVariables`（含最新分类）

#### 步骤 4：更新 Prompt 版本号

**文件**：`Services/AI/PromptManager.swift`

将 `intentRecognition` 的版本号从 4 提升到 5（第 78 行 `promptVersions` 字典）。这样用户如果之前自定义了 intentRecognition prompt（旧版本，不含 `{{expenseCategories}}` 占位符），会被自动回退到新的默认模板。

### 涉及文件

| 文件 | 改动 |
|------|------|
| `Services/AI/PromptManager.swift` | 变量替换 + 缓存监听 + 模板更新 + 版本号升级 |
| `Models/FinanceRepository+Categories.swift` | addCategory/updateCategory 补发通知 |

### Token 影响评估

- 默认分类（88 个二级）约 1000 tokens，动态注入后用户新增 5-10 个约增加 50-150 tokens
- 意图识别 prompt 总长约 2500-3000 tokens，增量在预算内

---

## 问题二：HoloProfile 扩展到分析查询和洞察生成

### 方案：分场景注入

- **分析查询**：改传实际 UserContext + 在分析模式分支追加 profile system message
- **记忆洞察**：MemoryInsightContext 新增字段 + Builder 自动填充
- **年度回顾**：同洞察方案，自动覆盖

### 步骤

#### 步骤 1：分析查询 — ChatViewModel 传实际 UserContext

**文件**：`Views/Chat/ChatViewModel.swift` 第 208 行

```swift
// 改前
userContext: UserContext.empty,
// 改后
userContext: userContext,  // 使用第 188 行已构建的 userContext
```

#### 步骤 2：分析查询 — OpenAICompatibleProvider 分析模式分支追加 profile

**文件**：`Services/AI/OpenAICompatibleProvider.swift` 第 122-129 行

在分析模式分支中，注入 contextOverride 后，额外检查 profile：

```swift
if let contextOverride = systemContextOverride {
    allMessages.append(.system(contextOverride))
    // 注入用户档案（分析场景）
    if let profile = userContext.profileContext, !profile.isEmpty {
        allMessages.append(.system("--- 用户档案 ---\n\(profile)"))
    }
} else {
    let contextMessage = buildContextMessage(userContext)
    allMessages.append(.system(contextMessage))
}
```

这样 profile 作为第三条 system message 独立注入，不侵入 AnalysisContext 结构，不改 prompt。

#### 步骤 3：记忆洞察 — MemoryInsightContext 新增字段

**文件**：`Models/MemoryInsightModels.swift` 第 176-192 行

在 `MemoryInsightContext` 结构体中新增：

```swift
let profileContext: String?  // 用户个人档案，用于个性化洞察
```

#### 步骤 4：记忆洞察 — Builder 中读取并填充 Profile

**文件**：`Services/AI/MemoryInsightContextBuilder.swift`

以下 3 处构建 `MemoryInsightContext` 的位置都需要补上新字段：

1. `build()` 方法（第 82-97 行）：调用 `await HoloProfileService.shared.loadProfile()` 获取内容，填充到 `profileContext`
2. `buildAnnualContext()` 方法（第 567-582 行）：同上
3. `emptyAnnualContext()` 方法（第 587-620 行）：填 `nil`

注意：`HoloProfileService` 是 `@MainActor`，`MemoryInsightContextBuilder` 是普通 struct，调用需要 `await`。由于 `build()` 已经是 `async` 方法，可以直接 `await`。

#### 步骤 5：记忆洞察 — enforceTokenBudget 适配

**文件**：`Services/AI/MemoryInsightContextBuilder.swift` 第 651-731 行

在 `enforceTokenBudget` 方法中：
1. 重建 `MemoryInsightContext` 时保留 `profileContext` 字段不变
2. Token 预算上调：
   - daily: 800 → 1500
   - weekly: 2000 → 3000
   - monthly: 3500 → 4500

### 涉及文件

| 文件 | 改动 |
|------|------|
| `Views/Chat/ChatViewModel.swift` | 分析查询传实际 userContext（1 行） |
| `Services/AI/OpenAICompatibleProvider.swift` | 分析模式分支追加 profile message（4 行） |
| `Models/MemoryInsightModels.swift` | MemoryInsightContext 新增 profileContext 字段 |
| `Services/AI/MemoryInsightContextBuilder.swift` | build/buildAnnualContext/emptyAnnualContext 填充 + enforceTokenBudget 适配 + 预算上调 |

---

## 实施顺序

1. 先做问题二（HoloProfile 扩展）— 改动面小且独立，无副作用
2. 再做问题一（分类同步）— 涉及 prompt 版本升级，需要更谨慎

## 验证方法

### 问题一验证
1. 在 APP 中新增一个自定义二级分类（如"购物/家政"）
2. 对 AI 说"家政花了200"
3. 确认 AI 能正确识别到自定义分类（LLM 返回的 categoryCandidate 被本地精确匹配命中）
4. 查看日志（长按 AI 消息 → 查看日志），确认 prompt 中分类表包含新增的自定义分类
5. 删除自定义分类，重新生成 prompt，确认分类表已更新

### 问题二验证
1. 编辑 HoloProfile（写入城市、职业等信息）
2. 分析查询："总结一下我最近的生活状态"，确认 AI 回复中引用了 Profile 信息
3. 生成周报洞察，确认 AI 在洞察中考虑了 Profile（如根据职业给出更相关的建议）
4. 检查 Token 预算：日报/周报/月报均能正常生成，不被截断
