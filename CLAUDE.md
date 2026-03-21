# HOLO - 个人数据资产 + AI 规划 iOS 应用

**技术栈**：SwiftUI, Swift 5+, MVVM, Core Data
**核心模块**：记账、习惯追踪、待办（开发中）

---

## 开发前必读

**开始任何开发前，必须先阅读 `docs/_common/` 下的文档：**

| 文档 | 用途 |
|------|------|
| `docs/_common/HoloPRD.md` | 产品需求文档 |
| `docs/_common/开发规范.md` | 开发规范与踩坑总结 |
| `docs/_common/notes/` | 历史问题解决方案 |
| `docs/_common/plans/` | 已完成功能的实现计划 |

---

## 快速参考

### 编码约定

| iOS (Swift) | Web (TypeScript) |
|------------|------------------|
| MVVM 架构 | 用 `unknown` 代替 `any` |
| 禁止 `!` force unwrap | 禁止 `console.log` |
| 禁止 `print()`，用 `Logger` | 不可变更新 |
| 错误处理用 `try-catch` | |

### 图标管理

- **分类图标**：`Holo/Assets.xcassets/CategoryIcons/`（62 个）
- **更新命令**：`python3 icon/integrate_icons.py`
- **App 图标**：1024×1024 PNG，Xcode 自动生成

### 提交规范

**Scope**：`iOS` / `Web` / `icon` / `docs`

```
feat(iOS): 新增分期记账功能
fix(iOS): 修复月历视图日期显示错误
docs: 更新 CHANGELOG
```

---

## 禁止操作（需先咨询）

- 删除 `Assets.xcassets/` 中的任何文件
- 修改 Xcode 项目配置（Team ID、Bundle ID、签名）
- Force push 到 main 或修改已发布的提交历史
- 删除整个目录

---

## 提交前检查

**iOS**：编译通过无警告 | 无 `print()` 和 force unwrap | 图标尺寸正确
**Web**：`npm run lint` 通过 | 无 `console.log`
**通用**：`docs/CHANGELOG.md` 已更新

---

## 提交流程

**当用户说"提交 Commit"时**，需执行三个动作：

1. 提交 Commit（git add + git commit）
2. 更新 `docs/CHANGELOG.md` 日志
3. 同步到 GitHub 仓库（git push）

---

## Core Data 调试经验

| 问题 | 解决方案 |
|------|----------|
| 多个视图监听同一通知 | 都需添加防护检查 |
| ForEach 子视图在列表更新时 | 仍可能活跃，需处理 |
| 访问已删除对象的任何属性 | 导致 EXC_BREAKPOINT |
| 安全访问已删除对象 | 用本地缓存 ID 完全避免 |

> 详细调试经验见 `docs/_common/notes/coredata-debugging.md`
