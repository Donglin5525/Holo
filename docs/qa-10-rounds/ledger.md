# QA 十轮走查 · 问题台账

> 计划文档：`docs/plans/2026-09-06-qa-ten-round-walkthrough-plan.md`
> 编号规则：R{轮次}-{序号}；分级：P0 崩溃/数据丢失，P1 功能不可用/明显卡顿/流程走不通，P2 体验瑕疵。

## 状态汇总

| 轮次 | 发现 | P0 | P1 | P2 | 已修复 | 待拍板 | 真机项 |
|---|---|---|---|---|---|---|---|
| 第 1 轮 稳定性与数据安全 | 12 | 2 | 5 | 5 | 8（含测试基建） | 0 | 0 |

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
