# 长期成本 Implementation Plan

**Goal:** 在财务统计中增加“长期成本”功能，统一管理周期性支出与一次性购买，并按使用次数/天数计算实际成本。

**Architecture:** 新增独立的 `SpendingProject` Core Data 实体，交易仍然使用现有 `Transaction`；项目通过关联交易 ID 记录自动生成或手动关联的流水。统计页新增入口和项目总览，详情页负责编辑规则、记录使用和展示成本。周期项目在进入长期成本页时按 `nextOccurrenceDate` 幂等补齐到今天的流水，一次性项目不自动重复记账。

**Tech Stack:** SwiftUI、Core Data 动态模型、现有 FinanceRepository、standalone Swift 测试。

---

## 已确认的产品规则

- 入口：`统计`页增加“长期成本”入口，不新增底部 Tab。
- 项目类型：`周期性支出`、`一次性购买`。
- 周期项目字段：金额、周期（月/年）、开始日期、下次扣款日、分类、账户、是否自动生成流水、启用/暂停状态、结束条件（无限期/结束日期/总周期数）。
- 一次性项目字段：购买金额、购买日期、预计使用结束日期或使用年限、关联购买流水。
- 使用记录：项目详情提供“今天使用了”动作；一次操作增加使用次数，并在当天首次使用时增加使用天数。
- 成本口径：周期项目展示月均承诺与累计支出；一次性项目展示累计使用天数、日均成本和单次成本（若有使用次数）。
- 周期项目默认自动生成流水；生成必须幂等，不能因重复进入页面产生重复账单。
- 删除项目不删除已生成的普通账本流水；暂停项目停止后续自动生成。
- 周期项目默认展示结束条件并在达到结束日期或总周期数后自动停止生成，不再继续调度后台任务。

## Task 1: 新增 Core Data 项目模型

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Models/SpendingProject.swift`
- Create: `Holo/Holo APP/Holo/Holo/Models/SpendingProject+CoreDataProperties.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Models/CoreDataStack+FinanceEntities.swift`

**Steps:**

1. 增加 `SpendingProject` 类型枚举、周期枚举和 NSManagedObject 属性：id、name、kind、amount、startDate、endDate、frequency、nextOccurrenceDate、isPaused、autoGenerateTransaction、usageCount、usageDayCount、lastUsedDate、category、account、linkedTransactionIDs、createdAt、updatedAt。
2. 在动态 Core Data 模型中注册实体及索引；可选字段保持兼容旧数据库，默认值保证已有用户数据不受影响。
3. 增加计算属性：`isRecurring`、`dailyCost`、`perUseCost`、`monthlyCommitment`、`isActive`。
4. 增加模型纯逻辑 standalone 测试，覆盖日均成本、单次成本、月度金额换算和无使用记录时的 nil/0 结果。

## Task 2: 增加项目仓储与周期流水生成

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Models/SpendingProjectRepository.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Models/FinanceRepository.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Models/SpendingProjectRepositoryTests.swift`

**Steps:**

1. 实现项目查询、创建、更新、暂停、删除和“今天使用一次”操作。
2. 创建周期项目时生成首个 `nextOccurrenceDate`；进入列表时补齐所有已到期周期，使用项目 ID + 日期作为幂等键。
3. 自动流水复用现有分类、账户和 Transaction 创建逻辑，写入项目关联 ID；项目删除只解除项目关系，不删除交易。
4. 支持一次性项目关联现有交易，未关联时允许只作为成本对象存在。
5. 流水补齐完成后发送现有 `financeDataDidChange` 通知，账本和统计能够刷新。
6. 测试：创建项目、暂停不生成、重复同步不重复、跨多个月补齐、删除不影响交易、使用次数与使用天数去重。

## Task 3: 增加长期成本总览与详情界面

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Views/Finance/SpendingProjectsView.swift`
- Create: `Holo/Holo APP/Holo/Holo/Views/Finance/SpendingProjectDetailView.swift`
- Create: `Holo/Holo APP/Holo/Holo/Views/Finance/AddSpendingProjectSheet.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Finance/FinanceAnalysisView.swift`

**Steps:**

1. 在统计页现有内容顶部增加“长期成本”入口卡片，显示每月承诺、进行中的项目数和一次性项目日均成本。
2. 总览页分为“周期性项目”和“一次性购买”两组；空态提供两个明确 CTA：“添加周期支出”“记录一次性购买”。
3. 项目行展示名称、项目类型、金额、下一次扣款/已使用天数和关键成本指标。
4. 详情页展示项目摘要、成本计算、使用统计、关联流水；提供“今天使用了”、编辑、暂停/恢复、删除。
5. 表单根据项目类型动态显示字段；金额、名称、日期必填，周期与频率校验，结束日期早于开始日期时阻止保存并给出中文提示。
6. 加载、空态、保存失败、自动补账失败均使用现有财务模块的提示风格；自动补账失败不阻塞查看已有项目。

## Task 4: 接入现有账本与统计刷新

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/Finance/FinanceLedgerView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Finance/FinanceComponents.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Finance/Analysis/OverviewTabView.swift`

**Steps:**

1. 自动生成的交易沿用现有交易行和分类图标，仅在详情或备注中显示来源项目，不改变普通账本的基本展示。
2. 在统计总览增加长期成本摘要，点击进入项目列表；现有月度统计继续基于真实 Transaction，不额外重复计入项目金额。
3. 账本编辑或删除关联交易时，不删除项目；项目详情展示“流水已被删除/未找到”状态并允许重新关联。
4. 验证统计、账本、项目页之间的通知刷新和返回路径。

## Task 5: 验证与交付

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo.xcodeproj/project.pbxproj`（仅在新增文件未自动纳入工程时）
- Modify: `Holo/Holo APP/Holo/HoloTests/...`（按实际新增测试归档）

**Steps:**

1. 用 standalone runner 运行项目成本计算和周期同步测试，确保不是 `Executed 0 tests`。
2. 用 `xcodebuild` 构建 iOS Simulator，确认新增 SwiftUI 页面、Core Data 动态模型和工程文件均可编译。
3. 手工验收：添加 ChatGPT 月订阅、进入页面两次验证不重复、暂停后不补账、添加 MacBook 记录使用并验证日均/单次成本、删除项目后检查账本流水仍在。
4. 只检查并报告本次涉及文件；保留当前工作区已有的 Memory/Thought/图标等无关改动，不做广泛 staging 或清理。

## 默认假设

- v1 使用本地 Core Data，不新增后端 API；项目和使用统计随本地数据存储。
- v1 的“使用情况”采用累计次数与累计使用天数，不记录每一次使用的历史明细；后续如需趋势图，再拆分 UsageRecord 实体。
- 周期自动流水采用“打开长期成本页时补齐”的本地机制，不承诺后台定时执行；后续可接入后台任务。
- 不支持退款、转卖、残值和多个项目共享一笔交易；这些作为后续扩展。
