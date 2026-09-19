# Findings: Holo 用户头像全局一致性方案

## 工作区保护

- 当前仓库存在大量并行未提交改动。
- 已按头像功能的精确文件清单增量实施；未清理、回滚、提交或夹带现有并行改动。

## 实施结论

- 已建立一份全局用户头像：设置与个人页共用同一个编辑器，Apple 登录账号卡与 Holo AI 用户消息共用同一展示组件。
- 用户可从相册选择或拍照，进入圆形蒙版裁剪页后拖动、缩放，并查看 32/56/80pt 三档实际效果。
- 原图进入裁剪前降采样，最终只保存 512×512 JPEG，限制 512KB，并通过重新渲染剥离 GPS/EXIF；不保存原图。
- 头像存于 Core Data 私有 CloudKit 镜像，显式同步 custom/removed 状态；退出 Apple 登录不移除头像，删除账号与数据会删除头像。
- 已完成主 App + Widget 构建、16 项纯几何断言及 2 项 XCTest；Production CloudKit schema、真机相册/相机和双设备同步仍是发版验收门。

## 第一轮代码搜索

- Apple 登录由 `Services/Auth/AppleSignInAuthService.swift` 管理，请求范围只有 `.fullName` 与 `.email`；现有本地会话 `HoloAuthSession` 包含 userIdentifier、fullName、email、authorizationCode、identityToken，没有头像字段。
- 设置页存在两处账号视觉：设置页头部固定 `person.crop.circle`，Apple 登录状态行使用固定 `person.crop.circle(.badge.checkmark)`，尚未发现实际用户图片。
- 个人页也存在固定 `person.crop.circle`，需要确认它是 HoloProfile 编辑入口还是账号入口。
- 工程已有稳定的 `PhotosPicker` 和相册图片加载能力，可复用图片读取链路；但附件图片存储不宜直接复用为头像数据模型。
- 需要收窄搜索范围排除 build 产物；首次宽搜索被后端长 Prompt 与构建索引放大，但未造成代码或状态改动。

## 当前产品链路初判

- Holo AI 对话中确实有独立用户头像视图 `MessageBubbleView.userAvatar`，当前是固定的 `person.fill`；这正是上传头像后最直接需要替换的消费点。
- AI 自己的头像/标识由 `aiHeader` 单独负责，需保持为 Holo 品牌标识，不能被用户头像覆盖。
- 设置页已有“昵称”编辑与“Apple 登录账号卡”两个相邻但割裂的身份入口；个人页也有昵称入口。方案应避免再增加第三套资料状态。
- Apple 登录只提供姓名和邮箱，现有代码没有、Apple 授权范围也不提供用户头像。所谓“Apple 登录预置头像同步更改”应理解为：账号卡里当前的系统占位头像改为 Holo 用户头像，而不是从 Apple 获取或回写 Apple ID 头像。
- 昵称已经形成统一写入口：`UserPreferenceRepository.setDisplayName` 同时更新本地设置和 iCloud 键值存储；头像应复用这一“本地即时 + 云端同步”的产品语义，但二进制图片不适合直接塞进现有昵称字符串通道。
- HoloProfile 是给 AI 使用的 Markdown 个人档案，不应拿来保存 UI 头像，避免身份资料与 AI 语义档案耦合。

## 现有架构可复用点与边界

- `MessageBubbleView` 把 AI 头像（`sparkles`）与用户头像（`person.fill`）明确分开，替换用户头像不会影响 Holo 品牌头像。
- `UserPreferenceRepository` 是 Core Data + CloudKit 的字符串键值表，适合继续保存昵称、头像版本/状态等轻量元数据，但不适合把图片编码成大字符串。
- 工程已有成熟的图片压缩与正方形缩略图能力：`AttachmentFileManager` 可将原图压缩、居中裁剪生成缩略图；头像应抽取通用图像处理能力或建立专用 `UserAvatarImageProcessor`，不要让个人资料依赖“任务附件”命名与目录。
- 账号与本地数据删除会清空全部 Core Data，并删除 `Application Support/Holo`，因此若头像的本地缓存放在该目录，可自然进入账号删除闭环。
- 单纯把头像文件放 `Application Support/Holo` 只能本机保存，不能满足“随 iCloud 同步/重装恢复”；主数据仍需进入 CloudKit 同步层，本地文件只应作为解码缓存。
- 当前设置页默认选中“昵称”，适合升级成“个人资料”分组，统一管理头像与昵称；个人页的个人档案区可提供同一编辑入口或头像快捷入口，不能各自维护状态。

## 数据模型方向

- Core Data 已启用自动轻量迁移，并通过 `NSPersistentCloudKitContainer` 镜像到用户私有 iCloud。
- 任务与观点附件已经验证“Core Data Binary Data → CloudKit 同步”的工程路径，因此头像无需新建 Holo 账号后端上传接口；继续走用户自己的 iCloud，更符合 Holo 当前本地优先与隐私承诺。
- 推荐新增单例语义的 `UserAvatarEntity`，而不是扩展通用字符串表：固定逻辑键、处理后头像数据、revision、state 与 updatedAt。头像只需存一份经过裁剪压缩的小图，避免保存原图与不必要的隐私/空间成本。
- 不建议同时存“原图 + 缩略图”：头像展示最大约 56pt，保存 512×512 的单份 HEIC/JPEG 即可覆盖 Retina 与后续入口；对话中再由系统缩放到 32pt。
- 用户主动删除头像不能等价于把数据置空后忘记状态，否则旧设备可能把旧图重新同步回来；需要显式 `avatarState = custom | removed` 与 `avatarRevision/updatedAt`，把删除作为可同步的用户意图。
- 现有 Core Data 模型缺少显式版本文件，虽然支持轻量迁移，仍需把“旧库升级、CloudKit schema 初始化、双设备冲突”列为单独验收门，而不能只以本机编译通过视为完成。

## 全局展示点盘点

### 应替换为真实用户头像

1. `MessageBubbleView.userAvatar`：Holo AI 对话中每条用户消息右侧，32pt。
2. `SettingsView.userInfoCard`：Apple 登录/本机模式账号卡，56pt；上传后不论是否登录都展示同一 Holo 用户头像。
3. 设置页“个人资料”编辑区：作为头像的主入口，同时承载昵称。
4. `PersonalView` 的昵称/个人资料区域：展示当前头像并跳转同一编辑体验，不能复制第二套保存逻辑。

### 需产品化判断，推荐保持系统图标

- `BottomNavBar` 与 iPad `HoloSidebarView` 的“个人”图标：它们是导航语义和选中态，不是用户身份展示，保持 `person.fill` 可读性更稳。
- `ChatLogView` 的 person 图标：内部日志的角色标识，表示 user role，不表示具体用户。
- 记忆“个人档案”域、账号删除行、分类图标库中的 person 图标：都是功能/数据类型语义，不应替换成头像。
- 首页右上角齿轮实际打开设置，应保持齿轮，避免头像被误解为进入个人页；上传入口在设置内即可。

### Holo 品牌头像

- `MessageBubbleView.aiAvatar` 的 `sparkles` 属于 Holo AI 身份，保持不变；本功能只管理用户头像。

## 入口产品结构

- 设置页把当前“昵称”分组升级为“个人资料”，顶部放可点击头像（更换/移除）和昵称；这是唯一写入口。
- 个人页展示头像并进入同一个 `UserProfileEditorView`；设置页与个人页复用该组件与同一 ViewModel/Store。
- Apple 登录账号卡只消费头像，不承担另一份头像；登录/退出只改变认证状态，不清除头像。账号删除才清除头像。

## 权限、隐私与发布边界

- App 最低 iOS 17，现有 `PhotosPicker`、PhotoKit iCloud 原图下载和相机封装均可直接复用。
- 现有相机权限文案只写“为任务拍摄附件照片”，加入头像拍照后必须改成覆盖“头像或附件”的通用描述；相册读取文案已足够通用。
- 隐私政策当前没有“头像/个人资料图片”，需要补充：用户主动选择、仅用于身份展示、保存于本机及个人 iCloud、不发送给 AI 模型或 Holo 后端、可随时更换/移除/随账号数据删除。
- App Store 隐私标签需要在提审前重新评估，但不能仅因本地/私人 iCloud 保存就自动判定为开发者收集；必须按 Apple 当时的定义核对后再决定是否更新。
- 新增 Core Data/CloudKit 实体意味着：Debug 真机 Development 环境上报/干跑后，发版前必须在 CloudKit Console 部署到 Production。此操作是生产侧变更，需要东林另行确认，不能在实现阶段自动执行。
- 这是纯 iOS 与 CloudKit schema 改动，不需要 HoloBackend 发版，也不应新增头像上传 API。

## 测试基础

- Core Data 测试需复用 `CoreDataTestSupport.sharedModel/sharedTestContainer`，避免多容器模型映射歧义。
- 现有 Debug `initializeCloudKitSchema(options: [.dryRun, .printSchema])` 可作为 schema 门禁。
- `UserAvatarRepository` 初始化应在 `CoreDataStack.waitUntilReady()` 后，与 `UserPreferenceRepository.setup()` 同一应用启动阶段完成。

## 实施前基线

- `Holo` 主 target 使用文件系统同步分组，新建在 App 源码目录中的 Swift 文件会自动纳入编译，不需要改动当前已有大量并行变化的 `project.pbxproj`。
- `HoloTests` 仍是手动工程分组；本轮优先把可独立验证的裁剪几何做 standalone 断言，并以主 target 构建覆盖真实集成，避免把无关测试工程改动混进来。
- `CoreDataStack.swift` 当前包含并行进行中的共享模型重构与 Goal Workshop 实体，头像实体只做增量追加，不改写已有结构。
- `SettingsView.swift`、`PersonalView.swift`、`MessageBubbleView.swift` 均有并行改动；接入时只修改头像相关局部，保留内容宽度、滑返、目标卡片等现有变化。
- `Localizable.xcstrings` 当前存在超大规模未提交变化；本轮不机械重写该文件，新增界面先采用与现有页面一致的中文文案，避免扩大冲突面。正式提审前再做一次集中本地化收口。
- 启动初始化点已确认在 `HomeView.task`：Core Data ready 后依次 setup 各仓库，可在 `UserPreferenceRepository.shared.setup()` 相邻位置初始化头像仓库。
- 主数据模型当前通过唯一 `sharedDataModel` 构建；头像实体必须追加到 `makeDataModel()`，同时保持既有共享模型语义。
- 设置页与个人页当前各有独立昵称弹窗；实施时统一收口到 `UserProfileEditorView`，保留 `UserPreferenceRepository.setDisplayName` 作为唯一保存出口。
- 工程已有全局 `CameraView` 与 `PhotoLibraryImageLoader`，头像编辑器可直接复用相机回调和相册三层读取能力，不复制附件业务模型。
- 隐私政策的“主动提供信息、使用目的、iCloud 同步、用户权利”四处都需要头像说明；否则界面隐私提示与正式政策会不一致。
- 昵称当前不限制字符数，本功能继续复用原有规范化规则，不借头像需求额外改变昵称产品规则。
- `HoloWidgets` 手动共享完整 Core Data 程序化模型；任何新增实体的“实体描述文件 + NSManagedObject 类”都必须同时加入小组件 Sources，否则共享 `CoreDataStack` 无法编译，且两端模型也会不一致。
- `AccountDataDeletionService` 会遍历当前模型内所有非抽象实体逐对象删除，因此 `UserAvatarEntity` 已自然进入账号删除与 CloudKit 删除同步闭环，不需要新增白名单。

## 圆形头像裁剪补充（2026-09-19）

- 原计划的“自动中心裁剪”会错误假设主体总在照片正中，真人合照、侧身照和横图很容易截掉脸；该方案已被否决。
- 首版升级为用户可拖动、双指缩放的头像裁剪器。圆形蒙版表达最终可见范围，但长期保存仍是 512×512 方形 JPEG，展示层再统一 clip 为 Circle。
- 裁剪状态只在本次编辑期存在；不保存原图、不保存 crop 参数，不做人脸识别。
- 相机/高像素照片进入裁剪页前用 ImageIO 降采样到最长边 2048px，避免完整解码造成内存峰值。
- 必须同时预览 32pt、56pt、80pt 三种圆形尺寸，覆盖 Holo AI、Apple 登录账号卡和个人页实际效果。
