# HOLO - 记账 + 习惯追踪 iOS 应用

## 📱 项目概述

HOLO 是一个 **混合技术栈项目**，包含 iOS 应用和 Web 前端：

| 部分 | 技术栈 | 位置 |
|------|--------|------|
| **iOS App** | SwiftUI, Swift 5+ | `/Holo/` |
| **Web 前端** | React 19, Vite, TypeScript | `/src/` |
| **项目管理** | Git (Conventional Commits) | Root |

### 核心功能
- 📊 记账管理（月历视图、周视图、交易管理）
- ✅ 习惯追踪（习惯打卡、数据持久化、图标系统）
- 🎨 丰富的图标系统（62+ 分类图标，支持自定义 SVG）
- 📤 数据导入导出与异常处理

---

## 📂 项目结构

```
HOLO/
├── Holo/                          # iOS 应用主目录
│   ├── Assets.xcassets/          # 资源文件
│   │   ├── AppIcon.appiconset/   # App 图标（必须维护）
│   │   ├── CategoryIcons/        # 分类图标（62 个）
│   │   └── AccentColor.colorset/ # 品牌色
│   ├── Components/               # 可复用组件
│   ├── Views/                    # SwiftUI 视图
│   ├── Utils/                    # 工具函数
│   ├── HoloApp.swift             # 应用入口
│   └── ContentView.swift         # 主视图
├── icon/                         # 图标管理目录
│   ├── Finance icon/             # Figma 导出的原始图标
│   ├── svg/                      # SVG 图标
│   ├── extract_icons.py          # 图标提取脚本
│   └── integrate_icons.py        # 图标集成脚本
├── src/                          # Web 前端源代码
├── docs/                         # 文档（CHANGELOG 等）
├── Holo.xcodeproj/              # iOS Xcode 项目配置
└── package.json                  # Web 项目配置
```

---

## 🚀 开发工作流

### iOS 功能开发流程

按照 **ECC (Everything Claude Code)** 规则：

#### **0. 研究与规划**
- 使用 GitHub 搜索相关实现
- 查阅官方 Apple 文档（SwiftUI）
- 确认不重复实现已有功能

#### **1. 规划阶段**
```bash
# 复杂功能使用 planner 代理
# 生成：实现计划、架构设计、技术文档
```

#### **2. TDD 开发**
- 先编写测试用例
- 实现功能使其通过测试
- 重构代码确保质量

#### **3. 代码审查**
- 完成后立即审查
- 修正 CRITICAL 和 HIGH 级问题

#### **4. 提交代码**
- 遵循 Conventional Commits 格式
- 详细描述变更内容

---

## 📋 关键约定

### 提交信息格式

```
<type>(<scope>): <subject>

<optional body>
```

**类型 (type):** feat, fix, refactor, docs, test, chore, perf, ci

**范围 (scope):** iOS, Web, icon, docs

**示例：**
```
feat(iOS): 新增交易分类筛选功能
fix(iOS): 修复月历视图日期显示错误
docs: 更新使用说明文档
```

### 编码风格

#### iOS (Swift)
- ✅ 使用 MVVM 架构
- ✅ 遵循 Swift API 设计指南
- ✅ 函数最多 50 行，文件最多 800 行
- ✅ 完整的错误处理（try-catch）
- ❌ 不使用 force unwrap (!) 除非确定安全
- ❌ 生产代码中禁止 print()，使用 Logger

#### Web (React + TypeScript)
- ✅ 明确的类型标注（公共 API）
- ✅ 使用 `unknown` 代替 `any`
- ✅ 不可变更新（使用扩展运算符）
- ✅ 80%+ 测试覆盖率
- ❌ 禁止 console.log
- ❌ 禁止硬编码密钥（使用环境变量）

---

## 🎨 图标管理

### 分类图标（CategoryIcons）
- **位置:** `Holo/Assets.xcassets/CategoryIcons/`
- **总数:** 62 个（9 大分类）
- **管理脚本:** `icon/integrate_icons.py`
- **来源:** Figma 设计稿导出

**分类：**
- 收入 - 投资理财 / 工资兼职
- 支出 - 医疗 / 交通 / 食物饮料 / 购物娱乐 / 日常 / 其他
- 转账/通用

### App 图标（AppIcon）
- **位置:** `Holo/Assets.xcassets/AppIcon.appiconset/`
- **格式:** 支持 light/dark/tinted 模式
- **必须尺寸:** 1024×1024 (通用)，Xcode 自动生成其他尺寸
- **更新方式:**
  1. 准备 1024×1024 PNG 图标
  2. 拖入 Xcode AppIcon.appiconset
  3. Xcode 自动生成所有尺寸

---

## ✅ 提交前检查清单

### iOS 开发
- [ ] 代码编译通过（Xcode Build 成功）
- [ ] 没有 Swift 编译警告
- [ ] 图标尺寸正确（如涉及图标修改）
- [ ] 错误处理完整（没有 force unwrap）
- [ ] 没有 print() 调试语句
- [ ] 提交信息遵循格式

### Web 开发
- [ ] TypeScript 编译通过 (`npm run lint`)
- [ ] 没有 console.log
- [ ] 所有依赖已更新到 package-lock.json
- [ ] 没有硬编码密钥
- [ ] 测试覆盖率 ≥ 80%

### 两端通用
- [ ] CHANGELOG.md 已更新
- [ ] 数据库/模型变更已记录
- [ ] 不存在循环依赖
- [ ] 代码审查问题已修复

---

## 🛑 禁止操作

**以下操作需要先咨询：**
- ❌ 删除任何 Assets.xcassets 中的文件
- ❌ 修改已发布的提交历史（git rebase -i）
- ❌ Force push 到 main 分支
- ❌ 删除整个目录（除非明确要求）
- ❌ 修改 Xcode 项目配置（Team ID、Bundle ID 等）

**直接拒绝：**
- 硬编码 API 密钥或用户凭证
- SQL 注入风险代码
- XSS 漏洞（未清理 HTML）
- 绕过权限验证的代码

---

## 🧠 推荐的代理和工具

### iOS 开发
| 任务 | 代理 | 用法 |
|------|------|------|
| 复杂功能规划 | **planner** | 规划阶段 |
| 系统设计 | **architect** | 架构决策 |
| 代码审查 | **code-reviewer** | 完成后立即使用 |
| 安全检查 | **security-reviewer** | 提交前 |
| 构建错误 | **build-error-resolver** | 编译失败时 |

### Web 开发
| 任务 | 工具 | 用法 |
|------|------|------|
| TDD | **tdd-guide 代理** | 新功能必用 |
| E2E 测试 | **e2e-runner** | Playwright 测试 |
| 代码简化 | **simplify skill** | 重构后使用 |

---

## 📚 ECC 规则已安装

本项目已安装 **Everything Claude Code (v1.8.0)** 规则库：

**通用规则 (9 个文件):**
- agents.md - 代理编排
- coding-style.md - 编码标准
- development-workflow.md - 开发流程
- git-workflow.md - Git 规范
- hooks.md - 钩子系统
- patterns.md - 设计模式
- performance.md - 性能优化
- security.md - 安全指南
- testing.md - 测试要求

**TypeScript 规则 (5 个文件):**
- 编码风格、设计模式、安全、测试

详见：`~/.claude/rules/` 目录

---

## 🔧 快速命令

```bash
# iOS 开发
open Holo.xcodeproj              # 打开 Xcode
xcodebuild build                 # 命令行构建

# Web 开发
npm install                      # 安装依赖
npm run dev                      # 启动开发服务器
npm run build                    # 生产构建
npm run lint                     # 代码检查

# 图标管理
python3 icon/integrate_icons.py  # 集成分类图标

# Git
git log --oneline -10            # 查看最近提交
git diff main...HEAD             # 查看当前分支变更
```

---

## 📞 关键联系信息

- **项目负责人:** 你
- **构建工具:** Xcode 15+, Vite, Node.js
- **主分支:** main
- **开发分支:** feature/*, fix/* 前缀

---

## 🎯 目标

保持 HOLO 项目的：
1. ✨ 代码质量与一致性
2. 🔒 安全与可维护性
3. 🚀 性能与用户体验
4. 📖 清晰的文档与提交历史
