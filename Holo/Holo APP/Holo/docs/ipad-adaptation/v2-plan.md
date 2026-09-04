# Holo iPad 全面整改方案 v2

> 状态：**已拍板动工（2026-09-05，东林）**
> 日期：2026-09-05
> 触发：12.9 寸真机走查（IMG_0944/0945）确认 v1「限宽居中」策略导致大面积空白、两层导航并存、弹窗窄小，东林拍板全面整改。
> 结论先行：纯客户端改动，**无需后端发版**；维持「iPad 全屏运行、不分屏多窗口」（沿袭 v1 D4）。

---

## 0. 拍板记录（2026-09-05）

> **2026-09-05 补充**：东林确认 HTML 设计稿无需再逐条拍板，授权按推荐项执行；本计划直接开工，推进至可真机验收。
> 执行口径：所有拍板点按各稿「推荐项」落地；唯一可选项「账本页宽屏双栏」按默认**不做**。

| 决策点 | 结论 | 备注 |
|---|---|---|
| 导航骨架 | **左侧边栏**（推翻 v1 D1「限宽居中」） | iPadOS 标准形态；设置/个人升级为正式页面 |
| 改写范围 | **8 模块全面改写、分批交付** | 习惯/看板/财务/任务/想法/长廊/AI/首页 |
| 拍板方式 | 设计稿已交，**按推荐项执行** | 设计稿在 `docs/design-prototypes/ipad-v2-*.html` |

设计稿清单（拍板后归档）：
1. `ipad-v2-0-skeleton-prototype.html` 侧边栏骨架线框
2. `ipad-v2-1-home-prototype.html` 首页改版
3. `ipad-v2-2-thoughts-prototype.html` 想法列表-详情双栏
4. `ipad-v2-3-finance-prototype.html` 财务统计仪表盘

## 1. 验收口径（全部达标才算完）

1. 12.9 寸横屏（约 1366pt 宽）下无大面积空白：每页信息密度随屏幕增长（多栏/多卡）；
2. 全 App 只有一套导航（侧边栏）；财务(5)/任务(4)/习惯(3) 内部底部小标签栏上移为顶部切换；
3. 设置、个人为侧边栏正式页面（宽屏设置页双栏：左分组右内容）；高频弹窗定宽合理；
4. 妙控键盘完整可用：菜单栏快捷键全覆盖且任意页面生效；想法编辑器 markdown 快打（行首 `-`/`+`/`*` + 空格 → `•` 列表符；Cmd+B/I/U）；
5. iPhone 端零变化（一切改动以宽度断点门控）；11 寸横竖屏与 12.9 竖屏不劣化。

## 2. 现状锚点（2026-09-05 探查结论，实施时直接引用）

### 2.1 骨架层
- `HoloApp.swift` → `ContentView.swift`（ZStack+switch 三 tab：今天/对话/我的；透明按钮挂 Cmd+1/2/3、Cmd+,、Cmd+N、Cmd+W 于 L40-56，部分 tab 失效）→ `HomeView.swift`（BottomNavBar 胶囊 + `ResidentScreenRouteStack` 七常驻模块 opacity 叠放 L36-41/143-151）。
- 布局工具：`Utils/HoloAdaptiveLayout.swift`（`contentColumnMaxWidth = 720` L18、`isRegularWidth` L21、`ContentColumnContainer` L27、`.holoContentColumn()` L92）。全项目 18 文件在用。
- 零 `userInterfaceIdiom` 判断、零 NavigationSplitView、零 `.commands`、零 `focusable/onMoveCommand/onKeyPress`、零指针 hover。

### 2.2 模块锚点（问题→文件:行）
| 模块 | 关键锚点 |
|---|---|
| 习惯 | `HabitsView.swift:207-210` 磁贴固定 2 列（空态 3 磁贴 2+1 松散根因）；`:131-133` 底部 3 tab h88；`HabitTileView.swift:72/553` minHeight118/扩散圆 300 |
| 今日看板 | `DailyKanbanView.swift` 单列七段卡片流（Hero/预算/习惯/日程/任务/心情/健康） |
| AI 对话 | `MessageBubbleView.swift:231` AI 气泡不限宽；`ChatInputView.swift:124` 输入条全宽；快捷条横滑通铺 |
| 财务 | `FinanceView.swift:224-226` 底部 5 tab h88；`Analysis/` 趋势图 h200/折线 h142/饼图 h300 写死；`Calendar/WeekView.swift:87` 滑出量=UIScreen 宽×0.3；`FinanceLedgerView.swift:94/108` 月历高写死 |
| 任务 | `TasksView.swift:168-170` 底部 4 tab h88；`TaskListView.swift` 单列卡片流，详情 sheet |
| 想法 | `ThoughtListView.swift` 单列+全宽卡；`ThoughtKnowledgeTreeView.swift:94/102` 双层 holoContentColumn；`Editor/SuggestionPanelView.swift:65` maxWidth 280 |
| 长廊 | `WeeklyGridView.swift:47-53` 固定一屏 3 天；`TimelineAxisLayout.swift:17-19` h56/g46、`TimelineReplayView.swift:139` 双泳道对半；`MonthlyCalendarView` 7 flexible 列；`MemoryHeatmapView.swift:18` cellSize16 固定 13 周；`MemoryGalleryView.swift:64/69` 双重限宽补丁 |
| 首页 | `HomeView.swift:121-124` pentagonRadius155/area420；`:662-666` heroScale 1.25/1.45（UIScreen.main，缩放糊）；`:524-565` 背景光球 350–500 手机画布 |
| 设置/个人 | `HomeView.swift:228/245` 以 sheet 弹出，无任何宽度定制（v1 D2 弹层零定制）；`SettingsView.swift` 1291 行单列分组 |
| 弹层总量 | `.sheet`≈168 / `fullScreenCover`≈67；0 处 presentation 宽度定制；固定高度 detents 14 处（v1 §5.1 清单） |
| 编辑器 | `MarkdownTextView.swift`（UITextView 代表）：shouldChangeTextIn L446-558（现仅拦 `\n` 做列表续行，L482 正则已认 `• ` 前缀）；程序化替换范式 `performProgrammaticEdit` L487-498；候选面板 UIKeyCommand L3326-3337；插入触发符 L1467。**markdown 快打挂点 = L462-470 之间** |

## 3. 阶段计划

### 阶段 0：计划落盘 + 设计稿拍板 ← 当前阶段
- 本文档落盘；旧 plan.md 标注被取代；✅
- 4 份 HTML 设计稿交东林拍板（清单见 §0）。**拍板通过前不动骨架代码。**

### 阶段 1：布局地基 v2
- `HoloAdaptiveLayout.swift` 升级三档断点：compact <720 / medium 720–1023 / expanded ≥1024；
- 新增：自适应列数助手（按磁贴最小宽算 2/3/4 列）、图表高度分档、统一宽度读取入口；
- 清理 11 处 `UIScreen.main`（v1 §5.2 清单：ChatView:906、DailyKanbanView:73、ThoughtEditorView:929、FinanceLedgerView、WeekView:87 等）。

### 阶段 2：导航骨架改造（唯一动架构的点）
- `ContentView` 宽屏下升级「侧边栏 + 内容」；iPhone 路径完全不动；
- 侧边栏条目：今天 / 想法 / 财务 / 任务 / 习惯 / 记忆长廊 / 健康 / AI 对话 ｜ 个人 / 设置；主橙 CTA（快速记录）放侧边栏底部；
- **保留常驻模块栈**（保滚动位置、聊天状态），仅切换入口换成侧边栏；
- 财务/任务/习惯内部底 tab → 宽屏顶部切换条（`FinanceView`/`TasksView`/`HabitsView` 各自 safeAreaInset 分支）；
- 设置、个人页面化：从 HomeView sheet 改为侧边栏目的地；设置宽屏双栏（左分组导航右内容）；顺带修「对话/我的 tab 下 Cmd+, 无响应」；
- `.commands` 菜单替换透明按钮：前往(Cmd+1…9) / 文件(Cmd+N/W) / 编辑(Cmd+F 搜索) / Cmd+, 设置。

### 阶段 3：弹层政策
- 统一弹窗宽度修饰器 `.holoSheetWidth()`；高频 ~20 弹窗定宽（表单 540–600pt）；设置类已页面化；14 处固定 detents 复核。

### 阶段 4：模块全面改写（三批）
**第一批（最痛）**：习惯（磁贴自适应 3–4 列、空态重排、统计双栏、tab 上移）；今日看板（双栏：左=预算+习惯+心情，右=日程+任务+健康）；AI 对话（气泡限宽 ~640、输入条/快捷条收窄居中、报告页宽屏）。
**第二批**：任务（列表-详情双栏，详情不再 sheet；筛选条收纳顶部）；想法（列表-详情双栏、知识树双层限宽修正、建议面板适配）。
**第三批**：长廊（周历一屏 5–7 天随宽、轴档泳道密度、月历格宽、热力图伸缩、洞察双栏章节；日回放保持纵读）；首页（五角形弃 scaleEffect 改布局级分档、背景光球铺满，按拍板稿实现）。

每批流程：实现 → build_sim → 模拟器截图走查 → 独立提交 → 东林验收。

### 阶段 5：妙控键盘包
- markdown 快打：`MarkdownTextView.swift` shouldChangeTextIn L462-470 挂行首 `-`/`+`/`*`+空格 → `• `（复用 `performProgrammaticEdit` 保撤销粒度；与 L482 续行正则天然兼容）；数字列表续行已有，回归确认；Cmd+B/I/U 绑 `MarkdownEditorAction`；
- Esc：关候选面板（已有）→ 收键盘 → 逐层退弹层；
- `.commands` 菜单（与阶段 2 合并实施）；
- 二期可选：列表上下键焦点导航、触控板 hover 高亮。

### 阶段 6：全量验收
- 矩阵：12.9 横+竖、11 寸横，逐模块截图对照 §1 验收口径；iPhone 主流程回归；
- 全量测试分批跑齐（工作区须独占）；交东林真机验收（带图想法、聊天、记账、长廊翻页等重交互路径）。

## 4. 工程纪律与风险

- **提交纪律**：每模块独立提交；工作区在途的多语言/素材/回放摘要等改动严禁混提交（改前 `git status` 分账）；
- 已知坑在档：iPad 方向须 launch 后设置；多会话共用模拟器互踩；长廊轴档近期刚优化（ec9a157d/ca59ba6a）勿回归；编辑器 typingAttributes 污染；SwiftUI zIndex 勿进 animation；
- 风险集中在阶段 2（唯一动架构）；常驻栈机制把改动面压到「切换入口」一层；
- iPhone 零影响靠断点门控，每批走查必须含一次 iPhone 模拟器冒烟。

## 5. 交付节奏

阶段 0 设计稿 → 东林拍板 → 阶段 1+2（骨架）→ 阶段 3+第一批 → 第二批 → 第三批+键盘包 → 全量验收。每批可独立验收。
