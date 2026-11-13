//
//  MemoryRandomWalkDayIndex.swift
//  Holo
//
//  随机漫步的历史日期索引（暖光规格 §5.1）：
//  - 后台上下文 + 轻量投影，一次读全历史「有记录的日子」，突破长廊 ±60 天窗口
//  - 四模块过滤与同 ID 副本去重完全沿用 CalendarEventProvider 的口径；
//    谓词漂移由 MemoryRandomWalkCoreTests 的 fixture 对拍防线兜住
//  - 记录代表（同 ID 多副本取物理行号最小）在全历史范围只选一次，
//    按日详情用它校验，避免单日查询与全历史查询选出不同日期的代表
//

import Foundation
import CoreData
import os.log

/// 一条日历记录的稳定身份（模块 + 业务 UUID）。
struct CalendarEventKey: Hashable {
    let module: CalendarModule
    let id: UUID
}

/// 「哪些本地日有记录」的轻量索引；只存身份与日聚合，不持有展示数据。
struct MemoryRandomWalkDayIndex: Equatable {
    /// 有记录的本地日（startOfDay），升序。
    let days: [Date]
    /// 日 → 该日记录身份集合（去重后的代表）。
    let keysByDay: [Date: Set<CalendarEventKey>]
    /// 记录身份 → 所属日（跨日副本守卫用）。
    let dayByKey: [CalendarEventKey: Date]
    /// 构建时失败的模块（候选口径不完整时 UI 要如实提示）。
    let failedModules: Set<CalendarModule>
    let revision: UUID

    static let empty = MemoryRandomWalkDayIndex(days: [], keysByDay: [:], dayByKey: [:],
                                                failedModules: [], revision: UUID())

    var hasAnyRecord: Bool { !days.isEmpty }

    /// 抽样候选：本地今天之前的全部有记录日。
    func candidateDays(before today: Date, calendar: Calendar) -> [Date] {
        let startOfToday = calendar.startOfDay(for: today)
        return days.filter { $0 < startOfToday }
    }

    /// 该记录身份是否属于给定日；索引不认识的身份（新写入）不算冲突。
    func isConsistent(_ key: CalendarEventKey, with day: Date) -> Bool {
        guard let known = dayByKey[key] else { return true }
        return known == day
    }
}

enum MemoryRandomWalkDayIndexBuilder {

    private static let logger = Logger(subsystem: "com.holo.app", category: "RandomWalkIndex")

    /// 全历史构建。调用方负责在后台执行（context.perform 内已串行）。
    static func build(coordinator: NSPersistentStoreCoordinator?,
                      calendar: Calendar = .current,
                      now: Date = Date()) -> MemoryRandomWalkDayIndex {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.undoManager = nil
        var result: MemoryRandomWalkDayIndex!
        context.performAndWait {
            result = build(in: context, calendar: calendar, now: now)
        }
        return result
    }

    static func build(in context: NSManagedObjectContext,
                      calendar: Calendar = .current,
                      now: Date = Date()) -> MemoryRandomWalkDayIndex {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)

        var keysByDay: [Date: Set<CalendarEventKey>] = [:]
        var failed: Set<CalendarModule> = []

        func absorb(_ keys: [(CalendarEventKey, Date)]) {
            for (key, date) in keys {
                let day = calendar.startOfDay(for: date)
                keysByDay[day, default: []].insert(key)
            }
        }

        // 记账：与 CalendarEventProvider.fetchFinance 同口径
        // （区间 + occurredPredicate + 软删；排除仍计划发生的记录）
        do {
            let request = Transaction.fetchRequest()
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "date < %@", end as NSDate),
                FinanceTransactionOccurrencePolicy.occurredPredicate(),
                NSPredicate(format: "deletedAt == nil")
            ])
            let rows = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
            absorb(rows.map { (CalendarEventKey(module: .finance, id: $0.id), $0.date) })
        } catch {
            failed.insert(.finance)
            logger.error("漫步索引·记账失败：\(String(describing: error))")
        }

        // 习惯：与 fetchHabit 同口径（父习惯存活 + 打卡型未完成跳过）
        do {
            let habitRequest = Habit.fetchRequest()
            habitRequest.predicate = NSPredicate(format: "isArchived == NO AND deletedAt == nil")
            let habits = DuplicateRowFilter.deduplicatingCopies(try context.fetch(habitRequest))
            var aliveCheckIn = Set<UUID>()
            for habit in habits where habit.isCheckInType {
                aliveCheckIn.insert(habit.id)
            }
            let recordRequest = HabitRecord.fetchRequest()
            recordRequest.predicate = NSPredicate(format: "date < %@ AND deletedAt == nil", end as NSDate)
            let records = DuplicateRowFilter.deduplicatingCopies(try context.fetch(recordRequest))
            let aliveIDs = Set(habits.map(\.id))
            absorb(records.compactMap { record in
                guard aliveIDs.contains(record.habitId) else { return nil }
                if aliveCheckIn.contains(record.habitId), !record.isCompleted { return nil }
                return (CalendarEventKey(module: .habit, id: record.id), record.date)
            })
        } catch {
            failed.insert(.habit)
            logger.error("漫步索引·习惯失败：\(String(describing: error))")
        }

        // 待办：与 fetchTodo(.completed) 同口径（completedAt 维度 + 软删/归档排除）
        do {
            let request = TodoTask.fetchRequest()
            request.predicate = NSPredicate(format: "completedAt < %@ AND completedAt != nil AND deletedAt == nil AND archived == NO",
                                            end as NSDate)
            let tasks = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
            absorb(tasks.compactMap { task in
                guard let date = task.completedAt else { return nil }
                return (CalendarEventKey(module: .todo, id: task.id), date)
            })
        } catch {
            failed.insert(.todo)
            logger.error("漫步索引·待办失败：\(String(describing: error))")
        }

        // 想法：直接走 ThoughtRepository.fetchThoughts（归档/软删/副本语义零漂移）
        do {
            let repo = ThoughtRepository(context: context)
            let thoughts = try repo.fetchThoughts(from: .distantPast, to: end)
            absorb(thoughts.map { (CalendarEventKey(module: .thought, id: $0.id), $0.createdAt) })
        } catch {
            failed.insert(.thought)
            logger.error("漫步索引·想法失败：\(String(describing: error))")
        }

        var dayByKey: [CalendarEventKey: Date] = [:]
        for (day, keys) in keysByDay {
            for key in keys where dayByKey[key] == nil {
                dayByKey[key] = day
            }
        }
        return MemoryRandomWalkDayIndex(days: keysByDay.keys.sorted(),
                                        keysByDay: keysByDay,
                                        dayByKey: dayByKey,
                                        failedModules: failed,
                                        revision: UUID())
    }
}
