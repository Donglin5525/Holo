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

### 任务模块 Phase 2 待办

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| CheckItem + ChecklistView | ✅ | 检查清单可用 |
| RepeatRule + RepeatRuleView | ✅ | 重复规则设置可用 |
| 多时间点提醒 | ✅ | ReminderPicker 组件已集成 |
| 四象限视图 | ⏳ | 待实现 EisenhowerMatrixView |
| 搜索功能 | ✅ | TaskSearchView 已完成 |
| 日历双向同步 | ⏳ | 待实现 |

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
