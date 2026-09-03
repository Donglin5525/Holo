//
//  Anniversary+CoreDataProperties.swift
//  Holo
//
//  纪念日实体属性扩展（创建方法、计算属性、天数算法）
//

import Foundation
import CoreData

// MARK: - 纪念日类型枚举

/// 纪念日类型（预设模板，影响默认图标/重复/正倒数倾向）
enum AnniversaryType: String, CaseIterable, Codable {
    case birthday = "birthday"       // 生日
    case anniversary = "anniversary" // 纪念日（恋爱/结婚/入职等）
    case countdown = "countdown"     // 倒数日（未来某天）
    case milestone = "milestone"     // 里程碑（过去起点，累计天数）

    /// 显示名
    var displayName: String {
        switch self {
        case .birthday: return String(localized: "生日")
        case .anniversary: return String(localized: "纪念日")
        case .countdown: return String(localized: "倒数日")
        case .milestone: return String(localized: "里程碑")
        }
    }

    /// 新建默认图标（emoji）：存量数据的 SF Symbol 图标不迁移，渲染层兼容两者
    nonisolated var defaultEmoji: String {
        switch self {
        case .birthday: return "🎂"
        case .anniversary: return "❤️"
        case .countdown: return "⏳"
        case .milestone: return "🚩"
        }
    }

    /// 默认是否每年重复
    var defaultRepeatYearly: Bool {
        switch self {
        case .birthday, .anniversary: return true
        case .countdown, .milestone: return false
        }
    }

    /// 默认主题色 hex
    nonisolated var defaultColor: String {
        switch self {
        case .birthday: return "#F46D38"       // 品牌橙
        case .anniversary: return "#EC4899"    // 粉红
        case .countdown: return "#60A5FA"      // 蓝
        case .milestone: return "#C084FC"      // 紫
        }
    }
}

// MARK: - 提醒预设

/// 纪念日提醒提前天数预设
enum AnniversaryReminderPreset: Int16, CaseIterable {
    case sameDay = 0       // 当天
    case oneDayBefore = 1  // 提前1天
    case threeDaysBefore = 3 // 提前3天
    case weekBefore = 7    // 提前7天

    var displayName: String {
        switch self {
        case .sameDay: return String(localized: "当天")
        case .oneDayBefore: return String(localized: "提前1天")
        case .threeDaysBefore: return String(localized: "提前3天")
        case .weekBefore: return String(localized: "提前7天")
        }
    }
}

extension Anniversary {

    // MARK: - 创建方法

    /// 创建一个纪念日托管对象（调用方负责 save）
    @nonobjc class func create(
        in context: NSManagedObjectContext,
        title: String,
        date: Date,
        type: AnniversaryType = .countdown,
        icon: String? = nil,
        color: String? = nil,
        note: String? = nil,
        isPinned: Bool = false,
        repeatYearly: Bool? = nil,
        isLunar: Bool = false,
        reminderEnabled: Bool = false,
        reminderDaysBefore: Int16 = 0,
        generateTask: Bool = false
    ) -> Anniversary {
        let item = Anniversary(context: context)
        item.id = UUID()
        item.title = title
        item.date = date
        item.type = type.rawValue
        item.icon = icon ?? type.defaultEmoji
        item.color = color ?? type.defaultColor
        item.note = note
        item.isPinned = isPinned
        item.isArchived = false
        item.isSoftDeleted = false
        item.sortOrder = 0
        item.repeatYearly = repeatYearly ?? type.defaultRepeatYearly
        item.isLunar = isLunar
        item.reminderEnabled = reminderEnabled
        item.reminderDaysBefore = reminderDaysBefore
        item.generateTask = generateTask
        item.createdAt = Date()
        item.updatedAt = Date()
        return item
    }

    // MARK: - 类型便捷属性

    var anniversaryType: AnniversaryType {
        AnniversaryType(rawValue: type) ?? .countdown
    }

    // MARK: - 天数计算（核心算法）

    /// 计算距「今天」的天数。
    /// - 正数 = 未来还有 N 天（倒数）
    /// - 负数 = 过去已经 N 天（累计，取绝对值展示）
    ///
    /// 对于每年重复的纪念日，自动计算**下一个周年**距今的天数（农历重复按农历推算）；
    /// 对于不重复的，直接算原始日期距今的差。
    ///
    /// - Parameter reference: 参考日期（默认今天）
    /// - Returns: 距今天的天数（正=未来，负=过去）
    func daysFromToday(reference: Date = Date()) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        let originalDay = calendar.startOfDay(for: date)

        // 不重复：直接算差
        if !repeatYearly {
            let diff = calendar.dateComponents([.day], from: originalDay, to: today).day ?? 0
            return -diff  // today 在 originalDay 之后 → 正数表示"已经过去N天"
        }

        // 每年重复：找到 >= 今天的下一个周年
        let nextAnniversary = nextOccurrenceDate(reference: reference)
        return calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: nextAnniversary)).day ?? 0
    }

    /// 下一周年的日期（仅 repeatYearly 时有意义；农历重复按农历月日推算）。
    func nextOccurrenceDate(reference: Date = Date()) -> Date {
        if isLunar {
            return ChineseLunarCalendar.nextLunarOccurrence(of: date, onOrAfter: reference)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        let originalDay = calendar.startOfDay(for: date)
        let origComp = calendar.dateComponents([.month, .day], from: originalDay)

        let nowYear = calendar.dateComponents([.year], from: reference).year ?? 0
        var thisYearComp = DateComponents()
        thisYearComp.year = nowYear
        thisYearComp.month = origComp.month
        thisYearComp.day = origComp.day
        let thisYearDate = calendar.date(from: thisYearComp) ?? originalDay

        if calendar.startOfDay(for: thisYearDate) >= today {
            return thisYearDate
        }
        thisYearComp.year = nowYear + 1
        return calendar.date(from: thisYearComp) ?? thisYearDate
    }

    /// 上一个周年的日期（早于今天的最近一次；年度周期进度用）。
    func previousOccurrenceDate(reference: Date = Date()) -> Date {
        if isLunar {
            return ChineseLunarCalendar.previousLunarOccurrence(of: date, before: reference)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        let originalDay = calendar.startOfDay(for: date)
        let origComp = calendar.dateComponents([.month, .day], from: originalDay)

        let nowYear = calendar.dateComponents([.year], from: reference).year ?? 0
        var thisYearComp = DateComponents()
        thisYearComp.year = nowYear
        thisYearComp.month = origComp.month
        thisYearComp.day = origComp.day
        let thisYearDate = calendar.date(from: thisYearComp) ?? originalDay

        if calendar.startOfDay(for: thisYearDate) < today {
            return thisYearDate
        }
        thisYearComp.year = nowYear - 1
        return calendar.date(from: thisYearComp) ?? originalDay
    }

    // MARK: - 展示计算属性

    /// 展示模式
    var displayMode: AnniversaryDisplayMode {
        let days = daysFromToday()
        if days >= 0 {
            return .countdown(days: days)
        } else {
            return .elapsed(days: -days)
        }
    }

    /// 周年数（从原始日期算起的整年数，用于"第N个周年"展示）
    var anniversaryNumber: Int {
        let calendar = Calendar.current
        let years = calendar.dateComponents([.year], from: date, to: Date()).year ?? 0
        return max(years, 0)
    }

    // MARK: - 里程碑与年度周期（详情页「时间的质感」数据）

    /// 从原始日期至今的总天数（里程碑轨道的「已同行 N 天」）
    var totalDaysSinceStart: Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: Date())
        return max(calendar.dateComponents([.day], from: start, to: today).day ?? 0, 0)
    }

    /// 每年重复的当前周期进度（0...1，上一周年 → 下一周年）；非重复返回 nil
    var yearlyCycleProgress: Double? {
        guard repeatYearly else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let prev = previousOccurrenceDate()
        let next = nextOccurrenceDate()
        let total = calendar.dateComponents([.day], from: prev, to: next).day ?? 0
        guard total > 0 else { return nil }
        let passed = calendar.dateComponents([.day], from: prev, to: today).day ?? 0
        return min(max(Double(passed) / Double(total), 0), 1)
    }

    /// 里程碑轨道数据（已达成 + 下一个里程碑）
    var milestoneInfo: AnniversaryMilestoneInfo {
        AnniversaryMilestoneInfo(totalDays: totalDaysSinceStart)
    }

    /// 农历日文案（「八月廿一」）；非农历纪念日也可展示所选日期的农历表示
    var lunarDateText: String {
        ChineseLunarCalendar.lunarDateText(of: date)
    }

    /// 是否临近（7天内）
    var isApproaching: Bool {
        let days = daysFromToday()
        return days >= 0 && days <= 7
    }

    /// 今天是否就是目标日（天数=0）
    var isToday: Bool {
        daysFromToday() == 0
    }

    /// 显示用的大数字
    var displayDays: Int {
        abs(daysFromToday())
    }

    /// 主文案（"还有 N 天" / "已经 N 天" / "就是今天"）
    var displayHeadline: String {
        let mode = displayMode
        switch mode {
        case .countdown(let days):
            return days == 0 ? String(localized: "就是今天") : String(localized: "还有 \(days) 天")
        case .elapsed(let days):
            return String(localized: "已经 \(days) 天")
        }
    }

    /// 提醒触发日期（纪念日日期 - 提前天数）
    func reminderTriggerDate(reference: Date = Date()) -> Date? {
        guard reminderEnabled else { return nil }
        let calendar = Calendar.current
        let baseDate = repeatYearly ? nextOccurrenceDate(reference: reference) : date
        return calendar.date(byAdding: .day, value: -Int(reminderDaysBefore), to: baseDate)
    }

    // MARK: - Preview 辅助

    #if DEBUG
    /// SwiftUI Preview 专用：用独立上下文创建一个临时纪念日用于预览。
    /// `daysOffset > 0` 表示未来（倒数），`< 0` 表示过去（累计）。
    static func previewMock(
        title: String,
        type: AnniversaryType,
        daysOffset: Int,
        repeatYearly: Bool
    ) -> Anniversary {
        let context = PersistencePreviewSupport.previewContext
        let date = Calendar.current.date(byAdding: .day, value: daysOffset, to: Date()) ?? Date()
        let item = Anniversary(context: context)
        item.id = UUID()
        item.title = title
        item.date = date
        item.type = type.rawValue
        item.icon = type.defaultEmoji
        item.color = type.defaultColor
        item.note = nil
        item.isPinned = false
        item.isArchived = false
        item.isSoftDeleted = false
        item.sortOrder = 0
        item.repeatYearly = repeatYearly
        item.isLunar = false
        item.reminderEnabled = false
        item.reminderDaysBefore = 0
        item.generateTask = false
        item.createdAt = Date()
        item.updatedAt = Date()
        return item
    }
    #endif
}

// MARK: - 展示模式枚举

enum AnniversaryDisplayMode: Equatable {
    case countdown(days: Int)   // 倒数：未来还有 N 天
    case elapsed(days: Int)     // 累计：过去已经 N 天

    var isCountdown: Bool {
        if case .countdown = self { return true }
        return false
    }
}

// MARK: - 里程碑轨道

/// 里程碑轨道模型：长途倒数的驿站（100/365/520/1000/…天）
struct AnniversaryMilestoneInfo: Equatable {
    /// 里程碑档位（天）
    static let thresholds: [Int] = [100, 365, 520, 1000, 2000, 3650]

    struct Mark: Equatable, Identifiable {
        let days: Int
        let state: State
        var id: Int { days }

        enum State { case reached, now, upcoming }
    }

    /// 自起点至今的总天数
    let totalDays: Int

    /// 已达成的里程碑
    var reached: [Int] {
        Self.thresholds.filter { $0 <= totalDays }
    }

    /// 下一个里程碑（nil = 全部达成）
    var nextThreshold: Int? {
        Self.thresholds.first { $0 > totalDays }
    }

    /// 距下一个里程碑还有几天（nil = 全部达成）
    var daysToNext: Int? {
        guard let next = nextThreshold else { return nil }
        return next - totalDays
    }

    /// 今天恰好是里程碑日
    var isMilestoneToday: Bool {
        Self.thresholds.contains(totalDays)
    }

    /// 轨道视图用的标记序列：已达成（最多最近 3 个）+ 当天（若有）+ 下一个
    var trackMarks: [Mark] {
        var marks = reached.suffix(3).map { Mark(days: $0, state: .reached) }
        if isMilestoneToday, let current = reached.last, current == totalDays {
            marks[marks.count - 1] = Mark(days: current, state: .now)
        }
        if let next = nextThreshold {
            marks.append(Mark(days: next, state: .upcoming))
        }
        return marks
    }
}
