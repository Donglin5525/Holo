# Changelog

本文件记录 HOLO 项目的所有重要变更。

## [Unreleased]

### Features
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
