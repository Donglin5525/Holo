# HOLO - 个人数据资产 + AI 规划 iOS 应用

**技术栈**：SwiftUI, Swift 5+, MVVM, Core Data
**核心模块**：记账 ✅ | 习惯追踪 ✅ | 待办 🚧 | 健康 📋 | 观点 📋 | AI 对话 ✅

---

## 🤝 协作规则

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

## 📖 开发前必读

| 文档 | 用途 |
|------|------|
| `docs/_common/HoloPRD.md` | 产品需求文档 |
| `docs/_common/开发规范.md` | 开发规范与踩坑总结 |
| `docs/_common/notes/` | 历史问题解决方案 |
| `docs/_common/plans/` | 已完成功能的实现计划 |

> **注意**：`docs/todo/` 是**待办模块的文档目录**（PRD、开发计划等），不是项目级待办清单。当东林说"更新 TODO"时，指的是根目录的 `TODO.md`（项目级待办清单），不要混淆。

---

## ⚡ 快速参考

### 编码约定

| 规则 | 说明 |
|------|------|
| MVVM 架构 | Model-View-ViewModel 分层 |
| 禁止 `!` force unwrap | 使用 `if let` / `guard let` |
| 禁止 `print()` | 使用 `Logger` 替代 |
| 错误处理 | 必须使用 `try-catch` |
| ScrollView 滚动条 | 必须隐藏 `showsIndicators: false` |
| DatePicker 语言 | 必须中文 `.environment(\.locale, Locale(identifier: "zh_CN"))` |
| 日期显示 | 禁止 `Text(date, style: .date/.time)` 和 `date.formatted(.dateTime)`，必须用 `DateFormatter` + `locale = Locale(identifier: "zh_CN")` |
| 右滑返回手势 | fullScreenCover 页面必须加 `.swipeBackToDismiss`，NavigationStack push 和 Sheet 系统自带 |
| ScrollView 内自定义手势 | 禁止使用 SwiftUI `DragGesture`，必须用 `UIViewRepresentable` + `UIPanGestureRecognizer`，通过 `gestureRecognizerShouldBegin` 控制方向（垂直放行给 ScrollView） |

```swift
// ScrollView 示例
ScrollView(showsIndicators: false) { ... }

// DatePicker 示例
DatePicker("", selection: $date, displayedComponents: .date)
    .environment(\.locale, Locale(identifier: "zh_CN"))

// 日期显示示例（禁止 Text(date, style:) / date.formatted()）
let f = DateFormatter()
f.locale = Locale(identifier: "zh_CN")
f.dateFormat = "M月d日"
return f.string(from: date)
```

### 图标管理

| 项目 | 路径/命令 |
|------|----------|
| 分类图标 (62个) | `Holo/Assets.xcassets/CategoryIcons/` |
| App 图标 | 1024×1024 PNG |
| 更新命令 | `python3 icon/integrate_icons.py` |

### 提交规范

**Scope**：`iOS` / `icon` / `docs`

```
feat(iOS): 新增分期记账功能
fix(iOS): 修复月历视图日期显示错误
docs: 更新 CHANGELOG
```

---

## 📂 模块文档

编辑某模块的 Models / Repository / Service 文件时，先读取对应模块 CLAUDE.md：

| 模块 | CLAUDE.md 路径 |
|------|---------------|
| AI 对话 | `Holo/Holo APP/Holo/Holo/Views/Chat/CLAUDE.md` |
| 财务 | `Holo/Holo APP/Holo/Holo/Views/Finance/CLAUDE.md` |
| 待办 | `Holo/Holo APP/Holo/Holo/Views/Tasks/CLAUDE.md` |
| 习惯 | `Holo/Holo APP/Holo/Holo/Views/Habits/CLAUDE.md` |
| 健康 | `Holo/Holo APP/Holo/Holo/Views/Health/CLAUDE.md` |
| 观点 | `Holo/Holo APP/Holo/Holo/Views/Thoughts/CLAUDE.md` |
| 记忆画廊 | `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/CLAUDE.md` |

---

## 🚫 禁止操作

| 操作 | 原因 |
|------|------|
| 删除 `Assets.xcassets/` 文件 | 图标资源不可逆 |
| 修改 Xcode 项目配置 | 签名和 Bundle ID 关键 |
| Force push 到 main | 破坏提交历史 |
| 删除整个目录 | 不可逆操作 |

---

## ✅ 提交前检查

- [ ] 编译通过无警告
- [ ] 无 `print()` 和 force unwrap
- [ ] `CHANGELOG.md` 已更新

---

## 📤 提交流程

**当用户说"提交 Commit"时**：

1. `git add` + `git commit`
2. 更新 `CHANGELOG.md`
3. `git push`

---

## 🐛 Core Data 调试

| 问题 | 解决方案 |
|------|----------|
| 多个视图监听同一通知 | 都需添加防护检查 |
| ForEach 子视图在列表更新时 | 仍可能活跃，需处理 |
| 访问已删除对象的任何属性 | 导致 EXC_BREAKPOINT |
| 安全访问已删除对象 | 用本地缓存 ID 完全避免 |

> 详见 `docs/_common/notes/coredata-debugging.md`
