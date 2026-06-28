# 健康洞察增强：多域生活闭环 + HKWorkout 运动会话

> 日期：2026-06-28
> 范围：iOS（Swift）+ HoloBackend（Prompt 双端同步 + 部署）
> 关联方案：`2026-06-27-Holo健康洞察LLM生成方案.md`（v1，已上线）

---

## 一、背景与问题

v1 已上线：健康页「今日核心洞察」「生活闭环」改为 LLM 生成，经后端网关 `health_insight_generation`。但真机验证暴露两个问题：

1. **生活闭环几乎总是硬编码三条兜底**。
   - 触发 LLM 生成的跨域候选目前只有「低睡眠 ∩ 咖啡」一种，门槛苛刻（近 14 天 ≥3 个 <6h 低睡眠日 + 咖啡账 + lift≥1.5）。
   - 不命中时 `lifestyleLoops` 为空，UI 回退到 `HealthDashboardSnapshot.lifestyleInsights`——**写死的固定三条**（"运动习惯拉动步数""低睡眠日咖啡偏高""压力记录集中久坐日"），不看真实数据，是"假洞察"。
2. **运动维度只有 `appleExerciseTime` 分钟数**，未读 `HKWorkout`（具体锻炼会话：跑步/骑行/力量…），无法区分运动类型。

### 关键发现（降低风险）

后端 Prompt（`defaultPrompts.json`，version 1）的输出 schema **早已支持** `domain` 为 `task/habit/finance/thought/mixed` 的生活闭环，示例甚至引用了 `task-completion-20260624`。瓶颈不在 Prompt，而在 **ContextBuilder 只产出 `health-sleep`、`finance-keyword-coffee` 两类证据**——LLM 被允许生成多域循环却"无料可用"。因此需求1 主要是「扩充跨域证据供给」，Prompt 仅微调示例 + 升版本，不动 schema。

---

## 二、需求

| # | 需求 | 目标 |
|---|------|------|
| 1 | 生活闭环用 LLM 生成（多域） | LLM 能基于 health×{habit,task,thought,finance} 多类证据生成 0-3 条动态生活闭环；无证据时诚实空态，不再硬编码三条 |
| 2 | 接入 HKWorkout | 读取 iOS 健康 App 的锻炼会话（类型/时长/次数），作为 health 域证据，并在健康页轻量展示今日运动 |

---

## 三、Part A — HKWorkout 接入（独立、低风险，建议先做）

### A1. 数据类型
`Models/HealthMetricType.swift` 新增值类型：
```swift
struct DailyWorkoutData: Equatable, Sendable {
    let date: Date
    let totalMinutes: Double      // 当日所有 workout duration 之和
    let sessionCount: Int         // 当日 workout 条数
    let topType: String?          // 当日时长最长的运动类型中文名（如"跑步"），无则 nil
}
```

### A2. HealthRepository 读取
`Models/HealthRepository.swift`：
- 新增 `fetchWorkouts(for date: Date) async -> DailyWorkoutData`：`HKSampleQuery(sampleType: HKObjectType.workoutType(), …)` 枚举当日 `HKWorkout`，按 `duration` 求和、`workoutActivityType` 映射中文名取 topType。模式对齐 `fetchStandTime`（HKSampleQuery + withCheckedContinuation）。
- 新增 `fetchWorkoutsRange(from:to:) async -> [DailyWorkoutData]`（逐日循环，对齐 `fetchRange`）。
- `readTypes` 数组追加 `HKObjectType.workoutType()`。
- `#if targetEnvironment(simulator)` 的 mock 分支补 `generateMockWorkout*`，保证模拟器可联调。

### A3. 权限确认（实施首步）
- `Info.plist` 的 `NSHealthShareUsageDescription` 是否覆盖 workout 读取（App 已能读 stepCount/sleep，通用声明通常已覆盖；需实际核对，若 HealthKit Clinical 另算）。
- HKWorkout 读取走 `requestAuthorization(toShare: nil, read: Set(readTypes))`，readTypes 加 workoutType 后首次需重新请求一次读权限（系统对每个 type 独立授权弹窗，已授权的不会重复弹）。

### A4. 证据化
- `HealthInsightDataSource` 协议追加 `dailyWorkouts(from:to:) async -> [DailyWorkoutData]`。
- `HoloHealthInsightDataSource` 实现 → `HealthRepository.shared.fetchWorkoutsRange`（值类型，非 NSManagedObject，**无跨线程风险**，可与其他 async let 并发）。
- ContextBuilder 产出 evidence：`health-workout-<yyyyMMdd>`（"X 日运动 N 分钟 / 类型 Y"），并定义「运动充足日」（≥30 分钟）集合，供正向跨域候选使用。

---

## 四、Part B — 多域生活闭环 LLM 生成（核心）

### B1. 跨域证据供给（关键）

扩展 `HealthInsightDataSource` 协议三个方法，每个返回 **Sendable 值类型**（仿 `HealthInsightFinanceRecord`）：

| 维度 | 协议方法 | 返回值类型 | 数据来源（复用现成值类型接口） |
|------|---------|-----------|------------------------------|
| 习惯 | `habitDailyCompletion(from:to:)` | `HealthInsightHabitRecord { date, completionRate: Double }` | `HabitRepository.getDailyAggregatedData(range:)` 或 `calculateCheckInCompletionRate`（@MainActor，值类型） |
| 待办 | `taskDailyCompletion(from:to:)` | `HealthInsightTaskRecord { date, completedCount: Int }` | `TodoRepository.getCompletionTrend(from:to:)`（已值类型 `[DailyTaskCount]`） |
| 观点 | `thoughtDailyCount(from:to:)` | `HealthInsightThoughtRecord { date, count: Int }` | `ThoughtRepository.getThoughtCountByDay(from:to:)`（已值类型 `[yyyy-MM-dd:Int]`） |

> 观点「按日情绪」暂缺（`getMoodDistribution` 是区间聚合）。本期降级用「每日观点条数」做信号；按日情绪留作后续增强。

### B2. 生产实现（@MainActor 脱敏）

`HoloHealthInsightDataSource` 三个新方法照搬 `financeRecords` 修复后的范式：内部 `await Self.extract…Records`（`@MainActor`），在闭包内完成 Repository 调用 + NSManagedObject→值类型转换（习惯/待办/观点这几个复用的方法本就返回值类型，几乎无需脱敏，但统一包 @MainActor 以规避 Repository 的 @MainActor 隔离）。

### B3. 多域候选与按日对齐（复用现有骨架）

ContextBuilder.build() 扩展：
- **多域 evidence**：`health-sleep-*`、`health-workout-*`、`habit-completion-*`、`task-completion-*`、`thought-count-*`、`finance-keyword-coffee-*`。id 统一 `<domain>-<subKind>-<yyyyMMdd>`。
- **集合定义**：`lowSleepDays`（已有）、`workoutSufficientDays`（≥30min）、`lowTaskDays`（完成数低于阈值）、`lowHabitDays`、`highThoughtDays`、`coffeeDays`（已有）。
- **候选扩展**（复用 `buildCandidate` 的 dayKey 集合交叉 + lift 模板）：
  - 负向：低睡眠日 ∩ {低待办、低习惯完成、高观点、咖啡}
  - 正向：运动充足日 ∩ {高待办、高习惯完成}
- 门槛放宽：`minLowSleepDays` 等下调（如 2），`minLiftRatio` 保持 1.5，新增「样本不足→confidenceHint 上限 0.6」约束。

### B4. Prompt 微调（双端，升 v2）

`PromptManager.swift`（iOS 后备）+ `HoloBackend/src/prompts/defaultPrompts.json`（生效端）+ `promptRegistry.js` 版本 `health_insight_generation: 2`：
- schema 不变；强化"可生成多类生活闭环（健康/待办/习惯/观点/财务两两跨域），每条≥2 跨域证据"。
- 更新示例：增加一条 `task` 或 `habit` 域循环示例，替换纯咖啡示例。
- 部署：`docker compose build --no-cache && up -d`（源码 baked 进镜像，必须重建）。

### B5. Verifier（微调，不变更架构）

`HealthInsightVerifier`：循环保持 `evidenceIds ≥2` + `跨域证据≥2` + 置信度≥0.55 + 字数/禁词校验。新域 evidence id 自动纳入 legalEvidenceIds，无需改 Verifier 主体。

---

## 五、Part C — 兜底诚实化（去假洞察）

- `HealthDashboardState.lifestyleInsights`：硬编码三条改为**诚实空态单条**——"暂无跨域关联，连续记录睡眠、运动、记账、待办后，HOLO 会发现规律"（或直接返回空数组，UI 显示占位）。
- `HealthInsightFallbackBuilder`：同步空态文案，不伪装跨模块。
- `HealthView.lifestyleRows`：兜底分支展示空态卡片，不再展示固定三条。

---

## 六、分阶段实施

| 阶段 | 内容 | 风险 | 可独立交付 |
|------|------|------|-----------|
| **P1** | Part A（HKWorkout 读取 + 证据化 + mock） | 低 | ✅ 先交付 |
| **P2** | Part B（多域证据 + 候选 + Verifier + 单测） | 中 | 依赖 P1 的 workout evidence 可并入 |
| **P3** | Part B4（Prompt v2 双端同步 + 部署） | 中（双端+部署） | 依赖 P2 |
| **P4** | Part C（兜底诚实化） + 全量回归 | 低 | 收尾 |

---

## 七、涉及文件清单

**iOS 新建/修改**：
- `Models/HealthMetricType.swift`（+DailyWorkoutData）
- `Models/HealthRepository.swift`（+HKWorkout 读取、+readTypes、+mock）
- `Services/AI/HealthInsightContextBuilder.swift`（协议扩展、新值类型、多域 evidence、候选扩展）— 核心
- `Services/AI/HealthInsightVerifier.swift`（微调）
- `Services/AI/HealthInsightFallbackBuilder.swift`（空态）
- `Models/HealthDashboardState.swift`（lifestyleInsights 空态）
- `Views/Health/HealthView.swift`（运动展示 + 空态）
- `Services/AI/PromptManager.swift`（模板 v2 + 版本号）
- `Info.plist`（核对 workout 权限声明）

**测试**：
- `HealthInsightContextBuilderTests`（多域 evidence + 候选 + 跨域对齐）
- `HealthInsightVerifierTests`（多域循环校验）
- `HealthRepository` HKWorkout 单测（注入或 mock）

**后端**：
- `HoloBackend/src/prompts/defaultPrompts.json`（health_insight_generation v2）
- `HoloBackend/src/prompts/promptRegistry.js`（版本号 2）
- 部署（Docker build --no-cache）

---

## 八、对抗性审查待办（实施前）

1. **HKWorkout 权限**：workoutType 读取是否触发额外授权弹窗、Info.plist 是否需补声明。
2. **并发性能**：build() 将有 6+ async let，多个走 @MainActor（habit/task/thought 仓库），是否串行化拖慢生成（健康页 .task）。
3. **候选门槛平衡**：太严→仍无料（等于没做）；太松→Verifier 把不住、LLM 出弱关联。需定 minLowSleepDays/lift 阈值并实测。
4. **LLM 编造风险**：Verifier 的 evidenceIds 同源校验 + 跨域≥2 是否足以挡住"貌似有理实则无证据"的循环。
5. **观点情绪降级**：用条数代替情绪是否产生误导（条数多≠情绪差），Prompt 措辞需规避。
6. **双端 Prompt 一致性**：iOS 后备模板与后端 defaultPrompts.json 必须逐字对齐，版本号三处同步。
7. **空态用户体验**：硬编码三条改空态后，长期无跨域数据的用户看到"暂无关联"是否比假洞察更好（产品判断）。

---

## 九、对抗审查结论与补充决策

审查后收敛 4 个方案未定的关键点（产品语言：结论→决策→技术支撑）：

1. **「生活闭环还是太少/太乱」**
   - 结论：多域候选会让候选数膨胀到 6 个，全塞给 AI 反而质量下降、输入超长。
   - 决策：**候选最多取 3-4 个**，按 confidenceHint 降序取 top。
   - 支撑：候选 × 证据会让 contextJSON 膨胀，AI 在过长输入下易跑偏；top-N 既保证多样性又不超载。

2. **「生成慢、成本高」**
   - 结论：14 天 × 6 域最多 ~84 条 evidence，全量发给 LLM 输入太长。
   - 决策：**evidence 裁剪**——只放「候选命中的日子」+「近 7 天代表性摘要」，控制输入 token。
   - 支撑：输入越长生成越慢越贵，且大部分证据与候选无关。

3. **「习惯完成率怎么算」的歧义**
   - 结论：用户有多个习惯，单值 completionRate 需明确聚合口径。
   - 决策：**每日「达标习惯数 / 活跃习惯数」**作为完成率（而非各习惯平均）。
   - 支撑：可解释性强（"这天 3/4 习惯达标"），且能按日与睡眠对齐。

4. **「9 个并发查询拖慢健康页」**
   - 结论：build() 将有 9 个 async let，其中 habit/task/thought 走 @MainActor 会串行化。
   - 决策：**可接受**——页面先显缓存/兜底，后台异步生成，几秒延迟不影响可用性。
   - 支撑：健康页 `.task` 已是缓存优先 + fallback 先渲染（v1 架构）。

> 待东林拍板的产品决策：① 分阶段（P1 Workout 先做 vs 一起做）；② 硬编码三条改「暂无关联」空态确认；③ 观点用「条数」暂代「情绪」是否接受。
