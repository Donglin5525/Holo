# Daily Sense 状态卡片重设计 - 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重写 Daily Sense 卡片为时间线圆点式布局，优化四维信号文案和阈值，启用健康数据。

**Architecture:** 模型层新增结构化信号类型替换旧 reasons 字符串数组；规则引擎输出 `[DailySenseSignal]` 并改为 async；UI 层用收起态圆点行+展开态时间线替换旧卡片。

**Tech Stack:** SwiftUI, Core Data, HealthKit, Codable JSON 持久化

**设计文档:** `docs/_common/plans/2026-06-05-Daily-Sense-状态卡片重设计.md`

**基础路径:** `/Users/tangyuxuan/Desktop/Claude/Holo/Holo/Holo APP/Holo/`

---

## 文件结构

| 文件 | 职责 |
|------|------|
| `Models/DailySenseSnapshot.swift` | 模型定义：`DailySenseSignal`, `SenseDimension`, `SignalLevel`, `DailySenseSnapshot` v2 |
| `Services/AI/DailySenseStateBuilder.swift` | 规则引擎：四维信号计算，输出 `[DailySenseSignal]`，async |
| `Views/MemoryGallery/Components/DailySenseStatusCard.swift` | UI：收起态圆点行 + 展开态时间线 |
| `Views/MemoryGallery/MemoryGalleryViewModel.swift` | 集成：调用 async builder，处理 legacy 缓存 |
| `HoloTests/Models/DailySenseSnapshotTests.swift` | 新增：模型 Codable 兼容性测试 |

---

### Task 1: 模型层 — 新增信号类型 + DailySenseSnapshot v2

**Files:**
- Modify: `Models/DailySenseSnapshot.swift`
- Create: `HoloTests/Models/DailySenseSnapshotTests.swift`

- [ ] **Step 1: 写 DailySenseSnapshot Codable 兼容性测试**

创建 `HoloTests/Models/DailySenseSnapshotTests.swift`：

```swift
import XCTest
@testable import Holo

final class DailySenseSnapshotTests: XCTestCase {

    // MARK: - v2 正常编解码

    func testV2RoundTrip() throws {
        let signals = [
            DailySenseSignal(dimension: .task, level: .warning, text: "2 笔过了截止日"),
            DailySenseSignal(dimension: .expense, level: .critical, text: "今天 ¥560 · 平时 ¥50"),
            DailySenseSignal(dimension: .health, level: .normal, text: "7.5h")
        ]
        let snapshot = DailySenseSnapshot(
            date: Date(),
            state: .atRisk,
            signals: signals,
            generatedAt: Date()
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DailySenseSnapshot.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.state, .atRisk)
        XCTAssertEqual(decoded.signals.count, 3)
        XCTAssertEqual(decoded.signals[0].dimension, .task)
        XCTAssertEqual(decoded.signals[0].level, .warning)
        XCTAssertEqual(decoded.signals[1].text, "今天 ¥560 · 平时 ¥50")
        XCTAssertFalse(decoded.isLegacy)
    }

    // MARK: - 旧版 JSON 兼容

    func testLegacyJSONDecoding() throws {
        // 模拟旧版格式：有 confidence + reasons，无 signals + schemaVersion
        let json = """
        {
            "date": 700000000,
            "state": "atRisk",
            "confidence": 0.8,
            "reasons": ["3 个任务逾期", "消费偏离均值 11.2x"],
            "generatedAt": 700000001
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DailySenseSnapshot.self, from: json)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.isLegacy)
        XCTAssertEqual(decoded.signals.count, 0)
        XCTAssertEqual(decoded.state, .atRisk)
    }

    // MARK: - signals 为空时的 snapshot

    func testEmptySignalsIsNotLegacy() throws {
        let snapshot = DailySenseSnapshot(
            date: Date(),
            state: .stable,
            signals: [],
            generatedAt: Date()
        )
        XCTAssertEqual(snapshot.schemaVersion, 2)
        XCTAssertFalse(snapshot.isLegacy)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test -project "Holo/Holo APP/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoloTests/DailySenseSnapshotTests 2>&1 | tail -20`

Expected: 编译失败（`DailySenseSignal` 类型不存在）

- [ ] **Step 3: 修改 DailySenseSnapshot.swift — 新增类型 + v2 模型**

将 `Models/DailySenseSnapshot.swift` 内容替换为：

```swift
//  DailySenseSnapshot.swift
//  Holo
//
//  每日状态雷达模型（v2）
//  结构化信号替代旧版 reasons 字符串数组
//

import Foundation

/// 信号维度
enum SenseDimension: String, Codable, CaseIterable {
    case task, habit, expense, health

    /// 显示名称
    var displayName: String {
        switch self {
        case .task: return "待办"
        case .habit: return "习惯"
        case .expense: return "消费"
        case .health: return "健康"
        }
    }
}

/// 信号等级
enum SignalLevel: String, Codable {
    case normal    // .holoSuccess 绿
    case warning   // .orange 橙
    case critical  // .holoError 红
}

/// 单维度信号
struct DailySenseSignal: Codable, Equatable {
    let dimension: SenseDimension
    let level: SignalLevel
    let text: String
}

/// 每日状态
enum DailySenseState: String, Codable {
    case stable       // 节奏不错
    case atRisk       // 节奏有点乱
    case recovering   // 节奏在找回
}

/// 每日状态快照（v2）
struct DailySenseSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let date: Date
    let state: DailySenseState
    let signals: [DailySenseSignal]
    let generatedAt: Date

    /// JSON 向下兼容解码
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        date = try container.decode(Date.self, forKey: .date)
        state = try container.decode(DailySenseState.self, forKey: .state)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        signals = try container.decodeIfPresent([DailySenseSignal].self, forKey: .signals) ?? []
    }

    /// 普通构造器
    init(date: Date, state: DailySenseState, signals: [DailySenseSignal], generatedAt: Date) {
        self.schemaVersion = 2
        self.date = date
        self.state = state
        self.signals = signals
        self.generatedAt = generatedAt
    }

    /// 是否为旧版格式（需要强制重建）
    var isLegacy: Bool { schemaVersion < 2 }

    /// 状态标题
    var stateTitle: String {
        switch state {
        case .stable: return "节奏不错"
        case .atRisk: return "节奏有点乱"
        case .recovering: return "节奏在找回"
        }
    }
}

/// 每日状态持久化（保留最近 7 天 JSON 数组）
final class DailySenseSnapshotStore {
    static let shared = DailySenseSnapshotStore()

    private let maxDays = 7
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo", isDirectory: true)
        return dir.appendingPathComponent("DailySenseSnapshots.json")
    }()

    private(set) var snapshots: [DailySenseSnapshot] = []

    private init() {
        load()
    }

    /// 保存今日快照（替换同日期的旧快照）
    func saveToday(_ snapshot: DailySenseSnapshot) {
        let calendar = Calendar.current
        snapshots.removeAll { calendar.isDate($0.date, inSameDayAs: snapshot.date) }
        snapshots.append(snapshot)
        cleanup()
        save()
    }

    /// 获取今日快照
    func todaySnapshot() -> DailySenseSnapshot? {
        let calendar = Calendar.current
        return snapshots.last { calendar.isDate($0.date, inSameDayAs: Date()) }
    }

    /// 获取最近 N 天快照
    func recentSnapshots(days: Int = 7) -> [DailySenseSnapshot] {
        Array(snapshots.suffix(days))
    }

    // MARK: - Private

    private func cleanup() {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -maxDays, to: Date()) ?? Date()
        snapshots = snapshots.filter { $0.date >= cutoff }
        snapshots.sort { $0.date < $1.date }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        snapshots = (try? JSONDecoder().decode([DailySenseSnapshot].self, from: data)) ?? []
        cleanup()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild test -project "Holo/Holo APP/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoloTests/DailySenseSnapshotTests 2>&1 | tail -20`

Expected: 3 个测试全部 PASS

- [ ] **Step 5: 修复编译错误**

`DailySenseStateBuilder.swift` 和 `DailySenseStatusCard.swift` 引用了旧的 `reasons` / `confidence` 字段。临时修复编译：
- `DailySenseStateBuilder.swift`：将所有 `reasons.append(...)` 改为空操作，`return DailySenseSnapshot(...)` 使用新构造器传入 `signals: []`
- `DailySenseStatusCard.swift`：将 `snapshot.reasons` 替换为 `snapshot.signals.map(\.text)` 临时兼容

确认 `xcodebuild build` 编译通过。

- [ ] **Step 6: 提交**

```bash
git add "Holo/Holo APP/Holo/HoloTests/Models/DailySenseSnapshotTests.swift" "Holo/Holo APP/Holo/Holo/Models/DailySenseSnapshot.swift" "Holo/Holo APP/Holo/Holo/Services/AI/DailySenseStateBuilder.swift" "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/DailySenseStatusCard.swift"
git commit -m "refactor(iOS): DailySense 模型升级 v2，结构化信号替代 reasons 字符串数组"
```

---

### Task 2: 规则引擎 — 重写 DailySenseStateBuilder

**Files:**
- Modify: `Services/AI/DailySenseStateBuilder.swift`

- [ ] **Step 1: 重写 DailySenseStateBuilder**

将 `Services/AI/DailySenseStateBuilder.swift` 完整替换为：

```swift
//  DailySenseStateBuilder.swift
//  Holo
//
//  每日状态规则引擎（v2）
//  输出结构化 DailySenseSignal，async 支持 HealthRepository
//

import Foundation
import CoreData
import os.log

struct DailySenseStateBuilder {
    private static let logger = Logger(subsystem: "com.holo.app", category: "DailySenseStateBuilder")

    /// 生成今日状态快照
    static func buildToday() async -> DailySenseSnapshot? {
        let context = CoreDataStack.shared.viewContext
        let today = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: today)

        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: todayStart) else {
            return nil
        }

        var signals: [DailySenseSignal] = []
        var riskScore: Double = 0
        var recoveryScore: Double = 0

        // 待办信号
        let overdueCount = fetchOverdueTaskCount(in: context, asOf: todayStart)
        let hasTasks = hasAnyTasks(in: context)
        if hasTasks {
            if overdueCount >= 3 {
                signals.append(DailySenseSignal(dimension: .task, level: .warning, text: "\(overdueCount) 笔过了截止日"))
                riskScore += 1.0
            } else if overdueCount > 0 {
                signals.append(DailySenseSignal(dimension: .task, level: .warning, text: "\(overdueCount) 笔快到截止日了"))
                riskScore += 0.3
            } else {
                signals.append(DailySenseSignal(dimension: .task, level: .normal, text: "没有逾期"))
            }
        }

        // 习惯信号
        let brokenHabits = fetchBrokenHabitCount(in: context, asOf: todayStart)
        let recoveredHabits = fetchRecoveredHabitCount(in: context, asOf: todayStart)
        let hasHabits = hasAnyHabits(in: context)
        if hasHabits {
            if brokenHabits >= 2 {
                signals.append(DailySenseSignal(dimension: .habit, level: .warning, text: "\(brokenHabits) 个断了节奏"))
                riskScore += 0.8
            } else if recoveredHabits > 0 {
                signals.append(DailySenseSignal(dimension: .habit, level: .normal, text: "\(recoveredHabits) 个恢复打卡"))
                recoveryScore += 1.0
            } else {
                signals.append(DailySenseSignal(dimension: .habit, level: .normal, text: "打卡都完成了"))
            }
        }

        // 消费信号
        let expenseResult = fetchExpenseDeviation(in: context, weekStart: weekAgo, todayStart: todayStart)
        if expenseResult.hasData {
            let todayAmount = expenseResult.todayAmount
            let dailyAvg = expenseResult.dailyAvg

            if todayAmount > 100 && todayAmount / dailyAvg > 3.0 {
                signals.append(DailySenseSignal(
                    dimension: .expense,
                    level: .critical,
                    text: "今天 \(formatAmount(todayAmount)) · 平时 \(formatAmount(dailyAvg))"
                ))
                riskScore += 0.6
            } else if todayAmount / dailyAvg > 1.5 {
                let diff = todayAmount - dailyAvg
                signals.append(DailySenseSignal(
                    dimension: .expense,
                    level: .warning,
                    text: "比平时多花了 \(formatAmount(diff))"
                ))
                riskScore += 0.3
            } else {
                signals.append(DailySenseSignal(dimension: .expense, level: .normal, text: "消费正常"))
                if todayAmount / dailyAvg <= 1.0 && todayAmount > 0 {
                    recoveryScore += 0.3
                }
            }
        }

        // 健康信号
        if InsightFeatureFlags.healthContextEnabled {
            if let healthSignal = await buildHealthSignal() {
                signals.append(healthSignal)
                if healthSignal.level == .warning {
                    riskScore += 0.3
                } else if healthSignal.level == .critical {
                    riskScore += 0.5
                }
            }
        }

        // 数据不足时不生成快照
        guard !signals.isEmpty else {
            return nil
        }

        // 状态优先级：atRisk > recovering > stable
        let state: DailySenseState
        if riskScore >= 1.0 {
            state = .atRisk
        } else if recoveryScore >= 0.5 {
            state = .recovering
        } else {
            state = .stable
        }

        return DailySenseSnapshot(
            date: today,
            state: state,
            signals: signals,
            generatedAt: Date()
        )
    }

    // MARK: - Task Signal Fetchers

    private static func fetchOverdueTaskCount(in context: NSManagedObjectContext, asOf date: Date) -> Int {
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "completed == NO AND deletedFlag == NO AND archived == NO AND dueDate < %@",
            date as CVarArg
        )
        return (try? context.count(for: request)) ?? 0
    }

    private static func hasAnyTasks(in context: NSManagedObjectContext) -> Bool {
        let request: NSFetchRequest<TodoTask> = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "deletedFlag == NO AND archived == NO")
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    // MARK: - Habit Signal Fetchers

    private static func fetchBrokenHabitCount(in context: NSManagedObjectContext, asOf date: Date) -> Int {
        let calendar = Calendar.current
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: date) else { return 0 }

        let request: NSFetchRequest<HabitRecord> = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND habit.isBadHabit == NO AND isCompleted == NO",
            yesterday as CVarArg,
            date as CVarArg
        )
        let records = (try? context.fetch(request)) ?? []
        return Set(records.map(\.habitId)).count
    }

    private static func fetchRecoveredHabitCount(in context: NSManagedObjectContext, asOf date: Date) -> Int {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { return 0 }

        let todayRequest: NSFetchRequest<HabitRecord> = HabitRecord.fetchRequest()
        todayRequest.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND isCompleted == YES",
            date as CVarArg,
            tomorrow as CVarArg
        )
        let todayCompleted = (try? context.fetch(todayRequest)) ?? []
        return min(Set(todayCompleted.map(\.habitId)).count, 3)
    }

    private static func hasAnyHabits(in context: NSManagedObjectContext) -> Bool {
        let request: NSFetchRequest<HabitRecord> = HabitRecord.fetchRequest()
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    // MARK: - Expense Signal Fetchers

    private struct ExpenseResult {
        let todayAmount: Double
        let dailyAvg: Double
        let hasData: Bool
    }

    private static func fetchExpenseDeviation(
        in context: NSManagedObjectContext,
        weekStart: Date,
        todayStart: Date
    ) -> ExpenseResult {
        let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND type == %@",
            weekStart as CVarArg,
            todayStart as CVarArg,
            "expense"
        )

        guard let transactions = try? context.fetch(request) else {
            return ExpenseResult(todayAmount: 0, dailyAvg: 0, hasData: false)
        }
        let totalAmount = transactions.map { $0.amount.doubleValue }.reduce(0, +)
        let days = max(Calendar.current.dateComponents([.day], from: weekStart, to: todayStart).day ?? 1, 1)
        let dailyAvg = totalAmount / Double(days)

        let todayRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        todayRequest.predicate = NSPredicate(
            format: "date >= %@ AND type == %@",
            todayStart as CVarArg,
            "expense"
        )
        let todayAmount = ((try? context.fetch(todayRequest)) ?? []).map { $0.amount.doubleValue }.reduce(0, +)

        let hasData = dailyAvg > 0 || todayAmount > 0
        return ExpenseResult(todayAmount: todayAmount, dailyAvg: dailyAvg, hasData: hasData)
    }

    // MARK: - Health Signal

    private static func buildHealthSignal() async -> DailySenseSignal? {
        let healthRepo = HealthRepository.shared

        guard healthRepo.isAuthorized else {
            return nil
        }

        // 如果缓存值为 0，尝试刷新一次
        if healthRepo.todaySleep == 0 && healthRepo.todaySteps == 0 {
            await healthRepo.refresh()
        }

        let sleepHours = healthRepo.todaySleep
        let steps = healthRepo.todaySteps
        let sleepAvailable = healthRepo.sleepAvailability == .available
        let stepsAvailable = healthRepo.stepsAvailability == .available

        guard sleepAvailable || stepsAvailable else {
            return nil
        }

        // 优先显示异常项
        if sleepAvailable && sleepHours < 5 {
            return DailySenseSignal(dimension: .health, level: .critical, text: "只睡了 \(String(format: "%.1f", sleepHours))h")
        }
        if stepsAvailable && steps < 2000 {
            return DailySenseSignal(dimension: .health, level: .warning, text: "步数偏少")
        }
        if sleepAvailable && sleepHours < 6 {
            return DailySenseSignal(dimension: .health, level: .warning, text: "\(String(format: "%.1f", sleepHours))h · 有点少")
        }

        // 无异常，显示睡眠时长
        if sleepAvailable {
            return DailySenseSignal(dimension: .health, level: .normal, text: "\(String(format: "%.1f", sleepHours))h")
        }
        if stepsAvailable {
            let formatted = NumberFormatter().then {
                $0.numberStyle = .decimal
                $0.maximumFractionDigits = 0
            }.string(from: Int(steps) as NSNumber) ?? "\(Int(steps))"
            return DailySenseSignal(dimension: .health, level: .normal, text: "走了 \(formatted) 步")
        }

        return nil
    }

    // MARK: - Formatting

    private static func formatAmount(_ value: Double) -> String {
        "¥\(Int(value.rounded()))"
    }
}
```

注意：`NumberFormatter().then` 如果项目中没有 `then` 扩展，改用普通初始化方式：

```swift
let formatter = NumberFormatter()
formatter.numberStyle = .decimal
formatter.maximumFractionDigits = 0
let formatted = formatter.string(from: Int(steps) as NSNumber) ?? "\(Int(steps))"
```

- [ ] **Step 2: 修复 MemoryGalleryViewModel 调用点**

修改 `Views/MemoryGallery/MemoryGalleryViewModel.swift` 第 664-672 行，将：

```swift
// 加载或生成 Daily Sense
if InsightFeatureFlags.dailySenseEnabled {
    if let cached = DailySenseSnapshotStore.shared.todaySnapshot() {
        dailySenseSnapshot = cached
    } else if let snapshot = DailySenseStateBuilder.buildToday() {
        DailySenseSnapshotStore.shared.saveToday(snapshot)
        dailySenseSnapshot = snapshot
    }
}
```

替换为：

```swift
// 加载或生成 Daily Sense
if InsightFeatureFlags.dailySenseEnabled {
    let cached = DailySenseSnapshotStore.shared.todaySnapshot()
    if let cached, !cached.isLegacy, !cached.signals.isEmpty {
        dailySenseSnapshot = cached
    } else if let snapshot = await DailySenseStateBuilder.buildToday() {
        DailySenseSnapshotStore.shared.saveToday(snapshot)
        dailySenseSnapshot = snapshot
    }
}
```

- [ ] **Step 3: 确认编译通过**

Run: `xcodebuild build -project "Holo/Holo APP/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/DailySenseStateBuilder.swift" "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryViewModel.swift"
git commit -m "feat(iOS): Daily Sense 规则引擎 v2，结构化信号输出 + 健康数据接入"
```

---

### Task 3: UI 层 — 重写 DailySenseStatusCard

**Files:**
- Modify: `Views/MemoryGallery/Components/DailySenseStatusCard.swift`

- [ ] **Step 1: 重写 DailySenseStatusCard**

将 `Views/MemoryGallery/Components/DailySenseStatusCard.swift` 完整替换为：

```swift
//  DailySenseStatusCard.swift
//  Holo
//
//  每日状态卡片（v2）
//  收起态：状态图标 + 标题 + 彩色圆点行
//  展开态：竖线圆点时间线
//

import SwiftUI

struct DailySenseStatusCard: View {

    let snapshot: DailySenseSnapshot

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // 收起态（始终显示）
            collapsedView
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                }

            // 展开态
            if isExpanded {
                expandedView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(stateColor.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Collapsed

    private var collapsedView: some View {
        HStack(spacing: HoloSpacing.md) {
            // 状态图标
            Image(systemName: stateIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(stateColor)

            // 状态标题
            Text(snapshot.stateTitle)
                .font(.holoCaption)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 彩色圆点行
            HStack(spacing: 4) {
                ForEach(snapshot.signals, id: \.dimension) { signal in
                    Circle()
                        .fill(colorForLevel(signal.level))
                        .frame(width: 8, height: 8)
                }
            }

            // 展开/收起箭头
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.holoTextPlaceholder)
        }
    }

    // MARK: - Expanded

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .background(Color.holoBorder.opacity(0.3))
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.xs)

            // 竖线圆点时间线
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(snapshot.signals.enumerated()), id: \.element.dimension) { index, signal in
                    HStack(spacing: HoloSpacing.sm) {
                        // 圆点
                        signalDot(signal: signal, isLast: index == snapshot.signals.count - 1)
                            .frame(width: 16)

                        // 维度名称
                        Text(signal.dimension.displayName)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 28, alignment: .leading)

                        // 信号文案
                        Text(signal.text)
                            .font(.holoTinyLabel)
                            .foregroundColor(colorForLevel(signal.level))
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
            }
            .padding(.leading, HoloSpacing.xs)
        }
    }

    // MARK: - Signal Dot with Timeline Line

    @ViewBuilder
    private func signalDot(signal: DailySenseSignal, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            // 圆点
            Circle()
                .fill(colorForLevel(signal.level))
                .frame(width: 8, height: 8)

            // 竖线（非最后一行才显示）
            if !isLast {
                Rectangle()
                    .fill(Color.holoBorder.opacity(0.2))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Style Helpers

    private var stateColor: Color {
        switch snapshot.state {
        case .stable: return .holoSuccess
        case .atRisk: return .orange
        case .recovering: return .holoPrimary
        }
    }

    private var stateIcon: String {
        switch snapshot.state {
        case .stable: return "checkmark.circle.fill"
        case .atRisk: return "exclamationmark.triangle.fill"
        case .recovering: return "arrow.up.circle.fill"
        }
    }

    private func colorForLevel(_ level: SignalLevel) -> Color {
        switch level {
        case .normal: return .holoSuccess
        case .warning: return .orange
        case .critical: return .holoError
        }
    }
}
```

- [ ] **Step 2: 确认编译通过**

Run: `xcodebuild build -project "Holo/Holo APP/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/DailySenseStatusCard.swift"
git commit -m "feat(iOS): Daily Sense 卡片重写，时间线圆点布局 + 展开态信号详情"
```

---

### Task 4: 集成验证 + CHANGELOG

**Files:**
- Modify: `Views/MemoryGallery/MemoryGalleryView.swift` (可能需要微调)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: 确认 MemoryGalleryView 的 signals.isEmpty 判断**

检查 `Views/MemoryGallery/MemoryGalleryView.swift` 第 139-142 行：

```swift
if InsightFeatureFlags.dailySenseEnabled,
   let snapshot = viewModel.dailySenseSnapshot {
    DailySenseStatusCard(snapshot: snapshot)
}
```

需要额外判断 `!snapshot.signals.isEmpty`，改为：

```swift
if InsightFeatureFlags.dailySenseEnabled,
   let snapshot = viewModel.dailySenseSnapshot,
   !snapshot.signals.isEmpty {
    DailySenseStatusCard(snapshot: snapshot)
}
```

- [ ] **Step 2: 全量编译**

Run: `xcodebuild build -project "Holo/Holo APP/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: 运行测试**

Run: `xcodebuild test -project "Holo/Holo APP/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoloTests/DailySenseSnapshotTests 2>&1 | tail -20`

Expected: 所有测试 PASS

- [ ] **Step 4: 更新 CHANGELOG.md**

在 CHANGELOG 顶部添加：

```markdown
### 2026-06-05

- **feat(iOS): Daily Sense 状态卡片重设计** — 时间线圆点布局，收起态彩色圆点概览各维度状态，展开态显示信号详情
  - 状态标题改为节奏视角：「节奏不错」/「节奏有点乱」/「节奏在找回」
  - 消费信号改为实际金额对比，阈值提升至 3x+¥100
  - 健康信号启用：睡眠 & 步数参与每日状态判断
  - 模型 v2 升级：结构化 DailySenseSignal 替代 reasons 字符串数组
```

- [ ] **Step 5: 提交**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryView.swift" "CHANGELOG.md"
git commit -m "feat(iOS): Daily Sense 卡片集成完成 + CHANGELOG 更新"
```
