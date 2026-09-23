# AI 建任务确认卡升级方案（提醒 + 清单就地设置）

- 日期：2026-09-22
- 状态：已实施（一二期合并交付），单测 16/16 绿 + worktree 隔离编译绿，待模拟器走查与真机验收
- 拍板记录：东林 2026-09-22 —— 一二期一起搞；footer 重复 bug 顺修；默认提醒亮出来（「15 分钟前」可见可改）；二期「更多调整」落地为「调整内容」弹层（标题/条目/描述/优先级/重复就地编辑），不另做完整表单跳转
- 实施说明：清单名未指定时显示「收件箱」（真实落点）；详情页「日期与时间」弹窗的提醒区已换用共用 TaskReminderEditor；详情页清单选择弹窗因与删除确认等页面状态强耦合本轮未强换，新增独立 TaskListPickerSheet 供确认卡使用
- 已知无关失败：ChatCardDataTests.testPlanningRunPersistWritesThroughEachTransition（测 HoloContextPlanRunController 状态机，与本改动零交集，工作区并行在途态下红，留全量回归定性）
- 范围：纯 iOS，无后端发版
- 关联：财务确认卡模式（TransactionChatCard）、AI 建任务 listName 归清单（已发版 220ce02fc）、reminderDates 多提醒（已发版 v31）

---

## 八、追加修复：绝对提醒默认时刻锚定任务日期（2026-09-23 东林真机实锤）

**现象**：「提醒我明天带包纸来公司」→ 任务日期正确 9.24；打开提醒弹层点「添加提醒时刻」，生成的却是 9.23 17:45（打开时刻+1h）——提醒日早于任务日，无效提醒。

**根因**：`TaskReminderEditor` 添加按钮写死 `Date().addingTimeInterval(3600)`，与任务日期零关联。

**方案**（东林已看规划，待确认后实施）：
1. 默认时刻锚定任务日：有截止日期 → 该日 09:00（9 点已过给当天最近整点）；无日期 → 保留 now+1h。
2. 打开提醒弹层预填一条「任务日 09:00」建议（仅当尚无任何提醒；草稿态，确认创建才落库；详情页不受影响）。依据：用户原话「提醒我」已表达提醒诉求，预填=把诉求落成可见可改的值。
3. 锚定算法收口为共享纯函数（TaskPendingDefaults）+ 单测，杜绝别处再写「取现在」。

**范围**：TaskReminderEditor / TaskReminderPickerSheet / ChatView 接线 + 单测；纯 iOS 无发版。

**实施记录（2026-09-23）**：已完工两轮交付——`TaskPendingDefaults.defaultAbsoluteTrigger(anchorDate:now:)` 纯函数收口锚定算法（任务日 09:00 / 当日 9 点已过给最近整点 / 无日期退回 now+1h）；提醒弹层打开时预填一条任务日 09:00 建议（仅绝对模式且空列表时，草稿态点完成才写回）；「添加提醒时刻」按钮同锚。并行会话恰在同日把弹层路由拆出 ChatTaskEditSheets.swift（栈溢出三修），anchorDate 接线落在拆出的新文件里。单测 19/19 绿（含新增 3 条锚定）。

**QA 两轮实锤**：首轮冒烟抓到「弹层壳漏把 anchorDate 转发给内嵌编辑器」——预填路径已锚、添加按钮仍 now+1h；补一行转发后二轮复验 PASS（新增默认=任务日 09:00，滚轮一致）。教训：同层组件传参要穿到底，单测盖不住 UI 转发层，必须冒烟。纯 iOS 无发版。

---

## 一、背景与问题（截图实锤）

东林真机截图：「提醒我明天请孙老师喝奶茶」→ AI 生成任务确认卡。

现状四个问题：

1. **「提醒」在卡上不存在**。用户话里明说「提醒我」，卡上只有「日期：9月22日」，没有任何提醒时间字段和设置入口。想设提醒必须：确认创建 → 点卡片进详情页 → 点「时间」→ 弹窗里选提醒 → 确定（4~5 步）。
2. **清单归属完全不可见**。AI 有「匹配或建清单」能力（listName 通道），但确认卡不显示清单，用户确认前不知道任务会放哪、也改不了；结果只在确认后的回执文案里出现。
3. **确认卡是纯只读**。财务确认卡至少有「分类不准？点击修改」入口；任务卡只有「取消 / 确认创建」，AI 听错了只能取消重说（再赌一次 AI 猜对）。
4. **顺带发现一个显示 bug**：截图上「日期：9月22日」出现了两次（卡身一次、底部汇总行一次），重复渲染。

链路层面的原因（代码事实）：

- 确认卡 UI：`Views/Chat/Cards/TaskChatCard.swift`——只读渲染 title/description/subtasks/footerText，无任何可编辑字段；`TaskCardData`（`Models/AI/ChatCardData.swift:605-693`）甚至不含 listName 字段。
- 执行侧其实早就支持：`IntentRouter.handleCreateTask`（`Services/AI/IntentRouter.swift:482-583`）已支持 `reminderDates`（用户明说的绝对提醒）和 `listName`（匹配或建清单）；`renderData` 是开放通道，确认时重放路由会原样传过去。**即：执行层不缺能力，缺的是确认卡上的「可见 + 可改」。**

## 二、目标体验（前后对比）

**现在**：说一句话 → 看卡（只能看）→ 确认 → 进详情页 → 点时间 → 选提醒 → 保存。清单放哪全程不知道。

**之后**：说一句话 → 确认卡上「日期 / 提醒 / 清单」三行都能看、都能点开改 → 顺手把提醒选了、清单挑了 → 点「确认创建」一步到位。确认 = 核对 + 微调 + 放行，不再需要二次进详情页补设置。

设计原则（与财务确认卡对齐并升级）：财务是「卡上展示 + 单字段跳完整表单改」；任务是「卡上展示 + 高频字段就地弹层改」——因为任务的高频调整诉求就集中在提醒和清单两个字段，就地改比跳表单更快。

## 三、方案详设

### 3.1 确认卡新结构（TaskChatCard 待确认态）

从上到下：

1. 头部：icon「任务待确认」+ 待确认 badge（不变）
2. 标题（不变）
3. 描述、子条目（有则显示，不变）
4. **设置区（新增，本次核心）**：
   - **日期行**：📅 9月22日 14:00（全天则不显示时刻）。点开系统 DatePicker 弹层可改。
   - **提醒行**：🔔 显示当前提醒状态——AI 识别到的提醒 / 默认「提前15分钟」（有截止时刻时）/ 「未设置」（全天任务）。点开提醒选择弹层（见 3.2）。
   - **清单行**：📁 显示归属——AI 的 listName 匹配结果 / 「将新建清单 X」（AI 给了名但没匹配到）/ 「收纳箱」（AI 没给清单，即真实默认落点）。点开清单选择弹层（见 3.3）。
5. 重复任务 chip（不变）
6. 按钮：取消 / 确认创建（不变，确认中/失败态逻辑不变）
7. **去掉底部 footerText 汇总行**（「日期：x · 提醒：a、b」）——信息已结构化展示，顺修重复渲染 bug。

已确认态 / 取消态卡片：保留现有形态（含「补充条目」），仅同样去掉重复的 footer。

### 3.2 提醒选择弹层（新组件，轻量）

复用现有提醒语义（`TaskReminder` 双模式）与组件（`ReminderChip`、FlowLayout）：

- **任务带截止时刻**：预设快捷 chips 多选——「截止时 / 提前5 / 15 / 30分钟 / 1小时 / 1天」（`TaskReminder.presetOptions` 现成）+「自定义时刻」入口（DatePicker 加绝对提醒）。
- **全天 / 无日期任务**：绝对提醒时刻列表（可删）+「添加提醒时刻」（默认当天 9:00 起步）——与任务详情页 TaskDatePickerSheet 的无截止日分支同语义。

组件落点：新建 `TaskReminderPickerSheet`，从 `TaskDatePickerSheet.swift:413-512` 的提醒区抽公共逻辑；详情页本轮不动（二期可换共用）。

### 3.3 清单选择弹层（新组件）

复用任务详情页 listPickerSheet（`TaskDetailView.swift:1841-1965`）的能力，抽出独立组件：

- 列表：收纳箱（=nil）+ 分组下的清单 + 未归组清单 +「新建清单」。
- AI listName 的**预演展示**：需要把 `TodoRepository.matchOrCreateList`（`Models/TodoRepository.swift:925-961`）拆成两步——`matchList(named:)` 只读匹配（不落库）+ 确认时才 `createIfNeeded`。卡上显示匹配结果；未命中显示「将新建清单 X」，点确认才真建（避免用户取消后留下空清单）。

### 3.4 数据链路（改动最小路径）

1. `TaskCardData` 增加 `listName` 字段；确认卡渲染时对 listName 做只读预演匹配。
2. 用户在卡上的任何修改**写回 `renderData`**：提醒覆盖值、清单选择、日期修改。`renderData` 是现成开放通道（`originalInput`/`listName`/`reminderDates` 已在其中流转），确认时 `ChatViewModel.confirmPendingTask` → `IntentRouter.route` 原样重放。
3. `IntentRouter.handleCreateTask` 增加一层优先级：**卡上用户改过的值 > AI 识别值 > 现有默认值**（默认值逻辑不变：有截止时刻默认提前15分钟，全天默认无提醒）。相对提醒（如「提前1小时」）需要 renderData 约定新键（如 `userReminderOffsets`），绝对提醒可复用 `reminderDates` 通道。

### 3.5 边界（本轮不做）

- 不动任务详情页现有编辑流程（手动管理场景）。
- 不做卡上改标题 / 描述 / 子条目 / 重复规则——识别错标题一般取消重说更自然；若后续有需求，二期加「更多调整」入口跳完整编辑表单（对齐财务的 AddTransactionSheet 模式）。

## 四、改动范围预估

| 改动 | 文件 | 性质 |
|---|---|---|
| 确认卡设置区 UI + 去 footer | `Views/Chat/Cards/TaskChatCard.swift` | 改 |
| TaskCardData 加 listName | `Models/AI/ChatCardData.swift` | 改 |
| 提醒弹层（新） | `Views/Tasks/TaskReminderPickerSheet.swift`（暂名） | 新增 |
| 清单弹层（新） | `Views/Tasks/TaskListPickerSheet.swift`（暂名，从 TaskDetailView 抽） | 新增 |
| 弹层挂载 + 修改写回 renderData | `Views/Chat/ChatView.swift`、`ChatViewModel.swift` | 改 |
| 用户覆盖优先级 + 相对提醒通道 | `Services/AI/IntentRouter.swift` | 改 |
| matchList 只读拆分 | `Models/TodoRepository.swift` | 改 |
| 新组件挂 pbxproj | `Holo.xcodeproj/project.pbxproj` | 改（注意并行会话在途，按 hunk 限定暂存） |

无后端改动、无 CloudKit schema 变更、无新权限。

## 五、拍板点（3 个）

1. **AI 没提清单时，清单行默认显示什么？**
   建议：显示「收纳箱」——它是当前真实的默认落点，所见即所得；不偷偷改成「上次用的清单」（那会悄悄改变现有创建行为）。
2. **默认提醒值要不要在卡上亮出来？**
   建议：亮出来（「提前15分钟」可见可改）。现在这个默认是静默的，用户根本不知道建出来的任务带了提醒；可见才可核对。（另一种做法是显示「未设置」仅当用户点开才加提醒——更克制但默认行为变得不可见，不推荐。）
3. **日期行本轮是否就支持点开修改？**
   建议：做。成本是一个系统 DatePicker 弹层，收益是三行设置区交互一致；若砍掉，用户改日期仍要取消重说。

## 六、分期

- **一期（本方案主体）**：设置区三行（日期/提醒/清单）+ 两个弹层 + 覆盖优先级链路 + footer 去重。
- **二期（可选，另立项）**：标题/描述/子条目就地编辑、「更多调整」完整表单入口、详情页换用共用提醒弹层。

## 七、验证计划

1. 单测：IntentRouter 覆盖优先级（用户改 > AI > 默认）三分支；listName 预演匹配不落库、确认才建；全天/带时刻两种提醒模式序列化。
2. 模拟器走查（ios-qa，无头）：说「提醒我明天请孙老师喝奶茶」→ 卡上选提醒时刻 → 换清单 → 确认 → 任务详情页核对提醒与清单正确；再走一条「明天下午3点开会」验证相对 chips；一条主题性多待办验证合并卡。
3. 回归：财务确认卡不受影响（共用 MessageBubble 回调链）。
