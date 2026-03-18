# Holo 全局待办清单

> 记录 App 整体开发过程中需要后续完成的重要事项

## 基础设施

- [ ] **启用 iCloud 同步** - 等 App 整体开发差不多后再做
  - 位置：`Holo/Models/CoreDataStack.swift`
  - 步骤：
    1. Xcode → Target → Signing & Capabilities → + Capability → iCloud
    2. 勾选 CloudKit，创建容器（如 `iCloud.com.yourcompany.Holo`）
    3. 将 `NSPersistentContainer` 改为 `NSPersistentCloudKitContainer`
    4. 取消 `cloudKitContainerOptions` 注释，填入容器 ID
  - 影响范围：所有 Core Data 数据（交易记录、分类、账户、首页图标配置等）

## 功能开发

- [ ] 任务模块
- [ ] 健康模块
- [ ] 观点模块
- [x] ~~习惯模块~~ — 2025-03-18 完成（打卡+统计+图标系统）

## 优化项

- [x] ~~**记账页面交互优化** — `AddTransactionSheet.swift`~~ — 2026-03-19 完成
  - [x] 点击空白区域收起键盘，点击金额区域重新弹出数字键盘
  - [x] 备注文字颜色修复（深色模式下不可见，改为 `.primary`）
  - [x] Header 右侧新增 ✓ 保存按钮（点击完成记账）
  - [x] 下拉整个页面 = 保存记账（X 按钮 = 取消不保存）
- [ ] App 性能优化
- [ ] **深色模式适配** - 适配苹果 Dark Mode，确保所有页面在深色模式下显示正常
- [ ] iPad 适配
- [ ] **记账首页卡片优化** - 「支出」和「收入」两张卡片面积过大，影响美观，需要重新设计布局
