//
//  HabitRepository+Stats.swift
//  Holo
//
//  习惯统计相关方法
//

import Foundation
import CoreData

// MARK: - Statistics Extension

extension HabitRepository {

    /// 获取总览统计数据
    func getOverviewStats(range: HabitStatsDateRange) -> HabitOverviewStats {
        let habits = activeHabits
        let totalHabits = habits.count

        guard totalHabits > 0 else {
            return HabitOverviewStats.empty()
        }

        // 今日完成数
        let (todayCompleted, _) = getTodayCheckInProgress()

        // 计算平均完成率
        let dateRange = range.dateRange()
        var totalCompletionRate: Double = 0

        for habit in habits {
            if habit.isCheckInType {
                let completionRate = calculateCheckInCompletionRate(for: habit, in: dateRange)
                totalCompletionRate += completionRate
            } else if habit.isNumericType {
                let completionRate = calculateNumericCompletionRate(for: habit, in: dateRange)
                totalCompletionRate += completionRate
            }
        }

        let averageCompletionRate = totalCompletionRate / Double(totalHabits)

        // 计算总连续天数
        let totalStreak = habits.reduce(0) { $0 + calculateStreak(for: $1) }

        return HabitOverviewStats(
            todayCompleted: todayCompleted,
            totalHabits: totalHabits,
            averageCompletionRate: averageCompletionRate,
            totalStreak: totalStreak
        )
    }

    /// 获取全局完成率趋势数据
    func getOverallCompletionTrend(range: HabitStatsDateRange) -> [DailyCompletionData] {
        let habits = activeHabits
        guard !habits.isEmpty else { return [] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 确定起始日期
        let startDate: Date
        if let rangeDate = range.dateRange() {
            startDate = calendar.startOfDay(for: rangeDate.lowerBound)
        } else {
            // 全部：从最早的习惯创建日期开始
            startDate = habits.map { calendar.startOfDay(for: $0.createdAt) }.min() ?? today
        }

        var result: [DailyCompletionData] = []
        var currentDate = startDate

        while currentDate <= today {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDate)!
            var dayCompleted = 0
            var dayTotal = 0

            for habit in habits {
                // 检查习惯在该日期是否已创建
                guard habit.createdAt < nextDay else { continue }
                dayTotal += 1

                if habit.isBadHabit {
                    // 坏习惯：判断是否控制在目标以内
                    if habit.isCheckInType {
                        // 打卡型坏习惯：未打卡 = 成功
                        let request = HabitRecord.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "habitId == %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
                            habit.id as CVarArg,
                            currentDate as NSDate,
                            nextDay as NSDate
                        )
                        if (try? context.count(for: request)) ?? 0 == 0 {
                            dayCompleted += 1
                        }
                    } else if habit.isNumericType, let targetValue = habit.targetValueDouble {
                        // 数值型坏习惯：聚合值 <= 目标值 = 成功
                        let request = HabitRecord.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "habitId == %@ AND date >= %@ AND date < %@ AND value != nil",
                            habit.id as CVarArg,
                            currentDate as NSDate,
                            nextDay as NSDate
                        )
                        if let dayRecords = try? context.fetch(request) as? [HabitRecord] {
                            let aggregatedValue: Double
                            if habit.isCountType {
                                aggregatedValue = dayRecords.compactMap { $0.value?.doubleValue }.reduce(0, +)
                            } else {
                                aggregatedValue = dayRecords.last?.value?.doubleValue ?? 0
                            }
                            if aggregatedValue <= targetValue {
                                dayCompleted += 1
                            }
                        }
                    } else {
                        // 无目标值的数值型坏习惯：有记录即算
                        let request = HabitRecord.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "habitId == %@ AND date >= %@ AND date < %@ AND value != nil",
                            habit.id as CVarArg,
                            currentDate as NSDate,
                            nextDay as NSDate
                        )
                        if (try? context.count(for: request)) ?? 0 > 0 {
                            dayCompleted += 1
                        }
                    }
                } else {
                    // 好习惯：原有逻辑
                    if habit.isCheckInType {
                        let request = HabitRecord.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "habitId == %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
                            habit.id as CVarArg,
                            currentDate as NSDate,
                            nextDay as NSDate
                        )
                        if (try? context.count(for: request)) ?? 0 > 0 {
                            dayCompleted += 1
                        }
                    } else if habit.isNumericType {
                        let request = HabitRecord.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "habitId == %@ AND date >= %@ AND date < %@ AND value != nil",
                            habit.id as CVarArg,
                            currentDate as NSDate,
                            nextDay as NSDate
                        )
                        if (try? context.count(for: request)) ?? 0 > 0 {
                            dayCompleted += 1
                        }
                    }
                }
            }

            let completionRate = dayTotal > 0 ? Double(dayCompleted) / Double(dayTotal) * 100 : 0
            result.append(DailyCompletionData(date: currentDate, completionRate: completionRate))

            currentDate = nextDay
        }

        return result
    }

    /// 获取习惯排行榜（按完成率排序）
    func getHabitRanking(range: HabitStatsDateRange, limit: Int = 5) -> [HabitRankingItem] {
        let habits = activeHabits
        guard !habits.isEmpty else { return [] }

        let dateRange = range.dateRange()

        var items: [HabitRankingItem] = []

        for habit in habits {
            let completionRate: Double
            if habit.isCheckInType {
                completionRate = calculateCheckInCompletionRate(for: habit, in: dateRange)
            } else {
                completionRate = calculateNumericCompletionRate(for: habit, in: dateRange)
            }

            let streak = calculateStreak(for: habit)

            items.append(HabitRankingItem(
                habitId: habit.id,
                name: habit.name,
                icon: habit.icon,
                color: habit.color,
                completionRate: completionRate,
                streak: streak
            ))
        }

        // 按完成率降序排序
        items.sort { $0.completionRate > $1.completionRate }

        // 返回前 limit 个
        return Array(items.prefix(limit))
    }

    /// 获取习惯统计数据项
    func getHabitStatsItems(range: HabitStatsDateRange, filter: HabitTypeFilter = .all) -> [HabitStatsItem] {
        var habits = activeHabits

        // 类型筛选
        switch filter {
        case .checkIn:
            habits = habits.filter { $0.isCheckInType }
        case .count:
            habits = habits.filter { $0.isCountType }
        case .measure:
            habits = habits.filter { $0.isMeasureType }
        default:
            break
        }

        let dateRange = range.dateRange()

        return habits.map { habit in
            let streak = calculateStreak(for: habit)
            let completionRate: Double
            let todayValue: Double?
            let todayTarget: Double?

            if habit.isCheckInType {
                completionRate = calculateCheckInCompletionRate(for: habit, in: dateRange)
                todayValue = isTodayCompleted(for: habit) ? 1 : 0
                todayTarget = habit.targetCountValue.map { Double($0) }
            } else {
                completionRate = calculateNumericCompletionRate(for: habit, in: dateRange)
                todayValue = getTodayValue(for: habit)
                todayTarget = habit.targetValueDouble
            }

            // 将 HabitStatsDateRange 转换为 HabitDateRange 以复用现有方法
            let legacyRange = convertToHabitDateRange(range)
            let dailyData = habit.isNumericType ? getDailyAggregatedData(for: habit, range: legacyRange) : []
            let calendarData = habit.isCheckInType ? getCheckInCalendarData(for: habit, range: range) : [:]

            return HabitStatsItem(
                habitId: habit.id,
                name: habit.name,
                icon: habit.icon,
                color: habit.color,
                typeRaw: habit.type,
                aggregationTypeRaw: habit.aggregationType,
                streak: streak,
                completionRate: completionRate,
                todayValue: todayValue,
                todayTarget: todayTarget,
                unit: habit.unit,
                dailyData: dailyData,
                calendarData: calendarData
            )
        }
    }

    /// 将 HabitStatsDateRange 转换为 HabitDateRange
    func convertToHabitDateRange(_ range: HabitStatsDateRange) -> HabitDateRange {
        switch range {
        case .week: return .week
        case .month: return .month
        case .quarter: return .quarter
        case .all: return .all
        }
    }

    /// 获取打卡型习惯的日历数据
    func getCheckInCalendarData(for habit: Habit, range: HabitStatsDateRange) -> [Date: Bool] {
        guard habit.isCheckInType else { return [:] }

        let calendar = Calendar.current
        let records = getRecords(for: habit, in: range.dateRange())

        var result: [Date: Bool] = [:]
        for record in records {
            let dayStart = calendar.startOfDay(for: record.date)
            result[dayStart] = record.isCompleted
        }

        return result
    }

    // MARK: - Private Helpers

    /// 计算打卡型习惯的完成率
    func calculateCheckInCompletionRate(for habit: Habit, in dateRange: ClosedRange<Date>?) -> Double {
        guard habit.isCheckInType else { return 0 }

        let calendar = Calendar.current
        let records = getRecords(for: habit, in: dateRange)

        // 计算周期内的天数
        let dayCount: Int
        if let range = dateRange {
            let components = calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound)
            dayCount = max(components.day ?? 1, 1) + 1
        } else {
            // 全部时间：从习惯创建日期到今天
            let components = calendar.dateComponents([.day], from: habit.createdAt, to: Date())
            dayCount = max(components.day ?? 1, 1) + 1
        }

        if habit.isBadHabit {
            // 坏习惯：未打卡的天数算作成功（没有做坏习惯）
            let checkedInCount = records.filter { $0.isCompleted }.count
            let controlledCount = max(dayCount - checkedInCount, 0)
            return dayCount > 0 ? Double(controlledCount) / Double(dayCount) * 100 : 0
        } else {
            // 好习惯：打卡天数即算完成
            let completedCount = records.filter { $0.isCompleted }.count
            return dayCount > 0 ? Double(completedCount) / Double(dayCount) * 100 : 0
        }
    }

    /// 计算数值型习惯的完成率
    func calculateNumericCompletionRate(for habit: Habit, in dateRange: ClosedRange<Date>?) -> Double {
        guard habit.isNumericType else { return 0 }

        let calendar = Calendar.current
        let records = getRecords(for: habit, in: dateRange)

        // 计算周期内的天数
        let dayCount: Int
        if let range = dateRange {
            let components = calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound)
            dayCount = max(components.day ?? 1, 1) + 1
        } else {
            let components = calendar.dateComponents([.day], from: habit.createdAt, to: Date())
            dayCount = max(components.day ?? 1, 1) + 1
        }

        if habit.isBadHabit, let targetValue = habit.targetValueDouble {
            // 坏习惯：按天聚合值，统计未超标（值 <= 目标值）的天数
            var dailyValues: [Date: Double] = [:]
            for record in records {
                guard let value = record.value?.doubleValue else { continue }
                let dayStart = calendar.startOfDay(for: record.date)

                if habit.isCountType {
                    dailyValues[dayStart, default: 0] += value
                } else {
                    dailyValues[dayStart] = value
                }
            }

            let controlledDays = dailyValues.values.filter { $0 <= targetValue }.count
            return dayCount > 0 ? Double(controlledDays) / Double(dayCount) * 100 : 0
        } else {
            // 好习惯：有记录的天数即算完成
            var recordedDays = Set<Date>()
            for record in records {
                let dayStart = calendar.startOfDay(for: record.date)
                recordedDays.insert(dayStart)
            }

            return dayCount > 0 ? Double(recordedDays.count) / Double(dayCount) * 100 : 0
        }
    }

    // MARK: - 月度统计投影

    /// 获取月度总览统计
    func getOverviewStats(forMonth month: Date, visibleHabitIds: [UUID]?) -> HabitOverviewStats {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth) else {
            return .empty()
        }
        let monthRange = monthStart...calendar.date(byAdding: .day, value: 1, to: monthEnd)!

        let habits: [Habit]
        if let visibleIds = visibleHabitIds, !visibleIds.isEmpty {
            let visibleSet = Set(visibleIds)
            habits = activeHabits.filter { visibleSet.contains($0.id) }
        } else {
            habits = activeHabits
        }

        let totalHabits = habits.count
        guard totalHabits > 0 else { return .empty() }

        let (todayCompleted, _) = getTodayCheckInProgress()

        var totalCompletionRate: Double = 0
        for habit in habits {
            if habit.isCheckInType {
                totalCompletionRate += calculateCheckInCompletionRate(for: habit, in: monthRange)
            } else if habit.isNumericType {
                totalCompletionRate += calculateNumericCompletionRate(for: habit, in: monthRange)
            }
        }

        let averageCompletionRate = totalCompletionRate / Double(totalHabits)
        let totalStreak = habits.reduce(0) { $0 + calculateStreak(for: $1) }

        return HabitOverviewStats(
            todayCompleted: todayCompleted,
            totalHabits: totalHabits,
            averageCompletionRate: averageCompletionRate,
            totalStreak: totalStreak
        )
    }

    /// 获取习惯统计展示项（月度）
    func getHabitStatsDisplayItems(
        month: Date,
        visibleHabitIds: [UUID]?,
        orderedHabitIds: [UUID]?
    ) -> [HabitStatsDisplayItem] {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth) else {
            return []
        }

        let habits = orderedHabitsForStats(visibleHabitIds: visibleHabitIds, orderedHabitIds: orderedHabitIds)

        return habits.map { habit in
            let monthCells = makeMonthCells(for: habit, monthStart: monthStart, monthEnd: monthEnd)
            let weeks = makeWeekSlices(from: monthCells, monthStart: monthStart)
            let collapsedWeek = weeks.last(where: { $0.days.contains(where: \.hasRecord) }) ?? weeks.first ?? HabitStatsWeekSlice(weekStart: monthStart, days: [])

            let weekdaySymbols = calendar.shortWeekdaySymbols
            let rows = stride(from: 0, to: monthCells.count, by: 7).map {
                Array(monthCells[$0..<min($0 + 7, monthCells.count)])
            }

            return HabitStatsDisplayItem(
                habitId: habit.id,
                name: habit.name,
                icon: habit.icon,
                isCustomIcon: habit.isCustomIcon,
                habitColorHex: habit.color,
                type: statsCardKind(for: habit),
                summary: statsSummary(for: habit, monthStart: monthStart, monthEnd: monthEnd),
                collapsedWeek: collapsedWeek,
                allWeeks: weeks,
                month: HabitStatsMonthSection(
                    monthStart: monthStart,
                    weekdaySymbols: weekdaySymbols,
                    rows: rows
                )
            )
        }
    }

    // MARK: - Private Helpers (月度统计)

    /// 按展示设置排序习惯
    func orderedHabitsForStats(visibleHabitIds: [UUID]?, orderedHabitIds: [UUID]?) -> [Habit] {
        let visible = Set(visibleHabitIds ?? activeHabits.map(\.id))
        let filtered = activeHabits.filter { visible.contains($0.id) }
        let order = Dictionary(uniqueKeysWithValues: (orderedHabitIds ?? []).enumerated().map { ($1, $0) })
        return filtered.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    /// 构建月份格子
    /// 好习惯：hasRecord=有记录（成功），isOverLimit=false
    /// 坏习惯：hasRecord=控制住（成功），isOverLimit=超标（失败）
    func makeMonthCells(for habit: Habit, monthStart: Date, monthEnd: Date) -> [HabitStatsDayCell] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let nextDay = calendar.date(byAdding: .day, value: 1, to: monthEnd)!
        let records = getRecords(for: habit, in: monthStart...nextDay)

        if habit.isBadHabit {
            return makeBadHabitMonthCells(
                habit: habit, monthStart: monthStart, monthEnd: monthEnd,
                today: today, records: records, calendar: calendar
            )
        }

        // 好习惯：原始逻辑不变
        var recordDates = Set<Date>()
        for record in records {
            let dayStart = calendar.startOfDay(for: record.date)
            recordDates.insert(dayStart)
        }

        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let weekdayOffset = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [HabitStatsDayCell] = []

        for i in 0..<weekdayOffset {
            guard let date = calendar.date(byAdding: .day, value: i - weekdayOffset, to: monthStart) else { continue }
            cells.append(HabitStatsDayCell(
                date: date, dayNumber: nil, isInCurrentMonth: false,
                isToday: false, hasRecord: false, isOverLimit: false
            ))
        }

        let daysInMonth = calendar.dateComponents([.day], from: monthStart, to: monthEnd).day! + 1
        for dayOffset in 0..<daysInMonth {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: monthStart) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            let dayNumber = calendar.component(.day, from: date)
            cells.append(HabitStatsDayCell(
                date: date, dayNumber: dayNumber, isInCurrentMonth: true,
                isToday: dayStart == today,
                hasRecord: recordDates.contains(dayStart), isOverLimit: false
            ))
        }

        let remainder = cells.count % 7
        if remainder > 0 {
            for i in 0..<(7 - remainder) {
                guard let date = calendar.date(byAdding: .day, value: i + 1, to: monthEnd) else { continue }
                cells.append(HabitStatsDayCell(
                    date: date, dayNumber: nil, isInCurrentMonth: false,
                    isToday: false, hasRecord: false, isOverLimit: false
                ))
            }
        }

        return cells
    }

    /// 坏习惯月份格子构建
    func makeBadHabitMonthCells(
        habit: Habit, monthStart: Date, monthEnd: Date,
        today: Date, records: [HabitRecord], calendar: Calendar
    ) -> [HabitStatsDayCell] {
        // 构建每日超标判断
        var exceededDays = Set<Date>()
        var recordedDays = Set<Date>()

        if habit.isCheckInType {
            // 打卡型坏习惯：有 isCompleted 记录 = 做了坏事 = 超标
            for record in records where record.isCompleted {
                let dayStart = calendar.startOfDay(for: record.date)
                exceededDays.insert(dayStart)
                recordedDays.insert(dayStart)
            }
        } else {
            // 数值型坏习惯：聚合值 > 目标值 = 超标
            let targetValue = habit.targetValueDouble ?? 0
            var dailyValues: [Date: Double] = [:]
            for record in records {
                let dayStart = calendar.startOfDay(for: record.date)
                recordedDays.insert(dayStart)
                if let value = record.value?.doubleValue {
                    if habit.isCountType {
                        dailyValues[dayStart, default: 0] += value
                    } else {
                        dailyValues[dayStart] = value
                    }
                }
            }
            for (day, value) in dailyValues where value > targetValue {
                exceededDays.insert(day)
            }
        }

        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let weekdayOffset = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [HabitStatsDayCell] = []

        for i in 0..<weekdayOffset {
            guard let date = calendar.date(byAdding: .day, value: i - weekdayOffset, to: monthStart) else { continue }
            cells.append(HabitStatsDayCell(
                date: date, dayNumber: nil, isInCurrentMonth: false,
                isToday: false, hasRecord: false, isOverLimit: false
            ))
        }

        let daysInMonth = calendar.dateComponents([.day], from: monthStart, to: monthEnd).day! + 1
        for dayOffset in 0..<daysInMonth {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: monthStart) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            let dayNumber = calendar.component(.day, from: date)
            let isExceeded = exceededDays.contains(dayStart)
            // 坏习惯：控制住=成功(hasRecord=true)，超标=失败(hasRecord=false, isOverLimit=true)
            cells.append(HabitStatsDayCell(
                date: date, dayNumber: dayNumber, isInCurrentMonth: true,
                isToday: dayStart == today,
                hasRecord: !isExceeded,
                isOverLimit: isExceeded
            ))
        }

        let remainder = cells.count % 7
        if remainder > 0 {
            for i in 0..<(7 - remainder) {
                guard let date = calendar.date(byAdding: .day, value: i + 1, to: monthEnd) else { continue }
                cells.append(HabitStatsDayCell(
                    date: date, dayNumber: nil, isInCurrentMonth: false,
                    isToday: false, hasRecord: false, isOverLimit: false
                ))
            }
        }

        return cells
    }

    /// 将月份格子切分为周
    func makeWeekSlices(from cells: [HabitStatsDayCell], monthStart: Date) -> [HabitStatsWeekSlice] {
        guard !cells.isEmpty else { return [] }

        var weeks: [HabitStatsWeekSlice] = []
        var index = 0
        while index < cells.count {
            let endIndex = min(index + 7, cells.count)
            let weekDays = Array(cells[index..<endIndex])
            weeks.append(HabitStatsWeekSlice(weekStart: weekDays.first?.date ?? monthStart, days: weekDays))
            index += 7
        }
        return weeks
    }

    /// 获取习惯的卡片类型
    func statsCardKind(for habit: Habit) -> HabitStatsCardKind {
        if habit.isCheckInType {
            return .checkIn
        } else if habit.isCountType {
            return .count
        } else {
            return .measure
        }
    }

    /// 计算习惯的月度摘要
    func statsSummary(for habit: Habit, monthStart: Date, monthEnd: Date) -> HabitStatsCardSummary {
        let calendar = Calendar.current
        let nextDay = calendar.date(byAdding: .day, value: 1, to: monthEnd)!
        let records = getRecords(for: habit, in: monthStart...nextDay)

        var dailyValues: [Date: Double] = [:]
        var dailyHasRecord = Set<Date>()
        for record in records {
            let dayStart = calendar.startOfDay(for: record.date)
            dailyHasRecord.insert(dayStart)
            if let value = record.value?.doubleValue {
                if habit.isCountType {
                    dailyValues[dayStart, default: 0] += value
                } else if habit.isMeasureType {
                    dailyValues[dayStart] = value
                }
            }
        }

        let streak = calculateStreak(for: habit)

        // 坏习惯：统计控制住的天数
        if habit.isBadHabit {
            let daysInMonth = calendar.dateComponents([.day], from: monthStart, to: monthEnd).day! + 1

            if habit.isCheckInType {
                // 打卡型：未打卡天数 = 控制住
                let checkedInDays = records.filter { $0.isCompleted }.count
                let controlledDays = max(daysInMonth - checkedInDays, 0)
                return .checkIn(completedDays: controlledDays, streak: streak)
            } else {
                let targetValue = habit.targetValueDouble ?? 0
                // 数值型：聚合值 <= 目标值的天数 + 没有记录的天数
                let exceededDays = dailyValues.values.filter { $0 > targetValue }.count
                let controlledDays = max(daysInMonth - exceededDays, 0)

                if habit.isCountType {
                    let total = dailyValues.values.reduce(0, +)
                    let formatted: String
                    if total == floor(total) {
                        formatted = "\(Int(total))次"
                    } else {
                        formatted = "\(String(format: "%.1f", total))次"
                    }
                    return .count(recordedDays: controlledDays, totalCountText: formatted)
                } else {
                    let avg: Double
                    if dailyValues.isEmpty {
                        avg = 0
                    } else {
                        avg = dailyValues.values.reduce(0, +) / Double(dailyValues.count)
                    }
                    let unit = habit.unit ?? ""
                    let formatted = String(format: "%.1f%@", avg, unit)
                    return .measure(recordedDays: controlledDays, averageValueText: formatted)
                }
            }
        }

        // 好习惯：原始逻辑
        let recordedDays = dailyHasRecord.count

        if habit.isCheckInType {
            return .checkIn(completedDays: recordedDays, streak: streak)
        } else if habit.isCountType {
            let total = dailyValues.values.reduce(0, +)
            let formatted: String
            if total == floor(total) {
                formatted = "\(Int(total))次"
            } else {
                formatted = "\(String(format: "%.1f", total))次"
            }
            return .count(recordedDays: recordedDays, totalCountText: formatted)
        } else {
            let avg: Double
            if dailyValues.isEmpty {
                avg = 0
            } else {
                avg = dailyValues.values.reduce(0, +) / Double(dailyValues.count)
            }
            let unit = habit.unit ?? ""
            let formatted = String(format: "%.1f%@", avg, unit)
            return .measure(recordedDays: recordedDays, averageValueText: formatted)
        }
    }
}
