//
//  TaskStatsViewModel.swift
//  Holo
//
//  统计页视图模型（方案 §7/§9.3/§7.10）：期间选择与请求版本化加载；
//  失败保留上次结果；快照与明细同源；当前待处理不随期间过滤。
//

import Foundation
import SwiftUI
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

    var analytics: TaskAnalyticsSnapshot? { result?.analytics }

    private let service = TaskAnalyticsService.shared
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

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
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
            guard service.isCurrent(version) else { return } // 旧响应丢弃（§7.10）
            result = loaded
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

    /// 完整日期范围（「2026年10月5日—10月11日」，跨年时终点带年份；进行中补「截至…」，§7.2）
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
        var title = "\(startFormatter.string(from: analytics.start))—\(endFormatter.string(from: analytics.endExclusive.addingTimeInterval(-1)))"
        if analytics.isOngoing {
            let asOfFormatter = DateFormatter()
            asOfFormatter.locale = Locale(identifier: "zh_CN")
            asOfFormatter.dateFormat = "M月d日 HH:mm"
            title += String(localized: "（截至") + asOfFormatter.string(from: analytics.asOf) + String(localized: "）")
        }
        return title
    }

    /// 对比差值文案（数量差，不显示百分比增长，§7.6-6）
    func deltaText(_ delta: Int, unit: String = String(localized: "项")) -> String {
        if delta > 0 { return String(localized: "较上期多 \(delta) \(unit)") }
        if delta < 0 { return String(localized: "较上期少 \(-delta) \(unit)") }
        return String(localized: "与上期持平")
    }

    /// 明细行
    func record(for id: UUID) -> TaskRecordSnapshot? {
        result?.recordsByID[id]
    }
}
