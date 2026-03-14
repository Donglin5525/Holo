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
- [ ] 习惯模块

## 优化项

- [ ] App 性能优化
- [ ] 深色模式适配
- [ ] iPad 适配
