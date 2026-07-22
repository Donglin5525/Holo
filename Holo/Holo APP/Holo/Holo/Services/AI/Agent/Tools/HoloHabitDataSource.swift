//
//  HoloHabitDataSource.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task #34 生产习惯数据源
//  包裹真实 HabitRepository，按日聚合近 14 天打卡/数值记录，转为 HabitTool 中性结构。
//  依赖 Core Data，仅随 app 编译，不进入 standalone 测试。
//

import Foundation

struct HoloDefaultHabitDataSource: HoloHabitDataSource {

    func habits(timeRange: HoloAgentTimeRange?) async -> [HoloHabitToolRecord] {
        await MainActor.run { Self.loadHabitsOnMain(timeRange: timeRange) }
    }

    private static func loadHabitsOnMain(timeRange: HoloAgentTimeRange?) -> [HoloHabitToolRecord] {
        let repo = HabitRepository.shared
        let calendar = Calendar.current
        let today = timeRange?.end ?? calendar.startOfDay(for: Date())
        let start = timeRange?.start ?? (calendar.date(byAdding: .day, value: -13, to: today) ?? today)
        let dayCount = max((calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: today).day ?? 0) + 1, 1)
        repo.loadActiveHabits()
        return repo.activeHabits.map { habit in
            let records = repo.getRecords(for: habit, in: start...today)
            return HoloHabitToolRecord(
                id: habit.id.uuidString,
                name: habit.name ?? "",
                polarity: habit.isBadHabit ? .negative : .positive,
                dailyGoal: goal(for: habit),
                dailyCounts: aggregate(records: records, habit: habit, today: today, dayCount: dayCount)
            )
        }
    }

    private static func goal(for habit: Habit) -> Double? {
        if let value = habit.targetValue?.doubleValue, value > 0 { return value }
        if let count = habit.targetCount?.intValue, count > 0 { return Double(count) }
        return nil
    }

    /// 按 dayOffset（0=今天）聚合每日记录：计数类累加、测量类取最后一个有效值、打卡型 +1。
    private static func aggregate(
        records: [HabitRecord],
        habit: Habit,
        today: Date,
        dayCount: Int
    ) -> [HoloHabitDailyCount] {
        let calendar = Calendar.current
        var bucket = [Double](repeating: 0, count: dayCount)

        if habit.isNumericType {
            let dailyValues = HabitNumericAggregator.aggregateDaily(
                samples: records.map { HabitNumericSample(date: $0.date, value: $0.valueDouble) },
                isCountType: habit.isCountType,
                calendar: calendar
            )
            for dailyValue in dailyValues {
                let dayOffset = calendar.dateComponents(
                    [.day],
                    from: calendar.startOfDay(for: dailyValue.date),
                    to: today
                ).day ?? -1
                guard dayOffset >= 0, dayOffset < dayCount else { continue }
                bucket[dayOffset] = dailyValue.value
            }
            return bucket.enumerated().map {
                HoloHabitDailyCount(dayOffset: $0.offset, count: $0.element)
            }
        }

        for record in records {
            let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: record.date), to: today).day ?? -1
            guard dayOffset >= 0, dayOffset < dayCount else { continue }
            if record.isCompleted {
                bucket[dayOffset] += 1
            }
        }
        return bucket.enumerated().map { HoloHabitDailyCount(dayOffset: $0.offset, count: $0.element) }
    }
}
