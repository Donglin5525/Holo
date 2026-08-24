# 数据清理与回收站（30 天缓冲）规划方案

- 日期：2026-08-24
- 状态：**已定稿（2026-08-24 东林拍板 D1–D7），开工实施中**
- 需求来源：东林提出——各模块（财务/想法/任务/习惯，健康不做）要有「清理所有记录」能力，设置页有「清空所有数据」；被删数据 30 天内可恢复，需规划与新数据的冲突处理。
- 代码探索结论日期：2026-08-24（两轮：数据层/删除逻辑/页面结构 + AI 数据深链跳转点）

---

## 1. 目标

1. **针对性清理**：财务 / 想法 / 任务 / 习惯 四模块各自可一键清空本模块记录；健康模块不参与（App 只读 HealthKit，本就不落库）。
2. **全局清理**：设置页提供「清空所有数据」。
3. **30 天缓冲期（回收站）**：**清空类删除**先进回收站，30 天内可恢复；到期自动真删。
4. **冲突处理**：恢复时若与删除后新产生的数据「撞车」，有明确的判定与用户决策流程。
5. **已清除感知（D6）**：模块数据被清后，AI 侧数据（记忆/卡片/深链）点击到已清除的原始数据时，明确提示「历史数据已被清除」。

## 2. 已拍板决策（2026-08-24）

| # | 决策 | 东林拍板 |
|---|---|---|
| D1 | 财务清空 | **提醒+咨询用户删减范围**：清空入口点进「范围选择页」（仅清交易 N 笔 / 全部含账户 M 分类 K 预算等），选择后再确认 |
| D2 | 清空所有数据范围 | **含**聊天记录、AI 报告、长期记忆、周计划 |
| D3 | 全局清空确认强度 | **手动输入「清空」二字二次确认**（专用确认页；模块级沿用 alert） |
| D4 | 想法清空入口 | 想法列表顶栏「…」菜单 |
| D5 | 回收站入口 | 仅设置页统一入口（模块内文案指路） |
| D6 | AI 记忆不连带清 | **不连带**；但数据清除后，AI 数据点击要显示「历史数据已被清除」，让用户有感知 |
| D7 | 单条删除不进回收站 | **不进**（回收站保持只放清空批次，避免冗余） |

## 3. 现状盘点（2026-08-24 探索结论）

### 3.1 数据层关键事实

- 单一主库 `HoloDataModel.sqlite`，**CloudKit 同步**（NSPersistentCloudKitContainer）；实体纯代码定义（`CoreDataStack+*.swift` 11 个文件），加字段=改工厂方法，轻量迁移。
- 记忆模块另有**独立本地库**（敏感记忆 `HoloSensitiveMemory.sqlite`，不进 CloudKit）。「清空所有数据」须一并处理（两个 context）。
- 全工程**无 `@FetchRequest`**，查询集中在 Repository 层；但 **AI 服务层约 10 个文件直查库**（UserContextBuilder、IntentRouter、TaskAnalysisContextBuilder、MemoryInsightContextBuilder、DailySenseStateBuilder、HoloThoughtReferenceDataSource、MemorySignalDataAdapter 等），加周边服务（TodoNotificationService、Daily/WeeklyBriefScheduler、HoloWidgetSnapshotService、AnniversaryTaskGenerator）——软删除过滤最易漏处，漏了会出现「AI/小组件读到已删数据」。
- 无 uniquenessConstraints；业务实体 id 均 UUID → 软删除方案下同 id 永远只有一条，恢复不存在主键冲突。
- 健康模块直读 HealthKit 不落库（健康类手动记录走数值习惯 HabitRecord，归习惯模块）。

### 3.2 各模块删除现状

| 模块 | 单条删除 | 清空全部 | 现状问题 |
|---|---|---|---|
| 任务 | 软删（deletedFlag+deletedAt，有 restore/clearTrash API 但 UI 零调用） | 无 | `TaskDetailView:356`「30 天可恢复」是空头支票；软删数据永远躺库无清理 |
| 想法 | 软删（isSoftDeleted 无时间戳，无恢复 UI；软删为保护 AI 引用不断裂） | 设置页「清除观点数据」硬删 6 实体+附件 | 同上，躺库无清理 |
| 纪念日 | 软删（isSoftDeleted 无时间戳） | 无 | 躺库无清理 |
| 财务 | 交易/账户/分类/预算硬删（账户/分类有占用保护） | 无 | — |
| 习惯 | 硬删（习惯 cascade 删打卡） | 无 | — |
| 聊天 | deleteMessage 硬删；clearAllMessages 硬删 | 无 | — |

### 3.3 可复用基建

- **财务判重引擎**：`importFingerprint`（`DataImportService.makeFingerprint`，日期|金额|类型|分类|账户，已建索引，可从存量反算）+ `BillDuplicateDetector`（金额+类型分组、日期就近一对一贪心配对，±1~2 天窗口）。→ 直接复用到恢复冲突预检。
- **批次先例**：`importBatchId` + `undoImportBatch` 整批撤回——回收站事件批次与此同构。
- **过期清理先例**：`ConvergenceRejectionRepository.purgeExpired()`；启动链维护模式（`recoverStaleProcessingThoughts`）；BGTask 两个先例（memoryInsightRefresh/spendingProjectRefresh）。
- **全量清空先例**：`AccountDataDeletionService`；想法 `deleteAllThoughtData()`。
- **附件生命周期先例**：任务 `permanentlyDeleteTask` 删附件目录、想法 `hardDelete` 删附件文件——沿用到物理清除时机。
- **深链基建**：`DeepLinkState` 单例（taskDetail/goalDetail/habitDetail/transactionDetail/thoughtDetail/…）+ `HomeView.handleDeepLink` 分发。
- **「已删除」兜底先例（D6 直接套用）**：① `CalendarEventDetailSheet` 预检+「原记录已删除」占位卡（最完整）；② `ThoughtDetailView` 引用预检+alert+快照；③ `GoalListView` 「目标不存在或已被删除」文案；④ 聊天卡 `isEntityDeleted` 预填置灰机制（Transaction/Task 已接，`ChatMessageRepository.prefillDeletionStates:1188-1262`），判定需升级为「查不到或 deletedAt!=nil」。

---

## 4. 总体设计

### 4.1 核心心智

「清空」统一两步：**进回收站（数据仍在、界面不显示、AI 不读取）→ 30 天后自动真删（连带附件文件）**。类比相册「最近删除」（UI 文案统一用「最近删除」）。

### 4.2 技术选型：统一软删除标记 `deletedAt` + `deletedBatchId`

全库统一约定：
- `deletedAt: Date?` — nil=正常；非 nil=已删除（值为删除时刻）。
- `deletedBatchId: UUID?` — 清空批次 id。**非 nil=清空类删除（回收站展示、可恢复）；nil=单条软删（不展示、不可恢复、30 天后物理清）**。

选同库软删除而非「导出副本再真删」：恢复=撕标签零成本、关系原封不动；同 id 唯一 → 冲突只剩内容撞车；CloudKit 下标记同步 → 回收站跨设备一致（A 清空 B 可恢复）；查询改造集中在 Repository（0 处 @FetchRequest）。

字段落地：
- `TodoTask` 已有 deletedFlag+deletedAt（兼容保留，统一以 deletedAt 为准）；
- `Thought` / `Anniversary` 补 deletedAt（旧 isSoftDeleted 一次性迁移：=YES 且无 deletedAt → 补迁移时刻）；
- 补 deletedAt 的实体：`Transaction` `Account` `Category` `Budget` `SpendingProject` `Habit` `HabitRecord` `Goal` `GoalMetricLog` `TodoList` `TodoFolder` `TodoTag` `ChatMessage` `MemoryInsight` `MemoryInsightFeedback` `Anniversary` + 记忆六实体（主库）+ 敏感库记忆实体 + LifePlan 六实体。

### 4.3 D7 落地：单条删除的统一规则

| 模块 | 单条删除行为（拍板后） |
|---|---|
| 财务 / 习惯 | **维持硬删**（现状，无感知变化） |
| 任务 / 想法 / 纪念日 | **维持软删**（技术必要：保护 AI 引用关系、通知联动），但收敛到 deletedAt 体系、无 batchId、回收站不展示；统一纳入 30 天过期物理清理（根治现状躺库积压） |

连带文案修正：`TaskDetailView:356`「任务将进入回收站，30 天后可恢复」→「删除后无法恢复」（现状本就无回收站 UI，文案与实现对齐）。

### 4.4 删除批次（回收站展示单元）：「按事件分组」

- 新增 `RecycleBinBatch` 实体（进 CloudKit）：`id(UUID)` `createdAt` `scope`（单模块清空/全局清空/财务档位）`modules`（涉及模块集合）`summary`（摘要文案）。条目全部物理清除后批次记录自删。
- 回收站 UI：**事件卡列表**（「8月24日 14:32 · 清空了财务数据 · 1,234 条 · 还剩 27 天」）→ 点开事件详情：模块分节 → 条目列表。支持整事件恢复 / 按模块恢复 / 单条恢复 / 立即清除。
- 跨设备：批次+标记随 CloudKit 同步；物理删除各设备各自执行、最终一致。

---

## 5. 功能范围界定

### 5.1 各模块清空范围

| 模块 | 范围 | 备注 |
|---|---|---|
| 财务 | **两档**（D1）：A 仅交易（含分期组/导入批次）；B 全部（交易+账户+分类+预算+固定支出项目） | 入口点进范围选择页（显示各档条数）→ 再确认 |
| 想法 | Thought+标签+主题+引用+标签分配（沿 deleteAllThoughtData 范围） | 附件文件保留至物理清除时再删 |
| 任务 | 所有正常状态任务（含归档）+清单/文件夹+标签；已在回收站的旧批次不动 | 清空时取消全部任务通知 |
| 习惯 | 习惯+全部打卡记录（含补记） | streak 恢复后自然重算 |

**模块数据 vs AI 资产口径**：模块自有的 AI 整理产物（想法的主题/标签分配）随模块清；跨模块 AI 资产（长期记忆 HoloMemory、AI 洞察、聊天记录）**不随模块清**（D6 不连带），仅「清空所有数据」时清。

### 5.2 「清空所有数据」范围（含 D2）

**含**：四模块全部 + 纪念日 + 目标（含量化日志） + 聊天记录（报告收藏/档案/回放随之，恢复即回） + AI 报告（MemoryInsight 及反馈） + 长期记忆（主库六实体+敏感独立库+记忆墓碑） + LifePlan 周计划。
**不含**：健康（只读 HealthKit）；App 设置（外观/通知/记账周期/严格预算/首屏图标配置）；iCloud 同步状态；登录态与订阅（≠删除账号）；回收站里已有的旧事件。
与「删除账号与 Holo 数据」区别：清空数据不注销、账号订阅设置保留、数据可 30 天恢复；UI 文案讲清。

---

## 6. 入口与交互设计

| 位置 | 入口 |
|---|---|
| 财务 → 设置 Tab →「数据管理」区 | 清空财务数据（→ 范围选择页） |
| 任务 → 归档管理页（扩展「归档与最近删除」提示） | 清空所有任务 |
| 习惯 → 设置 Tab 新增「数据管理」区 | 清空习惯数据 |
| 想法列表顶栏「…」菜单（D4） | 清空想法数据 |
| 设置页 → 新增「数据管理」子页 | ① 各模块数据概览 ② 清空所有数据 ③ **最近删除（回收站唯一入口，D5）** |

确认流程：
- 模块级：alert 二次确认（影响条数 + 「30 天内可在 设置→数据管理→最近删除 恢复」指路）。
- 财务：先范围选择页（D1）再 alert。
- **清空所有数据：专用确认页**——各模块影响条数清单 + **输入「清空」二字**（D3）→ 执行进度。
- 执行：后台 context 分批打标记（几万条级，流式先例），完成后广播各模块刷新通知。

---

## 7. 冲突处理规则（恢复时）

### 7.1 冲突分类

软删除下同 id 唯一，**无主键冲突**。真正的冲突两类：
- **C1 内容撞车**：删除后用户重新记了/导入了相似数据。
- **C2 依赖缺失**：恢复的记录其父对象还在回收站或已被彻底清除。

### 7.2 C1 内容判重（按模块指纹，默认策略=疑似重复跳过、保留现有，预览页可改判「仍然恢复」）

| 模块 | 精确指纹（默认跳过） | 宽松信号（标黄待定） |
|---|---|---|
| 财务·交易 | 复用 `importFingerprint` | `BillDuplicateDetector` 金额+类型+日期邻近 |
| 财务·账户/分类 | 同名同类型 | — |
| 任务 | 标题(trim)+截止日期 | 仅标题相等 |
| 想法 | 内容全文 | — |
| 习惯 | 名字+类型；打卡=habitId+日期 | — |
| 聊天/记忆/报告 | 不判重直接恢复 | — |

### 7.3 C2 依赖处理

- 整批恢复（主路径）：自动按依赖顺序——账户/分类→交易；习惯→打卡；任务→子任务；纪念日→其生成任务。
- 单条恢复遇父对象在回收站：提示联动恢复（「将同时恢复其所属账户」）。
- 父对象已被彻底清除：按既有 nullify 语义恢复为无归属，预览页明示。

### 7.4 恢复后联动

任务通知重排（rescheduleRemindersIfNeeded 先例）；习惯 streak/提醒重算；财务广播 financeDataDidChange 刷新统计与小组件快照；聊天卡删除态缓存刷新（refreshDeletionState 机制）。

---

## 8. D6 已清除感知（深链统一判定）

**统一规则**：任何「AI/聚合数据 → 原始数据」跳转，目标解析时 `记录不存在 || deletedAt != nil` → 显示「相关记录已被清除」提示（可恢复的批次数据附「可在 设置→数据管理→最近删除 恢复」指路，单删/已物理清除则纯提示）。

改造清单（基于 2026-08-24 深链探索）：

| # | 落点 | 现状 | 改造 |
|---|---|---|---|
| 1 | `FinanceView.swift:156` `.transactionDetail` 消费端 | fetch nil → sheet 静默不弹 | 弹「该交易已被清除」提示（toast/alert） |
| 2 | `HabitsView.swift:270-295` `.habitDetail` | guard 静默 / sheet 永久 ProgressView | 同上，提示后关闭 |
| 3 | `ThoughtDetailView`（thoughtId 无效时） | 近空白页 | 「该想法已被删除」占位卡 |
| 4 | `HoloMemoryRecordDetailView.handleEvidenceTap`（记忆证据跳转发起端） | 不校验直接发深链 | 跳转前按 sourceID 校验存在性，已清除则当前 sheet 内提示（不跳走）；消费端兜底仍保留 |
| 5 | `TaskListView` TaskNotFoundView | 「正在打开任务…」1.5s 自动关 | 文案改「该任务已被删除」后自动关 |
| 6 | `GoalListView:97` | 已有「目标不存在或已被删除」 | 保持 ✓ |
| 7 | `CalendarEventDetailSheet` | 已有完整「原记录已删除」占位 | 保持 ✓（判定补 deletedAt!=nil 分支） |
| 8 | 聊天卡 `prefillDeletionStates` | 硬删=查不到、软删=deletedFlag；anniversary 未接 | 判定统一「查不到或 deletedAt!=nil」；anniversary 接入预填；卡片置灰同时加「已删除」文字标签 |
| 9 | 洞察卡/回放卡 evidence | 纯文本无跳转 | 不动（无跳转则无感知问题） |

---

## 9. 30 天生命周期

```
清空 ──→ deletedAt=now + deletedBatchId=事件id ──→ 回收站事件卡可见可恢复
单删(任务/想法/纪念日) ──→ deletedAt=now（无batchId）───→ 不展示、30天后物理清
                    │
                    ├─ 30天内恢复（仅批次）──→ 清标记+冲突预检+联动 → 回正常视图
                    │
                    └─ deletedAt < now-30d ──→ 物理删除（CloudKit传播）+删附件/取消通知+批次自清
```

- 过期清理挂载：App 启动维护链（一期）；BGAppRefreshTask（二期）。
- 物理删除时才清磁盘：任务附件目录、想法附件文件。软删期间一律保留。
- 回收站每条显示「还剩 X 天」；可手动「立即清除」。

---

## 10. 技术实现要点

### 10.1 数据模型

- 各 `CoreDataStack+*.swift` 实体工厂补 `deletedAt(Date?)` + `deletedBatchId(UUID?)`；新增 `RecycleBinBatch` 实体；`applyIndexes` 为 deletedAt 建索引。轻量迁移。
- CloudKit：新字段随 App 发版更新 Apple 侧 schema（参考 docs/appstore-preflight/CloudKit-schema部署指南）；**无需后端发版**。敏感独立库同步加字段（无 CloudKit 顾虑）。

### 10.2 查询过滤改造清单（工程主体，防漏）

统一：所有面向用户/AI 的读取加 `deletedAt == nil`。建议各实体加静态 `notDeletedPredicate` / Repository 封装 fetch 工厂，杜绝散落手写。

1. Repository：FinanceRepository(+Accounts/+Categories/+Import/+Budget)、TodoRepository(+Kanban/+Stats)、HabitRepository、GoalRepository、AnniversaryRepository、ThoughtRepository（~20 处谓词合并）、ChatMessageRepository、MemoryInsight/Topic/LifePlan。
2. AI 服务层直查（~10 文件）：UserContextBuilder、DailySenseStateBuilder、TaskAnalysisContextBuilder、IntentRouter、MemoryInsightContextBuilder、MemorySignalDataAdapter、Agent/Tools 各 DataSource、HoloThoughtReferenceDataSource。
3. 周边服务：TodoNotificationService、Daily/WeeklyBriefScheduler、HoloWidgetSnapshotService、AnniversaryTaskGenerator、HomeScheduleService。
4. 模型便捷属性：`Goal.sortedTasks` 等内存过滤。
5. 聊天卡删除态预填升级（§8-8）。

### 10.3 新增服务与页面

- `RecycleBinService`：批次创建（打标记）、恢复（依赖排序+冲突预检+联动）、立即清除、过期清理、条数统计；支持主库+敏感库双 context。
- 冲突预检：财务复用 makeFingerprint+BillDuplicateDetector；其他模块新建轻量指纹比较器（风格对齐 BillDuplicateDetector）。
- UI：设置页「数据管理」子页、最近删除（事件列表+事件详情+恢复预览）、清空所有数据确认页（输入「清空」）、四模块清空入口、任务归档页扩展。

---

## 11. 分期

**一期（本次交付，纯客户端）**：模型字段+批次实体 → 查询过滤全量 → RecycleBinService（清空/恢复/冲突/清除/启动过期清理）→ UI 全套 → D6 深链提示+文案收敛。
**二期（可选）**：BGTask 到期清理、回收站存储占用估算、iCloud 空间提示。

## 12. 风险与测试要点

- 最大工程风险：§10.2 过滤清单漏改 → AI/小组件/简报读到回收站数据。缓解：实体级统一谓词+逐文件核对+AI 直查点回归测试。
- CloudKit：软删对象 30 天内仍占 iCloud 存储（预期）；物理删除跨设备最终一致；schema 随发版。
- 性能：清空=后台分批打标记；回收站按事件分组渲染不平铺几万条；冲突预检用轻量投影（fetchExistingEntries 先例）。
- 测试：30 天边界（HoloTests 规矩：禁 Date() 直取/写死日期，注入时钟）；各模块过滤回归；恢复后通知/统计刷新；附件「软删保留、真删清理」；冲突三类路径；整批恢复依赖顺序；isSoftDeleted 迁移；深链已清除提示（nil 与软删两分支）。
- 验收走查：清空→回收站→恢复→界面/AI/小组件口径一致；清空后重导入→恢复→冲突默认跳过；单恢复子对象→联动恢复父对象；清空所有→AI 记忆点击→「已清除」提示；单删任务 30 天→物理清理。
