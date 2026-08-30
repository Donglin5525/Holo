//
//  ScheduleStore.swift
//  Holo
//
//  系统日历只读服务（一期）
//  - 完全访问权限申请与状态流
//  - 日历来源管理（用户勾选哪些日历进 Holo）
//  - 双窗口读取：活跃窗口（前后3个月常驻）+ 任意日按需拉取（回放用）
//  - EKEventStoreChanged 无差别广播 → 防抖后重拉
//  - 日程完成态（单场实例粒度，仅本地）
//

import Foundation
import EventKit
import CoreData
import Combine
import SwiftUI

@MainActor
final class ScheduleStore: ObservableObject {

    static let shared = ScheduleStore()

    // MARK: - Published 状态

    /// 权限状态（.fullAccess 才可读日程）；authorizationStatus(for:) 为类方法，激活后刷新
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    /// 活跃窗口内、已勾选日历的日程（含完成态标记）
    @Published private(set) var schedules: [ScheduleItem] = []
    /// 设备上全部日历（设置页勾选用）
    @Published private(set) var availableCalendars: [ScheduleCalendarInfo] = []
    /// 完成态：外部标识 → 已完成的发生日集合
    @Published private(set) var completedDays: [String: Set<Date>] = [:]

    // MARK: - 用户设置

    /// 总开关（设置页「日历」入口）
    @AppStorage("com.holo.schedule.enabled") var isEnabled: Bool = false
    /// 勾选的日历 id 集合（JSON 数组）
    @AppStorage("com.holo.schedule.selectedCalendarIds") private var selectedCalendarIdsJSON: String = "[]"

    private var selectedCalendarIds: Set<String> {
        get {
            guard let data = selectedCalendarIdsJSON.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(ids)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)) {
                selectedCalendarIdsJSON = String(data: data, encoding: .utf8) ?? "[]"
            }
        }
    }

    // MARK: - 常量

    /// 活跃窗口半径（月）：前后各 3 个月常驻缓存
    static let activeWindowMonths = 3
    /// 变更通知防抖间隔
    private static let changeDebounceInterval: TimeInterval = 0.8

    // MARK: - 私有

    private var eventStore: EKEventStore?
    private var changeObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private let calendar = Calendar.current

    private init() {
        // 总开关打开时自动激活（冷启动恢复）
        if isEnabled {
            Task { await activate() }
        }
        // 回前台：权限可能在外部被改；后台期间日历可能有变更而变更通知未必送达 → 双兜底
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshAuthorizationStatus()
                if self.isEnabled, self.authorizationStatus == .fullAccess {
                    self.scheduleReload()
                }
            }
        }
    }

    /// 供 EventKitUI 呈现原始日程用（makeUIViewController 在主线程调用，EKEventStore 本身线程安全）
    nonisolated static var sharedEventStore: EKEventStore? {
        MainActor.assumeIsolated {
            shared.eventStore
        }
    }

    /// 供 Agent 数据源判定可用性（未开启/未授权返回 false → 工具层转空态）
    var isAvailableForAgent: Bool {
        isEnabled && authorizationStatus == .fullAccess && eventStore != nil
    }

    // 单例随 App 生命周期存活，无需 deinit 清理观察者

    // MARK: - 激活与权限

    /// 打开总开关后的入口：初始化 store → 申请权限 → 拉取
    func enable() async {
        isEnabled = true
        await activate()
    }

    func disable() {
        isEnabled = false
        schedules = []
        availableCalendars = []
        stopObservingChanges()
    }

    private func activate() async {
        guard let store = await ensureEventStore() else { return }
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            let granted = await requestFullAccess()
            if !granted { return }
        }
        refreshAuthorizationStatus()
        guard authorizationStatus == .fullAccess else { return }
        applyDefaultSelectionIfNeeded()
        refreshCalendars()
        await reloadActiveWindow()
        startObservingChanges()
    }

    /// EKEventStore 初始化可达数百毫秒，放后台队列，不卡调用方
    private func ensureEventStore() async -> EKEventStore? {
        if let eventStore { return eventStore }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let store = EKEventStore()
                Task { @MainActor in
                    self.eventStore = store
                    continuation.resume(returning: store)
                }
            }
        }
    }

    @discardableResult
    private func requestFullAccess() async -> Bool {
        guard let store = await ensureEventStore() else { return false }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        return granted
    }

    /// 权限被拒后的再次申请入口（设置页「去系统设置开启」之外的重试通道）
    func requestAccessAgain() async {
        guard let store = await ensureEventStore() else { return }
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = await requestFullAccess()
            if authorizationStatus == .fullAccess {
                await activate()
            }
            return
        }
        // denied 状态下系统不再弹窗，只能引导去系统设置
        refreshAuthorizationStatus()
    }

    private func refreshAuthorizationStatus() {
        guard let store = eventStore else {
            authorizationStatus = .notDetermined
            return
        }
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        // 权限被收回 → 日程展示自动隐退，不报错
        if authorizationStatus != .fullAccess {
            schedules = []
        }
    }

    // MARK: - 日历来源

    /// 首次开启时默认勾选：非订阅、非系统生日日历
    private func applyDefaultSelectionIfNeeded() {
        guard let store = eventStore else { return }
        let current = selectedCalendarIds
        guard current.isEmpty else { return }
        let defaults = defaultSelectedCalendarIds(from: store.calendars(for: .event))
        selectedCalendarIds = defaults
    }

    private func defaultSelectedCalendarIds(from calendars: [EKCalendar]) -> Set<String> {
        Set(calendars.filter { cal in
            cal.source.sourceType != .subscribed
                && cal.title != "Birthdays"
                && cal.title != "生日"
        }.map(\.calendarIdentifier))
    }

    func refreshCalendars() {
        guard let store = eventStore, authorizationStatus == .fullAccess else {
            availableCalendars = []
            return
        }
        availableCalendars = store.calendars(for: .event)
            .map { cal in
                ScheduleCalendarInfo(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    color: Color(cal.cgColor),
                    isSubscribed: cal.source.sourceType == .subscribed,
                    isSelected: selectedCalendarIds.contains(cal.calendarIdentifier)
                )
            }
            .sorted { $0.title < $1.title }
    }

    func toggleCalendarSelection(_ id: String) {
        var ids = selectedCalendarIds
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        selectedCalendarIds = ids
        refreshCalendars()
        Task { await reloadActiveWindow() }
    }

    private var selectedEKCalendars: [EKCalendar]? {
        guard let store = eventStore else { return nil }
        let all = store.calendars(for: .event)
        let selected = all.filter { selectedCalendarIds.contains($0.calendarIdentifier) }
        return selected.isEmpty ? nil : selected
    }

    // MARK: - 读取（双窗口）

    /// 活跃窗口：今天前后各 3 个月，常驻 @Published schedules
    func reloadActiveWindow() async {
        guard isEnabled, authorizationStatus == .fullAccess, let store = eventStore else {
            schedules = []
            return
        }
        let now = Date()
        let start = calendar.date(byAdding: .month, value: -Self.activeWindowMonths, to: now) ?? now
        let end = calendar.date(byAdding: .month, value: Self.activeWindowMonths, to: now) ?? now
        schedules = await fetchItems(from: start, to: end, store: store)
    }

    /// 回放按需拉取：任意历史/未来日，结果不常驻（三期长廊回放与 Agent 查询用）
    func fetchSchedules(onDay day: Date) async -> [ScheduleItem] {
        guard isEnabled, authorizationStatus == .fullAccess, let store = eventStore else { return [] }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? day
        return await fetchItems(from: start, to: end, store: store)
    }

    private func fetchItems(from start: Date, to end: Date, store: EKEventStore) async -> [ScheduleItem] {
        let calendars = selectedEKCalendars
        return await Task.detached(priority: .userInitiated) { [calendar] in
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            let events = store.events(matching: predicate)
            let items = events.map(ScheduleItem.init)
            return items.sorted { $0.startDate < $1.startDate }
        }.value
    }

    /// 活跃窗口缓存里某天的日程（视图常用入口，避免重复查询）
    nonisolated func cachedSchedules(onDay day: Date) -> [ScheduleItem] {
        // @Published 读取需在 MainActor；此处仅做值过滤，由调用侧（主线程视图）保证
        MainActor.assumeIsolated {
            let day = Calendar.current.startOfDay(for: day)
            let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
            return schedules.filter { item in
                item.startDate < next && item.endDate > day
            }.sorted { $0.startDate < $1.startDate }
        }
    }

    // MARK: - 变更监听（无差别广播 → 防抖）

    private func startObservingChanges() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleReload()
            }
        }
    }

    private func stopObservingChanges() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.changeDebounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleStoreChanged()
        }
    }

    private func handleStoreChanged() async {
        guard isEnabled, authorizationStatus == .fullAccess else { return }
        refreshCalendars()
        await reloadActiveWindow()
    }

    // MARK: - 完成态（单场实例粒度，JSON 文件本地存储）

    /// 完成记录（量级小：一天数条，全量内存过滤足够；避免入 CoreData 触发 CloudKit schema 追加部署）
    private struct CompletionRecord: Codable {
        var externalId: String
        var occurrenceDay: Date
        var completedAt: Date
    }

    private var completionRecords: [CompletionRecord] = []
    private var completionsNeedLoad = true

    private var completionsFileURL: URL {
        URL.documentsDirectory.appendingPathComponent("schedule-completions.json")
    }

    /// 启动时调用或首次使用时惰性加载
    func loadCompletions() {
        guard completionsNeedLoad else { return }
        completionsNeedLoad = false
        guard let data = try? Data(contentsOf: completionsFileURL),
              let records = try? JSONDecoder().decode([CompletionRecord].self, from: data) else {
            completionRecords = []
            return
        }
        completionRecords = records
        rebuildCompletedDays()
    }

    private func rebuildCompletedDays() {
        var result: [String: Set<Date>] = [:]
        for record in completionRecords {
            result[record.externalId, default: []].insert(record.occurrenceDay)
        }
        completedDays = result
    }

    private func persistCompletions() {
        if let data = try? JSONEncoder().encode(completionRecords) {
            try? data.write(to: completionsFileURL, options: .atomic)
        }
    }

    func isCompleted(_ item: ScheduleItem) -> Bool {
        loadCompletionsIfNeeded()
        return completedDays[item.completionKey]?.contains(item.occurrenceDay) ?? false
    }

    /// 勾/取消一场日程的完成态（仅 Holo 本地，不写系统日历）
    func setCompleted(_ item: ScheduleItem, _ completed: Bool) {
        loadCompletionsIfNeeded()
        let key = item.completionKey
        if completed {
            guard !(completedDays[key]?.contains(item.occurrenceDay) ?? false) else { return }
            completionRecords.append(
                CompletionRecord(externalId: key, occurrenceDay: item.occurrenceDay, completedAt: Date())
            )
        } else {
            completionRecords.removeAll {
                $0.externalId == key && $0.occurrenceDay == item.occurrenceDay
            }
        }
        persistCompletions()
        rebuildCompletedDays()
    }

    private func loadCompletionsIfNeeded() {
        if completionsNeedLoad { loadCompletions() }
    }
}

// MARK: - 日历信息（设置页勾选清单用）

struct ScheduleCalendarInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let color: Color
    let isSubscribed: Bool
    let isSelected: Bool

    static func == (lhs: ScheduleCalendarInfo, rhs: ScheduleCalendarInfo) -> Bool {
        lhs.id == rhs.id && lhs.isSelected == rhs.isSelected
    }
}
