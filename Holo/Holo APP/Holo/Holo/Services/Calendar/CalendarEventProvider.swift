//
//  CalendarEventProvider.swift
//  Holo
//
//  日历事件聚合层：把记账/习惯/待办/想法 4 模块按区间聚合成 [CalendarEvent]。
//
//  关键设计：
//  1. 串行调用 4 模块（非 async let 并发）——共享同一 Core Data context，并发会违反线程安全。
//  2. 每个模块独立 do-catch，失败在 moduleStates 标 .failed，不静默丢（避免"今天没待办"误读）。
//  3. aggregate 为纯函数，便于单测覆盖失败态/排序/empty。
//

import Foundation
import CoreData
import os.log

struct CalendarEventProvider {

    let financeRepo: FinanceRepository
    let habitRepo: HabitRepository
    let todoRepo: TodoRepository
    let thoughtRepo: ThoughtRepository

    private static let logger = Logger(subsystem: "com.holo.app", category: "CalendarEventProvider")

    /// 单模块的分项结果（直接带 state，不用 Result 避免 String→Error 协议限制）
    struct Partial {
        let module: CalendarModule
        let events: [CalendarEvent]           // 失败时为空
        let state: CalendarModuleLoadState
    }

    // MARK: - 公开

    /// 拉取区间内的全部日历事件（4 模块聚合，含每模块加载状态）
    func fetchEvents(in range: DateInterval) async -> CalendarEventsResult {
        // 串行：4 模块共享同一 Core Data context，并发访问违反线程安全
        let finance = await fetchFinance(in: range)
        let habit = fetchHabit(in: range)
        let todo = fetchTodo(in: range)
        let thought = fetchThought(in: range)
        return Self.aggregate(partials: [finance, habit, todo, thought])
    }

    /// 拉取某一天的日历事件（月历当天详情用）
    func fetchDaySummary(_ date: Date) async -> CalendarEventsResult {
        await fetchEvents(in: CalendarRangeBuilder.dayRange(date))
    }

    // MARK: - 聚合（纯函数，单测入口）

    static func aggregate(partials: [Partial]) -> CalendarEventsResult {
        var events: [CalendarEvent] = []
        var states: [CalendarModule: CalendarModuleLoadState] = [:]
        for p in partials {
            events.append(contentsOf: p.events)
            states[p.module] = p.state
        }
        events.sort { $0.date < $1.date }
        return CalendarEventsResult(events: events, moduleStates: states)
    }

    // MARK: - 单模块拉取 + 映射（各自 do-catch，失败不阻塞其他）

    /// 记账：复用 FinanceRepository.getTransactions(from:to:)（已半开区间、返回实体）
    private func fetchFinance(in range: DateInterval) async -> Partial {
        do {
            let txns = try await financeRepo.getTransactions(from: range.start, to: range.end)
            let events: [CalendarEvent] = txns.map { txn in
                let amountString = NumberFormatter.currency.string(from: txn.amount as NSDecimalNumber) ?? ""
                let sign = txn.transactionType == .expense ? "-" : "+"
                return CalendarEvent(
                    module: .finance,
                    date: txn.date,
                    title: txn.category?.name ?? "未分类",
                    detail: "\(sign)\(amountString)",
                    originID: txn.objectID
                )
            }
            return Partial(module: .finance, events: events, state: events.isEmpty ? .empty : .loaded)
        } catch {
            Self.logger.error("日历·记账加载失败：\(String(describing: error))")
            return Partial(module: .finance, events: [], state: .failed(message: "记账加载失败"))
        }
    }

    /// 习惯：getActiveHabits 建 habitMap → getRecords(from:to:) 反查
    private func fetchHabit(in range: DateInterval) -> Partial {
        let habits = habitRepo.getActiveHabits()
        var habitMap: [UUID: Habit] = [:]
        for habit in habits { habitMap[habit.id] = habit }

        let records = habitRepo.getRecords(from: range.start, to: range.end)
        let events: [CalendarEvent] = records.compactMap { record in
            guard let habit = habitMap[record.habitId] else { return nil }
            let detail: String?
            if habit.isNumericType, let value = record.valueDouble {
                let unit = habit.unit ?? ""
                detail = unit.isEmpty ? "\(value)" : "\(value) \(unit)"
            } else if habit.isCheckInType {
                detail = record.isCompleted ? "已完成" : "未完成"
            } else {
                detail = nil
            }
            return CalendarEvent(
                module: .habit,
                date: record.date,
                title: habit.name,
                detail: detail,
                originID: record.objectID
            )
        }
        return Partial(module: .habit, events: events, state: events.isEmpty ? .empty : .loaded)
    }

    /// 待办：按 completedAt 区间取已完成实体
    private func fetchTodo(in range: DateInterval) -> Partial {
        let tasks = todoRepo.getTasks(completedFrom: range.start, completedTo: range.end)
        let events: [CalendarEvent] = tasks.compactMap { task in
            guard let completedAt = task.completedAt else { return nil }
            return CalendarEvent(
                module: .todo,
                date: completedAt,
                title: task.title,
                detail: "已完成",
                originID: task.objectID
            )
        }
        return Partial(module: .todo, events: events, state: events.isEmpty ? .empty : .loaded)
    }

    /// 想法：按 createdAt 区间取实体
    private func fetchThought(in range: DateInterval) -> Partial {
        do {
            let thoughts = try thoughtRepo.fetchThoughts(from: range.start, to: range.end)
            let events: [CalendarEvent] = thoughts.map { thought in
                let title = thought.previewText.isEmpty ? "未命名想法" : thought.previewText
                return CalendarEvent(
                    module: .thought,
                    date: thought.createdAt,
                    title: title,
                    detail: thought.moodType?.displayName,
                    originID: thought.objectID
                )
            }
            return Partial(module: .thought, events: events, state: events.isEmpty ? .empty : .loaded)
        } catch {
            Self.logger.error("日历·想法加载失败：\(String(describing: error))")
            return Partial(module: .thought, events: [], state: .failed(message: "想法加载失败"))
        }
    }
}
