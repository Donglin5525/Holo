# HoloAI 卡片双向删除功能实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 HoloAI 聊天卡片的双向删除——从聊天删除卡片同步删除底层实体，从业务模块删除实体后卡片实时显示「已删除」状态。

**Architecture:** 渲染时检查实体存在性判定删除状态（零额外状态），CoreData `ObjectsDidChange` 通知驱动卡片刷新，长按上下文菜单 + 确认弹窗触发删除。

**Tech Stack:** SwiftUI, Core Data (NSManagedObject, fetchRequest, notifications), MVVM

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Models/ChatMessageViewData.swift` | Modify | 新增 `isEntityDeleted(for:)` + `entityExists(_:category:)` |
| `Views/Chat/Cards/ChatCardView.swift` | Modify | 新增 `isDeleted` 参数 + 已删除 UI overlay |
| `Views/Chat/Cards/TransactionChatCard.swift` | Modify | 传递 `isDeleted`，Text 加 `.strikethrough()` |
| `Views/Chat/Cards/TaskChatCard.swift` | Modify | 传递 `isDeleted`，Text 加 `.strikethrough()` |
| `Views/Chat/MessageBubbleView.swift` | Modify | 扩展 contextMenu + `onCardDelete` 回调 + 传递 `isDeleted` |
| `Views/Chat/ChatView.swift` | Modify | 确认弹窗 `@State` + 删除执行逻辑 + `confirmationDialog` |
| `Views/Chat/ChatViewModel.swift` | Modify | CoreData 通知监听 + 实体变更响应 |

**所有路径前缀：** `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/`

---

### Task 1: ChatMessageViewData — 实体删除状态判定

**Files:**
- Modify: `Models/ChatMessageViewData.swift`

- [ ] **Step 1: 添加 CoreData import**

在文件顶部第 9 行 `import Foundation` 后新增一行：

```swift
import CoreData
```

- [ ] **Step 2: 添加 isEntityDeleted 和 entityExists 方法**

在 `ChatMessageViewData` 结构体中，`hasLinkedEntity(for:)` 方法（第 246-248 行）之后、`// MARK: - DTO` 之前，插入以下代码：

```swift
// MARK: - Entity Deletion State

/// 检查关联实体是否已被删除
/// - Transaction: 硬删除（context.delete → 不存在即为已删除）
/// - TodoTask: 软删除（deletedFlag == true 即为已删除）
nonisolated func isEntityDeleted(for category: EntityCategory) -> Bool {
    guard let entityId = resolveLinkedEntityId(for: category) else { return false }
    return !Self.entityExists(entityId, category: category)
}

/// 检查指定实体是否存在（且未被软删除）
nonisolated private static func entityExists(_ id: UUID, category: EntityCategory) -> Bool {
    let context = CoreDataStack.shared.viewContext
    switch category {
    case .finance:
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.count(for: request)) ?? 0 > 0
    case .task:
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedFlag == NO", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.count(for: request)) ?? 0 > 0
    default:
        return true
    }
}
```

- [ ] **Step 3: 编译验证**

```bash
xcodebuild -project /Users/tangyuxuan/Desktop/Claude/HOLO/Holo.xcodeproj -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git -C /Users/tangyuxuan/Desktop/Claude/HOLO add "Holo/Holo APP/Holo/Holo/Models/ChatMessageViewData.swift"
git -C /Users/tangyuxuan/Desktop/Claude/HOLO commit -m "feat(iOS): ChatMessageViewData 新增 isEntityDeleted 实体删除状态判定"
```

---

### Task 2: ChatCardView — 已删除卡片 UI

**Files:**
- Modify: `Views/Chat/Cards/ChatCardView.swift`

- [ ] **Step 1: 添加 isDeleted 属性和修改 init**

将 `ChatCardView` 结构体（第 13-41 行）替换为：

```swift
struct ChatCardView<Content: View>: View {

    let content: Content
    var onTap: (() -> Void)?
    let isDeleted: Bool

    init(isDeleted: Bool = false, onTap: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.isDeleted = isDeleted
        self.onTap = onTap
        self.content = content()
    }

    var body: some View {
        Button {
            if !isDeleted { onTap?() }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoBorder, lineWidth: 1)
            )
            .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
            .opacity(isDeleted ? 0.5 : 1.0)
            .saturation(isDeleted ? 0 : 1)
            .overlay(alignment: .bottomTrailing) {
                if isDeleted {
                    Text("已删除")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoError)
                        .padding(.horizontal, HoloSpacing.xs)
                        .padding(.vertical, 2)
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .disabled(isDeleted)
    }
}
```

关键变更：
- 新增 `let isDeleted: Bool` 属性
- init 增加 `isDeleted: Bool = false` 参数（放在首位，避免与其他默认参数冲突）
- onTap 内增加 `!isDeleted` 守卫
- label 上叠加 `.opacity(0.5)` + `.saturation(0)` + 红色「已删除」标签
- 末尾 `.disabled(isDeleted)` 禁用按钮交互

- [ ] **Step 2: 编译验证**

```bash
xcodebuild -project /Users/tangyuxuan/Desktop/Claude/HOLO/Holo.xcodeproj -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git -C /Users/tangyuxuan/Desktop/Claude/HOLO add "Holo/Holo APP/Holo/Holo/Views/Chat/Cards/ChatCardView.swift"
git -C /Users/tangyuxuan/Desktop/Claude/HOLO commit -m "feat(iOS): ChatCardView 新增 isDeleted 已删除状态 UI"
```

---

### Task 3: TransactionChatCard + TaskChatCard — isDeleted 传递

**Files:**
- Modify: `Views/Chat/Cards/TransactionChatCard.swift`
- Modify: `Views/Chat/Cards/TaskChatCard.swift`

- [ ] **Step 1: 修改 TransactionChatCard**

将整个 `TransactionChatCard` 结构体（第 10-62 行）替换为：

```swift
struct TransactionChatCard: View {

    let data: TransactionCardData
    var isDeleted: Bool = false
    var onTap: (() -> Void)?

    var body: some View {
        ChatCardView(isDeleted: isDeleted, onTap: onTap) {
            // 头部：分类图标 + 标题
            CardHeaderView(
                icon: data.categoryIcon,
                title: data.displayTitle
            )

            // 分隔线
            CardDivider()

            // 金额
            Text(formattedAmount)
                .font(.holoHeading)
                .foregroundColor(data.isExpense ? .holoError : .holoSuccess)
                .strikethrough(isDeleted)

            // 分类路径
            if let path = data.categoryPath {
                Text(path)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
                    .strikethrough(isDeleted)
            }

            // 底部：时间 + 操作入口
            CardFooterView(timeText: formattedDate)
        }
        .accessibilityLabel("记账卡片：\(data.displayTitle)，\(data.isExpense ? "支出" : "收入")\(data.amount)元")
    }

    // MARK: - Formatting

    /// 格式化金额（支出加负号，收入加正号）
    private var formattedAmount: String {
        if data.isExpense {
            return "-¥\(data.amount)"
        }
        return "+¥\(data.amount)"
    }

    /// 格式化日期显示
    private var formattedDate: String {
        if let dateStr = data.date, !dateStr.isEmpty {
            return dateStr
        }
        return "刚刚"
    }
}
```

关键变更：
- 新增 `var isDeleted: Bool = false` 属性
- 传递 `isDeleted` 给 `ChatCardView`
- 金额和分类路径 Text 添加 `.strikethrough(isDeleted)`

- [ ] **Step 2: 修改 TaskChatCard**

将整个 `TaskChatCard` 结构体（第 10-40 行）替换为：

```swift
struct TaskChatCard: View {

    let data: TaskCardData
    var isDeleted: Bool = false
    var onTap: (() -> Void)?

    var body: some View {
        ChatCardView(isDeleted: isDeleted, onTap: onTap) {
            // 头部：图标 + 标题
            CardHeaderView(
                icon: "checkmark.circle",
                title: data.title
            )
            .strikethrough(isDeleted)

            // 分隔线
            CardDivider()

            // 底部：时间 + 操作入口
            CardFooterView(timeText: formattedDueDate)
        }
        .accessibilityLabel("任务卡片：\(data.title)")
    }

    // MARK: - Formatting

    private var formattedDueDate: String {
        if let dueDate = data.dueDate, !dueDate.isEmpty {
            return dueDate
        }
        return "今天"
    }
}
```

关键变更：
- 新增 `var isDeleted: Bool = false` 属性
- 传递 `isDeleted` 给 `ChatCardView`
- 标题 `CardHeaderView` 上添加 `.strikethrough(isDeleted)`

> 注意：`CardHeaderView` 是 View，不是 Text。`.strikethrough()` 是 `Text` 的 modifier。
> 替代方案：在 ChatCardView 层面用一个横线 overlay 实现删除线效果。
> 如果编译报错，改用以下 overlay 方案：
> ```swift
> // 在 ChatCardView body 的 label 内，VStack 闭包末尾添加：
> .overlay {
>     if isDeleted {
>         Rectangle()
>             .fill(Color.holoTextSecondary.opacity(0.4))
>             .frame(height: 1)
>     }
> }
> ```
> 此时 TransactionChatCard 和 TaskChatCard 中去掉 `.strikethrough(isDeleted)` 调用。

- [ ] **Step 3: 编译验证**

```bash
xcodebuild -project /Users/tangyuxuan/Desktop/Claude/HOLO/Holo.xcodeproj -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git -C /Users/tangyuxuan/Desktop/Claude/HOLO add "Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TransactionChatCard.swift" "Holo/Holo APP/Holo/Holo/Views/Chat/Cards/TaskChatCard.swift"
git -C /Users/tangyuxuan/Desktop/Claude/HOLO commit -m "feat(iOS): 交易/任务卡片传递 isDeleted 参数并添加删除线"
```

---

### Task 4: MessageBubbleView — 上下文菜单扩展 + isDeleted 传递

**Files:**
- Modify: `Views/Chat/MessageBubbleView.swift`

- [ ] **Step 1: 添加 onCardDelete 回调**

在第 19 行 `var onRetry: (() -> Void)? = nil` 之后新增：

```swift
var onCardDelete: ((ChatMessageViewData, EntityCategory, String) -> Void)? = nil
```

三个参数：message（消息数据）、category（实体类别）、description（删除确认弹窗的描述文字）。

- [ ] **Step 2: 添加 firstDeletableCard 计算属性**

在 `body` 计算属性之后（约第 127 行之后），`// MARK: - Avatars` 之前，新增：

```swift
/// 获取第一个可删除的卡片信息（用于上下文菜单）
private var firstDeletableCard: (category: EntityCategory, description: String)? {
    let allCards = executionCards.isEmpty ? (cardData.map { [$0] } ?? []) : executionCards

    for card in allCards {
        switch card {
        case .transaction(let data):
            if message.hasLinkedEntity(for: .finance) && !message.isEntityDeleted(for: .finance) {
                let desc = "\(data.displayTitle) ¥\(data.amount)"
                return (.finance, desc)
            }
        case .task(let data):
            if message.hasLinkedEntity(for: .task) && !message.isEntityDeleted(for: .task) {
                return (.task, "任务「\(data.title)」")
            }
        default:
            break
        }
    }
    return nil
}
```

- [ ] **Step 3: 扩展 contextMenu**

将第 118-127 行的 `.contextMenu` 替换为：

```swift
.contextMenu {
    // 删除记录（仅有关联实体且未删除的卡片消息）
    if !isUser, let info = firstDeletableCard {
        Button(role: .destructive) {
            onCardDelete?(message, info.category, info.description)
        } label: {
            Label("删除记录", systemImage: "trash")
        }
    }
    // 查看日志（保持原有）
    if !isUser, message.metadataState == .loaded, message.rawLog != nil {
        Button {
            onViewLog?(message)
        } label: {
            Label("查看日志", systemImage: "doc.text.magnifyingglass")
        }
    }
}
```

- [ ] **Step 4: 在 cardView(for:) 中传递 isDeleted**

将 `cardView(for:)` 方法（第 241-275 行）中 `.transaction` 和 `.task` 的 case 替换为：

```swift
case .transaction(let txData):
    TransactionChatCard(data: txData, isDeleted: message.isEntityDeleted(for: .finance)) {
        onCardTap?(message, data)
    }
case .task(let taskData):
    TaskChatCard(data: taskData, isDeleted: message.isEntityDeleted(for: .task)) {
        onCardTap?(message, data)
    }
```

其余 case（habitCheckIn、mood、weight、analysis 等）保持不变。

- [ ] **Step 5: 编译验证**

```bash
xcodebuild -project /Users/tangyuxuan/Desktop/Claude/HOLO/Holo.xcodeproj -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git -C /Users/tangyuxuan/Desktop/Claude/HOLO add "Holo/Holo APP/Holo/Holo/Views/Chat/MessageBubbleView.swift"
git -C /Users/tangyuxuan/Desktop/Claude/HOLO commit -m "feat(iOS): MessageBubbleView 扩展上下文菜单，支持卡片删除和 isDeleted 传递"
```

---

### Task 5: ChatView — 确认弹窗 + 删除执行

**Files:**
- Modify: `Views/Chat/ChatView.swift`

- [ ] **Step 1: 添加删除状态类型和 @State 属性**

在 `ChatView` 结构体的 `@State` 属性区（第 18 行之后）新增：

```swift
@State private var pendingDelete: PendingCardDelete?
@State private var showDeleteConfirmation = false
```

在文件末尾 `ChatSheet` enum 之后（第 381 行之后）新增：

```swift
/// 待删除卡片的信息（用于确认弹窗）
private struct PendingCardDelete {
    let category: EntityCategory
    let entityId: UUID
    let description: String
}
```

- [ ] **Step 2: 传递 onCardDelete 回调**

在 `messageList` 中的 `MessageBubbleView` 构造（第 182-202 行），在 `onRetry` 闭包之后新增：

```swift
onCardDelete: { message, category, description in
    guard let entityId = message.resolveLinkedEntityId(for: category) else { return }
    pendingDelete = PendingCardDelete(
        category: category,
        entityId: entityId,
        description: description
    )
    showDeleteConfirmation = true
}
```

- [ ] **Step 3: 添加 confirmationDialog 和删除执行方法**

在 `ChatView` 的 `body` 中，`.fullScreenCover(item: $viewingLogMessage)` 修饰符之后，添加：

```swift
.confirmationDialog(
    "删除确认",
    isPresented: $showDeleteConfirmation,
    titleVisibility: .visible
) {
    Button("删除", role: .destructive) {
        executePendingDelete()
    }
    Button("取消", role: .cancel) {
        pendingDelete = nil
    }
} message: {
    if let pending = pendingDelete {
        Text("确定删除\(pending.description)吗？此操作不可撤销。")
    }
}
```

在 `ChatView` 中 `handleCardTap` 方法之后新增：

```swift
// MARK: - Card Delete

private func executePendingDelete() {
    guard let pending = pendingDelete else { return }
    let category = pending.category
    let entityId = pending.entityId
    pendingDelete = nil

    switch category {
    case .finance:
        if let transaction = FinanceRepository.shared.findTransaction(by: entityId) {
            Task {
                try? await FinanceRepository.shared.deleteTransaction(transaction)
            }
        }
    case .task:
        if let task = TodoRepository.shared.findTask(by: entityId) {
            try? TodoRepository.shared.deleteTask(task)
        }
    default:
        break
    }
}
```

- [ ] **Step 4: 编译验证**

```bash
xcodebuild -project /Users/tangyuxuan/Desktop/Claude/HOLO/Holo.xcodeproj -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git -C /Users/tangyuxuan/Desktop/Claude/HOLO add "Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift"
git -C /Users/tangyuxuan/Desktop/Claude/HOLO commit -m "feat(iOS): ChatView 添加卡片删除确认弹窗和执行逻辑"
```

---

### Task 6: ChatViewModel — CoreData 通知监听

**Files:**
- Modify: `Views/Chat/ChatViewModel.swift`

- [ ] **Step 1: 添加 CoreData import**

在文件顶部第 11 行 `import os.log` 之后新增：

```swift
import CoreData
```

- [ ] **Step 2: 添加 coreDataObserver 属性**

在 `ChatViewModel` 的 private 属性区（第 44 行 `private let usesInjectedProvider: Bool` 之后）新增：

```swift
private var coreDataObserver: NSObjectProtocol?
```

- [ ] **Step 3: 在 bindRepository 后启动监听**

在 `bindRepository(_:)` 方法（第 160-177 行）末尾的 `}` 之前新增：

```swift
startObservingCoreDataChanges()
```

- [ ] **Step 4: 添加 deinit**

在 `init` 方法（第 50-58 行）之前新增：

```swift
deinit {
    stopObservingCoreDataChanges()
}
```

- [ ] **Step 5: 添加通知监听和响应方法**

在 `// MARK: - Helpers` 之前（约第 404 行之前）新增：

```swift
// MARK: - Core Data Change Observation

/// 监听 CoreData 实体变更（删除/软删除），刷新受影响的卡片
private func startObservingCoreDataChanges() {
    guard coreDataObserver == nil else { return }
    let context = CoreDataStack.shared.viewContext

    coreDataObserver = NotificationCenter.default.addObserver(
        forName: NSNotification.Name.NSManagedObjectContextObjectsDidChange,
        object: context,
        queue: .main
    ) { [weak self] notification in
        self?.handleCoreDataChange(notification)
    }
}

private func stopObservingCoreDataChanges() {
    if let observer = coreDataObserver {
        NotificationCenter.default.removeObserver(observer)
        coreDataObserver = nil
    }
}

private func handleCoreDataChange(_ notification: Notification) {
    guard let userInfo = notification.userInfo else { return }

    var affectedIds: Set<UUID> = []

    // 硬删除：Transaction、TodoTask 永久删除
    if let deleted = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> {
        for object in deleted {
            if let transaction = object as? Transaction {
                affectedIds.insert(transaction.id)
            }
            if let task = object as? TodoTask {
                affectedIds.insert(task.id)
            }
        }
    }

    // 软删除/更新：TodoTask deletedFlag 变更、restore
    if let updated = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> {
        for object in updated {
            if let task = object as? TodoTask {
                affectedIds.insert(task.id)
            }
        }
    }

    guard !affectedIds.isEmpty else { return }

    // 检查已加载的消息中是否有匹配的关联实体
    let hasAffectedMessages = messages.contains { message in
        for category in [EntityCategory.finance, .task] {
            if let entityId = message.resolveLinkedEntityId(for: category),
               affectedIds.contains(entityId) {
                return true
            }
        }
        return false
    }

    if hasAffectedMessages {
        objectWillChange.send()
    }
}
```

核心逻辑：
1. 监听 `NSManagedObjectContextObjectsDidChange` 通知
2. 从 `NSDeletedObjectsKey` 提取硬删除的 Transaction/TodoTask 的 ID
3. 从 `NSUpdatedObjectsKey` 提取更新的 TodoTask 的 ID（覆盖软删除 + 恢复）
4. 与已加载消息的 `linkedEntityId` 比对
5. 匹配则调用 `objectWillChange.send()` 触发 SwiftUI 重新渲染
6. 重新渲染时 `isEntityDeleted(for:)` 在渲染层自动返回正确结果

- [ ] **Step 6: 编译验证**

```bash
xcodebuild -project /Users/tangyuxuan/Desktop/Claude/HOLO/Holo.xcodeproj -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git -C /Users/tangyuxuan/Desktop/Claude/HOLO add "Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift"
git -C /Users/tangyuxuan/Desktop/Claude/HOLO commit -m "feat(iOS): ChatViewModel 监听 CoreData 变更通知，自动刷新已删除卡片"
```

---

### Task 7: 编译验证 + 集成测试

- [ ] **Step 1: 全量编译**

```bash
xcodebuild -project /Users/tangyuxuan/Desktop/Claude/HOLO/Holo.xcodeproj -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 2: 手动验证清单**

| 场景 | 操作 | 预期结果 |
|------|------|---------|
| 正向：聊天删除交易 | 长按交易卡片 → 删除记录 → 确认 | 卡片灰显+删除线+已删除标签，交易模块确认已删除 |
| 正向：聊天删除任务 | 长按任务卡片 → 删除记录 → 确认 | 卡片灰显+删除线+已删除标签，任务模块确认已删除 |
| 反向：模块删除交易 | 在财务模块删除一笔交易 | 回到聊天，对应卡片显示已删除 |
| 反向：模块删除任务 | 在待办模块删除一个任务 | 回到聊天，对应卡片显示已删除 |
| 已删除卡片不响应点击 | 点击已删除的卡片 | 无跳转 |
| 已删除卡片长按菜单 | 长按已删除的卡片 | 仅显示「查看日志」，不显示「删除记录」 |
| 确认弹窗取消 | 长按卡片 → 删除记录 → 取消 | 不执行删除，卡片状态不变 |
| 普通气泡不受影响 | 长按非卡片消息 | 仅显示「查看日志」，行为不变 |
