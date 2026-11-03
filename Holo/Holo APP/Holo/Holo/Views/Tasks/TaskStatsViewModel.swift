//
//  TaskStatsViewModel.swift
//  Holo
//
//  统计页视图模型（方案 §7/§9.3/§7.10）：期间选择与请求版本化加载；
//  失败保留上次结果；快照与明细同源；当前待处理不随期间过滤。
//

import Foundation
import SwiftUI
#if canImport(UIKit)
#else
import AppKit
#endif
import Combine

@MainActor
final class TaskStatsViewModel: ObservableObject {

    // MARK: - 期间状态

    enum PeriodKind: String, CaseIterable {
        case week, month, year, custom

        var title: String {
            switch self {
            case .week: return String(localized: "本周")
            case .month: return String(localized: "本月")
            case .year: return String(localized: "本年")
            case .custom: return String(localized: "自定义")
            }
        }
    }

    @Published var kind: PeriodKind = .week
    /// 周期锚定（周/月/年）；自定义的起止
    @Published var weekAnchor: Date = Date()
    @Published var monthAnchor: Date = Date()
    @Published var yearAnchor: Date = Date()
    @Published var customStart: Date = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    @Published var customEnd: Date = Calendar.current.startOfDay(for: Date())

    var period: TaskAnalyticsPeriod {
        switch kind {
        case .week: return .week(anchorDay: weekAnchor)
        case .month: return .month(anchorDay: monthAnchor)
        case .year: return .year(anchorDay: yearAnchor)
        case .custom: return .custom(startDay: customStart, endDay: customEnd)
        }
    }

    // MARK: - 结果状态

    @Published private(set) var result: TaskAnalyticsService.Result?
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var loadFailed: Bool = false
    /// 明细打开期间数据更新提示（§7.10）
    @Published private(set) var dataUpdatedWhileViewing: Bool = false
    /// Today 计划对账（仅周档有值；P2）
    @Published private(set) var todayPlanWeek: TodayPlanWeek?

    /// Today 计划周对账（nil 日 = 当日无显式计划或计划不可读）
    struct TodayPlanDay: Equatable {
        let date: Date
        let planned: Int
        let done: Int
    }
    struct TodayPlanWeek: Equatable {
        let days: [TodayPlanDay?]
        var plannedTotal: Int { days.compactMap(\.self).map(\.planned).reduce(0, +) }
        var doneTotal: Int { days.compactMap(\.self).map(\.done).reduce(0, +) }
    }

    var analytics: TaskAnalyticsSnapshot? { result?.analytics }

    private let service = TaskAnalyticsService.shared
    private let todayRepository = HoloTodayPlanRepository(context: CoreDataStack.shared.viewContext)
    private var cancellables: Set<AnyCancellable> = []

    var calendar: Calendar { TaskAnalyticsPeriod.makeCalendar() }

    init() {
        // 期间一切变化（含自定义起止日）→ 全部内容一起重算（§7.2 末段）。
        // MergeMany 可变参数要求同型，异构发布者走数组 + 类型擦除
        let periodChanges: [AnyPublisher<Void, Never>] = [
            $kind.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $weekAnchor.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $monthAnchor.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $yearAnchor.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $customStart.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $customEnd.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(periodChanges)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.reload()
        }
        .store(in: &cancellables)

        // 数据变化刷新（保存/完成/归档/删除/云端合并，§7.10）
        NotificationCenter.default.publisher(for: .todoDataDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload(markUpdated: true) }
            .store(in: &cancellables)

        #if canImport(UIKit)
        let activeName = UIApplication.didBecomeActiveNotification
        #else
        let activeName = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.publisher(for: activeName)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload(markUpdated: true) }
            .store(in: &cancellables)
    }

    // MARK: - 加载

    func reload(markUpdated: Bool = false) {
        let version = service.nextRequestVersion()
        isLoading = result == nil
        do {
            let loaded = try service.load(period: period, calendar: calendar)
            guard service.isCurrent(version) else { return } // 旧响应丢弃（§9.10）
            result = loaded
            reloadTodayPlanWeek(from: loaded)
            isLoading = false
            loadFailed = false
            if markUpdated {
                dataUpdatedWhileViewing = true
            }
        } catch {
            guard service.isCurrent(version) else { return }
            // 失败保留上次结果（§9.4）
            isLoading = false
            loadFailed = true
        }
    }

    func clearUpdatedFlag() {
        dataUpdatedWhileViewing = false
    }

    // MARK: - Today 计划对账（周档，P2）

    /// 逐日读 Today 计划 head：显式计划日的 entries 数为「计划」，
    /// entries 中完成时间落当日的为「完成」；无计划/继承基础/不可读 = nil 日。
    private func reloadTodayPlanWeek(from loaded: TaskAnalyticsService.Result) {
        guard case .week = kind else {
            todayPlanWeek = nil
            return
        }
        let timeZone = calendar.timeZone
        var days: [TodayPlanDay?] = []
        var cursor = loaded.analytics.start
        while cursor < loaded.analytics.endExclusive {
            let scope = HoloTodayDayScope(referenceTime: cursor, calendar: calendar, timeZone: timeZone)
            if case .active(let payload, _) = todayRepository.currentPlan(scope: scope).state,
               payload.selectionMode == .explicit {
                let done = payload.entries.filter { entry in
                    guard let record = loaded.recordsByID[entry.taskID],
                          let completedAt = record.completedAt else { return false }
                    return completedAt >= scope.dayStart && completedAt < scope.dayEnd
                }.count
                days.append(TodayPlanDay(date: scope.dayStart, planned: payload.entries.count, done: done))
            } else {
                days.append(nil)
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        todayPlanWeek = TodayPlanWeek(days: days)
    }

    // MARK: - 周期切换（左右箭头，§7.2）

    var canGoPrevious: Bool { true }

    var canGoNext: Bool {
        TaskAnalyticsPeriodResolver.nextAllowed(period, asOf: Date(), calendar: calendar)
    }

    func goPrevious() {
        let previous = TaskAnalyticsPeriodResolver.previous(of: period, calendar: calendar)
        apply(previous)
    }

    func goNext() {
        guard canGoNext else { return }
        let next = TaskAnalyticsPeriodResolver.next(of: period, calendar: calendar)
        apply(next)
    }

    private func apply(_ period: TaskAnalyticsPeriod) {
        switch period {
        case .week(let anchor):
            kind = .week
            weekAnchor = anchor
        case .month(let anchor):
            kind = .month
            monthAnchor = anchor
        case .year(let anchor):
            kind = .year
            yearAnchor = anchor
        case .custom(let start, let end):
            kind = .custom
            customStart = start
            customEnd = end
        }
        // kind/anchor 变化经 MergeMany 触发 reload；goPrevious/goNext 产生的新值必然不同
    }

    /// 自定义合法性（结束不得晚于今天；开始不得晚于结束，§7.2）
    var customValidationMessage: String? {
        let start = calendar.startOfDay(for: customStart)
        let end = calendar.startOfDay(for: customEnd)
        if start > end {
            return String(localized: "开始日期需要不晚于结束日期")
        }
        let today = calendar.startOfDay(for: Date())
        if end > today {
            return String(localized: "结束日期不能晚于今天")
        }
        return nil
    }

    // MARK: - 展示格式

    /// 完整日期范围（「2026年10月5日—10月11日」，跨年时终点带年份；§7.2）
    /// 「截至」信息独立为 asOfTitle 分层展示，避免长串括号混排不受控折行出孤行
    var rangeTitle: String {
        guard let analytics else { return "" }
        let calendar = TaskAnalyticsPeriod.makeCalendar()
        let startFormatter = DateFormatter()
        startFormatter.locale = Locale(identifier: "zh_CN")
        startFormatter.dateFormat = "yyyy年M月d日"
        let endFormatter = DateFormatter()
        endFormatter.locale = Locale(identifier: "zh_CN")
        let sameYear = calendar.component(.year, from: analytics.start)
            == calendar.component(.year, from: analytics.endExclusive.addingTimeInterval(-1))
        endFormatter.dateFormat = sameYear ? "M月d日" : "yyyy年M月d日"
        return "\(startFormatter.string(from: analytics.start))—\(endFormatter.string(from: analytics.endExclusive.addingTimeInterval(-1)))"
    }

    /// 进行中期间的统计时点（「截至10月14日 01:20」）；已完结期间为 nil（§7.2）
    var asOfTitle: String? {
        guard let analytics, analytics.isOngoing else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return String(localized: "截至\(formatter.string(from: analytics.asOf))")
    }

    /// 胶囊徽标：当前看的是哪一期（本周/上周/2周前…）；档位下拉菜单仍用 kind.title（§7.2 修复）
    var periodBadgeTitle: String {
        switch TaskAnalyticsPeriodResolver.position(of: period, asOf: Date(), calendar: calendar) {
        case .current:
            return kind.title
        case .previous:
            switch kind {
            case .week: return String(localized: "上周")
            case .month: return String(localized: "上月")
            case .year: return String(localized: "去年")
            case .custom: return kind.title
            }
        case .earlier(let count):
            switch kind {
            case .week:
                return String(localized: "\(count)周前")
            case .month:
                // 更早月份直接报月份名：当年「9月」、往年「2025年12月」（与 rangeTitle 同款中文格式）
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                let sameYear = calendar.component(.year, from: monthAnchor)
                    == calendar.component(.year, from: Date())
                formatter.dateFormat = sameYear ? "M月" : "yyyy年M月"
                return formatter.string(from: monthAnchor)
            case .year:
                let year = calendar.component(.year, from: yearAnchor)
                return String(localized: "\(year)年")
            case .custom:
                return kind.title
            }
        }
    }

    /// 对比差值文案（数量差，不显示百分比增长，§7.6-6）
    func deltaText(_ delta: Int, unit: String = String(localized: "项")) -> String {
        if delta > 0 { return String(localized: "较上期多 \(delta) \(unit)") }
        if delta < 0 { return String(localized: "较上期少 \(-delta) \(unit)") }
        return String(localized: "与上期持平")
    }

    /// 率差（百分点，如「+6%」）：上期无数值或持平时返回 nil
    func rateDeltaPercentage(_ current: Double?, _ previous: Double?) -> (text: String, positive: Bool)? {
        guard let current, let previous else { return nil }
        let points = Int(((current - previous) * 100).rounded())
        guard points != 0 else { return nil }
        return points > 0 ? ("+\(points)%", true) : ("\(points)%", false)
    }

    /// 明细行
    func record(for id: UUID) -> TaskRecordSnapshot? {
        result?.recordsByID[id]
    }
}
