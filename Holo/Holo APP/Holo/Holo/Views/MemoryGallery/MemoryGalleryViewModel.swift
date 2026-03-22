//
//  MemoryGalleryViewModel.swift
//  Holo
//
//  记忆长廊 ViewModel
//  负责从多个模块获取数据、缓存管理、筛选和分页加载
//

import Foundation
import SwiftUI
import CoreData
import Combine

// MARK: - MemoryGalleryViewModel

@MainActor
class MemoryGalleryViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 分组后的记忆条目
    @Published var sections: [MemoryItemSection] = []

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

    /// 分页大小
    private let pageSize: Int = 30

    /// 当前页偏移
    private var currentOffset: Int = 0

    /// 数据缓存（避免重复查询）
    private var cachedItems: [MemoryItem] = []

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
        // 监听各模块数据变更
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
        // 清除缓存，下次加载时重新获取
        invalidateCache()
        Task {
            await refresh()
        }
    }

    // MARK: - Cache Management

    /// 使缓存失效
    func invalidateCache() {
        cachedItems = []
        cacheTimestamp = nil
    }

    /// 检查缓存是否有效
    private func isCacheValid() -> Bool {
        guard let timestamp = cacheTimestamp else { return false }
        return Date().timeIntervalSince(timestamp) < cacheValidityDuration
    }

    // MARK: - Data Loading

    /// 刷新数据（重新加载第一页）
    func refresh() async {
        currentOffset = 0
        hasMoreData = true
        cachedItems = []
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
            // 如果缓存无效，重新获取所有数据
            if !isCacheValid() || cachedItems.isEmpty {
                cachedItems = try await fetchAllMemoryItems()
                cacheTimestamp = Date()
            }

            // 应用筛选
            let filteredItems = applyFilter(to: cachedItems)

            // 分页
            let startIndex = isLoadMore ? currentOffset : 0
            let endIndex = min(startIndex + pageSize, filteredItems.count)

            if endIndex > startIndex {
                let pageItems = Array(filteredItems[startIndex..<endIndex])

                if isLoadMore {
                    // 追加到现有数据
                    appendItemsToSections(pageItems)
                } else {
                    // 替换现有数据
                    sections = groupItemsByDate(pageItems)
                }

                currentOffset = endIndex
                hasMoreData = endIndex < filteredItems.count
            } else {
                if !isLoadMore {
                    sections = []
                }
                hasMoreData = false
            }
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }

        isLoading = false
        isLoadingMore = false
    }

    // MARK: - Data Fetching

    /// 从所有模块获取记忆条目
    private func fetchAllMemoryItems() async throws -> [MemoryItem] {
        var items: [MemoryItem] = []

        // 并行获取各模块数据
        async let transactions = fetchTransactions()
        async let habitRecords = fetchHabitRecords()
        async let tasks = fetchTasks()

        // 合并结果
        items.append(contentsOf: try await transactions)
        items.append(contentsOf: try await habitRecords)
        items.append(contentsOf: try await tasks)

        // 按日期降序排序
        return items.sorted { $0.date > $1.date }
    }

    /// 获取交易记录
    private func fetchTransactions() async throws -> [MemoryItem] {
        let request = Transaction.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchLimit = 500 // 限制数量，避免性能问题

        let transactions = try context.fetch(request)
        return transactions.map { MemoryItem.from(transaction: $0) }
    }

    /// 获取习惯记录
    private func fetchHabitRecords() async throws -> [MemoryItem] {
        var items: [MemoryItem] = []

        // 获取所有习惯
        let habitRequest = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "isArchived == NO")
        let habits = try context.fetch(habitRequest)

        // 脏获取最近的记录
        let recordRequest = HabitRecord.fetchRequest()
        recordRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        recordRequest.fetchLimit = 500

        let records = try context.fetch(recordRequest)

        // 创建习惯 ID 到习惯的映射
        var habitMap: [UUID: Habit] = [:]
        for habit in habits {
            habitMap[habit.id] = habit
        }

        // 转换记录
        for record in records {
            if let habit = habitMap[record.habitId] {
                items.append(MemoryItem.from(habitRecord: record, habit: habit))
            }
        }

        return items
    }

    /// 获取已完成的任务
    private func fetchTasks() async throws -> [MemoryItem] {
        let request = TodoTask.fetchRequest()
        // 只获取已完成或已过期的任务
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

    /// 应用筛选
    private func applyFilter(to items: [MemoryItem]) -> [MemoryItem] {
        switch moduleFilter {
        case .all:
            return items
        case .transaction:
            return items.filter { $0.type == .transaction }
        case .habitRecord:
            return items.filter { $0.type == .habitRecord }
        case .task:
            return items.filter { $0.type == .task }
        }
    }

    /// 设置模块筛选并刷新
    func setModuleFilter(_ filter: MemoryModuleFilter) async {
        moduleFilter = filter
        currentOffset = 0
        await loadData()
    }

    // MARK: - Grouping

    /// 按日期分组
    private func groupItemsByDate(_ items: [MemoryItem]) -> [MemoryItemSection] {
        let calendar = Calendar.current
        var sectionMap: [Date: [MemoryItem]] = [:]

        for item in items {
            let dayStart = calendar.startOfDay(for: item.date)
            sectionMap[dayStart, default: []].append(item)
        }

        return sectionMap.map { date, items in
            MemoryItemSection(date: date, items: items.sorted { $0.date > $1.date })
        }.sorted { $0.date > $1.date }
    }

    /// 追加条目到现有分组
    private func appendItemsToSections(_ newItems: [MemoryItem]) {
        let calendar = Calendar.current

        for item in newItems {
            let dayStart = calendar.startOfDay(for: item.date)

            if let index = sections.firstIndex(where: { $0.date == dayStart }) {
                sections[index].items.append(item)
                sections[index].items.sort { $0.date > $1.date }
            } else {
                let newSection = MemoryItemSection(date: dayStart, items: [item])
                sections.append(newSection)
                sections.sort { $0.date > $1.date }
            }
        }
    }
}
