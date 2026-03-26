# 待办模块开发总结

> 开发日期：2026-03-21
> 状态：✅ MVP 核心功能完成，Phase 2 进行中

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
