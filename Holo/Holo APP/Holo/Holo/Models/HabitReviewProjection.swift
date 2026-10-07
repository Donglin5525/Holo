//
//  HabitReviewProjection.swift
//  Holo
//
//  V2 回顾只读投影（2026-10-07 方案 §6/§7/§10）：
//  时间范围统一半开区间、HabitReviewDay（「有记录」与「表现」分字段）、
//  单习惯范围快照与整体月度摘要。纯函数 + 值快照输入，不做任何 fetch，
//  不重定义旧 HabitStatsDayCell.hasRecord 语义。
//

import Foundation

// MARK: - 时间范围

/// 单习惯回顾的时间范围。整体回顾固定月份；单习惯页继承后可切换。
/// 区间统一半开 [start, end)；名义上含「今天」的范围 end 钳到明天零点
/// （今天尚未结束，截止当前时刻由投影底座的 now 过滤兜底）。
enum HabitReviewRange: Equatable {
    /// 某自然月（入参为该月第一天）
    case month(Date)
    /// 最近 N 天（含今天）
    case lastDays(Int)
    /// 全部记录（调用方负责以习惯创建日为界）
    case all
    /// 自定义范围（start/end 均为自然日，end 含当天）
    case custom(start: Date, end: Date)

    /// 半开区间 [start, end)，end 不超过明天零点。
    func dateInterval(now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let start: Date
        let nominalEnd: Date
        switch self {
        case .month(let monthStart):
            start = calendar.startOfDay(for: monthStart)
            nominalEnd = calendar.date(byAdding: .month, value: 1, to: start) ?? tomorrow
        case .lastDays(let days):
            start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
            nominalEnd = tomorrow
        case .all:
            start = calendar.startOfDay(for: .distantPast)
            nominalEnd = tomorrow
        case .custom(let s, let e):
            let sDay = calendar.startOfDay(for: s)
            let eNext = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: e))
                ?? tomorrow
            start = sDay
            nominalEnd = max(eNext, calendar.date(byAdding: .day, value: 1, to: sDay) ?? tomorrow)
        }
        return DateInterval(start: start, end: min(nominalEnd, tomorrow))
    }

    /// 范围标题（与内容同步变化；HTML range 标签同款语义）
    func label(now: Date, calendar: Calendar) -> String {
        let interval = dateInterval(now: now, calendar: calendar)
        switch self {
        case .month(let monthStart):
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.setLocalizedDateFormatFromTemplate("yyyy年M月")
            return formatter.string(from: monthStart)
        case .lastDays(let days):
            return String(localized: "最近 \(days) 天")
        case .all:
            return String(localized: "全部记录")
        case .custom:
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.setLocalizedDateFormatFromTemplate("M月d日")
            return "\(formatter.string(from: interval.start)) — \(formatter.string(from: calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end))"
        }
    }
}

// MARK: - 习惯值快照

/// 回顾投影的习惯入参（值快照；不持有 NSManagedObject，测试可直构）
struct HabitReviewHabitInfo: Identifiable, Equatable {
    let id: UUID
    let name: String
    let icon: String
    let isCustomIcon: Bool
    let colorHex: String
    let kind: HabitRowKind
    let frequency: HabitFrequency
    let isBadHabit: Bool
    let lifecycle: HabitLifecycle
    let createdAt: Date
    let unit: String
    let pauseWindows: [HabitPauseWindow]

    init(habit: Habit, lifecycle: HabitLifecycle) {
        self.id = habit.id
        self.name = habit.name
        self.icon = habit.icon
        self.isCustomIcon = habit.isCustomIcon
        self.colorHex = habit.color
        self.kind = habit.isCheckInType ? .checkIn : (habit.isCountType ? .count : .measure)
        self.frequency = habit.habitFrequency
        self.isBadHabit = habit.isBadHabit
        self.lifecycle = lifecycle
        self.createdAt = habit.createdAt
        self.unit = habit.unit ?? ""
        self.pauseWindows = habit.pauseWindows
    }

    init(id: UUID, name: String = "习惯", icon: String = "leaf", isCustomIcon: Bool = false,
         colorHex: String = "#987444", kind: HabitRowKind, frequency: HabitFrequency = .daily,
         isBadHabit: Bool = false, lifecycle: HabitLifecycle = .active,
         createdAt: Date = .distantPast, unit: String = "", pauseWindows: [HabitPauseWindow] = []) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isCustomIcon = isCustomIcon
        self.colorHex = colorHex
        self.kind = kind
        self.frequency = frequency
        self.isBadHabit = isBadHabit
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.unit = unit
        self.pauseWindows = pauseWindows
    }

    var isNumeric: Bool { kind != .checkIn }
}

// MARK: - 单日

/// 回顾日历格 / 日期明细的单日语义（§10）：
/// isRecorded 只回答「有没有留下有效记录」，不掺表现达标。
struct HabitReviewDay: Equatable, Identifiable {
    let day: Date
    let isRecorded: Bool
    /// 数值型当日聚合（计数 SUM / 测量 LATEST；真实 0 有效）；打卡型 nil
    let dailyValue: Double?
    let isPaused: Bool
    let isRetroactive: Bool
    let isBeforeCreation: Bool
    let isFuture: Bool

    var id: Date { day }
}

// MARK: - 单习惯范围快照

/// 单习惯在指定范围的完整事实（摘要、图表、任意日明细共用同一来源）。
struct HabitRangeSnapshot: Equatable {
    let info: HabitReviewHabitInfo
    let range: HabitReviewRange
    /// 实际生效半开区间
    let interval: DateInterval
    /// 范围内全部有效记录（升序；当日明细用）
    let records: [HabitRecordFact]
    /// 有有效记录的不同日（好坏习惯均按「有记录」计，不看达标）
    let recordedDays: Set<Date>
    /// 数值日聚合（升序，只含有记录日；计数 SUM / 测量 LATEST）
    let dailyValues: [HabitDailyNumericValue]

    var recordedDayCount: Int { recordedDays.count }

    /// 半开归属判定（[start, end)）。DateInterval.contains 是闭区间语义（含 end），
    /// 界日（月末/明天零点）不得落入范围，必须手写比较（§10 日期窗口）。
    func containsDay(_ date: Date, calendar: Calendar) -> Bool {
        let dayStart = calendar.startOfDay(for: date)
        return dayStart >= interval.start && dayStart < interval.end
    }

    /// 计数范围总量（真实逐日聚合之和）；非计数 nil
    var countTotal: Double? {
        guard info.kind == .count else { return nil }
        return dailyValues.reduce(0.0) { $0 + $1.value }
    }

    /// 测量范围内最近值（及所在日）；非测量或无记录 nil
    var latestMeasure: (value: Double, day: Date)? {
        guard info.kind == .measure, let last = dailyValues.last else { return nil }
        return (last.value, last.date)
    }

    /// 任意一天的单日投影（历史日不靠今天行 trail 推断，§A18）
    /// today 由调用方传入（可测；视图传当前时刻）
    func day(_ date: Date, today: Date, calendar: Calendar) -> HabitReviewDay {
        let dayStart = calendar.startOfDay(for: date)
        let dayFacts = records.filter {
            calendar.startOfDay(for: $0.date) == dayStart
        }
        let recorded: Bool
        if info.kind == .checkIn {
            recorded = dayFacts.contains { $0.isCompleted }
        } else {
            recorded = dayFacts.contains { $0.finiteValue != nil }
        }
        let dailyValue: Double?
        if info.isNumeric, !dayFacts.isEmpty {
            let values = dayFacts.compactMap(\.finiteValue)
            if info.kind == .count {
                dailyValue = values.isEmpty ? nil : values.reduce(0, +)
            } else {
                dailyValue = dayFacts.filter { $0.finiteValue != nil }
                    .sorted { $0.date < $1.date }.last?.finiteValue
            }
        } else {
            dailyValue = nil
        }
        let todayStart = calendar.startOfDay(for: today)
        return HabitReviewDay(
            day: dayStart,
            isRecorded: recorded,
            dailyValue: dailyValue,
            isPaused: HabitProjectionData.isPausedDay(info.pauseWindows, on: dayStart,
                                                     today: todayStart, calendar: calendar),
            isRetroactive: dayFacts.contains { $0.isRetroactive },
            isBeforeCreation: dayStart < calendar.startOfDay(for: info.createdAt),
            isFuture: dayStart > todayStart
        )
    }
}

// MARK: - 整体月度快照

/// 回顾首页一行（整体结果列表；不内嵌图表）
struct HabitReviewRowSnapshot: Identifiable, Equatable, HabitIconRenderable {
    let id: UUID
    let name: String
    let icon: String
    let isCustomIcon: Bool
    let colorHex: String
    let kind: HabitRowKind
    let isBadHabit: Bool
    let lifecycle: HabitLifecycle
    /// 当月是否有有效记录（false = 活跃习惯的「该月无记录」行）
    let hasRecords: Bool
    let recordedDayCount: Int
    let countTotal: Double?
    let latestMeasure: (value: Double, day: Date)?
    let unit: String

    /// 行结果文案（§6.1 示例口径）
    var resultText: String {
        guard hasRecords else { return String(localized: "该月无记录") }
        switch kind {
        case .checkIn:
            let verb = isBadHabit ? String(localized: "发生") : String(localized: "记录")
            return String(localized: "\(verb) \(recordedDayCount) 天")
        case .count:
            let total = HabitPresentationProjector.formatValue(countTotal ?? 0)
            if isBadHabit {
                return String(localized: "发生 \(recordedDayCount) 天 · 共 \(total) \(unit)")
            }
            return String(localized: "共 \(total) \(unit) · 记录 \(recordedDayCount) 天")
        case .measure:
            if let latest = latestMeasure {
                let value = HabitPresentationProjector.formatValue(latest.value)
                return String(localized: "最近 \(value) \(unit) · 记录 \(recordedDayCount) 天")
            }
            return String(localized: "记录 \(recordedDayCount) 天")
        }
    }

    static func == (lhs: HabitReviewRowSnapshot, rhs: HabitReviewRowSnapshot) -> Bool {
        lhs.id == rhs.id && lhs.hasRecords == rhs.hasRecords
            && lhs.recordedDayCount == rhs.recordedDayCount
            && lhs.countTotal == rhs.countTotal
            && lhs.latestMeasure?.value == rhs.latestMeasure?.value
            && lhs.latestMeasure?.day == rhs.latestMeasure?.day
    }
}

/// 整体月度摘要：两个覆盖指标 + 结果列表（§6.1）
struct HabitReviewOverviewSnapshot: Equatable {
    /// 当前选中的月起始
    let monthStart: Date
    /// 生效半开区间（本月截止明天零点；过去月整月）
    let interval: DateInterval
    let rows: [HabitReviewRowSnapshot]
    /// 可见集合在范围内有有效记录的不同日期数
    let activeRecordDays: Int
    /// 可见集合在范围内留下有效记录的不同习惯数
    let recordedHabitCount: Int
    /// 可见范围描述（nil=全部习惯；非 nil=已选 N 项）
    let visibleCount: Int?
}

// MARK: - 投影器

enum HabitReviewProjector {

    /// 单习惯范围快照
    static func rangeSnapshot(
        info: HabitReviewHabitInfo,
        range: HabitReviewRange,
        data: HabitProjectionData
    ) -> HabitRangeSnapshot {
        let interval = range.dateInterval(now: data.now, calendar: data.calendar)
        let facts = (data.recordsByHabit[info.id] ?? []).filter { interval.contains($0.date) }

        var recordedDays: Set<Date> = []
        if info.kind == .checkIn {
            for fact in facts where fact.isCompleted {
                recordedDays.insert(data.dayStart(fact.date))
            }
        } else {
            for fact in facts where fact.finiteValue != nil {
                recordedDays.insert(data.dayStart(fact.date))
            }
        }

        let dailyValues: [HabitDailyNumericValue]
        if info.isNumeric {
            dailyValues = HabitNumericAggregator.aggregateDaily(
                samples: facts.compactMap { fact in
                    fact.finiteValue.map { HabitNumericSample(date: fact.date, value: $0) }
                },
                isCountType: info.kind == .count
            )
        } else {
            dailyValues = []
        }

        return HabitRangeSnapshot(
            info: info,
            range: range,
            interval: interval,
            records: facts,
            recordedDays: recordedDays,
            dailyValues: dailyValues
        )
    }

    /// 整体月度快照（§6.2 集合规则）。
    /// - habits：全部未删除习惯（active + paused + archived）
    /// - visibleIds：nil=全部；[]=用户明确全关；非空=白名单
    /// - orderedIds：用户回顾排序；未覆盖项按输入顺序（主排序）兜底
    static func overviewSnapshot(
        habits: [HabitReviewHabitInfo],
        visibleIds: [UUID]?,
        orderedIds: [UUID],
        month monthStart: Date,
        data: HabitProjectionData
    ) -> HabitReviewOverviewSnapshot {
        let calendar = data.calendar
        let monthStartDay = calendar.startOfDay(for: monthStart)
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStartDay) else {
            return HabitReviewOverviewSnapshot(
                monthStart: monthStartDay,
                interval: DateInterval(start: monthStartDay, end: monthStartDay),
                rows: [], activeRecordDays: 0, recordedHabitCount: 0, visibleCount: nil)
        }

        // 可见集合：全关闭=[]（保留空态），白名单过滤，nil=全部
        let visibleHabits: [HabitReviewHabitInfo]
        switch visibleIds {
        case .none:
            visibleHabits = habits
        case .some(let ids):
            let idSet = Set(ids)
            visibleHabits = habits.filter { idSet.contains($0.id) }
        }

        // 范围内有效记录（不同习惯的记录只算可见集合内的）
        var recordedDates: Set<Date> = []
        var recordedHabitIds: Set<UUID> = []
        var perHabitDays: [UUID: Set<Date>] = [:]
        for info in visibleHabits {
            let facts = (data.recordsByHabit[info.id] ?? []).filter {
                $0.date >= monthStartDay && $0.date < nextMonth
            }
            var days: Set<Date> = []
            if info.kind == .checkIn {
                for fact in facts where fact.isCompleted {
                    days.insert(data.dayStart(fact.date))
                }
            } else {
                for fact in facts where fact.finiteValue != nil {
                    days.insert(data.dayStart(fact.date))
                }
            }
            perHabitDays[info.id] = days
            if !days.isEmpty {
                recordedHabitIds.insert(info.id)
                recordedDates.formUnion(days)
            }
        }

        // 列表集合规则（§6.2）：当月有记录 ∪ 活跃且创建不晚于月末
        let rowsInput = visibleHabits.filter { info in
            if !perHabitDays[info.id]!.isEmpty { return true }
            guard info.lifecycle == .active else { return false }
            return data.dayStart(info.createdAt) < nextMonth
        }

        // 排序：orderedHabitIds 覆盖优先，未覆盖项保持主排序跟随其后
        let orderIndex = { (id: UUID) -> Int in
            let idx = orderedIds.firstIndex(of: id)
            return idx ?? Int.max
        }
        let sorted = rowsInput.sorted { a, b in
            let ia = orderIndex(a.id), ib = orderIndex(b.id)
            if ia != ib { return ia < ib }
            return a.id.uuidString < b.id.uuidString
        }

        let rows: [HabitReviewRowSnapshot] = sorted.map { info in
            let days = perHabitDays[info.id] ?? []
            var countTotal: Double?
            var latest: (value: Double, day: Date)?
            if info.isNumeric {
                let snapshot = rangeSnapshot(info: info, range: .month(monthStartDay), data: data)
                countTotal = snapshot.countTotal
                latest = snapshot.latestMeasure
            }
            return HabitReviewRowSnapshot(
                id: info.id,
                name: info.name,
                icon: info.icon,
                isCustomIcon: info.isCustomIcon,
                colorHex: info.colorHex,
                kind: info.kind,
                isBadHabit: info.isBadHabit,
                lifecycle: info.lifecycle,
                hasRecords: !days.isEmpty,
                recordedDayCount: days.count,
                countTotal: countTotal,
                latestMeasure: latest,
                unit: info.unit
            )
        }

        return HabitReviewOverviewSnapshot(
            monthStart: monthStartDay,
            interval: DateInterval(start: monthStartDay, end: nextMonth),
            rows: rows,
            activeRecordDays: recordedDates.count,
            recordedHabitCount: recordedHabitIds.count,
            visibleCount: visibleIds.map(\.count)
        )
    }
}

// MARK: - HabitProjectionData 暂停判定（静态出口）

extension HabitProjectionData {
    /// 供 HabitRangeSnapshot.day 使用的静态暂停判定（与实例方法同语义）
    static func isPausedDay(
        _ windows: [HabitPauseWindow],
        on day: Date,
        today: Date,
        calendar: Calendar
    ) -> Bool {
        let target = calendar.startOfDay(for: day)
        return windows.contains { window in
            let start = calendar.startOfDay(for: window.startDate)
            guard target >= start else { return false }
            guard let end = window.endDate else { return target <= today }
            return target <= calendar.startOfDay(for: end)
        }
    }
}
