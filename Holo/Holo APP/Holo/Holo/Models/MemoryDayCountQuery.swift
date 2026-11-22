//
//  MemoryDayCountQuery.swift
//  Holo
//
//  记忆长廊「按天件数」口径的唯一真源：记账 + 习惯记录（活跃习惯、排除取消打卡）+ 完成的任务 + 想法。
//  原散落在 MemoryGalleryViewModel（活跃热力图），2026-11-21 年鉴卡改版时原样搬出，
//  年鉴卡、长廊统计共用。所有方法需在调用方提供的（后台）context 上执行。
//

import CoreData
import Foundation

enum MemoryDayCountQuery {

    // MARK: - 公共口径

    /// 未归档、未删除的习惯 id
    static func activeHabitIds(context: NSManagedObjectContext) -> [UUID] {
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "isArchived == NO AND deletedAt == nil")
        let habits = (try? context.fetch(request)) ?? []
        return habits.map(\.id)
    }

    /// 排除取消打卡行（isCompleted=NO 仅在取消后出现；数值型行该字段恒 false，不适用），
    /// 记忆总数 / 记录天数 / 年鉴三个口径共用，口径变更只动这里
    static var excludeCancelledCheckInPredicate: NSPredicate {
        NSPredicate(format: "(habit.type != %d OR isCompleted == YES)", HabitType.checkIn.rawValue)
    }

    // MARK: - 按天件数

    /// `[start, end)` 区间内每天的件数，键为当天零点
    static func dayCounts(start: Date, end: Date, context: NSManagedObjectContext) -> [Date: Int] {
        let range = [start as NSDate, end as NSDate]
        var counts: [Date: Int] = [:]
        merge(into: &counts, fetchDayCounts(
            entityName: "Transaction",
            key: "date",
            predicate: NSPredicate(format: "deletedAt == nil AND date >= %@ AND date < %@", argumentArray: range),
            context: context
        ))
        merge(into: &counts, fetchHabitRecordDayCounts(
            for: activeHabitIds(context: context),
            start: start,
            end: end,
            context: context
        ))
        merge(into: &counts, fetchDayCounts(
            entityName: "TodoTask",
            key: "completedAt",
            predicate: NSPredicate(
                format: "deletedAt == nil AND archived == NO AND completed == YES AND completedAt >= %@ AND completedAt < %@",
                argumentArray: range
            ),
            context: context
        ))
        merge(into: &counts, fetchDayCounts(
            entityName: "Thought",
            key: "createdAt",
            predicate: NSPredicate(format: "deletedAt == nil AND isArchived == NO AND createdAt >= %@ AND createdAt < %@", argumentArray: range),
            context: context
        ))
        return counts
    }

    /// 自然年 `year` 的按天件数
    static func dayCounts(year: Int, calendar: Calendar = .current, context: NSManagedObjectContext) -> [Date: Int] {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return [:] }
        return dayCounts(start: start, end: end, context: context)
    }

    // MARK: - 开始记录日

    /// 四类记录中现存最早一条的日期（零点）；从未记录返回 nil
    static func firstRecordDate(context: NSManagedObjectContext) -> Date? {
        var candidates: [Date] = []
        candidates += earliest(entityName: "Transaction", key: "date",
                               predicate: NSPredicate(format: "deletedAt == nil"), context: context)
        let habitIds = activeHabitIds(context: context)
        if !habitIds.isEmpty {
            candidates += earliest(entityName: "HabitRecord", key: "date", predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "habitId IN %@ AND deletedAt == nil", habitIds),
                excludeCancelledCheckInPredicate
            ]), context: context)
        }
        candidates += earliest(entityName: "TodoTask", key: "completedAt",
                               predicate: NSPredicate(format: "deletedAt == nil AND archived == NO AND completed == YES AND completedAt != nil"),
                               context: context)
        candidates += earliest(entityName: "Thought", key: "createdAt",
                               predicate: NSPredicate(format: "deletedAt == nil AND isArchived == NO"), context: context)
        return candidates.min()?.startOfDay
    }

    // MARK: - 私有

    private static func fetchDayCounts(
        entityName: String,
        key: String,
        predicate: NSPredicate?,
        context: NSManagedObjectContext
    ) -> [Date: Int] {
        let request = NSFetchRequest<NSDictionary>(entityName: entityName)
        request.predicate = predicate
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = [key]
        let rows = (try? context.fetch(request)) ?? []
        return rows.reduce(into: [Date: Int]()) { result, row in
            guard let date = row[key] as? Date else { return }
            result[date.startOfDay, default: 0] += 1
        }
    }

    private static func fetchHabitRecordDayCounts(
        for activeHabitIds: [UUID],
        start: Date,
        end: Date,
        context: NSManagedObjectContext
    ) -> [Date: Int] {
        guard !activeHabitIds.isEmpty else { return [:] }
        return fetchDayCounts(
            entityName: "HabitRecord",
            key: "date",
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(
                    format: "habitId IN %@ AND date >= %@ AND date < %@ AND deletedAt == nil",
                    activeHabitIds,
                    start as NSDate,
                    end as NSDate
                ),
                excludeCancelledCheckInPredicate
            ]),
            context: context
        )
    }

    private static func earliest(entityName: String, key: String, predicate: NSPredicate, context: NSManagedObjectContext) -> [Date] {
        let request = NSFetchRequest<NSDictionary>(entityName: entityName)
        request.predicate = predicate
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = [key]
        request.sortDescriptors = [NSSortDescriptor(key: key, ascending: true)]
        request.fetchLimit = 1
        let rows = (try? context.fetch(request)) ?? []
        return rows.compactMap { $0[key] as? Date }
    }

    private static func merge(into target: inout [Date: Int], _ source: [Date: Int]) {
        for (date, count) in source {
            target[date, default: 0] += count
        }
    }
}
