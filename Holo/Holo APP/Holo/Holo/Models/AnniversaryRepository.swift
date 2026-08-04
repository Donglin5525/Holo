//
//  AnniversaryRepository.swift
//  Holo
//
//  纪念日模块数据仓库
//  所有 Core Data 操作均在主线程 viewContext 执行，避免跨线程访问
//

import Foundation
import CoreData
import Combine
import os.log

// MARK: - 通知名称

extension Notification.Name {
    /// 纪念日数据变更通知（新增/编辑/删除时发送）
    static let anniversaryDataDidChange = Notification.Name("anniversaryDataDidChange")
}

// MARK: - AnniversaryRepository

/// 纪念日模块数据仓库
/// 不使用 ObservableObject——数据变更完全靠 NotificationCenter 广播驱动 UI 刷新，
/// 与财务模块（FinanceRepository）保持一致，避免 sheet dismiss 过程中
/// @Published 触发 objectWillChange 导致主线程死锁。
@MainActor
class AnniversaryRepository {

    private let logger = Logger(subsystem: "com.holo.app", category: "AnniversaryRepository")

    // MARK: - Singleton

    static let shared = AnniversaryRepository()

    // MARK: - Properties

    /// 所有有效的纪念日（未删除、未归档）
    private(set) var activeAnniversaries: [Anniversary] = []

    /// 测试可注入独立上下文；生产单例始终使用 CoreDataStack 主上下文。
    private let contextOverride: NSManagedObjectContext?

    var context: NSManagedObjectContext {
        contextOverride ?? CoreDataStack.shared.viewContext
    }

    // MARK: - Initialization

    private init() {
        contextOverride = nil
    }

    /// 模块内测试入口
    init(context: NSManagedObjectContext) {
        self.contextOverride = context
    }

    /// 初始化加载（进入模块时调用）
    func setup() {
        loadActiveAnniversaries()
    }

    // MARK: - 查询

    /// 加载所有有效纪念日（未删除未归档），按业务规则排序
    func loadActiveAnniversaries() {
        activeAnniversaries = allAnniversaries(includeArchived: false, includeDeleted: false)
    }

    /// 查询纪念日
    /// - Parameters:
    ///   - includeArchived: 是否包含已归档
    ///   - includeDeleted: 是否包含已软删除
    /// - Returns: 排序后的纪念日数组
    func allAnniversaries(includeArchived: Bool = false, includeDeleted: Bool = false) -> [Anniversary] {
        let request = Anniversary.fetchRequest()
        var predicates: [NSPredicate] = []
        if !includeDeleted {
            predicates.append(NSPredicate(format: "isSoftDeleted == NO"))
        }
        if !includeArchived {
            predicates.append(NSPredicate(format: "isArchived == NO"))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "isPinned", ascending: false),   // 置顶在前
            NSSortDescriptor(key: "date", ascending: true)          // 按日期
        ]
        return (try? context.fetch(request)) ?? []
    }

    /// 按 ID 获取单个纪念日
    func anniversary(by id: UUID) -> Anniversary? {
        let request = Anniversary.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// 业务排序后的列表（供 UI 展示：置顶在前，再按距今天数升序）
    var sortedForDisplay: [Anniversary] {
        activeAnniversaries.sorted { a, b in
            // 置顶优先
            if a.isPinned != b.isPinned { return a.isPinned }
            // 同置顶状态下，按距今天数升序（倒数在前，累计在后）
            let aDays = a.daysFromToday()
            let bDays = b.daysFromToday()
            // 正数（未来）排在负数（过去）前
            if aDays >= 0 && bDays < 0 { return true }
            if aDays < 0 && bDays >= 0 { return false }
            // 同为正数，小的在前；同为负数，绝对值小的在前（更近的过去）
            return abs(aDays) < abs(bDays)
        }
    }

    // MARK: - CRUD
    // 与 FinanceRepository 完全一致的简单模式：
    // 主线程 viewContext 直接操作，方法 async throws，由调用方包在 Task {} 里执行。
    // 不做后台上下文切换——那是卡死的来源（在主线程直接调 private queue context 的 save）。

    /// 新增纪念日
    /// - Returns: 创建的纪念日对象
    @discardableResult
    func addAnniversary(
        title: String,
        date: Date,
        type: AnniversaryType,
        icon: String? = nil,
        color: String? = nil,
        note: String? = nil,
        isPinned: Bool = false,
        repeatYearly: Bool? = nil,
        reminderEnabled: Bool = false,
        reminderDaysBefore: Int16 = 0,
        generateTask: Bool = false
    ) async throws -> Anniversary {
        let item = Anniversary.create(
            in: context,
            title: title,
            date: date,
            type: type,
            icon: icon,
            color: color,
            note: note,
            isPinned: isPinned,
            repeatYearly: repeatYearly,
            reminderEnabled: reminderEnabled,
            reminderDaysBefore: reminderDaysBefore,
            generateTask: generateTask
        )
        try context.save()
        loadActiveAnniversaries()
        notifyDataChange()
        // 调度通知（纯值快照，跨上下文安全）
        if item.reminderEnabled {
            let payload = TodoNotificationService.AnniversaryReminderPayload(item)
            Task { await TodoNotificationService.shared.scheduleAnniversaryReminder(for: payload) }
        }
        return item
    }

    /// 更新纪念日
    func updateAnniversary(
        _ item: Anniversary,
        title: String? = nil,
        date: Date? = nil,
        type: AnniversaryType? = nil,
        icon: String? = nil,
        color: String? = nil,
        note: String? = nil,
        isPinned: Bool? = nil,
        repeatYearly: Bool? = nil,
        reminderEnabled: Bool? = nil,
        reminderDaysBefore: Int16? = nil,
        generateTask: Bool? = nil
    ) async throws {
        if let title = title { item.title = title }
        if let date = date { item.date = date }
        if let type = type { item.type = type.rawValue }
        if let icon = icon { item.icon = icon }
        if let color = color { item.color = color }
        if let note = note { item.note = note }
        if let isPinned = isPinned { item.isPinned = isPinned }
        if let repeatYearly = repeatYearly { item.repeatYearly = repeatYearly }
        if let reminderEnabled = reminderEnabled { item.reminderEnabled = reminderEnabled }
        if let reminderDaysBefore = reminderDaysBefore { item.reminderDaysBefore = reminderDaysBefore }
        if let generateTask = generateTask { item.generateTask = generateTask }
        item.updatedAt = Date()
        try context.save()
        loadActiveAnniversaries()
        notifyDataChange()
        // 重新调度通知（先取消旧的，再按新配置排）
        TodoNotificationService.shared.cancelAnniversaryReminder(for: item.id)
        if reminderEnabled ?? item.reminderEnabled {
            let payload = TodoNotificationService.AnniversaryReminderPayload(item)
            Task { await TodoNotificationService.shared.scheduleAnniversaryReminder(for: payload) }
        }
    }

    /// 软删除纪念日（移入回收站）
    func softDeleteAnniversary(_ item: Anniversary) async throws {
        item.isSoftDeleted = true
        item.updatedAt = Date()
        try context.save()
        loadActiveAnniversaries()
        notifyDataChange()
        // 取消通知
        TodoNotificationService.shared.cancelAnniversaryReminder(for: item.id)
    }

    /// 切换置顶状态
    func togglePin(_ item: Anniversary) async throws {
        try await updateAnniversary(item, isPinned: !item.isPinned)
    }

    // MARK: - 通知广播

    private func notifyDataChange() {
        // 异步派发：避免在 sheet dismiss 同一帧同步触发列表刷新导致主线程卡死。
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .anniversaryDataDidChange, object: nil)
        }
    }
}
