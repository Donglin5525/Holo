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
    /// 最近 N 个记录日的窗口（数值型默认视野）：不按固定时间长短取，
    /// 低频习惯（如半年一记）也保证一屏看到最近一批记录——2026-10-26 东林拍板。
    /// 真实区间依赖数据（哪些日子有记录），dateInterval 只返回占位区间，
    /// rangeSnapshot 会以记录日窗口覆盖 snapshot.interval
    case recentRecords(count: Int)
    /// 全部记录（调用方负责以习惯创建日为界）
    case all
    /// 自定义范围（start/end 均为自然日，end 含当天）
    case custom(start: Date, end: Date)

    /// 「最近记录」档默认取的记录日数
    static let defaultRecentCount = 30

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
        case .recentRecords, .all:
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

    /// 记录日历应显示的月份。月范围恒等于范围月——显示月是范围的派生值，
    /// 不允许落在独立翻月状态上（否则切「上月」后日历仍画本月，全部格子按
    /// 范围外禁用、无圆点，统计与日历对不上，2026-10-09 东林真机实锤）；
    /// 跨月范围显示月由用户翻月，读 fallback。
    func calendarDisplayMonth(fallback: Date) -> Date {
        if case .month(let monthStart) = self { return monthStart }
        return fallback
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
        case .recentRecords:
            return String(localized: "最近记录")
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
    /// 该习惯的每日结算时间（分钟；0 = 自然日）。records 已按它平移到日界坐标，
    /// 「今天」「创建日」等真实时刻在本快照内也必须按它平移
    let dayEndMinutes: Int

    var recordedDayCount: Int { recordedDays.count }

    /// 已过的自然日数（含今天，从创建日起；不含未来）——「x / y 天」里的 y 用它兜底
    var elapsedDays: Int {
        let calendar = Calendar.current
        let start = max(interval.start, creationDay(calendar: calendar))
        let end = min(interval.end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? interval.end)
        return max(calendar.dateComponents([.day], from: start, to: end).day ?? 0, 0)
    }

    /// 真实时刻 → 该习惯口径的日（startOfDay）
    func attributedDay(_ moment: Date, calendar: Calendar) -> Date {
        HabitDayAttribution.attributedDay(moment, dayEndMinutes: dayEndMinutes, calendar: calendar)
    }

    /// 创建日（习惯口径）
    func creationDay(calendar: Calendar) -> Date {
        attributedDay(info.createdAt, calendar: calendar)
    }

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
        let todayStart = attributedDay(today, calendar: calendar)
        return HabitReviewDay(
            day: dayStart,
            isRecorded: recorded,
            dailyValue: dailyValue,
            isPaused: HabitProjectionData.isPausedDay(info.pauseWindows, on: dayStart,
                                                     today: todayStart, calendar: calendar),
            isRetroactive: dayFacts.contains { $0.isRetroactive },
            isBeforeCreation: dayStart < creationDay(calendar: calendar),
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
        // 范围按该习惯的日界坐标展开：「今天」在结算时间前仍是前一天
        let dayEndMinutes = data.dayEndMinutes(for: info.id)
        let now = data.now(for: info.id)
        let interval: DateInterval
        if case .recentRecords(let count) = range {
            // 「最近记录」：从该习惯全部有效记录日取最近 count 个，最早一天为
            // 窗口起点（真实区间依赖数据，dateInterval 的 distantPast 占位在此覆盖）
            let allFacts = data.recordsByHabit[info.id] ?? []
            var allDays: Set<Date> = []
            if info.kind == .checkIn {
                for fact in allFacts where fact.isCompleted {
                    allDays.insert(data.dayStart(fact.date))
                }
            } else {
                for fact in allFacts where fact.finiteValue != nil {
                    allDays.insert(data.dayStart(fact.date))
                }
            }
            let recent = allDays.sorted(by: >).prefix(max(count, 1))
            let start = recent.min() ?? data.dayStart(now)
            interval = DateInterval(start: start, end: range.dateInterval(now: now, calendar: data.calendar).end)
        } else {
            interval = range.dateInterval(now: now, calendar: data.calendar)
        }
        // 半开归属 [start, end)：DateInterval.contains 含 end，界日（次月零点）
        // 会漏进本月（与 containsDay 同一个坑，必须手写比较）
        let facts = (data.recordsByHabit[info.id] ?? []).filter {
            $0.date >= interval.start && $0.date < interval.end
        }

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
            dailyValues: dailyValues,
            dayEndMinutes: dayEndMinutes
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

        // 可见集合：全关闭=[]（保留空态），白名单过滤，nil=全部。
        // 白名单可能存有已不存在 habit 的过期 UUID（重装恢复/迁移会重建 UUID），
        // 非空白名单一个都匹配不上时回退「全部」，否则页面对着「已选 N 项」渲染空世界
        let effectiveVisibleIds: [UUID]?
        let visibleHabits: [HabitReviewHabitInfo]
        switch visibleIds {
        case .none:
            effectiveVisibleIds = nil
            visibleHabits = habits
        case .some(let ids):
            let idSet = Set(ids)
            let filtered = habits.filter { idSet.contains($0.id) }
            if ids.isEmpty || !filtered.isEmpty {
                effectiveVisibleIds = ids
                visibleHabits = filtered
            } else {
                effectiveVisibleIds = nil
                visibleHabits = habits
            }
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
            let creationDay = HabitDayAttribution.attributedDay(
                info.createdAt, dayEndMinutes: data.dayEndMinutes(for: info.id), calendar: data.calendar
            )
            return creationDay < nextMonth
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
            visibleCount: effectiveVisibleIds.map(\.count)
        )
    }
}

// MARK: - 趋势柱（2026-11-02 轴即范围：只画完整落在范围内的自然日/周/月）

/// 趋势柱口径：完成率 / 记录天数 / 数量合计
enum HabitWeeklyTrendMode: Equatable {
    /// 记录天数 ÷ 有效天数（0...1）；仅 daily 好习惯
    case completionRate
    /// 记录（发生）天数；坏习惯往下走是好事，周习惯一周记 1 次即达成
    case weeklyDays
    /// 数量合计（计数型；周/月粒度把整段加总）
    case amount
}

/// 趋势粒度：范围 ≤31 天按天（仅计数型）、≤92 天按周、更长按月
enum HabitTrendGranularity: Equatable {
    case day
    case week
    case month
}

/// 一根趋势柱 = 一个完整的自然日 / 周（周一起）/ 月，半开区间 [start, end)
struct HabitTrendBar: Equatable, Identifiable {
    let start: Date
    let end: Date
    /// 有效天数（分母；创建前 / 暂停 / 未来剔除）
    let days: Int
    /// 有记录的天数（分子）
    let recordedDays: Int
    /// 计数型合计（区间内无记录 nil）
    let total: Double?
    /// 整根在未来（只有计数型「本月」按天铺满整月时出现）
    let isFuture: Bool

    var id: Date { start }

    /// 完成率（0...1）；分母为 0 的柱不画（那时习惯还不存在或整段暂停）
    var fraction: Double? {
        guard days > 0 else { return nil }
        return Double(recordedDays) / Double(days)
    }
}

struct HabitTrend: Equatable {
    let granularity: HabitTrendGranularity
    let mode: HabitWeeklyTrendMode
    let bars: [HabitTrendBar]
}

// MARK: - 本期 vs 上期对比（方案A：回答「有没有进步」）

/// 一侧窗口的聚合（等长窗口 + 完成率归一，月中对比才公平）
struct HabitPeriodSide: Equatable {
    /// 有记录的天数
    let recordedDays: Int
    /// 有效天数（创建前 / 暂停日剔除）
    let validDays: Int
    /// 计数型范围总量（仅 count）
    let countTotal: Double?
    /// 测量型均值（仅 measure；无记录 nil）
    let measureAverage: Double?

    /// 完成率（0...1）；分母 0 时 nil
    var completion: Double? {
        guard validDays > 0 else { return nil }
        return Double(recordedDays) / Double(validDays)
    }
}

/// 本期 vs 上期：上期 = 紧邻本期起点的等长窗口（长度 = 本期已过自然天数）。
/// 「本月过了 12 天」就跟「上月 1–12 日」比，完成率归一后月中与月末才可比。
struct HabitPeriodComparison {
    let current: HabitPeriodSide
    let previous: HabitPeriodSide?
    /// 上期窗口起日（nil = 无上期，如范围 all / 习惯创建晚于上期窗口）
    let previousStart: Date?
    /// 上期称谓（如「上月同期」「之前 30 天」）
    let previousLabel: String
}

// MARK: - 投影器

extension HabitReviewProjector {

    /// 统计起日：「全部」的区间起点是 distantPast 占位，一律以创建日为界（也防逐日空转卡死）
    static func effectiveStart(_ snapshot: HabitRangeSnapshot, calendar: Calendar) -> Date {
        max(snapshot.interval.start, snapshot.creationDay(calendar: calendar))
    }

    /// 名义终点：月范围 = 次月一日（按天画时铺满整月，未来日留空槽）；其余 = 区间终点（明天零点）
    static func nominalEnd(_ snapshot: HabitRangeSnapshot, calendar: Calendar) -> Date {
        if case .month(let monthStart) = snapshot.range {
            let start = calendar.startOfDay(for: monthStart)
            return calendar.date(byAdding: .month, value: 1, to: start) ?? snapshot.interval.end
        }
        return snapshot.interval.end
    }

    /// 打卡型趋势：范围落在一个自然月内 → nil（直接看日历）；跨月 ≤92 天按周、更长按月。
    /// 只画完整落在范围内且已过完的周 / 月——不满一个周期不画柱，轴上不会出现范围外的日期
    static func checkInTrend(snapshot: HabitRangeSnapshot, data: HabitProjectionData) -> HabitTrend? {
        guard snapshot.info.kind == .checkIn else { return nil }
        let calendar = data.calendar
        let start = effectiveStart(snapshot, calendar: calendar)
        let end = snapshot.interval.end
        guard start < end,
              let lastDay = calendar.date(byAdding: .day, value: -1, to: nominalEnd(snapshot, calendar: calendar)),
              !calendar.isDate(start, equalTo: lastDay, toGranularity: .month) else { return nil }
        let span = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        let granularity: HabitTrendGranularity = span <= 92 ? .week : .month
        let mode: HabitWeeklyTrendMode =
            (snapshot.info.frequency == .daily && !snapshot.info.isBadHabit) ? .completionRate : .weeklyDays
        // 只画已过完的完整周期：进行中的周/月只过了一部分，画出来矮柱永远像「退步」
        let cap = granularity == .week ? 26 : 36
        let bars = completePeriods(granularity, from: start, to: min(end, data.now),
                                   calendar: calendar, cap: cap)
            .map { trendBar(snapshot, data: data, start: $0.start, end: $0.end) }
        return bars.isEmpty ? nil : HabitTrend(granularity: granularity, mode: mode, bars: bars)
    }

    /// 计数型趋势：「最近记录」按天铺满真实区间；≤31 天按天（月范围铺满整月）、
    /// ≤92 天按周合计、更长按月合计（周 / 月只取完整的）
    static func countTrend(snapshot: HabitRangeSnapshot, data: HabitProjectionData) -> HabitTrend? {
        guard snapshot.info.kind == .count else { return nil }
        let calendar = data.calendar
        let start = effectiveStart(snapshot, calendar: calendar)
        let end = nominalEnd(snapshot, calendar: calendar)
        guard start < end else { return nil }
        let span = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        // 「最近记录」按天铺满真实区间（判读实锤：按周会把最近一次记录折进上周，用户找不到）
        let granularity: HabitTrendGranularity
        if case .recentRecords = snapshot.range {
            granularity = .day
        } else {
            granularity = span <= 31 ? .day : (span <= 92 ? .week : .month)
        }
        // 按天铺满整月（未来日空槽）；按周/月只画已过完的完整周期
        let periodEnd = granularity == .day ? end : min(snapshot.interval.end, data.now)
        let cap = granularity == .day ? 62 : (granularity == .week ? 26 : 36)
        let bars = completePeriods(granularity, from: start, to: periodEnd,
                                   calendar: calendar, cap: cap)
            .map { trendBar(snapshot, data: data, start: $0.start, end: $0.end) }
        return bars.isEmpty ? nil : HabitTrend(granularity: granularity, mode: .amount, bars: bars)
    }

    /// 测量型横轴：起日 + 天数。最近记录 = 首末记录日；月范围 = 整月；其余 = 范围起止（不早于创建日）
    static func measureAxis(snapshot: HabitRangeSnapshot, calendar: Calendar) -> (start: Date, dayCount: Int) {
        if case .recentRecords = snapshot.range,
           let first = snapshot.dailyValues.first?.date, let last = snapshot.dailyValues.last?.date {
            let start = calendar.startOfDay(for: first)
            let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: last)).day ?? 0
            return (start, days + 1)
        }
        let start = effectiveStart(snapshot, calendar: calendar)
        let end = nominalEnd(snapshot, calendar: calendar)
        return (start, max(calendar.dateComponents([.day], from: start, to: end).day ?? 1, 1))
    }

    /// [from, to) 内完整的自然日 / 周（周一起）/ 月，最多取最近 cap 个。
    /// 先定位最后一个周期起点、再倒推 cap 个起生成——夹具/同步副本可能带公元起的创建日，
    /// 从头逐周期迭代十万次会卡死主线程（2026-10-13「点全部闪退」同族，矩阵测试实锤 8s/2.4 万桶）
    static func completePeriods(_ granularity: HabitTrendGranularity, from: Date, to: Date,
                                calendar: Calendar, cap: Int) -> [(start: Date, end: Date)] {
        guard to > from, cap > 0 else { return [] }
        func step(_ date: Date, _ count: Int) -> Date? {
            switch granularity {
            case .day: return calendar.date(byAdding: .day, value: count, to: date)
            case .week: return calendar.date(byAdding: .day, value: 7 * count, to: date)
            case .month: return calendar.date(byAdding: .month, value: count, to: date)
            }
        }
        /// 某时刻所在周期的起点（day=当天；week=所在周周一；month=所在月 1 日）
        func periodStart(of moment: Date) -> Date {
            let day = calendar.startOfDay(for: moment)
            switch granularity {
            case .day:
                return day
            case .week:
                let offset = (calendar.component(.weekday, from: day) + 5) % 7
                return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
            case .month:
                return calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
            }
        }
        // 范围内第一个完整周期：from 当天或之后的第一个周期起点
        //（from 落在周期中段时，本周期不完整，从下一周期起）
        var first = periodStart(of: from)
        if first < from { first = step(first, 1) ?? first }
        // 最后一个完整周期：to 前最后一刻所在周期；它还没过完（end > to）时回退一个
        var last = periodStart(of: to.addingTimeInterval(-0.001))
        if let end = step(last, 1), end > to {
            last = step(last, -1) ?? last
        }
        guard last >= first, let lastEnd = step(last, 1), lastEnd <= to, first >= from else { return [] }
        // 倒推封顶：起点最多往前挪 cap - 1 个周期
        if let cappedFirst = step(last, -(cap - 1)), cappedFirst > first {
            first = cappedFirst
        }
        var periods: [(start: Date, end: Date)] = []
        var cursor = first
        while cursor <= last, let end = step(cursor, 1) {
            periods.append((cursor, end))
            guard let next = step(cursor, 1) else { break }
            cursor = next
        }
        return periods
    }

    private static func trendBar(_ snapshot: HabitRangeSnapshot, data: HabitProjectionData,
                                 start: Date, end: Date) -> HabitTrendBar {
        let calendar = data.calendar
        var days = 0
        var recorded = 0
        var total: Double?
        var day = start
        while day < end {
            let info = snapshot.day(day, today: data.now, calendar: calendar)
            if !info.isBeforeCreation && !info.isPaused && !info.isFuture {
                days += 1
                if info.isRecorded { recorded += 1 }
            }
            if let value = info.dailyValue { total = (total ?? 0) + value }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? end
        }
        return HabitTrendBar(start: start, end: end, days: days, recordedDays: recorded, total: total,
                             isFuture: snapshot.day(start, today: data.now, calendar: calendar).isFuture)
    }

    /// 本期 vs 上期对比。上期窗口紧邻本期起点、等长于本期已过天数；
    /// 上期没有任何有效天（习惯还不存在 / 整段暂停）时不比，不造无中生有的基线。
    static func periodComparison(
        snapshot: HabitRangeSnapshot,
        data: HabitProjectionData
    ) -> HabitPeriodComparison {
        let calendar = data.calendar
        // 「全部记录」没有「再往前一段」的语义；超长窗口的等长上期（如 distantPast 起算
        // 约 74 万天）逐日循环会卡死主线程——一律不比上期（2026-10-13 真机点「全部」闪退实锤）
        if case .all = snapshot.range {
            return HabitPeriodComparison(
                current: side(of: snapshot, data: data),
                previous: nil, previousStart: nil, previousLabel: "")
        }
        let elapsedDays = max(
            calendar.dateComponents([.day], from: snapshot.interval.start, to: snapshot.interval.end).day ?? 0,
            1)
        guard elapsedDays <= 366 else {
            return HabitPeriodComparison(
                current: side(of: snapshot, data: data),
                previous: nil, previousStart: nil, previousLabel: "")
        }
        let current = side(of: snapshot, data: data)

        // 上期窗口：月范围 = 上月同一段日子（11/1–11/2 对 10/1–10/2，按上月天数封顶）；
        // 其余 = 紧邻本期之前的等长窗口。旧实现月范围也取紧邻窗口，标签却写「上月同期」（2026-11-02 挑刺 N6）
        let previousStart: Date
        let previousEnd: Date
        if case .month(let monthStart) = snapshot.range {
            let thisMonth = calendar.startOfDay(for: monthStart)
            previousStart = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
            previousEnd = min(calendar.date(byAdding: .day, value: elapsedDays, to: previousStart) ?? thisMonth, thisMonth)
        } else {
            previousEnd = snapshot.interval.start
            previousStart = calendar.date(byAdding: .day, value: -elapsedDays, to: previousEnd) ?? previousEnd
        }
        guard previousStart < previousEnd else {
            return HabitPeriodComparison(current: current, previous: nil,
                                         previousStart: nil, previousLabel: "")
        }
        let previousSnapshot = rangeSnapshot(
            info: snapshot.info,
            range: .custom(start: previousStart,
                           end: calendar.date(byAdding: .day, value: -1, to: previousEnd) ?? previousEnd),
            data: data
        )
        let previous = side(of: previousSnapshot, data: data)
        guard previous.validDays > 0 else {
            return HabitPeriodComparison(current: current, previous: nil,
                                         previousStart: nil, previousLabel: "")
        }
        return HabitPeriodComparison(
            current: current,
            previous: previous,
            previousStart: previousStart,
            previousLabel: previousLabel(for: snapshot.range, start: previousStart, end: previousEnd,
                                         calendar: calendar)
        )
    }

    /// 单侧窗口聚合：记录天数 / 有效天数 / 计数总量 / 测量均值。
    /// 逐日循环必须封底：从 max(范围首日, 创建日) 起且只回看 ≤397 天——
    /// 「全部」的范围首日是公元 1 年，从那里空转到今天是「点全部卡死」的根源
    /// （2026-10-13 矩阵测试实锤：修掉周分桶后这里仍以 7.8s 超时）。
    private static func side(of snapshot: HabitRangeSnapshot, data: HabitProjectionData) -> HabitPeriodSide {
        let calendar = data.calendar
        let creationDay = snapshot.creationDay(calendar: calendar)
        let capFloor = calendar.date(byAdding: .day, value: -397, to: snapshot.interval.end)
            ?? snapshot.interval.start
        var day = max(max(snapshot.interval.start, creationDay), capFloor)
        var validDays = 0
        while day < snapshot.interval.end {
            let info = snapshot.day(day, today: data.now, calendar: calendar)
            if !info.isBeforeCreation && !info.isPaused && !info.isFuture {
                validDays += 1
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        var measureAverage: Double?
        if snapshot.info.kind == .measure, !snapshot.dailyValues.isEmpty {
            measureAverage = snapshot.dailyValues.reduce(0.0) { $0 + $1.value }
                / Double(snapshot.dailyValues.count)
        }
        return HabitPeriodSide(
            recordedDays: snapshot.recordedDayCount,
            validDays: validDays,
            countTotal: snapshot.countTotal,
            measureAverage: measureAverage
        )
    }

    /// 上期称谓：月范围 →「上月同期」；其余 →「之前 N 天」（N = 上期窗口自然日长；「前 N 天」易被读成「最初 N 天」。
    /// 旧实现拿 start→start-1 算出恒 0，「前 0 天」2026-10-26 模拟器实锤）
    private static func previousLabel(
        for range: HabitReviewRange,
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> String {
        if case .month = range {
            return String(localized: "上月同期")
        }
        let days = max(calendar.dateComponents([.day], from: start, to: end).day ?? 0, 1)
        return String(localized: "之前 \(days) 天")
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
