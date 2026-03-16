# Changelog

本文件记录 HOLO 项目的所有重要变更。

## [Unreleased]

### Bug Fixes
- **iOS**: 修复删除/归档习惯时真机闪退（EXC_BREAKPOINT）问题 — 多视图竞态条件全面修复
  - HabitsView: 通知驱动 UI 更新，避免 sheet.onDismiss 直接修改数组
  - HabitDetailView: 缓存 habit ID，三层防线避免访问已删除对象
  - HabitCardView: onReceive 使用缓存 ID，不再直接访问 Core Data 对象属性

### Chores
- 精简 CLAUDE.md，移除与全局规则重复的内容
- 配置真机开发环境（DEVELOPMENT_TEAM、Bundle ID）
- 新增分期搜索功能计划文档

## [0.3.0] - 2025-03-16

### Features
- App 图标上线，支持 light/dark/tinted 模式
- 习惯图标系统扩展 — 9 大分类 62 个图标 + 自定义 SVG 支持

### Bug Fixes
- 移除 App Groups 配置以支持免费开发者账号真机调试
