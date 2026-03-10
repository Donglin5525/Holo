---
name: todo-sync-after-commit
description: 每次 git commit 后自动更新 TODO 列表状态。在用户执行 commit 操作后，分析提交内容并同步更新相关的 TODO 任务状态。适用于需要追踪开发进度的项目。
---

# Commit 后更新 TODO

## 触发时机

在以下情况**必须**执行此技能：

1. 用户刚完成 `git commit` 操作
2. 用户请求创建 commit
3. commit 成功后（非失败情况）

## 工作流程

### 步骤 1：获取提交信息

```bash
# 获取最新提交的详细信息
git log -1 --pretty=format:"%h %s" --stat
```

### 步骤 2：分析提交内容

根据 commit message 和修改的文件，判断哪些 TODO 任务被完成：

| Commit 类型 | 处理方式 |
|------------|---------|
| `feat: xxx` | 检查是否实现了某个待开发功能 |
| `fix: xxx` | 检查是否修复了某个待修复问题 |
| `refactor: xxx` | 通常不改变 TODO 状态 |
| `docs: xxx` | 通常不改变 TODO 状态 |

### 步骤 3：更新 TODO 列表

使用 `TodoWrite` 工具更新任务状态：

```javascript
// 将完成的任务标记为 completed
TodoWrite({
  todos: [
    { id: "x", content: "任务描述", status: "completed" },
    // 其他任务保持不变或更新状态
  ],
  merge: true
})
```

### 步骤 4：输出更新结果

向用户汇报：

```markdown
## TODO 更新完成

✅ 已完成：
- [任务名称] - [commit hash]

⏳ 进行中：
- [任务名称]

📋 待开始：
- [任务名称]
```

## 匹配规则

### 自动匹配

| 修改文件 | 关联 TODO |
|---------|----------|
| `FinanceView.swift` | 月份选择器相关 |
| `HomeView.swift` | 首页跳转/语音助手相关 |
| `AddTransactionSheet.swift` | 记账相关 |

### 关键词匹配

从 commit message 中提取关键词，匹配 TODO 内容：

- 「月份选择器」→ `实现财务页月份选择器`
- 「语音助手」→ `实现语音助手激活功能`
- 「任务页面」→ `实现跳转到任务页面`
- 「健康页面」→ `实现跳转到健康页面`
- 「个人中心」→ `实现跳转到个人中心`
- 「观点页面」→ `实现跳转到观点页面`

## 注意事项

1. **不要重复标记**：已完成的任务不要再次标记
2. **保守原则**：不确定是否完成时，不要标记为 completed
3. **保持同步**：如果代码中的 TODO 注释被删除，应标记任务完成
4. **新增任务**：如果发现新的 TODO 注释，应添加到任务列表
