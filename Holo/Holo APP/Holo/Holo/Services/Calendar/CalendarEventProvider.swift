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
//  4. P2：待办支持 todoDimension（completed/due/planned）切换时间字段。
//

import Foundation
import CoreData
import os.log

/// 待办时间维度（P2：日历切换查看完成/到期/计划）
enum TodoTimeDimension: String, CaseIterable {
    case completed
    case due
    case planned

    /// 对应 TodoTask 实体字段名
    var fieldName: String {
        switch self {
        case .completed: return "completedAt"
        case .due:       return "dueDate"
        case .planned:   return "plannedDate"
        }
    }

    var displayName: String {
        switch self {
        case .completed: return "已完成"
        case .due:       return "到期"
        case .planned:   return "计划"
        }
    }
}

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
    func fetchEvents(in range: DateInterval,
                     todoDimension: TodoTimeDimension = .completed) async -> CalendarEventsResult {
        // 串行：4 模块共享同一 Core Data context，并发访问违反线程安全
        let finance = await fetchFinance(in: range)
        let habit = fetchHabit(in: range)
        let todo = fetchTodo(in: range, dimension: todoDimension)
        let thought = fetchThought(in: range)
        return Self.aggregate(partials: [finance, habit, todo, thought])
    }

    /// 拉取某一天的日历事件（月历当天详情用）
    func fetchDaySummary(_ date: Date,
                         todoDimension: TodoTimeDimension = .completed) async -> CalendarEventsResult {
        await fetchEvents(in: CalendarRangeBuilder.dayRange(date), todoDimension: todoDimension)
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

    /// 待办：按 dimension 选字段（completed/due/planned）取实体
    private func fetchTodo(in range: DateInterval, dimension: TodoTimeDimension) -> Partial {
        let tasks = todoRepo.getTasks(field: dimension.fieldName, from: range.start, to: range.end)
        let events: [CalendarEvent] = tasks.compactMap { task in
            let date: Date?
            switch dimension {
            case .completed: date = task.completedAt
            case .due:       date = task.dueDate
            case .planned:   date = task.plannedDate
            }
            guard let eventDate = date else { return nil }
            return CalendarEvent(
                module: .todo,
                date: eventDate,
                title: task.title,
                detail: dimension.displayName,
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
                // P3：经 Thought.topics 间接体现观点（取所有可见状态的观点标题）
                let topics = (thought.topics as? Set<Topic> ?? [])
                    .filter(\.isVisibleTopic)
                    .map { $0.title }
                    .sorted()
                return CalendarEvent(
                    module: .thought,
                    date: thought.createdAt,
                    title: title,
                    detail: thought.moodType?.displayName,
                    relatedTopics: topics.isEmpty ? nil : topics,
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
