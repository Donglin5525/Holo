# Holo iCloud CloudKit Sync Final Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 使用 Apple 原生 `NSPersistentCloudKitContainer` 为 Holo 开启 iCloud 私有数据库同步，并在真机/TestFlight 上验证跨设备数据同步闭环。

**Architecture:** 定稿方案放弃第一版手写 `CloudKitSyncService + SyncMetadata + per-entity adapter` 路线，改用 Core Data with CloudKit 的系统级 mirroring。实施顺序必须先通过 CloudKit 模型兼容性预检，再配置 entitlements 和 persistent store options，最后增加轻量 iCloud 状态 UI；不实现手动同步队列、业务级冲突 UI 或模块级同步开关。

**Tech Stack:** SwiftUI、Core Data programmatic model、`NSPersistentCloudKitContainer`、CloudKit private database、Xcode Signing & Capabilities、xcodebuild、真机/TestFlight 验证。

---

## 定稿结论

采用 GLM 审查报告建议的方向：**不要手写 CloudKit 同步层，改用 `NSPersistentCloudKitContainer`。**

但本轮二次审查修正一个关键点：这不是“只改 1 行就完事”。Apple 官方文档明确说明 Core Data with CloudKit 不支持 unique constraints、undefined attributes、required relationships；Holo 当前 programmatic Core Data model 里存在多处非可选关系和大量非可选属性，因此必须先做模型兼容性门禁。

最终路线：

1. 先做 CloudKit 兼容性预检。
2. 修正必要的 Core Data model 兼容性问题。
3. 配置 iCloud entitlements。
4. 将 `NSPersistentContainer` 切换为 `NSPersistentCloudKitContainer`。
5. 加 iCloud 账号状态和同步事件展示。
6. 用两台真机/TestFlight 验证目标、任务、习惯、财务等核心数据是否同步。

## 审查输入

- 原方案：`/Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-05-17-Holo-iCloud-CloudKit同步实施方案.md`
- GLM 审查报告：`/Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-05-17-iCloud同步方案-工程审查报告.md`
- Holo Core Data 入口：`/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift`
- Holo Debug entitlements：`/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Holo.entitlements`
- Holo Release entitlements：`/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/HoloRelease.entitlements`
- 设置页入口：`/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Settings/SettingsView.swift`

## 官方依据

- Apple `NSPersistentCloudKitContainer` 文档：`NSPersistentCloudKitContainer` 是 `NSPersistentContainer` 的子类，用来把 Core Data store 镜像到 CloudKit。
- Apple “Mirroring a Core Data store with CloudKit”：CloudKit mirroring 不支持 unique constraints、undefined attributes、required relationships。
- Apple “Creating a Core Data Model for CloudKit”：所有 relationships 必须 optional；unique constraints 不支持。
- Apple TN3163：同步对 App 透明，App 仍通过 Core Data API 读写本地 store，系统在合适时机导出本地变更并导入远端变更。
- Apple schema initialization options：`.dryRun` 可用于验证模型并生成 schema，而不上传到 CloudKit。

## 对 GLM 审查意见的采纳与修正

| GLM 观点 | 定稿处理 | 理由 |
|---|---|---|
| 手写同步层过重 | 采纳 | 原方案 8 个新文件 + metadata 队列会重复实现 Apple 已提供的离线、增量、冲突和重试机制 |
| 使用 `NSPersistentCloudKitContainer` | 采纳 | Holo 已使用 Core Data，且现有 `CoreDataStack` 已开启 history tracking 和 remote change notification |
| 同步所有实体无风险 | 部分修正 | 私有库方向正确，但模型必须先满足 CloudKit mirroring 限制 |
| Container ID 使用 `iCloud.com.tangyuxuan.Holo` | 采纳 | 与主 Bundle ID `com.tangyuxuan.Holo` 一致 |
| 手动同步按钮不能真正强制同步 | 采纳 | UI 只做账号状态、同步事件和“重新检查状态”，不承诺立即同步 |
| `refreshAllObjects()` 不在本次修复 | 部分修正 | 不作为主线任务，但在兼容性/性能风险中记录；若执行中发现同步后 UI 异常，再单独处理 |
| `fatalError` 不在本次修复 | 部分修正 | 不做完整错误恢复，但计划里要求先用 dry-run/schema 预检降低配置错误导致启动崩溃的概率 |

## 关键架构决策

### ADR 1: 使用 Core Data with CloudKit 原生镜像

**Decision:** `CoreDataStack.buildContainer()` 使用 `NSPersistentCloudKitContainer`。

**Rationale:** Holo 已经是 Core Data 本地持久层；原生容器可以复用现有 Repository、fetch、save 路径，并由系统处理离线队列、远端变更导入、持久历史和基础冲突策略。

**Trade-off:** 对每个实体的同步粒度控制较弱，v1 不做“只同步 Goal”。如果后续确实需要选择性同步，应拆分多个 persistent store，而不是回到手写同步层。

### ADR 2: 使用单一私有 CloudKit store

**Decision:** v1 将当前 `HoloDataModel.sqlite` store 配置为 CloudKit-backed store。

**Rationale:** 用户最期待的是“换设备后 Holo 数据都在”，而不是只同步某一个模块。私有数据库的数据归用户 iCloud 所有，隐私边界清晰。

**Trade-off:** 首次同步会上传所有 Core Data 实体，必须做真机 E2E 验证和 CloudKit Dashboard schema 检查。

### ADR 3: CloudKit 兼容性预检是硬门禁

**Decision:** 不允许直接切容器后盲目构建。必须先用 Apple 模型规则和 `initializeCloudKitSchema(options: [.dryRun, .printSchema])` 验证。

**Rationale:** Holo 当前模型中至少存在这些需要关注的 CloudKit 兼容点：

- `Transaction.category` / `Transaction.account` 是非可选关系。
- `HabitRecord.habit` 是非可选关系。
- `CheckItem.task` 是非可选关系。
- `TaskAttachment.task` 是非可选关系。
- `ThoughtReference.source` / `ThoughtReference.target` 是非可选关系。
- 大量非可选 attributes 需要默认值或调整为 optional。

**Trade-off:** 会比 GLM 的 3 文件改动多一些，但可以避免后续同步在运行期直接停止或失败。

### ADR 4: 不新增业务同步 metadata

**Decision:** 不创建 `SyncMetadata`、`CloudKitSyncService`、`GoalCloudSyncAdapter`。

**Rationale:** `NSPersistentCloudKitContainer` 已经维护 persistent history、record zone、导入导出状态和重试机制。

**Trade-off:** 不能用业务字段精确控制每条记录的同步状态；v1 只展示整体 iCloud 状态和容器事件。

### ADR 5: UI 展示状态，不承诺“立即同步”

**Decision:** 设置页增加 iCloud 同步状态区，按钮文案用“重新检查状态”，避免“立即同步”。

**Rationale:** Core Data with CloudKit 的同步调度由系统决定，没有稳定公开 API 能强制同步所有变更。

**Trade-off:** 用户掌控感略弱，但文案诚实，不制造错误预期。

## 范围

### In Scope

- Debug / Release entitlements 增加 CloudKit。
- Core Data model CloudKit 兼容性预检与必要修正。
- `CoreDataStack` 切换为 `NSPersistentCloudKitContainer`。
- CloudKit container options 指向 `iCloud.com.tangyuxuan.Holo`。
- 监听 `NSPersistentCloudKitContainer.eventChangedNotification`。
- 设置页显示 iCloud 账号状态、最近同步事件、最近错误。
- Debug 构建验证。
- 两台真机或 TestFlight 跨设备验证。

### Out of Scope

- 手写 CloudKit CRUD。
- 手写 sync metadata。
- 手写冲突解决 UI。
- 模块级同步开关。
- iCloud Documents。
- iCloud Key-Value Store。
- HealthKit 逻辑改造。
- CloudKit sharing。
- 多人协作。
- Production schema 部署自动化。

## 目标文件

### 修改文件

| 文件 | 目的 |
|---|---|
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Holo.entitlements` | Debug 增加 CloudKit entitlement |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/HoloRelease.entitlements` | Release/TestFlight 增加 CloudKit entitlement |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj/project.pbxproj` | 确认 capability、framework 和 entitlements 引用 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift` | 切换容器、配置 CloudKit options、保留 history/remote change |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+*.swift` | 修正 CloudKit 不兼容的 required relationships / undefined attributes |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Settings/SettingsView.swift` | 增加 iCloud 同步状态区入口 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/CHANGELOG.md` | 记录 iCloud 同步能力 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/TODO.md` | 更新任务状态 |

### 可新增文件

| 文件 | 目的 |
|---|---|
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/ICloudSyncStatusService.swift` | 账号状态和 `NSPersistentCloudKitContainer.Event` 监听 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Settings/ICloudSyncStatusView.swift` | 如 SettingsView 过大，可抽出独立视图 |

不新增 `SyncMetadata`、`GoalCloudSyncAdapter` 或任何手写 `CKRecord` 映射。

## 构建命令

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

---

### Task 0: Baseline 与 CloudKit 兼容性预检

**Files:**
- Read: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift`
- Read: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+FinanceEntities.swift`
- Read: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+HabitEntities.swift`
- Read: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+TodoEntities.swift`
- Read: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+ThoughtEntities.swift`
- Read: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+ChatEntities.swift`
- Read: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+GoalEntities.swift`
- Read: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+MemoryInsightEntity.swift`

**Step 1: 记录当前工作区状态**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO'
git status --short
```

Expected:

```text
只记录已有脏工作区，不回滚任何用户变更。
```

**Step 2: Baseline build**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

如果 baseline 本身失败，先记录失败原因，不进入 CloudKit 切换。

**Step 3: 静态扫描 unsupported model features**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO'
rg "uniquenessConstraints|isOptional = false|deleteRule|isOrdered" 'Holo/Holo APP/Holo/Holo/Models/CoreDataStack+'*.swift
```

Expected:

```text
列出 required relationships、可能缺 defaultValue 的 required attributes、ordered relationships 和 unique constraints。
```

**Step 4: 建立 CloudKit compatibility checklist**

执行者必须形成一张检查表：

| 检查项 | 通过标准 |
|---|---|
| Unique constraints | 没有任何 entity 使用 `uniquenessConstraints` |
| Ordered relationships | 没有 ordered relationship |
| Required relationships | 所有 relationship `isOptional = true` |
| Required attributes | 非 optional attribute 必须有合理 defaultValue，或改为 optional 并同步 Swift 属性 |
| Binary data | 大字段确认可接受 CKAsset/iCloud 配额影响 |
| Delete rules | 不因 optional relationship 改动破坏业务删除行为 |

**Step 5: 不提交**

Task 0 是审查任务，不产生 commit。

---

### Task 1: 配置 iCloud Capability 与 Entitlements

**Files:**
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Holo.entitlements`
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/HoloRelease.entitlements`
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj/project.pbxproj`

**Step 1: 在 Xcode 中开启 iCloud**

操作：

```text
Target Holo -> Signing & Capabilities -> + Capability -> iCloud
```

勾选：

```text
CloudKit
```

选择或创建：

```text
iCloud.com.tangyuxuan.Holo
```

**Step 2: Debug entitlements 加入 CloudKit**

在 `Holo.entitlements` 中保留 HealthKit，加入：

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.tangyuxuan.Holo</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
```

**Step 3: Release entitlements 加入 CloudKit**

在 `HoloRelease.entitlements` 做同样修改，确保 TestFlight 包可用。

**Step 4: 检查 entitlements**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO'
/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers' 'Holo/Holo APP/Holo/Holo/Holo.entitlements'
/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services' 'Holo/Holo APP/Holo/Holo/Holo.entitlements'
/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers' 'Holo/Holo APP/Holo/Holo/HoloRelease.entitlements'
/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services' 'Holo/Holo APP/Holo/Holo/HoloRelease.entitlements'
```

Expected:

```text
iCloud.com.tangyuxuan.Holo
CloudKit
```

**Step 5: 构建验证**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 6: Commit**

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO'
git add 'Holo/Holo APP/Holo/Holo/Holo.entitlements' \
        'Holo/Holo APP/Holo/Holo/HoloRelease.entitlements' \
        'Holo/Holo APP/Holo/Holo.xcodeproj/project.pbxproj'
git commit -m "feat: enable iCloud CloudKit capability"
```

---

### Task 2: 修正 Core Data Model 的 CloudKit 兼容性

**Files:**
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+FinanceEntities.swift`
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+HabitEntities.swift`
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+TodoEntities.swift`
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+ThoughtEntities.swift`
- Modify as needed: matching `*+CoreDataProperties.swift` or class files if relationship optionality changes require Swift type changes.

**Step 1: Required relationships 改为 optional**

至少检查并处理：

```text
Transaction.category
Transaction.account
HabitRecord.habit
CheckItem.task
TaskAttachment.task
ThoughtReference.source
ThoughtReference.target
```

CloudKit mirroring 要求 relationships optional，因此这些 relationship 的 `isOptional` 必须改为 `true`。

**Step 2: 同步 Swift 属性类型**

如果当前属性声明为非可选，例如：

```swift
@NSManaged var category: Category
```

需要改为：

```swift
@NSManaged var category: Category?
```

然后修复调用方编译错误。调用方不能强行 force unwrap，应该用已有 fallback 或在 UI 层过滤不完整数据。

**Step 3: Required attributes 处理**

对每个 `isOptional = false` 的 attribute，满足二选一：

1. 设置稳定、合理的 `defaultValue`。
2. 改为 optional，并同步 Swift 属性类型和读取 fallback。

建议保守处理：

- `Bool` / `Int16` / `Int64` / `Double` / `Decimal`：优先设置 `defaultValue`。
- `String`：如果业务上必填且所有 create path 都会赋值，可设置空字符串或业务默认值。
- `Date`：优先保持 create path 显式赋值；如果 dry-run 报错，再决定 defaultValue 或 optional。
- `UUID`：优先保持 create path 显式赋值；不要依赖单个静态 `UUID()` defaultValue 生成业务 ID。

**Step 4: 重新构建**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO'
git add 'Holo/Holo APP/Holo/Holo/Models'
git commit -m "fix: make Core Data model compatible with CloudKit"
```

---

### Task 3: 切换 CoreDataStack 到 NSPersistentCloudKitContainer

**Files:**
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift`

**Step 1: 更新顶部说明**

删除旧的“iCloud 同步启用指南”待办式注释，改为当前事实：

```swift
// 使用 NSPersistentCloudKitContainer 将本地 Core Data store 镜像到用户的 iCloud 私有数据库。
// 业务层仍通过 Core Data Repository 读写本地 store；同步由系统在后台调度。
```

**Step 2: 替换容器类型**

保持公开属性类型为 `NSPersistentContainer` 也可以，因为 `NSPersistentCloudKitContainer` 是子类。

在 `buildContainer()` 中改为：

```swift
let container = NSPersistentCloudKitContainer(
    name: "HoloDataModel",
    managedObjectModel: model
)
```

**Step 3: 配置 CloudKit container options**

在 persistent store description 上设置：

```swift
description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
    containerIdentifier: "iCloud.com.tangyuxuan.Holo"
)
```

保留已有配置：

```swift
description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
container.viewContext.automaticallyMergesChangesFromParent = true
container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
```

**Step 4: 增加 Debug schema dry-run 工具入口**

不要在生产启动路径里长期调用 `initializeCloudKitSchema`。可以在 `CoreDataStack` 增加 Debug-only 方法：

```swift
#if DEBUG
func validateCloudKitSchemaDryRun() throws {
    guard let container = persistentContainer as? NSPersistentCloudKitContainer else {
        return
    }
    try container.initializeCloudKitSchema(options: [.dryRun, .printSchema])
}
#endif
```

执行时可在临时调试入口调用，验证后不要让 UI 自动触发。

**Step 5: 构建验证**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 6: Commit**

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO'
git add 'Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift'
git commit -m "feat: mirror Core Data store with CloudKit"
```

---

### Task 4: iCloud 同步状态服务

**Files:**
- Create: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/ICloudSyncStatusService.swift`

**Step 1: 新增 Services/Sync 目录**

如果目录不存在，创建：

```text
Holo/Holo APP/Holo/Holo/Services/Sync
```

**Step 2: 新增状态服务**

Create `ICloudSyncStatusService.swift`:

```swift
import Foundation
import CloudKit
import CoreData
import Combine

@MainActor
final class ICloudSyncStatusService: ObservableObject {
    static let shared = ICloudSyncStatusService()

    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastEventDescription: String = "尚未检测"
    @Published private(set) var lastErrorMessage: String?

    private let container = CKContainer(identifier: "iCloud.com.tangyuxuan.Holo")
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleCloudKitEvent(notification)
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refreshAccountStatus() async {
        do {
            accountStatus = try await container.accountStatus()
            lastErrorMessage = nil
        } catch {
            accountStatus = .couldNotDetermine
            lastErrorMessage = error.localizedDescription
        }
    }

    private func handleCloudKitEvent(_ notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else {
            return
        }

        isSyncing = event.endDate == nil
        switch event.type {
        case .setup:
            lastEventDescription = isSyncing ? "正在准备 iCloud 同步" : "iCloud 同步已准备"
        case .import:
            lastEventDescription = isSyncing ? "正在接收 iCloud 数据" : "已接收 iCloud 数据"
        case .export:
            lastEventDescription = isSyncing ? "正在上传本机数据" : "已上传本机数据"
        @unknown default:
            lastEventDescription = "iCloud 同步状态已更新"
        }

        if let error = event.error {
            lastErrorMessage = error.localizedDescription
        }
    }
}
```

**Step 3: 构建验证**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 4: Commit**

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO'
git add 'Holo/Holo APP/Holo/Holo/Services/Sync/ICloudSyncStatusService.swift'
git commit -m "feat: add iCloud sync status observer"
```

---

### Task 5: 设置页增加 iCloud 状态 UI

**Files:**
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Settings/SettingsView.swift`
- Optional Create: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/Settings/ICloudSyncStatusView.swift`

**Step 1: 注入状态服务**

在 `SettingsView` 中加入：

```swift
@StateObject private var iCloudSyncStatus = ICloudSyncStatusService.shared
```

如果 `@StateObject` + singleton 不适合当前 SwiftUI 生命周期，改用：

```swift
@ObservedObject private var iCloudSyncStatus = ICloudSyncStatusService.shared
```

**Step 2: 在设置页加入 iCloud section**

建议放在“外观”和“AI 回放”之间：

```swift
iCloudSyncSection
```

文案原则：

- 使用“iCloud 同步”。
- 显示账号状态。
- 显示最近同步事件。
- 按钮叫“重新检查状态”，不要叫“立即同步”。

**Step 3: 增加状态文案映射**

```swift
private var iCloudAccountStatusText: String {
    switch iCloudSyncStatus.accountStatus {
    case .available:
        return "已登录，系统会自动同步"
    case .noAccount:
        return "未登录 iCloud"
    case .restricted:
        return "当前账号受限"
    case .temporarilyUnavailable:
        return "iCloud 暂时不可用"
    case .couldNotDetermine:
        return "尚未检测"
    @unknown default:
        return "未知状态"
    }
}
```

**Step 4: 首次进入设置页检查状态**

在 `SettingsView` 上加：

```swift
.task {
    await iCloudSyncStatus.refreshAccountStatus()
}
```

按钮动作：

```swift
Task {
    await iCloudSyncStatus.refreshAccountStatus()
}
```

**Step 5: 构建验证**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 6: Commit**

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO'
git add 'Holo/Holo APP/Holo/Holo/Views/Settings/SettingsView.swift' \
        'Holo/Holo APP/Holo/Holo/Views/Settings/ICloudSyncStatusView.swift'
git commit -m "feat: show iCloud sync status in settings"
```

如果未创建独立 view，不要 add 不存在的文件。

---

### Task 6: 启动路径与日志验证

**Files:**
- Modify if needed: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/HoloApp.swift`
- Modify if needed: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift`

**Step 1: 确认 App 启动仍触发 CoreDataStack.prepareIfNeeded()**

检查 `HoloApp.swift` 是否已有：

```swift
CoreDataStack.shared.prepareIfNeeded()
```

如果已有，不重复添加。

**Step 2: 真机 Debug 启动检查**

在 Xcode 真机运行，观察 console：

```text
NSPersistentCloudKitContainer setup/import/export event
```

不要求每次立即出现 export/import，系统可能延迟调度。

**Step 3: 如需降低 fatalError 风险，先只补充日志**

当前 `loadPersistentStores` 失败会 `fatalError`。本次不做完整错误恢复，但如果切 CloudKit 后遇到配置错误，应优先修复 entitlement/container/model，而不是吞掉错误。

**Step 4: 构建验证**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 5: Commit**

如有改动：

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO'
git add 'Holo/Holo APP/Holo/Holo/HoloApp.swift' \
        'Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift'
git commit -m "chore: verify CloudKit startup path"
```

如果无改动，不提交。

---

### Task 7: 真机 / TestFlight E2E 验证

**Files:**
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/CHANGELOG.md`
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/TODO.md`

**Step 1: CloudKit Dashboard 检查 Development schema**

检查：

```text
Container: iCloud.com.tangyuxuan.Holo
Database: Private Database
Zone: Core Data managed zone
Record types: 由 Core Data 自动生成
```

Expected:

```text
schema 已出现，且没有明显失败日志。
```

**Step 2: 设备 A 创建数据**

在设备 A 创建或修改：

- Goal
- TodoTask
- Habit
- Finance Transaction
- Thought

等待系统同步，设置页应显示 export/import 相关事件。

**Step 3: 设备 B 拉取数据**

在设备 B 登录同一个 iCloud，安装同一构建。

Expected:

```text
设备 A 的核心数据出现在设备 B，且不重复。
```

**Step 4: 修改同步验证**

操作：

1. 设备 A 修改一条 Goal 标题。
2. 等待同步。
3. 设备 B 确认标题更新。

Expected:

```text
设备 B 看到更新后的标题。
```

**Step 5: 删除同步验证**

操作：

1. 设备 A 删除一条非关键测试数据。
2. 等待同步。
3. 设备 B 确认列表中消失或符合本地软删除规则。

Expected:

```text
删除行为符合当前业务 Repository 规则。
```

**Step 6: 离线恢复验证**

操作：

1. 设备 A 断网。
2. 修改测试 Goal。
3. 恢复网络。
4. 等待系统同步。
5. 设备 B 确认变更到达。

Expected:

```text
恢复网络后系统自动同步。
```

**Step 7: 更新文档**

`CHANGELOG.md`：

```markdown
- 新增 iCloud CloudKit 私有数据库同步，使用 Core Data with CloudKit 在用户设备间自动同步本地数据。
```

`TODO.md`：

```markdown
- [x] iCloud CloudKit 同步基础能力
- [x] Core Data with CloudKit 真机同步验证
```

**Step 8: Commit**

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO'
git add CHANGELOG.md TODO.md
git commit -m "docs: record iCloud CloudKit sync verification"
```

---

## 验收标准

必须同时满足：

- Debug 和 Release entitlements 都包含 `iCloud.com.tangyuxuan.Holo` 和 `CloudKit`。
- `CoreDataStack` 使用 `NSPersistentCloudKitContainer`。
- `description.cloudKitContainerOptions` 指向 `iCloud.com.tangyuxuan.Holo`。
- `NSPersistentHistoryTrackingKey` 保持开启。
- `NSPersistentStoreRemoteChangeNotificationPostOptionKey` 保持开启。
- `viewContext.automaticallyMergesChangesFromParent = true` 保持开启。
- Debug build 通过。
- 真机 A -> 真机 B 新增、修改、删除至少各验证一次。
- 设置页能显示 iCloud 账号状态。
- 没有新增手写 `CKRecord` adapter、`SyncMetadata` 或业务同步队列。

## 回滚方案

如果 CloudKit 同步在真机上出现不可接受问题：

1. 移除 `description.cloudKitContainerOptions`。
2. 将 `NSPersistentCloudKitContainer` 改回 `NSPersistentContainer`。
3. 保留 entitlements 不会影响本地存储，但可在后续 PR 清理。
4. 不删除用户本地 sqlite。
5. 不重置 CloudKit Production schema。

如果 Development schema 污染：

1. 只在 CloudKit Dashboard Development 环境重置。
2. 不触碰 Production。
3. 重新运行真机 Debug 构建生成 schema。

## 后续版本建议

v1 完成后再考虑：

- 同步事件历史页面。
- iCloud 配额提醒。
- 首次同步说明。
- 更细的冲突解释。
- 将附件图片继续保存在文件系统，仅同步 metadata。
- 多 store 拆分：本地-only store + CloudKit-backed store。
- 将 `refreshAllObjects()` 技术债单独清理。

## 执行建议

执行优先级：

1. Task 0 必须先做，不能跳过。
2. Task 2 如果发现模型兼容性改动过大，先暂停并回报，不要硬切 CloudKit。
3. Task 3 后必须立即构建。
4. Task 7 必须用真机或 TestFlight 验证，模拟器不能作为最终验收依据。

Plan complete and saved to `docs/_common/plans/2026-05-17-Holo-iCloud-CloudKit同步实施方案-定稿.md`.
