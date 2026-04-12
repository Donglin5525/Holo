# Holo 待办清单

---

## 🔴 Bug 修复

| 优先级 | 问题 | 位置 | 状态 |
| --- | --- | --- | --- |
| 高 | AddTaskSheet 截止日期选择器无法交互 | `AddTaskSheet.swift` | 🔴 Open |
| 高 | HealthKit 授权失败：真机上点击授权按钮后卡死，需在 Xcode 手动配置 Signing & Capabilities 添加 HealthKit | `HealthRepository.swift` | 🔴 Open |

---

## ⏸️ 暂缓（等待开发者账号）

| 项目 | 说明 | 规划文档 |
| --- | --- | --- |
| 桌面小组件 - 习惯模块 | 需要 App Groups 共享数据，需付费开发者账号 | `docs/_common/plans/桌面小组件规划.md` |

---

## 🟡 功能开发

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| 习惯模块 | ✅ 已完成 | 打卡 + 统计 + 图标系统 |
| 记账模块 | ✅ 已完成 | 交互优化 + 深色模式适配 |
| 任务模块 | 🚧 进行中 | MVP + Phase 2 大部分完成 |
| 健康模块 | 📋 待开发 | PRD + 实现计划已完成，等待开发 |
| AI 对话 | 🚧 Phase 1-3 已完成 | Phase 1-3 意图扩展+路由重构已完成，Phase 4 确认卡片待实施，Phase 5 能量系统独立迭代 |

### 任务模块 Phase 2 待办

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| CheckItem + ChecklistView | ✅ | 检查清单可用 |
| RepeatRule + RepeatRuleView | ✅ | 重复规则设置可用 |
| 多时间点提醒 | ✅ | ReminderPicker 组件已集成 |
| 四象限视图 | ⏳ | 待实现 EisenhowerMatrixView |
| 搜索功能 | ✅ | TaskSearchView 已完成 |
| 日历双向同步 | ⏳ | 待实现 |

### 记忆长廊 Phase 2 待办

| 功能 | 状态 | 说明 |
|------|------|------|
| 里程碑触发日期修正 | 🔴 高 | 里程碑应标记在达成日期，而非永远"今天" |
| 空状态 CTA 按钮 | 🟡 中 | 添加"去记账"按钮跳转记账模块 |
| 节点时间线连接线 | 🟡 中 | 高亮/里程碑与左侧竖线缺少视觉连接 |
| 错误状态重试 UI | 🟡 中 | ViewModel 有 errorMessage 但 View 未渲染 |
| 骨架屏 shimmer 动画 | 🟢 低 | 当前静态色块，需加闪烁动画 |
| 筛选切换过渡动画 | 🟢 低 | 设计稿要求渐隐渐显，当前直接替换 |

### 观点模块

状态：✅ Phase 4 已完成，Phase 5 待开发

#### Phase 1: 数据层 ✅
- [x] Core Data 模型定义 (Thought, ThoughtTag, ThoughtReference)
- [x] NSManagedObject 子类生成
- [x] ThoughtRepository 仓储层实现

#### Phase 2: 列表视图层 ✅
- [x] ThoughtsView 根视图容器
- [x] ThoughtListView 主列表（下拉刷新、筛选）
- [x] ThoughtCardView 卡片组件
- [x] ThoughtFilterSheetView 筛选面板（心情、日期范围）
- [x] 首页入口集成 (fullScreenCover)

#### Phase 3: 编辑器层 ✅
- [x] ThoughtEditorView 主编辑器
- [x] MoodSelectorView 心情选择器
- [x] TagInputView 标签输入
- [x] ReferenceSelectorView 引用选择器

#### Phase 4: 详情页层 ✅
- [x] ThoughtDetailView 详情视图
- [x] ReferenceCardView 引用卡片
- [x] 引用关系展示（引用 + 反向链接）
- [x] 编辑功能集成

#### Phase 5: 搜索功能 📋 待开发
- [ ] ThoughtSearchBarView 搜索栏组件
- [ ] 搜索结果高亮
- [ ] 搜索历史

#### Phase 6: 测试与优化 📋 待开发
- [ ] Repository 层单元测试
- [ ] UI 测试

---

## 📋 已规划待实施

### 跨模块 / 基础设施

| 项目 | 规划文档 | 说明 |
|------|----------|------|
| 全局手势返回 | `docs/_common/plans/全局手势返回.md` | 统一 SwipeBackModifier，消除 FinanceView/HabitsView 重复代码，覆盖 10+ Sheet 页面 |
| 震动反馈规范化 | `docs/_common/plans/震动反馈规范化.md` | 创建 HapticManager 枚举，统一触觉反馈 API，补全保存交易/完成任务等缺失反馈 |
| 推送通知 | `docs/_common/plans/push 规划.md`、`push 开发计划.md` | 7 阶段本地推送：Core Data 扩展、通知服务增强、提醒选择 UI、设置页面、应用生命周期集成 |

### 记忆长廊

| 项目 | 规划文档 | 说明 |
|------|----------|------|
| 三层叙事时间线 | `docs/_common/plans/记忆长廊三层叙事时间线设计.md` | 替换瀑布流为三层时间线（每日摘要 + 高亮 + 里程碑），设计评审已通过，待实施 |
| 里程碑自定义设置 | `docs/_common/plans/里程碑自定义设置.md` | MilestoneConfigManager 支持开关预设、调阈值、自定义里程碑类型，含设置页面 UI |

### AI 对话

| 项目 | 规划文档 | 说明 |
|------|----------|------|
| Prompt 本地编辑器 | `docs/_common/plans/Prompt本地编辑器方案.md` | 应用内查看/编辑/测试 AI 提示词模板，UserDefaults 覆盖 + 真实 LLM 调用测试 |
| AI 对话能力扩展 | `docs/_common/plans/AI对话能力扩展方案.md` | Phase 1-3 已完成（14 意图+实体链接+路由重构），Phase 4 确认卡片待实施，Phase 5 能量系统独立迭代 |

### 待办模块

| 项目 | 规划文档 | 说明 |
|------|----------|------|
| 图片附件 | `docs/todo/plans/TASK_IMAGE_ATTACHMENT_PLAN.md` | 每任务最多 9 张图，PhotosPicker 集成，缩略图网格 + 全屏查看器，待确认 |

### 记账模块

| 项目 | 规划文档 | 说明 |
|------|----------|------|
| 统计图表分析 | `docs/finance/plans/统计图表分析.md` | 概览/详情/类别三 Tab，Swift Charts 实现，支持 6 种时间范围 |
| 分期记账 + 全局搜索 | `docs/finance/plans/分期记账+全局搜索.md` | 分期字段 + 自动生成 N 笔交易；防抖实时搜索 + 搜索历史 |
| 导入账单类别智能匹配 | `docs/finance/plans/category-smart-matching.md` | CSV 导入三层匹配策略（精确 → 同义词 → 模糊），含匹配预览 UI |
| 自定义分类管理 | `docs/finance/plans/自定义分类管理.md` | 财务设置入口 + 82 图标网格选择器，增强 AddCategorySheet |
| SF Symbols 图标迁移 | `docs/finance/plans/图标迁移SF-Symbols方案.md` | 97 个 SVG → SF Symbols，Phase 1 预览完成，⏸️ 暂缓等待视觉确认 |

---

## 🟢 优化项

| 项目 | 备注 |
| --- | --- |
| 大文件重构 | 5 个文件超过 1000 行，需拆分至 <800 行：CoreDataStack、AddTransactionSheet、FinanceView、AddTaskSheet、FinanceRepository |
| 代码质量目标 | 单文件 <800 行，组件化复用，消除重复代码 |
| Swift 6 兼容性 | MainActor 隔离 (10 处) + retroactive (4 处) |
| 记账首页卡片 | 支出/收入卡片面积过大，需重新设计 |
| App 性能优化 | - |
| iPad 适配 | - |

---

## 🔵 基础设施

| 项目 | 时机 |
| --- | --- |
| iCloud 同步 | App 整体开发完成后 |

---

## ✅ 已完成

| 项目 | 完成日期 |
| --- | --- |
| 习惯模块（打卡 + 统计 + 图标系统） | 2025-03-18 |
| 记账页面交互优化 | 2026-03-19 |
| 深色模式适配 | 2026-03-24 |
| 分类管理页面编辑按钮 + 返回手势修复 | 2026-03-26 |
| 分类管理页面重构为两级导航结构 | 2026-03-26 |
| 编辑自定义分类后返回误弹删除确认框修复 | 2026-03-27 |
| 分类系统扩展（人情分类 + 22 个图标） | 2026-03-28 |
| 记账页面左右滑动切换日期 | 2026-03-30 |
| 观点模块完整功能上线（数据层+列表+编辑器+详情页） | 2026-03-30 |
| 习惯统计模块多项修复（时间切换/图标/图表/布局） | 2026-03-30 |
| 记账键盘交互优化（选分类收起键盘+回车跳备注） | 2026-03-29 |
| 记账周视图视觉优化（无消费胶囊底色+日期对齐+边框修复） | 2026-03-30 |
| AI 对话模块完整功能上线（网络层+AI服务层+对话界面+意图路由） | 2026-04-04 |
| AI 对话能力扩展 Phase 1-3（14 意图+实体链接+路由重构+Prompt 重写） | 2026-04-12 |
