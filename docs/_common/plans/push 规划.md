# iOS Push 通知功能实施计划

> **💡 开发者账号说明**
>
> 本规划使用 **本地通知 (Local Notifications)** 实现，**不需要付费的开发者账号**。
>
> | 方案 | 需要开发者账号 | 本规划采用 |
> |------|---------------|-----------|
> | 本地通知 | ❌ 不需要 | ✅ 是 |
> | 远程推送 (APNs) | ✅ 需要 ($99/年) | ❌ 否 |
>
> 免费Apple ID 即可完成全部开发和测试，模拟器和真机都支持。

## Context

HOLO iOS 应用的 Todo 模块需要添加完整的本地通知提醒功能，以支持任务截止提醒、定时提醒和智能提醒（为 AI 功能预留）。

### 当前状态

| 项目 | 状态 | 说明 |
|------|------|------|
| 本地通知框架 | ✅ 无需配置 | UserNotifications 系统自带 |
| Push Notification capability | ⚠️ 可选 | 仅远程推送需要，本规划不需要 |
| 本地通知服务 | ✅ 已实现 | `TodoNotificationService.swift` 基础功能完整 |
| TaskReminder 结构体 | ✅ 已定义 | 预设选项完整 |
| TodoTask.reminders 字段 | ❌ 缺失 | 需要添加到数据模型 |
| 提醒设置 UI | ❌ 未实现 | `AddTaskSheet` 中无提醒选择器 |
| 定时提醒 | ❌ 未实现 | 需要添加每日提醒功能 |
| 智能提醒预留 | ❌ 未实现 | 需要添加 AI 扩展字段 |

---

## 实施计划概览

| 阶段 | 内容 | 需要开发者账号 |
|------|------|---------------|
| Phase 1 | 数据模型扩展 | ❌ 否 |
| Phase 2 | 通知服务增强 | ❌ 否 |
| Phase 3 | UI 组件开发 | ❌ 否 |
| Phase 4 | 全局设置 | ❌ 否 |
| Phase 5 | App 生命周期集成 | ❌ 否 |
| Phase 6 | Xcode 配置 | ⚠️ 可选（仅远程推送需要） |
| Phase 7 | 数据迁移策略 | ❌ 否 |

---

## 实施计划

### Phase 1: 数据模型扩展

**文件**: `Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift`

在 TodoTask 实体定义中（约第 760 行后，`taskUpdatedAt` 之后）添加以下属性：

```swift
// 1. 截止提醒设置（JSON 存储，支持多个提醒时间）
let taskReminders = NSAttributeDescription()
taskReminders.name = "reminders"
taskReminders.attributeType = .transformableAttributeType
taskReminders.isOptional = true
taskReminders.defaultValue = nil
todoTaskAttributes.append(taskReminders)

// 2. 定时提醒开关（每日固定时间提醒）
let taskHasDailyReminder = NSAttributeDescription()
taskHasDailyReminder.name = "hasDailyReminder"
taskHasDailyReminder.attributeType = .booleanAttributeType
taskHasDailyReminder.isOptional = false
taskHasDailyReminder.defaultValue = false
todoTaskAttributes.append(taskHasDailyReminder)

// 3. AI 智能提醒预留字段
// 智能提醒启用开关
let taskSmartReminderEnabled = NSAttributeDescription()
taskSmartReminderEnabled.name = "smartReminderEnabled"
taskSmartReminderEnabled.attributeType = .booleanAttributeType
taskSmartReminderEnabled.isOptional = false
taskSmartReminderEnabled.defaultValue = false
todoTaskAttributes.append(taskSmartReminderEnabled)

// 智能提醒调度配置（JSON 存储，AI 生成的提醒计划）
let taskSmartReminderSchedule = NSAttributeDescription()
taskSmartReminderSchedule.name = "smartReminderSchedule"
taskSmartReminderSchedule.attributeType = .transformableAttributeType
taskSmartReminderSchedule.isOptional = true
todoTaskAttributes.append(taskSmartReminderSchedule)
```

同时在 `TodoTask+CoreDataClass.swift` 和 `TodoTask+CoreDataProperties.swift` 中添加对应的 `@NSManaged` 属性和便利属性。

---

### Phase 2: 通知服务增强

**文件**: `Holo/Holo APP/Holo/Holo/Services/TodoNotificationService.swift`

#### 2.1 添加定时提醒功能

```swift
// MARK: - Daily Reminder

/// 设置每日提醒时间
func scheduleDailyReminder(at hour: Int, minute: Int) async throws

/// 取消每日提醒
func cancelDailyReminder() async
```

#### 2.2 添加智能提醒预留接口

```swift
// MARK: - Smart Reminder (AI 预留)

/// 智能提醒配置结构
struct SmartReminderSchedule: Codable {
    let id: UUID
    let triggerTimes: [Date]          // AI 计算的触发时间
    let reasoning: String?             // AI 推理原因（可选，用于调试）
    let algorithmVersion: String       // 算法版本（用于兼容性）
}

/// 应用智能提醒计划
func applySmartReminderSchedule(
    for task: TodoTask,
    schedule: SmartReminderSchedule
) async throws
```

#### 2.3 改进通知委托

添加通知分类和操作按钮（完成/稍后提醒）：

```swift
/// 注册通知分类
func registerNotificationCategories() {
    let completeAction = UNNotificationAction(
        identifier: "COMPLETE_TASK",
        title: "完成任务",
        options: .authenticationRequired
    )

    let snoozeAction = UNNotificationAction(
        identifier: "SNOOZE_TASK",
        title: "15分钟后提醒",
        options: []
    )

    let category = UNNotificationCategory(
        identifier: "TODO_TASK",
        actions: [completeAction, snoozeAction],
        intentIdentifiers: []
    )

    UNUserNotificationCenter.current()
        .setNotificationCategories([category])
}
```

---

### Phase 3: UI 组件开发

#### 3.1 创建提醒选择器组件

**新文件**: `Holo/Holo APP/Holo/Holo/Views/Tasks/ReminderPicker.swift`

```swift
struct ReminderPicker: View {
    @Binding var selectedReminders: Set<TaskReminder>
    let hasDueDate: Bool
}
```

功能：
- 多选预设提醒时间（截止时间、5分钟前、15分钟前...）
- 如果没有截止日期，禁用提醒选择
- 显示已选提醒数量

#### 3.2 创建定时提醒设置组件

**新文件**: `Holo/Holo APP/Holo/Holo/Views/Tasks/DailyReminderSettings.swift`

```swift
struct DailyReminderSettings: View {
    @Binding var isEnabled: Bool
    @Binding var reminderTime: Date
}
```

功能：
- 开关控制是否启用每日提醒
- 时间选择器设置提醒时间
- 仅在全局设置中生效（非单个任务）

#### 3.3 集成到 AddTaskSheet

**修改文件**: `Holo/Holo APP/Holo/Holo/Views/Tasks/AddTaskSheet.swift`

在 `dueDateSection` 后添加：

```swift
// 提醒设置
if hasDueDate {
    reminderSection
}
```

---

### Phase 4: 全局设置

#### 4.1 创建通知设置页面

**新文件**: `Holo/Holo APP/Holo/Holo/Views/Settings/NotificationSettingsView.swift`

功能：
- 请求通知权限按钮
- 每日提醒开关和时间设置
- 智能提醒开关（预留）
- 通知预览按钮（发送测试通知）

#### 4.2 集成到设置入口

在 `TasksView` 中添加设置入口，或在全局设置页面中添加通知设置部分。

---

### Phase 5: App 生命周期集成

**修改文件**: `Holo/Holo APP/Holo/Holo/HoloApp.swift`

#### 5.1 初始化通知服务

```swift
@main
struct HoloApp: App {
    @StateObject private var darkModeManager = DarkModeManager.shared
    @StateObject private var notificationService = TodoNotificationService.shared

    init() {
        // 设置通知代理
        TodoNotificationService.shared.setupDelegate()
        // 注册通知分类
        TodoNotificationService.shared.registerNotificationCategories()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(darkModeManager.colorScheme)
                .onAppear {
                    // 首次启动检查通知权限
                    Task {
                        await checkNotificationPermission()
                    }
                }
        }
    }
}
```

#### 5.2 处理通知响应

在 `TodoNotificationService` 的委托方法中实现深度链接：

```swift
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
) {
    let taskId = response.notification.request.content.userInfo["taskId"] as? String
    let actionIdentifier = response.actionIdentifier

    switch actionIdentifier {
    case "COMPLETE_TASK":
        // 标记任务完成
        handleCompleteTask(taskId: taskId)
    case "SNOOZE_TASK":
        // 稍后提醒（15分钟后）
        handleSnoozeTask(taskId: taskId)
    default:
        // 打开任务详情
        handleOpenTaskDetail(taskId: taskId)
    }

    completionHandler()
}
```

---

### Phase 6: Xcode 配置

> **⚠️ 注意**: 本规划使用本地通知，以下配置都是**可选的**。
>
> - 本地通知使用 `UserNotifications` 框架，无需任何额外配置即可工作
> - 以下配置仅用于将来扩展远程推送功能时使用

在 Xcode 中手动完成以下配置（无法通过代码实现）：

1. **启用 Push Notification Capability** (可选，仅用于远程推送):
   - 打开 `Holo.xcodeproj`
   - 选择 Target → Signing & Capabilities
   - 点击 "+ Capability" → 添加 "Push Notifications"
   - ⚠️ **需要付费开发者账号才能生效**

2. **添加 Background Modes** (可选，用于更好的定时提醒):
   - 添加 "Background Modes" capability
   - 勾选 "Background processing" 和 "Remote notifications"

---

### Phase 7: 数据迁移策略

由于数据模型发生变化，需要处理现有数据的迁移：

```swift
// 在 CoreDataStack.swift 中添加轻量级迁移配置
description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
```

对于已安装的版本，首次启动时：
- `reminders` 字段为 nil → 显示"未设置提醒"
- `hasDailyReminder` 默认为 false
- `smartReminderEnabled` 默认为 false

---

## 验证方案

### 测试场景

1. **截止提醒测试**:
   - 创建任务，设置截止时间，选择"15分钟前"提醒
   - 等待通知到达
   - 点击通知，验证跳转到任务详情
   - 点击"完成任务"按钮，验证任务状态更新

2. **定时提醒测试**:
   - 在设置中开启每日提醒，设置为当前时间后1分钟
   - 等待通知到达
   - 验证通知内容（显示今日待办摘要）

3. **权限请求测试**:
   - 首次启动 App，验证权限请求弹窗
   - 拒绝权限后，验证引导用户去设置开启
   - 已授权用户，验证不再弹出请求

4. **数据持久化测试**:
   - 创建带提醒的任务
   - 杀掉 App，重新打开
   - 验证提醒设置仍然存在
   - 修改任务，验证提醒正确更新

5. **边界条件测试**:
   - 无截止日期的任务，验证提醒选项禁用
   - 创建已过期任务的提醒，验证不创建通知
   - 完成任务，验证提醒自动取消

### MCP 工具验证

使用 XcodeBuildMCP 工具：

```bash
# 1. 编译验证
mcp__XcodeBuildMCP__build_sim

# 2. 运行到模拟器
mcp__XcodeBuildMCP__build_run_sim

# 3. 发送测试通知
# 在模拟器中，使用 Debug → Send Notification 测试

# 4. 查看日志
mcp__XcodeBuildMCP__start_sim_log_cap
```

---

## AI 扩展预留

为未来的智能提醒功能预留了以下扩展点：

1. **数据层**: `smartReminderSchedule` 字段存储 AI 生成的提醒计划
2. **服务层**: `applySmartReminderSchedule()` 接口接收 AI 计算结果
3. **UI 层**: 设置页面中的智能提醒开关
4. **通知分类**: 可扩展新的通知类型（如 "AI_SUGGESTION"）

未来集成时只需：
1. 实现 AI 算法，生成 `SmartReminderSchedule`
2. 调用 `applySmartReminderSchedule()` 应用
3. 在设置页面开启智能提醒开关

---

## 关键文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `CoreDataStack.swift` | 修改 | 添加 reminders 相关字段 |
| `TodoTask+CoreDataClass.swift` | 修改 | 添加 @NSManaged 属性 |
| `TodoTask+CoreDataProperties.swift` | 修改 | 添加便利属性 |
| `TodoNotificationService.swift` | 修改 | 添加定时/智能提醒功能 |
| `AddTaskSheet.swift` | 修改 | 集成提醒选择器 |
| `ReminderPicker.swift` | 新建 | 提醒选择器组件 |
| `DailyReminderSettings.swift` | 新建 | 定时提醒设置组件 |
| `NotificationSettingsView.swift` | 新建 | 通知设置页面 |
| `HoloApp.swift` | 修改 | 初始化通知服务 |

---

## 注意事项

1. **数据迁移**: 由于 Core Data 模型变化，首次运行新版本时可能需要删除旧数据或实现迁移策略
2. **权限处理**: 用户拒绝通知权限后，需要提供引导去设置开启的提示
3. **通知限制**: iOS 本地通知最多允许 64 个，需要清理过期通知
4. **时区处理**: 定时提醒需要考虑用户时区变化
5. **日志记录**: 使用 `Logger` 替代 `print()`，遵守开发规范
