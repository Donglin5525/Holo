# Holo 更新日志

记录 Holo App 的版本更新历史

---

## [2026-05-23] 个人档案接入全局 AI 上下文

### 新增
- 新增统一的 AI 用户上下文构建器，聊天和意图识别共享同一份个人档案、目标、近期趋势和习惯关注主题上下文
- 意图识别请求现在会携带个人档案，用于分类、习惯、目标等语义消歧
- 记忆洞察上下文新增 `personalProfileContext`，AI 回放生成时可读取稳定用户画像

### 优化
- 为意图识别加入档案优先级护栏：个人档案只能作为消歧和个性化依据，不得覆盖用户当前明确指令
- 去除 Holo 后端 Provider 和本地 OpenAI-compatible Provider 中重复的上下文拼接逻辑

### 验证
- 独立测试通过：`AIUserContextMessageBuilderStandaloneTests`
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS Simulator' build`

---

## [2026-05-23] 记账卡片编辑后金额同步

### 修复
- 用户在 HoloAI 中点击记账卡片修改金额/类型/日期后，卡片内容未同步更新
- `refreshTransactionCard` 现在完整同步 amount、type、date、primaryCategory、subCategory、note 六个字段到卡片 renderData

---

## [2026-05-22] 目标创建完成卡片跳转

### 优化
- HoloAI 目标规划保存成功后，将最后的「已创建目标」消息改为可点击卡片，展示目标标题、任务数和习惯数
- 点击目标创建完成卡片后，自动跳转到「个人 → 我的目标 → 目标详情」
- 为目标保存消息补充 `goalId` 等关联元数据，支持后续从聊天历史继续跳转

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project Holo.xcodeproj -scheme Holo -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/HoloDerivedData build`

---

## [2026-05-21] 健康模块权限持久化

### 修复
- 健康模块每次打开都显示权限引导页的问题：将 `hasRequestedPermission` 持久化到 UserDefaults，App 重启后不再重复请求授权

---

## [2026-05-21] 首次昵称设置

### 新增
- 首次打开 App 时弹出昵称设置弹窗，引导用户填写 Holo 对自己的称呼
- 首页、今日看板、设置页和个人页统一读取本地昵称，不再显示硬编码「东林」

### 优化
- 设置页修改昵称改为确认后保存，空白输入不会覆盖已有昵称

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`

---

## [2026-05-21] HoloAI 普通用户免配置

### 优化
- 正式版默认使用 Holo 自有后端网关提供 AI 对话、AI 回放和语音识别能力，新用户无需配置任何 AI/API Key 即可使用
- 普通用户界面隐藏 AI 助手和语音识别的技术配置入口，保留 Debug 环境下的开发调试入口
- 将「配置 AI / API Key」相关失败提示调整为服务暂时不可用提示，避免误导用户自行配置第三方 Key

### 验证
- Release 真机通用构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Release -destination "generic/platform=iOS" -derivedDataPath /private/tmp/holo-derived-data build`

---

## [2026-05-21] 首页通知栏修复 & 观点语音智能总结

### 修复
- 首页通知栏点击进入任务页后，回退再次点击无响应：`.tasks`/`.finance`/`.memoryGallery` 三类 deep link 目标未被消费，导致 `.onChange` 无法触发二次导航
- 归档管理页面缺少 `import OSLog` 导致编译失败

### 新增
- 归档管理页面新增「任务」标签页，归档任务可在归档列表中查看和恢复
- `TodoRepository` 新增 `loadArchivedTasks()` 方法
- 观点语音智能总结：语音输入后自动生成结构化总结
- `HoloBackendAIProvider` 新增 `chat(messages:purpose:)` 非流式调用方法

---

## [2026-05-20] iOS 17/18 向下兼容

### 优化
- 将 Holo iOS App 的最低系统版本从 iOS 26.2 下调到 iOS 17.0，覆盖 iOS 17、iOS 18 和当前 iOS 26 设备
- 修正 AppIcon 资源配置，补齐 iOS marketing 图标和缺失的 20pt@3x 图标引用，移除不匹配的 mac/iPad 图标槽位

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`

---

## [2026-05-19] 站立数据修复

### 修复
- 站立数据从 `appleStandTime`（分钟折合小时）改为 `appleStandHour`（Apple Watch 站立环小时数），数据与系统健康 app 一致

---

## [2026-05-19] 记账意图识别语义归一

### 优化
- 意图识别 Prompt 升级为 v8，新增 `normalizedCategoryCandidate` 和 `semanticCategoryHint`，由 AI 负责将品牌、口语和动作短语归一为可匹配的记账分类候选
- iOS 记账路由支持按「归一候选 → 原始候选 → 语义提示」匹配本地分类与后端 catalog，减少「肯德基40」「买烟250」这类输入落入兜底分类
- 后端 finance catalog 增加快餐语义锚点，并补充 Prompt 和 catalog 测试覆盖

### 验证
- 后端测试通过：`npm test`
- iOS 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`

---

## [2026-05-18] 洞察推送点击跳转修复

### 修复
- 修复点击洞察（周/月记忆回放）推送通知后无法跳转到对应页面的问题
- `MemoryInsightNotificationService` 为周/月提醒通知添加 `categoryIdentifier`
- `TodoNotificationService` 注册 `MEMORY_INSIGHT` 通知分类并在点击时触发 Deep Link 跳转到记忆长廊

---

## [2026-05-18] 子任务删除闪退修复

### 修复
- 修复删除子任务时 App 直接闪退的问题：`CheckItem.task` 关系的删除规则从 `cascadeDeleteRule` 改为 `nullifyDeleteRule`，防止删除子任务时级联删除父任务
- 优化 `AddTaskSheet` 新建模式下子列表使用 `Identifiable` 包装，消除 `ForEach` 索引越界风险
- `AddTaskSheet` 编辑模式删除子任务时先从本地数组移除，再执行 CoreData 删除，并增加失败回滚
- `ChecklistView` 将 `checkItems` 从计算属性改为 `@State` 数组，手动管理增删状态，避免 CoreData 删除后访问野指针

---

## [2026-05-18] iCloud 手动同步请求

### 新增
- 设置页 iCloud 区支持「请求同步并检查状态」，点击后写入内部 Core Data 同步探针，触发 CloudKit 尽快安排导出
- 新增内部 `ICloudSyncProbe` Core Data 实体，用于产生轻量同步变更，不影响业务数据

### 优化
- 最近同步时间合并到「同步状态」下方的小字，不再作为独立字段展示
- 手动请求后显示「最近请求同步」时间，真正收到 CloudKit 完成事件后再更新为「最近同步」
- App 启动时提前初始化 iCloud 同步监听，减少打开设置页太晚导致错过同步事件的情况

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -quiet -project Holo.xcodeproj -scheme Holo -configuration Debug -destination 'generic/platform=iOS Simulator' build`

---

## [2026-05-17] iCloud CloudKit 同步

### 新增
- 启用 iCloud CloudKit 私有数据库同步，使用 Core Data with CloudKit 在用户设备间自动同步本地数据
- 设置页增加 iCloud 同步状态区，显示账号状态、同步事件和错误信息
- CoreDataStack 增加 Debug 模式 CloudKit schema dry-run 验证方法

### 修改
- `NSPersistentContainer` 切换为 `NSPersistentCloudKitContainer`
- Core Data 模型 7 个 required relationship 改为 optional，适配 CloudKit mirroring 限制
- Debug/Release entitlements 增加 CloudKit 配置

---

## [2026-05-17] 健康模块导航与同步样式优化

### 优化
- 健康首页移除系统导航栏的左上角关闭按钮，改为右滑返回首页
- 健康详情页隐藏系统返回样式，改为 Holo 自绘标题区，并支持右滑返回健康总览
- 健康首页移除 iOS 原生刷新按钮和下拉刷新样式，新增 Holo 胶囊式「同步」控件与自绘小环动画

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS Simulator' build`

---

## [2026-05-17] 财务分类与图标编辑增强

### 新增
- 财务预设科目轻量扩容：新增车辆充电/保养、住宿门票、家政搬家、AI 工具/软件服务/云存储、家庭育儿/赡养、手续费/税费/快递等支出科目
- 收入科目新增基金、项目款、咨询费、稿费、补贴、个税退税
- 后端 finance category catalog 同步新增上述科目及别名、标签，保持 HoloAI 分类匹配语义与 iOS 本地预置一致
- 图标库新增两个 SwiftUI 自绘万能兜底图标：`holo.category.generic` 与 `holo.category.misc`

### 优化
- 分类管理页的一级/二级分类行新增可见编辑按钮，不再只能依赖左滑发现编辑入口
- 编辑分类页新增当前图标预览和「恢复默认」按钮，可从图标库直接替换预设分类图标
- 图标选择器支持混合展示 SF Symbols 与 SwiftUI 自绘图标，自绘图标不会进入 SF Symbol 可用性校验

### 验证
- 后端测试通过：`npm test -- tests/catalog.test.js`
- iOS Debug 模拟器构建通过：`xcodebuild -project Holo.xcodeproj -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' build`

---

## [2026-05-17] 目标规划体验优化

### 优化
- 草稿生成后先显示 inline 聊天卡片（显示目标标题和任务/习惯数量），点击后才弹出编辑界面，避免突兀弹窗
- GoalDraftReviewView 全面重写为 Holo 设计风格：卡片容器（holoCardBackground + 圆角 + 边框 + 阴影）、设计系统字体和间距、底部固定操作栏
- 目标规划 Prompt 增加"我是 Holo"人格引导：分轮次追问策略、自然口语化语气、草案质量要求

### 新增
- GoalDraftReadyChatCard：聊天内嵌目标计划入口卡片，复用 ChatCardView 设计风格
- GoalDraft.cardSummary：计算选中任务/习惯数量的摘要文本

---

## [2026-05-17] 目标系统 v1

### 新增
- 目标 Core Data 实体：Goal 与 TodoTask、Habit 的双向关系（nullifyDeleteRule，删除目标不级联删除任务/习惯）
- GoalModels 值类型：GoalStatus、GoalDomain、GoalDraft、GoalPlanningSession、GoalPlanningRequest
- GoalRepository：CRUD、草案落库（saveDraft 同时创建关联任务和习惯）、状态切换、AI 上下文授权查询
- GoalProgressEvaluator：基于任务完成率和习惯近 14 天完成率的粗粒度进展评估（起步中/稳定推进/有些停滞/接近完成/已暂停/已完成）
- GoalPlanningCoordinator：最多 3 轮追问的状态机，信息足够时提前生成 GoalDraft JSON
- GoalPlanningPromptBuilder：追问 prompt 和草案生成 prompt，支持精简/完整模式
- GoalListView：我的目标列表，空状态引导跳转 HoloAI 规划
- GoalDetailView：目标详情页，支持暂停/恢复/标记完成/删除，AI 授权开关
- GoalDraftReviewView：fullScreenCover 确认看板，可编辑标题/领域、勾选任务/习惯、选择频率、AI 授权
- 个人页「我的目标」入口，跨 Tab 跳转（PersonalView → HomeView → ChatView）
- ChatMessage 新增 messageType 字段，区分普通消息和目标规划消息
- ChatViewModel 目标规划分流：sendMessage 检测活跃规划 session，走专用追问链路
- QuickAction 新增「规划目标」快捷入口
- AI Context 注入：授权 active Goal 摘要注入 UserContext.goalContext，OpenAICompatibleProvider 和 HoloBackendAIProvider 均已支持
- MockAIProvider 目标规划确定性响应（固定追问 + 固定草案 JSON）
- HabitRepository 新增 getCompletionStats(for:days:) 窗口完成率统计

### 修复
- 修复目标规划跳转失败：根因是应用主导航在 HomeView 而非 ContentView，onPlanGoal 回调和 goalPlanningRequest binding 需要接入 HomeView 的 sheet/fullScreenCover
- 修复 HealthDetailView switch 缺少 activeMinutes case（预存问题）

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`

---

## [2026-05-17] 健康模块产品化重构

### 新增
- 新增健康首页 A+C 组合体验：三环主视觉、身体状态分数、三项指标摘要、Apple Health 数据源卡
- 新增健康展示状态模型，支持身体状态分数、指标可用性、数据源状态、无 Apple Watch 替代环和洞察文案
- 新增首页「今日核心洞察」和「生活闭环」关联线索，串联习惯、财务、思考等模块
- 新增活动分钟指标，用于无 Apple Watch 或无站立数据时替代站立环

### 优化
- 重构步数、睡眠、站立详情页，统一展示大圆环、7 天趋势、统计摘要、单项洞察和关联线索
- HealthKit 仓库新增按指标可用状态和数据源状态，避免把授权回调 success 简单等同于全部读取权限
- 权限引导页强调 Apple Health 只读同步、不写入、不上传原始健康记录
- 趋势图空状态文案改为「暂无可用趋势数据」，避免无数据与零进度混淆

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS Simulator' build`

---

## [2026-05-17] 财务模块滚动回弹修复

### 修复
- 分类管理二级分类列表超出首屏时无法滚到底部、回弹（缺少底部 safeAreaInset 避让自定义 Tab Bar）
- 账户管理页 ScrollView 同样缺少底部避让，内容多时底部被遮挡
- 账户详情页 ScrollView 同类问题一并修复

### 根因
- FinanceView 自定义 Tab Bar（88pt）通过 `.safeAreaInset(edge: .bottom)` 挂载，但 NavigationLink push 的子页面不会继承该修饰符，每个可滚动容器需自行处理

---

## [2026-05-16] 任务日期时间交互优化

### 优化
- 新建任务页的截止日期区域改为摘要式列表，主表单不再内嵌日期/时间滚轮，减少页面拥挤感
- 日期与时间设置迁移到独立底部弹窗，支持快捷日期、日历选择和全天/具体时间切换
- 具体时间改用紧凑选择器展示，避免日期滚轮和时间滚轮同时堆叠

### 验证
- iOS Debug 模拟器构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`

---

## [2026-05-16] HoloAI 聊天卡片双向删除

### 新增
- 支持在 HoloAI 聊天界面长按交易/任务卡片删除底层实体（上下文菜单 → 确认弹窗 → 执行删除）
- 已删除卡片显示灰色 + 删除线 + 红色「已删除」标签，禁用点击跳转
- 在财务/待办模块删除实体后，聊天卡片实时刷新为「已删除」状态（CoreData 通知驱动）

### 变更
- `ChatMessageViewData` 新增 `isEntityDeleted(for:)` 渲染时检查实体存在性
- `ChatCardView` 新增 `isDeleted` 参数，统一处理已删除 UI
- `ChatViewModel` 监听 `NSManagedObjectContextObjectsDidChange` 通知，自动刷新受影响卡片

---

## [2026-05-16] 全局文本长按复制支持

### 修复
- 修复 HoloAI 聊天消息、分析详情、亮点提醒等文本无法长按复制的问题
- 为记忆画廊洞察标题/摘要、高亮事件、里程碑、心情卡片、观点卡片、备注等全局文本添加 `.textSelection(.enabled)`

---

## [2026-05-16] V2 方案实施 — 科目对照与 Prompt 瘦身

### 新增
- 后端新增 `/v1/catalog/finance-categories` 科目对照 Catalog API
- 后端 Prompt 注册机制（promptRegistry），支持版本管理和历史同步
- iOS `FinanceCategoryCatalog` 数据模型 + `FinanceCategoryCatalogProvider` + 缓存
- iOS 分类匹配链新增 `categoryCandidate` 抽取规则和 `matchExistingCategoryByCandidate` 自定义科目匹配
- 后台 admin logs 页面增加手动刷新按钮

### 优化
- Prompt 模板瘦身：移除硬编码科目表，改为科目抽取规则 + categoryCandidate + 系统科目对照 catalog
- 记忆画廊 UI 全面重构：热力图暖橙色系、卡片化布局、品牌色统一
- AI 洞察上下文构建器升级：财务/习惯/待办/任务分析上下文增强
- 后台 `adminLogStore.list()` 改为合并热缓存 + SQLite，不再二选一
- 后台 `contentCaptureEnabled` 默认开启，确保日志存储请求/响应内容

### 修复
- 修复 HoloAI 卡片匹配成功后不显示科目名称的问题：RouteResult 新增 `matchedPrimaryCategory/matchedSubCategory`，`buildRenderData` 用 Core Data 真实科目名回写
- 修复 `matchExistingCategoryByCandidate` 多同名科目时返回 nil 的问题，改为取第一个匹配

---

## [2026-05-16] 记忆长廊重构与回放周期优化

### 新增
- AI 回放周期切换改为右上角下拉菜单，支持本周、本月、本季度、自定义周期
- 自定义周期新增开始日期和结束日期选择器，生成回放时按真实日期范围构建上下文
- `MemoryInsightPeriodType` 新增 `quarterly` 和 `custom`，洞察缓存、生成、刷新和继续问 AI 均适配新周期
- 未生成当前周期回放时新增缺省态卡片，不再展示其他周期的回放内容

### 优化
- 记忆长廊重构为洞察/明细双 tab，热力图移动到明细顶部
- 热力图改为品牌橙 5 档色阶：`#F5F2ED`、`#FFD6C7`、`#FFB499`、`#FF9B7A`、`#FF8C66`
- 洞察页减少内容堆叠，仅在当前周期已有回放时展示对应范围内的里程碑与高光
- AI 洞察卡片支持整卡点击展开，标题、状态标签和生成时间拆行展示
- 里程碑、高光、日摘要和最近日期卡片统一品牌色与清晰文本层级

### 修复
- 修复切换到本季度/自定义周期但未生成回放时仍显示本周内容的问题
- 修复回放兜底文案模板残留 `@` 字符的问题
- 修复热力图旧蓝色色块与品牌色不一致的问题

### 验证
- iOS Debug 真机构建通过：`xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -configuration Debug -destination 'generic/platform=iOS' build`

---

## [2026-05-16] 修复语音创建任务时间识别错误

### 修复
- `NLDateParser.containsTimeComponent` 现在能识别标准格式（`yyyy-MM-dd HH:mm`）中的时间部分，之前只匹配中文时间表达（"X点Y分"），导致语音创建的带具体时间的任务被错误标记为全天任务，时间选择器无法展开且不会自动添加提醒

---

## [2026-05-16] Holo 生活轨迹 AI 洞察升级

### 新增
- Prompt 体系升级：system_prompt 从"数据管理助手"升级为"生活轨迹观察助手"，memory_insight_generation 新增轨迹观察视角、洞察层级（fact/change/pattern/correlation/hypothesis/suggestion）、恢复迹象检测
- analysis_prompt 新增分层分析顺序（事实→变化→模式→关联→建议）
- annual_review 升级为转折点+恢复能力观察，不再逐月流水账
- intent_recognition 新增跨模块分析（crossModule）和混合意图识别规则
- 后端 `/v1/prompts/meta` 批量元数据 API（不含正文，供 iOS 判断缓存版本）
- 后端 Prompt 版本 `change_note` 变更说明字段（migration + 管理后台展示）
- 后端管理后台 Prompt 测试区（purpose + message 输入 + 实时测试）
- iOS Prompt 版本化缓存：`LoadedPrompt` 携带 version，meta TTL 2 分钟自动检测版本变化
- iOS 设置页「刷新后端 Prompt 缓存」按钮
- `LifeEvent` 关键事件流模型（最多 30 条，按优先级排序）
- `DailyLifeSnapshot` 每日快照模型（支出/任务/习惯/想法日维度数据）
- `PersonalBaseline` 个人基线模型（观察期前 4 周基线，含高支出工作日检测）
- `CrossModuleCorrelation` 扩展 `patternType` + `evidenceDates` 字段
- 2 条新跨模块规则：重要任务完成+习惯恢复、恢复迹象优先展示
- 跨模块去重逻辑（同一 modulePair+evidenceDates+patternType 不重复输出）
- 13 个后端 Prompt 相关测试用例

### 变更
- `generateMemoryInsight()` 强制 `responseFormat: .jsonObject`，提升 JSON 解析稳定性
- `AIProvider` 协议 `generateMemoryInsight` 返回 `MemoryInsightGenerationResult`（含 promptVersion），三个 Provider 同步适配
- `MemoryInsightService` 保存真实 promptVersion（不再硬编码 `4`）
- 洞察缓存命中同时检查 `sourceSnapshotHash` + `promptVersion`
- Jaccard 去重只比较同 promptVersion 内的洞察
- 旧 `promptVersion=0` 记录仍可展示但不阻挡新生成
- Token Budget 渐进式裁剪：daily 800 → weekly 2200 → monthly 3800 → annual 5000，CJK 友好估算
- 年度上下文新增专用预算裁剪（`enforceAnnualTokenBudget`）
- `ThoughtRepository` 新增 `getThoughtCountByDay` 聚合方法
- AISettingsView 修复 promptSection 未显示在 body 中的问题

### 涉及文件
- iOS: 13 个文件修改，+1373 行
- 后端: 7 个文件修改 + 1 个新增，+147 行

---

## [2026-05-16] HoloBackend 功能增强 — SQLite 持久化 + 日志增强 + Prompt 版本管理 + ECS 部署

### 新增
- SQLite 持久化基础设施：`src/db/database.js` + `src/db/migrations.js`，WAL 模式、integrity_check、busy_timeout、自动 migration（备份+事务+checksum+失败中止）
- 4 张数据表：`ai_call_logs`、`prompt_versions`、`rate_limits`、`request_logs`
- 请求耗时日志中间件 `src/middleware/requestLogger.js`：队列批量写入 SQLite，控制台结构化输出，队列满时丢弃不阻塞主链路
- ASR 调用摘要日志：ASR 路由已接入 startAiCall/finishAiCall 模式，记录音频格式、转写长度、耗时、错误
- 日志持久化：adminLogStore 从纯内存改为 SQLite + 内存热缓存双层架构
- 日志正文落库开关 `HOLO_LOG_CAPTURE_CONTENT=true`，基础敏感信息脱敏（邮箱/手机号/token/API key/长数字串），截断上限 2000 字符
- Prompt 版本历史 + Diff + 回滚：`getPromptHistory`/`getPromptVersionEntry`/`rollbackPrompt`，diff 库集成
- 管理后台新增 Prompt 版本历史页面：版本列表、行级 Diff 视图、回滚按钮
- 管理后台日志页面增强：ASR 调用卡片展示（音频格式、转写长度、专属 badge）
- 持久化限流存储 `src/usage/sqliteUsageStore.js`：INSERT ON CONFLICT 原子计数，成本接口 fail-closed
- 管理日志自动清理（默认 30 天）、request_logs 自动清理（7 天）

### 变更
- Docker Compose 端口绑定改为 `127.0.0.1:8787:8787`，禁止公网直连 Hono
- Docker Compose 新增 `volumes: ./data:/data` 挂载 SQLite 数据库
- Dockerfile 新增 `build-base` + `python3` 编译依赖（better-sqlite3 原生绑定）
- Nginx 配置明确本期仅代理 `/v1/`，管理后台通过 SSH tunnel 访问
- promptRegistry.js 以 SQLite 为唯一运行时事实源，managedPrompts.json 仅用于一次性迁移
- server.js 新增数据库初始化和优雅关闭（SIGINT/SIGTERM）

### 依赖
- 新增 `better-sqlite3`（SQLite 原生绑定）
- 新增 `diff`（行级 Diff 算法）

---

## [2026-05-16] HoloBackend Prompt 托管与内部管理后台

### 新增
- 新增后端 Prompt 托管接口：`GET /v1/prompts`、`GET /v1/prompts/:type`
- 新增 HoloBackend 内部管理后台，支持账号密码登录、AI 调用日志查看、后台测试调用
- 新增 Prompt 管理页面，可查看、编辑、保存和恢复默认 Prompt
- 新增 `docs/admin-backend.md` 和 `memory.md`，记录管理后台架构决策和后续演进方向

### 优化
- iOS HoloAI 调用优先从后端加载 Prompt，失败时回退本地默认模板
- iOS 设置页和个人页隐藏普通用户 Prompt 编辑入口，Prompt 暂由开发者通过后端管理
- AI 调用日志页面支持展开完整请求/响应 JSON，便于调试模型输入输出

### 安全
- 管理后台使用环境变量配置账号密码，登录后使用 HttpOnly Cookie
- `HOLO_ADMIN_TOKEN` 仅保留给脚本调试；日志仅保存在进程内存中，不保存 ASR 音频二进制
- Prompt 与日志文档不记录真实密码、session secret、API Key 或用户日志内容

### 验证
- HoloBackend `npm test` 通过
- iOS Debug 模拟器构建通过

## [2026-05-14] HoloAI 商用后端网关接入

### 新增
- 新增 HoloBackend 商用网关 MVP，统一代理聊天补全和语音识别请求，前端不再直接暴露大模型 API Key
- iOS Debug 环境默认接入 ECS 后端网关，HoloAI 对话、Prompt 测试、AI 洞察和语音识别均走后端转发
- 新增 DeepSeek 聊天转发、DashScope ASR 转写、设备级限流、请求字段过滤和后端部署文档

### 修复
- 修复服务器 Node 18 环境处理 ASR 上传时 `File is not defined` 导致语音接口 500 的问题
- 为当前公网 IP + HTTP 验收临时放行 iOS ATS，解决 App 语音请求到达服务器前被拦截的问题

### 待办
- 后续增加后端请求耗时日志，用于持续观察聊天和语音链路延迟
- 商用前切换为域名 + HTTPS，并移除临时 HTTP 放行配置

## [2026-05-13] 观点语音输入与编辑体验优化

### 优化
- 语音输入录音与 WebSocket 连接并行，消除打开时约 1 秒的准备延迟
- 观点模块语音输入最大录音时长从 60 秒提升到 5 分钟，HoloAI 对话保持 60 秒不变
- 录音时长显示和自动完成提示文案改为动态生成，不再硬编码
- 观点编辑器内容区改为更宽、更高的长文输入布局，减少右侧空白并提升编辑空间
- 观点编辑器富文本行距调整为 1.5 倍，提升长文本阅读和编辑舒适度
- 语音识别结果确认卡片扩大文本编辑区域，结果态隐藏波形区以优先展示识别文本
- 语音波形音量映射优化，弱声音量也能获得更明显的波形反馈

### 修复
- 修复点击语音识别结果「插入」后需要等待 1-2 秒才写入观点编辑器的问题
- 点击观点列表中的具体想法时直接进入编辑页面，不再打开未同步新编辑样式的详情页

---

## [2026-05-12] 语音识别实时流式上传

### 优化
- 语音识别改为录音期间实时推送 16k PCM 音频到 Qwen-ASR WebSocket，不再等录音结束后按真实时长回放上传
- 停止录音后只等待已发送音频提交和最终转写结果，显著减少长录音的二次等待
- 录音服务从文件式录制切换为 `AVAudioEngine` 输入流，并保留实时音量计算驱动波形反馈

---

## [2026-05-12] 语音识别长录音稳定性修复

### 修复
- 修复超过约 10 秒的语音识别容易因 WebSocket 断开而失败的问题
- Qwen-ASR Realtime 音频上传改为 100ms PCM 小块节流发送，避免一次性推送大音频块
- 语音识别总等待窗口放宽到 120 秒，适配最长 60 秒录音

---

## [2026-05-12] 观点编辑器语音输入

### 新增
- 观点新建和编辑页面的内容框右下角新增悬浮话筒按钮
- 复用 HoloAI 同一套语音录制、暂停、继续、重录、识别和错误处理底部卡片
- 语音识别结果确认后插入到当前光标位置

---

## [2026-05-12] HoloAI 语音输入转文字

### 新增
- HoloAI 聊天输入区新增语音按钮，可打开底部语音输入卡片
- 支持录音、暂停、继续、取消、完成，识别结果可编辑确认后再发送
- 新增阿里云百炼 Qwen-ASR Realtime 接入，支持在设置页配置地域、模型、语言和 DashScope API Key
- 语音识别配置存储在本机 Keychain，API Key 不写入代码仓库
- 录音使用 16k 单声道 PCM/WAV 临时文件，完成、取消或关闭后清理本地音频

### 优化
- 录音声波由真实麦克风音量驱动
- 来电、闹钟等音频中断时自动进入中断态，中断结束后可继续或完成
- 录音开始、暂停/继续、完成、识别成功、失败等关键动作加入触感反馈
- 录音达到 60 秒自动完成并进入识别，UI 明确显示自动完成原因
- 语音卡片按钮适配动态字体和窄屏布局，深浅色沿用 HoloAI 现有颜色体系

---

## [2026-05-11] AI 回放提醒修复

### 修复
- AI 回放每周/月提醒通知不生效：App 启动时未恢复已注册的本地通知，iOS 更新或重启后通知丢失无法恢复

---

## [2026-05-11] 习惯连续性频率感知

### 优化
- 习惯连续坚持显示改为频率感知：每日习惯显示"连续X天"、每周习惯显示"连续X周"、每月习惯显示"连续X月"
- 每周习惯（如"每周3次"）按周统计达标次数，连续达标周数即为连续周数
- 每月习惯按月统计达标次数，连续达标月数即为连续月数
- 里程碑检测使用等效天数比较，保持跨频率的一致性

### 新增
- `HabitStreak` 类型：统一管理连续性值和单位（天/周/月）
- `calculateStreakInfo(for:)` 方法：根据习惯频率智能选择计算逻辑
- `calculatePeriodicStreak` 通用周期连续性计算（周/月复用）
- `countDistinctCompletionDays` 统计时间范围内不同打卡天数

---

## [2026-05-11] HoloAI 超时兜底机制 — 防止对话永久卡死

### 修复
- URLError.timedOut 在 streaming 路径被错误映射为 networkUnavailable，绕过了重试逻辑
- sendStreaming() 无重试机制，超时直接失败
- 超时/错误时已接收的流式内容被完全丢弃
- Core Data 中 isStreaming=true 持久化，app 崩溃后重进对话永久卡在 loading
- ViewModel isStreaming 无 watchdog 守护，异常后 UI 锁死

### 新增
- APIClient: URLError.timedOut → APIError.timeout 正确映射（send + sendStreaming 双路径）
- APIClient: sendStreaming 增加最多 2 次指数退避重试（与 send 一致）
- ChatMessageRepository.cleanupOrphanedStreamingMessages: 启动时清理残留 streaming 消息
- ChatViewModel: 90s streaming watchdog，超时自动取消、保存部分内容、恢复 UI
- ChatViewModel.retryMessage: 错误消息支持基于原始用户消息重新发送
- MessageBubbleView: 错误消息显示红色边框 + 重新发送按钮
- ChatMessageViewData.isError: 错误消息检测计算属性

---

## [2026-05-10] HoloAI 交易卡片编辑后科目同步

### 修复
- 用户在 HoloAI 中编辑交易科目后返回，卡片仍显示旧科目的问题
- 根因：卡片数据来自 ChatMessage 的冻结 JSON 快照，编辑 Transaction 后未同步回 ChatMessage
- 新增 ChatMessageRepository.refreshTransactionCard 方法，onSave 时同步 executionBatchJSON + extractedDataJSON 并刷新内存快照
- 新增 FinanceRepository.findCategory / resolveCategoryNames 支持分类层级解析

---

## [2026-05-10] HoloAI 分析查询卡片化 + loading 状态 + 历史消息零闪烁

### 新增
- 分析查询识别后立即显示「AI 正在分析中」loading 卡片，流式文字不再暴露给用户
- 紧凑分析入口卡片（AnalysisCompactChatCard），streaming/loaded/placeholder 三态切换
- AnalysisDetailSheet 详情页，卡片点击打开展示 AI 分析文本 + 数据卡片混排
- AnalysisDetailBlockParser 解析 AI 文本中的 `{{card:xxx}}` 标记，支持默认插入策略
- AnalysisSummaryFormatter 从 AnalysisContext 生成卡片摘要（icon/title/subtitle/summaryLine）
- MarkdownAttributedStringRenderer 抽取流式文本 Markdown 渲染逻辑为独立组件
- ChatMessageRepository.setAnalysisLoadingState 方法，流式前设置 intent+analysisContext

### 修复
- query_analysis 意图因 LLM 返回 single_action mode 而未被拦截（移除 mode 检查）
- analysisContext 为 nil 时紧凑卡片渲染空白（退化为普通气泡）
- 历史消息进入 Chat 时 queryAnalysis 卡片闪烁（lightweight init 直接解码 analysisContext）

### 优化
- PromptManager analysisPrompt 追加 `{{card:xxx}}` 标记指令，AI 输出可精确控制卡片位置
- MessageBubbleView queryAnalysis 渲染逻辑简化为三路分支（streaming / hasContext / fallback）

---

## [2026-05-10] 记一笔键盘态布局与快捷金额栏优化

### 优化
- 金额和名称上移为紧凑双输入框，键盘弹出时首屏可直接看到金额输入
- 最近使用分类改为横向胶囊样式，保留分类图标并与下方分类网格区分层级
- 快捷金额栏与数字键盘合并为统一托盘，修复边角断层和双重圆角问题
- 快捷金额栏、托盘、键盘按键使用轻微色差分层，改善深色模式下的视觉过渡
- 下拉完成交易的交互范围覆盖金额/名称输入区，减少顶部输入区与内容区割裂感

---

## [2026-05-10] 餐饮科目根据当前时间自动归类

### 新增
- 意图识别 Prompt 新增 `{{currentTime}}` 变量，AI 获知当前时间用于餐类判定
- Prompt 新增「餐饮自动归类」规则：未指定餐次时按时间段自动归类（05-10→早餐，10-16→午餐，16-21→晚餐，21-05→夜宵）
- IntentRouter 新增 `correctMealCategoryIfNeeded()` 本地时间修正，AI 判断错误时兜底纠正
- 用户明确说了"早饭/午饭/晚饭/夜宵"时尊重用户选择，不做覆盖

---

## [2026-05-09] 习惯图标渲染统一为 HabitIconRenderable 协议

### 修复
- 「戒烟」等自定义图标在今日看板、数值输入弹窗中显示空白（3 处遗漏 isCustomIcon 分支）

### 重构
- 新增 `HabitIconRenderable` 协议，集中处理 SF Symbol 和自定义 Asset Catalog 图标的渲染分支
- 4 个数据类型（Habit/HabitDetailSnapshot/HabitStatsDisplayItem/HabitStatsItem）统一遵循协议
- 10 处渲染点替换为 `iconImage(size:)` 一行调用，以后新增自定义图标不会再遗漏

---

## [2026-05-09] 记一笔页面交互重构 — 弹窗替代展开式选择

### 重构
- 账户/日期/分期从 .sheet 底部弹出改为 ZStack 覆盖层弹窗（半透明遮罩+居中卡片），消除页面抖动
- 名称行从展开/收起改为始终可见的 TextField，消除 ScrollView 内容高度变化
- 备注从展开式改为始终可见的 TextEditor 大文本框，带 placeholder 覆盖层
- 移除 showNoteEditor/showRemarkEditor 状态，简化为 @FocusState 焦点管理
- AddTransactionSheet 大文件拆分为 6 个职责单一的扩展文件（InfoInputArea/CategoryGrid/Keypad/SaveHandler/StateManager/KeypadComponents）

---

## [2026-05-09] 任务模块统一：新建与编辑合并为 AddTaskSheet

### 重构
- 废弃 TaskDetailView（1435 行），新建和编辑统一走 AddTaskSheet 表单模式
- TaskListView / TaskSearchView / TagListView 调用方重定向至 AddTaskSheet
- 优先级选择改为等宽按钮平铺一行填满宽度

### 新增
- 编辑模式：完成切换按钮（支持重复任务生成下一实例）
- 编辑模式：状态选择行（待办 / 进行中 / 已完成）
- 编辑模式：检查清单进度条（仅编辑且有待办项时显示）
- 编辑模式：删除任务按钮 + 确认弹窗
- `TaskStatus.color` 扩展迁移至 TodoTaskPriority.swift

## [2026-05-09] 习惯看板展示可见性控制

### 新增
- 习惯设置页新增双开关药丸按钮：每个习惯可独立控制「统计」和「看板」的展示位置
- 统计 = 习惯模块统计页，看板 = 首页今日看板
- 今日看板习惯列表和进度计算均按可见性过滤
- 首页入口按钮进度环同步适配

## [2026-05-08] 手势方向锁定统一方案

### 新增
- `HorizontalGestureLock`：三态方向锁定工具（undecided/horizontal/vertical），touch slop 观望 + 主方向优势比，锁定后不回头
- 所有 ScrollView 内水平手势统一接入：左滑操作按钮、右滑关闭、日历切换、图表交互、饼图高亮
- 单元测试 `HorizontalGestureLockTests`：覆盖观望/锁定/不回头/斜向等场景

### 修复
- 左滑操作按钮在上下滚动时误触：方向判定改为三态锁定 + 优势比，消除垂直/水平互相争抢
- 开发规范第 15 节：新增手势方向锁定规范，含错误方案对照和强制规则

## [2026-05-07] 习惯统计看板修复与月份切换

### 修复
- 坏习惯月度格子：无记录天不再显示打勾，改为空白（之前 `hasRecord = !isExceeded` 导致无记录也算成功）
- 坏习惯数值型完成率：无记录天计入控制住天数，与日历、摘要等其他统计函数保持一致

### 新增
- 统计看板月份切换：左右箭头快速切换上/下月，下月不超过当前月
- 点击月份文字仍可弹出月份选择器

## [2026-05-07] 任务详情页新增所属清单选择

### 新增
- 任务详情编辑页（TaskDetailView）新增「所属清单」选择功能，位于标签卡片下方
- 支持将任务移至任意清单或设为收件箱（未归类）
- 清单选择弹窗显示当前选中项高亮和清单颜色标识

## [2026-05-06] HoloAI 历史消息加载优化

### 优化
- HoloAI 对话页首屏改为轻量消息快照加载，跳过重 JSON 元数据解码，显著降低进入对话时的卡顿
- AI 上下文构建路径独立化，UI 只加载当前会话不影响 AI 追问时的历史上下文
- 消息卡片和日志元数据改为按需批量懒加载，可见时才从数据库读取
- 进入对话默认只显示最近一次会话（4 小时边界），支持下拉加载更早会话
- 加载更早会话时保持用户滚动位置不跳变

### 技术
- `ChatMessageViewData` 新增 `ChatMessageMetadataState` 状态机（unavailable/unloaded/loading/loaded）
- `ChatMessageRepository` 新增轻量加载、当前会话加载、更早会话加载、数据库级 DTO 查询、批量元数据懒加载
- `ChatViewModel` 首屏切换到会话加载，新增元数据 debounce 合并、更早会话加载
- `ChatView` 使用 `.refreshable` 原生下拉加载 + 可点击 header，滚动行为区分首次/流式/prepend
- `MessageBubbleView` 根据 metadataState 控制日志入口显示时机

## [2026-05-06] AI 分类学习映射管理

### 新增
- AI 设置页新增「分类学习映射」管理入口，可查看、搜索、删除 AI 自动学习的分类映射规则
- 支持按候选分类名和目标分类名搜索，支出/收入分组展示
- 支持左滑删除单条映射、一键清除所有映射

### 技术
- `CategoryLearnedMapping` 新增 `LearnedMappingEntry` 展示模型、`listAll()` 和 `removeByKey()` 公开 API
- 新建 `CategoryLearnedMappingView` 视图，使用 `.searchable` + `.swipeActions` 原生交互
- `AISettingsView` 新增 `mappingSection` 区块，带映射数量 badge

## [2026-05-06] 统计分析类别饼图显示与交互修复

### 修复
- 修复类别饼图在导入数据后整图变灰或变成单一红色的问题
- 修复饼图区域阻断页面上下滚动的问题，纵向手势现在可正常滚动到下方明细
- 恢复饼图点击、悬停/手势切换时查看具体分类金额的交互

### 技术
- 类别统计页饼图与图例统一使用图表调色板，避免导入分类共享默认色导致整图单色
- 饼图交互从 SwiftUI `DragGesture(minimumDistance: 0)` 改为 UIKit 透明触摸层，横向追踪高亮、纵向让 `ScrollView` 接管
- 扇区间隔角按扇区角度动态收缩，避免 0.3% 等极小扇区因固定 inset 反向绘制成整圈
- 新增饼图交互与极小扇区回归用例，并将经验沉淀到开发规范

## [2026-05-06] 统计分析余额改为累计值

### 修复
- 分析页面余额折线从「时间范围内净收入累计」改为「真实累计余额」，反映所有账户的实际净资产走势
- 余额计算公式：所有账户 initialBalance 之和 + 历史全部交易净收入 + 时间范围内逐期累加

### 技术
- 新增 `FinanceRepository.getCumulativeBalance(before:)` 计算截止日期的累计余额
- `computeChartDataPoints` 接受 `initialBalance` 参数，余额折线起点为真实余额

## [2026-05-05] CSV 导入科目原样迁移

### 优化
- 导入分类逻辑从“相似匹配预警”改为“原样迁移”：只在 `type + 一级分类 + 二级分类` 完全一致时复用已有科目
- CSV 中不存在于 Holo 的科目会按原始一级/二级结构自动创建，不再因未确认分类阻断导入
- 导入预览从“分类匹配预览”改为“科目导入计划”，展示已存在、新建一级、新建二级科目数量
- 新建导入科目统一使用默认问号图标和灰色系颜色，后续可在科目管理中自行编辑

### 技术
- 新增 `ImportCategoryPlanner`，集中计算导入时复用/新建的科目计划
- 移除导入流程中的同义词、学习映射、模糊匹配自动替换，避免替用户猜测科目归属
- 新增 standalone 行为测试，覆盖同名二级科目在不同一级分类或收支类型下必须分别创建

## [2026-05-05] CSV 导入功能完善 — 防止错导入

### 新功能
- 分类三元匹配：type + 一级分类 + 二级分类联合匹配，防止同名二级分类串线（如「餐饮/其他」与「购物/其他」）
- 导入预览弹窗重构：新增 ViewModel 管理解析、匹配、确认流程，大文件解析移至后台线程
- 分类匹配编辑器：点击任意匹配行可手动选择已有分类或确认新建
- 字段映射编辑器：自动检测错误时可手动修正 CSV 列与 Holo 字段的对应关系
- 解析警告系统：日期解析失败不再静默使用今天，改为阻断性警告需用户确认
- 批量确认模糊匹配：一键接受所有相似匹配，减少手动操作
- 外部文件打开：支持拖拽 CSV 到模拟器/设备直接打开导入（CFBundleDocumentTypes + .onOpenURL）
- 调试加载按钮：沙箱 Documents 目录存在 holo_import.csv 时显示「加载测试数据」入口

### 优化
- 模糊匹配阈值从 0.6 提升至 0.75，减少误匹配
- 一级分类不匹配时精确/同义词匹配降级为模糊匹配，需用户确认
- 学习映射 key 格式扩展为 `type|primary|sub`，防止跨一级分类碰撞
- 旧格式学习映射自动迁移（启动时执行）

### 涉及文件
- 新增：ImportPreviewViewModel、CategoryMatchEditor、FieldMappingEditor、Info.plist
- 修改：ImportPreviewSheet、ImportExportModels、CategoryMatcherService、DataImportService、CategoryLearnedMapping、HoloApp

---

## [2026-05-05] 智能快捷标签栏 Quick Tag Bar

### 新功能
- 记账页面键盘上方新增快捷标签栏，展示历史金额和名称标签，点击一键填充
- 根据输入模式智能过滤：金额输入时只显示金额标签，名称输入时只显示名称标签
- 未选科目时展示全科目历史数据，选择科目后自动切换为该科目数据
- 选择科目后保持键盘显示，标签栏直接出现在键盘上方

---

## [2026-05-05] 交易模块 Core Data 卡死修复 + 数据刷新规范

### Bug 修复
- 修复交易模块整体卡死：Transaction→Category/Account 缺少反向关系，denyDeleteRule 放在 to-one 侧导致 save 卡死
- 修复删除/复制交易后页面不更新：移除 refreshAllObjects()，改用 await 重新 fetch
- 修复删除分类后列表仍显示：loadData 过滤 isDeleted 对象，删除后始终刷新

### 规范
- 新增开发规范第 13 节：Core Data 关系建模与数据刷新（反向关系强制、denyDeleteRule 方向性、刷新模式）
- CLAUDE.md 新增 Core Data 关系编码约定

---

## [2026-05-05] 统计分析饼图交互修复 + 交易金额格式化

### Bug 修复
- 饼图手势冲突：移除 10pt 移动阈值，支持拖拽切换扇区高亮，同时不阻断页面上下滑动
- 详情页黑屏：合并 Sheet 状态为 TransactionSheetData，避免 SwiftUI 状态不同步导致空 sheet
- 金额小数位：编辑交易时始终保留 2 位小数（191.50 而非 191.5，5.83 而非 5.833333）

### 优化
- 类别图例移除冗余颜色圆点，仅保留分类图标
- 下钻后点击子分类弹出交易明细列表
- 交易行整行可点击（contentShape 优化）
- 交易明细中点击单笔交易可跳转编辑页

---

## [2026-05-05] 删除科目后 UI 卡死修复

### Bug 修复
- 修复删除科目后交易列表卡死的问题：Transaction→Category CoreData 关系缺少 deleteRule，删除后触发 fault 卡死主线程
- 三层防御：CoreData 层 denyDeleteRule + Category.swiftUIColor isDeleted 守卫 + View 层 isDeleted 检查

---

## [2026-05-05] AI 能力全景文档

### 文档
- 新增 `docs/_common/AI能力全景(A+B+C).md`：Phase A+B+C 完成后的全部 AI 交互 use case 清单
  - 主动交互 5 类：对话助手（15 种意图）、数据分析、记忆洞察回放、个性化配置、智能分类学习
  - 被动交互 5 类：后台自动生成、定时通知、异常检测、跨域关联、去重缓存
  - 含智能分类学习完整工程链路图、存储设计、能力边界分析

---

## [2026-05-05] AI 智能洞察 Phase B+C

### 新功能
- 结构化异常观察：消费突增、预算超支/预警、习惯断连、任务堆积自动检测
- 异常卡片按严重度区分（critical 红色、warning 橙色、info 蓝色）
- 跨域关联增强：情绪-消费并发检测、工作日/周末消费差异分析
- 用户反馈系统：Core Data 新增评分字段，支持轻量反馈
- 洞察去重：与近期洞察文本相似度 >85% 时自动跳过生成
- 上期回顾注入：本期洞察自动回顾上期建议和异常

### 改进
- Prompt 升级至 v4：anomaly 卡片支持、数据护栏、用户文本注入防护
- 习惯断连检测仅限每日正向打卡习惯，避免误判

---

## [2026-05-05] 交易复制功能

### 新功能
- 列表页长按交易，上下文菜单新增"复制"选项（编辑和删除之间）
- 编辑交易页右上角确认按钮旁新增复制图标按钮
- 复制时弹出日期选择器，默认目标日期与原始交易一致，可自由修改
- 完整复制金额、分类、账户、名称、备注、标签等全部字段

---

## [2026-05-05] 账本周/月历点击切换 + 类别 Tab 重构

### 新功能
- 账本首页新增 chevron 箭头指示器，点击即可在周历/月历之间直接切换
- 箭头同时支持拖拽连续控制，保持原有手势能力
- 类别 Tab 一级科目点击弹出 Sheet 展示子分类详情，替代原有下钻导航

### 优化
- 日历区域改为 ZStack 统一容器，拖拽过程中只有单一高度值变化，消除数字抖动
- dragTranslation 取整 + 去重，减少亚像素布局刷新
- MonthlySummaryCard 金额字号统一为 20/16，移除 minimumScaleFactor，拖动时数字不再缩放
- 饼图交互从拖拽高亮简化为点击选中

---

## [2026-05-05] 财务模块 UI 优化 — 图表压缩 + 日历手势修复

### 优化
- 统计分析页图表高度大幅压缩（柱状图 300→200pt，折线图 220→160pt，类别图 200-320→140-220pt），整体从占半屏降至约 1/4
- 明细折线图 Y 轴锁定：新增 `niceCeil()` 取整算法，切换时间范围时坐标轴不再抖动
- 月历最大展开高度从 300→280pt，视觉更紧凑

### 修复
- 账本首页上滑收起月历手势宽容度极低：阈值逻辑改为方向感知（上滑收起阈值 55% vs 下拉展开 30%），并增大手柄触摸区域（minHeight: 28）
- 弹簧动画阻尼微调（0.8→0.82），切换更丝滑

---

## [2026-05-05] AI 分析异常检测文案修复

### 修复
- 异常消费描述从「2026-05-02 支出 ¥5,736.00」改为「当日合计 N 笔支出共 ¥5,736.00」，避免 AI 将日汇总金额误读为单笔交易

---

## [2026-05-05] AI 智能洞察阶段 A + 幻觉修复

### 新功能
- UserContextBuilder 增加历史趋势对比（周支出/环比/习惯率/任务完成/Top分类）
- 日报洞察完整实现（Service 映射 + ContextBuilder 800 token 预算 + ViewModel 状态管理）
- Prompt v3 升级（趋势分析指令 + 异常检测指令 + 日报专用规则）
- 首页洞察入口（HomeScheduleService 新增 insight 模块）
- 后台/前台补偿增加日报自动生成 + dailyAutoGenerationEnabled 设置

### 修复
- AI 数据查询幻觉：系统提示词新增禁止编造数据规则，数据查询路由到 queryAnalysis（走结构化数据路径）
- 习惯完成率显示 1714%：averageCompletionRate 已是百分比值，去掉多余的 × 100

### 清理
- 移除旧 insightGeneration prompt、旧 InsightType 5 个 case、generateInsight() 死代码

---

## [2026-05-05] 记忆长廊里程碑日期修复 + fetchTasks 谓词确认

### 修复
- 里程碑触发日期永远显示"今天"：连续打卡/累计记账/习惯掌握三类里程碑全部硬编码 `Date()`，现改为按实际达成日期标记
- `detectStreakDays` 从精确匹配改为 `>=` 阈值匹配，避免跳过里程碑触发日后永远丢失
- `detectCumulativeCount` 查询第 N 笔交易的实际日期作为达成日期

### 确认
- `fetchTasks()` 谓词已包含 `deletedFlag == NO AND archived == NO`，此 bug 在之前的版本已修复

---

## [2026-05-05] 记忆长廊里程碑图标显示为文字

### 修复
- 明细页100笔里程碑卡片显示 "trophy.fill" 纯文字而非奖杯图标
- 根因：`MilestoneNode` 使用 `Text(data.icon)` 而非 `Image(systemName:)`

---

## [2026-05-04] 观点编辑器 Markdown 功能重构 — 精简工具栏 + WYSIWYG 加粗 + 列表样式修复

### 修复
- 编辑器加粗功能：点击按钮后文字显示 ** 星号标记而非粗体（WYSIWYG 问题）
- 加粗开关失效：再次点击加粗按钮无法取消加粗，必须换行才能恢复
- 加粗延迟反馈：点击加粗按钮后无即时视觉反馈，需等待输入文字才生效
- 列表样式问题：无序列表使用横杠 `-` 而非圆角点 `•`
- 列表吸附问题：列表会自动吸附到有文字的下一行，而非插入到光标位置

### 优化
- 精简工具栏：只保留加粗、无序列表、有序列表三个按钮（移除斜体、下划线、颜色、标签）
- 加粗即时反馈：点击按钮立即高亮 + 字体变粗，无需等待输入
- explicitBold 状态机制：改为 Bool? 类型，支持强制关闭覆盖 contextual 推断
- parser 兼容：MarkdownParser 正则支持 `•` 前缀

---

## [2026-05-04] 左滑手势彻底重构 — 挂载到 window 解决反复丢失

### 修复
- 任务/观点模块左滑归档和删除手势反复丢失，8 次修修补补均未解决根因
- 根因：Pan 手势挂在 SwiftUI 内部 superview 上，该视图不参与正常 UIKit 触摸分发
- 修复：Pan 手势改为挂在 `UIWindow` 上，通过 `shouldReceiveTouch` 限定只在 overlay 区域内响应
- 新增 `didMoveToWindow` 钩子 + 延迟重试机制兜底极端时序

---

## [2026-05-04] 首页三环旋转动画加速修复

### 修复
- 首页中央看板按钮的同心环旋转动画偶尔加速到 ~2 秒一圈（正常 90 秒）
- 原因：mainButton 上的 `.animation()` 隐式修饰符在 `@ObservedObject` 触发重渲染时，将 2 秒呼吸动画泄漏到 90 秒旋转环
- 修复：呼吸缩放改用独立 `@State breathScale` + 显式 `withAnimation`，与旋转动画完全隔离

---

## [2026-05-04] AI 对话查看 LLM 日志功能

### 新增
- 长按 AI 消息气泡可弹出「查看日志」上下文菜单，点击进入全屏日志页面
- 日志页面展示每次 LLM 调用的请求消息（system/user/assistant）和响应内容
- 每个调用分区独立复制按钮 + 底部浮动「复制全部」胶囊按钮
- Core Data ChatMessage 实体新增 `rawLogJSON` 字段持久化日志
- `LLMCallLog` / `LLMLog` 模型捕获意图识别和对话回复两次调用
- `AIProvider` 协议新增 `lastCallLog` 属性，Provider 侧记录请求，ViewModel 侧填充流式响应
- 左边缘右滑返回手势适配

---

## [2026-05-04] AI 记账分类未识别兜底 + 卡片跳转修复

### 改进
- AI 记账分类匹配策略调整：仅接受精确匹配和同义词匹配，移除模糊匹配和随机兜底
- 无法识别分类时自动归入「待确认」（挂载到「其他」/「其他收入」下），并提示用户点击卡片修改
- 卡片显示与实际存储保持一致：分类未匹配时卡片显示「待确认」而非 AI 原始文本
- RouteResult 新增 `categoryUnmatched` 字段，ConversationCoordinator 据此覆盖卡片渲染数据

### 修复
- 记账卡片无法跳转：`cachedLinkedEntityIds` 在 `updateSnapshot` 后未重新计算，导致新创建的卡片 `resolveLinkedEntityId` 返回 nil。新增 `recomputeLinkedEntityIds()` 方法在快照更新后刷新缓存
- 分类识别错误：「家政服务59」被模糊匹配到「地铁」，移除不可靠的模糊匹配兜底逻辑

### 新增
- `FinanceRepository.ensurePendingCategory(type:)` 按需创建「待确认」系统分类
- `ChatCardData` 图标映射新增「待确认」→ `questionmark.circle.fill`
- `ChatMessageViewData` 新增 `rawLog` 字段支持 LLM 调用日志查看

---

## [2026-05-04] 今日看板交互优化 — 弹窗化 + 进度环修复 + 数据同步

### 改进
- 数值类型打卡记录从全屏 sheet 改为居中弹窗（卡片 + 半透明遮罩），交互更轻量
- 弹窗支持点击遮罩关闭、X 按钮关闭、键盘上方"完成"按钮收键盘
- 弹窗渲染从 KanbanHabitSection 移至 DailyKanbanView 顶层 ZStack，避免 ScrollView 裁剪

### 修复
- 数值打卡首次点击白屏：`.sheet(isPresented:)` + 独立 editingHabit 状态竞态，改用 `@Binding` + 居中 overlay 消除时序问题
- 圆形进度条随进度变化变形：`Circle().trim()` 边界框不稳定导致布局抖动，改用 `Color.clear.frame(64×64).overlay` 固定容器方案
- 首次进入看板习惯数据不同步：`loadActiveHabits()` 排在 async 之后延迟执行，`loadStatus()` 未响应 habits 变化。修复：提前加载 + `onChange` 监听自动刷新

---

## [2026-05-04] 任务附件优化 — 后台图片处理 + 拍照卡死修复

### 改进
- 相册上传改为传原始 Data，解码/压缩/写文件全部后台执行，避免主线程卡死
- 新增 `AttachmentFileManager.saveImageDataInBackground` 和 `previewImageInBackground` 后台方法
- 删除附件改用稳定 `NSManagedObjectID`，避免视图层持有已删除 Core Data 对象
- 附件网格引入 `TaskAttachmentGridItem` 值类型，解耦视图与 Core Data 实体
- CameraView 移除手动 `picker.dismiss`，由 SwiftUI 统一管理 fullScreenCover dismiss

### 修复
- 拍照添加附件卡死：CameraView delegate 中立即将 UIImage 转 Data（切断 picker 生命周期依赖），图片保存延迟到 fullScreenCover dismiss 动画完成后执行，统一走 Data 后台处理路径

---

## [2026-05-04] 任务附件功能

### 新增
- Core Data 新增 TaskAttachment 实体（图片路径、缩略图、排序）
- AttachmentFileManager 管理图片存储与清理
- 任务创建/详情页支持添加图片附件
- 附件缩略图网格展示 + 全屏预览画廊
- 项目配置新增相机权限描述

---

## [2026-05-04] 修复财务图表手势错位与左侧 Y 轴不显示

### 修复
- 手势坐标修正：`proxy.position(forX:)` 返回 plot area 局部坐标，触摸点需减 `plotFrame.minX` 后再比较
- 抽取 `ChartTouchSelection` 工具类统一触摸命中逻辑
- 左侧 Y 轴改用默认 `AxisValueLabel` 确保标签可见
- 禁止使用 `proxy.value(atX:)` 查询分类轴（坐标映射不可靠）

### 新增
- `FinanceChartScaleTests` 测试用例
- 开发规范第 11 节「Swift Charts 坐标系与触摸交互」

---

## [2026-05-04] 首页图标改版 — 回归 iOS 原生质感

### 改进
- 功能按钮底板：去除色染叠层和边框，改用 `.thinMaterial` 系统毛玻璃，自动适配深浅模式
- 图标颜色：五个按钮统一为 `.holoTextPrimary` 自适应色，降低视觉噪音
- 投影调整：更柔和的弥散投影，增强悬浮卡片感

---

## [2026-05-03] 首页视觉丰富度提升

### 改进
- 背景氛围：鲜艳渐变光球（橙/紫/蓝）+ 装饰弧线 + 光点闪烁，全部带浮动/旋转/呼吸动画
- 功能按钮：激活五角形按钮的专属颜色系统（任务=橙、财务=绿、健康=蓝、观点=紫）
- 日期信息条：header 下方新增日期胶囊 + 时段微文案，填补上半屏空白
- 中心按钮外环：虚线 + 缓慢旋转动画，不同速度产生视差效果
- 中心按钮图标：数据驱动三环轨道，外环=总进度/中环=习惯/内环=任务，各环独立旋转 + 末端光点 + 中心呼吸光点

---

## [2026-05-03] 今日看板入口图标

### 改进
- 首页圆圈按钮中心添加三层同心环图标，隐喻习惯/任务/健康三大维度
- 图标白色描边配合橙色渐变背景，与看板内部进度环视觉呼应

---

## [2026-05-03] AI 深度财务分析增强

### 新增
- 子分类明细：Top 3 一级分类的子分类拆解（最多各 5 个子分类），AI 可给出"减少宵夜开销"等精准建议
- 分类环比变化：各一级分类当前期 vs 对比期的金额变化百分比，除零保护
- 消费模式分析：星期几消费最高、工作日/周末日均消费对比、高频消费分类 Top 5
- 6 个新增数据模型：SubCategoryDetail / CategoryTrendItem / SpendingPatterns / DayOfWeekSpending / WeekdayWeekendComparison / FrequentCategory

### 改进
- 分析提示词强化数字精度规则：禁止四舍五入、分数近似，changePercent 必须原值引用
- 财务分析侧重扩展：增加子分类占比、分类环比变化、消费模式维度
- FinanceAnalysisContext 新字段全部为 Optional，兼容已持久化的旧 JSON 数据

### 架构
- 修改 3 个文件：AnalysisDomainContexts / FinanceAnalysisContextBuilder / PromptManager
- 新增 3 个私有计算方法，复用已加载交易数组做内存聚合，避免重复查 Core Data

---

## [2026-05-03] 今日看板优化

### 改进
- 入口按钮简化为纯渐变圆圈，移除百分比文字和"今日看板"标签
- 看板标题改用 ZStack 覆盖层居中，不受左右控件宽度影响
- 健康数据卡片移至最底部（心情之后）
- 打卡板块支持三种习惯类型：打卡型 toggle / 计数类 +1 / 测量类数值输入弹窗
- 待办新增"近期待办"子区域，支持"加入今日"按钮并实时刷新列表
- 心情标签从 6 个扩充到 10 个，改为单排横向滚动
- 标签关联观点模块 ThoughtTag，从 Core Data 加载真实标签，支持自定义输入

---

## [2026-05-02] 今日看板功能

### 新增
- 首页中心入口按钮 `DailyKanbanEntryButton`，显示今日整体进度环，替代原 VoiceAssistantButton
- 全屏看板 `DailyKanbanView`，ScrollView 布局融合五大模块
- `KanbanProgressHero` 顶部进度汇总卡片（橙色渐变，打招呼 + 进度条 + 四项统计）
- `KanbanBudgetSection` 月度预算摘要（剩余金额、进度条、今日支出、日均可用、剩余天数）
- `KanbanHealthSection` 健康数据（睡眠/步数/站立三环图 + 睡眠质量标签）
- `KanbanHabitSection` 每日习惯打卡列表（图标、连续天数、打卡圆圈交互 + haptic）
- `KanbanTaskSection` 今日待办任务列表（完成交互、仪式标签、到期提醒横幅）
- `KanbanMoodSection` 心情日记输入（文本 + 6 种心情 emoji，保存自动同步到观点模块）
- `TodoRepository+Kanban` 扩展：看板查询、每日仪式生成、进度计算

### 改进
- `TodoTask` 新增 `plannedDate`（Date?）和 `isDailyRitual`（Bool）字段，轻量级 Core Data 迁移
- 底部导航中间按钮改为 AI 对话入口（原 Holo One 移至 iPhone Action Button）
- 无预算时自动隐藏预算卡片

### 架构
- 新建 9 个文件：DailyKanbanEntryButton + DailyKanbanView + 6 个 Section + TodoRepository+Kanban
- 修改 4 个文件：CoreDataStack+TodoEntities / TodoTask+CoreDataClass / TodoTask+CoreDataProperties / HomeView

---

## [2026-05-02] AI 通用分析查询功能

### 新增
- AI 分析查询框架：支持财务、习惯、任务、想法和跨模块五大领域的周期性数据分析
- 新增 `query_analysis` 意图，用户可说"分析我2024年的消费""复盘一下最近一个月"等
- 5 种分析卡片 UI：概览(Summary)、趋势(Trend)、分类(Breakdown)、对比(Comparison)、亮点(Highlights)
- 分析上下文持久化到 Core Data，重启 App 后历史分析卡片仍能正常渲染
- 分析查询发送零历史消息，避免上下文污染
- AnalysisPeriodResolver：从用户原文和 LLM 提取结果中智能解析日期范围（支持年/月/周/最近N天等）

### 架构
- 新建 11 个文件：AnalysisDomain / AnalysisContext / AnalysisDomainContexts / AnalysisPeriodResolver / AnalysisContextBuilder / 5 个领域 Builder / AnalysisChatCard
- 修改 14 个文件：AIModels / PromptManager / ConversationCoordinator / AIProvider / OpenAICompatibleProvider / MockAIProvider / ChatViewModel / ChatMessageViewData / ChatMessageRepository / ChatCardData / MessageBubbleView / CoreDataStack+ChatEntities / ChatMessage+CoreDataProperties / IntentRouter / ChatView
- 跨模块分析采用并发构建（async let），无共享可变状态

---

## [2026-05-02] 大文件重构 Phase 1-2

### 重构
- CoreDataStack (1,784→262行) 拆为 7 个模块化实体文件
- HabitRepository (1,402→696行) 统计逻辑提取到独立扩展文件
- FinanceRepository (1,384→271行) 拆为 5 个职责化扩展文件
- TodoRepository (936→809行) 统计逻辑提取到独立扩展文件
- FinanceView (1,360→182行) 拆为 5 个独立子视图文件
- TaskListView (994→744行) TaskCardView 提取到独立文件
- MemoryGalleryViewModel (920→829行) TimelineSectionBuilder 提取到独立文件

### 说明
- 10 个文件拆分为 24 个文件，Phase 3（AddTransactionSheet/AddTaskSheet/TaskDetailView）待后续处理
- 纯重构，不改变任何业务逻辑

---

## [2026-05-02] 记忆长廊智能周期回退

### 新增
- 智能周期回退：当前周期数据不足时自动回退到上一周期（月初/周初不再看到空数据）
- 月度阈值 7 天、周度阈值 3 天，不足则自动展示"上月"/"上周"洞察
- 后台服务新增月度洞察自动生成，前台补偿同步支持

### 改进
- HeroCard 标签动态显示"本周/上周"、"本月/上月"
- 生成/刷新/兜底文案全部适配有效周期

---

## [2026-05-02] 系统编辑菜单中文化

### 修复
- 双击文本弹出的系统菜单（拷贝/粘贴/全选）从英文改为中文：设置 developmentRegion 为 zh-Hans 并添加中文本地化支持

---

## [2026-05-02] 任务模块最近已完成折叠抽屉 + 首次启动卡死修复

### 新增
- 任务列表"最近已完成"改为折叠抽屉，默认展示 3 个任务，点击可展开全部

### 修复
- 首次启动卡死 — Core Data 异步加载 + CheckedContinuation 就绪等待
- TodoRepository init 零 I/O 延迟加载，避免阻塞主线程

---

## [2026-05-02] 行为洞察系统 MVP + AI 回放导航修复

### 新增
- 跨模块行为洞察系统 MVP：财务/习惯/任务/观点四模块数据融合
- CrossModuleCorrelator：4 条规则式跨模块关联检测（习惯↔财务、任务↔财务、想法↔习惯、任务↔习惯）
- MemoryInsightContextBuilder 增强：预算绩效、消费异常检测、习惯排名、任务完成率趋势、文本驱动想法分析
- Prompt v2：跨模块关联指导 + 空数据降级 + data/instruction 分离
- 年度回放提示词模板 + 月度洞察聚合查询
- ThoughtRepository 聚合方法：想法数/心情分布/标签排行/文本采样

### 修复
- generate_memory_insight 意图标签不可点击（补充 EntityCategory.memoryInsight + canTap 逻辑）
- 点击"已生成回放"标签无跳转（DeepLinkTarget.memoryGallery + ChatView 导航处理）
- 意图标签显示原始 key 改为中文"已生成回放"

---

## [2026-05-01] 任务模块 UI 重构 + 聊天数据层重构

### 新增
- 任务完成音效 + 触觉反馈
- 任务详情支持编辑标题和描述
- 任务完成增加撤回机制（Toast 提示可撤销）
- AI 意图标签支持任务跳转
- 深度链接竞态修复

### 变更
- 截止时间从 sheet 改为内联抽屉（图形日期选择器 + 时间切换）
- 检查清单从 sheet 改为内联列表（进度条 + 添加/删除）
- 新建任务布局优化：检查清单上移、属性对齐、优先级右对齐
- 任务排序改为创建时间降序
- 聊天数据读取层重构：统一实体解析 + 修复收入卡片跳转 + 原子化消息写入

### 修复
- 修复左滑手势与垂直滚动冲突（方向确认前不禁用 ScrollView）
- 修复任务/观点模块左滑手势全局失效
- 修复左滑手势拦截按钮点击

---

## [2026-04-27] 首页导航修复 + Prompt 编辑器修复

### 新增
- 首页导航状态修复
- 小黄点指示器
- HoloProfile 个人档案

### 修复
- Prompt 编辑器栈溢出修复（去除 @StateObject ViewModel，改用 @State 属性）

---

## [2026-04-26] 记忆长廊改版 + 金额显示修复

### 新增
- 记忆长廊三 Tab 改版：AI 回放 + 地图 + 明细

### 修复
- 全局金额显示截断修复（紧凑格式 + minimumScaleFactor）
- 最近的日子卡片大小统一（顶部对齐 + 固定最小高度）

---

## [2026-04-25] 预算功能 Phase 2

### 变更
- 预算卡片紧凑化：单行布局，去掉已花金额和分类预警

### 新增
- 分类预算：支持按一级/二级分类设置月度/周度/年度预算（如"餐饮不超过 ¥2000/月"）
- 首页预算卡片：记账首页展示全局预算进度 + 分类预警 chips（超支/接近预算）
- CategoryBudgetPicker：可展开的分类选择器，支持选择父分类或子分类
- BudgetSettingsSheet 模式切换：总预算/分类预算双模式
- AccountDetailView 分类预算列表：显示每个分类预算的 mini 进度条、百分比、剩余/超支

### 修复
- 删除分类时自动清理关联预算记录
- 删除空账户时自动清理关联预算记录
- BudgetSettingsSheet 金额输入非法时显示错误提示

---

## [2026-04-21] 习惯统计模块重构

### 新增
- 月度仪表板：单页滚动布局替代双 Tab 结构（总览/习惯），当前自然月为统计周期
- 周视图优先：每个习惯默认展示折叠态周视图，点击原位展开为完整月历
- 单开规则：同一时间只允许一个习惯展开，点击新习惯自动收起当前展开项
- 月份切换：点击月份标题区域弹出 MonthYearPickerView 切换月份
- 轻量总览卡：展示习惯数、完成率、最佳连续天数
- 设置页：管理统计页展示习惯的可见性和排序（UserDefaults 持久化）
- 折叠态默认定位到最后一个有记录的周
- 分类型摘要：打卡型（完成天数+连续天数）、计数型（完成天数+累计次数）、测量型（记录天数+平均值）

### 变更
- 底部导航从 `统计/习惯/新增` 改为 `统计/习惯/设置`
- 新增按钮从底部导航移入习惯 Tab 右上角
- HabitStatsState 重写为月度仪表板模式
- HabitRepository 新增月度投影方法

### 移除
- 删除旧统计组件：HabitStatsOverviewTab、HabitStatsHabitsTab、HabitOverviewCard、HabitRankingCard、HabitTimeRangeSelector、HabitTrendChartView
- 移除 7天/30天/90天/全部 时间筛选器和排行榜

---

## [2026-04-19] 图标库扩容与分组展示

### 新增
- CategoryIconCatalog 图标目录：12 个展示分组，171 个 SF Symbol 图标（原 88 个 + 新增 83 个）
- 图标分组展示：餐饮、交通、娱乐、购物、个人护理、家居、医疗健康、学习成长、家庭人情、生活服务、收入资产、其他
- 历史图标 fallback：编辑已有分类时，若当前图标不在目录中，顶部自动展示"当前图标"分组
- CategoryIconCatalogTests 自动化校验：符号可解析、旧图标保留、无重复、分组结构验证

### 变更
- IconPickerGrid 从扁平 LazyVGrid 重构为按 section 分组展示（外层 ScrollView + LazyVStack）
- AddCategorySheet 默认图标来源从 presetCategoryIcons 切换为 CategoryIconCatalog.allIcons
- 移除全局变量 presetCategoryIcons，由 CategoryIconCatalog 统一管理

---

## [2026-04-12] AI 对话能力扩展（Phase 1-3）

### 新增
- AI 意图从 9 个扩展到 14 个：新增 completeTask、updateTask、deleteTask、createNote、queryTasks、queryHabits
- 移除 `.chat` 闲聊意图，所有非指令输入走 `.unknown` 追问兜底
- 通用实体链接系统（`LinkedEntity` + `LinkedEntityType`），统一管理交易/任务/习惯/笔记关联
- 任务操作支持关键词匹配（精确 > 标题包含 > 备注包含，三级优先排序）
- 创建任务增强：支持优先级、截止日期、标签、描述
- 意图标签扩展：新增完成/更新/删除任务、笔记、查询等图标和标签
- 快捷操作栏从 5 个扩展到 8 个（新增记笔记、今日任务、习惯状态）
- Prompt 模板重写：14 意图分组、日期解析规则、意图判断规则

### 变更
- ChatViewModel 路由逻辑重构：query→流式对话、unknown→追问、其他→本地路由
- 实体合并采用双写策略（新格式 entityType+entityId + 旧字段），向后兼容
- UserContext 注入活跃习惯名称和未完成任务摘要，辅助 AI 理解上下文
- MockAIProvider 新增所有新意图的关键词匹配

### 待实施
- Phase 4: ConfirmationCardView 确认卡片 UI
- Phase 5: 能量值与限流系统（独立迭代）

---

## [2026-04-12] AI Chat 卡片点击跳转详情页

### 修复
- 记账卡片点击：不再跳转到记账首页，直接弹出交易详情编辑页
- 待办卡片点击：不再跳转到任务列表页，直接跳转到对应任务详情页
- ChatMessage 新增 linkedTaskId 计算属性，从 extractedDataJSON 解析关联任务 ID

---

## [2026-04-07] 坏习惯功能 + 记录删除崩溃修复

### 新增
- 习惯模块新增「坏习惯」标记（如抽烟、熬夜），支持打卡型/计数型/测量型的超标检测
- 坏习惯超过目标值时卡片数值变红，显示「已超过当日限额」自动消失提示
- AddHabitSheet 新增好习惯/坏习惯选择 UI

### 修复
- 习惯详情页删除记录时闪退：Core Data 删除后 `refreshAll()` 的 Task 异步更新，SwiftUI 重新渲染时访问已删除对象导致崩溃。改为先同步从 `records` 数组移除再执行删除

### 重构
- 数值型习惯统计改为按日聚合计算，避免一天多次记录导致统计偏差

---

## [2026-04-07] 饼图颜色一致性修复

### 修复
- 一级分类饼图使用科目指定颜色，保证与 App 其他位置（分类图标、列表）颜色一致
- 图表调色板从 5 色扩展到 12 色，支持更多分类的下钻场景
- PieChartView 改为接收外部颜色数组，由 CategoryTabView 统一分配

---

## [2026-04-06] 推送通知 Deep Link 跳转修复

### 修复
- 冷启动时点击通知不跳转：`.task(id:)` 改为 `.onAppear` + `.onChange` 组合，确保冷启动/热启动都能触发跳转
- `setupDelegate()` 从异步 Task 改为同步调用，避免冷启动时 delegate 未就绪

### 重构
- `DeepLinkState` 引入 `DeepLinkTarget` 枚举替代单一 `pendingTaskId`，支持任务详情/每日提醒/习惯等多模块跳转
- 通知 delegate 按 `categoryIdentifier` 设置不同跳转目标，每日提醒现在也会跳转到任务列表

---

## [2026-04-05] AI 记账科目匹配与饼图 Canvas 重绘

### 新增
- AI 意图识别增加完整科目体系，自动归类一级/二级科目
- 记账消息标签可点击跳转到对应交易的编辑页面
- ChatMessage 新增 linkedTransactionId 计算属性
- FinanceRepository 新增按 ID 查询交易方法

### 重构
- 饼图从 Swift Charts SectorMark 改为 Canvas 自绘，消除动画崩溃风险
- 选中扇区凸出 8pt，大扇区内部显示科目名称，引导线外部显示占比
- 触摸饼图时自动禁用父级 ScrollView 滚动

## [2026-04-05] 饼图标签外移与交互优化

### 优化
- 饼图标签全部移至外侧，引导线连接文字与扇区，不再侵占图表区域
- 触摸高亮与下钻分离：触摸时高亮扇区，松手才触发导航
- 标签碰撞检测：左右分组强制最小垂直间距，防止重叠
- 高亮时白色弧线视觉反馈

## [2026-04-05] 修复财务分析饼图下钻闪退

### 修复
- 修复饼图扇区点击下钻时 EXC_BREAKPOINT 崩溃（withAnimation 包裹数据源切换导致 Swift Charts 动画插值失败）
- 修复饼图触摸交互角度计算坐标系不一致（atan2 归一化空间与扇区起始角度不匹配）
- 各图表视图增加零值数据防护

## [2026-04-05] 财务分析类别页恢复饼图

- 类别 Tab 替换柱状图+折线图为饼图，扇区内显示科目名称，外部显示百分比
- 点击饼图扇区支持下钻至二级分类
- 小于 6% 的扇区不在内部显示标签，外部合并显示科目+百分比

## [2026-04-05] 财务分析页图表重构

### 改进
- 类别占比图表由饼图改为柱状图+折线图组合（柱状图显示金额，折线图显示占比百分比）
- 合并时间范围选择器和标签为统一组件，新增自定义日期按钮
- 分析页 Tab 栏简化样式，移除图标仅保留文字标签

## [2026-04-05] 优化财务统计分析饼图

### 改进
- 饼图缩小一圈（240→200），中心区域去掉分类图标，信息更紧凑
- 所有扇区均展示分类名称和占比，小扇区标签外延显示
- 饼图交互使用 UIKit 手势替代 SwiftUI DragGesture，解决 ScrollView 冲突
- 取消分析模块卡片背景，饼图/图例列表/分类详情与底色融为一体
- 下钻返回按钮移除卡片样式，仅展示简洁文字按钮

## [2026-04-05] 优化财务模块交易记录布局

### 改进
- 交易记录去掉独立卡片样式，改为列表行风格（分隔线替代卡片阴影）
- 交易记录背景与页面底色融为一体，视觉更简洁
- 交易行图标与"交易记录"标题左对齐
- 增大"今日账本"标题与周视图之间的间距（8pt → 16pt）

---

## [2026-04-04] 新增 Prompt 本地编辑器

### 新增
- AI 设置页新增"Prompt 模板"入口，列出 6 个可编辑的提示词模板
- PromptEditorView：查看、编辑、保存自定义 Prompt，支持变量预览
- PromptEditorViewModel：编辑状态管理 + LLM 测试功能
- PromptTestSheet：输入测试文本，发送到 LLM 实时查看响应
- PromptManager 支持 UserDefaults 自定义覆盖，优先于硬编码默认值
- 恢复默认：一键清除自定义 Prompt 回退到系统默认

### 改进
- PromptType 新增 displayName/displayDescription/icon UI 元数据

### 修复
- CategoryPicker 从 `.task` 改为 `.onAppear`，每次打开"记一笔"时重新加载"最近使用"分类
- FinanceLedgerView 月份标题底部间距调整

---

## [2026-04-04] 新增 AI 对话模块

### 新增
- AI 对话主界面（ChatView）：消息列表 + 快捷操作栏 + 输入栏
- 消息气泡（MessageBubbleView）：用户/AI 双样式，意图标签，流式打字动画
- 流式文本渲染（StreamingTextView）：打字中闪烁光标，完成后 Markdown 渲染
- 快捷操作栏（QuickActionBar）：记账/任务/观点/打卡/周报一键触发
- AI 设置页（AISettingsView）：Provider 选择、API Key、模型配置、连接测试
- AI 配置 ViewModel（AIConfigViewModel）：Keychain 安全存储、Provider 切换
- ChatViewModel：消息管理、流式响应、意图路由
- OpenAI 兼容 Provider：统一适配 DeepSeek/Qwen/Moonshot/Zhipu/自定义
- MockAIProvider：关键词匹配意图识别 + 模拟流式响应
- 网络层（APIClient + APIRequest + APIError + SSEParser）：重试退避、SSE 解析
- KeychainService：API Key 安全存储
- PromptManager：JSON 模板加载 + {{变量}} 替换
- UserContextBuilder：从记账/习惯/任务/观点 Repository 构建用户上下文
- IntentRouter：意图识别 → 本地 Repository 操作路由（记账/任务/观点/打卡）
- ChatMessage Core Data 实体 + Repository
- 6 个 Prompt 模板 JSON（系统提示/意图识别/数据提取/澄清/洞察/响应）
- AI 数据模型（AIModels.swift、AIConfiguration.swift）

### 变更
- CoreDataStack 新增 createChatEntities() 方法
- ContentView .holo tab 从占位视图替换为 ChatView
- SettingsView 新增 AI 设置入口
- 首页麦克风按钮连接 ChatView（fullScreenCover）

---

## [2026-04-04] 修复日期显示英文 + 开发规范更新

### 修复
- 任务列表卡片截止日期改用 DateFormatter + zh_CN，避免英文设备显示 "Apr 4"
- 记账页日期行、交易时间已在上一提交修复

### 变更
- CLAUDE.md 编码约定新增日期显示规范（禁止 Text(date, style:) / date.formatted()）
- 开发规范全局中文化章节补充禁止 API 列表和检查清单

---

## [2026-04-04] 账本页 UI 改版 — 月度卡片 + 显示设置

### 新增
- 月度收支概览卡片（MonthlySummaryCard），支持环比对比（如 4.1-4.4 vs 3.1-3.4），自动处理月份天数差异
- 卡片右侧显示当日支出金额
- 财务设置新增"显示设置"区块，支持切换"本月支出"/"本月收入"卡片显隐（默认仅显示支出）
- FinanceDisplaySettings 单例，UserDefaults 持久化显示偏好

### 变更
- "今日账本"标题移至按钮行下方独占一行，修复居中对齐问题
- 删除旧的日级支出/收入卡片（ExpenseCard、IncomeCard）
- 整体布局间距收紧（标题、拖拽手柄、卡片、交易列表标题）
- 卡片水平 padding 收窄 10pt

### 修复
- AddTransactionView 日期显示改用 DateFormatter + zh_CN locale（原 `Text(date, style: .date)` 不符合项目规范）

---

## [2026-04-04] 任务完成按钮交互修复

### Bug 修复
- 修复任务列表中无法直接点击圆形按钮完成任务的问题
- 根因：SwipeActionView 的 UIKit overlay 拦截了所有触摸事件，导致 SwiftUI Button 无法响应
- 方案：overlay 的 hitTest 返回 nil 实现触摸穿透，Pan 手势改挂到父视图，导航点击改由 SwiftUI Button 处理

### 变更
- 点击圆形按钮 → 直接完成/取消完成任务
- 点击文字区域 → 进入任务详情页
- 观点卡片同步采用相同的触摸穿透机制

---

## [2026-04-03] 修复观点新增卡死 + 设置页调试入口

### Bug 修复
- 修复真机上点击"新增观点"按钮后 App 卡死的问题
- 根因：UITextView `isScrollEnabled=false` 在 SwiftUI ScrollView 中产生 `intrinsicContentSize` 无限布局反馈循环，真机布局时序更紧凑导致死循环
- 方案：改用 `isScrollEnabled=true` + `SelfSizingTextView` 通过 `sizeThatFits` 显式计算高度，异步回传给 SwiftUI

### 新增
- 设置页新增"调试"区域，支持清除观点模块数据（Thought/ThoughtTag/ThoughtReference）

---

## [2026-04-02] 修复任务列表滚动冲突

### Bug 修复
- 修复任务/观点列表中卡片铺满屏幕时无法上下滚动的问题
- 根因：SwiftUI `DragGesture` 在 ScrollView 内会拦截滚动手势
- 方案：改用 UIKit `UIPanGestureRecognizer` + `gestureRecognizerShouldBegin` 方向判断，垂直放行给 ScrollView

---

## [2026-04-01] 任务检查清单 + 记忆长廊三层时间线

### 新增功能

#### 任务检查清单
- 新建任务支持添加检查清单，保存时批量创建 CheckItem
- 编辑任务支持管理检查清单（添加、勾选、删除）
- 检查清单区域与任务表单无缝集成

#### 记忆长廊三层叙事时间线
- 重构为垂直时间线布局：日摘要 → 高亮 → 里程碑
- 新增 `HighlightDetector` 算法：检测消费异常、习惯表现、任务完成等值得注意事件
- 新增 `MilestoneDetector` 算法：检测连续打卡、累计记录、习惯掌握等重大成就
- 新增 `MemoryTimelineNode` 数据模型：统一三种节点类型
- 新增组件：`DailySummaryNode`（日摘要卡片）、`HighlightNode`（高亮卡片）、`MilestoneNode`（里程碑卡片）、`TimelineDateHeader`（日期头）
- 支持模块筛选（全部/记账/习惯/任务）

### Bug 修复
- 修复编辑任务时 `list` 参数未传递导致清单归属丢失的问题
- 修复 `MilestoneDetector` 属性名拼写错误（`streakThresholds` → `streakDaysThresholds`）
- 修复 `MemoryGalleryView` 中 ViewModel 属性名不匹配的问题
- 修复 `HighlightDetector` 交易类型查询谓词字段名错误

---

## [2026-03-31] 任务模块描述功能修复

### Bug 修复
- 修复新建任务时描述（desc）字段未保存的问题（createTask 缺少 description 参数）
- 修复新建/编辑任务页面标题"新建任务"重复显示的问题
- 任务详情页描述区域增加"描述"标签，与页面风格统一
- 任务列表卡片中新增描述截断展示（最多 2 行）

## [2026-03-30] 观点模块上线 + 多模块优化

### 新增功能

#### 观点模块
- Core Data 实体：Thought、ThoughtTag、ThoughtReference 注册到数据栈
- Repository 层：ThoughtRepository 实现 CRUD、搜索、标签管理、引用关系
- 视图层：列表页、编辑器、详情页、搜索栏、筛选、心情选择、标签输入、引用选择
- 首页集成：HomeView 观点按钮连通 ThoughtsView
- 通知机制：thoughtDataDidChange 刷新列表数据

### 改进优化

#### 记账模块
- 交易列表区域支持左右滑动手势快速切换前一天/后一天
- 复用 WeekView 两阶段动画模式（滑出 → 数据更新 → 弹入）
- 周视图无消费日期选中时用胶囊底色替代全格背景，减小底色占比
- 用透明文字占位确保有无消费的日期数字垂直对齐

#### 观点模块设计规范对齐
- 全局 holoPurple → holoPrimary，统一为橙色主题
- ThoughtCardView 圆角从 28pt 改为 HoloRadius.md(12pt)，去掉描边改为阴影
- 空状态、引用卡片、标签配色统一到设计规范

#### 习惯统计模块
- 修复时间维度切换不生效（@Binding+回调双重写入竞争）
- 修复时间选择器位置，移至 Tab 栏上方并加横向滚动
- 修复自定义图标不显示（Asset Catalog vs SF Symbol 适配）
- 修复数值型习惯显示错位，合并为单行 "值 / 目标"
- 修复测量类折线图 Y 轴标签过密，限制刻度数量为 4
- 修复完成率趋势图手势阻挡页面滚动

### Bug 修复
- 移除周视图未选中今日的多余边框
- 修复记账键盘交互：选分类后自动收起键盘，回车键跳转备注输入框
- 修复分类管理页面最后一个分类被底部 Tab 栏遮挡的问题

---

## [2026-03-28] 分类系统扩展与图标优化

### 新增功能

#### 分类系统扩展
- 新增支出一级分类「人情」（琥珀色 #F59E0B）
  - 子分类：红包礼金、请客、送礼、探望、其他
- 餐饮新增：饮品、水果、酒水、超市
- 交通新增：公交、火车、机票
- 居住新增：房贷、家电、装修
- 医疗新增：牙齿保健、医疗用品
- 其他新增：话费、烟酒
- 工资收入新增：报销
- 其他收入新增：公积金、出闲置

#### 新增图标（22个）
- 餐饮类：饮品、水果、酒水、超市
- 交通类：公交、火车、机票
- 居住类：房贷、家电、装修
- 医疗类：牙齿保健、医疗用品
- 人情类：红包礼金、请客、送礼、探望、人情其他
- 其他类：话费、烟酒、报销、公积金、出闲置

### 优化

#### 图标渲染统一
- `CategoryPicker.swift`：统一使用全局 `transactionCategoryIcon()` 函数
- `QuickTemplateView.swift`：修正 SF Symbol 字体比例（size → size*0.6）
- 修复 11 个 SVG 图标 viewBox 不一致导致的大小差异

#### 分类数据迁移
- 优化 `seedDefaultCategories()` 支持增量补充新分类
- 已有数据的用户升级后自动获得新增分类

---

## [2026-03-28] 首页图标拖拽修复

### Bug 修复

#### 首页模块图标拖拽交换
- 修复长按拖拽图标到其他位置时，选中和被选中图标剧烈跳动的问题
- 引入 `anchorTotalShift` 累计锚点位移变量，每帧统一计算 `dragOffset = translation - anchorTotalShift`
- 解决 `DragGesture.translation` 不可重置导致的坐标补偿失效
- 拖拽过程中屏蔽外部数据源刷新，防止数据竞争

---

## [2026-03-26] 任务日期选择交互重设计

### 新增功能

#### 任务日期选择弹窗
- 新增 `TaskDatePickerSheet.swift` 整合日期、提醒、重复设置
  - `DatePicker(.graphical)` 日历选择
  - 全天/定时切换按钮
  - 提醒设置（整合 ReminderChip 组件）
  - 重复设置（每天/每周/每月/每年/自定义）
  - 结束条件（永不/指定日期/重复次数）
  - 支持半屏和全屏两种 detents

### 改进优化

#### AddTaskSheet 简化
- 移除内联展开的 `DatePicker`
- 移除独立的 `reminderSection` 和 `repeatSection`
- 点击日期区域弹出 `TaskDatePickerSheet`
- 添加设置摘要徽章显示（提醒数量、重复类型）

#### 组件复用
- 新增 `Components/ReminderChip.swift`
- 新增 `Components/TaskChips.swift`（RepeatTypeChip、WeekdayChip）
- 移除重复的组件定义

### Bug 修复

#### 结束条件 UI
- 添加"重复次数"选择器 UI（1-100 次）
- 修复结束日期弹窗按钮重复问题

---

## [2026-03-25] 健康模块基础实现

### 新增功能

#### 健康数据读取（HealthKit）
- 集成 HealthKit 框架，支持读取步数、睡眠时长、站立时长
- 新增 `HealthRepository` 数据仓库，封装 HealthKit 查询逻辑
- 支持模拟器环境自动切换为模拟数据

#### 健康视图
- 新增 `HealthView` 健康主页面，展示今日健康数据概览
- 新增 `HealthDetailView` 详情页，包含 7 天趋势图表
- 新增 `HealthPermissionView` 权限请求页面

#### 组件
- `HealthRingView` - 圆环进度指示器
- `HealthMetricCard` - 指标卡片（含进度条）
- `HealthTrendChart` - 7 天趋势柱状图（使用 Swift Charts）

#### 项目配置
- 配置 HealthKit entitlements（read-only 模式）
- 首页五角形按钮添加健康模块入口

### 已知问题
- HealthKit 授权在真机上需要手动在 Xcode 中配置 Signing & Capabilities

---

## [2026-03-16] App 图标上线 + 项目结构修复

### 新增功能

#### App 图标
- 正式设计并集成 HOLO App 图标
- 图标风格：暖色调米白背景 + 橙色连续线条勾勒的女性轮廓，顶部带有品牌字母 "H"
- 支持全尺寸适配：iPhone、iPad、App Store（29px ～ 1024px 共 12 个规格）
- 支持 iOS Light / Dark / Tinted 三种模式
- 原始图稿保存于 `icon/Holoicon.png`（2048×2048 高清源文件）

#### 项目文档
- 新增 `CLAUDE.md` 项目规范文件，记录技术栈、目录结构、开发工作流、提交规范等

### 问题修复

#### 项目结构修复（从 Cursor 迁移到 Claude）
- 修复因跨目录复制项目导致的 Swift 文件重复引用问题（`Multiple commands produce` 编译错误）
- 删除根目录 `Holo/` 下的 7 个重复 Swift 文件（与 `Holo APP/Holo/Holo/` 内容完全一致）
- 删除根目录 `Holo/Assets.xcassets/` 重复资源目录，消除 62 个分类图标名称冲突警告
- 清理旧 DerivedData 缓存（3 个指向 cursor 路径的残留缓存）

### 文件变更
- `Holo/Holo APP/Holo/Holo/Assets.xcassets/AppIcon.appiconset/` — 新增全套图标文件及更新配置
- `icon/Holoicon.png` — 新增 App 图标原始源文件
- `CLAUDE.md` — 新增项目规范文档
- 删除 `Holo/Assets.xcassets/`（重复资源目录）
- 删除 `Holo/Components/`、`Holo/Views/`、`Holo/Utils/`、`Holo/ContentView.swift`、`Holo/HoloApp.swift`（重复代码文件）

---

## [2026-03-15] 习惯图标系统扩展

### 新增功能

#### 图标分类系统
- 习惯图标从 20 个扩展到 **62 个**，按 9 大分类组织
- 新增图标分类：运动健身、健康生活、学习成长、自我提升、饮食营养、财务理财、日常习惯、戒除/减少、其他
- 每个图标带有中文标签，方便用户识别

#### 图标选择器升级
- 图标选择器改为分类展示，每个分类有独立标题
- 图标下方显示中文名称（如"跑步"、"阅读"）
- 视觉优化：圆角卡片 + 选中高亮效果

#### 自定义 SVG 图标支持
- 新增 `HabitIcons` Asset Catalog 文件夹
- 创建自定义"戒烟"图标（香烟 + 禁止符号 SVG）
- 支持混合使用 SF Symbol 和自定义 Asset 图标
- `IconItem` 新增 `isCustom` 属性区分图标类型

### 技术要点

#### 图标类型判断
- `Habit` 模型新增 `isCustomIcon` 计算属性
- 根据图标名在 `HabitIconPresets.allItems` 中查找是否为自定义图标
- 自定义图标使用 `Image(name).renderingMode(.template)`，SF Symbol 使用 `Image(systemName:)`

#### 数据结构
- `HabitIconCategory`：图标分类（name, icon, items）
- `IconItem`：单个图标项（name, label, isCustom）
- `HabitIconPresets.categories`：分类数据源
- `HabitIconPresets.allItems`：扁平化图标列表

### 文件变更
- `HabitType.swift`：新增图标分类数据结构和 62 个图标定义
- `AddHabitSheet.swift`：图标选择器改为分类展示，支持自定义图标
- `HabitCardView.swift`：习惯卡片图标显示支持自定义图标
- `Habit.swift`：新增 `isCustomIcon` 属性
- `Assets.xcassets/HabitIcons/`：新增习惯图标资源文件夹

---

## [2026-03-15] 习惯打卡功能

### 新增功能

#### 习惯数据模型
- `Habit` Core Data 实体：支持打卡型（每日打卡）和数值型（记录数值）两种习惯
- `HabitRecord` Core Data 实体：记录每次打卡/数值，与 Habit 一对多关联
- 支持自定义图标、颜色、频率（每日/每周/每月）、目标值
- 数值型习惯支持计数（累加）和测量（取最新值）两种聚合方式

#### 习惯首页 (HabitsView)
- 习惯卡片列表，展示图标、名称、频率/目标、今日状态
- 打卡型习惯：点击勾选按钮完成/取消打卡，显示连续天数
- 数值型习惯：计数类显示 +1 按钮，测量类显示输入按钮
- 底部 Tab 栏：统计 / 习惯列表 / 新增
- 顶部显示今日完成进度（如 2/5）

#### 习惯详情页 (HabitDetailView)
- 习惯信息头部：图标、名称、类型标签、频率目标
- 时间范围切换：本周 / 本月 / 本季度 / 全部
- 统计摘要：打卡型显示连续天数/完成次数/完成率，数值型显示总计/日均/峰值或变化/最低/最高
- 记录列表：按时间倒序展示，支持删除单条记录
- 工具栏操作：编辑 / 归档 / 删除

#### 新增习惯表单 (AddHabitSheet)
- 习惯名称输入
- 类型选择：打卡型 / 数值型（分段选择器）
- 数值型聚合方式：计数 / 测量
- 图标选择：20 个预设 SF Symbols
- 颜色选择：10 种预设颜色（5x2 网格）
- 频率选择：每日 / 每周 / 每月
- 目标设置：打卡型设目标次数，数值型设目标值和单位

#### 首页入口
- 点击首页「习惯」图标进入习惯模块（fullScreenCover）
- 支持从左边缘向右滑动返回首页

### 技术要点

#### SwiftUI + Core Data 最佳实践
- **body 内禁止 Core Data 查询**：所有查询在 `onAppear`/`onReceive` 中执行，结果缓存到 `@State`
- **@StateObject 不能包装 @MainActor 单例**：改用 `@ObservedObject` 或直接 `.shared` 调用
- **访问 @MainActor 单例必须用 Task 包装**：`Task { @MainActor in ... }`

#### NSManagedObject 删除流程
1. 使用 ID（UUID）而非对象引用传递
2. sheet 用 `item` 绑定（值类型 selection），避免 `isPresented + selectedId` 状态不同步导致的 Loading
3. 删除前先从本地数组移除（`habits.removeAll { $0.id == id }`）
4. 延迟 0.1s 再执行 Core Data 删除
5. 访问前检查 `!habit.isDeleted && habit.managedObjectContext != nil`
6. 使用 `isDeleted`/`managedObjectContext` 需 `import CoreData`

### 修复与优化
- 修复 `HabitCardView` / `HabitDetailView` 缺失 `import CoreData` 导致编译失败
- 修复习惯详情 sheet 首次打开偶现「加载中...」与卡顿：改为 `.sheet(item:)` 单一状态驱动展示
- 优化习惯变更通知：携带 `habitId`，仅刷新对应卡片/详情，减少全量 Core Data 查询
- 优化今日完成进度统计：从逐个习惯查询改为单次 fetch 统计

### 文档更新
- 开发规范新增「6️⃣ SwiftUI + Core Data 视图卡死/白屏问题」
- 开发规范新增「7️⃣ NSManagedObject 删除后访问崩溃」（含标准删除流程代码和时序图）

---

## [2026-03-14] 首页功能入口重构

### 新增功能

#### 五角形图标布局
- 首页功能入口从 4 个扩展为 5 个
- 新增「习惯」功能入口，使用 `checkmark.circle` 图标
- 布局从四角定位改为五角形环绕语音助手按钮
- 5 个图标均匀分布在语音按钮周围（每隔 72° 一个位置）

#### 长按拖拽排序
- 长按 0.5 秒激活拖拽模式，伴随触觉反馈
- 拖拽时图标放大 1.15x 并添加阴影效果
- 拖到其他位置 50pt 范围内自动交换位置
- 只能在 5 个固定位置之间交换，不支持自由停放
- 松手后弹性动画归位

#### 图标配置持久化
- 新增 `HomeIconConfig` Core Data 实体
- 用户调整的图标顺序自动保存到本地数据库
- 重启 App 后保持上次的排列顺序
- 预留 `isVisible` 和 `customName` 字段，支持后续扩展

#### iCloud 同步准备
- 数据架构已为 CloudKit 同步做好准备
- 在 `CoreDataStack.swift` 中添加详细的启用指南

### 优化调整
- 图标与文字间距从 8pt 减少到 4pt
- 五角形布局整体上移 10pt

---

## [2026-03-14] 数据导入导出功能

### 新增功能
- CSV 文件导入功能，支持从其他记账 App 迁移数据
- CSV 文件导出功能，支持数据备份
- 导入预览界面，确认数据无误后再导入
- 异常数据智能处理，自动识别和修复格式问题

---

## [2026-03-14] 记账月历视图 Phase 2

### 体验增强
- 月历交互优化
- 日期选择体验改进
- 动画过渡更流畅

### 交易管理优化
- 交易列表展示优化
- 交易详情页面完善
- 编辑和删除交易功能

---

## [2026-03-14] 记账月历视图 Phase 1

### 新增功能
- 周视图：展示一周的收支概览
- 月历视图：日历形式查看每日收支
- 弹窗抽屉：点击日期查看当日交易详情
- 日期导航：快速切换月份和年份

---

## [2026-03-11] 开发工具优化

### 新增
- 添加 `todo-sync-after-commit` 技能
- 自动同步 TODO 状态与 Git 提交

---

## [2026-03-08] 记账键盘优化

### 修复
- 记账键盘输入体验优化
- 金额显示格式修正
- 键盘响应速度提升

### 文档
- 新增记账模块业务规则文档

---

## [2026-03-07] 财务页 UI 大版本升级

### 新增功能
- 分类体系升级：支持 71 个图标的二级分类
- Asset Catalog 规范化管理分类图标
- Figma 导出图标转换脚本

### UI 优化
- 财务页 UI 全面优化
- Tab 栏与加号按钮合一设计
- 收支卡片视觉升级
  - 去除边框，更简洁
  - 微渐变背景
  - 负空间设计
  - 毛玻璃效果

### 文档
- 开发规范文档
- 开发前必读指南

---

## [2026-03-05] 仓库结构统一

### 调整
- 统一仓库结构
- 纳入 iOS 记账 MVP 代码
- 整理项目文档

---

## [2026-03-03] 开发规范

### 文档
- 添加开发规范文档
- 记录频繁提交和推送的最佳实践

---

## [2026-03-02] 首页 UI 实现

### 新增功能
- 实现 Holo 首页 UI
- 基于 Figma 设计稿还原
- 顶部问候语和用户头像
- 中央语音助手按钮
- 四角功能入口按钮
- 底部浮动导航栏
- 日程提醒组件

---

## [2026-03-01] 项目初始化

### 初始提交
- 创建 Holo 项目仓库
- 初始化项目结构
