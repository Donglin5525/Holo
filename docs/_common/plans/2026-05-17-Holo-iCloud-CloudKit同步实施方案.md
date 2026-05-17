# Holo iCloud CloudKit Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 Holo 建立可扩展的 CloudKit 私有数据库同步底座，并在第一阶段只接入目标系统 `Goal` 同步。

**Architecture:** 本地 Core Data 继续作为主存储，CloudKit 作为跨设备同步层；第一版不直接切换到 `NSPersistentCloudKitContainer` 全量镜像，避免一次性影响所有模块。同步层采用 `CloudKitSyncService + per-entity adapter + SyncMetadata`，先让 `Goal` 完整跑通上传、拉取、冲突合并、删除和错误降级。

**Tech Stack:** SwiftUI、Core Data programmatic model、CloudKit private database、Repository 模式、xcodebuild、真机/TestFlight 验证。

---

## 背景与结论

用户已经加入 Apple Developer Program，可以开始使用 iCloud / CloudKit 能力。Holo 当前已经有 HealthKit entitlement，但 Debug 和 Release entitlements 尚未配置 iCloud container。

当前 Holo Core Data 不是 `.xcdatamodeld` 文件模型，而是通过代码创建 `NSManagedObjectModel`：

- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+GoalEntities.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/GoalRepository.swift`
- `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/Goal+CoreDataProperties.swift`

因此第一版不建议直接把整个持久层切换到 `NSPersistentCloudKitContainer`。更稳妥的路线是保留本地 Core Data，并新增手写 CloudKit 同步层。

## 非目标

第一阶段不做以下内容：

- 不同步财务流水、账户、预算。
- 不同步 Todo、Habit 与 Goal 的关系。
- 不迁移到 `NSPersistentCloudKitContainer`。
- 不做复杂冲突解决 UI。
- 不做 iCloud Documents 或 Key-Value Store。
- 不做后台静默自动同步的完整策略。
- 不改 HealthKit 逻辑。

## 架构决策

### ADR 1: 使用 CloudKit 私有数据库

**Decision:** 使用 `CKContainer(identifier: "iCloud.com.tangyuxuan.Holo").privateCloudDatabase`。

**Rationale:** Holo 的目标、任务、习惯、财务数据都属于用户个人隐私数据，应该只存在用户自己的 iCloud 私有数据库中。

**Trade-off:** 私有库不适合共享协作，但当前 Holo 没有多人协作需求。

### ADR 2: Core Data 继续作为本地事实源

**Decision:** 本地 Core Data 仍是 App 读写主路径，CloudKit 同步作为旁路服务。

**Rationale:** 当前业务代码大量依赖 Repository + Core Data，上来切 `NSPersistentCloudKitContainer` 会影响所有实体和迁移策略。

**Trade-off:** 手写同步层代码更多，但可控性更好，适合分模块上线。

### ADR 3: 第一阶段只同步 Goal 本体

**Decision:** 只同步 `Goal` 字段，不同步 `tasks` / `habits` 关系。

**Rationale:** Goal 字段简单、冲突规则可控，是验证 CloudKit 账号、schema、上传、拉取、删除、冲突处理的最佳 MVP。

**Trade-off:** 第一版多设备只能同步目标本体，目标关联的任务和习惯留到后续阶段。

### ADR 4: CloudKit recordName 使用本地 UUID

**Decision:** `GoalRecord` 的 `recordID.recordName` 使用 `goal.id.uuidString`。

**Rationale:** 可以保证跨设备合并稳定，避免首次同步和重装后产生重复数据。

**Trade-off:** 本地 UUID 生成后必须保持不变，后续导入功能也要遵守同一约束。

## CloudKit Schema

### Container

```text
iCloud.com.tangyuxuan.Holo
```

### Database

```text
privateCloudDatabase
```

### Record Type: GoalRecord

| CloudKit Field | Swift Type | Local Field | Required |
|---|---|---|---|
| `title` | `String` | `Goal.title` | yes |
| `summary` | `String?` | `Goal.summary` | no |
| `domain` | `String` | `Goal.domain` | yes |
| `desiredOutcome` | `String?` | `Goal.desiredOutcome` | no |
| `motivation` | `String?` | `Goal.motivation` | no |
| `status` | `String` | `Goal.status` | yes |
| `deadline` | `Date?` | `Goal.deadline` | no |
| `createdAt` | `Date` | `Goal.createdAt` | yes |
| `updatedAt` | `Date` | `Goal.updatedAt` | yes |
| `completedAt` | `Date?` | `Goal.completedAt` | no |
| `source` | `String` | `Goal.source` | yes |
| `allowAIContext` | `Int64` | `Goal.allowAIContext` | yes |
| `lastInsightSummary` | `String?` | `Goal.lastInsightSummary` | no |
| `deletedAt` | `Date?` | sync metadata | no |

`allowAIContext` 用 `Int64` 存 `0/1`，避免 CloudKit 字段类型在 Dashboard 中出现兼容歧义。

## 本地新增模型

### SyncMetadata Entity

建议以 Core Data entity 形式新增，便于跟现有持久层同库事务保存。

| Field | Type | 用途 |
|---|---|---|
| `id` | `UUID` | metadata 自身 id |
| `entityName` | `String` | 例如 `Goal` |
| `localID` | `String` | 例如 `goal.id.uuidString` |
| `recordName` | `String` | CloudKit record name |
| `lastKnownChangeTag` | `String?` | CloudKit change tag |
| `lastSyncedAt` | `Date?` | 最近成功同步时间 |
| `pendingOperation` | `String` | `none` / `upsert` / `delete` |
| `lastSyncError` | `String?` | 最近错误摘要 |
| `createdAt` | `Date` | metadata 创建时间 |
| `updatedAt` | `Date` | metadata 更新时间 |

### SyncState

第一版可以先用 `UserDefaults` 保存全局状态，后续再迁移到 Core Data：

- `holo.sync.icloud.enabled`
- `holo.sync.goal.lastFullSyncAt`
- `holo.sync.goal.serverChangeTokenData`

## 文件结构

### 新增文件

| 文件 | 职责 |
|---|---|
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/CloudKitSyncService.swift` | CloudKit 账号状态、数据库访问、同步编排 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/CloudKitSyncError.swift` | 同步错误枚举和用户可读信息 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/CloudSyncRecord.swift` | 本地实体和 `CKRecord` 映射协议 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/GoalCloudSyncAdapter.swift` | `Goal <-> CKRecord` 转换 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+SyncEntities.swift` | `SyncMetadata` programmatic Core Data entity |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/SyncMetadata+CoreDataClass.swift` | `SyncMetadata` NSManagedObject 类 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/SyncMetadata+CoreDataProperties.swift` | `SyncMetadata` 字段和便捷方法 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/SyncMetadataRepository.swift` | metadata 查询和 pending 状态管理 |

### 修改文件

| 文件 | 职责 |
|---|---|
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Holo.entitlements` | 增加 iCloud services 和 container |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/HoloRelease.entitlements` | 增加 iCloud services 和 container |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj/project.pbxproj` | 确认 iCloud capability、entitlements 引用、CloudKit framework |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift` | 注册 `SyncMetadata` entity |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/GoalRepository.swift` | Goal 创建、修改、删除后标记待同步 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/HoloApp.swift` | 启动时准备同步服务，第一版不强制自动同步 |
| `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Views/SettingsView.swift` 或现有设置入口 | 后续加入手动同步入口；若当前没有合适设置页，第一阶段可先不加 UI |

## 构建命令

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

## 真机验证前置

- Xcode Target 已开启 iCloud Capability。
- Services 勾选 CloudKit。
- Container 使用 `iCloud.com.tangyuxuan.Holo`。
- 真机登录 iCloud。
- 使用付费开发者团队签名，不使用 Personal Team。
- Debug 和 Release entitlements 都包含相同 iCloud container。

---

### Task 1: iCloud Entitlements 与项目能力配置

**Files:**
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Holo.entitlements`
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/HoloRelease.entitlements`
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj/project.pbxproj`

**Step 1: 更新 Debug entitlements**

在 `Holo.entitlements` 的 `<dict>` 中保留 HealthKit，并加入：

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

**Step 2: 更新 Release entitlements**

对 `HoloRelease.entitlements` 做同样修改，确保 TestFlight 包包含 CloudKit 权限。

**Step 3: 在 Xcode 中确认 Capability**

打开 Xcode：

```text
Target Holo -> Signing & Capabilities -> + Capability -> iCloud -> CloudKit
```

选择或创建：

```text
iCloud.com.tangyuxuan.Holo
```

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

```bash
git add 'Holo/Holo APP/Holo/Holo/Holo.entitlements' \
        'Holo/Holo APP/Holo/Holo/HoloRelease.entitlements' \
        'Holo/Holo APP/Holo/Holo.xcodeproj/project.pbxproj'
git commit -m "feat: enable iCloud CloudKit entitlement"
```

---

### Task 2: SyncMetadata Core Data Schema

**Files:**
- Create: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack+SyncEntities.swift`
- Create: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/SyncMetadata+CoreDataClass.swift`
- Create: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/SyncMetadata+CoreDataProperties.swift`
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/CoreDataStack.swift`

**Step 1: 新增 SyncMetadata class**

Create `SyncMetadata+CoreDataClass.swift`:

```swift
import Foundation
import CoreData

@objc(SyncMetadata)
public class SyncMetadata: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<SyncMetadata> {
        NSFetchRequest<SyncMetadata>(entityName: "SyncMetadata")
    }
}
```

**Step 2: 新增 SyncMetadata properties**

Create `SyncMetadata+CoreDataProperties.swift`:

```swift
import Foundation
import CoreData

extension SyncMetadata {
    @NSManaged var id: UUID
    @NSManaged var entityName: String
    @NSManaged var localID: String
    @NSManaged var recordName: String
    @NSManaged var lastKnownChangeTag: String?
    @NSManaged var lastSyncedAt: Date?
    @NSManaged var pendingOperation: String
    @NSManaged var lastSyncError: String?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date

    enum Operation: String {
        case none
        case upsert
        case delete
    }

    var operation: Operation {
        get { Operation(rawValue: pendingOperation) ?? .none }
        set {
            pendingOperation = newValue.rawValue
            updatedAt = Date()
        }
    }
}
```

**Step 3: 新增 programmatic entity builder**

Create `CoreDataStack+SyncEntities.swift`:

```swift
import Foundation
import CoreData

extension CoreDataStack {
    nonisolated func createSyncMetadataEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "SyncMetadata"
        entity.managedObjectClassName = "SyncMetadata"

        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.isOptional = optional
            return attr
        }

        let id = attribute("id", .UUIDAttributeType)
        let entityName = attribute("entityName", .stringAttributeType)
        let localID = attribute("localID", .stringAttributeType)
        let recordName = attribute("recordName", .stringAttributeType)
        let lastKnownChangeTag = attribute("lastKnownChangeTag", .stringAttributeType, optional: true)
        let lastSyncedAt = attribute("lastSyncedAt", .dateAttributeType, optional: true)
        let pendingOperation = attribute("pendingOperation", .stringAttributeType)
        pendingOperation.defaultValue = SyncMetadata.Operation.none.rawValue
        let lastSyncError = attribute("lastSyncError", .stringAttributeType, optional: true)
        let createdAt = attribute("createdAt", .dateAttributeType)
        let updatedAt = attribute("updatedAt", .dateAttributeType)

        entity.properties = [
            id, entityName, localID, recordName, lastKnownChangeTag,
            lastSyncedAt, pendingOperation, lastSyncError, createdAt, updatedAt
        ]
        return entity
    }
}
```

**Step 4: 注册 entity**

Modify `CoreDataStack.createDataModel()`:

```swift
entities.append(createSyncMetadataEntity())
```

放在业务实体之后或之前都可以，但要保持稳定顺序。

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
git add 'Holo/Holo APP/Holo/Holo/Models'
git commit -m "feat: add sync metadata storage"
```

---

### Task 3: SyncMetadataRepository

**Files:**
- Create: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/SyncMetadataRepository.swift`

**Step 1: 新增 repository**

Create `SyncMetadataRepository.swift`:

```swift
import Foundation
import CoreData

final class SyncMetadataRepository {
    static let shared = SyncMetadataRepository()

    private var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }

    private init() {}

    func metadata(entityName: String, localID: String) -> SyncMetadata? {
        let request = SyncMetadata.fetchRequest()
        request.predicate = NSPredicate(
            format: "entityName == %@ AND localID == %@",
            entityName,
            localID
        )
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    @discardableResult
    func ensureMetadata(entityName: String, localID: String, recordName: String) -> SyncMetadata {
        if let existing = metadata(entityName: entityName, localID: localID) {
            return existing
        }

        let now = Date()
        let metadata = SyncMetadata(context: context)
        metadata.id = UUID()
        metadata.entityName = entityName
        metadata.localID = localID
        metadata.recordName = recordName
        metadata.pendingOperation = SyncMetadata.Operation.none.rawValue
        metadata.createdAt = now
        metadata.updatedAt = now
        return metadata
    }

    func markPendingUpsert(entityName: String, localID: String, recordName: String) throws {
        let metadata = ensureMetadata(entityName: entityName, localID: localID, recordName: recordName)
        metadata.operation = .upsert
        metadata.lastSyncError = nil
        try context.save()
    }

    func markPendingDelete(entityName: String, localID: String, recordName: String) throws {
        let metadata = ensureMetadata(entityName: entityName, localID: localID, recordName: recordName)
        metadata.operation = .delete
        metadata.lastSyncError = nil
        try context.save()
    }

    func pendingMetadata(entityName: String) -> [SyncMetadata] {
        let request = SyncMetadata.fetchRequest()
        request.predicate = NSPredicate(
            format: "entityName == %@ AND pendingOperation != %@",
            entityName,
            SyncMetadata.Operation.none.rawValue
        )
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }
}
```

**Step 2: 构建验证**

Run:

```bash
cd '/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo'
xcodebuild -project Holo.xcodeproj -scheme Holo -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

**Step 3: Commit**

```bash
git add 'Holo/Holo APP/Holo/Holo/Models/SyncMetadataRepository.swift'
git commit -m "feat: add sync metadata repository"
```

---

### Task 4: CloudKit 基础服务

**Files:**
- Create: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/CloudKitSyncError.swift`
- Create: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/CloudKitSyncService.swift`

**Step 1: 新增错误模型**

Create `CloudKitSyncError.swift`:

```swift
import Foundation

enum CloudKitSyncError: LocalizedError {
    case iCloudUnavailable
    case iCloudAccountUnavailable
    case restricted
    case temporarilyUnavailable
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud 同步不可用"
        case .iCloudAccountUnavailable:
            return "未登录 iCloud，同步已暂停"
        case .restricted:
            return "当前 iCloud 账号受限，无法同步"
        case .temporarilyUnavailable:
            return "iCloud 暂时不可用，请稍后重试"
        case .unknown(let error):
            return error.localizedDescription
        }
    }
}
```

**Step 2: 新增 CloudKitSyncService skeleton**

Create `CloudKitSyncService.swift`:

```swift
import Foundation
import CloudKit

@MainActor
final class CloudKitSyncService: ObservableObject {
    static let shared = CloudKitSyncService()

    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isSyncing = false

    let container: CKContainer
    let privateDatabase: CKDatabase

    private init(
        container: CKContainer = CKContainer(identifier: "iCloud.com.tangyuxuan.Holo")
    ) {
        self.container = container
        self.privateDatabase = container.privateCloudDatabase
    }

    func refreshAccountStatus() async -> CKAccountStatus {
        do {
            let status = try await container.accountStatus()
            accountStatus = status
            lastErrorMessage = nil
            return status
        } catch {
            lastErrorMessage = error.localizedDescription
            accountStatus = .couldNotDetermine
            return .couldNotDetermine
        }
    }

    func ensureAvailable() async throws {
        let status = await refreshAccountStatus()
        switch status {
        case .available:
            return
        case .noAccount:
            throw CloudKitSyncError.iCloudAccountUnavailable
        case .restricted:
            throw CloudKitSyncError.restricted
        case .temporarilyUnavailable:
            throw CloudKitSyncError.temporarilyUnavailable
        case .couldNotDetermine:
            throw CloudKitSyncError.iCloudUnavailable
        @unknown default:
            throw CloudKitSyncError.iCloudUnavailable
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
git add 'Holo/Holo APP/Holo/Holo/Services/Sync'
git commit -m "feat: add CloudKit sync service foundation"
```

---

### Task 5: Goal CloudKit Adapter

**Files:**
- Create: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/CloudSyncRecord.swift`
- Create: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/GoalCloudSyncAdapter.swift`

**Step 1: 新增映射协议**

Create `CloudSyncRecord.swift`:

```swift
import Foundation
import CloudKit
import CoreData

protocol CloudSyncRecordAdapter {
    associatedtype Object: NSManagedObject

    var recordType: String { get }
    var entityName: String { get }

    func recordName(for object: Object) -> String
    func makeRecord(from object: Object, existingRecord: CKRecord?) -> CKRecord
    func apply(record: CKRecord, in context: NSManagedObjectContext) throws
}
```

**Step 2: 新增 Goal adapter**

Create `GoalCloudSyncAdapter.swift`:

```swift
import Foundation
import CloudKit
import CoreData

struct GoalCloudSyncAdapter: CloudSyncRecordAdapter {
    let recordType = "GoalRecord"
    let entityName = "Goal"

    func recordName(for object: Goal) -> String {
        object.id.uuidString
    }

    func makeRecord(from object: Goal, existingRecord: CKRecord? = nil) -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName(for: object))
        let record = existingRecord ?? CKRecord(recordType: recordType, recordID: recordID)
        record["title"] = object.title as CKRecordValue
        record["summary"] = object.summary as CKRecordValue?
        record["domain"] = object.domain as CKRecordValue
        record["desiredOutcome"] = object.desiredOutcome as CKRecordValue?
        record["motivation"] = object.motivation as CKRecordValue?
        record["status"] = object.status as CKRecordValue
        record["deadline"] = object.deadline as CKRecordValue?
        record["createdAt"] = object.createdAt as CKRecordValue
        record["updatedAt"] = object.updatedAt as CKRecordValue
        record["completedAt"] = object.completedAt as CKRecordValue?
        record["source"] = object.source as CKRecordValue
        record["allowAIContext"] = (object.allowAIContext ? 1 : 0) as CKRecordValue
        record["lastInsightSummary"] = object.lastInsightSummary as CKRecordValue?
        return record
    }

    func apply(record: CKRecord, in context: NSManagedObjectContext) throws {
        guard let uuid = UUID(uuidString: record.recordID.recordName) else { return }

        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        let goal = try context.fetch(request).first ?? Goal(context: context)

        if goal.entity.managedObjectContext == context, goal.id == UUID() {
            goal.id = uuid
        } else if goal.id.uuidString.isEmpty {
            goal.id = uuid
        }

        goal.id = uuid
        goal.title = record["title"] as? String ?? goal.title
        goal.summary = record["summary"] as? String
        goal.domain = record["domain"] as? String ?? GoalDomain.other.rawValue
        goal.desiredOutcome = record["desiredOutcome"] as? String
        goal.motivation = record["motivation"] as? String
        goal.status = record["status"] as? String ?? GoalStatus.active.rawValue
        goal.deadline = record["deadline"] as? Date
        goal.createdAt = record["createdAt"] as? Date ?? Date()
        goal.updatedAt = record["updatedAt"] as? Date ?? Date()
        goal.completedAt = record["completedAt"] as? Date
        goal.source = record["source"] as? String ?? "cloudkit"
        goal.allowAIContext = (record["allowAIContext"] as? Int64 ?? 0) == 1
        goal.lastInsightSummary = record["lastInsightSummary"] as? String
    }
}
```

**Implementation note:** 上面 `apply` 的新对象判断在实际实现时应进一步简化，推荐通过 `fetch first ?? Goal(context:)` 后直接赋值 `id = uuid`。计划里保留重点逻辑，执行时以可编译代码为准。

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
git add 'Holo/Holo APP/Holo/Holo/Services/Sync'
git commit -m "feat: add goal CloudKit record adapter"
```

---

### Task 6: GoalRepository 标记待同步

**Files:**
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Models/GoalRepository.swift`

**Step 1: 在 createGoal 后标记 upsert**

在 `createGoal(from:allowAIContext:)` 保存后增加：

```swift
try SyncMetadataRepository.shared.markPendingUpsert(
    entityName: "Goal",
    localID: goal.id.uuidString,
    recordName: goal.id.uuidString
)
```

**Step 2: 在 updateStatus 后标记 upsert**

在 `updateStatus(_:status:)` 保存后增加同样的 upsert 标记。

**Step 3: 在 updateAIContext 后标记 upsert**

在 `updateAIContext(_:allow:)` 保存后增加同样的 upsert 标记。

**Step 4: 在 deleteGoal 前标记 delete**

删除前先保存 `goal.id.uuidString`，删除后标记：

```swift
let recordName = goal.id.uuidString
context.delete(goal)
try context.save()
try SyncMetadataRepository.shared.markPendingDelete(
    entityName: "Goal",
    localID: recordName,
    recordName: recordName
)
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
git add 'Holo/Holo APP/Holo/Holo/Models/GoalRepository.swift'
git commit -m "feat: mark goal changes for CloudKit sync"
```

---

### Task 7: 手动 Goal 同步 MVP

**Files:**
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/CloudKitSyncService.swift`
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/Services/Sync/GoalCloudSyncAdapter.swift`

**Step 1: 实现上传 pending upsert**

逻辑：

1. `ensureAvailable()`
2. 从 `SyncMetadataRepository.pendingMetadata(entityName: "Goal")` 取 pending。
3. 对 `upsert` 找到本地 `Goal`。
4. 使用 `GoalCloudSyncAdapter.makeRecord` 创建 `CKRecord`。
5. 调用 `privateDatabase.save(record)`。
6. 成功后清空 pending operation，保存 `lastKnownChangeTag` 和 `lastSyncedAt`。

**Step 2: 实现 pending delete**

逻辑：

1. 对 `delete` 调用 `privateDatabase.deleteRecord(withID:)`。
2. 如果 CloudKit 返回 record not found，视为成功。
3. 成功后清空 pending operation。

**Step 3: 实现全量拉取 GoalRecord**

第一版可以先使用 query：

```swift
let query = CKQuery(recordType: "GoalRecord", predicate: NSPredicate(value: true))
```

然后逐条 `adapter.apply(record:in:)`。

**Step 4: 实现冲突策略**

当本地存在同 recordName 的 Goal：

- 如果云端 `updatedAt` 晚于本地 `updatedAt`，应用云端。
- 如果本地 `updatedAt` 晚于云端，保留本地并标记 upsert。
- 如果相等，不处理。

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
git add 'Holo/Holo APP/Holo/Holo/Services/Sync'
git commit -m "feat: add manual goal CloudKit sync"
```

---

### Task 8: 最小同步入口与状态展示

**Files:**
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/HoloApp.swift`
- Modify: 现有设置页或个人页入口文件，执行时先定位具体文件

**Step 1: App 启动时刷新 iCloud 状态**

在 `HoloApp` 启动流程中触发：

```swift
Task {
    await CloudKitSyncService.shared.refreshAccountStatus()
}
```

**Step 2: 增加手动同步入口**

如果已有设置页，加入：

- iCloud 状态文本。
- “立即同步”按钮。
- 最近错误信息。

如果没有合适设置页，先在开发调试入口或 Personal 页面隐藏区域加入，后续再产品化。

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
git add 'Holo/Holo APP/Holo/Holo'
git commit -m "feat: add iCloud sync status entry"
```

---

### Task 9: 真机与 TestFlight 验证

**Files:**
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/CHANGELOG.md`
- Modify: `/Users/tangyuxuan/Desktop/Claude/HOLO/TODO.md`

**Step 1: 真机 A 创建目标**

操作：

1. 在真机 A 登录 iCloud。
2. 创建一个新目标。
3. 点击“立即同步”。
4. 打开 CloudKit Dashboard 确认 `GoalRecord` 创建。

Expected:

```text
GoalRecord 存在，recordName 等于 Goal.id.uuidString。
```

**Step 2: 真机 B 拉取目标**

操作：

1. 真机 B 登录同一个 iCloud。
2. 安装同一 Debug 或 TestFlight 版本。
3. 点击“立即同步”。

Expected:

```text
真机 B 出现真机 A 创建的 Goal，且不重复。
```

**Step 3: 修改冲突验证**

操作：

1. 真机 A 修改目标标题并同步。
2. 真机 B 修改同一目标状态并同步。
3. 再分别同步两台设备。

Expected:

```text
较新的 updatedAt 胜出；不会产生重复 Goal。
```

**Step 4: 删除验证**

操作：

1. 真机 A 删除目标并同步。
2. 真机 B 拉取同步。

Expected:

```text
真机 B 对应 Goal 被删除或标记删除，列表不再显示。
```

**Step 5: 更新文档**

在 `CHANGELOG.md` 写入：

```markdown
- 新增 iCloud CloudKit 私有数据库同步底座，第一阶段支持目标系统同步。
```

在 `TODO.md` 标记：

```markdown
- [x] CloudKit 同步底座 MVP
- [x] Goal 私有数据库同步 MVP
```

**Step 6: Commit**

```bash
git add CHANGELOG.md TODO.md
git commit -m "docs: record CloudKit sync MVP verification"
```

---

## 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| entitlement 配置不一致 | Debug 可用但 TestFlight 不可用 | Debug / Release entitlements 同步更新 |
| iCloud 未登录 | 用户误以为数据丢失 | 本地继续可用，显示同步暂停 |
| CloudKit schema 不稳定 | 后续迁移困难 | 第一版只建 `GoalRecord`，字段保持保守 |
| 删除同步误伤 | 跨设备误删 | 第一版先手动同步验证，后续再做软删除和恢复 |
| 冲突覆盖用户修改 | 数据不符合预期 | 第一版使用 `updatedAt`，后续增加冲突 UI |
| 财务数据过早接入 | 金额/分类统计错乱 | 财务延后到同步框架稳定后 |

## 后续扩展顺序

1. `GoalRecord`
2. `TodoTaskRecord` / `HabitRecord` 与 Goal 关系
3. 分类、设置、首页配置
4. Finance Account / Category
5. Transaction / Budget
6. 后台自动同步和远程变更订阅
7. 冲突解决 UI 与同步日志页面

## 执行建议

建议每个 Task 独立提交。第一轮实现只做到 `Task 1` 到 `Task 7`，先用真机手动同步验证闭环，再决定是否加入设置页状态展示。

Plan complete and saved to `docs/_common/plans/2026-05-17-Holo-iCloud-CloudKit同步实施方案.md`.

Two execution options:

1. Subagent-Driven (this session): dispatch fresh subagent per task, review between tasks, fast iteration.
2. Parallel Session (separate): open new session with executing-plans, batch execution with checkpoints.
