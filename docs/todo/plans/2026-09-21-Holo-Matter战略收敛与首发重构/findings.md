# Findings: Holo Matter 战略收敛与首发重构

## 已确认的根因

- 现在的体验不是单点 UI 繁琐，而是产品同时暴露了规划草案、待办清单、Matter 和 Today 四层结构。
- 用户需要的不是管理这四层，而是 Holo 持续记住事情、判断卡点并给出当下一步。
- 旧实施方案已建立丰富领域模型，但当前最大风险是继续扩张功能，而不是缺功能。
- 当前工作区有大量并行未提交改动，本轮只新增方案文档，不修改业务代码。

## 复核结果

- Context Plan 卡的交互、真实落库路径和 Matter 激活路径均已复核。
- 单项任务不进“日本旅行”清单的分支已定位。
- Matter 激活、任务创建和 MatterLink 当前不是一个原子操作。
- Today 当前没有在返回前排除 Focus 已使用的 Agenda task。
- 现有四实体、Context Plan Draft、TodoList/Task、Rollout Policy 和测试骨架可复用。

## 当前代码事实

- `ContextPlanChatCard` 一张卡同时承担结论、个性化变化、任务列表、单项加入、批量加入、未知问题、依据、纠正、重新生成和 Matter 激活，已经超出一张行动卡能承担的决策密度。
- “日本旅行”归组错误根因已确认：`MessageBubbleView` 仅在 `creations.count >= 2` 时创建/匹配主题清单，而主流的单项加入每次只传 1 项，因此始终落到默认位置。
- 任务创建和 Matter 激活是两条独立链路：激活只创建 Matter、origin/conversation link 和 unknowns 对应的 Open Loop；已创建任务依赖事后补链。这不等价于“用户一次确认，Holo 整体接管”。
- `MessageBubbleView` 虽然拥有 `onOpenMatter`，但实例化 `ContextPlanChatCard` 时没有传入，因此“已加入进行中的事 → 查看”是无效操作。
- Today 快照先组装全部 Agenda，再独立解析 Primary Focus 和 Matter 卡，返回前没有从 Agenda 排除已被 Focus/Matter 投影的同一任务，重复展示是结构性结果。
- 后端 `personal_context_planning` Prompt 限制 `answerText` 和 `unknowns`，但不限制 `items` 数量，还要求输出多组内部字段；这会稳定制造内容密度，不是只改 UI 能解决。
- `TodoRepository` 与 `HoloMatterRepository` 生产环境都使用同一个 `CoreDataStack.shared.viewContext`，具备做真正单事务的基础；但现有 `createList` / `createTask` / `createContextPlanTask` 内部都会立即 `save`，必须新增一个唯一编排入口，不能在 UI 闭包中继续串多个仓储方法。
- 现有 Matter 四实体已能承担首发：Matter 记事项，Open Loop 记待确认，Link 关联任务/清单/对话，Event 留可追溯记录。首发不需要新增“计划步骤”实体，可直接以 TodoList + TodoTask 作为用户可见的执行计划。
- `HoloContextPlanDraft` 现有 `goalSummary` / `items` / `unknowns` / `dependencyEdges` 足以供首发落地；应先收缩 Prompt 和展示契约，而不是新造一套 V2 schema。
- 现有 Matter 测试覆盖 Repository、状态机、补链、展示策略和 Today Focus，但缺少“一次点击完成 Matter + 清单 + 全部任务 + Link + 下一步”的端到端原子性测试。
- `personal_context_planning` 当前是后端受管 Prompt v1，`PromptManager` 没有对应类型或后备模板。实施 Prompt 改动时需先补齐 iOS 后备真源，再同步后端并升版。

## Use Case 必须补齐的契约

- 之前的“用户旅程”仍留有大量实施自由：谁可以创建数据、什么时候算成功、重复计划怎么处理、中途杀进程怎么恢复、完成后 Today 怎么变，都没有成为单一契约。
- “另建同名 Matter”会同时带来清单同名风险；若用户明确另建，Matter 与 TodoList 都必须使用可区分名称，不能再被模糊匹配回老清单。
- “继续已有计划”不应默认合并新 Draft；首发应只打开已有计划，防止无预览地新增或覆盖任务。
- 一条真正完整的 Use Case 必须从对话输入一直覆盖到 Matter 完成、Today 退场和历史可回看，不能在“创建成功”处结束。
- 原方案要求模型输出 `dependencyEdges` 并按依赖选 ready task，但当前持久层没有依赖边存储契约；这会造成草案内正确、落库后丢失的假能力。
- `TodoTask` 本身没有可承担 Matter 计划顺序的字段；顺序应属于 Task 与 Matter 的关系，因此放在 `HoloMatterLink.planOrder` 而不是污染通用待办模型。
- 新 Use Case 已统一为 1 Matter + 1 List + 7 Tasks + 10 Links；原稿的 9 Links 统计遗漏了 origin、user message、list 三类链接中的一条，已纠正。
