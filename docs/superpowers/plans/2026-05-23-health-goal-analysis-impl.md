# Health & Goal 分析域扩展 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复习惯分析 setup() bug，将 Health 和 Goal 扩展为 AI 分析的新域

**Architecture:** 扩展现有 `AnalysisDomain` 枚举 + `XxxAnalysisContextBuilder` 模式。Health 通过 HealthKit 范围查询获取 4 个指标数据；Goal 通过 GoalRepository 获取活跃目标并计算关联任务/习惯完成率。完全复用现有分析管线。

**Tech Stack:** Swift, SwiftUI, HealthKit, Core Data, async/await

**设计文档:** `docs/superpowers/specs/2026-05-23-health-goal-analysis-design.md`

---

## 基础路径

所有 Swift 文件基于 `Holo/Holo APP/Holo/Holo/` 目录：

```
BASE = Holo/Holo APP/Holo/Holo/
```

---

## Task 1: 修复 HabitAnalysisContextBuilder setup() bug

**Files:**
- Modify: `BASE/Services/AI/HabitAnalysisContextBuilder.swift`

> Bug 已在之前的审查中修复，代码已编辑到位，但未提交。

- [ ] **Step 1: 验证修复内容**

确认 `HabitAnalysisContextBuilder.swift` 第 25-26 行为：
```swift
let repo = HabitRepository.shared
if !repo.isReady { repo.setup() }
```
确认第 35 行为（无多余 filter）：
```swift
let activeHabits = repo.activeHabits
```

- [ ] **Step 2: 提交**

```bash
git -C /Users/tangyuxuan/Desktop/Claude/Holo add "Holo/Holo APP/Holo/Holo/Services/AI/HabitAnalysisContextBuilder.swift"
git -C /Users/tangyuxuan/Desktop/Claude/Holo commit -m "fix(iOS): 习惯分析 setup() 未调用导致返回空数据"
```

---

## Task 2: 扩展 AnalysisDomain + 数据模型

**Files:**
- Modify: `BASE/Models/AI/AnalysisDomain.swift`
- Modify: `BASE/Models/AI/AnalysisDomainContexts.swift`
- Modify: `BASE/Models/AI/AnalysisContext.swift`

### Step 1: AnalysisDomain 新增 .health / .goal

在 `AnalysisDomain.swift` 的枚举中新增两个 case（在 `crossModule` 之前）：

```swift
enum AnalysisDomain: String, Codable, Equatable, Sendable {
    case finance
    case habit
    case task
    case thought
    case health
    case goal
    case crossModule

    static func infer(from text: String) -> AnalysisDomain? {
        let lower = text.lowercased()
        let financeKeywords = ["消费", "支出", "收入", "预算", "账单", "财务", "花了多少", "花钱"]
        let habitKeywords = ["习惯", "打卡", "连续", "完成率", "坚持"]
        let taskKeywords = ["任务", "待办", "完成", "逾期", "优先级"]
        let thoughtKeywords = ["想法", "记录", "情绪", "标签", "观点", "心情"]
        let healthKeywords = ["步数", "睡眠", "睡觉", "运动", "站立", "健康", "走路", "锻炼", "体能"]
        let goalKeywords = ["目标", "进展", "进度", "goal", "里程碑"]
        let crossKeywords = ["复盘", "综合分析", "状态", "最近过得", "总结", "整体"]

        for keyword in crossKeywords where lower.contains(keyword) { return .crossModule }
        for keyword in financeKeywords where lower.contains(keyword) { return .finance }
        for keyword in habitKeywords where lower.contains(keyword) { return .habit }
        for keyword in taskKeywords where lower.contains(keyword) { return .task }
        for keyword in thoughtKeywords where lower.contains(keyword) { return .thought }
        for keyword in healthKeywords where lower.contains(keyword) { return .health }
        for keyword in goalKeywords where lower.contains(keyword) { return .goal }
        return nil
    }
}
```

### Step 2: AnalysisDomainContexts 新增类型

在文件末尾（`CrossModuleAnalysisContext` 之后）追加：

```swift
// MARK: - Health

struct HealthMetricAnalysis: Codable, Equatable, Sendable {
    let totalValue: Double
    let dailyAverage: Double
    let goalMetDays: Int
    let totalDays: Int
    let dailyTrend: [DailyRatePoint]
    let bestDay: DailyRatePoint?

    var isDataFree: Bool {
        totalDays == 0 || (totalValue == 0 && goalMetDays == 0)
    }
}

struct HealthAnalysisContext: Codable, Equatable, Sendable {
    let steps: HealthMetricAnalysis?
    let sleep: HealthMetricAnalysis?
    let stand: HealthMetricAnalysis?
    let activeMinutes: HealthMetricAnalysis?
    let overallBodyScore: Double?
    let previousPeriodScore: Double?
    let anomalyNotes: [String]

    var isDataFree: Bool {
        let metrics = [steps, sleep, stand, activeMinutes].compactMap { $0 }
        return metrics.isEmpty || metrics.allSatisfy(\.isDataFree)
    }
}

// MARK: - Goal

struct GoalProgressItem: Codable, Equatable, Sendable {
    let title: String
    let domain: String
    let status: String
    let deadline: String?
    let daysRemaining: Int?
    let linkedTaskTotal: Int
    let linkedTaskCompleted: Int
    let linkedHabitTotal: Int
    let linkedHabitAverageRate: Double?
    let overallProgress: Double?
    let isOverdue: Bool
}

struct GoalAnalysisContext: Codable, Equatable, Sendable {
    let totalActiveGoals: Int
    let goals: [GoalProgressItem]
    let completedGoalsInPeriod: Int
    let atRiskGoals: [String]
    let domainDistribution: [String: Int]
    let previousPeriodCompleted: Int?

    var isDataFree: Bool {
        totalActiveGoals == 0 && completedGoalsInPeriod == 0
    }
}
```

### Step 3: AnalysisContext 新增字段

在 `AnalysisContext` 中新增两个可选字段和 `isEmpty` 检查：

```swift
struct AnalysisContext: Codable, Equatable, Sendable {
    let domain: AnalysisDomain
    let periodLabel: String
    let startDate: String
    let endDate: String
    let comparisonLabel: String?
    let finance: FinanceAnalysisContext?
    let habit: HabitAnalysisContext?
    let task: TaskAnalysisContext?
    let thought: ThoughtAnalysisContext?
    let health: HealthAnalysisContext?
    let goal: GoalAnalysisContext?
    let crossModule: CrossModuleAnalysisContext?

    var isEmpty: Bool {
        let hasFinance = finance != nil && !finance!.isDataFree
        let hasHabit = habit != nil && !habit!.isDataFree
        let hasTask = task != nil && !task!.isDataFree
        let hasThought = thought != nil && !thought!.isDataFree
        let hasHealth = health != nil && !health!.isDataFree
        let hasGoal = goal != nil && !goal!.isDataFree
        let hasCrossModule = crossModule != nil && !crossModule!.isDataFree
        return !hasFinance && !hasHabit && !hasTask && !hasThought && !hasHealth && !hasGoal && !hasCrossModule
    }
}
```

### Step 4: 编译验证

```bash
# 在 Xcode 中 Build（⌘B），确认无编译错误
# 重点关注 AnalysisContextBuilder.swift 的 switch 不完整错误（预期报错，Task 6 修复）
```

> 注意：此时 `AnalysisContextBuilder.swift` 的 switch 会报错缺少 `.health` / `.goal` case，这是预期的，Task 6 修复。

### Step 5: 提交

```bash
git -C /Users/tangyuxuan/Desktop/Claude/Holo add "Holo/Holo APP/Holo/Holo/Models/AI/AnalysisDomain.swift" "Holo/Holo APP/Holo/Holo/Models/AI/AnalysisDomainContexts.swift" "Holo/Holo APP/Holo/Holo/Models/AI/AnalysisContext.swift"
git -C /Users/tangyuxuan/Desktop/Claude/Holo commit -m "feat(iOS): 新增 health/goal 分析域数据模型"
```

---

## Task 3: HealthRepository 新增日期范围查询

**Files:**
- Modify: `BASE/Models/HealthRepository.swift`

### Step 1: 新增 4 个公开范围查询方法

在 `fetchWeeklyData(for:)` 方法之后、`// MARK: - 私有方法 - 真实数据获取` 之前插入：

```swift
// MARK: - 日期范围查询（AI 分析用）

/// 获取指定日期范围的步数数据
func fetchStepsRange(from start: Date, to end: Date) async -> [DailyHealthData] {
    await fetchRange(for: .steps, from: start, to: end)
}

/// 获取指定日期范围的睡眠数据
func fetchSleepRange(from start: Date, to end: Date) async -> [DailyHealthData] {
    await fetchRange(for: .sleep, from: start, to: end)
}

/// 获取指定日期范围的站立数据
func fetchStandTimeRange(from start: Date, to end: Date) async -> [DailyHealthData] {
    await fetchRange(for: .standHours, from: start, to: end)
}

/// 获取指定日期范围的活动分钟数据
func fetchActiveMinutesRange(from start: Date, to end: Date) async -> [DailyHealthData] {
    await fetchRange(for: .activeMinutes, from: start, to: end)
}

/// 通用范围查询
private func fetchRange(for type: HealthMetricType, from start: Date, to end: Date) async -> [DailyHealthData] {
    if useMockData {
        return generateMockRangeData(for: type, from: start, to: end)
    }

    let calendar = Calendar.current
    var results: [DailyHealthData] = []
    var current = calendar.startOfDay(for: start)
    let endDay = calendar.startOfDay(for: end)

    while current <= endDay {
        let value: Double
        switch type {
        case .steps: value = await fetchSteps(for: current)
        case .sleep: value = await fetchSleep(for: current)
        case .standHours: value = await fetchStandTime(for: current)
        case .activeMinutes: value = await fetchActiveMinutes(for: current)
        }
        results.append(DailyHealthData(date: current, value: value))
        guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
        current = next
    }
    return results
}
```

### Step 2: 新增 mock 范围数据生成器

在 `generateMockWeeklyData(for:)` 方法之后插入：

```swift
/// 生成模拟日期范围数据
private func generateMockRangeData(for type: HealthMetricType, from start: Date, to end: Date) -> [DailyHealthData] {
    let calendar = Calendar.current
    var results: [DailyHealthData] = []
    var current = calendar.startOfDay(for: start)
    let endDay = calendar.startOfDay(for: end)

    while current <= endDay {
        let value: Double
        switch type {
        case .steps: value = Double(Int.random(in: 5000...15000))
        case .sleep: value = Double(Int.random(in: 5...10)) + Double.random(in: 0...0.9)
        case .standHours: value = Double(Int.random(in: 6...14))
        case .activeMinutes: value = Double(Int.random(in: 12...60))
        }
        results.append(DailyHealthData(date: current, value: value))
        guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
        current = next
    }
    return results
}
```

### Step 3: 编译验证

Xcode Build 确认无错误。

### Step 4: 提交

```bash
git -C /Users/tangyuxuan/Desktop/Claude/Holo add "Holo/Holo APP/Holo/Holo/Models/HealthRepository.swift"
git -C /Users/tangyuxuan/Desktop/Claude/Holo commit -m "feat(iOS): HealthRepository 新增日期范围查询方法"
```

---

## Task 4: 创建 HealthAnalysisContextBuilder

**Files:**
- Create: `BASE/Services/AI/HealthAnalysisContextBuilder.swift`

### Step 1: 创建文件

```swift
//
//  HealthAnalysisContextBuilder.swift
//  Holo
//
//  健康分析上下文构建器
//  通过 HealthKit 范围查询获取步数/睡眠/站立/活动数据
//

import Foundation
import os.log

struct HealthAnalysisContextBuilder {

    private let logger = Logger(subsystem: "com.holo.app", category: "HealthAnalysisCtx")

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @MainActor
    func build(request: ResolvedAnalysisRequest) async -> HealthAnalysisContext? {
        let repo = HealthRepository.shared
        guard repo.isAuthorized else { return nil }

        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: request.start)
        let endDate = calendar.startOfDay(for: request.end)

        // 并发获取 4 个指标
        async let stepsData = repo.fetchStepsRange(from: startDate, to: endDate)
        async let sleepData = repo.fetchSleepRange(from: startDate, to: endDate)
        async let standData = repo.fetchStandTimeRange(from: startDate, to: endDate)
        async let activeData = repo.fetchActiveMinutesRange(from: startDate, to: endDate)

        let (steps, sleep, stand, active) = await (stepsData, sleepData, standData, activeData)

        let stepsAnalysis = buildMetricAnalysis(data: steps, goal: HealthMetricType.steps.dailyGoal)
        let sleepAnalysis = buildMetricAnalysis(data: sleep, goal: HealthMetricType.sleep.dailyGoal)
        let standAnalysis = buildMetricAnalysis(data: stand, goal: HealthMetricType.standHours.dailyGoal)
        let activeAnalysis = buildMetricAnalysis(data: active, goal: HealthMetricType.activeMinutes.dailyGoal)

        // 所有指标都没数据
        let allMetrics = [stepsAnalysis, sleepAnalysis, standAnalysis, activeAnalysis].compactMap { $0 }
        if allMetrics.isEmpty || allMetrics.allSatisfy(\.isDataFree) {
            return nil
        }

        // 体表分（3 槽位：步数 30%、睡眠 45%、站立或活动 25%）
        let bodyScore = calculateBodyScore(
            steps: stepsAnalysis,
            sleep: sleepAnalysis,
            stand: standAnalysis,
            active: activeAnalysis
        )

        // 上期体表分
        var previousScore: Double?
        if let compStart = request.comparisonStart, let compEnd = request.comparisonEnd {
            previousScore = await calculatePeriodScore(from: compStart, to: compEnd)
        }

        // 异常检测
        let anomalies = detectAnomalies(steps: steps, sleep: sleep, active: active)

        return HealthAnalysisContext(
            steps: stepsAnalysis,
            sleep: sleepAnalysis,
            stand: standAnalysis,
            activeMinutes: activeAnalysis,
            overallBodyScore: bodyScore,
            previousPeriodScore: previousScore,
            anomalyNotes: anomalies
        )
    }

    // MARK: - 指标分析构建

    private func buildMetricAnalysis(data: [DailyHealthData], goal: Double) -> HealthMetricAnalysis? {
        guard !data.isEmpty else { return nil }

        let totalValue = data.reduce(0) { $0 + $1.value }
        let totalDays = data.count
        let dailyAverage = totalDays > 0 ? totalValue / Double(totalDays) : 0
        let goalMetDays = data.filter { $0.value >= goal }.count

        let trend = data.suffix(31).map { point in
            DailyRatePoint(date: Self.dateFmt.string(from: point.date), rate: point.value)
        }

        let bestDay = data.max(by: { $0.value < $1.value }).map { point in
            DailyRatePoint(date: Self.dateFmt.string(from: point.date), rate: point.value)
        }

        let isDataFree = totalDays == 0 || (totalValue == 0 && goalMetDays == 0)

        // 全零数据不返回（HealthKit 未授权该指标）
        if totalValue == 0 && goalMetDays == 0 {
            return nil
        }

        return HealthMetricAnalysis(
            totalValue: totalValue,
            dailyAverage: dailyAverage,
            goalMetDays: goalMetDays,
            totalDays: totalDays,
            dailyTrend: trend,
            bestDay: bestDay
        )
    }

    // MARK: - 体表分（3 槽位模型）

    private func calculateBodyScore(
        steps: HealthMetricAnalysis?,
        sleep: HealthMetricAnalysis?,
        stand: HealthMetricAnalysis?,
        active: HealthMetricAnalysis?
    ) -> Double? {
        // stand 和 active 互斥取一
        let standOrActivity: (analysis: HealthMetricAnalysis?, goal: Double) = {
            if let stand = stand, !stand.isDataFree {
                return (stand, HealthMetricType.standHours.dailyGoal)
            }
            if let active = active, !active.isDataFree {
                return (active, HealthMetricType.activeMinutes.dailyGoal)
            }
            return (nil, 0)
        }()

        var weightedInputs: [(analysis: HealthMetricAnalysis, goal: Double, weight: Double)] = []
        if let s = steps, !s.isDataFree {
            weightedInputs.append((s, HealthMetricType.steps.dailyGoal, 0.30))
        }
        if let sl = sleep, !sl.isDataFree {
            weightedInputs.append((sl, HealthMetricType.sleep.dailyGoal, 0.45))
        }
        if let sa = standOrActivity.analysis {
            weightedInputs.append((sa, standOrActivity.goal, 0.25))
        }

        guard !weightedInputs.isEmpty else { return nil }

        let weightedScore = weightedInputs.reduce(0.0) { partial, item in
            let progress = min(item.analysis.dailyAverage / item.goal, 1.0)
            return partial + progress * item.weight * 100
        }
        let availableWeight = weightedInputs.reduce(0.0) { $0 + $1.weight }
        guard availableWeight > 0 else { return nil }

        return min(weightedScore / availableWeight, 100)
    }

    /// 计算指定日期范围的体表分
    @MainActor
    private func calculatePeriodScore(from start: Date, to end: Date) async -> Double? {
        let repo = HealthRepository.shared
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: start)
        let endDate = calendar.startOfDay(for: end)

        async let stepsData = repo.fetchStepsRange(from: startDate, to: endDate)
        async let sleepData = repo.fetchSleepRange(from: startDate, to: endDate)
        async let standData = repo.fetchStandTimeRange(from: startDate, to: endDate)
        async let activeData = repo.fetchActiveMinutesRange(from: startDate, to: endDate)

        let (steps, sleep, stand, active) = await (stepsData, sleepData, standData, activeData)

        let stepsAnalysis = buildMetricAnalysis(data: steps, goal: HealthMetricType.steps.dailyGoal)
        let sleepAnalysis = buildMetricAnalysis(data: sleep, goal: HealthMetricType.sleep.dailyGoal)
        let standAnalysis = buildMetricAnalysis(data: stand, goal: HealthMetricType.standHours.dailyGoal)
        let activeAnalysis = buildMetricAnalysis(data: active, goal: HealthMetricType.activeMinutes.dailyGoal)

        return calculateBodyScore(steps: stepsAnalysis, sleep: sleepAnalysis, stand: standAnalysis, active: activeAnalysis)
    }

    // MARK: - 异常检测

    private func detectAnomalies(
        steps: [DailyHealthData],
        sleep: [DailyHealthData],
        active: [DailyHealthData]
    ) -> [String] {
        var anomalies: [String] = []

        // 连续 3 天睡眠 < 6h
        let lowSleep = consecutiveLowDays(data: sleep, threshold: 6.0)
        if lowSleep >= 3 {
            anomalies.append("连续 \(lowSleep) 天睡眠不足 6 小时")
        }

        // 连续 3 天步数 < 3000
        let lowSteps = consecutiveLowDays(data: steps, threshold: 3000)
        if lowSteps >= 3 {
            anomalies.append("连续 \(lowSteps) 天步数不足 3000")
        }

        // 活动分钟持续为 0
        let allZeroActive = active.allSatisfy { $0.value == 0 } && !active.isEmpty
        if allZeroActive {
            anomalies.append("活动分钟数持续为 0")
        }

        return anomalies
    }

    /// 计算连续低于阈值的最长天数
    private func consecutiveLowDays(data: [DailyHealthData], threshold: Double) -> Int {
        var maxStreak = 0
        var currentStreak = 0
        for point in data {
            if point.value < threshold {
                currentStreak += 1
                maxStreak = max(maxStreak, currentStreak)
            } else {
                currentStreak = 0
            }
        }
        return maxStreak
    }
}
```

### Step 2: 编译验证

Xcode Build 确认无错误。

### Step 3: 提交

```bash
git -C /Users/tangyuxuan/Desktop/Claude/Holo add "Holo/Holo APP/Holo/Holo/Services/AI/HealthAnalysisContextBuilder.swift"
git -C /Users/tangyuxuan/Desktop/Claude/Holo commit -m "feat(iOS): 新建 HealthAnalysisContextBuilder"
```

---

## Task 5: 创建 GoalAnalysisContextBuilder

**Files:**
- Modify: `BASE/Models/GoalRepository.swift` — 新增 `completedGoalsCount(from:to:)`
- Create: `BASE/Services/AI/GoalAnalysisContextBuilder.swift`

### Step 1: GoalRepository 新增完成数查询

在 `GoalRepository` 的 `activeGoalsForAI(limit:)` 方法之后插入：

```swift
/// 获取指定时间段内完成的目标数量（AI 分析用）
func completedGoalsCount(from start: Date, to end: Date) -> Int {
    let request = Goal.fetchRequest()
    request.predicate = NSPredicate(
        format: "status == %@ AND completedAt >= %@ AND completedAt <= %@",
        GoalStatus.completed.rawValue,
        start as CVarArg,
        end as CVarArg
    )
    return (try? context.count(for: request)) ?? 0
}
```

### Step 2: 创建 GoalAnalysisContextBuilder

```swift
//
//  GoalAnalysisContextBuilder.swift
//  Holo
//
//  目标分析上下文构建器
//  计算活跃目标的关联任务/习惯完成率和风险检测
//

import Foundation
import os.log

struct GoalAnalysisContextBuilder {

    private let logger = Logger(subsystem: "com.holo.app", category: "GoalAnalysisCtx")

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @MainActor
    func build(request: ResolvedAnalysisRequest) async -> GoalAnalysisContext? {
        let goalRepo = GoalRepository.shared
        let goals = goalRepo.activeGoalsForAI(limit: 20)

        guard !goals.isEmpty else { return nil }

        let calendar = Calendar.current
        let analysisStart = calendar.startOfDay(for: request.start)
        guard let analysisEndExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: request.end)) else {
            return nil
        }
        let analysisRange = analysisStart...analysisEndExclusive

        // 确保习惯仓库已初始化
        let habitRepo = HabitRepository.shared
        if !habitRepo.isReady { habitRepo.setup() }

        var items: [GoalProgressItem] = []
        var atRiskNames: [String] = []

        for goal in goals {
            let item = buildProgressItem(
                goal: goal,
                analysisRange: analysisRange,
                calendar: calendar,
                habitRepo: habitRepo
            )
            items.append(item)

            // 风险检测
            if item.isOverdue || isAtRisk(item) {
                atRiskNames.append(item.title)
            }
        }

        // 本期完成的目标数
        let completedCount = goalRepo.completedGoalsCount(
            from: analysisStart,
            to: analysisEndExclusive
        )

        // 上期完成数
        var previousCompleted: Int?
        if let compStart = request.comparisonStart, let compEnd = request.comparisonEnd {
            let compStartDay = calendar.startOfDay(for: compStart)
            let compEndExcl = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: compEnd))
            if let compEnd = compEndExcl {
                previousCompleted = goalRepo.completedGoalsCount(from: compStartDay, to: compEnd)
            }
        }

        // 领域分布
        let domainDist = Dictionary(grouping: items, by: \.domain)
            .mapValues { $0.count }

        return GoalAnalysisContext(
            totalActiveGoals: goals.count,
            goals: items,
            completedGoalsInPeriod: completedCount,
            atRiskGoals: atRiskNames,
            domainDistribution: domainDist,
            previousPeriodCompleted: previousCompleted
        )
    }

    // MARK: - 单个目标进度

    @MainActor
    private func buildProgressItem(
        goal: Goal,
        analysisRange: ClosedRange<Date>,
        calendar: Calendar,
        habitRepo: HabitRepository
    ) -> GoalProgressItem {
        let tasks = goal.sortedTasks
        let habits = goal.sortedHabits

        // 任务完成率
        let taskTotal = tasks.count
        let taskCompleted = tasks.filter { $0.isCompleted }.count

        // 习惯完成率
        var habitTotal = habits.count
        var habitAvgRate: Double?

        if habitTotal > 0 {
            let rates = habits.compactMap { habit -> Double? in
                // 习惯可能晚于分析期创建，从创建日开始计算
                let habitStart = calendar.startOfDay(for: habit.createdAt)
                let effectiveStart = max(analysisRange.lowerBound, habitStart)
                guard effectiveStart < analysisRange.upperBound else { return nil }
                let effectiveRange = effectiveStart...analysisRange.upperBound
                return habitRepo.evaluatePerformance(for: habit, in: effectiveRange).completionRate
            }
            if !rates.isEmpty {
                habitAvgRate = rates.reduce(0, +) / Double(rates.count)
            }
        }

        // 综合进度：任务 60% + 习惯 40%
        let overallProgress = calculateOverallProgress(
            taskTotal: taskTotal,
            taskCompleted: taskCompleted,
            habitTotal: habitTotal,
            habitAvgRate: habitAvgRate
        )

        // 剩余天数
        let daysRemaining = goal.deadline.map {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: $0)).day ?? 0
        }

        // 是否逾期
        let isOverdue = goal.deadline.map {
            calendar.startOfDay(for: $0) < calendar.startOfDay(for: Date()) && goal.goalStatus != .completed
        } ?? false

        return GoalProgressItem(
            title: goal.title,
            domain: goal.goalDomain.rawValue,
            status: goal.goalStatus.rawValue,
            deadline: goal.deadline.map { Self.dateFmt.string(from: $0) },
            daysRemaining: daysRemaining,
            linkedTaskTotal: taskTotal,
            linkedTaskCompleted: taskCompleted,
            linkedHabitTotal: habitTotal,
            linkedHabitAverageRate: habitAvgRate,
            overallProgress: overallProgress,
            isOverdue: isOverdue
        )
    }

    /// 综合进度计算：任务 60% + 习惯 40%
    private func calculateOverallProgress(
        taskTotal: Int,
        taskCompleted: Int,
        habitTotal: Int,
        habitAvgRate: Double?
    ) -> Double? {
        let hasTasks = taskTotal > 0
        let hasHabits = habitTotal > 0 && habitAvgRate != nil

        if hasTasks && hasHabits {
            let taskRate = Double(taskCompleted) / Double(taskTotal)
            return taskRate * 0.6 + habitAvgRate! * 0.4
        } else if hasTasks {
            return Double(taskCompleted) / Double(taskTotal)
        } else if hasHabits {
            return habitAvgRate
        }
        return nil
    }

    /// 风险判断：deadline < 7 天且进度 < 50%，或习惯完成率 < 30%
    private func isAtRisk(_ item: GoalProgressItem) -> Bool {
        if let days = item.daysRemaining, days >= 0, days < 7 {
            if let progress = item.overallProgress, progress < 0.5 {
                return true
            }
        }
        if let habitRate = item.linkedHabitAverageRate, habitRate < 0.3 {
            return true
        }
        return false
    }
}
```

### Step 3: 编译验证

Xcode Build 确认无错误。

### Step 4: 提交

```bash
git -C /Users/tangyuxuan/Desktop/Claude/Holo add "Holo/Holo APP/Holo/Holo/Models/GoalRepository.swift" "Holo/Holo APP/Holo/Holo/Services/AI/GoalAnalysisContextBuilder.swift"
git -C /Users/tangyuxuan/Desktop/Claude/Holo commit -m "feat(iOS): 新建 GoalAnalysisContextBuilder + GoalRepository 完成数查询"
```

---

## Task 6: 集成分发 + 跨模块聚合

**Files:**
- Modify: `BASE/Services/AI/AnalysisContextBuilder.swift`
- Modify: `BASE/Services/AI/CrossModuleAnalysisContextBuilder.swift`

### Step 1: AnalysisContextBuilder 新增 health/goal 分支

完整替换 `build(request:)` 方法中的 switch：

```swift
@MainActor
func build(request: ResolvedAnalysisRequest) async -> AnalysisContext {
    switch request.domain {
    case .finance:
        let finance = await FinanceAnalysisContextBuilder().build(request: request)
        return AnalysisContext(
            domain: .finance,
            periodLabel: request.periodLabel,
            startDate: request.startDateString,
            endDate: request.endDateString,
            comparisonLabel: request.comparisonLabel,
            finance: finance,
            habit: nil,
            task: nil,
            thought: nil,
            health: nil,
            goal: nil,
            crossModule: nil
        )

    case .habit:
        let habit = await HabitAnalysisContextBuilder().build(request: request)
        return AnalysisContext(
            domain: .habit,
            periodLabel: request.periodLabel,
            startDate: request.startDateString,
            endDate: request.endDateString,
            comparisonLabel: request.comparisonLabel,
            finance: nil,
            habit: habit,
            task: nil,
            thought: nil,
            health: nil,
            goal: nil,
            crossModule: nil
        )

    case .task:
        let task = await TaskAnalysisContextBuilder().build(request: request)
        return AnalysisContext(
            domain: .task,
            periodLabel: request.periodLabel,
            startDate: request.startDateString,
            endDate: request.endDateString,
            comparisonLabel: request.comparisonLabel,
            finance: nil,
            habit: nil,
            task: task,
            thought: nil,
            health: nil,
            goal: nil,
            crossModule: nil
        )

    case .thought:
        let thought = await ThoughtAnalysisContextBuilder().build(request: request)
        return AnalysisContext(
            domain: .thought,
            periodLabel: request.periodLabel,
            startDate: request.startDateString,
            endDate: request.endDateString,
            comparisonLabel: request.comparisonLabel,
            finance: nil,
            habit: nil,
            task: nil,
            thought: thought,
            health: nil,
            goal: nil,
            crossModule: nil
        )

    case .health:
        let health = await HealthAnalysisContextBuilder().build(request: request)
        return AnalysisContext(
            domain: .health,
            periodLabel: request.periodLabel,
            startDate: request.startDateString,
            endDate: request.endDateString,
            comparisonLabel: request.comparisonLabel,
            finance: nil,
            habit: nil,
            task: nil,
            thought: nil,
            health: health,
            goal: nil,
            crossModule: nil
        )

    case .goal:
        let goal = await GoalAnalysisContextBuilder().build(request: request)
        return AnalysisContext(
            domain: .goal,
            periodLabel: request.periodLabel,
            startDate: request.startDateString,
            endDate: request.endDateString,
            comparisonLabel: request.comparisonLabel,
            finance: nil,
            habit: nil,
            task: nil,
            thought: nil,
            health: nil,
            goal: goal,
            crossModule: nil
        )

    case .crossModule:
        async let f = FinanceAnalysisContextBuilder().build(request: request)
        async let h = HabitAnalysisContextBuilder().build(request: request)
        async let t = TaskAnalysisContextBuilder().build(request: request)
        async let th = ThoughtAnalysisContextBuilder().build(request: request)
        async let ht = HealthAnalysisContextBuilder().build(request: request)
        async let g = GoalAnalysisContextBuilder().build(request: request)

        let (finance, habit, task, thought, health, goal) = await (f, h, t, th, ht, g)

        let crossModule = CrossModuleAnalysisContextBuilder().build(
            finance: finance,
            habit: habit,
            task: task,
            thought: thought,
            health: health,
            goal: goal
        )

        return AnalysisContext(
            domain: .crossModule,
            periodLabel: request.periodLabel,
            startDate: request.startDateString,
            endDate: request.endDateString,
            comparisonLabel: request.comparisonLabel,
            finance: finance,
            habit: habit,
            task: task,
            thought: thought,
            health: health,
            goal: goal,
            crossModule: crossModule
        )
    }
}
```

### Step 2: CrossModuleAnalysisContextBuilder 新增 health/goal 聚合

更新 `build` 方法签名和逻辑：

```swift
struct CrossModuleAnalysisContextBuilder {

    /// 从各模块 context 中提取亮点和风险
    func build(
        finance: FinanceAnalysisContext?,
        habit: HabitAnalysisContext?,
        task: TaskAnalysisContext?,
        thought: ThoughtAnalysisContext?,
        health: HealthAnalysisContext?,
        goal: GoalAnalysisContext?
    ) -> CrossModuleAnalysisContext {
        var highlights: [String] = []
        var warnings: [String] = []

        // 财务亮点/风险
        if let f = finance, !f.isDataFree {
            if let prev = f.previousPeriodExpense, prev > 0 {
                if f.totalExpense < prev {
                    let saved = prev - f.totalExpense
                    highlights.append("支出较上周期减少 \(NumberFormatter.compactCurrency(saved))")
                } else if f.totalExpense > prev {
                    let extra = f.totalExpense - prev
                    warnings.append("支出较上周期增加 \(NumberFormatter.compactCurrency(extra))")
                }
            } else {
                if f.totalIncome > f.totalExpense {
                    highlights.append("收入大于支出，财务状况健康")
                }
            }

            if let budget = f.budgetPerformance, budget.utilizationRate > 100 {
                warnings.append("预算已超支 \(String(format: "%.0f", budget.utilizationRate))%")
            }
        }

        // 习惯亮点/风险
        if let h = habit, !h.isDataFree {
            if let rate = h.averageCompletionRate, rate >= 0.8 {
                highlights.append(String(format: "习惯完成率 %.0f%%，表现优秀", rate * 100))
            } else if let rate = h.averageCompletionRate, rate < 0.5 {
                warnings.append(String(format: "习惯完成率仅 %.0f%%，需要加油", rate * 100))
            }

            if let topStreak = h.streaks.first, topStreak.currentStreak >= 7 {
                highlights.append("\(topStreak.habitName) 连续打卡 \(topStreak.currentStreak) 天")
            }
        }

        // 任务亮点/风险
        if let t = task, !t.isDataFree {
            if t.completionRate >= 0.8 {
                highlights.append(String(format: "任务完成率 %.0f%%，执行力强", t.completionRate * 100))
            } else if t.completionRate < 0.5 {
                warnings.append(String(format: "任务完成率仅 %.0f%%，有 \(t.overdueCount) 个逾期", t.completionRate * 100))
            }

            if t.overdueCount > 3 {
                warnings.append("逾期任务较多（\(t.overdueCount) 个），建议优先处理")
            }
        }

        // 想法亮点
        if let th = thought, !th.isDataFree {
            if th.totalCount >= 10 {
                highlights.append("记录了 \(th.totalCount) 条想法，保持了良好的思考习惯")
            }
            if let topMood = th.moodDistribution.first {
                highlights.append("最常见的心情是「\(topMood.mood)」")
            }
        }

        // 健康亮点/风险
        if let ht = health, !ht.isDataFree {
            if let score = ht.overallBodyScore {
                if score >= 80 {
                    highlights.append(String(format: "健康体表分 %.0f，状态良好", score))
                } else if score < 50 {
                    warnings.append(String(format: "健康体表分仅 %.0f，需要关注", score))
                }
            }
            if let prevScore = ht.previousPeriodScore, let currScore = ht.overallBodyScore {
                let diff = currScore - prevScore
                if diff > 10 {
                    highlights.append(String(format: "体表分较上期提升 %.0f 分", diff))
                } else if diff < -10 {
                    warnings.append(String(format: "体表分较上期下降 %.0f 分", abs(diff)))
                }
            }
            for anomaly in ht.anomalyNotes {
                warnings.append(anomaly)
            }
        }

        // 目标亮点/风险
        if let g = goal, !g.isDataFree {
            if g.totalActiveGoals > 0 && g.atRiskGoals.isEmpty {
                highlights.append("\(g.totalActiveGoals) 个活跃目标均无风险")
            }
            if !g.atRiskGoals.isEmpty {
                warnings.append("\(g.atRiskGoals.count) 个目标存在风险：\(g.atRiskGoals.joined(separator: "、"))")
            }
            if g.completedGoalsInPeriod > 0 {
                highlights.append("本周期完成了 \(g.completedGoalsInPeriod) 个目标")
            }
        }

        return CrossModuleAnalysisContext(
            highlights: Array(highlights.prefix(7)),
            warnings: Array(warnings.prefix(5))
        )
    }
}
```

### Step 3: 编译验证

Xcode Build 确认无错误。此时整个分析管线已连通。

### Step 4: 提交

```bash
git -C /Users/tangyuxuan/Desktop/Claude/Holo add "Holo/Holo APP/Holo/Holo/Services/AI/AnalysisContextBuilder.swift" "Holo/Holo APP/Holo/Holo/Services/AI/CrossModuleAnalysisContextBuilder.swift"
git -C /Users/tangyuxuan/Desktop/Claude/Holo commit -m "feat(iOS): 集成 health/goal 分析域到分发器和跨模块聚合"
```

---

## Task 7: 更新 UI 层

**Files:**
- Modify: `BASE/Views/Chat/Analysis/AnalysisSummaryFormatter.swift`
- Modify: `BASE/Models/AI/ChatCardData.swift`

### Step 1: AnalysisSummaryFormatter 新增 health/goal 格式化

在 `format(from:)` 的 switch 中新增两个 case（在 `.crossModule` 之前）：

```swift
case .health:
    return formatHealth(context: context, periodLabel: periodLabel)
case .goal:
    return formatGoal(context: context, periodLabel: periodLabel)
```

在文件末尾（`resolvePeriodLabel` 之前）新增两个私有方法：

```swift
// MARK: - Health

private static func formatHealth(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
    guard let health = context.health else { return nil }

    var parts: [String] = []
    if let score = health.overallBodyScore {
        parts.append("体表分 \(String(format: "%.0f", score))")
    }
    if let steps = health.steps, !steps.isDataFree {
        parts.append("日均 \(Int(steps.dailyAverage).formatted()) 步")
    }
    if let sleep = health.sleep, !sleep.isDataFree {
        parts.append("日均 \(String(format: "%.1f", sleep.dailyAverage))h 睡眠")
    }
    if !health.anomalyNotes.isEmpty {
        parts.append("\(health.anomalyNotes.count) 项提醒")
    }

    return AnalysisCompactSummary(
        icon: "heart.fill",
        title: "健康分析 · \(periodLabel)",
        subtitle: periodLabel,
        summaryLine: parts.isEmpty ? "暂无数据" : parts.joined(separator: " · ")
    )
}

// MARK: - Goal

private static func formatGoal(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
    guard let goal = context.goal else { return nil }

    var parts: [String] = []
    parts.append("活跃 \(goal.totalActiveGoals) 个")
    if goal.completedGoalsInPeriod > 0 {
        parts.append("完成 \(goal.completedGoalsInPeriod) 个")
    }
    if !goal.atRiskGoals.isEmpty {
        parts.append("\(goal.atRiskGoals.count) 个风险")
    }

    return AnalysisCompactSummary(
        icon: "target",
        title: "目标分析 · \(periodLabel)",
        subtitle: periodLabel,
        summaryLine: parts.joined(separator: " · ")
    )
}
```

### Step 2: ChatCardData 新增 health/goal 卡片工厂

在 `fromAnalysisContext(_:)` 的 switch 中新增两个 case（在 `.crossModule` 之前）：

```swift
case .health:
    if let ht = context.health {
        cards.append(contentsOf: healthCards(ht, periodLabel: context.periodLabel))
    }
case .goal:
    if let g = context.goal {
        cards.append(contentsOf: goalCards(g, periodLabel: context.periodLabel))
    }
```

在文件末尾（`thoughtCards` 方法之后、`}` 关闭大括号之前）新增：

```swift
// MARK: - Health Cards

private static func healthCards(_ h: HealthAnalysisContext, periodLabel: String) -> [ChatCardData] {
    var cards: [ChatCardData] = []

    // Summary
    var metrics: [AnalysisBreakdownRow] = []
    if let steps = h.steps, !steps.isDataFree {
        metrics.append(AnalysisBreakdownRow(
            label: "步数",
            value: "日均 \(Int(steps.dailyAverage).formatted()) 步 · 达标 \(steps.goalMetDays)/\(steps.totalDays) 天",
            percent: steps.totalDays > 0 ? Double(steps.goalMetDays) / Double(steps.totalDays) : nil
        ))
    }
    if let sleep = h.sleep, !sleep.isDataFree {
        metrics.append(AnalysisBreakdownRow(
            label: "睡眠",
            value: "日均 \(String(format: "%.1f", sleep.dailyAverage))h · 达标 \(sleep.goalMetDays)/\(sleep.totalDays) 天",
            percent: sleep.totalDays > 0 ? Double(sleep.goalMetDays) / Double(sleep.totalDays) : nil
        ))
    }
    if let stand = h.stand, !stand.isDataFree {
        metrics.append(AnalysisBreakdownRow(
            label: "站立",
            value: "日均 \(String(format: "%.1f", stand.dailyAverage))h · 达标 \(stand.goalMetDays)/\(stand.totalDays) 天",
            percent: stand.totalDays > 0 ? Double(stand.goalMetDays) / Double(stand.totalDays) : nil
        ))
    }
    if let active = h.activeMinutes, !active.isDataFree {
        metrics.append(AnalysisBreakdownRow(
            label: "活动",
            value: "日均 \(Int(active.dailyAverage).formatted()) 分钟 · 达标 \(active.goalMetDays)/\(active.totalDays) 天",
            percent: active.totalDays > 0 ? Double(active.goalMetDays) / Double(active.totalDays) : nil
        ))
    }
    if let score = h.overallBodyScore {
        metrics.append(AnalysisBreakdownRow(
            label: "体表分",
            value: String(format: "%.0f", score),
            percent: score / 100
        ))
    }
    if !metrics.isEmpty {
        cards.append(.analysisSummary(AnalysisSummaryCardData(
            domain: .health,
            periodLabel: periodLabel,
            metrics: metrics
        )))
    }

    // Trend — 步数趋势
    if let steps = h.steps, steps.dailyTrend.count > 1 {
        let points = steps.dailyTrend.suffix(14).map { pt in
            AnalysisTrendPoint(label: pt.date, value: pt.rate, displayValue: "\(Int(pt.rate).formatted()) 步")
        }
        cards.append(.analysisTrend(AnalysisTrendCardData(title: "步数趋势", points: points)))
    }

    // Trend — 睡眠趋势
    if let sleep = h.sleep, sleep.dailyTrend.count > 1 {
        let points = sleep.dailyTrend.suffix(14).map { pt in
            AnalysisTrendPoint(label: pt.date, value: pt.rate, displayValue: String(format: "%.1fh", pt.rate))
        }
        cards.append(.analysisTrend(AnalysisTrendCardData(title: "睡眠趋势", points: points)))
    }

    // Comparison — 体表分环比
    if let curr = h.overallBodyScore, let prev = h.previousPeriodScore {
        let diff = curr - prev
        let changeStr = diff >= 0 ? "+\(String(format: "%.0f", diff))" : String(format: "%.0f", diff)
        cards.append(.analysisComparison(AnalysisComparisonCardData(
            title: "体表分环比",
            currentValue: String(format: "%.0f", curr),
            previousValue: String(format: "%.0f", prev),
            change: changeStr
        )))
    }

    // Highlights
    if !h.anomalyNotes.isEmpty {
        cards.append(.analysisHighlights(AnalysisHighlightsCardData(
            highlights: [],
            warnings: h.anomalyNotes
        )))
    }

    return cards
}

// MARK: - Goal Cards

private static func goalCards(_ g: GoalAnalysisContext, periodLabel: String) -> [ChatCardData] {
    var cards: [ChatCardData] = []

    // Summary
    var metrics: [AnalysisBreakdownRow] = [
        AnalysisBreakdownRow(label: "活跃目标", value: "\(g.totalActiveGoals)", percent: nil)
    ]
    if g.completedGoalsInPeriod > 0 {
        metrics.append(AnalysisBreakdownRow(label: "本周期完成", value: "\(g.completedGoalsInPeriod)", percent: nil))
    }
    if !g.atRiskGoals.isEmpty {
        metrics.append(AnalysisBreakdownRow(label: "风险目标", value: "\(g.atRiskGoals.count)", percent: nil))
    }
    cards.append(.analysisSummary(AnalysisSummaryCardData(
        domain: .goal,
        periodLabel: periodLabel,
        metrics: metrics
    )))

    // Breakdown — 各目标进度
    let progressItems = g.goals.filter { $0.overallProgress != nil || $0.linkedTaskTotal > 0 }
    if !progressItems.isEmpty {
        let rows = progressItems.map { item in
            let progressStr = item.overallProgress.map { String(format: "%.0f%%", $0 * 100) } ?? "无数据"
            let taskInfo = "\(item.linkedTaskCompleted)/\(item.linkedTaskTotal) 任务"
            return AnalysisBreakdownRow(
                label: item.title,
                value: "\(progressStr) · \(taskInfo)",
                percent: item.overallProgress
            )
        }
        cards.append(.analysisBreakdown(AnalysisBreakdownCardData(title: "目标进度", rows: rows)))
    }

    // Highlights
    var highlights: [String] = []
    var warnings: [String] = g.atRiskGoals.map { "\($0) 需要关注" }
    if let prev = g.previousPeriodCompleted, prev > 0 {
        let diff = g.completedGoalsInPeriod - prev
        if diff > 0 {
            highlights.append("比上期多完成 \(diff) 个目标")
        }
    }
    if !highlights.isEmpty || !warnings.isEmpty {
        cards.append(.analysisHighlights(AnalysisHighlightsCardData(
            highlights: highlights,
            warnings: warnings
        )))
    }

    return cards
}
```

### Step 3: 编译验证

Xcode Build 确认无错误。

### Step 4: 提交

```bash
git -C /Users/tangyuxuan/Desktop/Claude/Holo add "Holo/Holo APP/Holo/Holo/Views/Chat/Analysis/AnalysisSummaryFormatter.swift" "Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift"
git -C /Users/tangyuxuan/Desktop/Claude/Holo commit -m "feat(iOS): 健康和目标分析卡片渲染"
```

---

## Task 8: 更新 PromptManager 模板

**Files:**
- Modify: `BASE/Services/AI/PromptManager.swift`

### Step 1: 更新 intent_recognition 模板

在 `intentRecognition` 模板的意图列表中，更新 `query_analysis` 行的触发词：

```
| query_analysis | 分析*/复盘*/对比总结/花了多少/消费统计/支出统计/习惯完成率/任务进度/步数/睡眠/运动/健康/走路/锻炼/目标进展/进度/goal | analysisDomain, startDate?, endDate?, periodLabel? |
```

更新 `analysisDomain` 字段描述（在示例 JSON 中的 `extractedData`）：

```
"analysisDomain": "finance|habit|task|thought|health|goal|crossModule",
```

### Step 2: 更新 analysis_prompt 模板

在 `analysis_prompt` 模板的"各领域分析侧重"部分追加两个领域：

```
- **健康**：步数/睡眠/站立/活动趋势、达标率、体表分变化、异常检测（连续睡眠不足、连续低步数）。bodyScore 使用 3 槽位模型（步数 30%、睡眠 45%、站立或活动 25%）。建议聚焦可改善指标，说明具体目标差距。
- **目标**：目标整体进度、关联任务完成率、关联习惯完成率、风险目标预警。风险标准：deadline < 7 天且进度 < 50%、关联习惯完成率 < 30%。综合进度 = 任务 60% + 习惯 40%。
```

### Step 3: 更新 promptVersions 版本号

将 `intentRecognition` 版本从 8 提升到 9：

```swift
private static let promptVersions: [PromptType: Int] = [
    .intentRecognition: 9,          // v9: health/goal 分析域
    .memoryInsightGeneration: 5,
    .annualReview: 1,
    .thoughtVoiceSummary: 1
]
```

### Step 4: 编译验证

Xcode Build 确认无错误。

### Step 5: 提交

```bash
git -C /Users/tangyuxuan/Desktop/Claude/Holo add "Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift"
git -C /Users/tangyuxuan/Desktop/Claude/Holo commit -m "feat(iOS): PromptManager 新增健康/目标分析指引"
```

---

## Task 9: 后端 Prompt 同步 + 部署

**Files:**
- Modify: `HoloBackend/src/prompts/defaultPrompts.json`

### Step 1: 更新后端 defaultPrompts.json

与 iOS PromptManager 的改动同步更新 `defaultPrompts.json`：

1. `intent_recognition`：更新 `query_analysis` 触发词和 `analysisDomain` 字段值
2. `analysis_prompt`：追加健康和目标分析指引
3. 版本号更新

### Step 2: 部署后端

```bash
ssh root@123.56.104.9
cd /root/Holo/HoloBackend/deploy
docker compose build --no-cache && docker compose up -d
```

### Step 3: 验证部署

```bash
curl http://localhost:8787/v1/prompts/intent_recognition
curl http://localhost:8787/v1/prompts/analysis_prompt
```

确认返回内容包含 `health`、`goal` 关键词。

---

## 自查清单

- [ ] **Spec 覆盖**：设计文档 12 个文件改动 → Task 1-9 全覆盖
- [ ] **Placeholder 扫描**：无 TBD/TODO/待定
- [ ] **类型一致性**：HealthAnalysisContext/GoalAnalysisContext 定义与所有引用点一致
- [ ] **编译完整**：每个 Task 都有编译验证步骤
- [ ] **双端同步**：PromptManager + 后端 defaultPrompts.json 都已更新
