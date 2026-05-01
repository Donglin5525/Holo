# HOLO - 个人数据资产 + AI 规划 iOS 应用

**技术栈**：SwiftUI, Swift 5+, MVVM, Core Data
**核心模块**：记账 ✅ | 习惯追踪 ✅ | 待办 🚧 | 健康 📋 | 观点 📋 | AI 对话 ✅

---

## 协作规则

| 规则 | 说明 |
|------|------|
| 全局中文回复 | 所有回复使用中文 |
| 称呼东林 | 每次回答前先称呼名字 |
| 禁止兼容性代码 | 除非东林主动要求 |
| 需求模糊时 | 先提问澄清再写代码 |
| 修改 >3 个文件 | 先拆成小任务 |
| 出 Bug 时 | 先写能重现的测试再修复 |
| 被纠正后 | 反思并制定不再犯的计划 |

---

## 开发前必读

| 文档 | 用途 |
|------|------|
| `docs/_common/HoloPRD.md` | 产品需求文档 |
| `docs/_common/开发规范.md` | 开发规范与踩坑总结（编码约定、布局、Core Data 等） |
| `docs/_common/notes/` | 历史问题解决方案（含 Core Data 调试） |
| `docs/*/plans/` | 各模块实施计划（含已完成和待开发） |

> `docs/todo/` 是**待办模块的文档目录**，不是项目级待办。东林说"更新 TODO"指的是根目录 `TODO.md`。

---

## 开发流程

新功能或非平凡重构前，按以下流程推进：

| 阶段 | 说明 |
|------|------|
| 写方案 | 在 `docs/*/plans/` 下写实施计划，明确范围、数据结构、涉及文件 |
| 对抗评审 | 方案完成后做对抗性审查：检查边界遗漏、技术可行性、与现有代码冲突 |
| 实施 | 评审通过后按步骤实施，多步任务用 TaskCreate 追踪进度 |

---

## 编码约定

| 规则 | 说明 |
|------|------|
| 禁止 `!` | 用 `if let` / `guard let` |
| 禁止 `print()` | 用 `Logger` |
| 错误处理 | 必须 `try-catch` |
| ScrollView | 必须隐藏滚动条 `showsIndicators: false` |
| DatePicker | 必须中文 locale `.environment(\.locale, Locale(identifier: "zh_CN"))` |
| 日期显示 | 禁止 `Text(date, style:)` 和 `date.formatted()`，必须用 `DateFormatter` + `zh_CN` |
| 右滑返回 | fullScreenCover 加 `.swipeBackToDismiss`，push/sheet 系统自带 |
| ScrollView 手势 | 禁止 SwiftUI `DragGesture`，用 `UIViewRepresentable` + `UIPanGestureRecognizer`。**方向确认前禁止禁用 ScrollView**：`.began` 只重置状态，`.changed` 中确认水平方向后才 `isScrollEnabled = false`，垂直方向直接 `cancel` 手势即可 |
| SF Symbol | 新增/修改名称时**必须先验证存在**（`NSImage(systemSymbolName:) != nil`），无效名称渲染为空白 |
| 金额显示（空间受限） | 必须用 `NumberFormatter.compactCurrency()`（万/亿单位），禁止 `fixedSize`，改用 `minimumScaleFactor(0.7)` + `lineLimit(1)` |
| 金额显示（空间充足） | 用 `NumberFormatter.currency` 完整格式，仍需加 `minimumScaleFactor(0.7)` + `lineLimit(1)` 防溢出 |
| 自定义导航栏 | HStack 必须加 `.frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)` 固定高度，仅靠 padding 无法约束 |

### 修复策略

- 同一 bug 修两次未果 → **停下来找根因**，禁止叠补丁
- 黑屏/卡死 / 启动阻塞 → **先查 `docs/_common/开发规范.md` 第 10 节**（首次启动卡死排查规范），按 Checklist 逐项排查，不能只盯 CoreDataStack
- "位置对不上" → 先检查是否存在两套独立的坐标/角度计算逻辑
- Repository `init()` 必须零 I/O（`@StateObject` 在 body 求值时同步创建，早于 `.task`）
- 启动阻塞的解法是「默认值先渲染 + 后台补数据」，不是「异步优化」

---

## 提交规范

**Scope**：`iOS` / `icon` / `docs`
**格式**：`feat(iOS): 描述` / `fix(iOS): 描述` / `docs: 描述`

**提交流程**：`git add` → `git commit` → 更新 `CHANGELOG.md` + `TODO.md` → `git push`

**提交前**：编译通过 | 无 `print()` / force unwrap | CHANGELOG 已更新

---

## 模块文档

编辑某模块的 Models / Repository / Service 前，先读对应 CLAUDE.md：

| 模块 | 路径 |
|------|------|
| AI 对话 | `docs/_common/Chat模块文档.md` |
| 财务 | `Views/Finance/CLAUDE.md` |
| 待办 | `Views/Tasks/CLAUDE.md` |
| 习惯 | `Views/Habits/CLAUDE.md` |
| 健康 | `Views/Health/CLAUDE.md` |
| 观点 | `Views/Thoughts/CLAUDE.md` |
| 记忆画廊 | `Views/MemoryGallery/CLAUDE.md` |

---

## 禁止操作

- 修改 Xcode 项目配置（签名和 Bundle ID）
- Force push 到 main
- 删除整个目录
