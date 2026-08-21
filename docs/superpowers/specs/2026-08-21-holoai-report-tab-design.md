# Holo AI「报告 Tab」设计文档

- 日期：2026-08-21
- 状态：待东林评审
- 原型：`docs/design-mockups/holoai-report-tab-prototype.html`（6 屏，含可交互 Tab 切换）
- 阶段：头脑风暴已定稿方向 → 本文档为实施前设计规格

---

## 1. 背景与问题

Holo AI 页（ChatView）当前是纯对话单页：导航栏 + 消息流 + 4 能力胶囊（今日状态/最近分析/周期回放/规划目标）+ 输入栏。深度分析与周期回放以聊天卡片形态内嵌在消息流中，详情用 sheet 承载。

四个已确认的痛点（东林 2026-08-21 全选确认）：

| 痛点 | 现状表现 |
|------|---------|
| 能力不可见 | 深度分析只有一个胶囊露出，新用户感知不到能力深度 |
| 展示形态太轻 | 详情是「盖在聊天上的 sheet，下拉即关」，像附属品 |
| 找不回旧报告 | 报告生成完沉进聊天记录，翻找成本随时间递增 |
| 缺少「家」 | 分析是一次性消费品，没有「档案越来越厚」的累积感 |

## 2. 目标与非目标

**目标**：Holo AI 页升级为「对话 / 报告」双 Tab。报告 Tab = 档案库（找回 + 累积）+ 发起入口（可见）+ 全屏详情（正式感），一个家解决四痛。

**非目标**：
- 不改记忆长廊洞察 Tab 的任何现有内容（萃取观点/DailySense/热力图/LifePlan 台账/回看片段全部原样保留）；
- 不动底部导航结构（否决了顶层新 Tab 方案）；
- 不做报告分享/导出（后续版本再议）；
- 不改后端（见 §5，纯客户端改动，无需后端发版）。

## 3. 已拍板决策

| # | 决策 | 结论 | 依据 |
|---|------|------|------|
| 位置 | Tab 放哪 | AI 页内页级 Tab（对话/报告） | 中央 AI 按钮是全 App 最热入口，能力可见性只有在这里解决；长廊是次级目的地 |
| D1 | 报告 Tab 收哪些 | 深度分析 + 周期回放两类 | 今日状态=即时问答非报告；规划目标产物是目标，已有「我的目标」页这个家 |
| D2 | 对话页 4 胶囊去留 | 全保留；「最近分析」更名「深度分析」 | 发起动线不变避免高频操作降级；更名让能力名实相符 |
| D3 | 详情页形态 | sheet → fullScreenCover 全屏正式页 | 三处入口（聊天卡/报告 Tab/长廊门卡）进同一详情页，复用现有 v21 内容结构 |
| D4 | 长廊放档案还是门 | 门：顶部插一张「最新报告」卡跳转报告 Tab | 一个家两个门，避免两处维护同一列表；接活长廊现有半截链路 `agentRenderedResult` |
| 边界 | 长廊现有内容 | 零改动（除 P1 门卡插入） | 东林 2026-08-21 二次确认；语义分工：观点萃取=「你是什么样的人」（长期画像），报告=「Holo 定期写的分析文档」（带日期按范围） |

## 4. 信息架构与交互

### 4.1 页面结构

ChatView 整体变为：

```
ChatView
├── chatNavBar（现状保留：✕ / HOLO AI / ⚙）
├── pageTabs（新增：对话 / 报告，胶囊式分段，含红点位）
└── ZStack（常驻不销毁，照搬 MemoryGalleryView.tabContent 模式）
    ├── chatPane（opacity/allowsHitTesting 切换）—— 现有全部内容原样
    └── reportPane（首次切换到才构建，之后常驻）
```

- 默认落在「对话」Tab；进入页面、发消息、语音等一切现有行为不变。
- 切换用 ZStack + `opacity` + `allowsHitTesting` + `accessibilityHidden`，与长廊 `MemoryGalleryView.swift:123-136` 完全同构，保证聊天侧滚动位置与输入态跨切换存活。
- 红点：生成完成且用户尚未切到过报告 Tab 时，「报告」Tab 亮红点；切过去即消。P0 仅内存态（本次会话有效），不做持久化。

### 4.2 报告 Tab 内容（自上而下）

1. **发起区**（ReportLaunchCard）：
   - 主按钮「✦ 发起新分析」；范围胶囊四档：近30天/近3月/近半年/近1年（复用现有换范围档位，用胶囊不用 Menu，规避 Menu 嵌 Button 手势坑）；
   - 额度角标「本月深度洞察剩余 n/N」——复用现有额度预检链路（发起前预检已在 2026-08-20 批次实现），额度不足走现有升级引导文案，不在本方案新做；
   - 范围选择的实现（自审补强）：范围胶囊不改预填文案之外的任何参数——选「近3月」即预填「分析一下我最近三个月的数据趋势」，时间语义由既有意图解析链路（L2 通用组合规则 + 时间语义解析）消化，**无需新接口新参数**；
   - 并发发起沿用现有约束（额度预检在两个入口各自拦截），不新增并发控制。
   - 点发起 = 等价于对话胶囊发起（同一条 `runAnalysis` 链路），发起后**留在报告 Tab**，列表顶部出现生成中进度卡；用户可随时切到对话 Tab，聊天流同样落分析卡，两侧进度同源。
2. **报告档案列表**（按时间倒序，深度分析与周期回放混排）：
   - 深度分析卡：类型徽标 + 范围 + 日期 + **用户原始提问**（`question ?? rootUserQuestion`，引言行样式——先看到当时问了什么，再看 Holo 看出了什么）+ 结论摘要（`keyInsight`，缺失时退回 `narrativeSummary` → `directAnswer`；左侧类型色竖条）+ 尾行（观察×n/证据×n + 「读报告 ›」）；
   - 回放卡：类型徽标 + 周期（上周/7月）+ 日期 + 对账摘要；
   - 点击 → 全屏详情页（§4.3）；
   - 列表分页：首次 20 条，上滑追加。
3. **生成中卡**：报告发起后列表顶部出现实时状态卡；提示「可切回对话继续聊，完成时报告 Tab 亮红点」。失败态展示错误 + 重试（复用现有 Agent 失败分支）。
   - 状态文案与聊天卡同源（`HoloAgentChatStatusPresenter.display`：标题 + 细节 + 是否转圈，含暂停态）；系统无百分比数据，不虚构进度条。
   - **数据源双通道**（自审修订）：进度卡不能只订阅内存态的进度流——杀 App 重开后内存订阅失联，而对话流的消息恢复链路仍在跑，两侧会不一致。正确做法：进度卡的存在性以**持久化消息的 streaming 状态**为准（冷启动可恢复），实时状态文案用消息 content 派生。
4. **空态 = 能力橱窗**（ReportEmptyStateView）：**无已完成报告且无生成中任务时**展示「Holo 能为你写的报告」——深度分析/周期回放两张能力介绍卡 + 一条示例报告摘录 + CTA「发起我的第一份分析」。首次进 AI 页即完成能力教育，直击「能力不可见」。

### 4.3 报告详情页（形态升级）

- `AgentDeepAnalysisDetailSheet` 从 `.sheet` 挂载改为 `.fullScreenCover`，顶部加返回栏（‹ + 报告类型 + 范围与日期区间 + ⋯）；
- **迁移方式（自审修订，踩坑速查表命中项）**：现状详情页是 ChatView `activeSheet(item:)` 枚举中的一个 case（`:155` 挂载、`:1027` 附近分支），ChatView 已挂 5 个 sheet + 3 个 fullScreenCover。迁移 = 把该 case 从 `activeSheet` 枚举移除，新增独立的 `fullScreenCover(item:)` + `onDismiss` 中复位状态，逐条核对 `handleSheetDismiss` 现有复位逻辑不被破坏（速查表「sheet/fullScreenCover 关闭后界面异常：同一视图挂多个 sheet、presentation 状态未复位」直接命中）；
- 内容结构沿用现有 v21 版式（开场摘要 → 核心发现 → 观察与解读 → 证据 → 建议 → 数据口径），不重做；
- 聊天卡「查看完整报告」、报告 Tab 列表卡、长廊门卡（P1）三处进的是同一个详情页实例；
- 周期回放无独立详情页（内容即卡片）：报告 Tab 中点击回放卡 → 全屏展示现有 `PeriodReplayChatCard` 内容的阅读版（外层包全屏容器，不新造版式）。

### 4.4 发起的三条路（殊途同归）

报告 Tab 主按钮 / 对话胶囊 / 直接说话问分析 —— 走同一条生成链路、归入同一份档案。聊天流照旧落一张分析卡，卡上新增「已存入报告 ↗」回执 chip（点击跳报告 Tab）。

### 4.5 长廊门卡（P1）

洞察 Tab 章节开场之下、`DomainMemorySection()` 之上插入一张「🔭 它看懂了你」卡：显示最新一份报告的类型/范围/摘要/日期，点击 = 打开 AI 页并直落报告 Tab；右上「全部报告 ›」同效。实现上接活 `MemoryGalleryViewModel.agentRenderedResult`（现为加载后无 UI 消费的半截链路，`MemoryGalleryViewModel.swift:81,719-740`）。跨模块跳转复用现有深链/常驻层通道：`openRootScreen(.ai)` + 传递待消费的初始 Tab 意图（参照长廊 `consumeMemoryFocus` 的 pending-target 消费模式）。

## 5. 数据与可行性

- **报告数据现成**：深度分析结果以 `agentResultJSON`（完整 `HoloRenderedAgentResult`，含 `keyInsight`/`narrativeSummary`/`timeRangeAttribution` 等）持久化在 `ChatMessage` 实体上，含 `timestamp`；周期回放任务同样持久化且有恢复链路（`ChatMessageRepository.recoverablePeriodReplayJobs`）。
- **过滤条件精确**（自审核实）：档案查询 = `intent == "query_analysis" && agentResultJSON != nil`。全仓唯一写入方是 `HoloAgentAnalysisService.swift:492`（固定写 `query_analysis`），不会混入其他 Agent 问答；`isQueryAnalysis` 是基于 `intent` 字段的计算属性（`ChatMessageViewData.swift:332`），查询谓词直接用持久化的 `intent` 字段。
- **解码性能护栏**（自审修订）：`agentResultJSON` 含完整证据链，单条可能很大；列表页禁止整条解码——仅解码列表所需轻量字段（标题/摘要三级退让/时间窗/计数），或用 `JSONDecoder` 按需浅解；完整结果延迟到进入详情页再解码。
- **列表查询**：按上述谓词过滤，时间倒序，分页（首次 20 条，上滑追加）；范围 label 取自结果既有字段，范围缺失显示「自定义范围」。
- **纯客户端**：无需后端发版、无新接口、无 schema 变更。
- **额度口径沿用现状**：深度洞察独立池（免费 2 次/月，Plus 更多）；翻阅旧报告不消耗额度。

## 6. 技术方案（文件清单）

**新建**（项目用 PBXFileSystemSynchronizedRootGroup，新 .swift 自动编译，无需登记 pbxproj）：

| 文件 | 职责 |
|------|------|
| `Views/Chat/ReportTab/ChatReportTabView.swift` | 报告 Tab 主页（发起区 + 列表 + 空态分发） |
| `Views/Chat/ReportTab/ReportLaunchCard.swift` | 发起区（范围胶囊 + 额度角标 + 主按钮） |
| `Views/Chat/ReportTab/ReportArchiveCard.swift` | 档案卡（分析/回放/生成中/失败四态） |
| `Views/Chat/ReportTab/ReportEmptyStateView.swift` | 能力橱窗空态 |
| `Views/Chat/ReportTab/ChatReportTabViewModel.swift` | 档案查询/分页/摘要提取/生成中状态订阅/红点状态 |

**修改**：

| 文件 | 改动 |
|------|------|
| `Views/Chat/ChatView.swift` | 页级 Tab 骨架（ZStack 双 pane）+ 红点 + 详情挂载 sheet→fullScreenCover |
| `Services/AI/HoloAICapabilityProvider.swift` | 「最近分析」→「深度分析」：只改显示文案，不动能力 ID 与点击行为。**两处构造点都要改**——常驻胶囊（`:86-92`）与空态建议卡（`:54-60`），否则两处名称不一致 |
| `Views/Chat/Analysis/AgentDeepAnalysisCard.swift` | 新增「已存入报告 ↗」回执 chip |
| `Views/Chat/Analysis/AgentDeepAnalysisDetailSheet.swift` | 顶部返回栏，适配全屏形态 |
| `Data/Repositories/ChatMessageRepository.swift` | 新增报告档案查询（类型过滤 + 倒序 + 分页） |

**删除（P1，死代码清理）**：`Views/MemoryGallery/Components/MemoryInsightHeroCard.swift`、`Views/Chat/WeeklyObservationCard.swift`（全仓零引用，已核实）。

## 7. 分期

**P0（骨架跑通，一个可发布单元）**：
双 Tab 骨架 + 深度分析档案列表 + 全屏详情 + 发起区（范围/额度预检）+ 生成中进度卡与红点 + 空态橱窗 + 回执 chip + 胶囊更名。

**P1（生态补全）**：
周期回放归档（含回放全屏阅读版）+ 长廊门卡（接活 agentRenderedResult + 跨模块跳转）+ 死代码删除 + 详情页「就这份报告继续问它」。注意：现有 `ChatInputView` 的「继续追问这份分析」草稿条是「**最近一条**分析消息」语义；从报告 Tab 打开数月前的旧报告再追问，必须显式传递该报告的消息上下文，不能依赖草稿条的默认语义。

## 8. 边界与风险

| 风险 | 应对 |
|------|------|
| 聊天页性能敏感（刚做过滚动性能根治） | 复用长廊 ZStack+opacity 常驻模式，报告 pane 首次切换才构建；不往消息流里塞新东西 |
| fullScreenCover 迁移破坏现有 sheet 状态机 | 详情从 `activeSheet` 枚举 case 迁出为独立 `fullScreenCover(item:)`，`onDismiss` 复位 + 核对 `handleSheetDismiss`（详见 §4.3，踩坑速查表命中项） |
| 隐藏 pane 拦截触摸（速查表「全屏透明视图拦截触摸」命中） | 照搬长廊四件套：`opacity` + `allowsHitTesting` + `accessibilityHidden` 一个不少 |
| 大 JSON 拖慢列表 | 列表轻量解码，完整结果延迟到详情页（详见 §5 解码护栏） |
| 范围选择 Menu 嵌 Button 手势坑 | 一律用胶囊直选，不用 Menu |
| 旧操作降级 | 已核对映射表：4 胶囊点击行为全部不变；「查看完整报告」入口不变（仅详情从下拉关变为返回键关）；长廊六块零改动 |
| 老数据摘要缺失 | keyInsight → narrativeSummary → directAnswer 三级退让，范围缺失显示「自定义范围」 |

## 9. 测试与验收

- 单测（若新增测试文件，HoloTests 是手工挂文件模式，须登记 pbxproj 四处）：档案查询过滤与排序、摘要三级退让、空态判定、红点状态机；
- 自查 skill：交付前按操作路径走查（Tab 切换时输入态/滚动位置保持、生成中切走切回、三入口进同一详情页、fullScreenCover 关闭路径）；
- 真机验收清单：新用户首进空态 → 发起 → 切对话聊天 → 红点 → 读报告 → 长廊门卡跳转（P1）。

## 10. 后端同步

无后端改动，无需发版。（依协作约定主动声明：本方案纯 iOS 客户端改动。）
