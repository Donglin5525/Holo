# G0 盘点 · iOS 侧（2026-10-23，只读代理产出）

ROOT = `Holo/Holo APP/Holo/Holo/`（工作区相对路径，下同）

## 1. 三域数据字段真源

### 1.1 想法（Thought）

实体定义：`ROOT/Models/CoreDataStack+ThoughtEntities.swift`（程序化模型）；实体类：`ROOT/Models/Thought+CoreDataClass.swift`

| 字段 | 属性名 | 证据 |
|---|---|---|
| 正文 | `content: String` | CoreDataStack+ThoughtEntities.swift:31-36；Thought+CoreDataClass.swift:19 |
| 创建时间（=发生时间） | `createdAt: Date` | CoreDataStack+ThoughtEntities.swift:38-43 |
| 修改时间 | `updatedAt: Date` | CoreDataStack+ThoughtEntities.swift:45-50 |
| 软删除（旧） | `isSoftDeleted: Bool` | 同上：71-76 |
| 归档 | `isArchived: Bool` | 同上：78-83 |
| 统一软删除 | `deletedAt`/`deletedBatchId`（`makeSoftDeleteAttributes()`） | 同上：910-917；`ROOT/Models/CoreDataStack.swift:737-749` |
| 正文版本 hash | `indexRequestedHash` / `indexCompletedHash` | 同上：138-149 |
| AI 整理状态 | `organizedStatus`（unprocessed/pending/…/excluded） | 同上：86-91；EditorCommit 回 pending 口径 `Data/Repositories/ThoughtRepository+EditorCommit.swift:74-85` |
| 标签关联 | `tags`（镜像）+ `tagAssignments`（事实源，ThoughtTagAssignment：source/confidence/assignedAt/rejectedAt/indexVersion/evidenceQuote/basisTextHash/indexState） | 同上：327-397；Thought+CoreDataClass.swift:40-46 |
| 主题关联 | `topics` + `topicLinks`（ThoughtTopicLink，含 basisTextHash/consentGeneration） | 同上：615-673、695-782 |
| AI 可见性口径 | `ThoughtAIAudience.aiVisiblePredicate()`（用户关联标签 excludeFromAI 子查询）、`processablePredicate`、`isExcluded`、`aiVisibleOnly` | `ROOT/Services/Thoughts/ThoughtAIAudience.swift:29-34、43-47、50-57、60-62` |

- **updatedAt 可作 sourceRevision**：有，但非自增版本号——只在有实质变化时手写（EditorCommit.swift:68-72「无变化不写 updatedAt」；delete 时也写，ThoughtRepository.swift:449）。更稳的版本语义是 `indexCompletedHash`/`basisTextHash`（内容 hash 口径）。
- **recordedAt 与 occurredAt 是否分开**：未分开。Thought 只有 createdAt，无独立发生时间字段（未找到）。

### 1.2 任务（Todo）

实体定义：`ROOT/Models/CoreDataStack+TodoEntities.swift`；仓库：`ROOT/Models/TodoRepository.swift`（`@MainActor class TodoRepository`，:26）

| 字段 | 属性名 | 证据 |
|---|---|---|
| 标题 | `title` | CoreDataStack+TodoEntities.swift:145-150 |
| 描述 | `desc` | 同上：152-156 |
| 状态 | `status`（默认 "todo"）+ `completed: Bool` | 同上：158-163、223-228 |
| 完成时间 | `completedAt` | 同上：230-234 |
| 截止 | `dueDate` + `isAllDay` | 同上：190-201 |
| 计划时间段 | `plannedStart`/`plannedEnd`（与 dueDate 语义分离） | 同上：203-214 |
| 创建/修改时间 | `createdAt` / `updatedAt` | 同上：269-281 |
| 删除 | `deletedFlag` + `deletedAt` | 同上：243-267 |
| 轻重缓急 | `importanceRaw`/`urgencyModeRaw`（与旧 `priority` 并存） | 同上：165-188 |
| 来源溯源 | `aiSourceMessageId`/`aiSourceItemId`、`sourceAnniversaryId`、`sourceTextSnippet` | 同上：250-261、328-340 |
| 执行版本 | `executionSchemaVersion`、`activeExecutionRevisionID` | 同上：345-357 |
| 子任务 | CheckItem（title/isChecked/order/isWaiting），关系挂 TodoTask | 同上：404-450 |
| 目标关联 | `taskGoalRelation.name = "goal"`（TodoTask→Goal 多对一） | 同上：745-766 |
| 想法来源 | `createdTasks`（Thought↔TodoTask） | 同上：768 起 |

- **updatedAt**：有（:276-281），可作 sourceRevision。
- **recordedAt/occurredAt**：createdAt（记录）与 completedAt（完成事件）分离；无独立「任务发生时间」（dueDate 是计划口径）。

### 1.3 习惯（Habit）

实体定义：`ROOT/Models/CoreDataStack+HabitEntities.swift`；仓库：`ROOT/Models/HabitRepository.swift`（:31）

| 字段 | 实体.属性名 | 证据 |
|---|---|---|
| 习惯定义 | Habit: `name`/`icon`/`color`/`type`(0 打卡 1 数值)/`frequency`/`targetCount`/`targetValue`/`unit`/`aggregationType`(0 SUM 1 LATEST)/`isBadHabit` | CoreDataStack+HabitEntities.swift:34-108 |
| 状态 | `isArchived`/`isPaused`/`pausedUntil` | 同上：111-131 |
| 结算口径 | `dayEndHour`/`dayEndMinute`（归昨天规则见 HabitDayAttribution） | 同上：171-184 |
| 创建/修改时间 | Habit.`createdAt` / Habit.`updatedAt` | 同上：187-200 |
| 打卡事件 | HabitRecord: `habitId`、`date`（发生时刻，精确到秒）、`isCompleted`、`value`、`note`、`isRetroactive`（补签）、`createdAt` | 同上：210-270 |
| 软删除 | Habit/HabitRecord 均 `deletedAt`/`deletedBatchId` | 同上：316-319 |
| 目标字段 | Habit.`goal`（多对一）↔ Goal.`habits` | 同上：296-315 |
| 日确认 | HabitDailyConfirmationMO（day/confirmedAt/statusRaw/recordDigest） | 同上：349-360、377-404 |
| 打卡写入点 | `toggleCheckIn`、`addNumericRecord`、`deleteRecord` | HabitRepository.swift:564-636 |

- **updatedAt**：Habit 定义实体有（:195-200）；**HabitRecord 事件实体没有 updatedAt，只有 createdAt**（:265-270）——事件级 sourceRevision 缺口。
- **recordedAt/occurredAt**：HabitRecord **已分开**（`date`=发生，`createdAt`=记录），且补签用 `isRetroactive` 区分。

## 2. 变更/删除通知与排除清理

| 域 | 通知名 | 定义 | 发出点 |
|---|---|---|---|
| Todo | `.todoDataDidChange` | TodoRepository.swift:18 | `notifyDataChange()` :1068-1078（所有本地写 + Cloud 同步刷新 :120 统一走此口）；`.holoTaskChange` :1116-1119（Matter 联动 typed change） |
| Habit | `.habitDataDidChange` | HabitRepository.swift:18 | `notifyDataChange(habitId:)` :1527-1535（object=habitId）；远程变更防抖后 :162；deferred setup :126；`.holoHabitCheckinDidRecord` :23（打卡/数值埋点，:583-588、596-601、621-626） |
| Thought | `.thoughtDataDidChange` | ThoughtRepository.swift:17 | 附件增删 `Data/Repositories/ThoughtRepository+Attachments.swift:51,75,94`；编辑器 UI 层 `Views/Thoughts/ThoughtEditorView.swift:307,364,582,684`；模块清空 `Services/RecycleBinService.swift:642-646`。注意：**Repository 主文件与 EditorCommit 本身不发此通知** |

- **删除路径**：Thought 软删 = `delete()` 置 `isSoftDeleted`+`deletedAt`（ThoughtRepository.swift:438-452），硬删 `hardDelete()` :465。
- **ThoughtAIExclusionService**（`ROOT/Services/Thoughts/ThoughtAIExclusionService.swift`）：
  - 变更通知方式：不依赖 UI 通知，由 **ChangeFeed 监听 Core Data 保存通知**驱动——`Services/AI/SemanticV3/ThoughtSemanticChangeFeed.swift:41-53` 监听 `NSManagedObjectContextDidSave`/`NSPersistentStoreRemoteChange`/`.holoAIDataProcessingConsentDidChange`；`handleSave` :58-94 把命中排除的想法交给 `ThoughtAIExclusionService.reconcile`（:85-89）。
  - 旧派生摘要清理：`purgeSemanticArtifacts` :172-191——向量库 `tombstoneItem`（`Services/AI/SemanticV3/ThoughtSemanticStore.swift:324`）+ 内存索引 `remove` + `HoloLongTermMemoryStore.deleteMemories` + `repository.deleteRecordsDerived(fromThoughtIDs:)`（`Services/AI/MemoryRepository/CoreDataHoloMemoryRepository.swift:553-582`，按 evidenceRefs lineage 级联删 crossDomain 记录）。
- **可借鉴的「派生数据失效」机制**（现成三套）：
  1. ChangeFeed 事件源模式（保存通知统一入队 + hash 去重 + 撤权 `consentGeneration` 作废，ThoughtSemanticChangeFeed.swift:1-14、ThoughtTopicLink.consentGeneration 于 +ThoughtEntities.swift:757-762）；
  2. `Topic.topicRevision`/`summaryBasisRevision` 版本失效（+ThoughtEntities.swift:503-528「标题、成员或用户决定变化时递增，AI 侧据此失效摘要」）；
  3. `HoloMemoryDirtyRegistry` 领域级 dirty+sourceDigest 压缩（`Services/AI/MemoryObservation/HoloMemoryDirtyRegistry.swift:22-44`）。

## 3. 现有 HoloAI 设置与开关现状

| 入口 | 位置 | 存储键 | Release 可达？ |
|---|---|---|---|
| 全局授权「HoloAI 数据授权」 | SettingsView.swift:863-875（aiOrganizationSection 内，section 定义 :848-900，主列表挂载 :243）→ sheet `AIDataProcessingConsentView` | `HoloAIDataProcessingConsent`，UserDefaults 键 **`holo_ai_dataProcessingConsentGranted`**（Models/AI/HoloAICapability.swift:40），变更发 `.holoAIDataProcessingConsentDidChange`（:30-34、52-61） | **是** |
| 想法设置（整理/主题/标签） | SettingsView.swift:877-881 → `ThoughtOrganizationSettingsView` | 见下两行 | 是 |
| 自动整理/新主题/相关笔记开关 | Views/Thoughts/ThoughtOrganizationSettingsView.swift:6-8 | @AppStorage：`thoughts.automaticOrganization.enabled`、`thoughts.automaticTopics.enabled`、`thoughts.relatedNotes.enabled`（Services/AI/SemanticV3/ThoughtSemanticFeatureFlags.swift:5-7） | 是 |
| 「AI 分析范围」标签排除 | Views/Thoughts/ThoughtAIScopeSettingsView.swift:11（入口 ThoughtOrganizationSettingsView.swift:142） | **无 UserDefaults 键**；落库 `ThoughtTag.excludeFromAI`（CoreDataStack+ThoughtEntities.swift:284-289），写入口 `ThoughtAIExclusionService.setTagExcluded`（:31-42；UI 调用 ThoughtAIScopeSettingsView.swift:152,163） | 是 |
| AISettingsView（Provider/Key/模型/Agent 调试） | Views/Settings/AISettingsView.swift——**整文件 #if DEBUG（:9 与 :345）** | AIConfigViewModel（Keychain） | **否，Debug 限定**。入口三处均 DEBUG：ChatView.swift:333-341（顶部导航按钮 Release 传空操作）+ sheet case :766-772（#if DEBUG）；SettingsView.swift:1104-1118（开发者折叠区）；MemoryGalleryView.swift:106-112 |
| 长期记忆两开关 | Views/Personal/PersonalMemorySettingsView.swift:37-44（自动形成记忆）、:49-56（记忆辅助回答），绑 `HoloMemorySettings.shared` | `holo_memory_automaticMemoryEnabled_v2`、`holo_memory_assistedAnsweringEnabled_v2`（HoloAICapability.swift:103-104；旧键迁移 :107-110、75-94） | 是（Views/Personal/PersonalView.swift 挂载） |
| 周月回放提醒 + 后台自动生成 | Views/Settings/SettingsView.swift aiPlaybackSection :904-956（挂载 :246）；通知中心版 Views/Settings/NotificationSettingsView.swift:746-800（AI 回放详情页：周开关 :762-766、周时间行 :770+/803 起、月开关 :778-784、月时间行 :786+） | MemoryInsightScheduleSettings.swift:22-30：`memoryInsight_weeklyReminderEnabled/Weekday/Hour`、`memoryInsight_monthlyReminderEnabled/Day/Hour`、**`memoryInsight_backgroundAutoGenerationEnabled`**；默认周关（周一 9 点）、月关（1 日 9 点）、后台关（:109-115） | 是 |
| 回放通知注册 | didSet 触发 `MemoryInsightNotificationService.scheduleWeeklyReminder/scheduleMonthlyReminder`（Services/AI/MemoryInsightNotificationService.swift:49-80、92-123，identifier `weeklyReminder` :67 / `monthlyReminder` :110；通知只提醒不生成） | — | 是 |

## 4. 周观察/日/月回放自动触发点（验证缺口）

文件：`ROOT/Services/AI/MemoryInsightBackgroundService.swift`

| 分支 | 类型 | 控制开关 | 证据 |
|---|---|---|---|
| BGAppRefreshTask `com.holo.app.memoryInsightRefresh` | 后台 | 注册 :44-54；调度 :57-76（最早 1h、quota 冷却、谷窗 `HoloAIWindowPolicy.nextValleyStart()` :62-68） | 调用点 HoloApp.swift:299 |
| **每周观察（weekly）** | 后台+前台两路 | **只受全局授权 + 有效记录资格 + 重试/额度冷却控制，不受 backgroundAutoGenerationEnabled** | 后台：:108-111 在 :118-122 的 `backgroundAutoGenerationEnabled` 闸**之前**；前台补偿：:221-224 在 :228 闸之前；闸内实现 :294-334（consent :299、`EffectiveRecordDayService` 资格 :302-306、重试预算 :336-371） |
| 日洞察（daily） | 后台+前台 | `backgroundAutoGenerationEnabled` | :118-150（后台）、:228-256（前台） |
| 月洞察（monthly，智能回退上月） | 后台+前台 | `backgroundAutoGenerationEnabled` | :157-186、:260-288 |
| 前台补偿入口 | 前台 | `checkForegroundCompensation()` :200-289（用户主动回放让位 :212-215） | HoloApp.swift:300（启动）、:414（回前台） |
| 额度冷却 | — | `holo.memoryInsight.automaticQuotaCooldownUntil`（:24、:376-410）；weekly 重试键 `holo.weeklyObservation.retry.*`（:21-23） | — |

调用关系：`HoloPeriodReplayCoordinator`（Services/AI/Insight/HoloPeriodReplayCoordinator.swift，start :161，直接持有 `MemoryInsightRepository` :121/263/319）是**用户主动**回放通道；`MemoryInsightRepository`（Data/Repositories/MemoryInsightRepository.swift，fetchInsight :28/42、saveGenerating :133、saveReady :163、saveFailed :184）是唯一落库口。**验证结论：预期缺口 ③ 成立——weekly 自动生成不受 `backgroundAutoGenerationEnabled` 控制**（注释自述「上周洞察是产品基础能力，不依赖 legacy 日/月后台生成开关」:107）。溯源先例：MemoryInsight 实体有 `sourceSnapshotHash`（Models/MemoryInsight.swift:26）。

## 5. capability 与「今日状态」

- `ROOT/Services/AI/HoloAICapabilityProvider.swift`（全文 110 行，纯静态 enum）：`emptyStateCapabilities` :29-73（今日状态常驻 :44-50）；**`persistentCapabilities` :78-109 为硬编码四项数组**（深度分析/今日状态/周期回放/规划目标），无注册机制。
- 模型：`ROOT/Models/AI/HoloAICapability.swift:11-26`（`HoloAICapabilityID` 六枚举 + struct）。同步机制：无远端同步，纯本地静态。
- **今日状态生成方式**：点击只**预填问句**不发送（ChatViewModel.swift:3963-3969「确认权原则」），用户发送后走普通 `chatStreaming` → HoloBackendAIProvider——即回答是 **AI 调用**，非本地规则。本地规则解析器 `Services/AI/TodayStateResolver.swift:20+` 在 App target 内**无任何调用方**（grep 仅命中自身；记忆长廊用的是 `DailySenseStateBuilder`，MemoryGalleryViewModel.swift:869）。
- ChatView 消费点：`ChatViewModel.swift:110-131`（@Published，:130-131 从 Provider 拉取）；常驻建议行渲染在 **`Views/Chat/QuickActionBar.swift:18-50`**（ForEach 胶囊，:29-33 深度分析箭头特判），挂载于 **ChatView.swift:975**；空态卡渲染 `Views/Chat/ChatEmptyStateView.swift:50-65`；tap 分发 `ChatViewModel.swift:3956-3985`。**ChatView.swift 共 1394 行**（wc -l）。

## 6. 后端通信与身份

`ROOT/Services/AI/HoloBackendAIProvider.swift`（`@MainActor`，:12）：

- **端点清单**：通用 chat `/v1/ai/chat/completions`（buildRequest :531-568，path :550）；专用无状态端点 `/v1/thoughts/organize` :329-342、`/v1/thoughts/semantic-relate` :346-359、`/v1/thoughts/category-brief` :363-376、`/v1/thoughts/topic-summary` :380-393、`/v1/thoughts/insight` :398-411、`/v1/thoughts/topic-name` :415-428、`/v1/ai/embeddings` :262-282；purpose 枚举 :720-754。
- **鉴权 header**：`Content-Type` + `X-Holo-Device-Id`（:552-555）；会话 Bearer 由 `APIClient.swift:69,147` 统一调 `HoloDeviceSessionManager.attachAuthorization`（Services/Network/HoloDeviceSessionManager.swift:57-64）注入；Ed25519 挑战-签名换短效 JWT（:141-186，`/v1/auth/device/session`+`/challenge`），401 刷新重试一次（APIClient.swift:83-89、292-297）。**iOS 无账号登录体系**——身份=设备：`HoloBackendDeviceIdentity`（HoloBackendAIProvider.swift:847-936，键 `holo.backend.deviceId` :850，Keychain>iCloud>新生成 三级 ：870-898）；未找到 holoSession/user 账号会话（未找到）。
- **response format 处理**：`.jsonObject` 按需传（:54-56、:291）；推理模型不强制 json_object（:130-131、:219-222）；围栏 JSON 容错解析 `extractJSON` :704-717。
- **取消机制**：流式 `onTermination → task.cancel` 真中断（:171-175、:504-509）；APIClient 对 `.cancelled` 不重试（APIClient.swift:109-115、198-207、226-231）。
- **quota 错误模式**：`HoloQuotaError.decode`（APIClient.swift:267-269；定义 Services/Subscription/HoloQuotaError.swift:10）；响应头 `X-Holo-Quota-Type` → `HoloSubscriptionService.refreshStatus()`（HoloBackendAIProvider.swift:296-298、516-518）；自动任务侧冷却 `recordAutomaticQuotaCooldown`（MemoryInsightBackgroundService.swift:397-410）。
- 授权总闸：`ensureDataProcessingConsent` :525-529。设备会话管理器全文见 Services/Network/HoloDeviceSessionManager.swift（cooldown :28-29、并发去重 :41）。

## 7. 可复用检索/证据工具

| 组件 | 类名 | 文件：行号 | 复用判定 |
|---|---|---|---|
| 本地向量库（想法） | `ThoughtEmbeddingStore`（actor，JSON 落盘、contentHash/modelVersion 失效、余弦暴力 top-K） | Services/AI/ThoughtEmbeddingStore.swift:14-79 | **可直接复用** |
| 语义库墓碑 | `ThoughtSemanticStore.tombstoneItem` | Services/AI/SemanticV3/ThoughtSemanticStore.swift:324 | 可直接复用 |
| 全文检索 | `ThoughtRepository.search`（Core Data `CONTAINS[cd]`） | Data/Repositories/ThoughtRepository.swift:205-244 | 可直接复用（SQLite FTS **未找到**，无 FTS/embedding 之外的独立索引） |
| 证据导航 | `HoloContextEvidenceNavigator` | Services/AI/PersonalContext/HoloContextEvidenceNavigator.swift:13 | 算法可借鉴 |
| 上下文检索服务 | `HoloContextRetrievalService` + `HoloContextSemanticSearchProviding` | Services/AI/PersonalContext/HoloContextRetrievalService.swift:20,29,53 | 可直接复用 |
| 语义检索运行时 | `HoloContextSemanticSearchProvider`/`HoloContextEmbeddingFilePersistence`/raw 回退 | Services/AI/PersonalContext/HoloContextSemanticSearchRuntime.swift:50,86,234；`HoloContextEmbeddingStore` :88（EmbeddingStore.swift） | 可直接复用 |
| 来源读取/分段/分页 | `HoloContextSegmenter`/`HoloContextSourceIndex`/cursor 分页 | Services/AI/PersonalContext/HoloContextSourceReader.swift:19,51,211-291 | 可直接复用 |
| 权限过滤 | `HoloContextAccessPolicy`/`HoloContextAccessGuard`（排除原因枚举） | Services/AI/PersonalContext/HoloContextAccessPolicy.swift:29,44,149 | 算法可借鉴（面向 personalContext 域） |
| 证据血缘 | `HoloEvidenceLineageResolver` | Services/AI/MemoryFusion/HoloEvidenceLineageResolver.swift:10 | 可直接复用（发现溯源直接对口） |
| 记忆查询/访问闸 | `HoloMemoryQueryService`、`HoloMemoryAccessPolicy` | Services/AI/MemoryQuery/HoloMemoryQueryService.swift:47；HoloMemoryAccessPolicy.swift:33 | 可直接复用 |
| 脏区注册表 | `HoloMemoryDirtyRegistry.markDirty(sourceDigest:)` | Services/AI/MemoryObservation/HoloMemoryDirtyRegistry.swift:22-44 | **可直接复用（作发现失效信号）** |
| 观察执行器 | `HoloDomainMemoryObserverExecutor`/`HoloMemoryObserverService`（tier2 评分触发） | Services/AI/HoloMemoryObserverService.swift:50,134,254-282 | 算法可借鉴 |
| 主题索引 | `ThoughtTagIndexProjection`、`ThoughtRepository+IndexV2.swift`、`ThoughtTopicLinkProjection` | Services/Thoughts/ThoughtTagIndexProjection.swift；Data/Repositories/ThoughtRepository+IndexV2.swift | 算法可借鉴（basisTextHash 失效口径，+ThoughtEntities.swift:385-390） |

## 与实施假设的冲突/缺口清单

1. **①今日状态常驻入口「可被替换」——部分成立，需注意**：常驻行是 `persistentCapabilities` 的**硬编码四项数组**（HoloAICapabilityProvider.swift:78-109），不是可插拔注册表；替换/插入「一个发现」要改 Provider 数组 + `ChatViewModel.handleCapabilityTap` 的 switch（:3956-3985）+ 空态卡（emptyStateCapabilities 也单独含今日状态，:44-50）。今日状态目前**只是预填问句的 AI 问答**，不是本地规则卡片；本地规则版 `TodayStateResolver` 是死代码（无调用方）——没有卡片可替换，只有一个胶囊入口。
2. **②AISettingsView 整个 #if DEBUG——与预期一致，已证实**（AISettingsView.swift:9/345；三个入口 ChatView.swift:333-341+766-772、SettingsView.swift:1104-1118、MemoryGalleryView.swift:106-112 均 DEBUG 限定）。
3. **③周观察不受 backgroundAutoGenerationEnabled 控制——与预期一致，已证实为缺口**（MemoryInsightBackgroundService.swift:108-111 与 :221-224 均在 :118/:228 闸之前）。
4. **④三域实体有 updatedAt——实体级成立，事件级不成立**：Thought/TodoTask/Habit 的 updatedAt 都有；但 **HabitRecord（打卡事件）只有 createdAt 无 updatedAt**，CheckItem 子任务同样没有。且 updatedAt 是手动维护的 Date 非自增版本——建议复用现成 contentHash/basisTextHash 口径 + topicRevision/sourceSnapshotHash 版本口径。
5. **补充缺口 A（发生时间）**：Thought 无独立 occurredAt，只有 createdAt；「从想法取材」只能以 createdAt 为发生时间口径。
6. **补充缺口 B（通知口径不统一）**：三域通知名各异且语义不同——Todo/Habit 走 Repository 显式 `notifyDataChange`，Thought 的 Repository 主写路径不发通知、AI 链路实际依赖 `ThoughtSemanticChangeFeed` 监听 **Core Data 保存通知**。「一个发现」的失效信号建议直接挂保存通知/DirtyRegistry，而非三域 UI 通知。
7. **补充缺口 C（无账号身份）**：iOS 无账号会话，只有 deviceId+设备会话 JWT（HoloDeviceSessionManager.swift）；若「发现」需要跨设备一致的用户身份或服务端配额口径，现有 X-Holo-Device-Id/Bearer 设备会话是唯一身份通道。
8. **补充缺口 D（本地检索）**：无 SQLite FTS；全文检索只有 Core Data `CONTAINS[cd]`（ThoughtRepository.swift:205），语义检索依赖后端 `/v1/ai/embeddings` + 本地 `ThoughtEmbeddingStore` 余弦暴力扫描（千条规模）。
