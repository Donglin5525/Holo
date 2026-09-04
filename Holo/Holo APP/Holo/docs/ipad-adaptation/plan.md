# Holo iPad 适配完整方案 v1

> ⚠️ **状态：核心策略已被 v2 取代（2026-09-05，东林）**
> v1 的「限宽居中（720pt 窄列）」与「弹层用系统默认」两条决策，经 12.9 寸真机走查确认导致大屏大面积空白、两层导航并存，已推翻。
> v2 改为「左侧边栏导航 + 各模块按 iPad 信息密度全面重排 + 弹窗定宽政策 + 妙控键盘完整适配」，见 [v2-plan.md](v2-plan.md)。
> 本文档保留作为：v1 体检数据（§0 清单仍有效）、止血记录、快捷键与 detents 遗留清单的存档。
>
> 状态：**已拍板动工（2026-08-21，东林）**
> 日期：2026-08-21
> 结论先行：完整适配（大屏布局 + 横屏 + 外接键盘）约 **25–36 人天（5–7 人周）**，纯客户端改动，无需后端发版。
> 止血已完成：2026-08-21 已将全 App 锁竖屏 + 要求全屏（见 §3 Phase 0），iPad 用户不会再以分屏/任意宽度的变形形态使用。

---

## 0. 现状体检（2026-08-21 审计事实）

### 0.1 工程配置

| 项 | 现状 |
|---|---|
| 设备声明 | TARGETED_DEVICE_FAMILY = "1,2"（已声明 iPhone+iPad，App Store 上 iPad 可见可装） |
| 方向 | iPhone 仅竖屏；iPad 全 4 方向（竖屏双方向 + 左右横屏，2026-08-26 随适配放开） |
| 分屏/侧滑 | UIRequiresFullScreen = YES，iPad 全屏运行、不支持分屏/侧滑/多窗口（明确非目标，保留此开关） |
| 部署目标 | iOS 17.0；3 个 target：Holo / HoloTests / HoloWidgets |
| 自适应代码 | Phase 1 已建 `Utils/HoloAdaptiveLayout.swift`（限宽容器 + 断点常量 + size class 判断），骨架层已包裹 |
| 启动图 | LaunchScreen.storyboard 按 393×852（iPhone 竖屏）设计的全屏图，iPad 上会被拉伸铺满；artwork 待东林 |

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

### 2.3 尺寸来源治理（2026-08-26 修正：降级为低优先级技术债）

原判断「UIScreen.main.bounds 在 iPad 上必错」的前提是放开分屏。D4 拍板保留 RequiresFullScreen（不做分屏/多任务）后：**全屏 App 的 UIScreen.main.bounds 恒等于当前窗口尺寸，旋转时两者同步变化**，11 处现状用法在数学上依然正确，外接键盘时键盘通知避让量自然为 0——无需为想象中的分屏场景提前改造（少写防御性代码）。

遗留：`UIScreen.main` 是 Apple 已废弃的 API，未来某次发版若被强制收紧再统一替换为窗口/容器尺寸（替换清单在 §5.2）。图表（折线/饼/柱）全依赖 GeometryReader 宽度：被限宽容器包住后自动正确，属免费受益项。

### 2.4 键盘专项策略（快捷键已于 2026-08-26 落地）

1. **打字本身不用开发**：TextField/TextEditor/UITextView 系统级支持外接键盘输入；
2. **4 处手动键盘避让**：全屏前提下（§2.3 修正）数学正确、外接键盘时避让量自动为 0，**无需改造**；`ThoughtEditorView` 的 `isDocked` 判断（宽度≈屏宽才避让）已正确排除 iPad 浮动/分体键盘；
3. **快捷键（已实施，编译绿待真机验收）**：
   - Cmd+1/2/3 切主 tab、Cmd+, 设置、Cmd+N 按模块分流新建（任务/记账/想法；首页默认新建任务）、Cmd+W 关闭当前常驻模块——挂载在 ContentView 常驻层透明按钮（label 供 iPad 长按 Cmd 的快捷键提示浮层显示），事件经 `Utils/HoloShortcutBus.swift` 广播，HomeView 分流响应；
   - 聊天 **Cmd+回车发送、Cmd+. 停止生成**（ChatInputView 挂在发送/停止按钮上）。纯回车不改：TextField 竖轴多行无法区分 Shift+回车，改 submitLabel 会动 iPhone 软件键盘体验，违反零回归；
   - **Cmd+F 搜索降二期**：任务/财务/想法三模块的搜索形态各不相同（导航流/列表内状态），强行统一事件分发要写三套定制状态机，收益风险比差；
   - Esc：SwiftUI sheet 系统默认支持；想法编辑器的自动补全已有 Escape UIKeyCommand 先例；
   - 已知限制：HomeView 只在「今天」主 tab 存活，对话/我的 tab 下 Cmd+N/W/, 无响应（切回 Cmd+1 即可），后续如需覆盖可把设置 sheet 上移到 ContentView。

### 2.5 Widget

WidgetKit 天然按设备自适应尺寸，理论免改；验收阶段在 iPad 真机确认各尺寸渲染即可。

---

## 3. 分期计划与工作量（含 2026-08-26 实施进度）

| Phase | 内容 | 人天 | 状态（2026-08-26） |
|---|---|---|---|
| **0 止血** | 全 App 锁竖屏 + UIRequiresFullScreen | 0.5 | ✅ 完成（随适配推进，iPad 横屏已重新放开、iPhone 维持锁竖屏） |
| **1 基建** | HoloAdaptiveLayout 工具层 + ContentColumnContainer + 断点常量 + 常驻栈包裹 | 4–6 | ✅ 完成（编译绿）——`Utils/HoloAdaptiveLayout.swift` + ContentView 三 tab 包裹；LaunchScreen 待东林 artwork |
| **2 骨架与弹层** | 24 处旧 NavigationView 迁 NavigationStack；sheet 形态策略 | 5–7 | ✅ 主体完成（编译绿）——迁移 24 处；sheet 在 iPad 系统默认即居中卡片（D2 无需逐个改造）；14 处固定高度 detents 与 29 处 fullScreenCover 留真机走查（Phase 3）按观感定改 |
| **3 模块走查** | 逐模块大屏/横屏走查与修（图表宽度、固定宽度 35 处、文字排版） | 8–12 | 🔶 静态部分完成——全屏覆盖层 24 处内容限宽（编辑器/详情/表单/付费墙/看板/搜索等）、相机与画廊 6 处保持全屏；固定宽度扫描确认无超 600pt 元素（720 内容列内无溢出）；观感微调待真机走查反馈 |
| **4 键盘专项** | 快捷键体系 + 编辑器验证 | 4–6 | ✅ 快捷键全部落地（编译绿）：Cmd+1/2/3/,/N/W/**F** + Cmd+回车发送 + Cmd+. 停止；避让经 §2.3 修正无需改造；想法编辑器外接键盘实测留真机验收 |
| **5 横屏放开 + 回归** | 恢复 iPad 横屏配置；旋转状态保持；全量回归 | 4–5 | 🔶 配置已放开（编译绿）；真机走查矩阵（§5.3）待东林验收 |
| **合计** | | **25–36 人天** | 工程侧静态可做的部分已完成，剩余为真机走查驱动项 |

提交策略：沿用「每批编译过再提交、Phase 3 按模块分批」的惯例。

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

### 5.3 真机走查矩阵（东林统一验收用）

设备 × 场景：iPhone 竖屏（纯回归）｜iPad 竖屏｜iPad 横屏｜iPad + 外接键盘（重点：聊天、想法编辑、记账表单、搜索）

主流程：今天页 → 任务增改查 → 想法新建/编辑/转任务 → 记账 + 账单导入 → 长廊日/周/月浏览 → 习惯打卡+补签 → 健康页 → 深度分析 → 设置（导入导出/反馈）→ 订阅页 → Onboarding

旋转专项（同一页面横竖各一次）：输入中内容不丢、滚动位置保持、弹层不消失、常驻模块切换正常。

快捷键专项（外接键盘）：
- 长按 Cmd：屏幕应浮出快捷键提示面板（按钮名：前往今天/对话/我的、打开设置、新建、关闭当前模块）
- Cmd+1/2/3 三个主 tab 轮切；Cmd+, 开设置；在任务/想法/记账页 Cmd+N 开对应新建；在模块内 Cmd+W 退回首页
- 任务页/财务页（任意子 Tab）按 Cmd+F 应切到任务/账本并开搜索；想法页知识树视图按 Cmd+F 应切回列表并聚焦搜索框
- 聊天输入框打字：Cmd+回车发送、Cmd+. 停止生成、纯回车换行
- 软件键盘弹出让位：聊天页、想法编辑器、看板数值弹窗三处光标不被键盘遮挡

覆盖层形态专项（iPad）：编辑器/详情/付费墙/看板/搜索等全屏页内容应居中限宽（两侧留白）；相机与图片画廊应全屏铺满；各类 sheet 弹窗应为居中卡片（系统默认行为）。

---

## 6. 决策点（已于 2026-08-21 全部拍板）

| # | 决策 | **拍板结果** |
|---|---|---|
| D1 | 大屏形态：限宽居中 vs 左右分栏 | **限宽居中** |
| D2 | iPad 弹层风格：居中卡片 vs 保留底部抽屉 | **表单类居中卡片**，强底部心智的抽屉（语音输入等）保留底部形态 |
| D3 | 快捷键范围：基础包 vs 一步到位含 Cmd 组合 | **含 Cmd 组合键**（基础包 + Cmd+1/2/3 切主 tab、Cmd+N 新建、Cmd+F 搜索等进阶包一并做） |
| D4 | 横屏放开时点 | **随首版一起**（Phase 5 与前面阶段同批发版） |
| D5 | 素材 | iPad 启动图 artwork 东林后续提供（工程侧先完成自适应结构）；App Store iPad 截图上架前录 |

### 6.1 Cmd 快捷键清单（D3 拍板范围；2026-08-26 已实施除 Cmd+F 外全部）

**基础包**：Esc 关闭当前弹层/收起键盘（sheet 系统默认支持）；聊天 Cmd+回车发送、Cmd+. 停止生成（已实施）。

**Cmd 组合（2026-08-26 已实施，编译绿待真机验收）**：

| 快捷键 | 动作 | 状态 |
|---|---|---|
| Cmd+1 / Cmd+2 / Cmd+3 | 切到 今天 / 对话 / 我的 主 tab | ✅ |
| Cmd+N | 当前模块内新建（任务/记账/想法分流；首页默认新建任务） | ✅ |
| Cmd+, | 打开设置 | ✅ |
| Cmd+W | 关闭当前常驻模块、回到模块首页 | ✅ |
| Cmd+F | 打开当前模块的搜索：任务页切任务 Tab 开搜索、财务页切账本 Tab 开搜索、想法页切列表视图聚焦搜索框 | ✅ 已接入（TasksView/FinanceView 以触发计数转发给 switch 销毁式的子页；ThoughtListView 单实例直接聚焦） |

已知限制：对话/我的主 tab 下 Cmd+N/W/, 无响应（订阅方 HomeView 只在「今天」tab 存活），Cmd+1/2/3 与三模块的 Cmd+F 不受影响。

---

## 7. v2 升级路径：左右分栏（本版不做）

若后续要做原生分栏：把 `ContentView` 三 tab 树改为 `navigationSplitView`（侧栏=模块列表，详情=当前 NavigationStack 内容）；常驻模块栈需改为分栏下的惰性加载；19 处旧 NavigationView 清零（Phase 2 已做）和尺寸治理（§2.3）都是前置条件，届时无需返工。预估增量 15–20 人天。
