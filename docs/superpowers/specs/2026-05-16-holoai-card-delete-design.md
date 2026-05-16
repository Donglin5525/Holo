# HoloAI 卡片删除功能设计

## 概述

为 HoloAI 聊天界面的交易卡片和任务卡片增加双向删除能力：
- 在聊天界面删除卡片 → 同步删除底层实体（交易/任务）
- 在业务模块删除实体 → 聊天卡片实时显示「已删除」状态

## 范围

**支持的卡片类型**：
- `TransactionChatCard`（交易卡片）
- `TaskChatCard`（任务卡片）

**不在本次范围**：习惯打卡、心情、体重、分析卡片。

## 核心设计原则

**零额外状态**：删除状态的唯一真相来源是实体是否存在。不在 `ChatMessage` 上新增任何字段。

## 1. 卡片删除状态判定

在 `ChatMessageViewData` 上新增方法：

```swift
func isEntityDeleted(for category: EntityCategory) -> Bool {
    guard let entityId = resolveLinkedEntityId(for: category) else { return false }
    return !entityExists(entityId, type: category.entityType)
}

private func entityExists(_ id: UUID, type: NSManagedObject.Type) -> Bool {
    let request = type.fetchRequest()
    request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
    request.fetchLimit = 1
    return (try? CoreDataStack.shared.viewContext.count(for: request)) ?? 0 > 0
}
```

`EntityCategory` 到 CoreData 实体类型的映射：
- `.finance` → `Transaction`
- `.task` → `Task`

## 2. 已删除卡片 UI

### ChatCardView 修改

`ChatCardView<Content>` 新增 `isDeleted: Bool = false` 参数。当为 `true` 时：

- 整体 `.opacity(0.5)` + `.saturation(0)`（灰度化）
- 内容叠加 `.strikethrough()` 删除线
- 底部右对齐显示红色「已删除」文字标签
- 禁用 `onTap` 回调（不跳转到编辑页面）

### 示意

```
┌─────────────────────────────┐
│ 📱 手办    ¥25.00           │  ← 灰色 + 删除线
│    日常 > 手办               │
│                   已删除     │  ← 红色小标签
└─────────────────────────────┘
```

实现方式：`ChatCardView` 内部根据 `isDeleted` 用 overlay 叠加修饰。各具体卡片视图（`TransactionChatCard`、`TaskChatCard`）传入 `isDeleted` 参数即可，内部布局不变。

## 3. 长按菜单交互

### MessageBubbleView 扩展

当前 `.contextMenu` 只有「查看日志」。扩展逻辑：

- **有关联实体的卡片消息**：
  - 「删除记录」— 红色 destructive 样式
  - 「查看日志」（保持原有）
- **无关联实体或已删除的卡片**：
  - 「查看日志」（保持原有）

### 删除流程

1. 用户长按卡片 → 弹出上下文菜单
2. 点击「删除记录」→ 弹出系统确认对话框（ConfirmationDialog）
3. 确认对话框内容示例：「确定删除这笔 ¥25.00 的手办消费记录吗？」
4. 用户确认 → 调用对应 Repository 的删除方法：
   - 交易：`FinanceRepository.shared.deleteTransaction()`
   - 任务：对应 Task 删除方法
5. CoreData 删除触发通知 → 卡片自动刷新为「已删除」状态

### 确认对话框位置

确认弹窗在 `ChatView` 层面管理，通过 `@State` 控制显隐，传入待删除的实体信息。

## 4. 反向实时同步（模块删除 → 卡片更新）

### 机制

在 `ChatViewModel` 中监听 CoreData 的 `NSManagedObjectContextObjectsDidChange` 通知。

### 处理流程

1. 收到通知，检查 `deletedObjects` 集合
2. 过滤出 `Transaction` 和 `Task` 类型的对象
3. 提取被删除对象的 `id`（UUID）
4. 遍历 `messages` 数组，找到 `linkedEntityId` 匹配的 `ChatMessageViewData`
5. 调用该消息的缓存失效方法，触发 SwiftUI 重新渲染
6. 卡片重新调用 `isEntityDeleted(for:)` → 返回 `true` → 显示已删除状态

### 关键实现细节

- 通知监听在 `ChatViewModel.init()` 或 `onAppear` 时注册，`deinit` 时移除
- 只处理当前已加载到内存的消息（不需要查询数据库找所有关联消息）
- 被删除实体的 UUID 从 Core Data 的 `NSManagedObjectID` 获取

## 5. 变更文件清单

| 文件 | 变更内容 |
|------|----------|
| `ChatMessageViewData.swift` | 新增 `isEntityDeleted(for:)` 和 `entityExists(_:type:)` |
| `ChatCardView.swift` | 新增 `isDeleted` 参数，叠加灰色/删除线/标签 overlay |
| `MessageBubbleView.swift` | 扩展 `.contextMenu`，增加「删除记录」选项 |
| `ChatView.swift` | 新增确认弹窗状态管理 + 删除执行逻辑 |
| `ChatViewModel.swift` | 监听 CoreData 删除通知，刷新受影响卡片 |
| `TransactionChatCard.swift` | 接收并传递 `isDeleted` 参数 |
| `TaskChatCard.swift` | 接收并传递 `isDeleted` 参数 |

**不变更**：
- `ChatMessage` CoreData schema — 无新字段
- `FinanceRepository` — 复用现有 `deleteTransaction()`
- `TaskRepository` — 复用现有删除方法

## 6. 测试要点

- 从聊天删除交易 → 交易模块确认已删除
- 从聊天删除任务 → 任务模块确认已删除
- 从交易模块删除 → 回到聊天，卡片显示「已删除」
- 从任务模块删除 → 回到聊天，卡片显示「已删除」
- 已删除卡片不响应点击
- 已删除卡片的长按菜单不显示「删除记录」
- 确认弹窗取消 → 不执行删除
- 批量执行消息（多张卡片）中删除单张卡片
