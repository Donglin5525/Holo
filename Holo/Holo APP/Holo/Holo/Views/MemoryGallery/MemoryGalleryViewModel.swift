//
//  MemoryGalleryViewModel.swift
//  Holo
//
//  记忆长廊 ViewModel
//  三层叙事时间线：日摘要 → 高亮 → 里程碑
//  复用已有的 MemoryItem 数据获取、缓存、通知骨架
//

import Foundation
import SwiftUI
import CoreData
import Combine

// MARK: - MemoryGalleryViewModel

@MainActor
class MemoryGalleryViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 时间线 section（按日期分组，每个 section 含多种节点）
    @Published var timelineSections: [TimelineSection] = []

    /// 加载状态
    @Published var isLoading: Bool = false

    /// 是否正在加载更多
    @Published var isLoadingMore: Bool = false

    /// 是否还有更多数据
    @Published var hasMoreData: Bool = true

    /// 错误信息
    @Published var errorMessage: String?

    /// 当前模块筛选
    @Published var moduleFilter: MemoryModuleFilter = .all

    /// 是否显示筛选器
    @Published var showFilter: Bool = false

    // MARK: - Private Properties

    /// 分页按天计算（每页加载 N 天的数据）
    private let pageDayCount: Int = 7

    /// 当前已加载到的最早日期偏移（天）
    private var currentDayOffset: Int = 0

    /// 原始记忆条目缓存（按模块聚合用）
    private var cachedItems: [MemoryItem] = []

    /// 缓存的高亮数据 [Date: [HighlightData]]
    private var cachedHighlights: [Date: [HighlightData]] = [:]

    /// 缓存的里程碑数据
    private var cachedMilestones: [(date: Date, data: MilestoneData)] = []

    /// 缓存时间戳
    private var cacheTimestamp: Date?

    /// 缓存有效期（5分钟）
    private let cacheValidityDuration: TimeInterval = 300

    /// Core Data 上下文
    private var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }

    // MARK: - Initialization

    init() {
        setupNotifications()
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDataChange),
            name: .financeDataDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDataChange),
            name: .habitDataDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDataChange),
            name: .todoDataDidChange,
            object: nil
        )
    }

    @objc private func handleDataChange() {
        invalidateCache()
        Task {
            await refresh()
        }
    }

    // MARK: - Cache Management

    func invalidateCache() {
        cachedItems = []
        cachedHighlights = [:]
        cachedMilestones = []
        cacheTimestamp = nil
    }

    private func isCacheValid() -> Bool {
        guard let timestamp = cacheTimestamp else { return false }
        return Date().timeIntervalSince(timestamp) < cacheValidityDuration
    }

    // MARK: - Data Loading

    /// 刷新数据（重新加载第一页）
    func refresh() async {
        currentDayOffset = 0
        hasMoreData = true
        await loadData()
    }

    /// 加载更多数据
    func loadMore() async {
        guard !isLoadingMore && hasMoreData && !isLoading else { return }
        await loadData(isLoadMore: true)
    }

    /// 加载数据
    private func loadData(isLoadMore: Bool = false) async {
        if isLoadMore {
            isLoadingMore = true
        } else {
            isLoading = true
        }
        errorMessage = nil

        do {
            // 缓存无效时重新获取
            if !isCacheValid() || cachedItems.isEmpty {
                cachedItems = try fetchAllMemoryItems()
                cacheTimestamp = Date()

                // 运行高亮和里程碑检测
                let dates = collectUniqueDates(from: cachedItems)
                cachedHighlights = HighlightDetector.detect(
                    for: dates,
                    context: context
                )
                cachedMilestones = MilestoneDetector.detect(context: context)
            }

            // 计算日期范围
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())

            let startOffset = currentDayOffset
            let endOffset = startOffset + pageDayCount

            // 生成时间范围内的 section
            var newSections: [TimelineSection] = []
            for dayIndex in startOffset..<endOffset {
                guard let sectionDate = calendar.date(byAdding: .day, value: -dayIndex, to: today) else { continue }
                let section = TimelineSectionBuilder.buildSection(
                    date: sectionDate,
                    items: filteredItems(for: sectionDate),
                    highlights: filteredHighlights(for: sectionDate),
                    milestones: filteredMilestones(for: sectionDate),
                    moduleFilter: moduleFilter
                )

                // 只添加有节点的 section（至少有日摘要或有高亮/里程碑）
                if !section.nodes.isEmpty {
                    newSections.append(section)
                }
            }

            if isLoadMore {
                timelineSections.append(contentsOf: newSections)
            } else {
                timelineSections = newSections
            }

            currentDayOffset = endOffset
            hasMoreData = currentDayOffset < 365 // 最多加载一年

        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }

        isLoading = false
        isLoadingMore = false
    }

    // MARK: - Data Fetching（复用原有逻辑）

    /// 从所有模块获取记忆条目
    private func fetchAllMemoryItems() throws -> [MemoryItem] {
        var items: [MemoryItem] = []

        items.append(contentsOf: try fetchTransactions())
        items.append(contentsOf: try fetchHabitRecords())
        items.append(contentsOf: try fetchTasks())

        return items.sorted { $0.date > $1.date }
    }

    private func fetchTransactions() throws -> [MemoryItem] {
        let request = Transaction.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchLimit = 500
        let transactions = try context.fetch(request)
        return transactions.map { MemoryItem.from(transaction: $0) }
    }

    private func fetchHabitRecords() throws -> [MemoryItem] {
        var items: [MemoryItem] = []

        let habitRequest = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "isArchived == NO")
        let habits = try context.fetch(habitRequest)

        let recordRequest = HabitRecord.fetchRequest()
        recordRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        recordRequest.fetchLimit = 500
        let records = try context.fetch(recordRequest)

        var habitMap: [UUID: Habit] = [:]
        for habit in habits {
            habitMap[habit.id] = habit
        }

        for record in records {
            if let habit = habitMap[record.habitId] {
                items.append(MemoryItem.from(habitRecord: record, habit: habit))
            }
        }

        return items
    }

    private func fetchTasks() throws -> [MemoryItem] {
        let request = TodoTask.fetchRequest()
        let now = Date()
        request.predicate = NSPredicate(
            format: "(completed == YES) OR (deletedFlag == NO AND archived == NO AND dueDate < %@)",
            now as NSDate
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "completedAt", ascending: false),
            NSSortDescriptor(key: "dueDate", ascending: false)
        ]
        request.fetchLimit = 200
        let tasks = try context.fetch(request)
        return tasks.map { MemoryItem.from(task: $0) }
    }

    // MARK: - Filtering

    /// 设置模块筛选并刷新
    func setModuleFilter(_ filter: MemoryModuleFilter) async {
        moduleFilter = filter
        currentDayOffset = 0
        await loadData()
    }

    /// 获取指定日期的筛选后 MemoryItem
    private func filteredItems(for date: Date) -> [MemoryItem] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        let dayItems = cachedItems.filter { item in
            item.date >= dayStart && item.date < dayEnd
        }

        switch moduleFilter {
        case .all: return dayItems
        case .transaction: return dayItems.filter { $0.type == .transaction }
        case .habitRecord: return dayItems.filter { $0.type == .habitRecord }
        case .task: return dayItems.filter { $0.type == .task }
        }
    }

    /// 获取指定日期的筛选后高亮
    private func filteredHighlights(for date: Date) -> [HighlightData] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let highlights = cachedHighlights[dayStart] ?? []

        switch moduleFilter {
        case .all: return highlights
        case .transaction: return highlights.filter { $0.sourceModule == .transaction }
        case .habitRecord: return highlights.filter { $0.sourceModule == .habitRecord }
        case .task: return highlights.filter { $0.sourceModule == .task }
        }
    }

    /// 获取指定日期的筛选后里程碑
    private func filteredMilestones(for date: Date) -> [MilestoneData] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)

        return cachedMilestones
            .filter { calendar.isDate($0.date, inSameDayAs: dayStart) }
            .map { $0.data }
    }

    // MARK: - Helpers

    /// 从缓存中提取所有唯一起始日日期
    private func collectUniqueDates(from items: [MemoryItem]) -> [Date] {
        let calendar = Calendar.current
        let uniqueDays = Set(items.map { calendar.startOfDay(for: $0.date) })
        return Array(uniqueDays).sorted(by: >)
    }
}

// MARK: - TimelineSectionBuilder

/// 时间线 section 构建器
/// 将原始 MemoryItem + 高亮 + 里程碑 合成为时间线节点
enum TimelineSectionBuilder {

    /// 为某一天构建完整的时间线 section
    static func buildSection(
        date: Date,
        items: [MemoryItem],
        highlights: [HighlightData],
        milestones: [MilestoneData],
        moduleFilter: MemoryModuleFilter
    ) -> TimelineSection {
        var nodes: [MemoryTimelineNode] = []

        // 1. 日摘要节点（始终生成，即使部分数据为空）
        let summaryNode = buildDailySummary(
            date: date,
            items: items,
            moduleFilter: moduleFilter
        )
        nodes.append(summaryNode)

        // 2. 里程碑节点（如有）
        for milestoneData in milestones {
            let node = MemoryTimelineNode(
                date: date,
                type: .milestone,
                data: .milestone(milestoneData)
            )
            nodes.append(node)
        }

        // 3. 高亮节点
        for highlightData in highlights {
            let node = MemoryTimelineNode(
                date: date,
                type: .highlight,
                data: .highlight(highlightData)
            )
            nodes.append(node)
        }

        // 按 sortOrder 排序：日摘要 → 里程碑 → 高亮
        nodes.sort { $0.sortOrder < $1.sortOrder }

        return TimelineSection(date: date, nodes: nodes)
    }

    /// 构建日摘要节点
    private static func buildDailySummary(
        date: Date,
        items: [MemoryItem],
        moduleFilter: MemoryModuleFilter
    ) -> MemoryTimelineNode {
        // 计算各模块统计
        let transactions = items.filter { $0.type == .transaction }
        let habits = items.filter { $0.type == .habitRecord }
        let tasks = items.filter { $0.type == .task }

        // 总消费（仅支出）
        let totalExpense: Decimal? = transactions.isEmpty ? nil : transactions.reduce(Decimal(0)) { sum, item in
            guard let amount = item.amount else { return sum }
            return sum + amount
        }

        // 习惯完成数（简化：按有记录的习惯计数）
        let habitsCompleted = habits.filter { $0.subtitle != "未完成" }.count
        let habitsTotal = habits.count

        // 任务完成数
        let tasksCompleted = tasks.filter { $0.subtitle == "已完成" }.count

        let summaryData = DailySummaryData(
            totalExpense: totalExpense,
            habitsCompleted: habitsCompleted,
            habitsTotal: habitsTotal,
            tasksCompleted: tasksCompleted
        )

        return MemoryTimelineNode(
            date: date,
            type: .dailySummary,
            data: .summary(summaryData)
        )
    }
}
