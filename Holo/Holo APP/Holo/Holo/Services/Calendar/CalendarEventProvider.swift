//
//  CalendarEventProvider.swift
//  Holo
//
//  日历事件聚合层：把记账/习惯/待办/想法 4 模块按区间聚合成 [CalendarEvent]。
//
//  关键设计：
//  1. 在同一个后台 context 串行查询四模块，主线程只接收值快照。
//  2. 每个模块独立 do-catch，失败在 moduleStates 标 .failed，不静默丢（避免"今天没待办"误读）。
//  3. aggregate 为纯函数，便于单测覆盖失败态/排序/empty。
//  4. P2：待办支持 todoDimension（completed/due/planned）切换时间字段。
//

import Foundation
import CoreData
import os.log

/// 待办时间维度（日历切换查看完成/到期）
enum TodoTimeDimension: String, CaseIterable {
    case completed
    case due

    /// 对应 TodoTask 实体字段名
    var fieldName: String {
        switch self {
        case .completed: return "completedAt"
        case .due:       return "dueDate"
        }
    }

    var displayName: String {
        switch self {
        case .completed: return String(localized: "已完成")
        case .due:       return String(localized: "到期")
        }
    }
}

struct CalendarEventProvider {

    private let coordinator: NSPersistentStoreCoordinator?

    /// 只借用持久化存储，不把主上下文或仓库中的托管对象带到后台。
    init(context: NSManagedObjectContext) {
        coordinator = context.persistentStoreCoordinator
    }

    /// 保留既有测试注入入口；四模块都来自同一个生活数据存储。
    init(financeRepo: FinanceRepository, habitRepo: HabitRepository,
         todoRepo: TodoRepository, thoughtRepo: ThoughtRepository) {
        self.init(context: financeRepo.context)
    }

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
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.undoManager = nil
        return await context.perform {
            // 查询、关系读取和映射都在私有队列内完成；只返回值快照与 objectID。
            defer { context.reset() }
            return Self.aggregate(partials: [
                Self.fetchFinance(in: range, context: context),
                Self.fetchHabit(in: range, context: context),
                Self.fetchTodo(in: range, dimension: todoDimension, context: context),
                Self.fetchThought(in: range, context: context)
            ])
        }
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
    private static func fetchFinance(in range: DateInterval, context: NSManagedObjectContext) -> Partial {
        do {
            let request = Transaction.fetchRequest()
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "date >= %@ AND date < %@", range.start as NSDate, range.end as NSDate),
                FinanceTransactionOccurrencePolicy.occurredPredicate(),
                NSPredicate(format: "deletedAt == nil")
            ])
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            request.relationshipKeyPathsForPrefetching = ["category", "account"]
            let txns = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
            let events: [CalendarEvent] = txns.map { txn in
                let categoryName = txn.category?.name ?? "未分类"
                let note = txn.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let genericCategories = Set(["其他", "未分类"])
                let fallbackTitle = txn.transactionType == .expense ? String(localized: "一笔支出") : String(localized: "一笔收入")
                let title = note.isEmpty
                    ? (genericCategories.contains(categoryName) ? fallbackTitle : categoryName)
                    : note

                var contextParts: [String] = []
                if title != categoryName { contextParts.append(categoryName) }
                if let remark = txn.remark?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !remark.isEmpty,
                   remark != title {
                    contextParts.append(remark)
                }
                if let account = txn.account, !account.isDefault {
                    contextParts.append(account.name)
                }

                return CalendarEvent(
                    id: txn.id,
                    module: .finance,
                    date: txn.date,
                    title: title,
                    detail: txn.formattedAmountWithSign,
                    context: contextParts.isEmpty ? nil : contextParts.joined(separator: " · "),
                    numericValue: txn.amountAsDecimal,
                    valueDirection: txn.transactionType == .expense ? .negative : .positive,
                    originID: txn.objectID
                )
            }
            return Partial(module: .finance, events: events, state: events.isEmpty ? .empty : .loaded)
        } catch {
            Self.logger.error("日历·记账加载失败：\(String(describing: error))")
            return Partial(module: .finance, events: [], state: .failed(message: String(localized: "记账加载失败")))
        }
    }

    /// 习惯：getActiveHabits 建 habitMap → getRecords(from:to:) 反查
    private static func fetchHabit(in range: DateInterval, context: NSManagedObjectContext) -> Partial {
        do {
            let habitRequest = Habit.fetchRequest()
            habitRequest.predicate = NSPredicate(format: "isArchived == NO AND deletedAt == nil")
            let habits = DuplicateRowFilter.deduplicatingCopies(try context.fetch(habitRequest))
            let habitMap = Dictionary(habits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let request = HabitRecord.fetchRequest()
            request.predicate = NSPredicate(format: "date >= %@ AND date < %@ AND deletedAt == nil",
                                            range.start as NSDate, range.end as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            let records = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
            let events: [CalendarEvent] = records.compactMap { record in
                guard let habit = habitMap[record.habitId] else { return nil }
                if habit.isCheckInType, !record.isCompleted { return nil }
                let value = habit.isNumericType ? record.valueDouble : nil
                return CalendarEvent(
                    id: record.id, module: .habit, date: record.date,
                    title: habit.name,
                    detail: HabitValueText.detail(value: value, unit: habit.unit, isCheckIn: habit.isCheckInType),
                    sourceIconEmoji: EmojiCatalog.isEmojiIcon(habit.icon) ? habit.icon : nil,
                    habitAggregation: HabitDayAggregationContext(
                        habitID: habit.id, isCountType: habit.isCountType,
                        isCheckIn: habit.isCheckInType, unit: habit.unit, value: value
                    ),
                    originID: record.objectID
                )
            }
            return Partial(module: .habit, events: events, state: events.isEmpty ? .empty : .loaded)
        } catch {
            Self.logger.error("日历·习惯加载失败：\(String(describing: error))")
            return Partial(module: .habit, events: [], state: .failed(message: String(localized: "习惯加载失败")))
        }
    }

    /// 待办：按 dimension 选字段（completed/due）取实体
    private static func fetchTodo(in range: DateInterval, dimension: TodoTimeDimension,
                                  context: NSManagedObjectContext) -> Partial {
        do {
            let request = TodoTask.fetchRequest()
            request.predicate = NSPredicate(format: "%K >= %@ AND %K < %@ AND deletedAt == nil AND archived == NO",
                                            dimension.fieldName, range.start as NSDate,
                                            dimension.fieldName, range.end as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: dimension.fieldName, ascending: true)]
            let tasks = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
            let events: [CalendarEvent] = tasks.compactMap { task in
                let date = dimension == .completed ? task.completedAt : task.dueDate
                guard let eventDate = date else { return nil }
                return CalendarEvent(id: task.id, module: .todo, date: eventDate, title: task.title,
                                     detail: dimension.displayName, originID: task.objectID)
            }
            return Partial(module: .todo, events: events, state: events.isEmpty ? .empty : .loaded)
        } catch {
            Self.logger.error("日历·待办加载失败：\(String(describing: error))")
            return Partial(module: .todo, events: [], state: .failed(message: String(localized: "待办加载失败")))
        }
    }

    /// 想法：按 createdAt 区间取实体
    private static func fetchThought(in range: DateInterval, context: NSManagedObjectContext) -> Partial {
        do {
            let thoughtRepo = ThoughtRepository(context: context)
            let thoughts = try thoughtRepo.fetchThoughts(from: range.start, to: range.end)
            // 册页风照片堆：消费已生成的 300×300 缩略图（imageData 原图不进长廊列表）。
            // 走附件投影查询——读托管对象会把附件整行（含原图大二进制）拉进内存。
            let thumbnailsByThought = try thoughtRepo.fetchAttachmentThumbnails(
                from: range.start, to: range.end
            )
            let events: [CalendarEvent] = thoughts.map { thought in
                let title = thought.previewText.isEmpty ? String(localized: "未命名想法") : thought.previewText
                // P3：观点的主题标题（读源统一 P0-A：link 投影，与卡片徽章同口径）
                let effectiveTopics = ThoughtTopicLinkProjection.effectiveTopics(for: thought)
                    .filter(\.isVisibleTopic)
                let topics = effectiveTopics.map { $0.title }.sorted()
                // 主题徽章带 emoji（TopicIconProvider 同口径：用户设置 > 预设 > 关键词 > 哈希兜底）
                let topicBadges = effectiveTopics
                    .map { CalendarTopicBadge(title: $0.title, emoji: TopicIconProvider.icon(for: $0)) }
                    .sorted { $0.title < $1.title }
                // 自建 tag 外显：已被合并重定向的概念不显示旧名（目标概念若有关自然会出现）
                let tagBadges = ((thought.tags as? Set<ThoughtTag>) ?? [])
                    .filter { $0.mergedIntoTagID == nil }
                    .map { CalendarTagBadge(name: $0.name, colorHex: $0.color) }
                    .sorted { $0.name < $1.name }
                let quotes = Self.referenceQuotes(richContentJSON: thought.richContentJSON)
                return CalendarEvent(
                    id: thought.id,
                    module: .thought,
                    date: thought.createdAt,
                    title: title,
                    detail: thought.moodType?.displayName,
                    relatedTopics: topics.isEmpty ? nil : topics,
                    topicBadges: topicBadges.isEmpty ? nil : topicBadges,
                    tagBadges: tagBadges.isEmpty ? nil : tagBadges,
                    attachmentThumbnails: thumbnailsByThought[thought.id] ?? [],
                    thoughtReferenceQuotes: quotes,
                    originID: thought.objectID
                )
            }
            return Partial(module: .thought, events: events, state: events.isEmpty ? .empty : .loaded)
        } catch {
            Self.logger.error("日历·想法加载失败：\(String(describing: error))")
            return Partial(module: .thought, events: [], state: .failed(message: String(localized: "想法加载失败")))
        }
    }

    /// 正文 @ 引用的被引内容摘要：与编辑器 Token 操作面板的「来源」行同口径——
    /// 显示名走统一规则（优先标题、缺了用快照首行兜底），来源行与显示名同文时不再重复。
    private static func referenceQuotes(richContentJSON: String?) -> [ThoughtReferenceQuote] {
        guard let richContentJSON, !richContentJSON.isEmpty,
              let nodes = try? RichContentSerializer.nodes(fromJSONString: richContentJSON) else {
            return []
        }
        return nodes.compactMap { node in
            guard case .reference(_, let displayText, let snapshot) = node else { return nil }
            let display = RichContentSerializer.normalizedReferenceDisplayText(
                displayText: displayText,
                snapshot: snapshot
            )
            let sourceLine = RichContentSerializer.firstLine(fromPlainText: snapshot)
            let normalizedSource = sourceLine.hasPrefix("@") ? String(sourceLine.dropFirst()) : sourceLine
            let source: String? = (normalizedSource.isEmpty || normalizedSource == display) ? nil : normalizedSource
            return ThoughtReferenceQuote(displayText: display, sourceLine: source)
        }
    }
}

// MARK: - 习惯数值文本（单一真源）

/// 习惯数值的人性化文本：单条事件、聚合行与旧 MemoryItem 共用同一口径。
/// 2026-11-16 东林实报「1.0 支不是人话」——整数去小数点、真小数保留、聚合按次数说。
enum HabitValueText {

    /// 1.0 → "1"，71.5 → "71.5"，71.50 → "71.5"（最多两位小数、去尾随零）
    static func numberText(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        let two = String(format: "%.2f", value)
        return two.hasSuffix("0") ? String(format: "%.1f", value) : two
    }

    /// 数值 + 单位（有单位拼空格「3 支」；无单位返回纯数字）
    static func valueText(_ value: Double, unit: String?) -> String {
        let u = unit?.trimmingCharacters(in: .whitespaces) ?? ""
        return u.isEmpty ? numberText(value) : numberText(value) + " " + u
    }

    /// 单条事件副信息
    static func detail(value: Double?, unit: String?, isCheckIn: Bool) -> String? {
        if let value { return valueText(value, unit: unit) }
        if isCheckIn { return String(localized: "已完成") }
        return nil
    }

    /// 聚合行副信息：计数类求和（无单位按次数说「N 次」）、测量类取最后一次、打卡类计次。
    /// 全空数值的组退回按次数说，不显示误导性的「0」。
    static func aggregatedDetail(values: [Double?], isCountType: Bool, isCheckIn: Bool, unit: String?) -> String? {
        let count = values.count
        if isCheckIn { return String(localized: "\(count) 次") }
        if isCountType {
            let numbers = values.compactMap { $0 }.filter(\.isFinite)
            guard !numbers.isEmpty else { return String(localized: "\(count) 次") }
            let u = unit?.trimmingCharacters(in: .whitespaces) ?? ""
            if u.isEmpty { return String(localized: "\(count) 次") }
            return valueText(numbers.reduce(0, +), unit: unit)
        }
        if let last = values.compactMap { $0 }.filter(\.isFinite).last {
            return valueText(last, unit: unit)
        }
        return String(localized: "\(count) 次")
    }
}

// MARK: - 同日同习惯合并（长廊展示层纯函数）

/// 把同一天内同一习惯的多条事件合并成一行：计数类求和、测量类取最后一次、打卡类计次，
/// 口径与 HabitNumericAggregator 同源。只作用于长廊时间线渲染——月历热度、日回放与
/// 统计口径仍按原始 1:1 事件计算，不受合并影响（2026-11-16 东林拍板：戒烟不平铺 1.0）。
enum CalendarHabitDayMerger {

    /// 输入一天的事件，同习惯多条合并为一行；非习惯事件原样保留。输出按时间升序。
    static func mergeDay(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var passthrough: [CalendarEvent] = []
        var groups: [UUID: [CalendarEvent]] = [:]
        for event in events {
            if event.module == .habit, let ctx = event.habitAggregation {
                groups[ctx.habitID, default: []].append(event)
            } else {
                passthrough.append(event)
            }
        }
        var merged: [CalendarEvent] = passthrough
        for group in groups.values {
            if group.count > 1 {
                merged.append(aggregate(group))
            } else {
                merged.append(contentsOf: group)
            }
        }
        return merged.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString }
    }

    /// 聚合行锚定最后一条（最新时刻）；id/originID 同取最后一条（点行回查最新记录）。
    private static func aggregate(_ group: [CalendarEvent]) -> CalendarEvent {
        let ordered = group.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString }
        guard let last = ordered.last else { return group[0] }
        guard let ctx = last.habitAggregation else { return last }
        let moments = ordered.map { event in
            CalendarHabitMoment(
                date: event.date,
                valueText: event.habitAggregation?.value.flatMap { HabitValueText.valueText($0, unit: ctx.unit) }
            )
        }
        return CalendarEvent(
            id: last.id,
            module: .habit,
            date: last.date,
            title: last.title,
            detail: HabitValueText.aggregatedDetail(
                values: ordered.map { $0.habitAggregation?.value },
                isCountType: ctx.isCountType, isCheckIn: ctx.isCheckIn, unit: ctx.unit
            ),
            context: last.context,
            sourceIconEmoji: last.sourceIconEmoji,
            habitAggregation: last.habitAggregation,
            habitMoments: moments,
            originID: last.originID
        )
    }
}
