# 健康与目标模块 AI 分析扩展设计

## 背景

HoloAI 当前支持 5 个分析域（finance/habit/task/thought/crossModule），但健康模块完全未接入 AI 系统，目标模块仅有文本级上下文。本次扩展将 health 和 goal 作为新的分析域加入，同时修复习惯分析的 setup() bug。

## 已修复的 Bug

`HabitAnalysisContextBuilder.build()` 访问 `HabitRepository.shared.activeHabits` 时未先调用 `repo.setup()`，导致用户未访问习惯 Tab 时分析返回"没有数据"。

修复：在访问 `activeHabits` 前添加 `if !repo.isReady { repo.setup() }`。

## 方案选择

**方案 A（已选）**：扩展现有 AnalysisDomain 枚举，沿用 XxxAnalysisContextBuilder 模式。完全复用架构，维护成本低。

## 第一部分：Health 分析域

### 数据模型

```swift
// HealthMetricAnalysis — 单个指标的分析结果
struct HealthMetricAnalysis: Codable, Equatable, Sendable {
    let totalValue: Double          // 总量
    let dailyAverage: Double        // 日均
    let goalMetDays: Int            // 达标天数
    let totalDays: Int              // 总天数
    let dailyTrend: [DailyRatePoint] // 复用现有类型（最多31天）
    let bestDay: DailyRatePoint?   // 最佳单日
    let isDataFree: Bool
}

// 复用现有 DailyRatePoint（date: String, rate: Double），不新建类型

// HealthAnalysisContext — 完整健康分析上下文
struct HealthAnalysisContext: Codable, Equatable, Sendable {
    let steps: HealthMetricAnalysis?
    let sleep: HealthMetricAnalysis?
    let stand: HealthMetricAnalysis?
    let activeMinutes: HealthMetricAnalysis?
    let overallBodyScore: Double?
    let previousPeriodScore: Double?
    let anomalyNotes: [String]

    var isDataFree: Bool { ... }
}
```

### HealthRepository 扩展

新增按日期范围查询方法，基于现有 HKStatisticsQuery/HKSampleQuery 模式：

- `fetchSteps(from:to:) -> [DailyHealthData]`
- `fetchSleep(from:to:) -> [DailyHealthData]`
- `fetchStandTime(from:to:) -> [DailyHealthData]`
- `fetchActiveMinutes(from:to:) -> [DailyHealthData]`

每个方法使用 HKPredicate\`withDateRange` 构建日期范围，遍历区间内每一天（或使用 HKStatisticsCollectionQuery 一次性获取），返回 `[DailyHealthData]`。

### HealthAnalysisContextBuilder

新建文件 `Services/AI/HealthAnalysisContextBuilder.swift`。

逻辑：
1. 检查 `HealthRepository.shared.isAuthorized`，未授权直接返回 nil
2. 调用 HealthRepository 的 4 个范围查询方法（并发 async let）
3. 每个指标构建 `HealthMetricAnalysis`（总量/日均/达标天数/趋势/最佳日）
4. 达标判定复用 `HealthMetricType.dailyGoal`（步数 10000、睡眠 8h、站立 12h、活动 30min）
5. 综合体表分沿用现有 3 槽位模型：步数 30%、睡眠 45%、站立或活动 25%（stand 和 activeMinutes 互斥取一，复用 `standOrActivitySnapshot` 逻辑）
6. 异常检测：连续 3 天睡眠 < 6h、连续 3 天步数 < 3000、活动分钟连续为 0
7. 如果所有指标都 isDataFree，返回 nil

### 意图识别关键词

`步数|睡眠|睡觉|运动|站立|健康|走路|锻炼|体能`

---

## 第二部分：Goal 分析域

### 数据模型

```swift
struct GoalProgressItem: Codable, Equatable, Sendable {
    let title: String
    let domain: String           // GoalDomain rawValue
    let status: String           // GoalStatus rawValue
    let deadline: String?        // yyyy-MM-dd
    let daysRemaining: Int?
    let linkedTaskTotal: Int
    let linkedTaskCompleted: Int
    let linkedHabitTotal: Int
    let linkedHabitAverageRate: Double?
    let overallProgress: Double? // 0-1
    let isOverdue: Bool
}

struct GoalAnalysisContext: Codable, Equatable, Sendable {
    let totalActiveGoals: Int
    let goals: [GoalProgressItem]
    let completedGoalsInPeriod: Int
    let atRiskGoals: [String]
    let domainDistribution: [String: Int]
    let previousPeriodCompleted: Int?

    var isDataFree: Bool { ... }
}
```

### GoalAnalysisContextBuilder

新建文件 `Services/AI/GoalAnalysisContextBuilder.swift`。

逻辑：
1. 从 `GoalRepository.shared.activeGoalsForAI()` 拉取活跃目标
2. 遍历每个目标的 `sortedTasks` 和 `sortedHabits`
3. 任务完成率 = completedCount / totalCount
4. 习惯完成率：对每个关联习惯调用 `HabitRepository.evaluatePerformance(for:in:)`，取均值（需先 `repo.setup()`）
5. 综合进度：任务权重 60% + 习惯权重 40%（无关联项则纯靠有数据的一方）
6. 风险检测：deadline < 7 天且进度 < 50%、关联习惯完成率 < 30%
7. 如果没有活跃目标，返回 nil

### 意图识别关键词

`目标|进展|进度|goal|里程碑`

---

## 第三部分：系统集成点

### 修改文件清单

| 步骤 | 文件 | 改动 |
|------|------|------|
| 1 | `Models/AI/AnalysisDomain.swift` | 新增 `.health`、`.goal` case + 关键词映射 |
| 2 | `Models/AI/AnalysisDomainContexts.swift` | 新增 `HealthAnalysisContext`、`GoalAnalysisContext` 及子类型 |
| 3 | `Models/AI/AnalysisContext.swift` | 新增 `health`/`goal` 可选字段，更新 `isEmpty` |
| 4 | `Models/HealthRepository.swift` | 新增 4 个按日期范围查询方法 |
| 5 | `Services/AI/HealthAnalysisContextBuilder.swift` | 新建 |
| 6 | `Services/AI/GoalAnalysisContextBuilder.swift` | 新建 |
| 7 | `Services/AI/AnalysisContextBuilder.swift` | dispatch 新增 health/goal 分支 |
| 8 | `Services/AI/PromptManager.swift` | `analysis_prompt` 新增健康/目标分析指引 |
| 9 | `Services/AI/CrossModuleAnalysisContextBuilder.swift` | 聚合加入 health/goal highlights/warnings |
| 10 | `Views/Chat/Analysis/AnalysisSummaryFormatter.swift` | 新增 health/goal 摘要格式化 |
| 11 | `Models/AI/ChatCardData.swift` | 新增健康/目标分析卡片工厂方法 |
| 12 | `Views/Chat/Analysis/AnalysisDetailBlockParser.swift` | 支持新卡片标记 |

### 后端双端同步

- `PromptManager.swift` 的 `intent_recognition` 模板：加健康/目标关键词到 `query_analysis` 触发词
- 后端 `defaultPrompts.json` 同步更新
- `analysis_prompt` 模板加健康/目标的 LLM 分析指引
- 部署后端：重建 Docker 镜像

### 不改的部分

- `ConversationCoordinator` — 新 case 自动走 `queryAnalysis` 通道
- `UserContext` — 本次不改，后续迭代
- `MemoryInsightContextBuilder` — 记忆洞察更复杂，后续迭代
- `AnalysisPeriodResolver` — 新 case 自动兼容

### crossModule 更新

用户说"复盘"或"综合分析"时，`CrossModuleAnalysisContextBuilder` 同时拉取 6 个域：
- 健康 highlights："睡眠达标率显著提升"、"本周步数持续偏低"
- 目标 warnings："2 个目标即将到期但进度不足 50%"

---

## 第四部分：审查发现与实施注意事项

### 问题 1（已修复）：DailyValuePoint 冗余
直接复用现有 `DailyRatePoint`，不新建类型。

### 问题 2（已修复）：体表分 3 槽位 vs 4 指标
分析数据保留 4 个指标的完整趋势，但体表分计算沿用现有 3 槽位互斥逻辑（stand 和 activeMinutes 取一）。

### 问题 3（实施注意）：HealthKit 未授权处理
`HealthAnalysisContextBuilder` 开头检查 `HealthRepository.shared.isAuthorized`，未授权直接返回 nil，避免无意义的 HealthKit 查询。

### 问题 4（已修复）：关键词 "计划" 过于宽泛
目标域关键词改为 `目标|进展|进度|goal|里程碑`，去掉 "计划" 和 "规划"。

### 问题 5（实施注意）：crossModule 预算调整
`CrossModuleAnalysisContextBuilder` 当前 highlights 限 5 条、warnings 限 3 条。加入 health/goal 后 6 个域竞争 8 个名额，实施时提升到 highlights 7、warnings 5。

### 问题 6（实施注意）：目标关联习惯的完成率时间段
习惯可能晚于分析期开始创建。习惯完成率计算区间改为 `max(分析开始日期, 习惯创建日期) → 分析结束日期`，避免创建前空窗期拉低完成率。
