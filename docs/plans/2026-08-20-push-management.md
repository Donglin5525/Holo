# 推送管理 · 方案定稿（2026-08-20）

> **状态：已实施（4 批次完成，全量编译过，未提交）——待真机验收。**
> 实施批次：①财务两类调度基建 ②习惯按条（模型+调度+UI）③设置页两级化+fallbackEnabled 语义修正+死设置清理 ④编译复核+代码走查。
> 东林已拍板：本期做推送管理界面升级 + 账单到期提醒 + 预算超支提醒 + **习惯按条设提醒时间**（原计划下期，拍板提前）。
> 交互原型：`docs/design-mockups/push-management-prototype.html`（两级结构版，已评审通过）。
> **纯客户端改动，无需后端发版。**

## 0. 决策记录

| 决策点 | 结论 |
|---|---|
| 界面结构 | 两级：首页清单式总览（一行一类：状态摘要+开关）→ 详情页（说明/时间/预览文案） |
| 习惯提醒 | 每习惯三态：不提醒 / 跟随兜底（默认）/ 单独时间；同一习惯一天最多提醒一次 |
| 账单到期提醒 | 本期新增，随周期账单挂 **Plus**（复用 `.billingCycle` 付费墙 context） |
| 预算超支提醒 | 本期新增，**免费**；超支当天一次 + 回到线内不重复 + 再超支再提醒 + 每日全局最多 1 条 |
| 不做 | 每日回放提醒、记忆确认提醒、LifePlan 提醒（易骚扰/重复）；App 内勿扰时段（iOS 系统已管） |
| 清理 | `dailyAutoGenerationEnabled` 死设置删除；`smartReminderEnabled/Schedule` Core Data 属性**保留**（无消费方，删属性要写迁移，收益低） |

## 1. 现状事实（2026-08-20 调研核实）

- 通知全部为本地通知（无 APNs），category 7 个：task / dailyReminder / habitReminder / weeklyBrief / memoryInsight / anniversary / goalRisk（`TodoNotificationService.swift:16-24`）。
- 滚动排期基类 `RollingNotificationScheduler`（早报/习惯/晨报共用）；AI 回放独立在 `MemoryInsightNotificationService`。
- 设置页 `NotificationSettingsView`（`Views/Tasks/`，双入口：`SettingsView.swift:525` + `TaskListView.swift:321`，重构后双入口保留）。
- 周期账单：`SpendingProject`（`kind=recurring`），**`nextOccurrenceDate: Date?` 指向下一个未发生期**（补账时推进），`SpendingProjectRepository.allProjects()` 可取全量（`FinanceRepository.swift:647`）。
- 预算：`BudgetRepository.computeBudgetStatus(budget:) -> BudgetStatus?`（`isOverBudget = progress >= 1.0`、`overPercent`、`spentAmount` 现成，`BudgetRepository.swift:173`）。
- Habit Core Data **程序化构建**（无 .xcdatamodeld，`CoreDataStack+HabitEntities.swift:15`），轻量迁移已开启（`CoreDataStack.swift:78-81`），加带默认值属性自动迁移。
- 深链 `.finance` / `.addTransaction` 已存在（`DeepLinkState.swift:45,49`）——**不碰 DeepLinkState.swift / HomeView.swift**（工作区有并行会话改动，避开）。
- Plus 拦截：`HoloPlusActionCoordinator.shared.requirePlus(context: .billingCycle)`；身份判定 `HoloEntitlementState.shared.isPlusActive`。

## 2. 分组结构（首页四组）

```
每日 · 每周汇总：每日早报 / 习惯打卡提醒 / 周一晨报 / AI 回放(周月合一)
财务提醒(新)：周期账单到期提醒(PLUS) / 预算超支提醒
按条设置的提醒：任务提醒(12条→) / 纪念日提醒(3个→)
AI 主动提醒：目标风险提醒(2个目标→)
```

入口行点击 = dismiss 设置 sheet + `navigateToScreen(对应模块)`；不接管单条级开关。

## 3. 详案

### A. 通知设置页两级化（批次3）

- `NotificationSettingsView.swift` 由 `Views/Tasks/` 挪至 `Views/Settings/`（git mv；项目为 PBXFileSystemSynchronizedRootGroup，无需改 pbxproj）。
- 首页：权限轻量行（未授权才显眼）→ 四组 9 行（`图标 名称 … 摘要 [开关|›]`）。开关行点行进详情、拨开关即时生效；入口行 dismiss+跳模块。
- 详情页（push）：通用型（早报/晨报/预算）= 说明卡+开关+时间+「预览通知样式」（发送该类真实文案测试通知）；习惯型 = 兜底开关/时间+习惯三态列表+规则卡；AI回放型 = 周/月两开关；账单型 = 开关+提前量 chips+时间（非 Plus 锁定，点击 `requirePlus(context: .billingCycle)`）。
- 摘要联动：开关/时间变化即时重算行摘要（如「兜底 20:30 · 3 个单独」「已关闭」）。
- 旧操作→新入口映射自查（防回退）：早报/习惯/晨报/AI回放开关与时间路径不变深、测试通知保留、任务页 bell 入口不变、AISettingsView 的 AI 回放区本期不动。

### B. 账单到期提醒（批次1，Plus）

- category `TODO_BILL_DUE`；新文件 `Services/BillDueReminderScheduler.swift`。
- 设置 UserDefaults：`holo.billDue.enabled`(默认 true) / `holo.billDue.advance`(0|1|3，默认 1) / `holo.billDue.hour/minute`(默认 9:00)。
- 排程：取 `isRecurring && !isPaused && hasRemainingOccurrences` 且 `nextOccurrenceDate` 有效的项目，对每个算 `提醒日 = nextOccurrenceDate − advance 天`；提醒日 ≥ 明天才排（已过不追发），`UNCalendarNotificationTrigger` 年月日+时分，identifier `holo.billDue.{projectId}`（重排先清前缀）。
- 非Plus 不排程（排程时检查 `isPlusActive`；权益变化靠下次数据变化/启动重排收敛）。
- 监听 `.financeDataDidChange`（debounce 1s）+ `handleAppActivity()`（启动/回前台，HoloApp 现有两处调用点各加一行）。
- 文案：`{name}{明天/后天/N天后}到期` / `周期账单 ¥{amount} · {M月d日}扣款，记得留足余额`；点击深链 `.addTransaction`（在 `TodoNotificationService.didReceive` 分发，不碰 DeepLinkState）。

### C. 预算超支提醒（批次1，免费）

- category `TODO_BUDGET_OVERRUN`；新文件 `Services/BudgetOverrunNotificationService.swift`。
- 设置：`holo.budgetOverrun.enabled`（默认 true）。
- 触发：`.financeDataDidChange` debounce 1s 检查 + `handleAppActivity()`；遍历各账户 Budget → `computeBudgetStatus`。
- 频控状态机（UserDefaults，key `holo.budgetOverrun.state.{budgetId}`）：进入超支且未标记 → 发+标记；回到线内（progress<1）→ 清标记（下次再超再发）。叠加每日全局 1 条（`holo.budgetOverrun.lastGlobalDay`），多条同超取超出比例最大者。
- 发送：即时 `center.add`（无 trigger；App 前台由现有 `willPresent` 弹横幅）。
- 文案：`「{预算名}」预算超支了` / `已花 ¥{spent} · 预算 ¥{amount}（超出{pct}%），回到线内前不再提醒`；预算名=总预算用「本月总预算」，分类预算用分类名；点击深链 `.finance`。

### D. 习惯按条提醒（批次2）

- 模型：Habit 实体加 `reminderMode: String`（默认 "follow"，枚举 follow|solo|none）、`reminderHour: Int16`（默认 9）、`reminderMinute: Int16`（默认 0）。同步 `Habit.swift` / `Habit+CoreDataProperties.swift` @NSManaged 与计算属性。轻量迁移自动生效。
- `HabitReminderScheduler` 改造（`makeRequests`）：
  - solo 组：打卡型且 `!completedToday` 且未归档 → 各排 `UNCalendarNotificationTrigger`(自己时分)，identifier `holo.habitReminder.solo.{habitId}`；文案 `「{name}」还没打卡 · 已连续 N 天，今天别断了`。
  - follow 组：打卡型且 `!completedToday` 且 mode=follow → 兜底时间一条汇总（沿用现有单/多文案），identifier `holo.habitReminder.fallback`。
  - 「同一习惯一天最多一次」由分组天然保证（solo 的不进 fallback）。
- UI 三处：
  - `AddHabitSheet`：打卡型时显示「打卡提醒」区块（radio 三选一 + solo 展开时间行，默认 follow）。
  - `HabitDetailView`：同区块编辑（显示当前值）。
  - 设置页习惯详情：兜底开关/时间 + 习惯列表（每行三态值，点击弹三选一 confirmationDialog 或 sheet，参照 `sheet(item:)` 惯例避免 UITextView 竞态坑）。
- 数值型习惯不显示区块、不参与提醒；Repository 创建/更新链路保存三个字段。

### E. 收尾（批次3）

- 删 `MemoryInsightScheduleSettings.dailyAutoGenerationEnabled` 及残留 UI（先全工程 grep 确认无消费方）。
- `smartReminderEnabled/smartReminderSchedule` 属性保留不动（已在调研确认无消费方）。

## 4. 实施批次（每批编译过再进下批）

1. **批次1**：B+C 财务两类（新 Scheduler/Service、category、didReceive 分发、HoloApp 接线；不碰设置页 UI）。
2. **批次2**：D 习惯按条（模型+调度+三处 UI）。
3. **批次3**：A 设置页两级化（挪文件+重构+新类型接入+入口行跳转）+ E 收尾清理。
4. **批次4**：全量编译 + 按验收清单自审。

## 5. 验收清单（自审 + 真机）

- [ ] 首页一屏扫完：9 行状态摘要正确，开关拨动摘要即时变。
- [ ] 未授权状态：推送行禁用态；授权按钮流程不变。
- [ ] 习惯：solo 习惯在自己时间收到单条；follow 习惯兜底时间一条汇总；solo 过的不进兜底；全打卡当天静默；数值型不参与。
- [ ] 习惯表单三态创建/编辑回显正确。
- [ ] 账单到期：提前 N 天 9:00 收到；非 Plus 不排；点击进记一笔。
- [ ] 预算超支：超支当天一条；回线内再超再发；同日多条只发一条；点击进财务。
- [ ] 旧入口不回退：任务页 bell、设置页入口、AISettingsView AI 回放区、测试通知。
- [ ] 深浅色两种模式走查。
