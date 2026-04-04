# 任务模块 — 图片附件功能方案

> 创建日期：2026-04-05
> 状态：待确认

---

## 背景

任务模块目前只支持文字内容（标题、描述、检查清单）。用户在新建/编辑任务时希望能附加图片，用于补充说明任务内容。

**需求确认**：
- 每个任务最多 9 张图片
- 仅支持从系统相册选择
- 图片存储在 Core Data

---

## 改动范围

### 新建 2 个文件

| 文件 | 用途 |
|------|------|
| `Utils/ImageCompressor.swift` | 图片压缩工具（缩放 + JPEG 压缩） |
| `Views/Tasks/TaskImageGalleryView.swift` | 全屏图片浏览器（TabView 分页 + 缩放） |

### 修改 6 个文件

| 文件 | 改动 |
|------|------|
| `Models/CoreDataStack.swift` | TodoTask 实体新增 `imagesData` 属性（Transformable） |
| `Models/TodoTask+CoreDataClass.swift` | 新增 `@NSManaged var imagesData: Data?` |
| `Models/TodoTask+CoreDataProperties.swift` | 新增 `imagesArray` 计算属性 + `hasImages` / `imageCount` |
| `Models/TodoRepository.swift` | `createTask` / `updateTask` 新增 `images` 参数 |
| `Views/Tasks/AddTaskSheet.swift` | 新增图片选择区（3列网格缩略图 + PhotosPicker） |
| `Views/Tasks/TaskDetailView.swift` | 新增图片卡片 + 全屏预览入口 |

---

## 实现步骤

### Step 1: Core Data Schema — 添加 `imagesData` 属性

**文件**: `CoreDataStack.swift` (约 line 819)

在 `taskSmartReminderSchedule` 之后、`// MARK: - TodoTag Entity` 之前添加：

```swift
let taskImagesData = NSAttributeDescription()
taskImagesData.name = "imagesData"
taskImagesData.attributeType = .transformableAttributeType
taskImagesData.isOptional = true
taskImagesData.valueTransformerName = "NSSecureUnarchiveFromData"
todoTaskAttributes.append(taskImagesData)
```

沿用 `reminders` 属性完全相同的 Transformable 模式。项目已启用轻量级迁移，新增可选属性无需手动迁移。

### Step 2: TodoTask 模型层

**`TodoTask+CoreDataClass.swift`** — 添加属性：
```swift
@NSManaged var imagesData: Data?
```

**`TodoTask+CoreDataProperties.swift`** — 添加计算属性（仿照 `remindersSet` 模式）：
```swift
var imagesArray: [Data] {
    get {
        guard let data = imagesData else { return [] }
        return (try? JSONDecoder().decode([Data].self, from: data)) ?? []
    }
    set {
        imagesData = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue))
    }
}

var hasImages: Bool { !imagesArray.isEmpty }
var imageCount: Int { imagesArray.count }
```

### Step 3: ImageCompressor 工具

**新建文件**: `Utils/ImageCompressor.swift`

- `compress(_:maxDimension:quality:) -> Data?` — 同步压缩
- `compressAsync(_:maxDimension:quality:) async -> Data?` — 后台线程压缩
- 参数：`maxDimension = 1024`, `quality = 0.7`
- 单张约 100-300KB，9 张最坏约 2.7MB，Core Data 可承受
- 使用 `Logger` 记录错误，不使用 `print()`

### Step 4: TodoRepository API

**`createTask`** — 新增参数 `images: [Data]? = nil`：
```swift
if let images = images, !images.isEmpty {
    task.imagesArray = images
}
```

**`updateTask`** — 新增参数 `images: [Data]? = nil`：
```swift
if let images = images {
    task.imagesArray = images
}
```

### Step 5: AddTaskSheet 图片选择区

**新增状态**：
```swift
@State private var selectedImages: [UIImage] = []
@State private var selectedPhotoItems: [PhotosPickerItem] = []
```

**UI 布局** — 在 `descriptionSection` 和 `checklistSection` 之间插入 `imageSection`：
- 标签："图片（可选）"
- 3 列 LazyVGrid 展示缩略图
- 每张缩略图右上角有删除按钮
- 最后一个位置是 "+" 添加按钮（当 `count < 9` 时显示）
- 使用 `.photosPicker` modifier 弹出系统相册选择器
- 需要 `import PhotosUI`

**选择即压缩**：`onChange(of: selectedPhotoItems)` 中立即压缩图片，避免内存压力

**编辑模式**：`init` 中从 `task.imagesArray` 加载已有图片到 `selectedImages`

**保存时**：将 `selectedImages` 的压缩 Data 传入 `repository.createTask/updateTask`

### Step 6: TaskDetailView 图片展示

**在 `taskInfoCard` 之后添加图片卡片**（仅当 `task.hasImages` 时显示）：
- 卡片标题："图片" + 数量
- 水平滚动缩略图（可点击查看大图）
- 点击缩略图 → 打开 `TaskImageGalleryView` 全屏预览

### Step 7: TaskImageGalleryView 全屏浏览器

**新建文件**: `Views/Tasks/TaskImageGalleryView.swift`

- `TabView` + `.tabViewStyle(.page)` 实现左右滑动
- 页码指示器："2/5"
- 支持双指缩放（MagnifyGesture 或 UIScrollViewRepresentable）
- 关闭按钮 + `.swipeBackToDismiss`
- 黑色背景

---

## 关键设计决策

| 决策 | 选择 | 原因 |
|------|------|------|
| 存储格式 | Transformable (JSON 编码 `[Data]`) | 与 `reminders` 一致，支持变长数组 |
| 图片压缩 | 1024px / JPEG 0.7 | 平衡质量与体积，单张 100-300KB |
| 选择器 | PhotosPicker (iOS 16+) | 无需相册权限，系统级 UI |
| 压缩时机 | 选择后立即压缩 | 避免内存中持有 9 张原图 |
| 重复任务 | 不复制图片到新实例 | 图片属于特定任务实例 |

## 迁移安全

- 新属性 `imagesData` 为可选、无默认值
- 项目已启用 `NSMigratePersistentStoresAutomaticallyOption` + `NSInferMappingModelAutomaticallyOption`
- 轻量级迁移自动处理，已有任务 `imagesData = nil` → `imagesArray = []`
- 无 `.xcdatamodeld` 文件，模型在代码中定义，启动时自动重建

---

## 验证方案

1. **编译验证**: `Cmd+B` 确认无错误无警告
2. **Core Data 迁移**: 启动 App，确认已有任务正常显示、不崩溃
3. **新建任务 + 图片**: 选择 1-9 张图片 → 保存 → 检查图片显示
4. **编辑任务 + 图片**: 编辑已有图片的任务 → 增删图片 → 保存 → 验证更新
5. **全屏预览**: TaskDetailView 点击图片 → 左右滑动 → 缩放 → 关闭
6. **边界情况**: 不选图片保存、选满 9 张后添加按钮隐藏、删除所有图片
