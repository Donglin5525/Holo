# Changelog

本文件记录 HOLO 项目的所有重要变更。

## [Unreleased]

### Improvements
- **iOS**: 清单系统重构
  - 清单选择器扁平化显示，移除文件夹层级嵌套
  - 新建清单不再需要先创建文件夹
  - 任务列表筛选器支持按清单筛选，显示清单颜色
  - 长按清单可编辑/删除
  - 修复新建清单后无法显示的问题
  - 修复任务关联清单不生效的问题
- **iOS**: AddListSheet 颜色选择交互优化
  - 选中颜色显示 checkmark 图标，交互更明显
- **iOS**: AddTaskSheet 日期选择交互优化
  - 将双 Toggle 开关简化为「单一开关 + 胶囊切换」模式
  - 全天/定时切换使用胶囊样式，与优先级选择器风格一致
  - 点击日期文字区域可展开/收起日期选择器
  - 视觉更简洁，交互更直观
- **iOS**: TaskDetailView 支持直接编辑模式
  - 移除顶部"编辑"按钮，改为直接点击字段编辑
  - 优先级点击弹出 Menu 选择器直接调整
  - 截止日期点击弹出日期选择器直接调整（含全天/定时切换、提醒设置）
  - 标签点击弹出标签选择器直接调整
  - 标签选择器支持新增标签功能
- **iOS**: TaskCardView 检查清单平铺展示
  - 在任务卡片中直接显示检查清单项，支持直接勾选
  - 超过5项显示"还有 X 项"省略，点击展开/收起
  - 元信息区域显示检查清单进度（如"已完成 2/5 项"）
- **iOS**: ChecklistView 适配 Holo 设计风格
  - 使用 Holo 设计系统颜色、字体、间距
  - 添加进度概览卡片显示完成进度
  - 统一卡片样式和按钮样式

### Bug Fixes
- **iOS**: 修复统计视图 TOP 3 卡片布局问题
  - 移除标题区域多余的 TOP 3 标签（支出/收入显示不一致）
  - 移除排名徽章，为科目名称和金额腾出更多空间
  - 金额使用 fixedSize 确保完整显示，支持六位数加小数点格式
  - 科目名称添加 truncationMode 在空间不足时末尾截断
  - 优化图标尺寸和布局间距

### Features
- **iOS**: TaskDetailView 风格统一
  - 重构为卡片式布局，与 HabitDetailView 风格一致
  - 使用 Holo 设计系统（holoBackground/holoCardBackground/holoTextPrimary 等）
  - 截止日期统一使用中文格式（M月d日 E / 今天 / 明天）
  - 新增提醒时间显示（在时间卡片中显示已设置的提醒）
  - 添加右滑返回手势支持
- **iOS**: Todo 本地通知提醒功能
  - 新增 ReminderPicker 组件，支持多选预设提醒时间（截止时/5分钟/15分钟/30分钟/1小时/1天前）
  - 新增 NotificationSettingsView 全局通知设置页面（权限管理/每日提醒/测试通知）
  - TodoNotificationService 增强：每日提醒、通知分类、操作按钮（完成任务/15分钟后提醒）
  - AddTaskSheet 集成提醒选择器，截止日期开关控制提醒可用性
  - TaskListView 新增通知设置入口（header 右侧铃铛按钮）
  - 数据模型扩展：TodoTask 新增 reminders/hasDailyReminder/smartReminderEnabled 字段
  - HoloApp 生命周期集成：自动设置通知代理和注册分类
  - 预留 AI 智能提醒接口（smartReminderSchedule）
- **iOS**: 财务分析 TOP3 分类卡片 UI 优化
  - 优化布局为更紧凑的水平排列
  - 修复卡片宽度不自适应问题
- **iOS**: 财务统计分析模块 — 三 Tab 可视化分析视图
  - 总览 Tab：柱状图展示支出/收入对比，TOP3 分类卡片
  - 明细 Tab：折线图 + 点击交互查看具体日期交易列表
  - 类别 Tab：环形饼图 + 一级分类下钻到二级分类
  - 时间范围选择：日/周/月/季度/年 + 自定义日期范围
  - X 轴粒度自动切换：<=1 天按小时，2-14 天按天，15-90 天按周，>90 天按月
  - 新增 FinanceAnalysisState 状态管理（参考 CalendarState 模式）
  - 新增 FinanceAggregation 数据模型（ChartDataPoint/CategoryAggregation/PeriodSummary）

- **iOS**: 财务统计分析时间选择器优化
  - 去掉"日"维度选项，保留周/月/季度/年/自定义
  - 修复自定义日期选择器：改用 Tab 切换开始/结束日期，确保可正常滚动选择
- **iOS**: 习惯模块交互优化
  - 记录删除添加确认弹窗，防止误删
  - 修复时间范围选择器（近30天/90天/全部）点击无响应问题
  - 测量类习惯卡片显示历史最新值（如体重），即使今日无记录也能展示
- **iOS**: 日期选择器月份中文化及年月顺序统一
  - 为所有 DatePicker 添加中文 locale（zh_CN），确保月份显示为中文而非英文
  - 修改文件：CustomDateSheet、TimeRangeSelector、AddTransactionView、RepeatRuleView
  - 将 RepeatRuleView 中的序数词改为中文数字（"一"、"二"、"三"...）
  - 统一 MonthYearPickerView 的年月顺序为"先月份后年份"
- **iOS**: 修复财务统计分析模块 UI 问题
  - 修复 TOP3 卡片在无数据时高度不一致问题（固定高度 200pt）
  - 修复饼图中心信息展示，添加选中分类的图标、名称、占比、金额动画
  - 修复明细页点击图表后按粒度展示数据（非仅单日）
  - 新增日期范围标签点击下钻功能（周/月/季度可跳转到具体时间段）
  - 修复日期选择器确认后不生效的问题（currentDateRange 优先使用 customDateRange）
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
