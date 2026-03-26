# 待办模块开发总结

> 开发日期：2026-03-21
> 状态：✅ Phase 1 完成，Phase 2 大部分完成

---

## 开发进度

### Phase 1: MVP 核心 ✅ 全部完成

| 功能 | 状态 | 说明 |
|------|------|------|
| 数据模型与 Core Data | ✅ | 实体编译通过，CRUD 正常 |
| TaskRepository | ✅ | CRUD、查询、统计、软删除 |
| TasksView + TaskListView | ✅ | 底部 Tab 导航（统计/任务/新增） |
| AddTaskSheet | ✅ | 创建/编辑任务，支持清单选择 |
| TaskDetailView | ✅ | 直接编辑模式，点击字段即可编辑 |
| 清单与文件夹管理 | ✅ | 扁平化清单选择器，长按编辑/删除 |
| 软删除与回收站 | ✅ | 30 天自动清理 |
| 归档功能 | ✅ | 已完成任务自动归档 |
| 本地通知 | ✅ | 多时间点提醒，通知分类，操作按钮 |
| 统计视图 | ✅ | 总览/按优先级/今日进度 |

### Phase 2: 体验增强 🔧 进行中

| 功能 | 状态 | 说明 |
|------|------|------|
| CheckItem + ChecklistView | ✅ | 检查清单管理，任务卡片直接展示 |
| RepeatRule + RepeatRuleView | ✅ | 每天/每周/每月/每年/自定义重复 |
| 自动生成下次任务 | ✅ | 完成重复任务后自动创建下一实例 |
| 多时间点提醒 | ✅ | ReminderPicker 组件 |
| 四象限视图 | ❌ | 待开发 |
| TaskSearchView | ✅ | 按标题/描述/标签搜索，搜索历史 |
| 日历双向同步 | ❌ | 待开发 |

### 已知问题

- AddTaskSheet 中截止日期 DatePicker 在 ScrollView 中交互异常（重复结束日期已改用 Sheet 解决，截止日期待修复）

---

## 文件清单

### 数据模型层（`Models/`）

| 文件 | 说明 |
| --- | --- |
| `TodoTask+CoreDataClass.swift` | 任务实体类 |
| `TodoTask+CoreDataProperties.swift` | 任务实体属性扩展 |
| `TodoList+CoreDataClass.swift` | 清单实体类 |
| `TodoList+CoreDataProperties.swift` | 清单实体属性扩展 |
| `TodoFolder+CoreDataClass.swift` | 文件夹实体类 |
| `TodoFolder+CoreDataProperties.swift` | 文件夹实体属性扩展 |
| `TodoTag+CoreDataClass.swift` | 标签实体类 |
| `TodoTag+CoreDataProperties.swift` | 标签实体属性扩展 |
| `CheckItem+CoreDataClass.swift` | 检查项实体类 |
| `CheckItem+CoreDataProperties.swift` | 检查项实体属性扩展 |
| `RepeatRule+CoreDataClass.swift` | 重复规则实体类 |
| `RepeatRule+CoreDataProperties.swift` | 重复规则实体属性扩展 |
| `TodoTaskPriority.swift` | TaskStatus、TaskPriority 枚举 |
| `TodoTaskModels.swift` | RepeatType、TaskReminder、CheckItem 等结构体 |
| `Weekday.swift` | 星期枚举和扩展 |
| `TodoRepository.swift` | 数据仓库（CRUD、查询、统计、软删除） |

### 视图层（`Views/Tasks/`）

| 文件 | 说明 |
| --- | --- |
| `TasksView.swift` | 模块入口（侧边栏 + 主内容） |
| `TaskListView.swift` | 清单任务列表页 |
| `TaskRowView.swift` | 任务行组件 |
| `TaskDetailView.swift` | 任务详情页 |
| `AddTaskSheet.swift` | 新建/编辑任务表单 |
| `AddFolderSheet.swift` | 新建文件夹表单 |
| `AddListSheet.swift` | 新建清单表单 |
| `PriorityPicker.swift` | 优先级选择器 |
| `ChecklistView.swift` | 检查清单管理视图 |
| `RepeatRuleView.swift` | 重复规则设置视图 |
| `TaskStatsView.swift` | 任务统计视图 |

### 服务层

| 文件 | 说明 |
| --- | --- |
| `TodoNotificationService.swift` | 本地通知服务（提醒功能） |

---

## 技术亮点

1. 遵循现有架构，完全复用 HabitRepository 的模式
2. 不可变更新，所有更新操作都创建新对象
3. 错误处理，所有 CRUD 操作都使用 `throws`
4. 数据变更通知，通过 NotificationCenter 实现跨组件同步
5. 软删除设计，支持回收站和 30 天自动清理
