//
//  HabitRepository.swift
//  Holo
//
//  习惯功能数据仓库
//  所有 Core Data 操作均在主线程 viewContext 执行，避免跨线程访问
//

import Foundation
import CoreData
import Combine
import os.log

// MARK: - 通知名称

extension Notification.Name {
    /// 习惯数据变更通知（新增/编辑/删除习惯或记录时发送）
    static let habitDataDidChange = Notification.Name("habitDataDidChange")
}

// MARK: - HabitRepository

/// 习惯功能数据仓库
/// 使用 @MainActor 保证所有操作在主线程执行
@MainActor
class HabitRepository: ObservableObject {

    private let logger = Logger(subsystem: "com.holo.app", category: "HabitRepository")

    // MARK: - Singleton

    static let shared = HabitRepository()
    
    // MARK: - Published Properties
    
    /// 当前活跃（未归档）的习惯列表
    @Published var activeHabits: [Habit] = []
    @Published private(set) var isReady: Bool = false
    
    // MARK: - Properties
    
    /// 主上下文（延迟初始化，避免进入模块前就阻塞主线程）
    lazy var context: NSManagedObjectContext = CoreDataStack.shared.viewContext
    
    // MARK: - Initialization
    
    private init() {}

    /// 注入自定义 context（测试用 in-memory；生产仍走 shared 单例）
    /// 与 Finance/Todo/Thought 等其他 Repository 保持一致的注入入口，
    /// 用于在不污染单例的前提下跑隔离测试
    init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Repository 的资源都由 ARC/Core Data 自行释放，无需切回主执行器做析构。
    /// 显式使用 nonisolated 可避开旧系统兼容析构 thunk 在 XCTest 宿主中的重复释放崩溃。
    nonisolated deinit {}

    func setup() {
        guard !isReady else { return }
        _ = context
        loadActiveHabits()
        isReady = true
    }
    
    // MARK: - 数据加载
    
    /// 加载活跃习惯列表
    func loadActiveHabits() {
        if !isReady {
            _ = context
        }
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "isArchived == NO")
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        
        do {
            activeHabits = try context.fetch(request)
        } catch {
            logger.error("加载习惯失败: \(error)")
            activeHabits = []
        }
    }
    
    // MARK: - Habit CRUD
    
    /// 创建新习惯
    /// - Parameters:
    ///   - name: 习惯名称
    ///   - icon: SF Symbol 图标名
    ///   - color: Hex 颜色值
    ///   - type: 习惯类型
    ///   - frequency: 频率
    ///   - targetCount: 目标次数（打卡型）
    ///   - targetValue: 目标数值（数值型）
    ///   - unit: 单位（数值型）
    ///   - aggregationType: 聚合类型（数值型）
    /// - Returns: 新建的习惯
    @discardableResult
    func createHabit(
        name: String,
        icon: String,
        color: String,
        type: HabitType,
        frequency: HabitFrequency = .daily,
        targetCount: Int? = nil,
        targetValue: Double? = nil,
        unit: String? = nil,
        aggregationType: HabitAggregationType = .sum,
        isBadHabit: Bool = false
    ) throws -> Habit {
        if !isReady { setup() }
        // 计算新的排序顺序
        let maxSortOrder = activeHabits.map { $0.sortOrder }.max() ?? -1
        
        let habit = Habit.create(
            in: context,
            name: name,
            icon: icon,
            color: color,
            type: type,
            frequency: frequency,
            targetCount: targetCount,
            targetValue: targetValue,
            unit: unit,
            aggregationType: aggregationType,
            isBadHabit: isBadHabit,
            sortOrder: maxSortOrder + 1
        )
        
        try context.save()
        loadActiveHabits()
        // 新建习惯需出现在今日看板；看板白名单非空时自动纳入（不限频率），避免新建后看不到
        HabitStatsDisplaySettings.shared.addDashboardHabitIfNeeded(habit.id)
        notifyDataChange(habitId: habit.id)

        return habit
    }
    
    /// 更新习惯
    func updateHabit(_ habit: Habit, updates: HabitUpdates) throws {
        if !isReady { setup() }
        if let name = updates.name { habit.name = name }
        if let icon = updates.icon { habit.icon = icon }
        if let color = updates.color { habit.color = color }
        if let frequency = updates.frequency { habit.frequency = frequency.rawValue }
        if let targetCount = updates.targetCount { habit.targetCount = NSNumber(value: targetCount) }
        if let targetValue = updates.targetValue { habit.targetValue = NSNumber(value: targetValue) }
        if let unit = updates.unit { habit.unit = unit }
        if let aggregationType = updates.aggregationType { habit.aggregationType = aggregationType.rawValue }
        if let isBadHabit = updates.isBadHabit { habit.isBadHabit = isBadHabit }
        
        habit.updatedAt = Date()
        
        try context.save()
        loadActiveHabits()
        notifyDataChange(habitId: habit.id)
    }
    
    /// 归档习惯（软删除）
    func archiveHabit(_ habit: Habit) throws {
        if !isReady { setup() }
        habit.isArchived = true
        habit.updatedAt = Date()
        
        try context.save()
        loadActiveHabits()
        notifyDataChange(habitId: habit.id)
    }
    
    /// 恢复归档的习惯
    func unarchiveHabit(_ habit: Habit) throws {
        if !isReady { setup() }
        habit.isArchived = false
        habit.updatedAt = Date()
        
        try context.save()
        loadActiveHabits()
        notifyDataChange(habitId: habit.id)
    }
    
    /// 删除习惯（硬删除，会级联删除所有记录）
    func deleteHabit(_ habit: Habit) throws {
        if !isReady { setup() }
        let habitId = habit.id
        context.delete(habit)
        
        try context.save()
        loadActiveHabits()
        notifyDataChange(habitId: habitId)
    }
    
    /// 通过 ID 删除习惯（安全方法，用于视图 dismiss 后的延迟删除）
    func deleteHabitById(_ habitId: UUID) throws {
        if !isReady { setup() }
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", habitId as CVarArg)
        request.fetchLimit = 1
        
        guard let habit = try context.fetch(request).first else {
            return  // 习惯不存在，可能已被删除
        }
        
        context.delete(habit)
        try context.save()
        loadActiveHabits()
        notifyDataChange(habitId: habitId)
    }
    
    /// 通过 ID 归档习惯（安全方法，用于视图 dismiss 后的延迟归档）
    func archiveHabitById(_ habitId: UUID) throws {
        if !isReady { setup() }
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", habitId as CVarArg)
        request.fetchLimit = 1
        
        guard let habit = try context.fetch(request).first else {
            return  // 习惯不存在
        }
        
        habit.isArchived = true
        habit.updatedAt = Date()
        
        try context.save()
        loadActiveHabits()
        notifyDataChange(habitId: habitId)
    }
    
    /// 更新习惯排序
    func updateHabitOrder(_ habits: [Habit]) throws {
        if !isReady { setup() }
        for (index, habit) in habits.enumerated() {
            habit.sortOrder = Int16(index)
        }
        
        try context.save()
        loadActiveHabits()
    }
    
    // MARK: - Record Operations
    
    /// 打卡（打卡型习惯）- 切换今日完成状态
    /// - Parameters:
    ///   - habit: 习惯
    ///   - note: 本次打卡备注（取消打卡时忽略；AI/手动补备注传入）
    /// - Returns: 当前完成状态
    @discardableResult
    func toggleCheckIn(for habit: Habit, note: String? = nil) throws -> Bool {
        if !isReady { setup() }
        guard habit.isCheckInType else { return false }

        // 查找今日记录
        if let existingRecord = findTodayCheckInRecord(for: habit) {
            // 切换完成状态（取消打卡保留原备注）
            existingRecord.isCompleted.toggle()
            if existingRecord.isCompleted, let note, !note.isEmpty {
                existingRecord.note = note
            }
            try context.save()
            notifyDataChange(habitId: habit.id)
            return existingRecord.isCompleted
        } else {
            // 创建新记录（默认已完成）
            _ = HabitRecord.createCheckIn(in: context, habit: habit, isCompleted: true, note: note)
            try context.save()
            notifyDataChange(habitId: habit.id)
            return true
        }
    }
    
    /// 添加数值记录（数值型习惯）
    /// - Parameters:
    ///   - habit: 习惯
    ///   - value: 数值
    ///   - note: 备注
    /// - Returns: 新建的记录
    @discardableResult
    func addNumericRecord(for habit: Habit, value: Double, note: String? = nil) throws -> HabitRecord {
        let record = HabitRecord.createNumeric(in: context, habit: habit, value: value, note: note)
        
        try context.save()
        notifyDataChange(habitId: habit.id)
        
        return record
    }
    
    /// 快捷 +1（计数类数值型习惯）
    @discardableResult
    func incrementCount(for habit: Habit, by amount: Int = 1) throws -> HabitRecord {
        return try addNumericRecord(for: habit, value: Double(amount))
    }
    
    /// 删除记录
    func deleteRecord(_ record: HabitRecord) throws {
        let habitId = record.habitId
        context.delete(record)
        try context.save()
        notifyDataChange(habitId: habitId)
    }

    /// 撤销今日最近一笔记录（数值型习惯误记 / 多 +1 时回退用）
    /// - 删除今日该习惯 date 最大的一条记录，今日进度统计随之自动重算
    /// - Returns: 是否成功删除（false = 今日无记录可删，不抛错）
    @discardableResult
    func removeLatestTodayRecord(for habit: Habit) throws -> Bool {
        if !isReady { setup() }
        // 历史迁移或同步可能留下空值记录；撤销只针对最新一笔有效数值记录
        guard let latest = getTodayRecords(for: habit).first(where: { $0.valueDouble?.isFinite == true }) else {
            return false
        }
        context.delete(latest)
        try context.save()
        notifyDataChange(habitId: habit.id)
        return true
    }
    
    /// 更新记录
    func updateRecord(_ record: HabitRecord, value: Double?, note: String?) throws {
        if let value = value {
            record.value = NSNumber(value: value)
        }
        record.note = note

        try context.save()
        notifyDataChange(habitId: record.habitId)
    }

    // MARK: - 补签（Retroactive Check-in）

    /// 补签写入结果
    enum RetroactiveCheckInResult {
        /// 成功（打卡型附带连续天数恢复前后的值，供 UI 反馈）
        case success(streakBefore: Int, streakAfter: Int)
        /// 目标日已有完成记录：幂等返回，不写入不扣额度
        case alreadyCompleted
        /// 日期不在可补窗口内（仅最近 7 天的过去日期）
        case invalidDate
        /// 免费额度已用完（UI 层接到此结果应走付费墙）
        case requiresPlus
    }

    /// 最近 7 天内可补签的日期（升序，元素为 startOfDay）
    /// - 打卡型：仅每日好习惯返回漏卡日；weekly/monthly 有周期弹性，无「漏卡」概念
    /// - 数值型：当天无任何记录的日子
    /// - 坏习惯不参与补签（「补做坏事」无意义）
    /// - 早于习惯创建日的日子不算漏卡
    func retroactiveEligibleDays(for habit: Habit) -> [Date] {
        guard retroactiveSupported(habit) else { return [] }
        // 打卡型仅每日习惯有「漏卡」概念；weekly/monthly 周期内有弹性，少一天不算漏
        if habit.isCheckInType && habit.habitFrequency != .daily { return [] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let createdDay = calendar.startOfDay(for: habit.createdAt)

        // 一次取回窗口内该习惯的全部记录，内存判定逐日是否可补
        guard let windowStart = calendar.date(byAdding: .day, value: -(HabitRetroactivePolicy.lookbackDays - 1), to: today) else {
            return []
        }
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(
            format: "habitId == %@ AND date >= %@ AND date < %@",
            habit.id as CVarArg,
            windowStart as NSDate,
            today as NSDate
        )
        let records = (try? context.fetch(request)) ?? []

        var daysWithCompletion: Set<Date> = []   // 打卡型：该日有完成记录
        var daysWithAnyRecord: Set<Date> = []    // 数值型：该日有任何记录
        for record in records {
            let day = calendar.startOfDay(for: record.date)
            if record.isCompleted { daysWithCompletion.insert(day) }
            daysWithAnyRecord.insert(day)
        }

        var eligible: [Date] = []
        for offset in stride(from: -(HabitRetroactivePolicy.lookbackDays - 1), through: -1, by: 1) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            guard day >= createdDay else { continue }
            if habit.isCheckInType {
                if !daysWithCompletion.contains(day) { eligible.append(day) }
            } else {
                if !daysWithAnyRecord.contains(day) { eligible.append(day) }
            }
        }
        return eligible
    }

    /// 补签目标日是否落在可补窗口内（最近 7 天的过去日期）
    func isRetroactiveWindowValid(_ day: Date) -> Bool {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: Date())
        guard dayStart < today else { return false }
        guard let earliest = calendar.date(byAdding: .day, value: -(HabitRetroactivePolicy.lookbackDays - 1), to: today) else {
            return false
        }
        return dayStart >= earliest
    }

    /// 预览补签后的连续天数：借助未保存的 pending 记录让既有 streak 算法「看到」补签效果，
    /// 算完立即删除，不留痕。仅打卡型有意义。
    func simulateStreakAfterRetroactiveCheckIn(for habit: Habit, on day: Date) -> (before: Int, after: Int) {
        guard habit.isCheckInType else { return (0, 0) }
        let before = calculateStreakInfo(for: habit).value

        let pending = HabitRecord.createRetroactiveCheckIn(in: context, habit: habit, on: day)
        let after = calculateStreakInfo(for: habit).value
        context.delete(pending)

        return (before, after)
    }

    /// 执行补签写入（额度校验、幂等、通知都在这）
    /// - Parameters:
    ///   - habit: 目标习惯
    ///   - day: 补签目标日（startOfDay）
    ///   - value: 数值型补签值（计数型默认 1；打卡型忽略）
    ///   - note: 备注（可选）
    ///   - allowsFullHistory: true = 补记模式，不限 7 天窗口（创建日 ~ 昨天任意一天）
    @discardableResult
    func retroactiveCheckIn(
        for habit: Habit,
        on day: Date,
        value: Double? = nil,
        note: String? = nil,
        allowsFullHistory: Bool = false
    ) throws -> RetroactiveCheckInResult {
        guard retroactiveSupported(habit) else { return .invalidDate }
        // 早于习惯创建日的日期不可补（那时习惯还不存在）
        guard day >= Calendar.current.startOfDay(for: habit.createdAt) else { return .invalidDate }
        if allowsFullHistory {
            // 补记：只要早于今天即可（今天请直接打卡）
            let calendar = Calendar.current
            guard calendar.startOfDay(for: day) < calendar.startOfDay(for: Date()) else { return .invalidDate }
        } else {
            guard isRetroactiveWindowValid(day) else { return .invalidDate }
        }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return .invalidDate }

        // 额度：Plus 无限；免费用尽返回 requiresPlus，由 UI 层弹付费墙
        let isPlus = HoloEntitlementState.shared.isPlusActive
        if !isPlus, HabitRetroactiveQuota.remaining() <= 0 {
            return .requiresPlus
        }

        let streakBefore = calculateStreakInfo(for: habit).value

        if habit.isCheckInType {
            // 当天已有完成记录 → 幂等返回
            let request = HabitRecord.fetchRequest()
            request.predicate = NSPredicate(
                format: "habitId == %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
                habit.id as CVarArg,
                dayStart as NSDate,
                dayEnd as NSDate
            )
            request.fetchLimit = 1
            if ((try? context.fetch(request))?.count ?? 0) > 0 {
                return .alreadyCompleted
            }

            // 当天存在「取消态」记录（曾打卡又取消）时复用它，保持一天一条的数据形态
            let existing = HabitRecord.fetchRequest()
            existing.predicate = NSPredicate(
                format: "habitId == %@ AND date >= %@ AND date < %@",
                habit.id as CVarArg,
                dayStart as NSDate,
                dayEnd as NSDate
            )
            existing.fetchLimit = 1
            if let canceled = try context.fetch(existing).first {
                canceled.isCompleted = true
                canceled.isRetroactive = true
                if let note, !note.isEmpty { canceled.note = note }
            } else {
                _ = HabitRecord.createRetroactiveCheckIn(in: context, habit: habit, on: dayStart, note: note)
            }
        } else {
            // 数值型：计数类默认补 1 次；测量类必须带值
            let numericValue: Double
            if let value {
                numericValue = value
            } else if habit.isCountType {
                numericValue = 1
            } else {
                return .invalidDate
            }
            _ = HabitRecord.createRetroactiveNumeric(in: context, habit: habit, on: dayStart, value: numericValue, note: note)
        }

        try context.save()
        if !isPlus { HabitRetroactiveQuota.consume() }
        notifyDataChange(habitId: habit.id)

        let streakAfter = habit.isCheckInType ? calculateStreakInfo(for: habit).value : 0
        return .success(streakBefore: streakBefore, streakAfter: streakAfter)
    }

    /// 该习惯是否支持补签：打卡型/数值型的好习惯（坏习惯不参与）
    private func retroactiveSupported(_ habit: Habit) -> Bool {
        guard !habit.isBadHabit else { return false }
        return habit.isCheckInType || habit.isNumericType
    }
    
    // MARK: - Query Methods
    
    /// 查找今日打卡记录
    func findTodayCheckInRecord(for habit: Habit) -> HabitRecord? {
        let today = Calendar.current.startOfDay(for: Date())
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) else {
            return nil
        }
        
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(
            format: "habitId == %@ AND date >= %@ AND date < %@",
            habit.id as CVarArg,
            today as NSDate,
            tomorrow as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchLimit = 1
        
        return try? context.fetch(request).first
    }
    
    /// 获取今日所有记录（数值型习惯）
    func getTodayRecords(for habit: Habit) -> [HabitRecord] {
        let today = Calendar.current.startOfDay(for: Date())
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) else {
            return []
        }
        
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(
            format: "habitId == %@ AND date >= %@ AND date < %@",
            habit.id as CVarArg,
            today as NSDate,
            tomorrow as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        
        return (try? context.fetch(request)) ?? []
    }
    
    /// 获取指定日期范围的记录
    func getRecords(for habit: Habit, in range: ClosedRange<Date>?) -> [HabitRecord] {
        let request = HabitRecord.fetchRequest()
        
        if let range = range {
            request.predicate = NSPredicate(
                format: "habitId == %@ AND date >= %@ AND date <= %@",
                habit.id as CVarArg,
                range.lowerBound as NSDate,
                range.upperBound as NSDate
            )
        } else {
            request.predicate = NSPredicate(format: "habitId == %@", habit.id as CVarArg)
        }
        
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        
        return (try? context.fetch(request)) ?? []
    }
    
    /// 获取所有记录（按时间倒序）
    func getAllRecords(for habit: Habit) -> [HabitRecord] {
        return getRecords(for: habit, in: nil)
    }

    /// 获取指定时间范围内的所有习惯记录（不带 habitId 过滤，跨习惯；半开区间 [start, end)）
    ///
    /// 用于日历聚合：遍历所有习惯打卡记录。习惯名等信息由调用方用 habitMap 反查
    /// （不依赖 record.habit 关系，复刻 fetchHabitRecords() 的稳定做法）。
    /// 注意：与 getRecords(for:in:) 的闭区间不同，这里用半开 [start, end) 统一日历语义。
    func getRecords(from start: Date, to end: Date) -> [HabitRecord] {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@",
            start as NSDate,
            end as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// 获取所有未归档习惯（用于日历聚合建 habitMap 反查 record.habitId → Habit）
    func getActiveHabits() -> [Habit] {
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "isArchived == NO")
        return (try? context.fetch(request)) ?? []
    }
    
    // MARK: - Statistics
    
    /// 获取今日完成状态（打卡型）
    func isTodayCompleted(for habit: Habit) -> Bool {
        guard habit.isCheckInType else { return false }
        return findTodayCheckInRecord(for: habit)?.isCompleted ?? false
    }
    
    /// 获取今日数值（数值型）
    /// - 计数类：返回今日总和
    /// - 测量类：返回今日最新值
    func getTodayValue(for habit: Habit) -> Double? {
        guard habit.isNumericType else { return nil }

        let todayRecords = getTodayRecords(for: habit)
        guard !todayRecords.isEmpty else { return nil }

        if habit.isCountType {
            // 计数类：求和
            return todayRecords.compactMap { $0.valueDouble }.filter(\.isFinite).reduce(0, +)
        } else {
            // 测量类：取最新有效值，避免空记录遮住当天真实测量值
            return todayRecords.lazy.compactMap(\.valueDouble).first(where: \.isFinite)
        }
    }

    /// 获取历史最新值（测量类数值型）
    /// - Returns: 最新的记录值，如果没有记录则返回 nil
    func getLatestValue(for habit: Habit) -> Double? {
        guard habit.isNumericType && !habit.isCountType else { return nil }

        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(
            format: "habitId == %@ AND value != nil",
            habit.id as CVarArg
        )
        // 同日多条（补记修正当日值）时取 createdAt 最新的，保证「后补覆盖前值」确定
        request.sortDescriptors = [
            NSSortDescriptor(key: "date", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false)
        ]
        request.fetchLimit = 1

        return try? context.fetch(request).first?.valueDouble
    }
    
    /// 计算连续天数（打卡型）
    func calculateStreak(for habit: Habit) -> Int {
        guard habit.isCheckInType else { return 0 }

        let calendar = Calendar.current
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())

        if habit.isBadHabit {
            // 坏习惯：连续未打卡天数（连续控制住的天数）
            // 今天已打卡（做了坏事）→ 从昨天开始倒查
            let todayCompleted = isTodayCompleted(for: habit)
            if todayCompleted {
                guard let yesterday = calendar.date(byAdding: .day, value: -1, to: checkDate) else {
                    return 0
                }
                checkDate = yesterday
            }

            let maxLookback = 3650
            for _ in 0..<maxLookback {
                let dayStart = checkDate
                guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }

                let request = HabitRecord.fetchRequest()
                request.predicate = NSPredicate(
                    format: "habitId == %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
                    habit.id as CVarArg,
                    dayStart as NSDate,
                    dayEnd as NSDate
                )
                request.fetchLimit = 1

                let hasBadRecord = ((try? context.fetch(request))?.count ?? 0) > 0
                // 有打卡记录（做了坏事）→ 中断连续控制
                guard !hasBadRecord else { break }

                streak += 1
                guard let previousDay = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
                checkDate = previousDay
            }

            return streak
        }

        // 好习惯：原始逻辑（连续打卡天数）
        // 今天未完成 → 从昨天开始倒查
        let todayCompleted = isTodayCompleted(for: habit)
        if !todayCompleted {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: checkDate) else {
                return 0
            }
            checkDate = yesterday
        }

        // 向前逐天检查，最多追溯 3650 天（防止极端情况）
        let maxLookback = 3650
        for _ in 0..<maxLookback {
            let dayStart = checkDate
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }

            let request = HabitRecord.fetchRequest()
            request.predicate = NSPredicate(
                format: "habitId == %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
                habit.id as CVarArg,
                dayStart as NSDate,
                dayEnd as NSDate
            )
            request.fetchLimit = 1

            let hasRecord = ((try? context.fetch(request))?.count ?? 0) > 0
            guard hasRecord else { break }

            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = previousDay
        }

        return streak
    }

    /// 根据习惯频率计算连续坚持信息（打卡型）
    /// 每日习惯：连续打卡天数
    /// 每周习惯：连续达标周数（每周完成次数 >= 目标次数）
    /// 每月习惯：连续达标月数（每月完成次数 >= 目标次数）
    func calculateStreakInfo(for habit: Habit) -> HabitStreak {
        guard habit.isCheckInType else { return .zero() }

        let frequency = habit.habitFrequency
        let target = max(habit.targetCountValue ?? 1, 1)

        switch frequency {
        case .daily:
            let days = calculateStreak(for: habit)
            return HabitStreak(value: days, unit: .day)
        case .weekly:
            let weeks = calculatePeriodicStreak(
                for: habit, target: target,
                periodComponent: .weekOfYear,
                periodCount: { [weak self] habit, start, end in
                    self?.countDistinctCompletionDays(for: habit, from: start, to: end) ?? 0
                }
            )
            return HabitStreak(value: weeks, unit: .week)
        case .monthly:
            let months = calculatePeriodicStreak(
                for: habit, target: target,
                periodComponent: .month,
                periodCount: { [weak self] habit, start, end in
                    self?.countDistinctCompletionDays(for: habit, from: start, to: end) ?? 0
                }
            )
            return HabitStreak(value: months, unit: .month)
        }
    }

    // MARK: - 周期连续性私有方法

    /// 统计时间范围内的不同打卡天数
    private func countDistinctCompletionDays(for habit: Habit, from start: Date, to end: Date) -> Int {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(
            format: "habitId == %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
            habit.id as CVarArg,
            start as NSDate,
            end as NSDate
        )

        let records = (try? context.fetch(request)) ?? []
        let calendar = Calendar.current
        let distinctDays = Set(records.map { calendar.startOfDay(for: $0.date) })
        return distinctDays.count
    }

    /// 通用周期连续性计算（周/月复用）
    /// - Parameters:
    ///   - habit: 习惯
    ///   - target: 每周期目标次数
    ///   - periodComponent: .weekOfYear 或 .month
    ///   - periodCount: 计算某周期内完成次数的闭包
    private func calculatePeriodicStreak(
        for habit: Habit,
        target: Int,
        periodComponent: Calendar.Component,
        periodCount: (Habit, Date, Date) -> Int
    ) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 计算当前周期的起始日
        let currentPeriodStart: Date
        if periodComponent == .weekOfYear {
            currentPeriodStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!
        } else {
            currentPeriodStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        }

        guard let currentPeriodEnd = calendar.date(byAdding: periodComponent, value: 1, to: currentPeriodStart) else {
            return 0
        }

        // 判断当前周期是否已达标，决定起始检查周期
        let currentCount = periodCount(habit, currentPeriodStart, currentPeriodEnd)
        var checkPeriodStart: Date

        if currentCount >= target {
            checkPeriodStart = currentPeriodStart
        } else {
            guard let prevPeriod = calendar.date(byAdding: periodComponent, value: -1, to: currentPeriodStart) else {
                return 0
            }
            checkPeriodStart = prevPeriod
        }

        var streak = 0
        let maxLookback = periodComponent == .weekOfYear ? 520 : 120

        for _ in 0..<maxLookback {
            guard let periodEnd = calendar.date(byAdding: periodComponent, value: 1, to: checkPeriodStart) else { break }
            let count = periodCount(habit, checkPeriodStart, periodEnd)
            guard count >= target else { break }

            streak += 1
            guard let prevPeriod = calendar.date(byAdding: periodComponent, value: -1, to: checkPeriodStart) else { break }
            checkPeriodStart = prevPeriod
        }

        return streak
    }

    /// 计算周期内完成次数（打卡型）
    func calculatePeriodCompletionCount(for habit: Habit, range: HabitDateRange) -> Int {
        calculatePeriodCompletionCount(for: habit, dateRange: range.dateRange())
    }

    /// 计算指定日期区间内完成次数（打卡型）
    func calculatePeriodCompletionCount(for habit: Habit, dateRange: ClosedRange<Date>?) -> Int {
        guard habit.isCheckInType else { return 0 }
        
        let records = getRecords(for: habit, in: dateRange)
        return records.filter { $0.isCompleted }.count
    }
    
    /// 计算周期统计（数值型，基于每日聚合）
    func calculatePeriodStats(for habit: Habit, range: HabitDateRange) -> HabitPeriodStats {
        calculatePeriodStats(for: habit, dateRange: range.dateRange())
    }

    /// 计算指定日期区间统计（数值型，基于每日聚合）
    func calculatePeriodStats(for habit: Habit, dateRange: ClosedRange<Date>?) -> HabitPeriodStats {
        let records = getRecords(for: habit, in: dateRange)
        let dailyValues = aggregateDailyNumericValues(for: habit, records: records)

        guard !dailyValues.isEmpty else {
            return HabitPeriodStats(
                total: 0,
                average: 0,
                min: 0,
                max: 0,
                count: 0,
                latestValue: nil,
                earliestValue: nil
            )
        }

        let aggregatedValues = dailyValues.map(\.value)
        let total = aggregatedValues.reduce(0, +)
        let average = total / Double(aggregatedValues.count)
        let minVal = aggregatedValues.min() ?? 0
        let maxVal = aggregatedValues.max() ?? 0

        // 按日期排序获取首尾值
        let earliest = dailyValues.first?.value
        let latest = dailyValues.last?.value

        return HabitPeriodStats(
            total: total,
            average: average,
            min: minVal,
            max: maxVal,
            count: aggregatedValues.count,
            latestValue: latest,
            earliestValue: earliest
        )
    }
    
    /// 获取按日聚合的数据（用于图表）
    func getDailyAggregatedData(for habit: Habit, range: HabitDateRange) -> [DailyHabitData] {
        getDailyAggregatedData(for: habit, dateRange: range.dateRange())
    }

    /// 获取指定日期区间的按日聚合数据（用于图表）
    func getDailyAggregatedData(for habit: Habit, dateRange: ClosedRange<Date>?) -> [DailyHabitData] {
        guard habit.isNumericType else { return [] }
        let records = getRecords(for: habit, in: dateRange)
        return aggregateDailyNumericValues(for: habit, records: records)
    }

    /// 详情统计、趋势图和统计总览共享同一套数值口径。
    func aggregateDailyNumericValues(for habit: Habit, records: [HabitRecord]) -> [DailyHabitData] {
        HabitNumericAggregator.aggregateDaily(
            samples: records.map { HabitNumericSample(date: $0.date, value: $0.valueDouble) },
            isCountType: habit.isCountType
        )
        .map { DailyHabitData(date: $0.date, value: $0.value) }
    }
    
    /// 获取今日习惯完成进度（打卡型 + 数值型）
    /// - 打卡型：今日有 isCompleted==YES 记录即算完成
    /// - 数值型：今日有记录即算完成（功能鼓励「保持记录」，与数值大小/是否达标无关）
    func getTodayCheckInProgress(visibleHabitIds: [UUID]? = nil) -> (completed: Int, total: Int) {
        let visibleSet: Set<UUID>? = {
            guard let visible = visibleHabitIds, !visible.isEmpty else { return nil }
            return Set(visible)
        }()
        func isVisible(_ id: UUID) -> Bool { visibleSet?.contains(id) ?? true }

        let checkInHabits = activeHabits.filter { $0.isCheckInType && isVisible($0.id) }
        let numericHabits = activeHabits.filter { $0.isNumericType && isVisible($0.id) }

        let total = checkInHabits.count + numericHabits.count
        guard total > 0 else { return (0, 0) }

        let today = Calendar.current.startOfDay(for: Date())
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) else {
            return (0, total)
        }

        // 打卡型完成数：单次 distinct fetch
        let checkInCompleted = countCheckedHabits(
            ids: checkInHabits.map(\.id), from: today, to: tomorrow
        )
        // 数值型完成数：今日有记录即算（功能鼓励「保持记录」，与数值大小/是否达标无关）
        let numericCompleted = numericHabits.filter { hasTodayNumericRecord($0) }.count

        return (checkInCompleted + numericCompleted, total)
    }

    /// 本周（含今日）各习惯逐日完成情况，供磁贴点阵一次取用
    /// 返回 habitId -> [当天是否有记录]，下标 0 = 本周第一天（跟随系统 firstWeekday），末位 = 今天
    func getWeekCompletionPatterns() -> [UUID: [Bool]] {
        guard isReady, !activeHabits.isEmpty else { return [:] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today) else { return [:] }

        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(format: "date >= %@ AND date < %@", week.start as NSDate, week.end as NSDate)
        let records = (try? context.fetch(request)) ?? []
        guard !records.isEmpty else { return [:] }

        let dayCount = calendar.dateComponents([.day], from: week.start, to: today).day ?? 0
        let totalDays = dayCount + 1
        var hitDaysByHabit: [UUID: Set<Int>] = [:]
        for record in records {
            let day = calendar.dateComponents([.day], from: week.start, to: record.date).day ?? 0
            guard day >= 0, day < totalDays else { continue }
            hitDaysByHabit[record.habitId, default: []].insert(day)
        }
        return hitDaysByHabit.mapValues { hitDays in
            (0..<totalDays).map { hitDays.contains($0) }
        }
    }

    /// 今日目标贡献：今天有打卡/记录、且关联了目标的习惯数。
    /// 复用与 getTodayCheckInProgress 相同的今日完成判定逻辑，保持口径一致。
    func getTodayGoalHabitContribution() -> (habitCount: Int, goalCount: Int) {
        let goalHabits = activeHabits.filter { !$0.isArchived && $0.goal != nil }
        guard !goalHabits.isEmpty else { return (0, 0) }

        let checkInCompleted = goalHabits.filter { $0.isCheckInType && isTodayCompleted(for: $0) }
        let numericCompleted = goalHabits.filter { $0.isNumericType && hasTodayNumericRecord($0) }
        let completedHabits = checkInCompleted + numericCompleted

        let goalIds = Set(completedHabits.compactMap { $0.goal?.id })
        return (completedHabits.count, goalIds.count)
    }

    /// 数值型习惯今日是否有记录
    private func hasTodayNumericRecord(_ habit: Habit) -> Bool {
        getTodayValue(for: habit) != nil
    }

    /// 分正负向统计今日打卡型习惯进度
    /// - positive: 正向习惯（completed = 今日已打卡数）
    /// - negative: 负向习惯（checked = 今日已发生数）
    func getTodayCheckInSplit() -> (
        positive: (completed: Int, total: Int),
        negative: (checked: Int, total: Int)
    ) {
        let positiveHabits = activeHabits.filter { $0.isCheckInType && !$0.isBadHabit }
        let negativeHabits = activeHabits.filter { $0.isCheckInType && $0.isBadHabit }

        let today = Calendar.current.startOfDay(for: Date())
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) else {
            return ((0, positiveHabits.count), (0, negativeHabits.count))
        }

        let positiveCompleted = countCheckedHabits(
            ids: positiveHabits.map(\.id), from: today, to: tomorrow
        )
        let negativeChecked = countCheckedHabits(
            ids: negativeHabits.map(\.id), from: today, to: tomorrow
        )

        return (
            (positiveCompleted, positiveHabits.count),
            (negativeChecked, negativeHabits.count)
        )
    }

    /// 统计指定习惯 ID 列表中今日有打卡记录的习惯数量
    private func countCheckedHabits(ids: [UUID], from: Date, to: Date) -> Int {
        guard !ids.isEmpty else { return 0 }

        let request = NSFetchRequest<NSDictionary>(entityName: "HabitRecord")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["habitId"]
        request.returnsDistinctResults = true
        request.predicate = NSPredicate(
            format: "habitId IN %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
            ids as NSArray,
            from as NSDate,
            to as NSDate
        )

        do {
            return try context.fetch(request).count
        } catch {
            logger.error("统计习惯打卡失败: \(error)")
            return 0
        }
    }
    
    // MARK: - Notifications

    /// 发送数据变更通知
    private func notifyDataChange(habitId: UUID? = nil) {
        // 触发 objectWillChange，让仅依赖 @ObservedObject（未监听 NotificationCenter）的视图
        // 如 KanbanProgressHero 在打卡后实时刷新；既有通过 .habitDataDidChange 监听的视图不受影响
        objectWillChange.send()
        NotificationCenter.default.post(name: .habitDataDidChange, object: habitId)
    }
}


// MARK: - Update Model

/// 习惯更新参数
struct HabitUpdates {
    var name: String?
    var icon: String?
    var color: String?
    var frequency: HabitFrequency?
    var targetCount: Int?
    var targetValue: Double?
    var unit: String?
    var aggregationType: HabitAggregationType?
    var isBadHabit: Bool?
}

// MARK: - Statistics Models

/// 周期统计数据
struct HabitPeriodStats {
    let total: Double
    let average: Double
    let min: Double
    let max: Double
    let count: Int
    let latestValue: Double?
    let earliestValue: Double?
    
    /// 变化量（最新值 - 最早值）
    var change: Double? {
        guard let latest = latestValue, let earliest = earliestValue else { return nil }
        return latest - earliest
    }
}

/// 每日聚合数据（用于图表）
struct DailyHabitData: Identifiable, Equatable {
    let date: Date
    let value: Double
    
    var id: Date { date }
    
    /// 格式化日期（MM-dd）
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Errors

enum HabitError: LocalizedError {
    case invalidData
    case notFound
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidData: return "数据无效"
        case .notFound: return "习惯不存在"
        case .saveFailed: return "保存失败"
        }
    }
}
