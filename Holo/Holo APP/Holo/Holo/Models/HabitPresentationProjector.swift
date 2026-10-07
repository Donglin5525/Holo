//
//  HabitPresentationProjector.swift
//  Holo
//
//  批量只读投影：把已去重的记录一次性聚合为行快照 / 单日快照。
//  数据获取固定批量执行（1 次全量记录字典查询），不随习惯数、格子数、
//  连续天数线性增加 fetch；纯界面 body 重算不触发任何 fetch。
//
//  连续口径：打卡型与 repository.calculateStreakInfo 完全同源（含部分冻结
//  折算，2026-10-06 84aacb01e 口径）；数值型为本轮新增只读投影（方案 §9.4），
//  不修改旧对外 streak 语义。
//

import Foundation

// MARK: - 轻量记录值

/// 投影用的记录值快照（不持有 NSManagedObject）
struct HabitRecordFact: Equatable {
    let id: UUID
    let habitId: UUID
    let date: Date
    let isCompleted: Bool
    let value: Double?
    let isRetroactive: Bool

    var finiteValue: Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

// MARK: - 投影数据底座

/// 一次批量取数后的内存聚合结果，跨页共享。
struct HabitProjectionData {
    /// habitId -> 记录值（按日期升序）
    let recordsByHabit: [UUID: [HabitRecordFact]]
    /// habitId -> 有完成打卡的不同日集合（打卡型连续与周期判定用）
    let completedDaysByHabit: [UUID: Set<Date>]
    /// habitId -> 逐日数值聚合（计数 SUM / 测量 LATEST，复用既有聚合真源；含真实 0）
    let dailyNumericByHabit: [UUID: [HabitDailyNumericValue]]
    /// habitId -> 暂停窗口（解码一次，判定复用）
    let pauseWindowsByHabit: [UUID: [HabitPauseWindow]]
    let now: Date
    let calendar: Calendar

    /// 指定日的 startOfDay
    func dayStart(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    /// 今天 0 点
    var today: Date { dayStart(now) }

    /// 某习惯某天是否冻结（语义与 Habit.isDayPaused 一致：开放窗口延伸至今天）
    func isDayPaused(_ windows: [HabitPauseWindow], on day: Date) -> Bool {
        let target = dayStart(day)
        let todayStart = today
        return windows.contains { window in
            let start = dayStart(window.startDate)
            guard target >= start else { return false }
            guard let end = window.endDate else { return target <= todayStart }
            return target <= dayStart(end)
        }
    }

    /// 该习惯某天的有效记录（按给定日界）
    func records(_ facts: [HabitRecordFact], on day: Date) -> [HabitRecordFact] {
        let start = dayStart(day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return facts.filter { $0.date >= start && $0.date < end }
    }
}

// MARK: - 投影器

enum HabitPresentationProjector {

    /// 从原始记录构建投影数据底座（一次调用、内存聚合）
    static func buildData(
        records: [HabitRecordFact],
        pauseWindowsByHabit: [UUID: [HabitPauseWindow]],
        now: Date,
        calendar: Calendar = .current
    ) -> HabitProjectionData {
        var grouped: [UUID: [HabitRecordFact]] = [:]
        for fact in records where fact.date <= now {
            grouped[fact.habitId, default: []].append(fact)
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.date < $1.date }
        }

        var completedDays: [UUID: Set<Date>] = [:]
        var dailyNumeric: [UUID: [HabitDailyNumericValue]] = [:]
        for (habitId, facts) in grouped {
            var days: Set<Date> = []
            for fact in facts where fact.isCompleted {
                days.insert(calendar.startOfDay(for: fact.date))
            }
            completedDays[habitId] = days

            // 数值日聚合复用既有聚合真源（保留真实 0，过滤 nil/NaN/无穷）
            let numericFacts = facts.filter { $0.value != nil }
            dailyNumeric[habitId] = HabitNumericAggregator.aggregateDaily(
                samples: numericFacts.map { HabitNumericSample(date: $0.date, value: $0.value) },
                isCountType: true
            )
        }

        return HabitProjectionData(
            recordsByHabit: grouped,
            completedDaysByHabit: completedDays,
            dailyNumericByHabit: dailyNumeric,
            pauseWindowsByHabit: pauseWindowsByHabit,
            now: now,
            calendar: calendar
        )
    }

    /// 滚动七天（今天-6 … 今天，升序）。截至今天，不含未来。
    static func rollingSevenDays(_ data: HabitProjectionData) -> [Date] {
        (0..<7).compactMap { data.calendar.date(byAdding: .day, value: $0 - 6, to: data.today) }
    }

    /// 滚动三十天（今天-29 … 今天，升序）。截至今天，不含未来。行内缝线痕迹用（B 方案）。
    static func rollingThirtyDays(_ data: HabitProjectionData) -> [Date] {
        (0..<30).compactMap { data.calendar.date(byAdding: .day, value: $0 - 29, to: data.today) }
    }

    // MARK: 行快照

    static func rowSnapshot(
        habit: Habit,
        lifecycle: HabitLifecycle,
        data: HabitProjectionData
    ) -> HabitRowSnapshot {
        let facts = data.recordsByHabit[habit.id] ?? []
        let windows = data.pauseWindowsByHabit[habit.id] ?? []

        let isCheckIn = habit.isCheckInType
        let kind: HabitRowKind = isCheckIn ? .checkIn : (habit.isCountType ? .count : .measure)

        // 今日状态
        let todayFacts = data.records(facts, on: data.today)
        let isCheckInDone = isCheckIn && todayFacts.contains { $0.isCompleted }
        let isRecorded: Bool
        if isCheckIn {
            isRecorded = isCheckInDone
        } else {
            isRecorded = todayFacts.contains { $0.finiteValue != nil }
        }

        // 目标与周期
        let target = targetSummary(for: habit)
        let isTargetMet = isTargetMet(habit: habit, target: target, isBadHabit: habit.isBadHabit, data: data)
        let numericToday = habit.isNumericType ? dailyAggregate(habit: habit, facts: todayFacts, data: data) : nil
        let periodInfo = periodProgressText(for: habit, target: target, facts: facts, data: data)

        // 坏习惯超限（当日聚合 > 控制上限；与日快照 isOverLimit 同口径）
        var isOverLimit = false
        if habit.isBadHabit, let limit = target?.value, let value = numericToday {
            isOverLimit = value > limit
        }

        let today = HabitTodayProgress(
            isCheckInDone: isCheckInDone,
            isRecorded: isRecorded,
            isTargetMet: isTargetMet,
            todayValue: numericToday,
            periodValueText: periodInfo.text,
            periodRangeText: periodInfo.rangeText,
            isOverLimit: isOverLimit
        )

        // 连续积累
        let streak = streakLabel(for: habit, data: data)

        // 三十天缝线痕迹（B 方案）：记录/补录/暂停/创建前空位，今天带指针
        let creationDay = data.dayStart(habit.createdAt)
        let trail = rollingThirtyDays(data).map { day -> HabitTrailDay in
            let dayFacts = data.records(facts, on: day)
            let recorded: Bool
            if isCheckIn {
                recorded = dayFacts.contains { $0.isCompleted }
            } else {
                recorded = dayFacts.contains { $0.finiteValue != nil }
            }
            return HabitTrailDay(
                day: day,
                isRecorded: recorded,
                isRetroactive: dayFacts.contains { $0.isRetroactive },
                isPaused: data.isDayPaused(windows, on: day),
                isToday: day == data.today,
                isBeforeCreation: day < creationDay
            )
        }

        // 暂停说明
        let pauseText: String? = {
            guard lifecycle == .paused else { return nil }
            if let until = habit.pausedUntil {
                let text = Self.dateText(until, data: data)
                return String(localized: "暂停至 \(text)")
            }
            return String(localized: "无限期暂停")
        }()

        return HabitRowSnapshot(
            id: habit.id,
            name: habit.name,
            icon: habit.icon,
            isCustomIcon: habit.isCustomIcon,
            colorHex: habit.color,
            kind: kind,
            frequency: habit.habitFrequency,
            isBadHabit: habit.isBadHabit,
            lifecycle: lifecycle,
            pauseSummaryText: pauseText,
            target: target,
            today: today,
            streak: streak,
            trail: trail,
            allowsTodayRecord: lifecycle == .active
        )
    }

    // MARK: 目标摘要

    static func targetSummary(for habit: Habit) -> HabitTargetSummary? {
        if habit.isCheckInType {
            guard let count = habit.targetCountValue else { return nil }
            return HabitTargetSummary(count: max(count, 1), value: nil, unit: nil, isControlTarget: habit.isBadHabit)
        }
        // 数值型：targetValue 优先，历史数值习惯 targetCount 兜底兼容（方案 §9.2）
        let value = habit.targetValueDouble ?? habit.targetCountValue.map(Double.init)
        guard let value else { return nil }
        return HabitTargetSummary(
            count: nil,
            value: value,
            unit: habit.unit,
            isControlTarget: habit.isBadHabit
        )
    }

    // MARK: 周期进展文本

    /// 返回（进展文本, 周期范围文本）。daily 用「今天 x」；weekly/monthly 用「本周/本月 x」。
    private static func periodProgressText(
        for habit: Habit,
        target: HabitTargetSummary?,
        facts: [HabitRecordFact],
        data: HabitProjectionData
    ) -> (text: String?, rangeText: String?) {
        let calendar = data.calendar
        let unit = habit.unitText

        switch habit.habitFrequency {
        case .daily:
            if habit.isCheckInType { return (nil, nil) }
            let todayFacts = data.records(facts, on: data.today)
            let value = dailyAggregate(habit: habit, facts: todayFacts, data: data)
            guard let value else { return (nil, nil) }
            let valueText = formatValue(value)
            if let target {
                if habit.isMeasureType {
                    // 测量目标是参考值，不做 x / y 进展（方案 §8.2）
                    return (String(localized: "今天 \(valueText) \(unit)"), nil)
                }
                let targetText = formatValue(target.value ?? 0)
                return (String(localized: "今天 \(valueText) / \(targetText) \(unit)"), nil)
            }
            return (String(localized: "今天 \(valueText) \(unit)"), nil)

        case .weekly:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: data.now) else { return (nil, nil) }
            return periodText(habit: habit, target: target, facts: facts,
                              in: interval, unitName: String(localized: "本周"), data: data)

        case .monthly:
            guard let interval = calendar.dateInterval(of: .month, for: data.now) else { return (nil, nil) }
            return periodText(habit: habit, target: target, facts: facts,
                              in: interval, unitName: String(localized: "本月"), data: data)
        }
    }

    private static func periodText(
        habit: Habit,
        target: HabitTargetSummary?,
        facts: [HabitRecordFact],
        in interval: DateInterval,
        unitName: String,
        data: HabitProjectionData
    ) -> (text: String?, rangeText: String?) {
        let periodFacts = facts.filter { $0.date >= interval.start && $0.date < interval.end }
        let rangeText = periodRangeText(interval, data: data)

        if habit.isCheckInType {
            let days = distinctDays(periodFacts.filter(\.isCompleted), data: data).count
            if let target, let count = target.count {
                return (String(localized: "\(unitName) \(days) / \(count) 次"), rangeText)
            }
            return (String(localized: "\(unitName)已记录 \(days) 天"), rangeText)
        }

        let value = periodNumericValue(habit: habit, facts: periodFacts, data: data)
        guard let value else { return (nil, rangeText) }
        let unit = habit.unitText
        let valueText = formatValue(value)
        if let target, let targetValue = target.value, !habit.isMeasureType {
            let targetText = formatValue(targetValue)
            return (String(localized: "\(unitName) \(valueText) / \(targetText) \(unit)"), rangeText)
        }
        return (String(localized: "\(unitName) \(valueText) \(unit)"), rangeText)
    }

    private static func periodRangeText(_ interval: DateInterval, data: HabitProjectionData) -> String? {
        let endDay = data.calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        return "\(shortDateText(interval.start, data: data)) – \(shortDateText(endDay, data: data))"
    }

    // MARK: 达标判定（当前周期）

    /// 当前周期是否达标。坏习惯恒 false（表现由控制/超标表达，不叫达标）。
    static func isTargetMet(
        habit: Habit,
        target: HabitTargetSummary?,
        isBadHabit: Bool,
        data: HabitProjectionData
    ) -> Bool {
        guard !isBadHabit, let target else { return false }
        let calendar = data.calendar

        switch habit.habitFrequency {
        case .daily:
            if habit.isCheckInType {
                let facts = data.recordsByHabit[habit.id] ?? []
                return data.records(facts, on: data.today).contains { $0.isCompleted }
            }
            guard let targetValue = target.value else { return false }
            let daily = data.dailyNumericByHabit[habit.id] ?? []
            let todayValue = daily.last { $0.date == data.today }?.value
            if habit.isMeasureType { return false } // 测量参考目标不做自动达标
            return (todayValue ?? 0) >= targetValue

        case .weekly:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: data.now) else { return false }
            return periodTargetMet(habit: habit, target: target, in: interval, data: data)

        case .monthly:
            guard let interval = calendar.dateInterval(of: .month, for: data.now) else { return false }
            return periodTargetMet(habit: habit, target: target, in: interval, data: data)
        }
    }

    private static func periodTargetMet(
        habit: Habit,
        target: HabitTargetSummary,
        in interval: DateInterval,
        data: HabitProjectionData
    ) -> Bool {
        let facts = (data.recordsByHabit[habit.id] ?? []).filter { $0.date >= interval.start && $0.date < interval.end }
        if habit.isCheckInType {
            guard let count = target.count else { return false }
            return distinctDays(facts.filter(\.isCompleted), data: data).count >= count
        }
        guard let targetValue = target.value, !habit.isMeasureType else { return false }
        let value = periodNumericValue(habit: habit, facts: facts, data: data) ?? 0
        return value >= targetValue
    }

    // MARK: 连续积累

    /// 打卡型 / 数值型统一入口。数值坏习惯不出连续（方案 §9.4：避免伪造）。
    static func streakLabel(for habit: Habit, data: HabitProjectionData) -> HabitStreakLabel? {
        if habit.isBadHabit {
            if habit.isCheckInType {
                // 坏习惯打卡：沿用既有「连续控制住」口径
                let days = checkInControlStreak(habit: habit, data: data)
                return HabitStreakLabel(value: days, unitName: String(localized: "天"),
                                        kindName: String(localized: "连续控制"))
            }
            return nil
        }

        if habit.isCheckInType {
            return checkInStreakLabel(habit: habit, data: data)
        }
        return numericStreakLabel(habit: habit, data: data)
    }

    /// 打卡型连续（与 repository.calculateStreakInfo 同口径）
    static func checkInStreakLabel(habit: Habit, data: HabitProjectionData) -> HabitStreakLabel {
        let frequency = habit.habitFrequency
        let target = max(habit.targetCountValue ?? 1, 1)
        let completedDays = data.completedDaysByHabit[habit.id] ?? []
        let windows = data.pauseWindowsByHabit[habit.id] ?? []
        let creationDay = data.dayStart(habit.createdAt)
        // 有目标→连续达标；无目标→连续记录（方案 §9.4）
        let dailyKindName = habit.targetCountValue == nil
            ? String(localized: "连续记录")
            : String(localized: "连续达标")

        switch frequency {
        case .daily:
            let days = dailyCompletionStreak(
                completedDays: completedDays, isBadHabit: false,
                windows: windows, creationDay: creationDay, data: data)
            return HabitStreakLabel(value: days, unitName: String(localized: "天"),
                                    kindName: dailyKindName)

        case .weekly:
            let weeks = periodicCompletionStreak(
                habit: habit, target: target, completedDays: completedDays,
                windows: windows, creationDay: creationDay,
                component: .weekOfYear, partialFrozenProrates: true, data: data)
            return HabitStreakLabel(value: weeks, unitName: String(localized: "周"),
                                    kindName: String(localized: "连续达标"))

        case .monthly:
            let months = periodicCompletionStreak(
                habit: habit, target: target, completedDays: completedDays,
                windows: windows, creationDay: creationDay,
                component: .month, partialFrozenProrates: true, data: data)
            return HabitStreakLabel(value: months, unitName: String(localized: "月"),
                                    kindName: String(localized: "连续达标"))
        }
    }

    /// 坏习惯打卡「连续控制住」：与 repository.calculateStreak 坏习惯分支同口径
    static func checkInControlStreak(habit: Habit, data: HabitProjectionData) -> Int {
        let completedDays = data.completedDaysByHabit[habit.id] ?? []
        return dailyCompletionStreak(
            completedDays: completedDays, isBadHabit: true,
            windows: data.pauseWindowsByHabit[habit.id] ?? [],
            creationDay: data.dayStart(habit.createdAt), data: data)
    }

    /// daily 逐日倒查（好习惯 = 连续完成天数；坏习惯 = 连续无记录控制天数）
    private static func dailyCompletionStreak(
        completedDays: Set<Date>,
        isBadHabit: Bool,
        windows: [HabitPauseWindow],
        creationDay: Date,
        data: HabitProjectionData
    ) -> Int {
        let calendar = data.calendar
        var checkDate = data.today
        let todayHasCompletion = completedDays.contains(data.today)

        if isBadHabit {
            if todayHasCompletion {
                guard let yesterday = calendar.date(byAdding: .day, value: -1, to: checkDate) else { return 0 }
                checkDate = yesterday
            }
        } else if !todayHasCompletion {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: checkDate) else { return 0 }
            checkDate = yesterday
        }

        var streak = 0
        let maxLookback = 3650
        for _ in 0..<maxLookback {
            let day = checkDate
            guard day >= creationDay else { break }

            let hasCompletion = completedDays.contains(day)
            if isBadHabit {
                if hasCompletion { break }
                if data.isDayPaused(windows, on: day) {
                    // 冻结日：不算克制、不计数，继续向前
                } else {
                    streak += 1
                }
            } else {
                if hasCompletion {
                    streak += 1
                } else if data.isDayPaused(windows, on: day) {
                    // 冻结日：不算断、不计数，继续向前
                } else {
                    break
                }
            }

            guard let previous = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = previous
        }
        return streak
    }

    /// 周/月打卡连续（与 repository.calculatePeriodicStreak 同口径，含部分冻结折算）
    private static func periodicCompletionStreak(
        habit: Habit,
        target: Int,
        completedDays: Set<Date>,
        windows: [HabitPauseWindow],
        creationDay: Date,
        component: Calendar.Component,
        partialFrozenProrates: Bool,
        data: HabitProjectionData
    ) -> Int {
        let calendar = data.calendar
        guard let currentStart = periodStart(for: data.now, component: component, calendar: calendar) else { return 0 }

        let currentDays = completedDaysIn(completedDays, from: currentStart, component: component, calendar: calendar)
        var checkStart: Date
        if currentDays >= target {
            checkStart = currentStart
        } else {
            guard let prev = previousPeriod(currentStart, component: component, calendar: calendar) else { return 0 }
            checkStart = prev
        }

        var streak = 0
        let maxLookback = component == .weekOfYear ? 520 : 120

        for _ in 0..<maxLookback {
            guard let periodEnd = nextPeriod(checkStart, component: component, calendar: calendar) else { break }
            guard periodEnd > creationDay else { break }

            if isPeriodFullyPaused(windows, from: checkStart, to: periodEnd, data: data) {
                checkStart = previousPeriod(checkStart, component: component, calendar: calendar) ?? checkStart
                continue
            }

            let effectiveTarget: Int
            if partialFrozenProrates {
                let frozenDays = pausedDayCount(windows, from: checkStart, to: periodEnd, data: data)
                if frozenDays > 0 {
                    let periodDays = calendar.dateComponents([.day], from: checkStart, to: periodEnd).day ?? 0
                    if periodDays > 0 {
                        effectiveTarget = max(1, Int((Double(target) * Double(periodDays - frozenDays) / Double(periodDays)).rounded(.up)))
                    } else {
                        effectiveTarget = target
                    }
                } else {
                    effectiveTarget = target
                }
            } else {
                effectiveTarget = target
            }

            let count = completedDaysIn(completedDays, from: checkStart, component: component, calendar: calendar)
            guard count >= effectiveTarget else { break }

            streak += 1
            guard let prev = previousPeriod(checkStart, component: component, calendar: calendar) else { break }
            checkStart = prev
        }
        return streak
    }

    /// 数值型连续（新只读投影，方案 §9.4）
    /// - daily：连续有有效数值的不同日（真实 0 有效；冻结空日跳过不断）
    /// - weekly/monthly 有目标计数：按周期 SUM 达标 →「连续达标 N 周/月」
    /// - weekly/monthly 无目标 / 测量：周期至少一次有效记录 →「连续记录 N 周/月」
    /// - 当前未达成周期不立即截断（从上一完整周期起算）；完整冻结周期跳过；
    ///   部分冻结周期不折算数值目标（满额判定）。
    static func numericStreakLabel(habit: Habit, data: HabitProjectionData) -> HabitStreakLabel? {
        let daily = data.dailyNumericByHabit[habit.id] ?? []
        let windows = data.pauseWindowsByHabit[habit.id] ?? []
        let creationDay = data.dayStart(habit.createdAt)
        let calendar = data.calendar
        let target = targetSummary(for: habit)

        switch habit.habitFrequency {
        case .daily:
            var recordedDays: Set<Date> = []
            for entry in daily where entry.value.isFinite {
                recordedDays.insert(entry.date)
            }
            var checkDate = data.today
            if !recordedDays.contains(data.today) {
                guard let yesterday = calendar.date(byAdding: .day, value: -1, to: checkDate) else { return nil }
                checkDate = yesterday
            }
            var streak = 0
            for _ in 0..<3650 {
                guard checkDate >= creationDay else { break }
                if recordedDays.contains(checkDate) {
                    streak += 1
                } else if data.isDayPaused(windows, on: checkDate) {
                    // 冻结空日：跳过且不断
                } else {
                    break
                }
                guard let prev = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
                checkDate = prev
            }
            return HabitStreakLabel(value: streak, unitName: String(localized: "天"),
                                    kindName: String(localized: "连续记录"))

        case .weekly, .monthly:
            let component: Calendar.Component = habit.habitFrequency == .weekly ? .weekOfYear : .month
            guard let currentStart = periodStart(for: data.now, component: component, calendar: calendar) else { return nil }

            let hasTarget = habit.isCountType, hasTargetValue = target?.value
            let kindName: String
            if habit.isMeasureType || hasTargetValue == nil {
                kindName = String(localized: "连续记录")
            } else {
                kindName = String(localized: "连续达标")
            }
            let targetValue = hasTargetValue

            var checkStart = currentStart
            var currentSatisfied = false
            if let tv = targetValue, !habit.isMeasureType {
                currentSatisfied = numericPeriodSatisfied(daily: daily, habit: habit, from: checkStart,
                                                          component: component, target: tv, data: data)
            } else {
                currentSatisfied = numericPeriodHasRecord(daily: daily, from: checkStart, component: component, data: data)
            }
            if !currentSatisfied {
                guard let prev = previousPeriod(checkStart, component: component, calendar: calendar) else { return nil }
                checkStart = prev
            }

            var streak = 0
            let maxLookback = component == .weekOfYear ? 520 : 120
            for _ in 0..<maxLookback {
                guard let periodEnd = nextPeriod(checkStart, component: component, calendar: calendar) else { break }
                guard periodEnd > creationDay else { break }
                if isPeriodFullyPaused(windows, from: checkStart, to: periodEnd, data: data) {
                    checkStart = previousPeriod(checkStart, component: component, calendar: calendar) ?? checkStart
                    continue
                }
                let satisfied: Bool
                if let tv = targetValue, !habit.isMeasureType {
                    // 部分冻结不折算数值目标：满额判定
                    satisfied = numericPeriodSatisfied(daily: daily, habit: habit, from: checkStart,
                                                       component: component, target: tv, data: data)
                } else {
                    satisfied = numericPeriodHasRecord(daily: daily, from: checkStart, component: component, data: data)
                }
                guard satisfied else { break }
                streak += 1
                guard let prev = previousPeriod(checkStart, component: component, calendar: calendar) else { break }
                checkStart = prev
            }

            let unitName = habit.habitFrequency == .weekly ? String(localized: "周") : String(localized: "月")
            return HabitStreakLabel(value: streak, unitName: unitName, kindName: kindName)
        }
    }

    /// 数值周期是否达标（周期内日值 SUM >= target）
    private static func numericPeriodSatisfied(
        daily: [HabitDailyNumericValue],
        habit: Habit,
        from periodStart: Date,
        component: Calendar.Component,
        target: Double,
        data: HabitProjectionData
    ) -> Bool {
        guard let periodEnd = nextPeriod(periodStart, component: component, calendar: data.calendar) else { return false }
        let sum = daily
            .filter { $0.date >= periodStart && $0.date < periodEnd }
            .reduce(0.0) { $0 + $1.value }
        return sum >= target
    }

    /// 数值周期是否至少一次有效记录
    private static func numericPeriodHasRecord(
        daily: [HabitDailyNumericValue],
        from periodStart: Date,
        component: Calendar.Component,
        data: HabitProjectionData
    ) -> Bool {
        guard let periodEnd = nextPeriod(periodStart, component: component, calendar: data.calendar) else { return false }
        return daily.contains { $0.date >= periodStart && $0.date < periodEnd && $0.value.isFinite }
    }

    // MARK: - 单日快照

    static func daySnapshot(
        habit: Habit,
        day: Date,
        data: HabitProjectionData
    ) -> HabitDaySnapshot {
        let facts = data.recordsByHabit[habit.id] ?? []
        let dayFacts = data.records(facts, on: day)
        let windows = data.pauseWindowsByHabit[habit.id] ?? []
        let dayStart = data.dayStart(day)

        let isCheckInDone = habit.isCheckInType && dayFacts.contains { $0.isCompleted }
        let isRecorded: Bool
        if habit.isCheckInType {
            isRecorded = isCheckInDone
        } else {
            isRecorded = dayFacts.contains { $0.finiteValue != nil }
        }

        var numericValue: Double?
        if habit.isNumericType {
            numericValue = dailyAggregate(habit: habit, facts: dayFacts, data: data)
        }

        var isOverLimit = false
        if habit.isBadHabit, let target = targetSummary(for: habit), let limit = target.value,
           let value = numericValue {
            isOverLimit = value > limit
        }

        return HabitDaySnapshot(
            habitId: habit.id,
            day: dayStart,
            isRecorded: isRecorded,
            isCheckInDone: isCheckInDone,
            isPausedDay: data.isDayPaused(windows, on: day),
            isBeforeCreation: dayStart < data.dayStart(habit.createdAt),
            isFuture: dayStart > data.today,
            hasRetroactive: dayFacts.contains { $0.isRetroactive },
            isOverLimit: isOverLimit,
            numericValue: numericValue,
            recordCount: dayFacts.count,
            allowedRetroactiveMode: nil
        )
    }

    // MARK: - 补录资格（方案 §10.1）

    /// 判定某天对某习惯的补录模式。返回 nil 表示不可补（原因见 daySnapshot 状态字段组合）。
    static func retroactiveMode(
        habit: Habit,
        day: Date,
        data: HabitProjectionData,
        lookbackDays: Int = HabitRetroactivePolicy.lookbackDays
    ) -> HabitRetroactiveMode? {
        guard !habit.isBadHabit else { return nil }
        guard habit.isCheckInType || habit.isNumericType else { return nil }
        let dayStart = data.dayStart(day)
        guard dayStart < data.today else { return nil }            // 今天/未来不可补
        guard dayStart >= data.dayStart(habit.createdAt) else { return nil } // 创建前不可补

        if habit.isCheckInType && habit.habitFrequency != .daily {
            return nil // 周/月打卡无「漏签」，也不开放补记（既有契约）
        }

        let facts = data.recordsByHabit[habit.id] ?? []
        let dayFacts = data.records(facts, on: day)
        if habit.isCheckInType {
            // 已完成日幂等，不需要补
            if dayFacts.contains(where: \.isCompleted) { return nil }
        } else {
            // 数值型补记允许追加（多次有效记录），窗口外历史走 fullHistory
        }

        guard let earliest = data.calendar.date(byAdding: .day, value: -(lookbackDays - 1), to: data.today) else { return nil }
        if dayStart >= earliest {
            // 补签窗口内：打卡漏签日或数值无记录日
            if habit.isNumericType {
                let hasRecord = dayFacts.contains { $0.finiteValue != nil }
                return hasRecord ? .backfill : .sign
            }
            return .sign
        }
        return .backfill
    }

    // MARK: - 工具

    private static func distinctDays(_ facts: [HabitRecordFact], data: HabitProjectionData) -> Set<Date> {
        Set(facts.map { data.dayStart($0.date) })
    }

    private static func completedDaysIn(
        _ completedDays: Set<Date>,
        from periodStart: Date,
        component: Calendar.Component,
        calendar: Calendar
    ) -> Int {
        guard let periodEnd = nextPeriod(periodStart, component: component, calendar: calendar) else { return 0 }
        return completedDays.filter { $0 >= periodStart && $0 < periodEnd }.count
    }

    private static func pausedDayCount(
        _ windows: [HabitPauseWindow],
        from periodStart: Date,
        to periodEnd: Date,
        data: HabitProjectionData
    ) -> Int {
        var count = 0
        var day = data.dayStart(periodStart)
        let lastDay = data.dayStart(data.calendar.date(byAdding: .day, value: -1, to: periodEnd) ?? periodStart)
        while day <= lastDay {
            if data.isDayPaused(windows, on: day) { count += 1 }
            guard let next = data.calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return count
    }

    private static func isPeriodFullyPaused(
        _ windows: [HabitPauseWindow],
        from periodStart: Date,
        to periodEnd: Date,
        data: HabitProjectionData
    ) -> Bool {
        var day = data.dayStart(periodStart)
        let end = data.dayStart(periodEnd)
        while day < end {
            if !data.isDayPaused(windows, on: day) { return false }
            guard let next = data.calendar.date(byAdding: .day, value: 1, to: day) else { return false }
            day = next
        }
        return true
    }

    static func periodStart(for date: Date, component: Calendar.Component, calendar: Calendar) -> Date? {
        if component == .weekOfYear {
            return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))
        }
        if component == .month {
            return calendar.date(from: calendar.dateComponents([.year, .month], from: date))
        }
        return calendar.startOfDay(for: date)
    }

    private static func nextPeriod(_ start: Date, component: Calendar.Component, calendar: Calendar) -> Date? {
        calendar.date(byAdding: component, value: 1, to: start)
    }

    private static func previousPeriod(_ start: Date, component: Calendar.Component, calendar: Calendar) -> Date? {
        calendar.date(byAdding: component, value: -1, to: start)
    }

    /// 当日数值聚合值（计数 SUM / 测量 LATEST，复用既有聚合器口径）
    static func dailyAggregate(habit: Habit, facts: [HabitRecordFact], data: HabitProjectionData) -> Double? {
        let values = facts.compactMap(\.finiteValue)
        guard !values.isEmpty else { return nil }
        if habit.isCountType {
            return values.reduce(0, +)
        }
        // 测量：当天最后一条有效值（与聚合器 max(by: date) 一致）
        let sorted = facts.filter { $0.finiteValue != nil }.sorted { $0.date < $1.date }
        return sorted.last?.finiteValue
    }

    /// 周期内数值（计数 SUM / 测量 LATEST-of-day 再取周期内最后一天）
    static func periodNumericValue(habit: Habit, facts: [HabitRecordFact], data: HabitProjectionData) -> Double? {
        let daily = HabitNumericAggregator.aggregateDaily(
            samples: facts.map { HabitNumericSample(date: $0.date, value: $0.value) },
            isCountType: habit.isCountType
        )
        if habit.isCountType {
            return daily.reduce(0.0) { $0 + $1.value }
        }
        return daily.last?.value
    }

    static func formatValue(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    static func dateText(_ date: Date, data: HabitProjectionData) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = data.calendar
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter.string(from: date)
    }

    static func shortDateText(_ date: Date, data: HabitProjectionData) -> String {
        dateText(date, data: data)
    }
}
