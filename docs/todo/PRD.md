# 📋 待办模块 PRD (Product Requirement Document)

> 版本: v0.1.0
> 日期: 2026-03-21
> 状态: ✅ 已确认

---

## 📌 概述

### 1.1 产品定位

待办模块是 Holo 应用的核心模块之一，采用**日历驱动 + 传统交互 + AI 增强**的混合架构：

- **日历驱动**: 以日历视图为核心，任务与时间深度绑定，类似 Apple Calendar + Reminders 的结合
- **传统交互**: 保留列表/清单操作，符合用户使用习惯
- **AI 增强**: 架构预留扩展点，为后续对话创建、智能排序等 AI 功能奠定基础

### 1.2 目标用户

- 职场人士：管理工作任务、会议、项目里程碑
- 学生：规划学习任务、作业、考试准备
- 个人用户：管理生活琐事、购物清单、个人目标
- 习惯使用者：与习惯模块联动，记录需要完成的事项

### 1.3 与其他模块的关系

```
┌─────────────────────────────────────────────────┐
│              待办模块 (Todo)                     │
├─────────────────────────────────────────────────┤
│ 与日历联动 │ 双向同步，日历中可创建/编辑任务     │
│ 与习惯联动 │ 记录习惯相关的待办事项              │
│ 与健康联动 │ 运动/饮食计划可转为待办任务         │
│ 与聊天联动 │ 后续支持对话创建任务                │
└─────────────────────────────────────────────────┘
```

---

## 🎯 核心功能

### 2.1 清单与文件夹系统

**结构**: 两层组织结构（文件夹 → 清单 → 任务）

- **文件夹** (Folder)
  - 顶层容器，用于场景/项目分组
  - 例如：「工作」、「学习」、「生活」
  - 可折叠/展开，拖拽排序

- **清单** (List)
  - 文件夹下的具体列表
  - 例如：「工作 → 本周任务」、「学习 → 考试复习」
  - 智能默认清单：「收件箱」（未归类任务）

**操作**:
- 创建/编辑/删除文件夹
- 创建/编辑/删除清单
- 拖拽移动文件夹和清单
- 清单归档（隐藏但保留数据）

---

### 2.2 任务管理

#### 2.2.1 任务模型

```swift
enum TaskStatus: String, Codable {
    case todo      // 待办
    case inProgress // 进行中
    case completed  // 已完成
}

enum TaskPriority: String, Codable {
    case urgent  // 十分紧急（红色）
    case high    // 高（橙色）
    case medium  // 中（黄色）
    case low     // 低（灰色）
}

struct Task {
    let id: UUID
    var title: String              // 标题（200 字符限制）
    var description: String        // 描述（Markdown 支持，10,000 字符限制）
    var status: TaskStatus
    var priority: TaskPriority
    var dueDate: Date?             // 截止时间
    var isAllDay: Bool             // 是否全天任务
    var isOverdue: Bool            // 是否已过期（计算属性）
    var listId: UUID?              // 所属清单
    var tags: [Tag]                // 标签数组
    var checklist: [CheckItem]     // 检查清单（扁平列表）
    var repeatRule: RepeatRule?    // 重复规则
    var reminders: [Reminder]      // 提醒时间
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?         // 完成时间
}
```

#### 2.2.2 基础操作

- **创建任务**: 从清单页快速添加或从详情页详细编辑
- **编辑任务**: 修改所有属性（标题、状态、优先级、截止时间等）
- **完成任务**: 一键标记完成/取消完成
- **删除任务**: 软删除，进入回收站，30 天后自动清理

---

### 2.3 时间管理

#### 2.3.1 截止时间

- 支持精确时间（2026-03-22 14:30）
- 支持全天任务（2026-03-22 全天）
- 自动高亮：过期任务红色、今天到期黄色

#### 2.3.2 提醒通知

**多时间点提醒**:
```
┌────────────────────────────────────┐
│  提醒选项                           │
├───────────────┬────────────────────┤
│ 即时          │ 截止时间点         │
│ 5 分钟前      │ 5 分钟提醒         │
│ 15 分钟前     │ 15 分钟提醒        │
│ 30 分钟前     │ 30 分钟提醒        │
│ 1 小时前      │ 1 小时提醒         │
│ 1 天前        │ 1 天前提醒         │
│ 自定义        │ 任意时间点         │
└───────────────┴────────────────────┘
```

- 支持添加多个提醒
- 本地通知推送
- 手动关闭/延迟提醒

#### 2.3.3 重复任务

**高级重复规则**:
```swift
enum RepeatType {
    case daily               // 每天
    case weekly              // 每周（可选星期）
    case monthly             // 每月（日期或第 N 周）
    case yearly              // 每年（日期）
    case custom              // 自定义规则
}

struct RepeatRule {
    let type: RepeatType

    // 每周：周几（可多选）
    var weekdays: [Weekday]?           // [.monday, .friday]

    // 每月：日期或第 N 周的周几
    var monthDay: Int?                 // 1-31
    var monthWeekOrdinal: Int?         // 1-5 (第一周、第二周)
    var monthWeekday: Weekday?         // 第二周的周三

    // 重复结束：次数或日期
    var untilCount: Int?               // 重复 N 次后结束
    var untilDate: Date?               // 到某日期结束

    // 跳过规则
    var skipHolidays: Bool             // 跳过节假日
    var skipWeekends: Bool             // 跳过周末
}
```

**示例**:
- 每周一、周三早上 9 点开会
- 每月最后一天提交报告
- 每年 3 月 21 日生日

---

### 2.4 检查清单 (Checklist)

- 扁平列表结构（不支持嵌套）
- 每个任务可有多个步骤
- 步骤支持勾选/取消
- 进度显示：`已完成 2/5 项`

**数据模型**:
```swift
struct CheckItem {
    let id: UUID
    var title: String
    var isChecked: Bool
    var order: Int
}
```

---

### 2.5 标签系统

- 自由创建标签（无预设）
- 每个标签可设置颜色
- 一个任务可关联多个标签
- 标签可编辑/删除（软删除）
- 标签可作为筛选维度

**示例**:
- 🔴 项目 A
- 🟢 紧急
- 🔵 会议准备
- 🟡 待确认

---

### 2.6 四象限视图

**艾森豪威尔矩阵**:

```
┌──────────────────────┬──────────────────────┐
│   重要 ⬆️ 紧急       │   重要 ⬆️ 不紧急     │
│   ┌──────────────┐   │   ┌──────────────┐   │
│   │  优先处理    │   │   │  预先规划    │   │
│   │  • 今天到期  │   │   │  • 长期项目  │   │
│   │  • 十分紧急  │   │   │  • 高优先级  │   │
│   └──────────────┘   │   └──────────────┘   │
├──────────────────────┼──────────────────────┤
│   不重要 ⬇️ 紧急    │   不重要 ⬇️ 不紧急  │
│   ┌──────────────┐   │   ┌──────────────┐   │
│   │  委派/简化   │   │   │  减少/避免   │   │
│   │  • 临时会议  │   │   │  • 刷社交媒体│   │
│   │  • 琐事      │   │   │  • 娱乐      │   │
│   └──────────────┘   │   └──────────────┘   │
└──────────────────────┴──────────────────────┘
         紧急 ⬅️                不紧急 ➡️
```

**说明**:
- 四象限作为**可选视图**，不强制要求设置属性
- 自动分类规则：
  - 重要 = 优先级为「高/十分紧急」
  - 紧急 = 今天或明天到期，或已过期
- 支持手动调整象限

---

### 2.7 Markdown 编辑器

- **支持语法**:
  - 标题 (`#`, `##`, `###`)
  - 粗体/斜体 (`**bold**`, `*italic*`)
  - 列表 (`-`, `1.`)
  - 链接/图片
  - 代码块

- **手机键盘优化**:
  - 顶部工具栏：快速插入格式
  - 自动换行
  - 实时预览模式切换

---

### 2.8 数据持久化与同步

#### 2.8.1 存储方案

- **Core Data**: 与习惯模块保持一致
- **iCloud 同步**: 多设备数据同步
- **冲突解决**: 以最新 `updatedAt` 为准

#### 2.8.2 归档与回收站

- **归档**: 已完成任务可手动/自动归档，减少列表干扰
- **回收站**:
  - 删除任务进入回收站
  - 可恢复/永久删除
  - 30 天后自动清理

---

### 2.9 与日历的双向同步

- 待办任务显示在日历对应日期
- 日历视图中可直接创建/编辑任务
- 点击日历中的任务卡片跳转到详情页

---

## 📱 用户体验设计

### 3.1 主要视图

#### 3.1.1 待办主页 (TodoMainView)

```
┌──────────────────────────────────┐
│  侧边栏          │  主内容区       │
├──────────────────┼─────────────────┤
│  📁 工作         │                 │
│    ✅ 本周任务   │  [清单名称]     │
│    📋 待处理     │                 │
│  📁 学习         │  • [ ] 任务 1   │
│    ✅ 复习计划   │  • [✓] 任务 2   │
│  📁 生活         │  • [ ] 任务 3   │
│    ✅ 购物清单   │                 │
│                  │  [+ 添加任务]   │
│  ────────────    │                 │
│  📭 收件箱 (12)  │                 │
│  🔍 搜索         │                 │
└──────────────────┴─────────────────┘
```

#### 3.1.2 任务列表页 (TaskListView)

- 筛选：状态、优先级、标签、日期范围
- 排序：截止时间、优先级、创建时间
- 批量操作：多选 → 完成/删除/移动/修改优先级

#### 3.1.3 任务详情页 (TaskDetailView)

```
┌────────────────────────────────┐
│  [←] 任务标题                   │
├────────────────────────────────┤
│  状态: [待办 ▼]                │
│  优先级: [🔴 十分紧急 ▼]       │
│  截止时间: 2026-03-22 14:30    │
│  提醒: [1 天前, 30 分钟前]     │
│                                │
│  描述:                         │
│  ┌──────────────────────────┐ │
│  │ 这是一个 Markdown 描述...  │ │
│  └──────────────────────────┘ │
│                                │
│  标签: [#工作] [#会议]         │
│                                │
│  检查清单:                     │
│  ☐ 准备材料                    │
│  ☑ 邀请参会人员                │
│  ☐ 测试设备                    │
│                                │
│  [重复: 每周一、周三]          │
│                                │
│  [删除] [编辑] [完成 ✓]        │
└────────────────────────────────┘
```

#### 3.1.4 四象限视图 (QuadrantView)

- 拖拽任务到不同象限
- 空象限自动隐藏
- 点击任务展开详情

---

### 3.2 交互细节

#### 3.2.1 创建任务

**快速创建**:
```
┌──────────────────────┐
│  [+ 添加任务]        │
└──────────────────────┘
     ↓ (点击)
┌──────────────────────┐
│  [输入标题...]       │
│  [添加到清单 ▼]      │
│                      │
│  [取消]  [保存]      │
└──────────────────────┘
```

**完整编辑**:
- 从快速创建页点击「详细编辑」
- 或从任务详情页点击「编辑」

#### 3.2.2 手势操作

```
┌───────────────────────┬──────────────────────────────┐
│      列表项手势       │           操作               │
├───────────────────────┼──────────────────────────────┤
│ 左滑                  │ 显示操作菜单                 │
│                       │ - 完成/取消完成              │
│                       │ - 删除                       │
│                       │ - 移动到其他清单             │
├───────────────────────┼──────────────────────────────┤
│ 右滑                  │ 标记完成/取消完成            │
├───────────────────────┼──────────────────────────────┤
│ 长按拖拽              │ 调整任务顺序                 │
└───────────────────────┴──────────────────────────────┘
```

#### 3.2.3 筛选与搜索

- **顶部筛选栏**: 快速切换状态/优先级/标签
- **高级筛选**: 打开筛选面板，多条件组合
- **搜索**: 标题/描述全文搜索，实时结果

---

### 3.3 空状态设计

```
┌──────────────────┬────────────────────────────────────┬──────────────┐
│       场景       │              空状态文案            │   操作引导   │
├──────────────────┼────────────────────────────────────┼──────────────┤
│ 清单无任务       │ 「还没有任务」                     │ 显示添加按钮 │
│                  │ 「点击下方 + 添加第一个任务」      │              │
├──────────────────┼────────────────────────────────────┼──────────────┤
│ 收件箱为空       │ 「收件箱是空的」                   │ 隐藏添加按钮 │
│                  │ 「所有任务都已归类到清单中」       │              │
├──────────────────┼────────────────────────────────────┼──────────────┤
│ 已完成列表为空   │ 「还没有完成的任务」               │ -            │
│                  │ 「继续加油！」                     │              │
├──────────────────┼────────────────────────────────────┼──────────────┤
│ 回收站为空       │ 「回收站是空的」                   │ -            │
├──────────────────┼────────────────────────────────────┼──────────────┤
│ 搜索无结果       │ 「没有找到匹配的任务」             │ 显示搜索建议 │
│                  │ 「试试其他关键词？」               │              │
├──────────────────┼────────────────────────────────────┼──────────────┤
│ 四象限某区域为空 │ 「暂无任务」                       │ 隐藏该区域   │
└──────────────────┴────────────────────────────────────┴──────────────┘
```

---

## 🛠️ 技术实现

### 4.1 数据模型

#### 4.1.1 Core Data 模型

```
┌─────────────────────────────────────────┐
│  Task (任务)                             │
├─────────────────────────────────────────┤
│  • id: UUID (主键)                       │
│  • title: String                         │
│  • description: String                   │
│  • status: String (enum)                 │
│  • priority: String (enum)               │
│  • dueDate: Date?                        │
│  • isAllDay: Bool                        │
│  • createdAt: Date                       │
│  • updatedAt: Date                       │
│  • completedAt: Date?                    │
│  • isArchived: Bool                      │
│  • isDeleted: Bool                       │
│  • deletedAt: Date?                      │
│                                          │
│  Relationships:                          │
│  • list ←→ List                          │
│  • tags ←→ Tag (many-to-many)            │
│  • checkItems ←→ CheckItem               │
│  • repeatRule ←→ RepeatRule?             │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│  List (清单)                             │
├─────────────────────────────────────────┤
│  • id: UUID                              │
│  • name: String                          │
│  • order: Int16                          │
│  • color: String?                        │
│  • isArchived: Bool                      │
│                                          │
│  Relationships:                          │
│  • folder ←→ Folder?                     │
│  • tasks ←→ Task                         │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│  Folder (文件夹)                         │
├─────────────────────────────────────────┤
│  • id: UUID                              │
│  • name: String                          │
│  • order: Int16                          │
│  • isExpanded: Bool                      │
│                                          │
│  Relationships:                          │
│  • lists ←→ List                         │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│  Tag (标签)                              │
├─────────────────────────────────────────┤
│  • id: UUID                              │
│  • name: String                          │
│  • color: String                         │
│                                          │
│  Relationships:                          │
│  • tasks ←→ Task (many-to-many)          │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│  CheckItem (检查项)                      │
├─────────────────────────────────────────┤
│  • id: UUID                              │
│  • title: String                         │
│  • isChecked: Bool                        │
│  • order: Int16                          │
│                                          │
│  Relationships:                          │
│  • task ←→ Task                          │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│  RepeatRule (重复规则)                   │
├─────────────────────────────────────────┤
│  • id: UUID                              │
│  • type: String (enum)                   │
│  • weekdays: String? (逗号分隔)          │
│  • monthDay: Int16?                      │
│  • monthWeekOrdinal: Int16?              │
│  • monthWeekday: String?                 │
│  • untilCount: Int16?                    │
│  • untilDate: Date?                      │
│  • skipHolidays: Bool                    │
│  • skipWeekends: Bool                    │
│                                          │
│  Relationships:                          │
│  • task ←→ Task                          │
└─────────────────────────────────────────┘
```

---

### 4.2 业务逻辑

#### 4.2.1 重复任务生成

```swift
class RepeatTaskService {
    /// 根据重复规则生成未来 30 天的重复任务实例
    func generateInstances(
        baseTask: Task,
        repeatRule: RepeatRule,
        range: DateInterval
    ) -> [TaskInstance] {
        var instances: [TaskInstance] = []
        var currentDate = baseTask.dueDate ?? Date()

        while currentDate <= range.end {
            // 检查是否符合重复规则
            if matchesRepeatRule(date: currentDate, rule: repeatRule) {
                // 创建实例（浅拷贝原任务）
                let instance = TaskInstance(
                    baseTaskId: baseTask.id,
                    occurrenceDate: currentDate,
                    status: .todo
                )
                instances.append(instance)
            }

            currentDate = nextDate(after: currentDate, rule: repeatRule)
        }

        return instances
    }

    /// 检查日期是否符合重复规则
    private func matchesRepeatRule(date: Date, rule: RepeatRule) -> Bool {
        switch rule.type {
        case .daily:
            return true

        case .weekly:
            guard let weekdays = rule.weekdays else { return false }
            let weekday = Calendar.current.component(.weekday, from: date)
            return weekdays.contains(weekday)

        case .monthly:
            if let day = rule.monthDay {
                // 按日期（如每月 15 号）
                return Calendar.current.component(.day, from: date) == day
            } else if let ordinal = rule.monthWeekOrdinal,
                      let weekday = rule.monthWeekday {
                // 按第 N 周的周几（如每月最后一个周五）
                let components = Calendar.current.dateComponents(
                    [.day, .weekday, .weekOfMonth, .weekOfYear],
                    from: date
                )
                // 计算是否是第 ordinal 周
                let weekOrdinal = components.weekOfMonth ?? 0
                let isLastWeek = isLastWeekOfMonth(date: date)

                if ordinal == 5 && isLastWeek {
                    return components.weekday == weekday.rawValue
                }
                return weekOrdinal == ordinal && components.weekday == weekday.rawValue
            }
            return false

        case .yearly:
            let components = Calendar.current.dateComponents([.month, .day], from: date)
            let ruleComponents = Calendar.current.dateComponents(
                [.month, .day],
                from: rule.referenceDate
            )
            return components.month == ruleComponents.month &&
                   components.day == ruleComponents.day

        case .custom:
            return evaluateCustomRule(date: date, rule: rule)
        }
    }

    /// 计算下一次重复日期
    private func nextDate(after date: Date, rule: RepeatRule) -> Date {
        switch rule.type {
        case .daily:
            return Calendar.current.date(byAdding: .day, value: 1, to: date)!

        case .weekly:
            return Calendar.current.date(byAdding: .weekOfYear, value: 1, to: date)!

        case .monthly:
            return Calendar.current.date(byAdding: .month, value: 1, to: date)!

        case .yearly:
            return Calendar.current.date(byAdding: .year, value: 1, to: date)!

        case .custom:
            return calculateNextCustomDate(after: date, rule: rule)
        }
    }

    /// 判断是否是当月最后一周
    private func isLastWeekOfMonth(date: Date) -> Bool {
        let nextWeek = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: date)!
        let nextWeekMonth = Calendar.current.component(.month, from: nextWeek)
        let currentMonth = Calendar.current.component(.month, from: date)
        return nextWeekMonth != currentMonth
    }
}
```

#### 4.2.2 提醒通知生成

```swift
class ReminderService {
    static let reminderOffsets: [(Int, String)] = [
        (0, "截止时间"),
        (5, "5 分钟前"),
        (15, "15 分钟前"),
        (30, "30 分钟前"),
        (60, "1 小时前"),
        (1440, "1 天前")
    ]

    /// 为任务创建本地通知
    func scheduleReminders(for task: Task) {
        guard let dueDate = task.dueDate,
              !task.isCompleted else { return }

        for reminder in task.reminders {
            let triggerDate = Calendar.current.date(
                byAdding: .minute,
                value: -reminder.offsetMinutes,
                to: dueDate
            )

            guard let triggerDate = triggerDate, triggerDate > Date() else {
                continue // 已过期的提醒不创建
            }

            let content = UNMutableNotificationContent()
            content.title = "⏰ 任务提醒"
            content.body = task.title
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: triggerDate
                ),
                repeats: task.repeatRule != nil
            )

            let request = UNNotificationRequest(
                identifier: "\(task.id)-\(reminder.offsetMinutes)",
                content: content,
                trigger: trigger
            )

            UNUserNotificationCenter.current().add(request)
        }
    }

    /// 取消任务的所有提醒
    func cancelReminders(for taskId: UUID) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let taskIds = requests
                .filter { $0.identifier.hasPrefix(taskId.uuidString) }
                .map { $0.identifier }

            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: taskIds
            )
        }
    }
}
```

#### 4.2.3 日期处理工具

```swift
extension Task {
    /// 计算有效截止时间（全天任务返回 23:59:59）
    var effectiveDueDate: Date? {
        guard let dueDate else { return nil }

        if isAllDay {
            return Calendar.current.date(
                bySettingHour: 23,
                minute: 59,
                second: 59,
                of: dueDate
            )
        }
        return dueDate
    }

    /// 判断是否过期
    var isOverdue: Bool {
        guard let date = effectiveDueDate, status != .completed else { return false }
        return date < Date()
    }

    /// 判断是否今天到期
    var isDueToday: Bool {
        guard let date = dueDate else { return false }
        return Calendar.current.isDateInToday(date)
    }

    /// 判断是否明天到期
    var isDueTomorrow: Bool {
        guard let date = dueDate else { return false }
        return Calendar.current.isDateInTomorrow(date)
    }
}

extension Calendar {
    /// 获取下周的指定星期
    func dateOfNext(weekday: Weekday, after date: Date) -> Date {
        var nextDate = date
        while !isDate(nextDate, equalTo: weekday, toGranularity: .day) {
            nextDate = self.date(byAdding: .day, value: 1, to: nextDate)!
        }
        return nextDate
    }
}
```

---

### 4.3 错误处理

```swift
enum TodoError: LocalizedError {
    case taskNotFound
    case invalidTitle
    case invalidDueDate
    case repeatRuleWithoutDueDate
    case coreDataError(Error)
    case notificationPermissionDenied

    var errorDescription: String? {
        switch self {
        case .taskNotFound:
            return "任务不存在"
        case .invalidTitle:
            return "请输入任务标题"
        case .invalidDueDate:
            return "截止时间无效"
        case .repeatRuleWithoutDueDate:
            return "重复任务需要先设置截止时间"
        case .coreDataError(let error):
            return "数据保存失败：\(error.localizedDescription)"
        case .notificationPermissionDenied:
            return "请在设置中开启通知权限"
        }
    }
}

// 使用示例
func saveTask(_ task: Task) throws {
    guard !task.title.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw TodoError.invalidTitle
    }

    if task.repeatRule != nil && task.dueDate == nil {
        throw TodoError.repeatRuleWithoutDueDate
    }

    do {
        try context.save()
    } catch {
        throw TodoError.coreDataError(error)
    }
}
```

---

### 4.4 边界情况处理

#### 4.4.1 数据边界

```
┌────────────────────────────┬─────────────────────────────────────────────┐
│            场景            │                   处理方式                   │
├────────────────────────────┼─────────────────────────────────────────────┤
│ 任务标题为空               │ 禁止保存，显示提示「请输入任务标题」        │
├────────────────────────────┼─────────────────────────────────────────────┤
│ 任务标题超长               │ 限制 200 字符，超出截断并提示               │
├────────────────────────────┼─────────────────────────────────────────────┤
│ 描述超长                   │ 限制 10,000 字符，Markdown 编辑器显示字数   │
├────────────────────────────┼─────────────────────────────────────────────┤
│ 截止时间早于当前           │ 允许保存，标记为「已过期」并红色高亮        │
├────────────────────────────┼─────────────────────────────────────────────┤
│ 清单下有任务时删除清单     │ 提示「该清单有 N 个任务，是否移动到收件箱？」│
├────────────────────────────┼─────────────────────────────────────────────┤
│ 文件夹下有清单时删除文件夹 │ 提示「该文件夹有 N 个清单，是否移动到顶层？」│
├────────────────────────────┼─────────────────────────────────────────────┤
│ 标签被任务使用时删除       │ 软删除，已关联的任务保留标签显示            │
├────────────────────────────┼─────────────────────────────────────────────┤
│ 重复任务无截止时间         │ 禁止设置重复，提示「重复任务需要设置截止时间」│
└────────────────────────────┴─────────────────────────────────────────────┘
```

#### 4.4.2 并发与数据一致性

```
┌──────────────────┬─────────────────────────────────────────┐
│       场景       │                处理方式                 │
├──────────────────┼─────────────────────────────────────────┤
│ 多设备同步冲突   │ 以最新 updatedAt 为准（iCloud 同步时）  │
├──────────────────┼─────────────────────────────────────────┤
│ 重复任务生成竞态 │ 使用 Core Data 事务，防止重复生成       │
├──────────────────┼─────────────────────────────────────────┤
│ 批量操作         │ 使用 NSBatchUpdateRequest 提升性能      │
├──────────────────┼─────────────────────────────────────────┤
│ 后台刷新         │ 检查并触发即将到期的提醒                │
└──────────────────┴─────────────────────────────────────────┘
```

---

## 🚀 功能优先级与实施计划

### 5.1 功能优先级矩阵

#### P0 - MVP 核心（必须有）

```
┌───────────┬────────────────────────────────┬────────┐
│   功能    │              说明              │ 复杂度 │
├───────────┼────────────────────────────────┼────────┤
│ 清单管理  │ 创建/编辑/删除清单，文件夹分组 │ 中     │
├───────────┼────────────────────────────────┼────────┤
│ 任务 CRUD │ 创建/查看/编辑/删除任务        │ 高     │
├───────────┼────────────────────────────────┼────────┤
│ 任务状态  │ 待办/进行中/已完成             │ 低     │
├───────────┼────────────────────────────────┼────────┤
│ 优先级    │ 十分紧急/高/中/低              │ 低     │
├───────────┼────────────────────────────────┼────────┤
│ 截止时间  │ 日期 + 时间 / 全天             │ 低     │
├───────────┼────────────────────────────────┼────────┤
│ 标签系统  │ 创建/编辑/删除标签，多标签     │ 中     │
├───────────┼────────────────────────────────┼────────┤
│ 软删除    │ 删除进入回收站，30天自动清理   │ 中     │
├───────────┼────────────────────────────────┼────────┤
│ 归档      │ 已完成任务归档                 │ 低     │
├───────────┼────────────────────────────────┼────────┤
│ 本地通知  │ 截止时间提醒                   │ 中     │
└───────────┴────────────────────────────────┴────────┘
```

#### P1 - 体验增强（首批迭代）

```
┌─────────────────┬─────────────────────────────────┬────────┐
│      功能       │              说明               │ 复杂度 │
├─────────────────┼─────────────────────────────────┼────────┤
│ 检查清单        │ 任务步骤，支持勾选              │ 中     │
├─────────────────┼─────────────────────────────────┼────────┤
│ 重复任务        │ 高级重复规则                    │ 高     │
├─────────────────┼─────────────────────────────────┼────────┤
│ 多时间点提醒    │ 自定义多个提醒时间              │ 中     │
├─────────────────┼─────────────────────────────────┼────────┤
│ 四象限视图      │ 重要/紧急矩阵展示               │ 中     │
├─────────────────┼─────────────────────────────────┼────────┤
│ Markdown 编辑器 │ 描述支持 Markdown，手机键盘适配 │ 高     │
├─────────────────┼─────────────────────────────────┼────────┤
│ 搜索            │ 任务标题/描述搜索               │ 低     │
├─────────────────┼─────────────────────────────────┼────────┤
│ 日历双向同步    │ 日历中创建/编辑任务             │ 高     │
└─────────────────┴─────────────────────────────────┴────────┘
```

#### P2 - 后续迭代

```
┌────────────────┬──────────────────────────────┬────────┐
│      功能      │             说明             │ 复杂度 │
├────────────────┼──────────────────────────────┼────────┤
│ AI 智能排序    │ 基于优先级、截止时间自动排序 │ 高     │
├────────────────┼──────────────────────────────┼────────┤
│ AI 每日总结    │ 生成任务完成情况总结         │ 高     │
├────────────────┼──────────────────────────────┼────────┤
│ 数据统计       │ 完成率、趋势图表             │ 中     │
├────────────────┼──────────────────────────────┼────────┤
│ Widget         │ 今日任务小组件               │ 中     │
├────────────────┼──────────────────────────────┼────────┤
│ Siri Shortcuts │ 语音创建任务                 │ 中     │
└────────────────┼──────────────────────────────┴────────┘
```

---

### 5.2 实施阶段

#### Phase 1: MVP 核心 (3-4 周)

```
┌─────────────────────────────────────────────────────────────┐
│  Week 1: 数据层                                             │
├─────────────────────────────────────────────────────────────┤
│  □ Core Data 模型设计                                       │
│  □ TodoRepository 实现                                      │
│  □ 基础 CRUD 操作                                           │
│                                                             │
│  Week 2: 核心视图                                           │
│  □ TodoMainView (侧边栏 + 列表)                             │
│  □ TaskListView (任务列表)                                  │
│  □ 清单/文件夹管理                                          │
│                                                             │
│  Week 3: 任务详情                                           │
│  □ TaskDetailView 基础结构                                  │
│  □ 标题/状态/优先级/截止时间                                 │
│  □ 标签系统                                                 │
│                                                             │
│  Week 4: 收尾                                               │
│  □ 软删除 + 回收站                                          │
│  □ 归档功能                                                 │
│  □ 本地通知                                                 │
│  □ 测试 + Bug 修复                                          │
└─────────────────────────────────────────────────────────────┘
```

#### Phase 2: 体验增强 (3 周)

```
┌─────────────────────────────────────────────────────────────┐
│  Week 5-6: 复杂功能                                         │
├─────────────────────────────────────────────────────────────┤
│  □ 检查清单                                                 │
│  □ 重复任务（高级规则）                                      │
│  □ 多时间点提醒                                             │
│  □ Markdown 编辑器                                          │
│                                                             │
│  Week 7: 扩展视图                                           │
│  □ 四象限视图                                               │
│  □ 日历双向同步                                             │
│  □ 搜索功能                                                 │
│  □ 测试 + Bug 修复                                          │
└─────────────────────────────────────────────────────────────┘
```

#### Phase 3: AI 能力 (后续大版本)

```
┌─────────────────────────────────────────────────────────────┐
│  □ 对话创建任务（接入 AI 意图识别）                          │
│  □ AI 智能排序                                              │
│  □ AI 每日总结                                              │
│  □ AI 时间预估                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## ✅ 验收标准

### 6.1 MVP 核心验收标准

- [ ] 可以创建文件夹和清单，并组织层级结构
- [ ] 可以在清单中创建任务，设置标题、状态、优先级、截止时间
- [ ] 任务可以标记完成/取消完成
- [ ] 任务可以添加/删除标签（多标签支持）
- [ ] 删除任务进入回收站，30 天后自动清理
- [ ] 已完成任务可以归档
- [ ] 截止时间到达前推送本地通知
- [ ] 过期任务红色高亮显示
- [ ] 收件箱自动收集未归类任务
- [ ] 所有数据通过 iCloud 同步到其他设备

### 6.2 用户体验验收标准

- [ ] 快速创建任务不超过 3 次点击
- [ ] 编辑任务的所有属性都在一个页面内完成
- [ ] 左滑/右滑手势操作流畅无卡顿
- [ ] 任务列表滚动流畅（60 FPS）
- [ ] 空状态有清晰的引导文案
- [ ] 错误提示友好易懂
- [ ] 支持深色模式
- [ ] 支持动态字体大小

---

## 📝 附录

### 7.1 术语表

- **收件箱 (Inbox)**: 默认清单，未归类的任务自动进入此清单
- **软删除 (Soft Delete)**: 删除后数据保留，可恢复，一定时间后自动清理
- **归档 (Archive)**: 将已完成任务移出主列表，减少干扰但保留数据
- **四象限 (Quadrant)**: 艾森豪威尔矩阵，按重要/紧急程度分类任务
- **检查清单 (Checklist)**: 任务的步骤列表，支持勾选完成状态

### 7.2 参考资料

- Apple Reminders App 设计
- Things 3 任务管理理念
- Todoist 重复任务规则
- Notion 数据库组织方式
- GTD (Getting Things Done) 工作流

### 7.3 待确认事项

- [ ] 是否需要任务之间的依赖关系（前置任务）
- [ ] 是否需要任务评论/协作功能
- [ ] 是否需要任务附件（图片/文件）
- [ ] 是否需要任务时间预估与实际耗时记录
- [ ] 是否需要任务完成后的自动归档策略

---

**文档维护**: 此文档将随着开发进度持续更新，最新版本请查看 `docs/todo/PRD.md`
