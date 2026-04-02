# iOS 本地通知功能开发计划

## Context

为 HOLO iOS 应用的 Todo 模块添加本地通知提醒功能，支持：
- **截止提醒**：任务截止前自动提醒（5分钟、15分钟、1小时、1天前等）
- **定时提醒**：每日固定时间提醒待办事项
- **智能提醒预留**：为未来 AI 功能预留扩展接口

**方案优势**：使用本地通知 (Local Notifications)，**不需要付费开发者账号**，免费 Apple ID 即可完成全部开发和测试。

---

## 当前状态

| 组件 | 状态 | 说明 |
|------|------|------|
| TodoNotificationService | ✅ 基础完整 | 已有安排/取消提醒功能 |
| TaskReminder 结构体 | ✅ 已定义 | 预设选项完整 |
| TodoTask.reminders 字段 | ❌ 缺失 | 需添加到数据模型 |
| 提醒设置 UI | ❌ 未实现 | AddTaskSheet 中无提醒选择器 |
| 定时提醒 | ❌ 未实现 | 无每日提醒功能 |
| 通知操作按钮 | ❌ 未实现 | 无完成/稍后提醒按钮 |

---

## 实施计划

### Phase 1: 数据模型扩展

**修改文件**：
- `CoreDataStack.swift` - 添加 TodoTask 实体属性
- `TodoTask+CoreDataClass.swift` - 添加 @NSManaged 属性
- `TodoTask+CoreDataProperties.swift` - 添加便利属性

**新增字段**：
```
reminders: Transformable (JSON 存储 Set<TaskReminder>)
hasDailyReminder: Bool (默认 false)
smartReminderEnabled: Bool (默认 false，AI 预留)
smartReminderSchedule: Transformable (AI 预留)
```

**数据迁移**：启用轻量级自动迁移，现有数据不受影响。

---

### Phase 2: 通知服务增强

**修改文件**：`TodoNotificationService.swift`

**新增功能**：
1. `scheduleDailyReminder(at:minute:)` - 每日提醒
2. `cancelDailyReminder()` - 取消每日提醒
3. `registerNotificationCategories()` - 注册通知分类和操作按钮
4. `handleCompleteTask(taskId:)` - 处理"完成任务"操作
5. `handleSnoozeTask(taskId:)` - 处理"稍后提醒"操作

**通知操作按钮**：
- ✅ 完成任务
- ⏰ 15分钟后提醒

---

### Phase 3: UI 组件开发

**新建文件**：
- `ReminderPicker.swift` - 提醒选择器（多选预设时间）
- `DailyReminderSettings.swift` - 定时提醒设置

**修改文件**：
- `AddTaskSheet.swift` - 集成提醒选择器到截止日期下方

**UI 逻辑**：
- 无截止日期时，禁用提醒选择
- 显示已选提醒数量徽章

---

### Phase 4: 全局设置页面

**新建文件**：`NotificationSettingsView.swift`

**功能**：
- 通知权限状态显示和请求
- 每日提醒开关 + 时间选择
- 智能提醒开关（预留，禁用状态）
- 发送测试通知按钮

---

### Phase 5: App 生命周期集成

**修改文件**：`HoloApp.swift`

**初始化流程**：
1. 设置通知代理
2. 注册通知分类
3. 首次启动检查权限

---

## 关键文件清单

| 文件 | 操作 |
|------|------|
| `CoreDataStack.swift` | 修改 |
| `TodoTask+CoreDataClass.swift` | 修改 |
| `TodoTask+CoreDataProperties.swift` | 修改 |
| `TodoNotificationService.swift` | 修改 |
| `AddTaskSheet.swift` | 修改 |
| `ReminderPicker.swift` | **新建** |
| `DailyReminderSettings.swift` | **新建** |
| `NotificationSettingsView.swift` | **新建** |
| `HoloApp.swift` | 修改 |

---

## 验证方案

1. **编译验证**：`mcp__XcodeBuildMCP__build_sim`
2. **运行测试**：`mcp__XcodeBuildMCP__build_run_sim`
3. **功能测试**：
   - 创建带提醒任务，等待通知到达
   - 点击通知验证跳转
   - 点击"完成任务"按钮验证状态更新
   - 测试每日提醒功能

---

## 开发顺序建议

```
Phase 1 (数据模型) → Phase 2 (服务层) → Phase 3 (UI) → Phase 5 (集成) → Phase 4 (设置页)
```

Phase 4 可以最后做，因为它依赖前面的基础设施。
