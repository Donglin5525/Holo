# 任务模块图片附件功能 V2（实体 + 文件系统方案）

> 创建日期：2026-05-03
> 状态：已根据两轮对抗性审查修订（GPT + Claude）
> 替代：V1 方案（`TASK_IMAGE_ATTACHMENT_PLAN.md`，Transformable 内联存储）

---

## Context

TodoTask 实体目前没有任何图片/附件能力。用户需要在任务中附加多张图片（拍照 + 相册选取），用于记录发票、白板笔记、参考截图等场景。

**V1 方案问题**：`imagesData` Transformable 将所有图片序列化为 JSON `[Data]` 存入 Core Data。9 张图约 2.7MB 压缩数据直接膨胀 SQLite 文件，影响全表查询性能，且 CloudKit 单字段限制 1MB。

**V2 方案选型**：新建 `TaskAttachment` 实体 + 文件系统存储（`Documents/Attachments/`），Core Data 只存文件名引用和附件元数据。

理由：(1) 支持多图不膨胀数据库 (2) Core Data 查询性能不受影响 (3) 单张图可独立加载/删除 (4) 未来 iCloud 方案可以在 `TaskAttachment` 实体上演进。

**iCloud 边界说明**：V2 只让附件“元数据实体”具备同步基础，不解决图片文件跨设备传输。若未来启用 `NSPersistentCloudKitContainer`，另一台设备只能拿到 `fileName` 等字段，无法自动获得本机 `Documents/Attachments/` 中的文件。后续需要单独选择文件同步方案：`CKAsset`、iCloud Drive/ubiquity container，或自建对象存储。

---

## Phase 1: 数据层

### 1.1 新建 TaskAttachment 实体

**新建文件：`Models/TaskAttachment+CoreDataClass.swift`**（~40 行，参照 CheckItem 模式）

```swift
@objc(TaskAttachment)
class TaskAttachment: NSManagedObject, @unchecked Sendable {
    @NSManaged var id: UUID
    @NSManaged var fileName: String           // 如 "{uuid}.jpeg"
    @NSManaged var thumbnailFileName: String   // 如 "{uuid}_thumb.jpeg"
    @NSManaged var sortOrder: Int16
    @NSManaged var sourceType: String          // "camera" / "photoLibrary"
    @NSManaged var createdAt: Date
    @NSManaged var task: TodoTask?             // many-to-one
}
```

### 1.1a TodoTask 附件计数字段

**修改：`Models/TodoTask+CoreDataClass.swift`**

在普通属性区域添加冗余计数字段，避免任务列表每张卡片读取 `attachments` relationship 造成 N+1 fault：
```swift
@NSManaged var attachmentCount: Int16
```

Repository 的附件增删方法必须同步维护 `task.attachmentCount`。任务列表和 `TaskCardView` 只读取 `attachmentCount`；详情页、网格、删除清理流程才读取 `sortedAttachments` / `attachmentFileRefs`。

### 1.2 TaskAttachment 属性扩展

**新建文件：`Models/TaskAttachment+CoreDataProperties.swift`**（~35 行，参照 CheckItem.create 模式）

```swift
static func create(
    in context: NSManagedObjectContext,
    fileName: String,
    thumbnailFileName: String,
    task: TodoTask,
    order: Int16 = 0,
    sourceType: String = "photoLibrary"
) -> TaskAttachment
```

### 1.3 TodoTask 添加 attachments 关系

**修改：`Models/TodoTask+CoreDataClass.swift`**

在 Relationships 区域添加：
```swift
@NSManaged var attachments: NSSet?
```

在 Core Data Generated Accessors 区域添加：
```swift
@objc(addAttachmentsObject:)
@NSManaged func addAttachments(_ value: TaskAttachment)
@objc(removeAttachmentsObject:)
@NSManaged func removeAttachments(_ value: TaskAttachment)
@objc(addAttachments:)
@NSManaged func addAttachments(_ values: Set<TaskAttachment>)
@objc(removeAttachments:)
@NSManaged func removeAttachments(_ values: Set<TaskAttachment>)
```

**修改：`Models/TodoTask+CoreDataProperties.swift`**

添加计算属性：
```swift
var sortedAttachments: [TaskAttachment] {
    let array = attachments?.allObjects as? [TaskAttachment] ?? []
    return array.sorted { $0.sortOrder < $1.sortOrder }
}
```

添加附件文件引用类型（供 Repository 删除流程使用）。`AttachmentFileRef` 必须是 top-level struct，不要嵌套在 `extension TodoTask` 里，否则 Repository 中直接使用 `[AttachmentFileRef]` 会与实际类型名不一致。
```swift
struct AttachmentFileRef {
    let taskId: UUID
    let fileName: String
    let thumbnailFileName: String
}

var attachmentFileRefs: [AttachmentFileRef] {
    sortedAttachments.map { .init(taskId: id, fileName: $0.fileName, thumbnailFileName: $0.thumbnailFileName) }
}
```

### 1.4 注册实体到 CoreDataStack

**修改：`Models/CoreDataStack+TodoEntities.swift`**

在 `createTodoEntities()` 中（参照现有 CheckItem 的定义模式）：

1. 定义 TaskAttachment entity 的 6 个属性（NSAttributeDescription）
2. 为 TodoTask 定义 `attachmentCount` integer16 属性（默认值 0）
3. 定义 TodoTask → TaskAttachment 一对多关系（cascade，删除任务时级联删除附件记录）
4. 定义 TaskAttachment → TodoTask 多对一关系（nullify）
5. 将 attachments 关系追加到 `todoTaskEntity.properties`
6. 将 `taskAttachmentEntity` 追加到 return 数组

`attachmentCount` 属性定义：
```swift
let taskAttachmentCount = NSAttributeDescription()
taskAttachmentCount.name = "attachmentCount"
taskAttachmentCount.attributeType = .integer16AttributeType
taskAttachmentCount.isOptional = false
taskAttachmentCount.defaultValue = 0
todoTaskAttributes.append(taskAttachmentCount)
```

**关键**：line 528 当前是：
```swift
todoTaskEntity.properties = todoTaskAttributes + [taskListRelation, taskTagsRelation, taskCheckItemsRelation, taskRepeatRuleRelation]
```
改为追加 `taskAttachmentsRelation`。

**迁移安全**：新增实体、可选关系（`attachments` isOptional=true, minCount=0）和带默认值的非可选 `attachmentCount`。`attachmentCount.defaultValue = 0` 是 lightweight migration 能推断迁移的关键；现有 TodoTask 的 `attachments` 为 nil，`attachmentCount` 为 0，所有现有代码通过 `?.allObjects as? [Type] ?? []` 模式访问，不受影响。

---

## Phase 2: 服务层

### 2.1 文件管理服务

**新建文件：`Services/AttachmentFileManager.swift`**（~200 行，enum 无状态工具，参照项目内 HapticManager 的 enum 模式）

**目录结构**：
```
Documents/
  HoloDataModel.sqlite           (现有)
  Attachments/
    {taskId}/
      {attachmentId}.jpeg        (原图, max 2048px, quality 0.8)
      {attachmentId}_thumb.jpeg  (缩略图, max 300px, quality 0.6)
```

用 taskId 子目录的理由：(1) 整任务批量删除只需 rmdir (2) 调试时直观 (3) 无文件名冲突。

**核心方法**：
| 方法 | 说明 |
|------|------|
| `saveImage(_:taskId:attachmentId:) async throws -> (fileName, thumbFileName)` | 后台压缩原图 + 生成缩略图 + 原子写磁盘 |
| `saveImageToTemporaryAttachment(_:attachmentId:) async throws -> PendingAttachment` | 新建任务未保存前，先后台压缩写入临时目录 |
| `promoteTemporaryAttachment(_:toTaskId:) throws -> (fileName, thumbFileName)` | 保存任务成功后，将临时附件移动到正式任务目录 |
| `deleteTemporaryAttachment(_:)` | 用户取消新建任务或移除待保存附件时清理临时文件 |
| `deleteAttachmentFiles(fileName:thumbFileName:taskId:)` | 删除单个附件的两个文件 |
| `deleteAllAttachments(for taskId:)` | 删除整个任务附件目录 |
| `loadThumbnail(fileName:taskId:) -> UIImage?` | 加载缩略图（网格显示用） |
| `loadFullImage(fileName:taskId:) -> UIImage?` | 加载原图（全屏浏览用） |
| `compressImage(_:maxDimension:quality:) -> Data?` | UIImage 缩放 + JPEG 压缩，统一输出 JPEG（输入可能是 HEIC/PNG/GIF） |
| `generateThumbnail(from:maxSize:) -> Data?` | 生成 300px 缩略图 |
| `scanAndDeleteOrphanAttachmentDirectories(validTaskIds:)` | 启动或维护时清理孤儿附件目录 |

**图片格式统一**：PhotosPicker 可能返回 HEIC、PNG、GIF 等格式。`compressImage` 必须统一转 JPEG 输出（`.jpeg` 后缀），通过 `UIImage.jpegData(compressionQuality:)` 隐式完成格式转换。

**异步压缩与 actor 边界**：
- `TodoRepository` 是 `@MainActor`，12MP 大图压缩不能在主线程执行。
- 附件新增链路统一使用 `async throws`，调用方通过 `await` 等待压缩、写文件、Core Data 保存和补偿清理完成。
- 后台任务只处理 `Data`、`UUID`、`String`、`URL` 等可安全跨 actor 传递的值；不要把 `TodoTask`、`TaskAttachment`、`NSManagedObjectContext` 或其他 `NSManagedObject` 捕获进 `Task.detached`。
- 如果后台阶段需要定位任务，只传 `task.objectID` 或 `task.id`；回到 `MainActor` 后用当前 `context` 重新获取对象，再创建/更新 Core Data 记录。
- 尽量在进入后台压缩前把 `UIImage` 转成 `Data` 或在主线程完成必要的 UIKit 解码，避免把非 Sendable 的 `UIImage` 直接跨并发边界传递。

**12MP 相机照片预估体积**：原图压缩后通常约 300KB-1.2MB（受图片内容复杂度影响），缩略图约 20KB-80KB。9 张附件总计按 3MB-12MB 预估，不把 `<300KB` 作为硬性验收指标。

### 2.2 Repository 扩展

**新建文件：`Models/TodoRepository+Attachments.swift`**（~180 行，参照 +Kanban.swift / +Stats.swift 模式）

| 方法 | 说明 |
|------|------|
| `addAttachment(imageData:to:sourceType:) async throws -> TaskAttachment` | 后台压缩→存磁盘→回 MainActor 建 Core Data 记录；若 Core Data 保存失败，回滚刚写入的文件 |
| `savePendingAttachment(imageData:sourceType:) async throws -> PendingAttachment` | 新建任务未保存前，后台压缩并写入 `_pending` 临时目录 |
| `attachPromotedTemporaryFile(_:to:sourceType:) async throws -> TaskAttachment` | 新建任务保存后，将临时文件提升为正式附件记录 |
| `deleteAttachment(_:) throws` | 先删 Core Data 记录并保存→再删磁盘文件；磁盘删除失败记录日志并交给孤儿清扫 |
| `reorderAttachments(_:) throws` | 批量更新 sortOrder |
| `deleteAllAttachmentRecords(for:) throws -> [AttachmentFileRef]` | 只删除附件记录并返回待删文件引用 |
| `deleteAllAttachments(for:) throws` | 删除附件记录保存成功后，再清理文件 |
| `cleanupOrphanAttachments() throws` | 根据现存 TodoTask id 扫描并删除孤儿附件目录 |

涉及 Core Data 写入的方法仍遵循现有模式：`context.save() → loadActiveTasks() → notifyDataChange()`。异步附件新增方法在后台阶段完成后，必须回到 `MainActor` 再执行这组 Core Data 操作。

**事务边界原则**：
- 不允许 `try?` 静默吞掉附件清理错误。
- Core Data 和文件系统不是同一个事务，所有写入/删除都要有补偿路径。
- 添加附件：先写文件，再建记录；若 `context.save()` 失败，立即删除本次写入的文件。
- 删除附件或任务：先删除 Core Data 记录并成功保存，再删除文件。文件删除失败不会恢复数据库记录，但必须记录日志，并由 `cleanupOrphanAttachments()` 后续清理孤儿文件。
- 批量删除任务前先收集 `AttachmentFileRef(taskId, fileName, thumbnailFileName)`，Core Data 保存成功后再逐个删除文件。

**修改：`Models/TodoRepository.swift`**

1. **`permanentlyDeleteTask`**（line 464）：在 `context.delete(task)` 前收集待删附件引用，删除任务并 `context.save()` 成功后再清理文件：
   ```swift
   let fileRefs = task.attachmentFileRefs
   context.delete(task)
   try context.save()
   AttachmentFileManager.deleteFiles(fileRefs)
   ```

2. **`clearTrash`**（line 774）：先收集所有回收站任务的附件引用，批量删除并保存成功后再清理文件：
   ```swift
   var fileRefs: [AttachmentFileRef] = []
   for task in trashed {
       fileRefs.append(contentsOf: task.attachmentFileRefs)
       context.delete(task)
   }
   try context.save()
   AttachmentFileManager.deleteFiles(fileRefs)
   ```

3. **`deleteList(_:)`**（line 239）：清单删除会级联删除任务，必须纳入附件清理：
   ```swift
   let tasks = list.tasks?.allObjects as? [TodoTask] ?? []
   let fileRefs = tasks.flatMap(\.attachmentFileRefs)
   context.delete(list)
   try context.save()
   AttachmentFileManager.deleteFiles(fileRefs)
   ```

4. **`deleteFolder(_:)`**（line 167）：**（GPT 审查遗漏，Claude 补充）** 文件夹删除级联链 Folder → List → Task → Attachment，Core Data cascade 会删除实体记录但不会清理磁盘文件。同 `deleteList` 模式处理：
   ```swift
   let allTasks = folder.lists?.allObjects.compactMap { ($0 as? TodoList)?.tasks?.allObjects as? [TodoTask] }.flatMap { $0 } ?? []
   let fileRefs = allTasks.flatMap(\.attachmentFileRefs)
   context.delete(folder)
   try context.save()
   AttachmentFileManager.deleteFiles(fileRefs)
   ```

5. 启动或 `TodoRepository` 初始化后可触发一次低优先级 `cleanupOrphanAttachments()`，用于清理历史异常、崩溃或半保存造成的残留目录。

---

## Phase 3: UI 组件

### 3.1 缩略图视图

**新建文件：`Views/Tasks/AttachmentThumbnailView.swift`**（~80 行）

- 使用 `.task` modifier 生命周期感知加载缩略图
- `@State private var image: UIImage?` 持有，视图消失自动释放
- 1:1 正方形裁剪，`aspectRatio(1, contentMode: .fill)` + `clipped()`

### 3.2 附件网格

**新建文件：`Views/Tasks/TaskAttachmentGrid.swift`**（~250 行）

3 列 `LazyVGrid`，包含：
- **缩略图卡片**：1:1 正方形，点击打开全屏浏览
- **添加按钮**：虚线边框 "+" 方格，仅在 `count < 9` 时显示
- **删除交互**：长按进入编辑模式 → 每个缩略图右上角红色 x 按钮（参照 iOS 相册 App）
- 回调：`onAdd`、`onDelete(TaskAttachment)`、`onTap(Int)`

### 3.3 图片选择器

**新建文件：`Views/Tasks/TaskImagePicker.swift`**（~150 行）

Menu 两个选项：
1. **"拍照"** → `UIViewControllerRepresentable` 包装 `UIImagePickerController(sourceType: .camera)`
2. **"从相册选择"** → `PhotosPicker`（`selectionLimit = 9 - 当前数量`，`matching: .images`）

**权限处理**：
- 相机：检查 `AVCaptureDevice.authorizationStatus(for: .video)`，拒绝时弹 Alert 引导去设置
- 相册：`PhotosPicker` 在 iOS 17+ 无需 Info.plist 权限描述（系统级进程外选择器）

### 3.4 全屏图片浏览器

**新建文件：`Views/Tasks/AttachmentGalleryView.swift`**（~200 行）

- `TabView(selection:)` + `.tabViewStyle(.page)` 横向滑动切换
- 每页：封装 `ZoomableImageView`，优先用 `UIScrollViewRepresentable` 获得稳定的双指缩放 + 拖拽平移；不要只用 SwiftUI `ScrollView` 假设它自带 pinch zoom
- 覆盖层：顶部关闭按钮（左上角 xmark），底部页码 "1/5"
- 黑色背景，fullScreenCover 呈现

### 3.5 集成到 AddTaskSheet

**修改：`Views/Tasks/AddTaskSheet.swift`**（~100 行净增）

**位置**：在 `checklistSection` 和 `metadataSection` 之间插入 `attachmentSection`

**新增状态**：
```swift
@State private var pendingAttachments: [PendingAttachment] = []
@State private var showAttachmentGallery = false
@State private var galleryStartIndex = 0
```

`PendingAttachment` 不能持有原始 `UIImage` 或大块原始 `Data`。结构只保存轻量引用：
```swift
struct PendingAttachment: Identifiable {
    let id: UUID
    let tempFileName: String
    let tempThumbnailFileName: String
    let sourceType: String
}
```

**新建任务**：
1. 用户选择/拍摄图片后，立即逐张压缩并写入 `Documents/Attachments/_pending/{uuid}/`。
2. `pendingAttachments` 只保存临时文件名和 sourceType，缩略图按需从临时目录读取。
3. 用户取消新建任务或删除某个 pending 附件时，删除对应临时文件。
4. `saveTask()` 先创建任务并保存成功，再 `await repository.attachPromotedTemporaryFile(...)` 把临时附件移动到 `Documents/Attachments/{taskId}/`，然后创建 `TaskAttachment` 记录。
5. 若附件提升失败，要提示用户“任务已保存，但部分附件保存失败”，并清理失败项的临时文件或保留可重试状态。

**编辑任务保存语义**：
- AddTaskSheet 编辑模式必须和表单其他字段保持一致：附件改动也走 pending delta，用户点“保存”后再提交，点“取消”则回滚并清理临时新增文件。
- `TaskDetailView` 是详情页直接编辑语义，可以在 `Task {}` 中 `await` 调用 repository 增删附件。
- 如果未来决定让 AddTaskSheet 附件也即时保存，必须同步修改取消按钮和未保存提醒文案，明确“附件改动已立即保存”。

**修改 `hasUnsavedChanges`**：添加 `!pendingAttachments.isEmpty` 判断

### 3.6 集成到 TaskDetailView

**修改：`Views/Tasks/TaskDetailView.swift`**（~80 行净增）

**位置**：在 `checklistCard` 和 `tagCard` 之间插入 `attachmentCard`

卡片结构（参照 checklistCard 模式）：
- 标题行："附件" + 数量徽标 + "添加" 按钮
- 内容区：内嵌 `TaskAttachmentGrid`
- 直接通过 repository 增删（无 pending 状态）

### 3.7 重复任务的附件处理

当 `RepeatRule` 触发生成新任务实例时，**不复制附件**。附件属于特定任务实例，新实例从空附件列表开始。理由：(1) 重复任务通常是日程性质（如"每周买菜"），每次执行的照片是独立的 (2) 复制附件会产生额外的磁盘占用和复杂的事务管理。

### 3.8 TaskCardView 附件指示器

**修改：`Views/Tasks/TaskCardView.swift`**（~5 行净增）

在任务卡片上显示附件图标，让用户在列表层面就能看到哪些任务有附件。不要在卡片里调用 `task.sortedAttachments`，否则列表渲染会触发 attachments relationship N+1 fault：
- 当 `task.attachmentCount > 0` 时，在卡片标题行右侧或描述行下方显示 `paperclip` SF Symbol + 数量徽标
- 样式与现有的优先级/日期图标保持一致（小图标 + 文字颜色）

### 3.9 Info.plist / Build Settings

项目当前 `GENERATE_INFOPLIST_FILE = YES`，仓库没有独立 `Info.plist` 文件，因此不要新增一个游离 plist。应修改 `Holo.xcodeproj/project.pbxproj` 的 Debug / Release build settings：

- `INFOPLIST_KEY_NSCameraUsageDescription = "需要访问相机以为任务拍摄附件照片";`
- `INFOPLIST_KEY_NSPhotoLibraryUsageDescription = "需要访问相册以为任务选择附件图片";`（iOS 16 兼容）

如后续改为显式 Info.plist，再迁移这些 key。

---

## 文件清单

### 新建（9 个文件）

| 文件 | 路径 | 估计行数 |
|------|------|---------|
| TaskAttachment+CoreDataClass.swift | Models/ | ~40 |
| TaskAttachment+CoreDataProperties.swift | Models/ | ~35 |
| AttachmentFileManager.swift | Services/ | ~200 |
| TaskImagePicker.swift | Views/Tasks/ | ~150 |
| TaskAttachmentGrid.swift | Views/Tasks/ | ~250 |
| AttachmentThumbnailView.swift | Views/Tasks/ | ~80 |
| AttachmentGalleryView.swift | Views/Tasks/ | ~200 |
| ZoomableImageView.swift | Views/Tasks/ | ~120 |
| TodoRepository+Attachments.swift | Models/ | ~180 |

### 修改（8 个文件）

| 文件 | 改动 |
|------|------|
| `CoreDataStack+TodoEntities.swift` | 新增 TaskAttachment entity 定义 + TodoTask attachments 关系 + attachmentCount 属性（~90 行） |
| `TodoTask+CoreDataClass.swift` | 添加 attachmentCount、attachments 关系 + accessors（~16 行） |
| `TodoTask+CoreDataProperties.swift` | 添加 sortedAttachments、attachmentFileRefs 计算属性 + top-level AttachmentFileRef（~20 行） |
| `TodoRepository.swift` | permanentlyDeleteTask + clearTrash + deleteList + **deleteFolder** 清理附件文件（~20 行） |
| `AddTaskSheet.swift` | attachment section + 状态 + picker sheet + save 逻辑（~100 行） |
| `TaskDetailView.swift` | attachment card + gallery sheet（~80 行） |
| `TaskCardView.swift` | 附件图标指示器（~5 行） |
| `Holo.xcodeproj/project.pbxproj` | 添加生成式 Info.plist 的相机/相册隐私 key |

---

## 实施顺序

| 阶段 | 内容 | 验证点 |
|------|------|--------|
| Phase 1 | 数据层（实体 + 关系 + CoreDataStack 注册） | 启动 App 无报错，已有任务正常显示 |
| Phase 2 | 服务层（FileManager + Repository 扩展 + delete 清理 + deleteFolder + 孤儿清扫） | 临时 debug view 验证增删附件、删除任务、删除清单、删除文件夹 |
| Phase 3a | UI 基础组件（Thumbnail → Grid → Picker → Gallery + ZoomableImageView） | Xcode Preview 验证各组件 |
| Phase 3b | 集成（AddTaskSheet + TaskDetailView + build settings 隐私 key） | 端到端流程测试 |

---

## V1 vs V2 对比

| 维度 | V1（Transformable 内联） | V2（实体 + 文件系统） |
|------|--------------------------|----------------------|
| 存储方式 | `[Data]` JSON 编码存入 Core Data | 文件存磁盘，Core Data 只存文件名 |
| 数据库影响 | 9 图 ~2.7MB 膨胀 SQLite | 零膨胀 |
| 图片来源 | 仅相册 | 相册 + 相机 |
| 单图删除 | 需要重新序列化整个数组 | 直接删文件 + Core Data 记录 |
| iCloud 同步 | CloudKit 单字段 1MB 限制 | 只同步元数据；文件传输必须另做 CKAsset / iCloud Drive / 对象存储 |
| 实现复杂度 | 较低（2 新建 + 6 修改） | 较高（9 新建 + 8 修改） |
| 缩略图 | 无（直接用压缩原图） | 独立缩略图 300px |

---

## 验证

1. 使用旧版本 store 启动新模型 → lightweight migration 成功 → 已有任务正常显示
2. 创建新任务 → 添加 3 张图片 → 保存 → 检查 `Documents/Attachments/{taskId}/` 目录有 6 个文件，`_pending` 目录已清空
3. 新建任务添加 3 张图片后点取消 → 临时附件文件全部删除
4. 编辑任务添加/删除附件后点取消 → 已有附件不变，临时新增文件清理
5. 编辑任务添加/删除附件后点保存 → Core Data 记录与磁盘文件一致
6. 打开任务详情 → 看到缩略图 → 点击进入全屏浏览 → 左右滑动 → 双指缩放与拖拽正常
7. 删除一张图片 → Core Data 记录删除成功 → 磁盘文件同步删除或被 orphan cleanup 后续清理 → 缩略图网格更新
8. 删除任务（移入回收站 → 永久删除）→ 附件文件全部清理
9. 删除包含附件任务的清单 → 级联删除任务后附件目录全部清理
10. **删除包含附件任务的文件夹** → 级联删除清单和任务后附件目录全部清理（deleteFolder 验证）
11. 模拟文件删除失败 → 数据库删除不回滚，但日志记录且 `cleanupOrphanAttachments()` 可清理残留
12. 12MP 相机拍照附件 → 原图压缩到合理体积区间，缩略图加载无明显卡顿
13. 选择 HEIC/PNG 图片 → 统一转为 JPEG 存储，缩略图正常显示
14. 列表页包含大量任务时 → TaskCardView 只读取 `attachmentCount`，不触发每个任务的 `attachments` relationship fault
15. 附件新增流程 → 调用方使用 `await`，后台压缩不捕获 `NSManagedObject`，完成后回 MainActor 保存 Core Data

---

## 风险与缓解

| 风险 | 缓解措施 |
|------|---------|
| 大图内存压力 | PhotosPicker 逐张加载后立即压缩写入临时目录，`pendingAttachments` 只保存文件引用；使用 autoreleasepool 释放中间 UIImage |
| 主线程压缩卡顿 | 附件新增 API 使用 `async throws`；压缩和 JPEG 编码在后台执行，Core Data 写入回 MainActor |
| Swift 并发/actor 边界错误 | 后台任务只传递 Data、UUID、String、URL 等值；不捕获 TodoTask、TaskAttachment、context 等 Core Data 对象 |
| 相机权限被拒 | 预检 authorizationStatus，拒绝时弹窗引导去设置 |
| 磁盘空间不足 | 添加附件时先写文件再 save Core Data；Core Data 保存失败则删除本次写入文件；文件写入失败则不创建记录 |
| Core Data 与文件系统不具备事务一致性 | 明确补偿策略：添加失败删新文件；删除记录成功后删文件；文件删除失败记录日志并通过 orphan cleanup 补扫 |
| 任务删除文件残留 | permanentlyDeleteTask、clearTrash、deleteList 都收集附件引用并在 Core Data 保存成功后删文件 |
| 清单级级联删除遗漏 | deleteList 和 **deleteFolder** 显式收集所有任务的附件引用，不能只依赖 Core Data cascade |
| 文件夹级级联删除遗漏 | deleteFolder 收集 folder.lists 下所有任务的附件引用（Folder → List → Task 三级级联） |
| 编辑页取消语义混乱 | AddTaskSheet 编辑模式附件改动走 pending delta；TaskDetailView 才即时保存 |
| 任务列表附件指示导致 N+1 fault | TaskCardView 只读取 TodoTask.attachmentCount；详情页和删除流程才读取 attachments relationship |
| 全屏浏览缩放不可用 | 使用 `UIScrollViewRepresentable` 封装缩放视图，不依赖 SwiftUI ScrollView 自带能力 |
| iCloud 同步 | 当前仅同步附件元数据；文件传输另行设计 CKAsset / iCloud Drive / 对象存储 |
