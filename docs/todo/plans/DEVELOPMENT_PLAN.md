# HOLO 待办模块开发计划

> 创建时间：2026-03-21
> 版本：v1.0
> 状态：待审批

---

## 一、Context（背景与目标）

### 1.1 为什么需要待办模块

HOLO 应用目前已包含记账和习惯追踪两大核心功能。待办模块的引入将完善产品矩阵，形成"**时间 + 任务 + 习惯**"三位一体的个人管理工具：

- **记账模块**：管理财务收支
- **习惯模块**：追踪长期行为
- **待办模块**：处理短期任务和事项

### 1.2 产品定位

采用**日历驱动 + 传统交互 + AI 增强**的混合架构：
- 日历驱动：与日历模块双向同步，任务显示在对应日期
- 传统交互：保留文件夹→清单→任务的三层结构，符合用户习惯
- AI 增强：预留扩展点，为后续智能排序、每日总结等功能奠定基础

### 1.3 与现有模块的关系

| 模块 | 联动方式 |
|------|----------|
| 日历 | 双向同步，日历中可创建/编辑任务 |
| 习惯 | 习惯关联的待办事项（如运动日记录） |
| 健康 | 运动/饮食计划可转为待办任务 |
| 聊天 | 后续支持对话创建任务（AI 能力） |

---

## 二、PRD 分析与问题识别

### 2.1 PRD 优点

✅ **数据模型设计完整**：Core Data 实体定义清晰，关系明确
✅ **功能优先级分明**：P0/P1/P2 分层合理，支持渐进式开发
✅ **验收标准具体**：MVP 和用户体验验收标准清晰
✅ **边界情况考虑周全**：数据边界和并发处理有明确说明

### 2.2 识别出的问题

#### 问题 1：数据模型中的命名冲突

PRD 中 `Task` 实体可能与 SwiftUI 或 iOS SDK 中的现有类型冲突。

**建议**：使用 `TodoTask` 或 `TodoItem` 作为实体名。

#### 问题 2：软删除与 Core Data 的集成

PRD 提到软删除，但未说明如何处理：
- 软删除后，Core Data 的 fetch request 需要全局过滤 `deletedAt == nil`
- 30 天自动清理需要后台任务支持

**建议**：在 Repository 层统一处理软删除过滤，避免每个查询都手动添加条件。

#### 问题 3：重复任务逻辑的复杂性

PRD 中的重复规则非常复杂（如"每月最后一个周五"），但实现细节不足：
- 完成一个重复任务后，是创建新任务实例还是修改原任务的 dueDate？
- 如何处理"跳过周末/节假日"的规则？

**建议**：采用"任务模板 + 实例"模式，原任务作为模板保留，每次完成时创建新实例。

#### 问题 4：四象限视图的自动分类规则

PRD 定义：
- 重要 = 优先级为「高/十分紧急」
- 紧急 = 今天或明天到期，或已过期

但优先级有四档（urgent/high/medium/low），与"重要"的映射关系不明确。

**建议**：明确定义映射规则：
- 重要：priority == .urgent || priority == .high
- 紧急：dueDate <= tomorrow || isOverdue

#### 问题 5：测试策略不够具体

PRD 提到 80% 覆盖率要求，但未说明：
- Mock 数据的创建方式
- Core Data 测试的隔离策略
- 通知权限的处理

---

## 三、实施方案

### 3.1 文件结构设计

```
Holo/Holo/
├── Models/
│   ├── TodoTask.swift                    # 任务实体
│   ├── TodoTask+CoreDataProperties.swift # 任务扩展
│   ├── TodoList.swift                    # 清单实体
│   ├── TodoList+CoreDataProperties.swift # 清单扩展
│   ├── TodoFolder.swift                  # 文件夹实体
│   ├── TodoFolder+CoreDataProperties.swift # 文件夹扩展
│   ├── TodoTag.swift                     # 标签实体
│   ├── TodoTag+CoreDataProperties.swift  # 标签扩展
│   ├── CheckItem.swift                   # 检查项实体
│   ├── CheckItem+CoreDataProperties.swift # 检查项扩展
│   ├── RepeatRule.swift                  # 重复规则实体
│   ├── RepeatRule+CoreDataProperties.swift # 重复规则扩展
│   ├── TodoModels.swift                  # 辅助模型（枚举/结构体）
│   └── TodoRepository.swift              # 任务数据仓库
│
├── Views/Tasks/
│   ├── TasksView.swift                   # 模块容器（底部 Tab 导航）
│   ├── TaskListView.swift                # 清单列表页
│   ├── TaskDetailView.swift              # 任务详情页
│   ├── AddTaskSheet.swift                # 新增/编辑任务
│   ├── FolderSidebarView.swift           # 文件夹侧边栏
│   ├── TaskRowView.swift                 # 任务行组件
│   ├── TaskCardView.swift                # 任务卡片组件
│   ├── TaskFiltersView.swift             # 筛选/排序视图
│   ├── TaskStatsView.swift               # 统计视图
│   ├── PriorityPicker.swift              # 优先级选择器
│   ├── DueDatePicker.swift               # 日期时间选择器
│   ├── ChecklistView.swift               # 检查清单视图 (P1)
│   ├── RepeatRuleView.swift              # 重复规则设置 (P1)
│   ├── TaskSearchView.swift              # 搜索视图 (P1)
│   └── EisenhowerMatrixView.swift        # 四象限视图 (P1)
│
├── Components/
│   ├── TaskPriorityChip.swift            # 优先级标签组件
│   ├── TaskStatusToggle.swift            # 任务状态切换组件
│   ├── TodoTagChip.swift                 # 任务标签芯片
│   └── TaskProgressBar.swift             # 进度条组件 (P1)
│
├── Services/
│   ├── TodoNotificationService.swift     # 本地通知管理
│   └── TodoRecurrenceService.swift       # 重复任务生成 (P1)
│
└── Utils/
    ├── Date+Helpers.swift                # 日期工具扩展
    └── TaskPriority+Colors.swift         # 优先级颜色映射
```

### 3.2 开发阶段划分

#### Phase 1: MVP 核心（3-4 周）

| 阶段 | 任务 | 预计工时 | 验收标准 |
|------|------|----------|----------|
| 1.1 | 数据模型与 Core Data 集成 | 3 天 | 实体编译通过，可 CRUD |
| 1.2 | TaskRepository 实现 | 2 天 | 单元测试通过，查询正确 |
| 1.3 | TasksView + TaskListView | 2 天 | 可从首页进入，显示列表 |
| 1.4 | AddTaskSheet + 基础属性 | 2 天 | 可创建任务，设置标题/优先级 |
| 1.5 | TaskDetailView | 2 天 | 可编辑所有基础属性 |
| 1.6 | 清单与文件夹管理 | 2 天 | 可创建/编辑/删除 |
| 1.7 | 软删除与回收站 | 2 天 | 删除进入回收站，可恢复 |
| 1.8 | 归档功能 | 1 天 | 已完成任务可归档 |
| 1.9 | 本地通知 | 2 天 | 截止时推送通知 |
| 1.10 | TaskStatsView | 2 天 | 统计数据显示正确 |

**MVP 里程碑**：完成所有 P0 功能，可独立使用

#### Phase 2: 体验增强（3 周）

| 阶段 | 任务 | 预计工时 | 验收标准 |
|------|------|----------|----------|
| 2.1 | CheckItem + ChecklistView | 2 天 | 可添加步骤，显示进度 |
| 2.2 | RepeatRule + RepeatRuleView | 3 天 | 可设置重复规则 |
| 2.3 | TodoRecurrenceService | 2 天 | 自动生成下次任务 |
| 2.4 | 多时间点提醒 | 1 天 | 可设置多个提醒 |
| 2.5 | EisenhowerMatrixView | 2 天 | 四象限展示正确 |
| 2.6 | TaskSearchView | 2 天 | 全文搜索可用 |
| 2.7 | 日历双向同步 | 3 天 | 日历中可创建/编辑任务 |

**Phase 2 里程碑**：完整功能集，用户体验接近成熟产品

#### Phase 3: AI 能力（后续）

- AI 智能排序
- AI 每日总结
- Widget 小组件
- Siri Shortcuts

### 3.3 依赖关系

```
                    ┌─────────────────┐
                    │   Phase 1.1-1.2 │
                    │  数据模型 +Repo │
                    └────────┬────────┘
                             │
            ┌────────────────┼────────────────┐
            │                │                │
            ▼                ▼                ▼
    ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
    │   Phase 1.3   │ │   Phase 1.6   │ │   Phase 1.7   │
    │   基础 UI     │ │  清单/文件夹  │ │  软删除/归档  │
    └───────┬───────┘ └───────┬───────┘ └───────────────┘
            │                 │
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │   Phase 1.4-1.5 │
            │   任务详情      │
            └────────┬────────┘
                     │
            ┌────────┴────────┐
            │                 │
            ▼                 ▼
    ┌───────────────┐ ┌───────────────┐
    │   Phase 1.9   │ │   Phase 1.10  │
    │   本地通知    │ │   统计视图    │
    └───────────────┘ └───────────────┘
```

### 3.4 代码复用清单

#### 可直接复用

| 组件 | 位置 | 说明 |
|------|------|------|
| TagSelector | `Components/TagSelector.swift` | 标签选择器直接使用 |
| DesignSystem | `Utils/DesignSystem.swift` | 颜色/字体/间距 |
| CoreDataStack | `Models/CoreDataStack.swift` | 扩展实体定义 |
| Repository 模式 | `Models/HabitRepository.swift` | 参考实现 |

#### 需适配复用

| 组件 | 适配说明 |
|------|----------|
| HabitCardView | 改为 TaskCardView，字段不同 |
| HabitDetailView | 改为 TaskDetailView，结构类似 |
| AddHabitSheet | 改为 AddTaskSheet，表单不同 |
| HabitsView | 改为 TasksView，Tab 不同 |

---

## 四、测试策略

### 4.1 单元测试（80%+ 覆盖率）

**测试文件**:
- `HoloTests/Models/TodoRepositoryTests.swift` - CRUD 操作
- `HoloTests/Models/TodoPriorityTests.swift` - 优先级排序
- `HoloTests/Services/TodoRecurrenceServiceTests.swift` - 重复规则计算
- `HoloTests/Services/TodoNotificationServiceTests.swift` - 通知调度

### 4.2 集成测试

- Core Data 持久化测试
- 通知权限处理
- 跨模块数据流（与日历模块）

### 4.3 E2E 测试

- 创建任务完整流程
- 完成任务流程
- 删除/恢复流程

---

## 五、风险识别与缓解

| 风险 | 影响 | 概率 | 缓解措施 |
|------|------|------|----------|
| Core Data 模型迁移 | 高 | 中 | 启用轻量级迁移，充分测试 |
| 本地通知权限被拒 | 中 | 低 | 首次启动时引导用户授权 |
| 重复任务逻辑复杂 | 中 | 中 | 采用任务模板 + 实例模式，充分测试 |
| iCloud 同步冲突 | 高 | 低 | Phase 1 先做本地，后续启用 CloudKit |
| 需求范围蔓延 | 高 | 高 | 严格按 P0/P1/P2 优先级执行 |

---

## 六、验收标准

### MVP (Phase 1) 验收清单

- [ ] 可从首页进入待办模块
- [ ] 可创建/编辑/删除任务
- [ ] 支持三层结构（文件夹→清单→任务）
- [ ] 支持四档优先级
- [ ] 支持截止时间和全天任务
- [ ] 支持多标签
- [ ] 软删除和回收站
- [ ] 归档功能
- [ ] 本地通知提醒
- [ ] 统计视图

### P1 功能验收清单

- [ ] 检查清单（Checklist）
- [ ] 重复任务
- [ ] 四象限视图
- [ ] 搜索功能
- [ ] 日历双向同步

---

## 七、关键文件

实施本计划最关键的 5 个文件：

1. **`Models/CoreDataStack.swift`** - 需要在 `createDataModel()` 中添加所有 Todo 实体
2. **`Models/TodoRepository.swift`** - 核心数据仓库，CRUD 和查询入口
3. **`Models/TodoTask.swift`** - 任务核心实体
4. **`Views/Tasks/TasksView.swift`** - 模块入口容器
5. **`Views/Tasks/TaskRowView.swift`** - 任务列表核心展示单元
