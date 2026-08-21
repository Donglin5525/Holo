# Holo iPad 适配完整方案 v1

> 状态：待东林拍板（决策点见 §6）
> 日期：2026-08-21
> 结论先行：完整适配（大屏布局 + 横屏 + 外接键盘）约 **25–36 人天（5–7 人周）**，纯客户端改动，无需后端发版。
> 止血已完成：2026-08-21 已将全 App 锁竖屏 + 要求全屏（见 §3 Phase 0），iPad 用户不会再以分屏/任意宽度的变形形态使用。

---

## 0. 现状体检（2026-08-21 审计事实）

### 0.1 工程配置

| 项 | 现状 |
|---|---|
| 设备声明 | TARGETED_DEVICE_FAMILY = "1,2"（已声明 iPhone+iPad，App Store 上 iPad 可见可装） |
| 方向 | ~~iPad 全 4 方向、iPhone 竖+左右横屏~~ → **2026-08-21 已锁：iPhone 仅竖屏；iPad 仅竖屏（正/反两个竖屏方向）** |
| 分屏/侧滑 | **UIRequiresFullScreen = YES 已加上**，iPad 上强制全屏，不再出现任意窗口宽度 |
| 部署目标 | iOS 17.0；3 个 target：Holo / HoloTests / HoloWidgets |
| 自适应代码 | `horizontalSizeClass` / `verticalSizeClass` / `userInterfaceIdiom` 全库 **0 处**——一行大屏适配代码都没有 |
| 启动图 | LaunchScreen.storyboard 按 393×852（iPhone 竖屏）设计的全屏图，iPad 上会被拉伸铺满 |

### 0.2 界面骨架（适配难度的根源）

根部是**三层自定义导航**，完全按「竖屏手机」心智写的：

1. `ContentView`：ZStack + switch 三主 tab（今天/对话/我的），非原生 TabView；
2. `HomeView`：又一层 ZStack 自定义导航——底部浮动栏 `BottomNavBar` + 七个常驻模块（任务/记账/习惯/想法/长廊/健康/AI）用 opacity/zIndex 叠放不销毁（`ResidentScreenRouteStack`）；
3. `SwipeBackModifier`：挂 UIKit 导航控制器实现的右滑返回手势。

### 0.3 适配对象数据清单（全部为实测统计）

| 类别 | 数量 | 说明 |
|---|---|---|
| NavigationStack | 127 处 / 74 文件 | 现代容器，iPad 上安全 |
| **NavigationView（旧式）** | **19 处 / 18 文件** | **iPad 大屏下会自动变左右分栏（master-detail），是必炸点**；集中在 Thoughts(9)、Habits(3)、Goals(2) |
| sheet 弹层 | 143 处 / 72 文件 | iPad 上默认变成居中大卡片，需统一形态策略 |
| fullScreenCover | 29 处 / 16 文件 | iPad 全屏覆盖，需逐个看观感 |
| presentationDetents | 48 处 / 42 文件 | 其中固定 `.height()` 14 处（清单见 §5.1） |
| GeometryReader | 36 处 / 25 文件 | 图表、周历网格、任务列表分栏等按容器宽算布局，横屏会变 |
| UIScreen.main.bounds | 11 处 | 全 App 直接读「设备屏幕」而不是「当前窗口」（清单见 §5.2） |
| frame(width: ≥100pt) | 35 处 / 19 文件 | 大固定宽度，iPad 上观感需逐个看 |
| 硬件键盘快捷键 | keyboardShortcut 0 处 | UIKeyCommand 仅 5 处（想法编辑器自动补全的 Esc/上下/回车） |
| @FocusState | 16 处 / 11 文件 | 焦点管理基础已有零星使用 |
| 手动键盘避让 | 4 处 | `KeyboardAvoidanceDisabler`、`ChatView`、`DailyKanbanView`、`ThoughtEditorView`，全用屏幕尺寸/手动算高度 |

规模：全 App 790 个 Swift 文件 ≈ 19.9 万行；Views 271 文件。模块文件数：Chat 43、长廊 34、想法 33、财务 30、设置 26、任务 22、习惯 18、目标 10、健康 9、看板 8、Onboarding 6、记账表单 6、日历 5、订阅 4、纪念日 4、AI 3、个人 2。

---

## 1. 目标 / 非目标

**目标**

1. iPad 全屏**竖屏**一等体验：布局自适应、不拉伸、不出现「放大手机 App」观感；
2. iPad **横屏**支持：横过来内容限宽居中、不变形；
3. **外接键盘**：打字输入（系统自带）+ 回车/Esc/方向键基础包 + 高频 Cmd 快捷键；
4. iPhone 现有行为**零回归**（继续锁竖屏）。

**非目标（明确不做）**

- 左右分栏导航（navigationSplitView）→ 作为 v2 升级路径（§7）；
- iPad 多任务（Split View / Slide Over / Stage Manager 多窗口）→ 保留 UIRequiresFullScreen；
- Apple Pencil 手写、Mac Catalyst。

---

## 2. 总体策略：限宽居中（推荐），不分栏

### 2.1 为什么推荐限宽居中

| 维度 | A. 限宽居中（推荐） | B. 左右分栏 |
|---|---|---|
| 做法 | iPad 上内容像「报纸栏目」居中，两侧留白/背景延续 | 左列表右详情（系统 Split View） |
| 骨架改造 | 一个全局容器组件，127 处 NavigationStack 不用动 | 三层自定义导航需重构为分栏树，127 处导航路径全要重新理 |
| 横竖屏 | 横竖同一套（留白变化而已） | 横竖切换要处理分栏折叠/展开状态 |
| 工作量 | 25–36 人天 | 40+ 人天 |
| 观感 | Instagram/Slack 紧凑风格，稳 | iPad 原生感强，但改造风险大 |

限宽宽度建议：**内容列最大 720pt 居中**（iPad 竖屏 768/810/834pt 宽，横屏 1024–1366pt 宽，内容列恒定 → 横竖切换零重排）。具体数值 Phase 1 出真机对比后定。

### 2.2 技术基建（Phase 1 落地）

1. **`HoloAdaptiveLayout` 工具层**（新建 Utils）：
   - 环境读取 `horizontalSizeClass`，暴露统一判断（如 `isRegularWidth`）；
   - **`ContentColumnContainer` 限宽容器组件**：compact 宽度自然撑满，regular 宽度限 720pt 居中 + 背景延伸；
   - 断点常量集中管理（内容列宽、弹层理想宽度），禁止散落魔法数字。
2. **常驻模块栈**：七个模块保持常驻内存策略不变，各自根视图包 `ContentColumnContainer`；
3. **弹层形态策略**（Phase 2 落地）：iPad 上 sheet 默认居中卡片——统一加理想宽度（表单类建议 540pt 居中）；抽屉类（语音输入等强底部心智的）单独评估保留底部形态；
4. **旧 NavigationView 清零**：19 处全部迁到 NavigationStack。这是**必做项**不是可选项——旧容器在 iPad 大屏会自动变分栏，直接炸版；迁移本身也是 iOS 17 该还的债；
5. **LaunchScreen**：storyboard 布局改自适应，需要东林出 iPad 尺寸启动 artwork。

### 2.3 尺寸来源治理

- `UIScreen.main.bounds` 11 处全部替换为「当前窗口/容器尺寸」（GeometryReader 或 windowScene）——锁全屏时两者恰好相等所以现在没炸，但**放开横屏后必须正确**，且这是 Apple 已废弃的 API；
- 图表（折线/饼/柱）全依赖 GeometryReader 宽度：被限宽容器包住后自动正确，属免费受益项。

### 2.4 键盘专项策略

1. **打字本身不用开发**：TextField/TextEditor/UITextView 系统级支持外接键盘输入；
2. **4 处手动键盘避让改造**：改用「当前窗口坐标系」的键盘帧通知；外接键盘时软件键盘不弹出、避让量自动为 0，顺带修复；`ThoughtEditorView` 用屏幕高减键盘高的算法在 iPad 上必错，重点改；
3. **快捷键分两包**：
   - 基础包（Phase 4 必做）：Esc 关闭弹层/收起键盘、聊天回车发送、Shift+回车换行、列表上下方向键移动；
   - 进阶包（视性价比二期）：Cmd+1/2/3 切主 tab、Cmd+N 新建、Cmd+F 搜索、Cmd+W 关闭模块；
4. **想法编辑器专项**：`MarkdownTextView.swift`（3457 行 UIKit 桥接）是全 App 键盘交互最深处，已有 5 处 UIKeyCommand 先例；外接键盘下回车/Esc/自动补全/工具栏联动需逐项验证修复，单列预算。

### 2.5 Widget

WidgetKit 天然按设备自适应尺寸，理论免改；验收阶段在 iPad 真机确认各尺寸渲染即可。

---

## 3. 分期计划与工作量

| Phase | 内容 | 人天 | 交付物/验收 |
|---|---|---|---|
| **0 止血（已完成 2026-08-21）** | 全 App 锁竖屏 + UIRequiresFullScreen | 0.5 | iPad 不再以分屏变形形态打开；本次已改 pbxproj 待提交 |
| **1 基建** | HoloAdaptiveLayout 工具层 + ContentColumnContainer + 断点常量 + LaunchScreen 自适应 + 常驻栈包裹 | 4–6 | iPad 真机：内容限宽居中、启动图不拉伸；iPhone 零变化 |
| **2 骨架与弹层** | ContentView/HomeView/BottomNavBar 大屏形态；sheet 理想宽度策略全局落地；14 处固定高度 detents 改自适应；29 处 fullScreenCover 观感过一遍；19 处旧 NavigationView 迁 NavigationStack | 5–7 | iPad 上弹层形态统一、无分栏炸版 |
| **3 模块走查** | 按「高频→低频」顺序逐模块大屏走查与修：今天/任务/想法/记账/长廊/习惯/健康 → 设置/订阅/纪念日/Onboarding；每模块过：图表宽度、固定宽度 35 处、文字排版、双列卡片 | 8–12 | 每模块真机截图走查通过，按模块分批提交 |
| **4 键盘专项** | 4 处避让改造 + 基础包快捷键 + 想法编辑器专项 + @FocusState 补齐 | 4–6 | 外接键盘全主流程可操作（不碰屏幕完成「新建想法→编辑→保存」） |
| **5 横屏放开 + 回归** | 恢复 iPad 横屏方向配置（保留 RequiresFullScreen）；旋转时状态保持专项（输入中/滚动位置/弹层不消失）；iPhone 继续锁竖屏；全量回归 | 4–5 | 真机走查矩阵（§5.3）全绿 |
| **合计** | | **25–36 人天 ≈ 5–7 人周** | |

提交策略：沿用「每批编译过再提交、Phase 3 按模块分批」的惯例；适配期间与功能开发的合并冲突风险集中在 `ContentView`/`HomeView`/各模块根视图，Phase 1-2 尽量连续做完。

---

## 4. 风险清单

1. **想法编辑器 `MarkdownTextView`（3457 行）**：键盘+布局双风险深水区，Phase 4 单列预算，预期可能超 2 人天 buffer；
2. **常驻模块栈 × 旋转**：七个常驻模块在旋转瞬间的布局缓存与状态保持是 Phase 5 最大回归面；
3. **自定义手势**：右滑返回/双击在 iPad 全屏正常，但放开横屏后需复验（历史上手势与子级滚动的冲突已有多次踩坑记录）；
4. **App Store 资产**：需要东林准备 iPad 启动图 artwork + App Store iPad 截图（截图在适配完成后录）；
5. 性能无忧：限宽策略下列表渲染量与 iPhone 相同，不引入 iPad 大屏性能债。

---

## 5. 实施用清单

### 5.1 固定高度 detents 14 处（Phase 2 逐个改自适应/理想尺寸）

ImportExportView:378(460)、AddFolderSheet:70(200)、PopupCalendarSheet:53,69(480/320)、AddListSheet:142(320)、RepeatPicker:412(400)、EditListSheet:158(360)、EditFolderSheet:73(200)、ExpandedCalendarView:120(320)、TaskDatePickerSheet:87,840(560/400)、Chat/Voice/VoiceInputSheet:82、HabitStatsView:163(320)、ThoughtEditorView:265(220)

### 5.2 UIScreen.main.bounds 11 处（Phase 1/4 改窗口/容器尺寸）

SwipeBackModifier:103、PopupCalendarSheet:219、ExpandedCalendarView:127、WeekView:87、ChatView:906、DailyKanbanView:73、ThoughtEditorView:929,944,957、FinanceLedgerView:671-672

### 5.3 真机走查矩阵（Phase 5 验收）

设备 × 场景：iPhone 竖屏（纯回归）｜iPad 竖屏｜iPad 横屏｜iPad + 外接键盘（重点：聊天、想法编辑、记账表单、搜索）

主流程：今天页 → 任务增改查 → 想法新建/编辑/转任务 → 记账 + 账单导入 → 长廊日/周/月浏览 → 习惯打卡+补签 → 健康页 → 深度分析 → 设置（导入导出/反馈）→ 订阅页 → Onboarding

旋转专项（同一页面横竖各一次）：输入中内容不丢、滚动位置保持、弹层不消失、常驻模块切换正常。

---

## 6. 需要东林拍板的决策点

| # | 决策 | 推荐 |
|---|---|---|
| D1 | 大屏形态：限宽居中 vs 左右分栏 | **限宽居中**（省 40% 工作量，v2 可升级分栏） |
| D2 | iPad 弹层风格：居中卡片 vs 保留底部抽屉 | **表单类居中卡片、强底部心智的抽屉保留** |
| D3 | 快捷键范围：基础包先做 vs 一步到位含 Cmd 组合 | **基础包先行**，进阶包看真机使用习惯再定 |
| D4 | 横屏放开时点：随首版一起 vs 竖屏先上、横屏后续版本 | **随首版一起**（横屏是本次目标之一，且限宽策略下横屏增量成本只剩回归） |
| D5 | 素材：iPad 启动图 artwork（Phase 1 需要）、App Store iPad 截图（上架前） | 东林排期 |

---

## 7. v2 升级路径：左右分栏（本版不做）

若后续要做原生分栏：把 `ContentView` 三 tab 树改为 `navigationSplitView`（侧栏=模块列表，详情=当前 NavigationStack 内容）；常驻模块栈需改为分栏下的惰性加载；19 处旧 NavigationView 清零（Phase 2 已做）和尺寸治理（§2.3）都是前置条件，届时无需返工。预估增量 15–20 人天。
