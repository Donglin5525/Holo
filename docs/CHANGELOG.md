# Changelog

本文件记录 HOLO 项目的所有重要变更。

## [Unreleased]

### Features
- **iOS**: Todo 模块重构为 Tab 栏导航模式
  - 重构 TasksView 为底部 Tab 容器（统计/任务/新增），与 Habits/Finance 模块交互一致
  - 新增 TaskListView 支持任务筛选（全部/收件箱/今日/已过期）
  - 新增 TaskStatsView 展示任务统计（总览/按优先级/今日进度）
  - 新增 AddTaskSheet 支持创建和编辑任务，可选择所属清单
  - 新增 TaskDetailView 展示任务详情
  - 右侧圆形 `+` 按钮直接弹出新建任务 Sheet
- **iOS**: 记账页面交互优化 — AddTransactionSheet 体验提升
  - Header 右侧新增 ✓ 保存按钮，点击即可完成记账
  - 下拉刷新保存记账（X 按钮 = 取消不保存）
  - 点击空白区域自动收起键盘，点击金额区域弹出数字键盘
  - 备注输入框颜色修复，深色模式下正常显示
- **iOS**: 导入账单科目智能匹配功能
  - 新增分类智能匹配服务，支持精确匹配、同义词匹配、模糊匹配三种策略
  - 导入预览界面新增分类匹配预览 Section，显示匹配统计和匹配列表
  - 同义词映射配置，支持「早饭」→「早餐」、「打车」→「出租车」等常见变体
  - 无匹配时智能推测图标和颜色（根据分类名称关键词）
- **iOS**: 分类管理页面新增批量清理导入分类功能
  - 新增清理按钮（扫帚图标），一键删除所有导入时自动创建的非预设分类
  - 被交易使用的分类会被自动保留，避免数据关联断裂
  - 修复分类管理页面编辑/删除按钮点击不响应的问题
- **iOS**: 全局右滑返回手势 — 统一的 SwipeBackModifier，支持所有页面
  - 新增可复用的 `SwipeBackModifier`，从左侧 40pt 区域右滑 120pt 即可关闭
  - 使用 `simultaneousGesture` 解决 ScrollView 手势冲突
  - 应用到 10 个页面：FinanceView、HabitsView、FinanceSearchView、SettingsView、HabitDetailView、AddTransactionSheet、AddHabitSheet、CategoryManagementView、ImportPreviewSheet、PopupCalendarSheet
- **iOS**: 深色模式完整适配 — 支持跟随系统/浅色/深色三种模式
  - 新增 DarkModeManager 单例管理器，UserDefaults 持久化用户设置
  - 新增 SettingsView 设置页面，从首页右上角人头像进入
  - 新增 9 个 Asset Catalog Color Sets（Background/CardBackground/TextPrimary/TextSecondary 等）
  - 每个颜色支持 Light/Dark 双变体，系统自动切换
- **iOS**: 分期记账功能 — 支持 3/6/12/24 期及自定义期数，自动分摊金额+手续费
  - Core Data 模型新增 installmentGroupId/installmentIndex/installmentTotal 字段
  - AddTransactionSheet 新增分期设置区域（期数选择、手续费输入）
  - 支持分期交易单笔删除或整组删除
- **iOS**: 交易搜索功能 — 新增 FinanceSearchView，支持关键词搜索交易记录
  - FinanceView 顶部新增搜索按钮入口

### Bug Fixes
- **iOS**: 修复 Todo 模块保存任务时崩溃问题
  - Core Data 属性名不匹配：`allDay` → `isAllDay`
  - `@StateObject` 创建多实例问题，改用单例访问 `TodoRepository.shared`
- **iOS**: 修复周视图点击日期跳转到错误周的问题 — 隐藏的月历网格触摸事件穿透
- **iOS**: 修复切换 Tab 后日历状态丢失的问题 — CalendarState 提升到 FinanceView 层级
- **iOS**: 优化账本标题显示，非今天仅显示「M月d日」避免换行
- **iOS**: 修复删除/归档习惯时真机闪退（EXC_BREAKPOINT）问题 — 多视图竞态条件全面修复
  - HabitsView: 通知驱动 UI 更新，避免 sheet.onDismiss 直接修改数组
  - HabitDetailView: 缓存 habit ID，三层防线避免访问已删除对象
  - HabitCardView: onReceive 使用缓存 ID，不再直接访问 Core Data 对象属性

### Chores
- 精简 CLAUDE.md，移除与全局规则重复的内容
- 配置真机开发环境（DEVELOPMENT_TEAM、Bundle ID）
- 文档重组：按模块划分子目录（`docs/_common/`、`docs/finance/`）

## [0.3.0] - 2025-03-16

### Features
- App 图标上线，支持 light/dark/tinted 模式
- 习惯图标系统扩展 — 9 大分类 62 个图标 + 自定义 SVG 支持

### Bug Fixes
- 移除 App Groups 配置以支持免费开发者账号真机调试
