# 技术体检五轮 · 问题台账

- 立册：2026-09-09（第 0 轮摸底产出入册）
- 计划：`docs/plans/2026-09-09-tech-debt-five-rounds-plan.md`
- 编号规则：R{发现轮次}-{序号}，分级 P0（用户可感/高风险）/ P1（明确收益）/ P2（次要）/ P3（记录观察）
- 状态：`待修` → `已修` → `已验证`；不修的标 `豁免`（附原因）

## 汇总

| 轮次 | 主题 | 入册 | 已修 | 豁免 |
|---|---|---|---|---|
| R0 | 体检发现 | 38 | - | - |
| R1 | 卡顿专项 | - | - | - |
| R2 | 死代码清理 | - | - | - |
| R3 | 冗余收敛 | - | - | - |
| R4 | 结构治理（保守版） | - | - | - |
| R5 | 收尾加固 | - | - | - |

## R0 · 体检发现（2026-09-09 三路排查 + 人工复核）

### A. 卡顿/性能（→ 第 1 轮为主战场）

| 编号 | 级 | 问题 | 位置 | 状态 |
|---|---|---|---|---|
| R0-1 | P1 | 习惯 streak 逐天 fetch ≤3650 次/习惯且在主线程，统计页×习惯数放大 | Models/HabitRepository.swift:821,858 + HabitRepository+Stats.swift:80,451 | 待修→R1 |
| R0-2 | P1 | 长廊高光检测「日期×习惯」双循环 fetch 全主线程 | Models/HighlightDetector.swift:170,217 + Views/MemoryGallery/MemoryGalleryViewModel.swift:245-250 | 待修→R1 |
| R0-3 | P1 | 任务卡每次渲染内联新建最多 4 个 DateFormatter | Views/Tasks/TaskCardView.swift:310,331,340,377 | 待修→R1 |
| R0-4 | P1 | 首页日程卡内联 formatter，首页高频取用 | Views/Schedule/ScheduleCommonViews.swift:193,370,503,524 | 待修→R1 |
| R0-5 | P1 | 财务明细渲染路径逐日 Decimal reduce + 循环内 formatter | Views/Finance/Analysis/DetailTabView.swift:55-63,234,473 | 待修→R1 |
| R0-6 | P1 | 想法图库打开主线程逐张全尺寸解码原图 | Views/Thoughts/ThoughtGalleryView.swift:70-80 | 待修→R1 |
| R0-7 | P2 | 周视图叙事主线程跑 Highlight/Milestone 检测 | Views/MemoryGallery/Calendar/CalendarViewModel.swift:346 | 待修→R1 |
| R0-8 | P2 | 拍立得卡 onAppear 批量主线程解码照片 | Views/MemoryGallery/Calendar/Daily/PolaroidMomentCard.swift:95 | 待修→R1 |
| R0-9 | P2 | 任务附件画廊 .task 逐张原图解码主线程 | Views/Tasks/AttachmentGalleryView.swift:78 | 待修→R1 |
| R0-10 | P2 | 今日看板整页非 Lazy 全量物化 | Views/DailyKanban/DailyKanbanView.swift:41-46 + KanbanTaskSection.swift:53 | 待修→R1 |
| R0-11 | P2 | 财务分析每条变更通知主线程全量重算图表 | Views/Finance/FinanceAnalysisState.swift:186-200（叠加 FinanceRepository @MainActor 架构） | 待修→R1（重算节流/预计算，不动架构） |
| R0-12 | P2 | 里程碑检测阈值循环内逐次 fetch | Models/MilestoneDetector.swift:92 | 待修→R1 |
| R0-13 | P2 | 周期项目逐 project 一次 Transaction fetch | Models/FinanceRepository.swift:800-815 | 待修→R1 |
| R0-14 | P2 | 启动对账逐 message fetch | Data/Repositories/ChatMessageRepository.swift:984 | 待修→R1 |
| R0-15 | P2 | 日程同步循环内逐操作 EventKit+CoreData 双 save | Services/Schedule/ScheduleSyncEngine.swift:188-210 | 待修→R1 |
| R0-16 | P2 | 分享卡 renderedImage 为 computed，body 多处取用重复渲染 | Views/Anniversary/AnniversaryShareCard.swift:99-104 | 待修→R1 |
| R0-17 | P3 | 长廊洞察长页非 Lazy（固定分区+故事 ForEach） | Views/MemoryGallery/MemoryGalleryView.swift:194-215 | 待修→R1 |
| R0-18 | P3 | 相册加载器疑无降采样（待核实使用面） | Services/PhotoLibraryImageLoader.swift | 待核→R1 |

### B. 性能观察项（→ 第 3 轮评估，保守处理）

| 编号 | 级 | 问题 | 位置 | 状态 |
|---|---|---|---|---|
| R0-20 | P2 | ChatViewModel 单对象 29 个 @Published，任一变化全页失效 | Views/Chat/ChatViewModel.swift:19-39 | 评估→R3 |
| R0-21 | P2 | 长廊 ViewModel 24 个 @Published 同款 | Views/MemoryGallery/MemoryGalleryViewModel.swift | 评估→R3 |
| R0-22 | P3 | 记忆出处徽章每枚串行 8 个 async fetch | Views/Chat/MemoryAttributionBadge.swift:93-98 | 观察→R3 |
| R0-23 | P3 | 回执读 UserDefaults+Decoder 每次新建 | Views/Chat/Cards/ContextPlanChatCard.swift:575-596 | 观察→R3 |
| R0-24 | P3 | 单例 init 即读盘（文件小，首次触达） | Models/DailySenseSnapshot.swift:171-231 | 豁免候选 |
| R0-25 | P3 | 调试页日志列表非 Lazy | Views/Chat/ChatLogView.swift:52-54 | 豁免候选 |
| R0-26 | P3 | 4 个 selector 观察者未成对移除（iOS9+ 无泄漏） | Views/MemoryGallery/MemoryGalleryViewModel.swift:131-152 | 观察→R3 |

### C. 死代码（→ 第 2 轮，删除前逐文件重验引用）

| 编号 | 级 | 对象 | 行数 | 状态 |
|---|---|---|---|---|
| R0-30 | ~~P1~~ | **误判豁免**：AddTransaction「旧记账簇」实为活代码——6 文件是 AddTransactionSheet 的扩展实现（typeTabBar/categoryGrid/infoInputArea 等在用），「新旧互不引用」系误读，**不得删除**；仅 AddTransactionView.swift（342 行）确认死、已删 | 342 | 已删→R2 |
| R0-31 | P1 | 任务旧组件簇：ChecklistView/RepeatPicker/RepeatRuleView/AddFolderSheet/EditFolderSheet/PriorityPicker | 1,407 | 已删→R2 |
| R0-32 | P1 | AI 记忆旧簇：逐类型精修——服务类/视图删除，内部活类型（DomainMemoryLLMClient/ObserverExecutor/RunInput/memoryInsightDidGenerate 通知名等）保留并按活内容重命名文件 | ~400 | 已删→R2 |
| R0-33 | P1 | MockAIProvider | 547 | 已删→R2 |
| R0-34 | P1 | 散件：ReferenceSelectorView/CategoryMatchEditor/PromptEditorViewModel/HabitQuickCheckInView/HoloAgentFallbackComposer（ChatScrollBehavior/OverBudgetStripes/GalleryScrollView 内含活类型恢复保留） | ~650 | 已删→R2 |
| R0-35 | ~~P2~~ | **误判豁免**：ThoughtShareCard.swift 全文件基本是活的（ThoughtShareSheet+ThoughtShareCard 导出渲染+PolaroidPhoto 在用）；仅 HoloDashedDivider 曾判死，后证实被活卡引用而恢复 | 0 | 豁免（误判） |
| R0-36 | P2 | 仅测试引用 4 处：HoloMemoryForgettingService(测试+pbxproj 手术)/HoloInsightCritic(同)/ChatScrollBehavior(测试同删)——HoloWidgetModels/HoloMemoryAnchorRegistry 复核为活或收益不足，豁免 | ~500 | 已删→R2 |
| R0-37 | P2 | 集合文件死类型（逐项复核后确认）：RoundedCorner+HoloRectCorner+SummaryCard+DateDivider；ScheduleSectionCard/ScheduleRowCard/EmptyStateView/AnalysisChatCard(实为 AnalysisSummaryChatCard)/TimeRangeLabel 等复核为活 | ~200 | 已删→R2 |

### D. 冗余（→ 第 3 轮）

| 编号 | 级 | 问题 | 规模 | 状态 |
|---|---|---|---|---|
| R0-40 | P1 | DateFormatter 内联创建（用完即弃） | 222 处/100+ 文件 | 待修→R3 |
| R0-41 | P1 | 金额格式化 3 套并存（统一入口 + 10 处 private formatAmount + 13 处手工拼接） | 23 处 | 待修→R3 |
| R0-42 | P2 | Logger subsystem 魔法串重复；ChatViewModel 内 4 次重复构造 | 158 处 | 待修→R3 |
| R0-43 | P2 | 裸 NSLog 未走 os.Logger（Release 也输出） | HoloBackgroundContinuationManager.swift 6 处 | 待修→R3 |
| R0-44 | P2 | Toast 两套实现（HoloToastCenter vs MemoryNoticeToast+页内自制） | - | 只评估→R3 |
| R0-45 | P3 | ChatViewModel 重复 updateMessage 参数组 | 9-10 处 | 待修→R3 |

### E. 结构（→ 第 4 轮保守版）

| 编号 | 级 | 问题 | 状态 |
|---|---|---|---|
| R0-50 | P2 | MarkdownTextView 3,579 行单文件 | 待拆→R4 |
| R0-51 | P2 | ChatViewModel 3,220 行 92 个方法 | 待拆→R4 |
| R0-52 | P2 | Repository 两套位置（Models 根平铺 vs Data/Repositories） | 待归位→R4 |

### F. 护栏（→ 第 5 轮）

| 编号 | 级 | 问题 | 状态 |
|---|---|---|---|
| R0-60 | P2 | 无 SwiftLint/SwiftFormat、无 lint 构建相位 | 待引入→R5 |
| R0-61 | P2 | 编译警告无基线（2026-09-09 增量编译 0 警告；全量基线 R5 建） | 记录 |
| R0-62 | P3 | 超 1,000 行文件 31 个无冻结清单 | 待建→R5 |

### G. 卫生基线（体检确认的良好面，无需动）

print 仅 2 处且在 DEBUG 内；debugPrint 0；try!×1、as!×6、fatalError×6（均属合理用法密度极低）；IUO≈1；注释掉的代码块 0；TODO 仅 1 条（RepeatRule+CoreDataProperties.swift:94）；DispatchQueue.main.sync / 主线程信号量 / Timer(target:) 均 0；fetchLimit 覆盖良好；缩略图路径规范。

## 执行日志

- 2026-09-09 R0：三路排查完成（结构/性能/死代码），人工复核纠正 1 处误判（R0-35）；在途 47+35 文件按 6 主题分拣提交；增量编译 0 警告，全量单测启动。
- 2026-09-09 R0 协调事件：并行会话 01:08 提交推送 `1cc30301b 财务项目一期`（抢走 C1 主体 28 文件），本会话仅补齐 4 残余文件（amend 为 `f6c87141d`）；C4 小组件批归还并行会话（其在途 widget-interactivity 批次）。首轮全量单测 TEST FAILED——但跑测窗口内源码被并行会话持续改写（HabitRepository 01:10 仍在写入），结果视为污染无效，失败明细因日志过滤管道截断未留存；**全量测试门禁延后到工作区安静后重跑**，R1 先做与并行会话零交集的文件。
- 2026-09-09 R1a 完工（零交集 8 项，行为等价）：
  - R0-3 ✅ TaskCardView 4 处内联 formatter → TaskCardFormatters 缓存（time/monthDay/dueDate）
  - R0-4 ✅ ScheduleCommonViews 5 处（多于排查报告的 4 处）→ ScheduleFormatters 缓存，全天分支前移免建
  - R0-5 ✅ DetailTabView 图表逐日 formatter 出循环 + periodTitle 3 模板缓存 + dateHeader 缓存；顺删孤儿扩展 monthDayString/monthDayWeekdayString（无调用方）
  - R0-6 ✅ ThoughtGalleryView 全尺寸解码挪后台 + preparingForDisplay（全屏缩放查看器保持全分辨率不降采样）
  - R0-8 ✅ PolaroidMomentCard onAppear 批量解码挪后台
  - R0-9 ✅ AttachmentGalleryView 同 R0-6 模式
  - R0-11 ✅ FinanceAnalysisView 通知流 throttle(500ms, latest:true)——首发立即刷、风暴合并，终态一致
  - R0-16 ✅ AnniversaryShareSheet renderedImage 计算属性 → init 渲染一次（原 body 每次求值渲染 2 遍）
  - R0-10 ⏸️ 豁免：看板为固定 8 分区仪表盘，外层 Lazy 无收益；任务行惰性化在带背景裁切卡片内会出现「背景随滚动渐进生长」视觉变化，违反零功能变化红线；行成本已由 R0-3 降低
  - R0-17 ⏸️ 豁免：洞察页为编辑式固定版面，精选故事有 prefix 限量，非长列表
  - 验证：独立派生数据目录编译（/tmp/holo-techdebt-dd，避免与并行会话构建锁互踩）；全量测试门禁与 R1b 一并在工作区安静后补跑。
