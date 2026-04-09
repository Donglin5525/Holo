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
    
    // MARK: - Singleton
    
    static let shared = HabitRepository()
    
    // MARK: - Published Properties
    
    /// 当前活跃（未归档）的习惯列表
    @Published var activeHabits: [Habit] = []
    
    // MARK: - Properties
    
    /// 主上下文（主线程）
    private var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }
    
    // MARK: - Initialization
    
    private init() {
        loadActiveHabits()
    }
    
    // MARK: - 数据加载
    
    /// 加载活跃习惯列表
    func loadActiveHabits() {
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "isArchived == NO")
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        
        do {
            activeHabits = try context.fetch(request)
        } catch {
            print("[HabitRepository] 加载习惯失败: \(error)")
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
        notifyDataChange(habitId: habit.id)
        
        return habit
    }
    
    /// 更新习惯
    func updateHabit(_ habit: Habit, updates: HabitUpdates) throws {
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
        habit.isArchived = true
        habit.updatedAt = Date()
        
        try context.save()
        loadActiveHabits()
        notifyDataChange(habitId: habit.id)
    }
    
    /// 恢复归档的习惯
    func unarchiveHabit(_ habit: Habit) throws {
        habit.isArchived = false
        habit.updatedAt = Date()
        
        try context.save()
        loadActiveHabits()
        notifyDataChange(habitId: habit.id)
    }
    
    /// 删除习惯（硬删除，会级联删除所有记录）
    func deleteHabit(_ habit: Habit) throws {
        let habitId = habit.id
        context.delete(habit)
        
        try context.save()
        loadActiveHabits()
        notifyDataChange(habitId: habitId)
    }
    
    /// 通过 ID 删除习惯（安全方法，用于视图 dismiss 后的延迟删除）
    func deleteHabitById(_ habitId: UUID) throws {
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
        for (index, habit) in habits.enumerated() {
            habit.sortOrder = Int16(index)
        }
        
        try context.save()
        loadActiveHabits()
    }
    
    // MARK: - Record Operations
    
    /// 打卡（打卡型习惯）- 切换今日完成状态
    /// - Parameter habit: 习惯
    /// - Returns: 当前完成状态
    @discardableResult
    func toggleCheckIn(for habit: Habit) throws -> Bool {
        guard habit.isCheckInType else { return false }
        
        let today = Calendar.current.startOfDay(for: Date())
        
        // 查找今日记录
        if let existingRecord = findTodayCheckInRecord(for: habit) {
            // 切换完成状态
            existingRecord.isCompleted.toggle()
            try context.save()
            notifyDataChange(habitId: habit.id)
            return existingRecord.isCompleted
        } else {
            // 创建新记录（默认已完成）
            _ = HabitRecord.createCheckIn(in: context, habit: habit, isCompleted: true)
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
    
    /// 更新记录
    func updateRecord(_ record: HabitRecord, value: Double?, note: String?) throws {
        if let value = value {
            record.value = NSNumber(value: value)
        }
        record.note = note
        
        try context.save()
        notifyDataChange(habitId: record.habitId)
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
            return todayRecords.compactMap { $0.valueDouble }.reduce(0, +)
        } else {
            // 测量类：取最新（已按时间倒序，取第一条）
            return todayRecords.first?.valueDouble
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
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchLimit = 1

        return try? context.fetch(request).first?.valueDouble
    }
    
    /// 计算连续天数（打卡型）
    func calculateStreak(for habit: Habit) -> Int {
        guard habit.isCheckInType else { return 0 }
        
        let calendar = Calendar.current
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())
        
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
    
    /// 计算周期内完成次数（打卡型）
    func calculatePeriodCompletionCount(for habit: Habit, range: HabitDateRange) -> Int {
        guard habit.isCheckInType else { return 0 }
        
        let records = getRecords(for: habit, in: range.dateRange())
        return records.filter { $0.isCompleted }.count
    }
    
    /// 计算周期统计（数值型，基于每日聚合）
    func calculatePeriodStats(for habit: Habit, range: HabitDateRange) -> HabitPeriodStats {
        let records = getRecords(for: habit, in: range.dateRange())
        let calendar = Calendar.current

        // 按日期分组
        var groupedByDay: [Date: [HabitRecord]] = [:]
        for record in records {
            let dayStart = calendar.startOfDay(for: record.date)
            groupedByDay[dayStart, default: []].append(record)
        }

        // 按天聚合（复用 getDailyAggregatedData 的逻辑）
        var dailyValues: [(date: Date, value: Double)] = []
        for (date, dayRecords) in groupedByDay {
            let values = dayRecords.compactMap { $0.valueDouble }
            guard !values.isEmpty else { continue }

            let aggregatedValue: Double
            if habit.isCountType {
                aggregatedValue = values.reduce(0, +)
            } else {
                let sorted = dayRecords.sorted { $0.date > $1.date }
                aggregatedValue = sorted.first?.valueDouble ?? 0
            }
            dailyValues.append((date: date, value: aggregatedValue))
        }

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
        let sortedByDate = dailyValues.sorted { $0.date < $1.date }
        let earliest = sortedByDate.first?.value
        let latest = sortedByDate.last?.value

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
        guard habit.isNumericType else { return [] }
        
        let records = getRecords(for: habit, in: range.dateRange())
        let calendar = Calendar.current
        
        // 按日期分组
        var groupedByDay: [Date: [HabitRecord]] = [:]
        for record in records {
            let dayStart = calendar.startOfDay(for: record.date)
            groupedByDay[dayStart, default: []].append(record)
        }
        
        // 聚合计算
        var result: [DailyHabitData] = []
        for (date, dayRecords) in groupedByDay {
            let values = dayRecords.compactMap { $0.valueDouble }
            guard !values.isEmpty else { continue }
            
            let aggregatedValue: Double
            if habit.isCountType {
                // 计数类：求和
                aggregatedValue = values.reduce(0, +)
            } else {
                // 测量类：取当天最新值
                let sorted = dayRecords.sorted { $0.date > $1.date }
                aggregatedValue = sorted.first?.valueDouble ?? 0
            }
            
            result.append(DailyHabitData(date: date, value: aggregatedValue))
        }
        
        return result.sorted { $0.date < $1.date }
    }
    
    /// 获取今日打卡型习惯完成进度
    func getTodayCheckInProgress() -> (completed: Int, total: Int) {
        let checkInHabitIds = activeHabits
            .filter { $0.isCheckInType }
            .map(\.id)
        
        let total = checkInHabitIds.count
        guard total > 0 else { return (0, 0) }
        
        let today = Calendar.current.startOfDay(for: Date())
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) else {
            return (0, total)
        }
        
        // 单次 fetch 统计今日完成的习惯数量（避免对每个习惯逐个 fetch）
        let request = NSFetchRequest<NSDictionary>(entityName: "HabitRecord")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["habitId"]
        request.returnsDistinctResults = true
        request.predicate = NSPredicate(
            format: "habitId IN %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
            checkInHabitIds as NSArray,
            today as NSDate,
            tomorrow as NSDate
        )
        
        do {
            let results = try context.fetch(request)
            return (results.count, total)
        } catch {
            print("[HabitRepository] 获取今日进度失败: \(error)")
            return (0, total)
        }
    }
    
    // MARK: - Notifications

    /// 发送数据变更通知
    private func notifyDataChange(habitId: UUID? = nil) {
        NotificationCenter.default.post(name: .habitDataDidChange, object: habitId)
    }
}

// MARK: - Statistics Extension

extension HabitRepository {

    /// 获取总览统计数据
    func getOverviewStats(range: HabitStatsDateRange) -> HabitOverviewStats {
        let habits = activeHabits
        let totalHabits = habits.count

        guard totalHabits > 0 else {
            return HabitOverviewStats.empty()
        }

        // 今日完成数
        let (todayCompleted, _) = getTodayCheckInProgress()

        // 计算平均完成率
        let dateRange = range.dateRange()
        var totalCompletionRate: Double = 0

        for habit in habits {
            if habit.isCheckInType {
                let completionRate = calculateCheckInCompletionRate(for: habit, in: dateRange)
                totalCompletionRate += completionRate
            } else if habit.isNumericType {
                let completionRate = calculateNumericCompletionRate(for: habit, in: dateRange)
                totalCompletionRate += completionRate
            }
        }

        let averageCompletionRate = totalCompletionRate / Double(totalHabits)

        // 计算总连续天数
        let totalStreak = habits.reduce(0) { $0 + calculateStreak(for: $1) }

        return HabitOverviewStats(
            todayCompleted: todayCompleted,
            totalHabits: totalHabits,
            averageCompletionRate: averageCompletionRate,
            totalStreak: totalStreak
        )
    }

    /// 获取全局完成率趋势数据
    func getOverallCompletionTrend(range: HabitStatsDateRange) -> [DailyCompletionData] {
        let habits = activeHabits
        guard !habits.isEmpty else { return [] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 确定起始日期
        let startDate: Date
        if let rangeDate = range.dateRange() {
            startDate = calendar.startOfDay(for: rangeDate.lowerBound)
        } else {
            // 全部：从最早的习惯创建日期开始
            startDate = habits.map { calendar.startOfDay(for: $0.createdAt) }.min() ?? today
        }

        var result: [DailyCompletionData] = []
        var currentDate = startDate

        while currentDate <= today {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDate)!
            var dayCompleted = 0
            var dayTotal = 0

            for habit in habits {
                // 检查习惯在该日期是否已创建
                guard habit.createdAt < nextDay else { continue }
                dayTotal += 1

                if habit.isBadHabit {
                    // 坏习惯：判断是否控制在目标以内
                    if habit.isCheckInType {
                        // 打卡型坏习惯：未打卡 = 成功
                        let request = HabitRecord.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "habitId == %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
                            habit.id as CVarArg,
                            currentDate as NSDate,
                            nextDay as NSDate
                        )
                        if (try? context.count(for: request)) ?? 0 == 0 {
                            dayCompleted += 1
                        }
                    } else if habit.isNumericType, let targetValue = habit.targetValueDouble {
                        // 数值型坏习惯：聚合值 <= 目标值 = 成功
                        let request = HabitRecord.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "habitId == %@ AND date >= %@ AND date < %@ AND value != nil",
                            habit.id as CVarArg,
                            currentDate as NSDate,
                            nextDay as NSDate
                        )
                        if let dayRecords = try? context.fetch(request) as? [HabitRecord] {
                            let aggregatedValue: Double
                            if habit.isCountType {
                                aggregatedValue = dayRecords.compactMap { $0.value?.doubleValue }.reduce(0, +)
                            } else {
                                aggregatedValue = dayRecords.last?.value?.doubleValue ?? 0
                            }
                            if aggregatedValue <= targetValue {
                                dayCompleted += 1
                            }
                        }
                    } else {
                        // 无目标值的数值型坏习惯：有记录即算
                        let request = HabitRecord.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "habitId == %@ AND date >= %@ AND date < %@ AND value != nil",
                            habit.id as CVarArg,
                            currentDate as NSDate,
                            nextDay as NSDate
                        )
                        if (try? context.count(for: request)) ?? 0 > 0 {
                            dayCompleted += 1
                        }
                    }
                } else {
                    // 好习惯：原有逻辑
                    if habit.isCheckInType {
                        let request = HabitRecord.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "habitId == %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
                            habit.id as CVarArg,
                            currentDate as NSDate,
                            nextDay as NSDate
                        )
                        if (try? context.count(for: request)) ?? 0 > 0 {
                            dayCompleted += 1
                        }
                    } else if habit.isNumericType {
                        let request = HabitRecord.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "habitId == %@ AND date >= %@ AND date < %@ AND value != nil",
                            habit.id as CVarArg,
                            currentDate as NSDate,
                            nextDay as NSDate
                        )
                        if (try? context.count(for: request)) ?? 0 > 0 {
                            dayCompleted += 1
                        }
                    }
                }
            }

            let completionRate = dayTotal > 0 ? Double(dayCompleted) / Double(dayTotal) * 100 : 0
            result.append(DailyCompletionData(date: currentDate, completionRate: completionRate))

            currentDate = nextDay
        }

        return result
    }

    /// 获取习惯排行榜（按完成率排序）
    func getHabitRanking(range: HabitStatsDateRange, limit: Int = 5) -> [HabitRankingItem] {
        let habits = activeHabits
        guard !habits.isEmpty else { return [] }

        let dateRange = range.dateRange()

        var items: [HabitRankingItem] = []

        for habit in habits {
            let completionRate: Double
            if habit.isCheckInType {
                completionRate = calculateCheckInCompletionRate(for: habit, in: dateRange)
            } else {
                completionRate = calculateNumericCompletionRate(for: habit, in: dateRange)
            }

            let streak = calculateStreak(for: habit)

            items.append(HabitRankingItem(
                habitId: habit.id,
                name: habit.name,
                icon: habit.icon,
                color: habit.color,
                completionRate: completionRate,
                streak: streak
            ))
        }

        // 按完成率降序排序
        items.sort { $0.completionRate > $1.completionRate }

        // 返回前 limit 个
        return Array(items.prefix(limit))
    }

    /// 获取习惯统计数据项
    func getHabitStatsItems(range: HabitStatsDateRange, filter: HabitTypeFilter = .all) -> [HabitStatsItem] {
        var habits = activeHabits

        // 类型筛选
        switch filter {
        case .checkIn:
            habits = habits.filter { $0.isCheckInType }
        case .count:
            habits = habits.filter { $0.isCountType }
        case .measure:
            habits = habits.filter { $0.isMeasureType }
        default:
            break
        }

        let dateRange = range.dateRange()

        return habits.map { habit in
            let streak = calculateStreak(for: habit)
            let completionRate: Double
            let todayValue: Double?
            let todayTarget: Double?

            if habit.isCheckInType {
                completionRate = calculateCheckInCompletionRate(for: habit, in: dateRange)
                todayValue = isTodayCompleted(for: habit) ? 1 : 0
                todayTarget = habit.targetCountValue.map { Double($0) }
            } else {
                completionRate = calculateNumericCompletionRate(for: habit, in: dateRange)
                todayValue = getTodayValue(for: habit)
                todayTarget = habit.targetValueDouble
            }

            // 将 HabitStatsDateRange 转换为 HabitDateRange 以复用现有方法
            let legacyRange = convertToHabitDateRange(range)
            let dailyData = habit.isNumericType ? getDailyAggregatedData(for: habit, range: legacyRange) : []
            let calendarData = habit.isCheckInType ? getCheckInCalendarData(for: habit, range: range) : [:]

            return HabitStatsItem(
                habitId: habit.id,
                name: habit.name,
                icon: habit.icon,
                color: habit.color,
                typeRaw: habit.type,
                aggregationTypeRaw: habit.aggregationType,
                streak: streak,
                completionRate: completionRate,
                todayValue: todayValue,
                todayTarget: todayTarget,
                unit: habit.unit,
                dailyData: dailyData,
                calendarData: calendarData
            )
        }
    }

    /// 将 HabitStatsDateRange 转换为 HabitDateRange
    private func convertToHabitDateRange(_ range: HabitStatsDateRange) -> HabitDateRange {
        switch range {
        case .week: return .week
        case .month: return .month
        case .quarter: return .quarter
        case .all: return .all
        }
    }

    /// 获取打卡型习惯的日历数据
    func getCheckInCalendarData(for habit: Habit, range: HabitStatsDateRange) -> [Date: Bool] {
        guard habit.isCheckInType else { return [:] }

        let calendar = Calendar.current
        let records = getRecords(for: habit, in: range.dateRange())

        var result: [Date: Bool] = [:]
        for record in records {
            let dayStart = calendar.startOfDay(for: record.date)
            result[dayStart] = record.isCompleted
        }

        return result
    }

    // MARK: - Private Helpers

    /// 计算打卡型习惯的完成率
    private func calculateCheckInCompletionRate(for habit: Habit, in dateRange: ClosedRange<Date>?) -> Double {
        guard habit.isCheckInType else { return 0 }

        let calendar = Calendar.current
        let records = getRecords(for: habit, in: dateRange)

        // 计算周期内的天数
        let dayCount: Int
        if let range = dateRange {
            let components = calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound)
            dayCount = max(components.day ?? 1, 1) + 1
        } else {
            // 全部时间：从习惯创建日期到今天
            let components = calendar.dateComponents([.day], from: habit.createdAt, to: Date())
            dayCount = max(components.day ?? 1, 1) + 1
        }

        if habit.isBadHabit {
            // 坏习惯：未打卡的天数算作成功（没有做坏习惯）
            let checkedInCount = records.filter { $0.isCompleted }.count
            let controlledCount = max(dayCount - checkedInCount, 0)
            return dayCount > 0 ? Double(controlledCount) / Double(dayCount) * 100 : 0
        } else {
            // 好习惯：打卡天数即算完成
            let completedCount = records.filter { $0.isCompleted }.count
            return dayCount > 0 ? Double(completedCount) / Double(dayCount) * 100 : 0
        }
    }

    /// 计算数值型习惯的完成率
    private func calculateNumericCompletionRate(for habit: Habit, in dateRange: ClosedRange<Date>?) -> Double {
        guard habit.isNumericType else { return 0 }

        let calendar = Calendar.current
        let records = getRecords(for: habit, in: dateRange)

        // 计算周期内的天数
        let dayCount: Int
        if let range = dateRange {
            let components = calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound)
            dayCount = max(components.day ?? 1, 1) + 1
        } else {
            let components = calendar.dateComponents([.day], from: habit.createdAt, to: Date())
            dayCount = max(components.day ?? 1, 1) + 1
        }

        if habit.isBadHabit, let targetValue = habit.targetValueDouble {
            // 坏习惯：按天聚合值，统计未超标（值 <= 目标值）的天数
            var dailyValues: [Date: Double] = [:]
            for record in records {
                guard let value = record.value?.doubleValue else { continue }
                let dayStart = calendar.startOfDay(for: record.date)

                if habit.isCountType {
                    dailyValues[dayStart, default: 0] += value
                } else {
                    dailyValues[dayStart] = value
                }
            }

            let controlledDays = dailyValues.values.filter { $0 <= targetValue }.count
            return dayCount > 0 ? Double(controlledDays) / Double(dayCount) * 100 : 0
        } else {
            // 好习惯：有记录的天数即算完成
            var recordedDays = Set<Date>()
            for record in records {
                let dayStart = calendar.startOfDay(for: record.date)
                recordedDays.insert(dayStart)
            }

            return dayCount > 0 ? Double(recordedDays.count) / Double(dayCount) * 100 : 0
        }
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
struct DailyHabitData: Identifiable {
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
