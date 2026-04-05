# 推送通知 Deep Link 跳转修复方案

> 创建日期：2026-04-06
> 状态：实施中

---

## 问题描述

用户点击推送通知后没有跳转到对应的详情页（如任务详情），只停留在首页。

## 根因分析

### 核心 Bug：冷启动时 `.task(id:)` 不触发

SwiftUI 的 `.task(id:)` 修饰器只在 `id` 值**变化**时触发闭包。冷启动时序：

1. 用户点击通知 → iOS 启动 app
2. `HoloApp.init()` 调用 `setupDelegate()`（异步 Task 包裹）
3. `didReceive` 被系统调用，设置 `DeepLinkState.shared.pendingTaskId = taskId`
4. HomeView 渲染时，`@ObservedObject var deepLinkState` 读取到 `pendingTaskId` 已有值
5. `.task(id:)` 期望检测 `id` 变化（nil → 非 nil），但初始值就是非 nil，**不触发**

热启动（后台/前台）时 HomeView 已在视图层级中，`pendingTaskId` 确实从 nil 变为目标值，所以可能正常。

### 额外问题

- `DAILY_REMINDER` 通知没有 deep link 处理（无 taskId）
- `DeepLinkState` 只有 `pendingTaskId: UUID?`，无法扩展到习惯等模块
- `HoloApp.init()` 中 `setupDelegate()` 包在 `Task {}` 里异步执行，可能在 `didReceive` 之后才执行

## 修复方案

### 1. 重构 DeepLinkState — 引入枚举目标

将 `pendingTaskId: UUID?` 替换为 `pendingTarget: DeepLinkTarget?`：

```swift
enum DeepLinkTarget: Equatable {
    case taskDetail(taskId: UUID)
    case dailyReminder        // 跳转今日任务列表
    case habitDetail(habitId: UUID)  // 未来扩展
}
```

### 2. 修复 HoloApp.init — 同步设置 delegate

```swift
init() {
    TodoNotificationService.shared.setupDelegate()        // 同步，不用 Task {}
    TodoNotificationService.shared.registerNotificationCategories()
}
```

### 3. 修改通知 delegate — 按 category 设置不同目标

```swift
case UNNotificationDefaultActionIdentifier:
    let category = response.notification.request.content.categoryIdentifier
    switch category {
    case TodoNotificationCategory.task:
        if let taskId = UUID(uuidString: taskIdString) {
            DeepLinkState.shared.pendingTarget = .taskDetail(taskId: taskId)
        }
    case TodoNotificationCategory.dailyReminder:
        DeepLinkState.shared.pendingTarget = .dailyReminder
    default: break
    }
```

### 4. 用 `.onAppear` + `.onChange` 替代 `.task(id:)`

**HomeView** 和 **TaskListView** 都改为：

```swift
.onAppear { handleDeepLink() }
.onChange(of: deepLinkState.pendingTarget) { handleDeepLink() }
```

`.onAppear` 确保冷启动时能读取已有值；`.onChange` 覆盖热启动场景。

## 修改文件清单

| 文件 | 改动 |
|------|------|
| `Services/DeepLinkState.swift` | 引入 `DeepLinkTarget` 枚举，替换 `pendingTaskId` 为 `pendingTarget` |
| `HoloApp.swift` | `setupDelegate()` 改为同步调用 |
| `Services/TodoNotificationService.swift` | `didReceive` 按 category 设置 `DeepLinkTarget` |
| `Views/HomeView.swift` | `.task(id:)` → `.onAppear` + `.onChange` + `handleDeepLink()` |
| `Views/Tasks/TaskListView.swift` | `.task(id:)` → `.onAppear` + `.onChange` + `handleDeepLink()` |

## 验证场景

| 场景 | 操作 | 预期 |
|------|------|------|
| 冷启动+任务通知 | 杀 app → 触发任务通知 → 点击 | 启动 → TasksView → TaskDetailView |
| 冷启动+每日提醒 | 杀 app → 触发每日提醒 → 点击 | 启动 → TasksView（不弹详情）|
| 后台+任务通知 | 切后台 → 触发通知 → 点击 | TasksView → TaskDetailView |
| 前台+通知 | 前台收到通知 → 点击横幅 | TasksView → TaskDetailView |
| 操作按钮 | 点击"完成任务" | 任务完成，不跳转（行为不变）|

## 当前 Deep Link 架构

```
通知点击
  ↓
TodoNotificationService.didReceive
  ↓ 设置 DeepLinkState.shared.pendingTarget
HomeView (.onAppear + .onChange)
  ↓ showTasksView = true (打开 fullScreenCover)
TasksView → TaskListView (.onAppear + .onChange)
  ↓ selectedTask = TaskSelection(id: taskId)
TaskDetailView (.sheet)
```

## 扩展性

`DeepLinkTarget` 枚举可轻松添加新的跳转目标：

```swift
case habitDetail(habitId: UUID)
case financeDetail(transactionId: UUID)
case thoughtDetail(thoughtId: UUID)
```

每个新目标只需：
1. 在 `didReceive` 中设置对应 case
2. 在 `HomeView.handleDeepLink()` 中打开对应模块
3. 在对应模块的列表视图中消费 pendingTarget
