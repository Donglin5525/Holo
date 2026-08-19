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
        let historicalRange = HoloAgentHistoricalTimePolicy.resolve(timeRange)
        guard !historicalRange.isEntirelyFuture else { return [] }
        let effectiveRange = historicalRange.effectiveRange
        let defaultToday = calendar.startOfDay(for: Date())
        let defaultEnd = calendar.date(byAdding: .day, value: 1, to: defaultToday) ?? Date()
        let exclusiveEnd = calendar.startOfDay(for: effectiveRange?.end ?? defaultEnd)
        let referenceDay = calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) ?? defaultToday
        let start = calendar.startOfDay(
            for: effectiveRange?.start
                ?? calendar.date(byAdding: .day, value: -13, to: referenceDay)
                ?? referenceDay
        )
        let dayCount = max(
            (calendar.dateComponents([.day], from: start, to: referenceDay).day ?? 0) + 1,
            1
        )
        let inclusiveEnd = exclusiveEnd.addingTimeInterval(-0.001)
        repo.loadActiveHabits()
        return repo.activeHabits.map { habit in
            let records = repo.getRecords(for: habit, in: start...inclusiveEnd)
            return HoloHabitToolRecord(
                id: habit.id.uuidString,
                name: habit.name,
                polarity: habit.isBadHabit ? .negative : .positive,
                dailyGoal: goal(for: habit),
                dailyCounts: aggregate(
                    records: records,
                    today: referenceDay,
                    dayCount: dayCount,
                    isMeasureType: habit.isMeasureType
                ),
                unit: habit.isNumericType ? habit.unitText : nil,
                isMeasureType: habit.isMeasureType,
                recentNotes: collectNotes(records: records, today: referenceDay, dayCount: dayCount)
            )
        }
    }

    private static func goal(for habit: Habit) -> Double? {
        if let value = habit.targetValue?.doubleValue, value > 0 { return value }
        if let count = habit.targetCount?.intValue, count > 0 { return Double(count) }
        return nil
    }

    /// 按 dayOffset（0=参考日）聚合每日计数：计数型累加 value，打卡型 +1；
    /// 测量型（如体重，LATEST 聚合）取当日最后一条记录值，避免一天多次记录被错误累加。
    /// retroactiveCount 同步统计该日后补（补签/补记）条数，供工具层向 AI 标注。
    private static func aggregate(records: [HabitRecord], today: Date, dayCount: Int, isMeasureType: Bool) -> [HoloHabitDailyCount] {
        let calendar = Calendar.current
        var bucket = [Double](repeating: 0, count: dayCount)
        var retroBucket = [Int](repeating: 0, count: dayCount)
        if isMeasureType {
            // 同日多条（后补修正当日值）按 createdAt 取最新：补记记录 date=目标日零点、createdAt=补记时刻，
            // 按 date 比较会因同日相等退化为「先 fetch 先得」
            var latestCreatedAtByOffset = [Int: Date]()
            for record in records {
                guard let value = record.value?.doubleValue else { continue }
                let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: record.date), to: today).day ?? -1
                guard dayOffset >= 0, dayOffset < dayCount else { continue }
                if let existing = latestCreatedAtByOffset[dayOffset], existing >= record.createdAt {
                    continue
                }
                latestCreatedAtByOffset[dayOffset] = record.createdAt
                bucket[dayOffset] = value
                retroBucket[dayOffset] = record.isRetroactive ? 1 : 0
            }
        } else {
            for record in records {
                let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: record.date), to: today).day ?? -1
                guard dayOffset >= 0, dayOffset < dayCount else { continue }
                if let value = record.value?.doubleValue {
                    bucket[dayOffset] += value
                } else if record.isCompleted {
                    bucket[dayOffset] += 1
                }
                if record.isRetroactive { retroBucket[dayOffset] += 1 }
            }
        }
        return bucket.enumerated().map {
            HoloHabitDailyCount(dayOffset: $0.offset, count: $0.element, retroactiveCount: retroBucket[$0.offset] > 0 ? retroBucket[$0.offset] : nil)
        }
    }

    /// 收集近期备注（近→早，最多 5 条）：同一天多条时取最新一条（按 createdAt，与聚合口径一致）
    private static func collectNotes(records: [HabitRecord], today: Date, dayCount: Int) -> [HoloHabitDailyNote] {
        let calendar = Calendar.current
        var latestByOffset: [Int: (createdAt: Date, note: String, isRetroactive: Bool)] = [:]
        for record in records {
            guard let note = record.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { continue }
            let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: record.date), to: today).day ?? -1
            guard dayOffset >= 0, dayOffset < dayCount else { continue }
            if let existing = latestByOffset[dayOffset], existing.createdAt >= record.createdAt {
                continue
            }
            latestByOffset[dayOffset] = (record.createdAt, note, record.isRetroactive)
        }
        return latestByOffset
            .map { HoloHabitDailyNote(dayOffset: $0.key, note: $0.value.note, isRetroactive: $0.value.isRetroactive ? true : nil) }
            .sorted { $0.dayOffset < $1.dayOffset }
            .prefix(5)
            .map { $0 }
    }
}
