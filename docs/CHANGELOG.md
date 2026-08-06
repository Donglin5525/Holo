# Changelog

本文件是 HOLO 项目变更记录的**轻量入口**。

- **已发布的完整变更历史**：见根目录 [`CHANGELOG.md`](../CHANGELOG.md)（按日期、叙事式、详细记录）。
- **下个版本待发布清单**：见下方 `[Unreleased]`（分类累积，发布后合并进根目录）。

> ⚠️ 同一项改动**只记一处**：已发布的写根目录 CHANGELOG；待发布的写在这里。
> 不要两边重复记录，避免维护负担和不一致。

---

## [Unreleased]

### Bug Fixes
- **iOS**: 修复全局键盘避让导致输入框被挤压/遮挡的体验问题。想法首页搜索框键盘弹出时不再被压缩；今日看板习惯数值输入弹窗（手写 overlay 系统避让管不到）改为跟随键盘高度上移；调整余额备注框改为可滚动避免被遮；习惯打卡（卡片入口/快捷打卡）、周期项目编辑、一次性购买编辑的数字键盘统一补「完成」收键盘按钮

### Improvements
- **docs**: 规范文档归类重组——创建 `docs/standards/` 规范中心，集中 6 个开发/Prompt/图表/Agent 规范文档，新增 `INDEX.md` 按场景索引；清理根目录临时过程文件（findings/progress/task_plan/memory）
- **docs**: 键盘避让事故复盘沉淀进开发守则（三轮误判错误模式、`KeyboardAvoidanceDisabler` 修复方案）；速查表加「键盘弹出输入框被顶起」条目；自检清单加键盘检查项

---

*历史发布记录已迁移至根目录 [`CHANGELOG.md`](../CHANGELOG.md)。本文件仅保留 `[Unreleased]` 累积区。*
