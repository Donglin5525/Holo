# Holo 更新日志

记录 Holo App 的版本更新历史

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
