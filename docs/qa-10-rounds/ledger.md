# QA 十轮走查 · 问题台账

> 计划文档：`docs/plans/2026-09-06-qa-ten-round-walkthrough-plan.md`
> 编号规则：R{轮次}-{序号}；分级：P0 崩溃/数据丢失，P1 功能不可用/明显卡顿/流程走不通，P2 体验瑕疵。

> **2026-09-16 G1 对齐记录**：第 3 轮实际已于 2026-09-06 完成并提交（9b532a53f），台账标题与汇总表此前未同步更新，本次补齐。第 1–3 轮进入「只抽验易回归问题」状态；第 4 轮起继续按计划补齐。抽验与新增专项记录在 `journey-matrix.md` 与各轮小节。

## 状态汇总

| 轮次 | 发现 | P0 | P1 | P2 | 已修复 | 待拍板 | 真机项 |
|---|---|---|---|---|---|---|---|
| 第 1 轮 稳定性与数据安全 | 12 | 2 | 5 | 5 | 8（含测试基建） | 0 | 0 |
| 第 2 轮 手势与触控 | 4+8灰 | 0 | 1 | 3 | 4 | 1（轴档三问题重报） | 1（R2-G1） |
| 第 3 轮 滚动与性能 | 10+灰 | 0 | 1 | 9 | 10 | 轴档改名挂起/前瞻条未定；轴档①②待实施确认 | 0 |

---

## 测试基建（第 1 轮建立）

- 全量单元测试基线：**897/897 全绿**（2026-09-06）。
- 首跑 31 失败全是**语言假红**：测试断言写死简体中文，模拟器语言为 zh-Hant 时全部崩（含 5 个 standalone 测试进程内 exit 中断整个套件）。修法：Holo scheme 固定 `-AppleLanguages (zh-Hans)`。此坑在档（uitest-false-failures），现已从 scheme 层根治。
- 注意：HoloTests 目录不在文件系统同步分组，新增测试文件必须手动挂 pbxproj，否则假绿（不执行也不报错）。

## 第 1 轮：稳定性与数据安全（删除流 / 保存落盘 / nil 语义）

### 确认问题与修复

| 编号 | 级别 | 位置 | 问题 | 修复 | 回归 |
|---|---|---|---|---|---|
| R1-1 | P0 | AccountDetailView.swift | 删除账户后不退页，详情页继续渲染已删账户→闪退（删除按钮注释写着「返回上一页」但从未实现） | 仓储层抽 `validateAccountDeletable` 守卫预检；页面先预检（失败留在本页提示）→ dismiss → onDisappear 落删（对齐 SpendingProjectDetailView 范式） | 编译✅ 冒烟✅ |
| R1-2 | P0 | TransactionSaveHandler.swift | 转分期/取消分期保存成功后 `isSaving=false` 触发 body 重读已删交易→闪退（isDeleting 有同款防护注释，isSaving 漏了） | 新增 `isEditingTransactionGone` 判定，同步/异步两条路径终态不复位 | 编译✅ |
| R1-3 | P1 | TransactionSaveHandler.swift:118/269 | 分期缩期时正在编辑的那笔可能被删，闭包里读 `transaction.id` →失效对象访问 | 提前捕获 `editedTransactionID` 常量比对 | 编译✅ |
| R1-4 | P1 | TransactionSaveHandler.swift（async 路径） | 下拉保存时 note/remark 空串被转 nil=「不修改」，清空备注永远不生效（同步路径正确、异步路径漏对齐） | async 路径原样传空串，与同步路径及仓储「空串=清空」约定对齐 | 编译✅ |
| R1-5 | P1 | TransactionInfoInputArea.swift + TransactionSaveHandler.swift | 转分期「先删后建」：自定义期数允许输 1 → 删掉原交易后创建抛错 → 数据丢失+崩溃 | 输入端钳制期数≥2（与仓储守卫同一不变量） | 编译✅ |
| R1-6 | P1 | TodoRepository.swift + TaskDetailView.swift | `updateTask(list:)` nil 语义吞掉「移回收件箱」——任务从清单改选收件箱后静默失效（与历史「截止日期删不掉」同族，dueDate 已修、list 漏了） | 新增 `TaskListUpdate` 枚举（.set/.clear，与 TaskDueDateUpdate 同构）；全局核对 4 个调用方 | 单测✅（新增 2 例） |
| R1-7 | P1 | TopicDetailView.swift | 删除自身主题「先硬删库后退页」且 `@State topic` 不清空 → 退场动画期间渲染已删对象 | 先清选中态（missingTopicView 兜底）再删库，失败恢复现场 | 编译✅ |
| R1-8 | P2 | ThoughtListView.swift | deleteThought 先删库后刷数组，安全依赖软删实现（隐性地雷） | 加固为先移除本地数组再删库 | 编译✅ |

### 灰色地带（记录在案，暂不修）

| 编号 | 级别 | 位置 | 现象 | 不修的理由 |
|---|---|---|---|---|
| R1-G1 | P2 | FinanceLedgerView/AccountDetailView 删除弹窗 | 「删库→刷新→清选中态」同栈完成，安全性依赖链路上无真实挂起点；未来有人加 await 就变成闪退 | 静态分析下无渲染窗口，属于结构性提醒；已在代码审查档案留痕 |
| R1-G2 | P2 | FinanceSearchView.swift | sheet 内删除后异步重搜与 sheet(item:) 置 nil 有毫秒级竞态窗口 | 窗口极小无实证案例 |
| R1-G3 | P2 | TaskDetailView deleteTarget / GoalListView requestDelete | 硬删落在退出动画窗口内，依赖系统时序 | 当前缓解因素充分；第 9 轮边界场景复验 |
| R1-G4 | P2 | HabitDetailView.swift:907 | 无回调分支固定 300ms 等待可能短于动画 | 当前唯一调用方走回调分支 |
| R1-G5 | P2 | RepeatRuleView.swift + ChecklistView.swift | ①先删旧规则再建新规则，创建失败丢规则；②两文件全工程无生产调用点（死代码） | 死代码建议第 10 轮收口时统一清理 |
| R1-G6 | P2 | ThoughtRepository.update mood 参数 | nil 语义陷阱但当前无调用方需要清空 | 无行为差异，将来需要时按 richContentJSON 双层可选模式补 |

### 已核对安全的删除点（三路审查共 30+ 处）

CategoryManagementView、SpendingProjectDetailView（pendingDeletionID 范式）、TaskDetailView 子任务/附件/软删、TaskListView 滑删、ArchiveManagementView、GoalDetailView 记录、HabitDetailView 记录、HabitsView（最稳范式：onDismiss+0.2s+按ID删）、HabitTileView、AnniversaryListView/AddAnniversarySheet（全软删链）、TopicManagementView、ThoughtTagManagementView、ChatViewModel（值类型消息数组）、ChatView executePendingDelete、ReportTab 三处（标准纪律）、RecycleBinView、DataManagementView（清空范围与文案一致）、SettingsView 注销。

### 第 1 轮结论

删除流的「先清界面再删库」纪律在全工程的普及率已经很高（30+ 处合规），漏网的 3 处（R1-1/R1-2/R1-7）集中在「详情页删除自身」场景——已全部按 SpendingProjectDetailView 范式统一。nil 语义家族（历史「截止日期删不掉」）排查了全部 update 接口，漏网 2 处（list/async note）已修，1 处记录在案（mood）。

---

## 第 2 轮：手势与触控（热区 / 手势冲突 / 滑动操作 / 长按菜单）

走查通道：294 处 plain 按钮全局扫描 + 双专员代码审计（手势冲突 20+ 站点 / 滑动操作与长按 15+ 站点）+ XCUI 实机走查 11 状态（想法/任务/财务/长廊，截图存 /tmp/qa_r2/）。

### 确认问题与修复

| 编号 | 级别 | 位置 | 问题 | 修复 | 回归 |
|---|---|---|---|---|---|
| R2-1 | P1 | Modifiers/SwipeBackModifier.swift | 边缘右滑让位判定递归扫**整个窗口**：任何常驻模块（ChatView 等隐藏在后面也算）有推送内容时，本页右滑返回被误杀。2026-09-01 财务搜索页已实锤过（当时只迁走一处），其余 20+ 调用点仍暴露 | 让位判定改为沿响应链只找**包含本视图的**导航栈（UINavigationController ancestor），一处修复全体受益 | 编译✅ |
| R2-2 | P2 | Utils/EdgeSwipeBack.swift | 新边缘返回**零阈值提交**：左缘起手的滚动带一点右向分量，抬手即关页（cancelsTouchesInView 未关还会打断滚动） | 补方向锁（HorizontalGestureLock）+ 35% 屏宽或 500 速度守门，与 SwipeBackModifier 同口径 | 编译✅ |
| R2-3 | P2 | Views/Habits/HabitTileView.swift | 长按菜单「撤销今日最近一笔」直删无确认无红色标记（同卡片撤销按钮与看板长按撤销都有确认）；且确认弹窗挂在测量类行上，计数类卡片不在场 | 弹窗上移到磁贴根部（全场在场，两入口共用）；菜单项补 role: .destructive 并改走确认 | 编译✅ |
| R2-4 | P2 | Views/Chat/ChatView.swift | 「回到最新」胶囊：iOS26 plain 按钮热区收缩到文字，材质胶囊画在 Button 外（contentShape 也挂在外层无效）——8/20 观察名单最后一处真问题 | 视觉整体（padding/材质/描边）移入 label + label 末尾 contentShape(Capsule())，视觉与热区同源 | 编译✅ |

### 灰色地带（记录在案）

| 编号 | 级别 | 位置 | 现象 | 处置 |
|---|---|---|---|---|
| R2-G1 | P2 | HomeView.swift:945 | 首页长按排序存在双 guard 时序缝隙：长按震动后不拖动立即抬手，理论上可能误开功能页 | **真机验证项**（合成事件通道验不了）；若复现，修法=onEnded 延迟一帧清 draggingItem |
| R2-G2 | P2 | WeeklyGridView.swift:473 | 捏合缩放每帧写 @AppStorage 触发全量重算 + 缩放伴生滚动漂移 | 性能类，第 3 轮性能专项复核（修法：@GestureState 暂存 + onEnded 一次写 + 缩放期 scrollDisabled） |
| R2-G3 | P2 | FinanceLedgerView.swift:163 | 日滑动每帧写 @State 驱动非 lazy 列表全量重算 | 第 3 轮性能专项顺带 |
| R2-G4 | P2 | DailyReplayView.swift:382 | 时间门长按 0.3s/24pt 刻意放宽的副作用：慢速滚动落在章节头日期上会意外弹时间门 | 设计权衡记录，暂不动 |
| R2-G5 | P2 | CategoryLearnedMappingView | 学习映射右滑删除直删无确认（可再学习，清除全部反而有确认） | 可接受，报备 |
| R2-G6 | P2 | ThoughtCardView.swift:128 | 「…」菜单删除直删（软删）但无恢复入口说明；任务删除有 30 天回收站提示，想法没有 | 建议对齐口径，文案级改动，随下一批文案统一处理 |
| R2-G7 | P2 | TaskListView.swift:1082 | 任务「归档」仅右滑可触达，无菜单/提示（发现性弱化，归档可逆） | 记录 |
| R2-G8 | P2 | 图库翻页 vs 边缘返回 | 最左 20pt 起手翻页变关页（有意共存的设计代价） | R2-2 修复后自然缓解 |

### 待拍板（重报，2026-09-03 诊断在档）

长廊「轴」档三问题（TimelineReplayView）：①滑动「随机滑不动」三根因（0.3s 隐形长按劫持/任务块上下缘 14pt 隐形把手/无初始定位停在 0 点）；②凌晨压缩可复用周档现成折叠模式；③轴 vs 日定位区分（改名/前瞻功能/互跳）。原则方案已给：默认一切触摸给滚动、编辑动作先出可见反馈再接管。**等东林定方向与优先级后实施。**

### 已核对安全（摘要）

双击全部 onTapGesture(count:2)（无 SpatialTapGesture 反模式）；高优手势全部「长按成立才接管」；坐标系全部命名空间；SwipeActionView/HorizontalGestureLock 守门完备；想法/任务/纪念日/报告滑动操作 role+确认齐备；EdgeSwipeBack 根基（UIScreenEdgePan+20pt+穿透）正确；实机走查 11 状态无新异常。

### 附注

- UI 测试走查发现：XCUITest 启动的 app 不继承 scheme 的语言参数（跟模拟器系统语言走，本次为繁体）——与单元测试行为不同，后续 UI 断言注意。
- 临时手势走查方法 testQAWalkthroughGestures 暂托管在 HoloXhsShotUITests.swift（该文件已接线，新文件需 pbxproj 手动挂）。

---

## 第 3 轮：滚动与性能（✅ 完成 2026-09-06，台账状态 2026-09-16 补记对齐）


### 已完成并推送（0ba273813）
- R3-1 [P2→已修] 周历捏合缩放：@GestureState 内存连续变化 + @AppStorage 松手一次写 + 缩放期 scrollDisabled（R2-G2）
- R3-2 [P2→已修] 财务日滑动：手势状态隔离进 DaySwipeContainer + 列表 LazyVStack（R2-G3）

### 确认问题与修复（第 3 轮第二批）

| 编号 | 级别 | 位置 | 问题 | 修复 | 回归 |
|---|---|---|---|---|---|
| R3-3 | P1 | ReadOnlyRichTextView.swift:267-348 | 想法卡片每张滚入视口触发全量 Markdown 重建+两次全文排版（LazyVStack 行滚回重建、无缓存），长笔记滚动掉帧 | 溢出判定结果按「内容key+1pt宽度档+行数+字号档」进 NSCache（countLimit 600） | 编译✅ |
| R3-4 | P2 | ChatReportTabViewModel.swift | 报告 Tab 常驻不可见但 AI 流式期间以约30fps 重算；groupedEntries 每次新建 DateFormatter+全量分组 | formatter 提为 static let；groupedEntries 改缓存字段，entries/筛选 didSet 时重建 | 编译✅ |
| R3-5 | P2 | TimelineReplayView.swift:736-746 | rangeText/timeText 每次新建 DateFormatter；轴档拖拽时段时整帧重算全部事件块，一天 15 块=每帧 15-30ms | static let 缓存 HH:mm formatter | 编译✅ |
| R3-6 | P2 | DomainMemorySection.swift:242/689 | 记忆卡渲染每次新建 DateFormatter（两处不同类型）；洞察 tab 非懒渲染叠加 | 两类型各补 static let dayFormatter | 编译✅ |
| R3-7 | P2 | CalendarViewModel.swift:157-160 | eventsByDay 计算属性每次 body 重算全量过滤+分组；timelineEvents 随浏览累积无上限，长会话滚动周期性顿挫 | 改缓存字段：timelineEvents/moduleFilter didSet 置空，首读重建 | 编译✅ |
| R3-8 | P2 | HomeView.swift:945（东林确认复现） | 首页长按排序后不拖动立即抬手误开功能页：onEnded 同步清空 draggingItem 使 tap 判定放行 | draggingItem 延迟一帧清空（DispatchQueue.main.async），tap 守卫在窗口期内必然拦截 | 编译✅ |
| R3-9 | P2 | CategoryLearnedMappingView.swift | 学习映射右滑删除直删无确认（东林拍板：加确认） | 右滑只记 pendingDeleteEntry，confirmationDialog 确认后才删，附影响说明 | 编译✅ |
| R3-10 | P2 | SwipeActionView.swift:90 + ThoughtCardView.swift | 想法删除无回收站提示（东林拍板：对齐任务口径）；「此操作不可撤销」文案与软删事实相反 | 共享确认文案改为「进入回收站保留30天可恢复」；「…」菜单删除补二次确认（挂卡片根避免连环弹层冲突） | 编译✅ |

灰色地带（待评估）：filteredThoughts 每次 body 求值两遍+搜索用 localizedCaseInsensitiveContains（建议换 localizedStandardContains+缓存）；hasProcessingThoughts/shouldShowAIEducation 列表层 O(n) 扫描×2；ChatScrollBehavior.swift:80-98 同发布首尾ID同变判为 .replaced 跳过视口保持（低概率）。

已核对安全（摘要）：想法列表 LazyVStack✅；三轮「…」卡顿修复未退化（ThoughtContentBody/无障碍二级缓存/渲染输入缓存）✅；聊天流式重绘双保险（33ms节流+equatable 只比源字段+流式纯文本不跑Markdown）✅；渐进分页防跳屏（KVO补偿+0.4s稳定窗+预取阈值）✅；卡片缩略图预生成小图✅；DateFormatter 想法/聊天已静态缓存✅。

基建发现：21 个 @main 独立测试套件不在自动回归（只能手动 swiftc 跑），无统一 runner——建议第 10 轮收口补自动化。另：XCUITest 启动的 app 不继承 scheme 语言参数（跟模拟器系统语言）。

### 长廊+日回放专员补充发现（已并入上表）
- R3-5/R3-6/R3-7 来自该专员。灰色地带记录：momentsByPeriod 每次渲染重复分组 7 遍（单日几十条时 1-3ms，暂不动）；拍立得 onAppear 同步解码 300×300 缩略图（可接受，调大缩略图规格时需重估）；MemoryGalleryView 两处低频 formatter（点热力图才触发，暂不动）；DomainMemorySection nonemptyGroups O(n) 排序（与 R3-6 同源，数据量大后再治）。
- 死代码记录：TodayMemoryCabinetCard / RecentDayCoverView 全库无调用点（第 10 轮收口清理候选）。

### 已核对安全（长廊+日回放方向）
日回放 LazyVStack+pinned headers✅；「禁止顶部插入」铁律未退化（翻页只底部追加）✅；focusedDate 单一事实源未退化✅；展开/收起重锚定健在✅；长廊列表只进 300×300 预生成缩略图✅；热力图等组件规模有界✅。

### 东林拍板记录（2026-09-06）
- 首页长按排序抬手误开页：东林确认此前真机遇到过 → 转 R3-8 已修；
- 想法删除加回收站提示 → R3-10 已修；学习映射删除加确认 → R3-9 已修；
- 轴档改名「排程」：**挂起**，东林要再想想；「下一个事项」前瞻条已向他解释含义（顶部常驻小横条：下一个安排+多久开始+今日剩余空档），待他决定是否加；
- 轴档①滑动劫持治理（0.5s 长按+震动+可见把手）与②凌晨折叠（复用周历模式）暂列待实施，动工前再与东林确认方案细节。

## 第 4 轮：页面状态与生命周期（G1 2026-09-16 开工，进行中）

### 确认问题与修复

| 编号 | 级别 | 位置 | 问题 | 修复 | 回归 |
|---|---|---|---|---|---|
| R4-1 | P1（测试门禁；无直接用户影响实证） | 测试进程实体模型污染：`FinanceReconciliationTests`（sharedModel 独立容器）× `ChatMessageRepositoryCacheRecoveryTests`（真栈）× `ReceiptBookingKernelTests`（真栈） | 全量单测 1126 条中 3 条红（ReceiptBooking 原子写/并发/幂等三测，报 `accountMissing`）。单独跑、双跑、多数小组合全绿；最小复现 = FinanceReconciliationTests + ChatMessageRepositoryCacheRecoveryTests → ReceiptBooking 必挂（两次复现）。机制：同进程两套 NSManagedObjectModel 反复 load 跨阈值后 `Account` 类→实体映射歧义，`findAccount` 的 `try? context.fetch` 把 fetch 失败吞成 nil，误报「账户不存在」。佐证：FinanceReconciliationTests 注释明载同类系统层错误（模型不兼容 134020）及其容器共享规避 | **已修（2026-09-16 深夜，东林拍板「先A后B」）**。A：`CoreDataTestSupport` 新增进程唯一测试容器 `sharedTestContainer` + `clearEntities` 辅助；ReceiptBookingKernelTests 迁入（不再依赖真栈/seedDefaultData），`FinanceTransactionCommandService.commit` 加 `repository` 注入参数（默认 `.shared`，生产零变化）。B：FinanceReconciliationTests、FinanceProjectRepositoryTests 两个自建容器同批迁入共享容器（进程内 load 次数 -2）；政策注释落在 `CoreDataTestSupport.sharedTestContainer`——新增测试类禁止自建容器，存量其余 24 类按域渐进收编（grep `loadPersistentStores` 得清单）。C 项（`findAccount` 去 try?）未做：生产路径改动需单独评审，另立事项 | 证据：最小复现组合修复前两连红 → 修复后 47/47 绿（含并行会话新增 5 条通知测试）；全量重跑结果见下。**B 政策扩展（2026-09-17 凌晨）**：并行会话提交 1d5a39c25 后，其在 ThoughtRichContentTests 新增 ~7 用例（每用例自建容器 +1 load）把全量进程 load 总数推过阈值，134020 同族复发（7 红）；已按同政策迁入 sharedTestContainer（CoreDataTestSupport 增 clearAllEntities 辅助），worktree（HEAD+己方改动）全量 **1108/0 全绿** 复验。worktree 法在并行中间态挡编译时使用（主工作区当时被并行未提交的 ThoughtReferenceListView.swift 重复声明卡死，不代改） |


| R4-2 | P2（演示/走查基建；非功能回归） | MatterVerticalSliceUITests.testFocusCardDetailRevertComplete 断言首页 Matter 焦点卡 | 全量 UITests 该测报「首页焦点卡应出现（种子+flag）」失败；两台模拟器复现。排查链：干净机复现→疑 seed 坏→给 MatterDemoSeed 加沙盒诊断日志（临时）→实测 `args=true → deleteAll 成功 → matter created id=…` **种子工作正常**→根因=首页焦点卡按 T0-T5（1ec53a4b7）设计退役：`matterFocusSection` 有 `!HoloTodayRolloutPolicy.isEnabled` 门（§4/T4「新版开启后 Matter 焦点并入 Today 页」），M0-M3 时代的老测试断言的是已退役的首页卡。新版「今天」语义已由 TodayMatterVerticalSliceUITests 覆盖且 PASS | **不修代码，交拍板**：① 老测试断言迁「今天」页焦点 或 ② 直接退役（新版已有覆盖）。因涉及历史验收口径，未单方面改 | 诊断日志+复跑日志在案；matter-seed-diag.log 沙盒文件在 Skip Audit 模拟器 |


| R4-3 | P1（测试门禁）→ 已根治 | `createDataModel()` 每次调用生成新 NSManagedObjectModel 实例（真栈与测试栈各一份，内容相同实例不同） | 134020 第三轮复发：R4-1 迁共享容器后，并行新增测试把进程负载推过阈值，13 条 ThoughtRichContent 域测试报「模型不兼容」。worktree HEAD 复现确认非在途引入 | **根治：数据模型进程唯一单例**——`CoreDataStack.sharedDataModel` static let 惰性初始化，`createDataModel()` 改为返回同一实例（生产仅 buildContainer 调一次，行为不变；真栈/测试栈/standalone 共享一份 → 子类→实体映射全进程唯一，歧义根除）。修复后全量 **1131/2**（13 条 134020 全消） | 三轮复现→单例后复归绿；证据 /tmp/qa_p0-unittests3.log |

**遗留移交（2026-09-17）**：`HoloAgentSchedulerTests.testRunLoop_健康锁屏…` 在 HEAD（6644e776f）单跑确定性失败（「锁屏不得产生 evidence」）——09-16 深夜基线绿、源码自 08-22 未变，回归变量在 1d5a39c25→6644e776f 区间的已提交内容，属 Agent 域（并行会话领域），已单跑+HEAD 隔离定性，未代修。

### G1 基线备注（2026-09-16）

- 修复前基线：1126 执行 / 3 失败（全部 R4-1）/ 230s；**R4-1 修复后全量重跑：1131 执行 / 0 失败 / 230s，TEST SUCCEEDED**（1131=1126+并行会话新增 5 条通知测试，DerivedData 复用 `/tmp/holo-g1-baseline-dd`）。
- 第 1-3 轮抽验（代码层）：R2-1 让位判定在批次③改动后完好（在途 diff 是「挂载点整层失效」新修复，两者兼容）；R1-8 想法删除「先移数组再删库」仍在；R3-10 转正在途标志/回收站提示仍在。UI 层抽验并入旅程矩阵 J2/J3 执行。
