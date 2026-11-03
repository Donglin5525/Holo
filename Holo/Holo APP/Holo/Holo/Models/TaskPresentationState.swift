//
//  TaskPresentationState.swift
//  Holo
//
//  任务多视图的会话状态（多视图方案 §3.2）：视图切换、日历选中日、展示月份、
//  月览/日程、显示已完成。由 TasksView 以 @StateObject 持有并注入任务子页——
//  模块内统计/纪念日往返不销毁，从首页新进入或冷启动才创建新会话（默认日历）。
//  视图选择只在会话内保留，不读写旧 taskPresentation.v1.mode；
//  月览/日程与显示已完成是日历自身的独立偏好，可跨会话记住。
//

import Foundation
import Combine

// MARK: - 视图模式

/// 任务页顶部三段：日历 / 四象限 / 列表
enum TaskViewMode: String, CaseIterable, Identifiable {
    case calendar
    case matrix
    case list

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .calendar: return String(localized: "日历")
        case .matrix: return String(localized: "四象限")
        case .list: return String(localized: "列表")
        }
    }

    var iconName: String {
        switch self {
        case .calendar: return "calendar"
        case .matrix: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }

    /// 异常持久值回日历（§3.2）；本版视图选择本就不持久化，防御原始值入口
    static func safe(_ raw: String?) -> TaskViewMode {
        TaskViewMode(rawValue: raw ?? "") ?? .calendar
    }
}

// MARK: - 日历二级模式

/// 日历内部模式：月览 / 单日日程（独立偏好，跨会话记住上次，首次月览）
enum TaskCalendarMode: String {
    case month
    case day

    static let preferenceKey = "taskPresentation.v1.calendarMode"

    static func loadPreferred() -> TaskCalendarMode {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .month
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.preferenceKey)
    }
}

// MARK: - 会话对象

/// 任务页展示会话：一次模块进入周期内的视图与日历状态。
/// 「今天」以注入时钟计算（测试可注入固定时钟，方案 §11）。
@MainActor
final class TaskPresentationSession: ObservableObject {

    @Published var viewMode: TaskViewMode = .calendar
    /// 日历选中日（冷启动今天；同次打开保留）
    @Published private(set) var selectedDay: Date
    /// 展示月份锚点（与选中日所在月保持一致）
    @Published private(set) var displayedMonth: Date

    /// 月览 / 日程（独立偏好，记住上次）
    @Published var calendarMode: TaskCalendarMode {
        didSet { calendarMode.persist() }
    }

    /// 日历「显示已完成」（独立偏好，首次关；只影响日历投影）
    @Published var calendarShowsCompleted: Bool {
        didSet { UserDefaults.standard.set(calendarShowsCompleted, forKey: Self.showsCompletedKey) }
    }

    /// 会话是否已离开日历视图又回来（V02：日期按会话规则恢复，由本对象天然承载）
    private let startOfToday: Date

    private static let showsCompletedKey = "taskPresentation.v1.calendarShowsCompleted"

    init(now: Date = Date()) {
        let calendar = TaskAnalyticsPeriod.makeCalendar()
        let today = calendar.startOfDay(for: now)
        self.startOfToday = today
        self.selectedDay = today
        self.displayedMonth = today
        self.calendarMode = TaskCalendarMode.loadPreferred()
        self.calendarShowsCompleted = UserDefaults.standard.object(forKey: Self.showsCompletedKey) as? Bool ?? false
    }

    private var calendar: Calendar { TaskAnalyticsPeriod.makeCalendar() }

    // MARK: 日期选择与导航（§5.1）

    /// 点击日期：只改选择与月份，不弹新增
    func selectDay(_ day: Date) {
        let start = calendar.startOfDay(for: day)
        selectedDay = start
        displayedMonth = start
    }

    /// 月览前后箭头：每次一月，保持日号并夹到目标月最后一天（1/31 → 2/28）
    func shiftMonth(direction: Int) {
        let current = calendar.dateComponents([.year, .month, .day], from: selectedDay)
        var target = DateComponents()
        target.year = current.year
        target.month = (current.month ?? 1) + direction
        target.day = 1
        guard let firstOfMonth = calendar.date(from: target) else { return }
        let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        target.day = min(current.day ?? 1, daysInMonth)
        guard let shifted = calendar.date(from: target) else { return }
        selectedDay = shifted
        displayedMonth = shifted
    }

    /// 日程前后箭头：每次一周（±7 个日历日），跨月同步年月
    func shiftWeek(direction: Int) {
        guard let shifted = calendar.date(byAdding: .day, value: 7 * direction, to: selectedDay) else { return }
        selectedDay = calendar.startOfDay(for: shifted)
        displayedMonth = selectedDay
    }

    /// 「今天」：回真实今天并切对应月
    func goToday() {
        selectedDay = startOfToday
        displayedMonth = startOfToday
    }

    // MARK: 创建/编辑后的日历定位（§5.4/§7.2）

    /// 计划保存或创建成功后：选中新的计划日，月标题同步
    func revealDay(_ day: Date) {
        selectDay(day)
    }

    var isTodaySelected: Bool {
        calendar.isDate(selectedDay, inSameDayAs: startOfToday)
    }
}

// MARK: - 计划默认时段（§5.3）

nonisolated enum TaskPlannedTimeDefaults {

    /// 新安排的默认时段：今天 = 下一个 15 分钟刻度起一小时（无法保持同日一小时
    /// 缩到 23:59，日期不变）；其他日 = 09:00–10:00。默认值只落草稿，用户保存前可见。
    static func defaultRange(on day: Date, from now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let dayStart = calendar.startOfDay(for: day)
        if calendar.isDate(day, inSameDayAs: now) {
            let hour = calendar.component(.hour, from: now)
            let minute = calendar.component(.minute, from: now)
            let nextQuarter = (minute / 15 + 1) * 15
            var startHour = hour
            var startMinute = nextQuarter
            if startMinute >= 60 {
                startMinute = 0
                startHour += 1
            }
            // 23 点后无完整一小时余量：起夹 23:45 前的刻度，止夹 23:59（保日期）
            startHour = min(startHour, 23)
            startMinute = min(startMinute, 45)
            let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: dayStart)
                ?? dayStart
            let naiveEnd = calendar.date(byAdding: .hour, value: 1, to: start) ?? start
            if calendar.isDate(naiveEnd, inSameDayAs: start) {
                return (start, naiveEnd)
            }
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: dayStart) ?? start
            return (start, end)
        }
        let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayStart) ?? dayStart
        let end = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: dayStart) ?? dayStart
        return (start, end)
    }

    /// 日程空白整点：该点起一小时；23 点至 23:59（不跨日，§5.2-10）
    static func hourSlot(day: Date, hour: Int, calendar: Calendar) -> (start: Date, end: Date) {
        let dayStart = calendar.startOfDay(for: day)
        let start = calendar.date(bySettingHour: min(hour, 23), minute: 0, second: 0, of: dayStart) ?? dayStart
        let end: Date
        if hour >= 23 {
            end = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: dayStart) ?? start
        } else {
            end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start
        }
        return (start, end)
    }
}
