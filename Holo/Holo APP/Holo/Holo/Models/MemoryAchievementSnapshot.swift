//
//  MemoryAchievementSnapshot.swift
//  Holo
//
//  长廊成就检测的批量只读材料：复用习惯模块的连续规则，一次读记录列，
//  不经主线程仓库逐日回查；调用者必须在传入 context 的队列上执行。
//

import Foundation
import CoreData

struct MemoryAchievementSnapshot {
    let streaks: [UUID: HabitStreak]
    let completedToday: Set<UUID>

    init(context: NSManagedObjectContext, now: Date = Date()) {
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "isArchived == NO")
        let habits = DuplicateRowFilter.deduplicatingCopies((try? context.fetch(request)) ?? [])
        let records = NSFetchRequest<NSDictionary>(entityName: "HabitRecord")
        records.resultType = .dictionaryResultType
        records.propertiesToFetch = ["id", "habitId", "date", "isCompleted"]
        records.predicate = NSPredicate(format: "deletedAt == nil")
        let facts: [HabitRecordFact] = ((try? context.fetch(records)) ?? []).compactMap { row in
            guard let id = row["id"] as? UUID, let habitID = row["habitId"] as? UUID,
                  let date = row["date"] as? Date else { return nil }
            return HabitRecordFact(id: id, habitId: habitID, date: date,
                                   isCompleted: (row["isCompleted"] as? NSNumber)?.boolValue ?? false,
                                   value: nil, isRetroactive: false)
        }
        let windows = Dictionary(habits.map { ($0.id, $0.pauseWindows) }, uniquingKeysWith: { first, _ in first })
        let data = HabitPresentationProjector.buildData(records: facts, pauseWindowsByHabit: windows, now: now)
        let completedToday = Set(data.recordsByHabit.compactMap { id, facts in
            // 与旧仓库今日判定同口径：当天最新一条记录的完成态。
            data.records(facts, on: data.today).last?.isCompleted == true ? id : nil
        })
        var streaks: [UUID: HabitStreak] = [:]
        for habit in habits {
            guard habit.isCheckInType else { streaks[habit.id] = .zero(); continue }
            let value: Int
            if habit.isBadHabit && habit.habitFrequency == .daily {
                value = HabitPresentationProjector.checkInControlStreak(habit: habit, data: data,
                    todayCompleted: completedToday.contains(habit.id))
            } else {
                value = HabitPresentationProjector.checkInStreakLabel(habit: habit, data: data,
                    todayCompleted: completedToday.contains(habit.id)).value
            }
            let unit: HabitStreakUnit = habit.habitFrequency == .daily ? .day : (habit.habitFrequency == .weekly ? .week : .month)
            streaks[habit.id] = HabitStreak(value: value, unit: unit)
        }
        self.streaks = streaks
        self.completedToday = completedToday
    }
}
