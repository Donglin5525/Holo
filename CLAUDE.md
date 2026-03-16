# HOLO - 记账 + 习惯追踪 iOS 应用

## 项目概述

| 部分 | 技术栈 | 位置 |
|------|--------|------|
| iOS App | SwiftUI, Swift 5+, MVVM | `/Holo/` |
| Web 前端 | React 19, Vite, TypeScript | `/src/` |

核心功能：记账管理（月历/周视图）、习惯追踪（打卡+数据持久化）、图标系统（62+ 图标）

---

## 项目结构

```
HOLO/
├── Holo/
│   ├── Assets.xcassets/
│   │   ├── AppIcon.appiconset/   # App 图标，必须维护
│   │   ├── CategoryIcons/        # 分类图标（62 个）
│   │   └── AccentColor.colorset/
│   ├── Components/               # 可复用组件
│   ├── Views/                    # SwiftUI 视图
│   ├── Utils/                    # 工具函数
│   ├── HoloApp.swift             # 应用入口
│   └── ContentView.swift
├── icon/
│   ├── integrate_icons.py        # 图标集成脚本
│   └── extract_icons.py
├── src/                          # Web 前端
├── docs/                         # CHANGELOG 等
└── Holo.xcodeproj/
```

---

## 编码约定

### iOS (Swift)
- 架构：MVVM
- 禁止 force unwrap `!`（除非绝对安全）
- 禁止 `print()`，使用 `Logger`
- 错误处理用 `try-catch`，不得静默吞掉

### Web (TypeScript)
- 用 `unknown` 代替 `any`
- 禁止 `console.log`
- 不可变更新（展开运算符，不直接 mutate）

---

## 图标管理

### 分类图标
- **位置：** `Holo/Assets.xcassets/CategoryIcons/`（62 个，9 大分类）
- **更新：** `python3 icon/integrate_icons.py`
- **分类：** 收入（投资理财/工资兼职）、支出（医疗/交通/食物饮料/购物娱乐/日常/其他）、转账/通用

### App 图标
- **位置：** `Holo/Assets.xcassets/AppIcon.appiconset/`
- **要求：** 提供 1024×1024 PNG，支持 light/dark/tinted，Xcode 自动生成其他尺寸

---

## 提交规范

Scope 可选值：`iOS` / `Web` / `icon` / `docs`

```
feat(iOS): 新增交易分类筛选功能
fix(iOS): 修复月历视图日期显示错误
docs: 更新 CHANGELOG
```

---

## 禁止操作

**需先咨询：**
- 删除 `Assets.xcassets/` 中的任何文件
- 修改 Xcode 项目配置（Team ID、Bundle ID、签名）
- Force push 到 main 或修改已发布的提交历史
- 删除整个目录

---

## 提交前检查

**iOS：**
- [ ] Xcode Build 编译通过，无警告
- [ ] 无 `print()` 调试语句，无 force unwrap
- [ ] 图标尺寸正确（涉及图标修改时）

**Web：**
- [ ] `npm run lint` 通过
- [ ] 无 `console.log`，无硬编码密钥

**通用：**
- [ ] `docs/CHANGELOG.md` 已更新
