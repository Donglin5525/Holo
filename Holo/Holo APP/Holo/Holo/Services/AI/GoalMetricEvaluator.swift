//
//  GoalMetricEvaluator.swift
//  Holo
//
//  量化目标进度与预测评估（与 GoalProgressEvaluator 并列：
//  过程型走六档状态，量化型走「类型 × 数据源」矩阵的大数字口径）
//
//  单一事实来源原则：Goal 不存 currentValue，进度每次展示时从源实时计算。
//

import Foundation
import CoreData

struct GoalHealthSample: Equatable, Sendable {
    let value: Double
    let date: Date?
    var coveredNights: Int? = nil

    var hasEnoughData: Bool { coveredNights.map { $0 == 7 } ?? true }
}

@MainActor
final class GoalHealthKitCache {
    static let shared = GoalHealthKitCache()

    struct Reading: Equatable {
        let current: HoloHealthQueryOutcome<GoalHealthSample>
        let baseline: GoalHealthSample?
    }

    private struct Key: Equatable {
        let kind: GoalHealthMetricKind
        let since: Date
    }

    private struct Entry {
        let key: Key
        let cutoff: Date
        let reading: Reading
    }

    private var entries: [UUID: Entry] = [:]
    private var inFlight: [UUID: (key: Key, token: UUID)] = [:]
    #if DEBUG
    private var simulated: [UUID: Double] = [:]

    func setValue(_ value: Double?, for goalID: UUID) {
        simulated[goalID] = value
    }
    #endif

    func reading(for goal: Goal, kind: GoalHealthMetricKind, cutoff: Date) -> Reading? {
        #if DEBUG
        if let value = simulated[goal.id] {
            return Reading(current: .value(GoalHealthSample(value: value, date: nil)),
                           baseline: goal.baselineValueDouble.map { GoalHealthSample(value: $0, date: nil) })
        }
        #endif
        let key = Key(kind: kind, since: goal.baselineDate ?? goal.createdAt)
        guard let entry = entries[goal.id], entry.key == key, entry.cutoff <= cutoff else { return nil }
        return entry.reading
    }

    func refreshIfNeeded(for goal: Goal, force: Bool = false) async {
        guard goal.isRenderable, goal.metricSourceEnum == .healthKit,
              let kind = goal.healthMetricKindEnum else { return }
        let id = goal.id
        let key = Key(kind: kind, since: goal.baselineDate ?? goal.createdAt)
        let cutoff = Date()
        guard inFlight[id]?.key != key else { return }
        if !force, let entry = entries[id], entry.key == key, cutoff.timeIntervalSince(entry.cutoff) < 30 { return }

        let token = UUID()
        inFlight[id] = (key, token)
        let repository = HealthRepository.shared
        async let current = repository.fetchGoalMetric(kind: kind, since: key.since, before: cutoff)
        async let baseline = Self.readBaseline(kind: kind, since: key.since, cutoff: cutoff, in: repository)
        let reading = await Reading(current: current, baseline: baseline)
        guard inFlight[id]?.token == token else { return }
        inFlight[id] = nil
        guard goal.isRenderable, goal.metricSourceEnum == .healthKit, goal.healthMetricKindEnum == kind,
              (goal.baselineDate ?? goal.createdAt) == key.since else { return }
        let previous = entries.updateValue(Entry(key: key, cutoff: cutoff, reading: reading), forKey: id)
        if previous?.key != key || previous?.reading != reading {
            GoalNotificationService.broadcastGoalDataChange()
        }
    }

    private static func readBaseline(kind: GoalHealthMetricKind, since start: Date, cutoff: Date,
                                     in repository: HealthRepository) async -> GoalHealthSample? {
        guard kind == .bodyMass || kind == .bodyFatPercentage else { return nil }
        let startingPoint = await repository.fetchGoalMetric(kind: kind, since: start, before: start)
        switch startingPoint {
        case .value(let sample): return sample
        case .noData:
            if case .value(let first) = await repository.fetchGoalMetric(kind: kind, since: start, before: cutoff, firstSample: true) {
                return first
            }
        case .waitingForUnlock, .unavailable: break
        }
        return nil
    }
}

/// 量化目标进度快照
struct GoalMetricProgress: Equatable {
    /// 累积型=当前累计值；达标型=最新记录值（无记录时=基线）
    let currentValue: Double
    /// 0~1。累积型=累计÷目标；达标型=|基线−当前|÷|基线−目标|（基线视角，不从 0 起）
    let progress: Double
    let isAchieved: Bool
    /// 进度 <10% 或速率不足时为 nil（低速段预测波动大，不输出避免误判打击用户）
    let forecast: GoalMetricForecast?
}

/// 预测结论：日均速率外推出的预计达成日 + 与截止日的比较
struct GoalMetricForecast: Equatable {
    let predictedDate: Date
    /// 有截止日期时才有结论：true=预计如期达成
    let meetsDeadline: Bool?
}

@MainActor
enum GoalMetricEvaluator {

    /// 入口：非量化目标或配置不完整返回 nil（调用方回落过程型展示）。
    /// habit 源习惯失效（被删/归档）同样返回 nil，由 isHabitSourceUnavailable 区分提示。
    static func evaluate(goal: Goal) -> GoalMetricProgress? {
        evaluate(goal: goal, finance: .shared)
    }

    /// 同一份观测供目标详情、卡片、回顾与小组件使用。
    static func evaluate(goal: Goal, finance: FinanceRepository) -> GoalMetricProgress? {
        guard goal.isQuantitative, let context = goal.managedObjectContext else { return nil }
        let configuration = GoalPlanResolver.resultConfiguration(goal: goal, in: context)
        guard let source = configuration.source else { return nil }
        let builder = GoalEvaluationSnapshotBuilder(
            context: context, financeRepository: finance, budgetRepository: .shared, habitRepository: .shared
        )
        let result = builder.resultObservation(goal: goal, source: source, reviewDays: configuration.reviewDays, now: Date())
        return progress(for: result, goal: goal)
    }

    static func progress(for observation: GoalResultObservation, goal: Goal) -> GoalMetricProgress? {
        guard observation.status == .observed,
              let current = observation.value ?? observation.moneyValue.map({ NSDecimalNumber(decimal: $0).doubleValue }),
              let target = observation.targetValue, let achieved = observation.isAchieved,
              let fraction = observation.progressFraction ?? (achieved ? 1 : nil) else { return nil }
        let total: Double
        if let baseline = observation.baselineValue, observation.comparison == .trendDown || observation.comparison == .trendUp {
            total = abs(target - baseline)
        } else {
            total = target
        }
        return GoalMetricProgress(
            currentValue: current,
            progress: fraction,
            isAchieved: achieved,
            forecast: makeForecast(goal: goal, moved: fraction * total, total: total,
                                   elapsedAnchor: goal.baselineDate ?? goal.createdAt, achieved: achieved, progress: fraction)
        )
    }

    /// 原始习惯被归档或删除时，保持引用，等用户主动重选。
    static func sourceHabit(for goal: Goal) -> Habit? {
        guard goal.metricSourceEnum == .habit, let habitId = goal.sourceHabitId,
              let habit = HabitRepository.shared.findHabit(by: habitId), !habit.isArchived else { return nil }
        return habit
    }

    static func isHabitSourceUnavailable(goal: Goal) -> Bool {
        goal.isQuantitative && goal.metricSourceEnum == .habit && sourceHabit(for: goal) == nil
    }

    /// 预测：日均速率外推预计达成日，与 deadline 比较出结论。
    /// 已达成、进度 <10%、速率为 0 时不输出。
    private static func makeForecast(
        goal: Goal,
        moved: Double,
        total: Double,
        elapsedAnchor: Date,
        achieved: Bool,
        progress: Double
    ) -> GoalMetricForecast? {
        guard !achieved, progress >= 0.1 else { return nil }
        let elapsedDays = max(1.0, Date().timeIntervalSince(elapsedAnchor) / 86400)
        let dailyRate = moved / elapsedDays
        guard dailyRate > 0 else { return nil }
        let remainingDays = (total - moved) / dailyRate
        let predictedDate = Date().addingTimeInterval(remainingDays * 86400)
        return GoalMetricForecast(
            predictedDate: predictedDate,
            meetsDeadline: goal.deadline.map { predictedDate <= $0 }
        )
    }

    // MARK: - 展示格式化

    /// 数值展示：整数不带小数点，小数保留一位（与 Habit.formatValue 同口径）
    static func formatValue(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    /// 日期展示（如「11月2日」，预测与记录行共用）
    static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
