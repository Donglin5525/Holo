# 记忆长廊 · 两 tab 收敛方案（撤明细 tab，热力图迁洞察）

## 背景

记忆长廊现为三 tab：日历 / 洞察 / 明细。改造后存在四处重叠：

| 重叠内容 | 明细 tab | 已有更强版本 |
| --- | --- | --- |
| 热力图 | 顶部 GitHub 式 13 周热力图 | 日历月历热力着色（单月粒度，非跨月趋势） |
| 点一天看当天 | 热力图点选 → 当天轨迹统计卡 | 日历月历点选 → DayDetailCard（逐条可点） |
| 按天分组列表 | 时间线（日摘要+高光+里程碑） | 日历周历列表（逐条事件卡） |
| 高光/里程碑出口 | 时间线内高光节点 | 洞察「可回看的片段」（同一数据源） |

明细 tab 真正独有、别处没有的只有两样：**无限往回滚**、**按模块筛选**。

**决策（2026-08-19，东林拍板）**：撤明细 tab，收敛为「日历 / 洞察」两 tab；明细的独有资产迁入日历；**热力图保留**（东林明确要求），迁至洞察 tab。

## 定位

- **日历 = 发生过什么**（事实层）：时间导航 + 逐条事件 + 筛选 + 无限翻旧账。
- **洞察 = 意味着什么**（意义层）：理解档案、DailySense、活跃节奏（热力图）、LifePlan、可回看片段。

热力图归洞察而非日历的理由：它的核心价值是「跨周趋势 + N 天有记录的坚持反馈」，属于自我认知而非逐条导航；日历 tab 周历模式首屏已拥挤放不下，月历模式下又与月历热力着色同屏打架；洞察是流式布局，加卡零结构成本。

## 需求一：热力图 + 当天轨迹卡迁洞察 tab

- `MemoryHeatmapView`（13 周）插入洞察 tab，位置：DailySense 状态卡之后、LifePlan 台账之前（节奏反馈与 DailySense 同族）。
- 点选交互保留：选中态 + 下方展开「当天轨迹」统计卡（现 `selectedDatePreview` 逻辑原样搬，同 view 同 viewModel，数据依赖 `timelineSections` 与 `ensureWeekLoaded` 均已存在）。
- 计数口径 `computeHeatmapData` 4 源（记账/习惯/待办/想法）不变，与日历实际事件口径一致；「健康」目前仅枚举占位未进数据，未来接入日历时热力图同步纳入。

## 需求二：模块筛选接入日历（CalendarFilterBar 上岗）

- `CalendarFilterBar`（已写好未接）挂到日历 tab，位于观察摘要卡下方，周历/月历共用。
- `CalendarViewModel.moduleFilter` / `setModuleFilter` / `filteredEvents` 均已存在且生效，纯接 UI，无逻辑改动。
- chip：全部 + 记账/习惯/待办/想法（健康 P3 注释维持）。
- 导航栏右上角原明细 tab 的筛选按钮随明细一并移除。

## 需求三：周历列表无限上翻（明细的「无限滚动」迁入）

- 列表结构改为**周间倒序、周内升序**：顶部是本周（周一→周日），滚到底部 append 上一周，与明细 tab「往下滚=看更早」的浏览方向一致；append 在尾部，无 prepend 滚动跳动问题。
- `CalendarViewModel` 为周历列表维护累积窗口（[窗口起点, 本周末]），`eventsByDay` 改由累积事件计算；滚到底触发窗口起点前移一周并增量加载合并去重。
- 周历网格视图（3 日窗口按天步进）不扩展，天然可达任意日期；月历取数路径不动。
- 复核结论（2026-08-19 review）：原 prepend 方案否决——用户在底部触发加载而新内容出现在顶部，交互别扭且需锚定防跳。

## 需求四：高光/里程碑插入周历列表

- 周历列表加载某周时同步取该周 `HighlightData` / `MilestoneData`（现 `MemoryGalleryViewModel.cachedHighlights` 体系），按日期插入对应 `WeeklyDayRow` 之间，卡片复用 `GentleHighlightNode` / `MilestoneNode` 样式。
- 取数下沉为共享 provider 或由 `MemoryGalleryViewModel` 注入 `CalendarRootView`，避免两个 VM 各查一套（实施时定，倾向前者）。
- 筛选联动：模块筛选激活时隐藏高光/里程碑卡（高光为跨模块事件，无法按单模块过滤），「全部」模式才显示。
- 洞察「可回看的片段」保留不变，仍是叙事出口（两出口收敛为一个半）。

## 需求五：撤明细 tab 与死代码清理（最后执行）

- `MemoryGalleryTab` 删 `.detail`，`MemorySegmentedTabs` 自动两段；默认 tab 保持 `.calendar`。
- 删：`detailTab`、旧 FilterChip 筛选条、`timelineList`/`timelineSectionView`/`nodeView`、`viewModel.showFilter`、`MemoryModuleFilter`（「观点/想法」命名不一致随之消失）、`DailySummaryNode` 组件（撤后无引用）。
- 删死状态：`selectedMemory` 仅有声明与 sheet 挂载、无任何赋值入口，连同 `MemoryDetailView` 挂载移除；实施时确认 `MemoryDetailView`、`HighlightNode`（明细时间线专用强色版，洞察与周历均用 `GentleHighlightNode`）、`collapsibleInsightLayer`（无调用）、`onNavigateToFinance`/`onNavigateToChat`（无消费）均为零引用，一并删除。
- 保留：`timelineSections` 分页加载体系（洞察「可回看的片段」与热力图伴生当天卡仍依赖）。
- DEBUG 截图路由（`.memoryInsight` → 洞察）与 deep link「聚焦新记忆」→ 洞察，均不受影响。
- 测试同步：`HoloTests/Views/MemoryGallery/` 仅两个 ViewModel 层测试，不涉 tab 结构，预期小改或不改。

## 实施顺序

1. 需求一：热力图迁洞察（独立可验收）
2. 需求二：筛选接日历（独立可验收）
3. 需求三：周历无限上翻
4. 需求四：高光/里程碑插入周历
5. 需求五：撤明细 tab + 清理（等前四步皆有归宿后最后执行）
6. CHANGELOG 补记

## 风险

- 高光卡插入改变周历列表信息密度 → 视觉验收。
- 撤 tab 是用户可见的结构变化 → 发版说明提一句。
- 洞察首屏高度增加约 200pt → 热力图置于 DailySense 之后，理解档案仍居首屏。

## 关联文件

- `Views/MemoryGallery/MemoryGalleryView.swift`（tab 结构、明细视图、当天预览卡搬迁）
- `Views/MemoryGallery/Components/MemorySegmentedTabs.swift`
- `Views/MemoryGallery/Components/MemoryHeatmapView.swift`（不动，换挂载点）
- `Views/MemoryGallery/Calendar/CalendarRootView.swift`（筛选条挂载）
- `Views/MemoryGallery/Calendar/CalendarFilterBar.swift`（上岗）
- `Views/MemoryGallery/Calendar/CalendarViewModel.swift`（累积窗口、筛选接线）
- `Views/MemoryGallery/Calendar/Weekly/WeeklyListView.swift`（无限上翻、高光卡插入）
- `Views/MemoryGallery/MemoryGalleryViewModel.swift`（heatmapData 保留、MemoryModuleFilter/showFilter 清理）
- 删除文件：`Components/DailySummaryNode.swift`、`Components/TimelineDateHeader.swift`、`Components/HighlightNode.swift`、`MemoryDetail/MemoryDetailView.swift`
- `Views/HomeView.swift`（MemoryGalleryView 构造调用点）

## 后端发版

纯客户端改动，无需后端发版。
