# Holo 更新日志

记录 Holo App 的版本更新历史

---

## [2026-04-05] 财务分析页图表重构

### 改进
- 类别占比图表由饼图改为柱状图+折线图组合（柱状图显示金额，折线图显示占比百分比）
- 合并时间范围选择器和标签为统一组件，新增自定义日期按钮
- 分析页 Tab 栏简化样式，移除图标仅保留文字标签

## [2026-04-05] 优化财务统计分析饼图

### 改进
- 饼图缩小一圈（240→200），中心区域去掉分类图标，信息更紧凑
- 所有扇区均展示分类名称和占比，小扇区标签外延显示
- 饼图交互使用 UIKit 手势替代 SwiftUI DragGesture，解决 ScrollView 冲突
- 取消分析模块卡片背景，饼图/图例列表/分类详情与底色融为一体
- 下钻返回按钮移除卡片样式，仅展示简洁文字按钮

## [2026-04-05] 优化财务模块交易记录布局

### 改进
- 交易记录去掉独立卡片样式，改为列表行风格（分隔线替代卡片阴影）
- 交易记录背景与页面底色融为一体，视觉更简洁
- 交易行图标与"交易记录"标题左对齐
- 增大"今日账本"标题与周视图之间的间距（8pt → 16pt）

---

## [2026-04-04] 新增 Prompt 本地编辑器

### 新增
- AI 设置页新增"Prompt 模板"入口，列出 6 个可编辑的提示词模板
- PromptEditorView：查看、编辑、保存自定义 Prompt，支持变量预览
- PromptEditorViewModel：编辑状态管理 + LLM 测试功能
- PromptTestSheet：输入测试文本，发送到 LLM 实时查看响应
- PromptManager 支持 UserDefaults 自定义覆盖，优先于硬编码默认值
- 恢复默认：一键清除自定义 Prompt 回退到系统默认

### 改进
- PromptType 新增 displayName/displayDescription/icon UI 元数据

### 修复
- CategoryPicker 从 `.task` 改为 `.onAppear`，每次打开"记一笔"时重新加载"最近使用"分类
- FinanceLedgerView 月份标题底部间距调整

---

## [2026-04-04] 新增 AI 对话模块

### 新增
- AI 对话主界面（ChatView）：消息列表 + 快捷操作栏 + 输入栏
- 消息气泡（MessageBubbleView）：用户/AI 双样式，意图标签，流式打字动画
- 流式文本渲染（StreamingTextView）：打字中闪烁光标，完成后 Markdown 渲染
- 快捷操作栏（QuickActionBar）：记账/任务/观点/打卡/周报一键触发
- AI 设置页（AISettingsView）：Provider 选择、API Key、模型配置、连接测试
- AI 配置 ViewModel（AIConfigViewModel）：Keychain 安全存储、Provider 切换
- ChatViewModel：消息管理、流式响应、意图路由
- OpenAI 兼容 Provider：统一适配 DeepSeek/Qwen/Moonshot/Zhipu/自定义
- MockAIProvider：关键词匹配意图识别 + 模拟流式响应
- 网络层（APIClient + APIRequest + APIError + SSEParser）：重试退避、SSE 解析
- KeychainService：API Key 安全存储
- PromptManager：JSON 模板加载 + {{变量}} 替换
- UserContextBuilder：从记账/习惯/任务/观点 Repository 构建用户上下文
- IntentRouter：意图识别 → 本地 Repository 操作路由（记账/任务/观点/打卡）
- ChatMessage Core Data 实体 + Repository
- 6 个 Prompt 模板 JSON（系统提示/意图识别/数据提取/澄清/洞察/响应）
- AI 数据模型（AIModels.swift、AIConfiguration.swift）

### 变更
- CoreDataStack 新增 createChatEntities() 方法
- ContentView .holo tab 从占位视图替换为 ChatView
- SettingsView 新增 AI 设置入口
- 首页麦克风按钮连接 ChatView（fullScreenCover）

---

## [2026-04-04] 修复日期显示英文 + 开发规范更新

### 修复
- 任务列表卡片截止日期改用 DateFormatter + zh_CN，避免英文设备显示 "Apr 4"
- 记账页日期行、交易时间已在上一提交修复

### 变更
- CLAUDE.md 编码约定新增日期显示规范（禁止 Text(date, style:) / date.formatted()）
- 开发规范全局中文化章节补充禁止 API 列表和检查清单

---

## [2026-04-04] 账本页 UI 改版 — 月度卡片 + 显示设置

### 新增
- 月度收支概览卡片（MonthlySummaryCard），支持环比对比（如 4.1-4.4 vs 3.1-3.4），自动处理月份天数差异
- 卡片右侧显示当日支出金额
- 财务设置新增"显示设置"区块，支持切换"本月支出"/"本月收入"卡片显隐（默认仅显示支出）
- FinanceDisplaySettings 单例，UserDefaults 持久化显示偏好

### 变更
- "今日账本"标题移至按钮行下方独占一行，修复居中对齐问题
- 删除旧的日级支出/收入卡片（ExpenseCard、IncomeCard）
- 整体布局间距收紧（标题、拖拽手柄、卡片、交易列表标题）
- 卡片水平 padding 收窄 10pt

### 修复
- AddTransactionView 日期显示改用 DateFormatter + zh_CN locale（原 `Text(date, style: .date)` 不符合项目规范）

---

## [2026-04-04] 任务完成按钮交互修复

### Bug 修复
- 修复任务列表中无法直接点击圆形按钮完成任务的问题
- 根因：SwipeActionView 的 UIKit overlay 拦截了所有触摸事件，导致 SwiftUI Button 无法响应
- 方案：overlay 的 hitTest 返回 nil 实现触摸穿透，Pan 手势改挂到父视图，导航点击改由 SwiftUI Button 处理

### 变更
- 点击圆形按钮 → 直接完成/取消完成任务
- 点击文字区域 → 进入任务详情页
- 观点卡片同步采用相同的触摸穿透机制

---

## [2026-04-03] 修复观点新增卡死 + 设置页调试入口

### Bug 修复
- 修复真机上点击"新增观点"按钮后 App 卡死的问题
- 根因：UITextView `isScrollEnabled=false` 在 SwiftUI ScrollView 中产生 `intrinsicContentSize` 无限布局反馈循环，真机布局时序更紧凑导致死循环
- 方案：改用 `isScrollEnabled=true` + `SelfSizingTextView` 通过 `sizeThatFits` 显式计算高度，异步回传给 SwiftUI

### 新增
- 设置页新增"调试"区域，支持清除观点模块数据（Thought/ThoughtTag/ThoughtReference）

---

## [2026-04-02] 修复任务列表滚动冲突

### Bug 修复
- 修复任务/观点列表中卡片铺满屏幕时无法上下滚动的问题
- 根因：SwiftUI `DragGesture` 在 ScrollView 内会拦截滚动手势
- 方案：改用 UIKit `UIPanGestureRecognizer` + `gestureRecognizerShouldBegin` 方向判断，垂直放行给 ScrollView

---

## [2026-04-01] 任务检查清单 + 记忆长廊三层时间线

### 新增功能

#### 任务检查清单
- 新建任务支持添加检查清单，保存时批量创建 CheckItem
- 编辑任务支持管理检查清单（添加、勾选、删除）
- 检查清单区域与任务表单无缝集成

#### 记忆长廊三层叙事时间线
- 重构为垂直时间线布局：日摘要 → 高亮 → 里程碑
- 新增 `HighlightDetector` 算法：检测消费异常、习惯表现、任务完成等值得注意事件
- 新增 `MilestoneDetector` 算法：检测连续打卡、累计记录、习惯掌握等重大成就
- 新增 `MemoryTimelineNode` 数据模型：统一三种节点类型
- 新增组件：`DailySummaryNode`（日摘要卡片）、`HighlightNode`（高亮卡片）、`MilestoneNode`（里程碑卡片）、`TimelineDateHeader`（日期头）
- 支持模块筛选（全部/记账/习惯/任务）

### Bug 修复
- 修复编辑任务时 `list` 参数未传递导致清单归属丢失的问题
- 修复 `MilestoneDetector` 属性名拼写错误（`streakThresholds` → `streakDaysThresholds`）
- 修复 `MemoryGalleryView` 中 ViewModel 属性名不匹配的问题
- 修复 `HighlightDetector` 交易类型查询谓词字段名错误

---

## [2026-03-31] 任务模块描述功能修复

### Bug 修复
- 修复新建任务时描述（desc）字段未保存的问题（createTask 缺少 description 参数）
- 修复新建/编辑任务页面标题"新建任务"重复显示的问题
- 任务详情页描述区域增加"描述"标签，与页面风格统一
- 任务列表卡片中新增描述截断展示（最多 2 行）

## [2026-03-30] 观点模块上线 + 多模块优化

### 新增功能

#### 观点模块
- Core Data 实体：Thought、ThoughtTag、ThoughtReference 注册到数据栈
- Repository 层：ThoughtRepository 实现 CRUD、搜索、标签管理、引用关系
- 视图层：列表页、编辑器、详情页、搜索栏、筛选、心情选择、标签输入、引用选择
- 首页集成：HomeView 观点按钮连通 ThoughtsView
- 通知机制：thoughtDataDidChange 刷新列表数据

### 改进优化

#### 记账模块
- 交易列表区域支持左右滑动手势快速切换前一天/后一天
- 复用 WeekView 两阶段动画模式（滑出 → 数据更新 → 弹入）
- 周视图无消费日期选中时用胶囊底色替代全格背景，减小底色占比
- 用透明文字占位确保有无消费的日期数字垂直对齐

#### 观点模块设计规范对齐
- 全局 holoPurple → holoPrimary，统一为橙色主题
- ThoughtCardView 圆角从 28pt 改为 HoloRadius.md(12pt)，去掉描边改为阴影
- 空状态、引用卡片、标签配色统一到设计规范

#### 习惯统计模块
- 修复时间维度切换不生效（@Binding+回调双重写入竞争）
- 修复时间选择器位置，移至 Tab 栏上方并加横向滚动
- 修复自定义图标不显示（Asset Catalog vs SF Symbol 适配）
- 修复数值型习惯显示错位，合并为单行 "值 / 目标"
- 修复测量类折线图 Y 轴标签过密，限制刻度数量为 4
- 修复完成率趋势图手势阻挡页面滚动

### Bug 修复
- 移除周视图未选中今日的多余边框
- 修复记账键盘交互：选分类后自动收起键盘，回车键跳转备注输入框
- 修复分类管理页面最后一个分类被底部 Tab 栏遮挡的问题

---

## [2026-03-28] 分类系统扩展与图标优化

### 新增功能

#### 分类系统扩展
- 新增支出一级分类「人情」（琥珀色 #F59E0B）
  - 子分类：红包礼金、请客、送礼、探望、其他
- 餐饮新增：饮品、水果、酒水、超市
- 交通新增：公交、火车、机票
- 居住新增：房贷、家电、装修
- 医疗新增：牙齿保健、医疗用品
- 其他新增：话费、烟酒
- 工资收入新增：报销
- 其他收入新增：公积金、出闲置

#### 新增图标（22个）
- 餐饮类：饮品、水果、酒水、超市
- 交通类：公交、火车、机票
- 居住类：房贷、家电、装修
- 医疗类：牙齿保健、医疗用品
- 人情类：红包礼金、请客、送礼、探望、人情其他
- 其他类：话费、烟酒、报销、公积金、出闲置

### 优化

#### 图标渲染统一
- `CategoryPicker.swift`：统一使用全局 `transactionCategoryIcon()` 函数
- `QuickTemplateView.swift`：修正 SF Symbol 字体比例（size → size*0.6）
- 修复 11 个 SVG 图标 viewBox 不一致导致的大小差异

#### 分类数据迁移
- 优化 `seedDefaultCategories()` 支持增量补充新分类
- 已有数据的用户升级后自动获得新增分类

---

## [2026-03-28] 首页图标拖拽修复

### Bug 修复

#### 首页模块图标拖拽交换
- 修复长按拖拽图标到其他位置时，选中和被选中图标剧烈跳动的问题
- 引入 `anchorTotalShift` 累计锚点位移变量，每帧统一计算 `dragOffset = translation - anchorTotalShift`
- 解决 `DragGesture.translation` 不可重置导致的坐标补偿失效
- 拖拽过程中屏蔽外部数据源刷新，防止数据竞争

---

## [2026-03-26] 任务日期选择交互重设计

### 新增功能

#### 任务日期选择弹窗
- 新增 `TaskDatePickerSheet.swift` 整合日期、提醒、重复设置
  - `DatePicker(.graphical)` 日历选择
  - 全天/定时切换按钮
  - 提醒设置（整合 ReminderChip 组件）
  - 重复设置（每天/每周/每月/每年/自定义）
  - 结束条件（永不/指定日期/重复次数）
  - 支持半屏和全屏两种 detents

### 改进优化

#### AddTaskSheet 简化
- 移除内联展开的 `DatePicker`
- 移除独立的 `reminderSection` 和 `repeatSection`
- 点击日期区域弹出 `TaskDatePickerSheet`
- 添加设置摘要徽章显示（提醒数量、重复类型）

#### 组件复用
- 新增 `Components/ReminderChip.swift`
- 新增 `Components/TaskChips.swift`（RepeatTypeChip、WeekdayChip）
- 移除重复的组件定义

### Bug 修复

#### 结束条件 UI
- 添加"重复次数"选择器 UI（1-100 次）
- 修复结束日期弹窗按钮重复问题

---

## [2026-03-25] 健康模块基础实现

### 新增功能

#### 健康数据读取（HealthKit）
- 集成 HealthKit 框架，支持读取步数、睡眠时长、站立时长
- 新增 `HealthRepository` 数据仓库，封装 HealthKit 查询逻辑
- 支持模拟器环境自动切换为模拟数据

#### 健康视图
- 新增 `HealthView` 健康主页面，展示今日健康数据概览
- 新增 `HealthDetailView` 详情页，包含 7 天趋势图表
- 新增 `HealthPermissionView` 权限请求页面

#### 组件
- `HealthRingView` - 圆环进度指示器
- `HealthMetricCard` - 指标卡片（含进度条）
- `HealthTrendChart` - 7 天趋势柱状图（使用 Swift Charts）

#### 项目配置
- 配置 HealthKit entitlements（read-only 模式）
- 首页五角形按钮添加健康模块入口

### 已知问题
- HealthKit 授权在真机上需要手动在 Xcode 中配置 Signing & Capabilities

---

## [2026-03-16] App 图标上线 + 项目结构修复

### 新增功能

#### App 图标
- 正式设计并集成 HOLO App 图标
- 图标风格：暖色调米白背景 + 橙色连续线条勾勒的女性轮廓，顶部带有品牌字母 "H"
- 支持全尺寸适配：iPhone、iPad、App Store（29px ～ 1024px 共 12 个规格）
- 支持 iOS Light / Dark / Tinted 三种模式
- 原始图稿保存于 `icon/Holoicon.png`（2048×2048 高清源文件）

#### 项目文档
- 新增 `CLAUDE.md` 项目规范文件，记录技术栈、目录结构、开发工作流、提交规范等

### 问题修复

#### 项目结构修复（从 Cursor 迁移到 Claude）
- 修复因跨目录复制项目导致的 Swift 文件重复引用问题（`Multiple commands produce` 编译错误）
- 删除根目录 `Holo/` 下的 7 个重复 Swift 文件（与 `Holo APP/Holo/Holo/` 内容完全一致）
- 删除根目录 `Holo/Assets.xcassets/` 重复资源目录，消除 62 个分类图标名称冲突警告
- 清理旧 DerivedData 缓存（3 个指向 cursor 路径的残留缓存）

### 文件变更
- `Holo/Holo APP/Holo/Holo/Assets.xcassets/AppIcon.appiconset/` — 新增全套图标文件及更新配置
- `icon/Holoicon.png` — 新增 App 图标原始源文件
- `CLAUDE.md` — 新增项目规范文档
- 删除 `Holo/Assets.xcassets/`（重复资源目录）
- 删除 `Holo/Components/`、`Holo/Views/`、`Holo/Utils/`、`Holo/ContentView.swift`、`Holo/HoloApp.swift`（重复代码文件）

---

## [2026-03-15] 习惯图标系统扩展

### 新增功能

#### 图标分类系统
- 习惯图标从 20 个扩展到 **62 个**，按 9 大分类组织
- 新增图标分类：运动健身、健康生活、学习成长、自我提升、饮食营养、财务理财、日常习惯、戒除/减少、其他
- 每个图标带有中文标签，方便用户识别

#### 图标选择器升级
- 图标选择器改为分类展示，每个分类有独立标题
- 图标下方显示中文名称（如"跑步"、"阅读"）
- 视觉优化：圆角卡片 + 选中高亮效果

#### 自定义 SVG 图标支持
- 新增 `HabitIcons` Asset Catalog 文件夹
- 创建自定义"戒烟"图标（香烟 + 禁止符号 SVG）
- 支持混合使用 SF Symbol 和自定义 Asset 图标
- `IconItem` 新增 `isCustom` 属性区分图标类型

### 技术要点

#### 图标类型判断
- `Habit` 模型新增 `isCustomIcon` 计算属性
- 根据图标名在 `HabitIconPresets.allItems` 中查找是否为自定义图标
- 自定义图标使用 `Image(name).renderingMode(.template)`，SF Symbol 使用 `Image(systemName:)`

#### 数据结构
- `HabitIconCategory`：图标分类（name, icon, items）
- `IconItem`：单个图标项（name, label, isCustom）
- `HabitIconPresets.categories`：分类数据源
- `HabitIconPresets.allItems`：扁平化图标列表

### 文件变更
- `HabitType.swift`：新增图标分类数据结构和 62 个图标定义
- `AddHabitSheet.swift`：图标选择器改为分类展示，支持自定义图标
- `HabitCardView.swift`：习惯卡片图标显示支持自定义图标
- `Habit.swift`：新增 `isCustomIcon` 属性
- `Assets.xcassets/HabitIcons/`：新增习惯图标资源文件夹

---

## [2026-03-15] 习惯打卡功能

### 新增功能

#### 习惯数据模型
- `Habit` Core Data 实体：支持打卡型（每日打卡）和数值型（记录数值）两种习惯
- `HabitRecord` Core Data 实体：记录每次打卡/数值，与 Habit 一对多关联
- 支持自定义图标、颜色、频率（每日/每周/每月）、目标值
- 数值型习惯支持计数（累加）和测量（取最新值）两种聚合方式

#### 习惯首页 (HabitsView)
- 习惯卡片列表，展示图标、名称、频率/目标、今日状态
- 打卡型习惯：点击勾选按钮完成/取消打卡，显示连续天数
- 数值型习惯：计数类显示 +1 按钮，测量类显示输入按钮
- 底部 Tab 栏：统计 / 习惯列表 / 新增
- 顶部显示今日完成进度（如 2/5）

#### 习惯详情页 (HabitDetailView)
- 习惯信息头部：图标、名称、类型标签、频率目标
- 时间范围切换：本周 / 本月 / 本季度 / 全部
- 统计摘要：打卡型显示连续天数/完成次数/完成率，数值型显示总计/日均/峰值或变化/最低/最高
- 记录列表：按时间倒序展示，支持删除单条记录
- 工具栏操作：编辑 / 归档 / 删除

#### 新增习惯表单 (AddHabitSheet)
- 习惯名称输入
- 类型选择：打卡型 / 数值型（分段选择器）
- 数值型聚合方式：计数 / 测量
- 图标选择：20 个预设 SF Symbols
- 颜色选择：10 种预设颜色（5x2 网格）
- 频率选择：每日 / 每周 / 每月
- 目标设置：打卡型设目标次数，数值型设目标值和单位

#### 首页入口
- 点击首页「习惯」图标进入习惯模块（fullScreenCover）
- 支持从左边缘向右滑动返回首页

### 技术要点

#### SwiftUI + Core Data 最佳实践
- **body 内禁止 Core Data 查询**：所有查询在 `onAppear`/`onReceive` 中执行，结果缓存到 `@State`
- **@StateObject 不能包装 @MainActor 单例**：改用 `@ObservedObject` 或直接 `.shared` 调用
- **访问 @MainActor 单例必须用 Task 包装**：`Task { @MainActor in ... }`

#### NSManagedObject 删除流程
1. 使用 ID（UUID）而非对象引用传递
2. sheet 用 `item` 绑定（值类型 selection），避免 `isPresented + selectedId` 状态不同步导致的 Loading
3. 删除前先从本地数组移除（`habits.removeAll { $0.id == id }`）
4. 延迟 0.1s 再执行 Core Data 删除
5. 访问前检查 `!habit.isDeleted && habit.managedObjectContext != nil`
6. 使用 `isDeleted`/`managedObjectContext` 需 `import CoreData`

### 修复与优化
- 修复 `HabitCardView` / `HabitDetailView` 缺失 `import CoreData` 导致编译失败
- 修复习惯详情 sheet 首次打开偶现「加载中...」与卡顿：改为 `.sheet(item:)` 单一状态驱动展示
- 优化习惯变更通知：携带 `habitId`，仅刷新对应卡片/详情，减少全量 Core Data 查询
- 优化今日完成进度统计：从逐个习惯查询改为单次 fetch 统计

### 文档更新
- 开发规范新增「6️⃣ SwiftUI + Core Data 视图卡死/白屏问题」
- 开发规范新增「7️⃣ NSManagedObject 删除后访问崩溃」（含标准删除流程代码和时序图）

---

## [2026-03-14] 首页功能入口重构

### 新增功能

#### 五角形图标布局
- 首页功能入口从 4 个扩展为 5 个
- 新增「习惯」功能入口，使用 `checkmark.circle` 图标
- 布局从四角定位改为五角形环绕语音助手按钮
- 5 个图标均匀分布在语音按钮周围（每隔 72° 一个位置）

#### 长按拖拽排序
- 长按 0.5 秒激活拖拽模式，伴随触觉反馈
- 拖拽时图标放大 1.15x 并添加阴影效果
- 拖到其他位置 50pt 范围内自动交换位置
- 只能在 5 个固定位置之间交换，不支持自由停放
- 松手后弹性动画归位

#### 图标配置持久化
- 新增 `HomeIconConfig` Core Data 实体
- 用户调整的图标顺序自动保存到本地数据库
- 重启 App 后保持上次的排列顺序
- 预留 `isVisible` 和 `customName` 字段，支持后续扩展

#### iCloud 同步准备
- 数据架构已为 CloudKit 同步做好准备
- 在 `CoreDataStack.swift` 中添加详细的启用指南

### 优化调整
- 图标与文字间距从 8pt 减少到 4pt
- 五角形布局整体上移 10pt

---

## [2026-03-14] 数据导入导出功能

### 新增功能
- CSV 文件导入功能，支持从其他记账 App 迁移数据
- CSV 文件导出功能，支持数据备份
- 导入预览界面，确认数据无误后再导入
- 异常数据智能处理，自动识别和修复格式问题

---

## [2026-03-14] 记账月历视图 Phase 2

### 体验增强
- 月历交互优化
- 日期选择体验改进
- 动画过渡更流畅

### 交易管理优化
- 交易列表展示优化
- 交易详情页面完善
- 编辑和删除交易功能

---

## [2026-03-14] 记账月历视图 Phase 1

### 新增功能
- 周视图：展示一周的收支概览
- 月历视图：日历形式查看每日收支
- 弹窗抽屉：点击日期查看当日交易详情
- 日期导航：快速切换月份和年份

---

## [2026-03-11] 开发工具优化

### 新增
- 添加 `todo-sync-after-commit` 技能
- 自动同步 TODO 状态与 Git 提交

---

## [2026-03-08] 记账键盘优化

### 修复
- 记账键盘输入体验优化
- 金额显示格式修正
- 键盘响应速度提升

### 文档
- 新增记账模块业务规则文档

---

## [2026-03-07] 财务页 UI 大版本升级

### 新增功能
- 分类体系升级：支持 71 个图标的二级分类
- Asset Catalog 规范化管理分类图标
- Figma 导出图标转换脚本

### UI 优化
- 财务页 UI 全面优化
- Tab 栏与加号按钮合一设计
- 收支卡片视觉升级
  - 去除边框，更简洁
  - 微渐变背景
  - 负空间设计
  - 毛玻璃效果

### 文档
- 开发规范文档
- 开发前必读指南

---

## [2026-03-05] 仓库结构统一

### 调整
- 统一仓库结构
- 纳入 iOS 记账 MVP 代码
- 整理项目文档

---

## [2026-03-03] 开发规范

### 文档
- 添加开发规范文档
- 记录频繁提交和推送的最佳实践

---

## [2026-03-02] 首页 UI 实现

### 新增功能
- 实现 Holo 首页 UI
- 基于 Figma 设计稿还原
- 顶部问候语和用户头像
- 中央语音助手按钮
- 四角功能入口按钮
- 底部浮动导航栏
- 日程提醒组件

---

## [2026-03-01] 项目初始化

### 初始提交
- 创建 Holo 项目仓库
- 初始化项目结构
