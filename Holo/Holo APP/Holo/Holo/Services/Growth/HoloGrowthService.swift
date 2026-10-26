// 共享积累状态：后台聚合、防抖串行刷新、首轮静默、失败保留可信值。
import Foundation
import CoreData
import Combine
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import OSLog

extension Notification.Name {
    static let holoGrowthDidChange = Notification.Name("holoGrowthDidChange")
    static let holoGrowthDidReset = Notification.Name("holoGrowthDidReset")
}

@MainActor
final class HoloGrowthService: ObservableObject {
    static let shared = HoloGrowthService()
    @Published private(set) var snapshot: HoloGrowthSnapshot?
    @Published private(set) var milestones: [HoloGrowthMilestone] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDownloading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var celebration: HoloGrowthMilestone?
    @Published private(set) var remindersEnabled = true
    private var observers: [NSObjectProtocol] = []
    private var syncSubscription: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh = false
    private var pendingMetric: HoloGrowthMetric?
    private var generation = 0
    private var isRefreshing = false
    private let logger = Logger(subsystem: "com.holo.app", category: "Growth")
    private let loadResult: (Bool) async throws -> HoloGrowthStore.Result
    private let saveReminders: (Bool) async throws -> Void
    private let observesChanges: Bool
    private init() {
        observesChanges = true
        saveReminders = { enabled in
            try await CoreDataStack.shared.performBackgroundTask { context in
                try HoloGrowthStore.setReminders(enabled, context: context)
            }
        }
        loadResult = { persist in
            await CoreDataStack.shared.waitUntilReady()
            return try await CoreDataStack.shared.performBackgroundTask { context in
                try HoloGrowthStore.load(context: context, now: Date(), persist: persist)
            }
        }
    }
    #if DEBUG
    /// 自动验收仅连接独立内存库，禁止向用户的日用/CloudKit 库造数。
    init(validationContext: NSManagedObjectContext) {
        observesChanges = false
        saveReminders = { enabled in
            try await validationContext.perform {
                try HoloGrowthStore.setReminders(enabled, context: validationContext)
            }
        }
        loadResult = { persist in
            try await validationContext.perform {
                try HoloGrowthStore.load(context: validationContext, now: Date(), persist: persist)
            }
        }
    }
    #endif

    func start() {
        guard observesChanges, observers.isEmpty else { return }
        for (name, metric) in [(Notification.Name.financeDataDidChange, HoloGrowthMetric.finance),
                               (.thoughtDataDidChange, .thought), (.habitDataDidChange, .habit)] {
            observe(name) { [weak self] in self?.schedule(metric: metric) }
        }
        // 兜住未广播模块通知的写入入口（例如快捷记录/Agent）。只在保存所属队列
        // 提取实体名和上下文身份，跨队列不传托管对象；偏好事件保存不会触发自循环。
        let mainContext = CoreDataStack.shared.viewContext
        let coordinator = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
        observers.append(NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { [weak self] note in
            guard let context = note.object as? NSManagedObjectContext,
                  context.persistentStoreCoordinator === coordinator else { return }
            var metrics = Set<HoloGrowthMetric>()
            for key in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
                let objects = note.userInfo?[key] as? Set<NSManagedObject> ?? []
                for row in objects {
                    switch row.entity.name {
                    case "Transaction", "Account": metrics.insert(.finance)
                    case "Thought": metrics.insert(.thought)
                    case "Habit", "HabitRecord": metrics.insert(.habit)
                    default: break
                    }
                }
            }
            guard !metrics.isEmpty else { return }
            let metric = context === mainContext && metrics.count == 1 ? metrics.first : nil
            Task { @MainActor [weak self] in self?.schedule(metric: metric) }
        })
        observe(.holoCloudDataDidSync) { [weak self] in self?.schedule(metric: nil) }
        #if canImport(UIKit)
        observe(UIApplication.didBecomeActiveNotification) { [weak self] in self?.schedule(metric: nil) }
        #else
        observe(NSApplication.didBecomeActiveNotification) { [weak self] in self?.schedule(metric: nil) }
        #endif
        observe(.NSCalendarDayChanged) { [weak self] in self?.schedule(metric: nil) }
        observe(.NSSystemTimeZoneDidChange) { [weak self] in self?.schedule(metric: nil) }
        observe(.holoGrowthDidReset) { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.snapshot = nil
            self.milestones = []
            self.celebration = nil
            self.schedule(metric: nil)
        }
        if CloudKitRuntimeAvailability.isAvailable {
            syncSubscription = ICloudSyncStatusService.shared.$isDownloading.removeDuplicates().sink { [weak self] value in
                self?.isDownloading = value
                if !value { self?.schedule(metric: nil) }
            }
        }
        schedule(metric: nil)
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        })
    }

    private func schedule(metric: HoloGrowthMetric?) {
        // 一旦合并窗口包含同步/不同模块，就保持静默，后来的本地广播不能重新放行。
        if !pendingRefresh { pendingMetric = metric }
        else if pendingMetric != metric { pendingMetric = nil }
        pendingRefresh = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.refreshTask = nil
            await self.refresh()
        }
    }

    func refresh() async {
        start()
        guard !isRefreshing else { pendingRefresh = true; return }
        isRefreshing = true
        repeat {
            pendingRefresh = false
            let metric = pendingMetric
            pendingMetric = nil
            let revision = generation
            isLoading = true
            do {
                let shouldPersist = !isDownloading
                let result = try await loadResult(shouldPersist)
                guard revision == generation else { continue }
                if shouldPersist && !isDownloading {
                    let eventsChanged = milestones != result.events
                    if result.remindersEnabled {
                        celebration = HoloGrowthRules.celebration(previous: snapshot, current: result.snapshot,
                            existing: result.previousEvents, events: result.events, localMetric: metric) ?? celebration
                    } else { celebration = nil }
                    snapshot = result.snapshot
                    milestones = result.events
                    remindersEnabled = result.remindersEnabled
                    if eventsChanged { NotificationCenter.default.post(name: .holoGrowthDidChange, object: nil) }
                }
                errorMessage = nil
            } catch {
                logger.error("积累统计失败：\(error.localizedDescription, privacy: .public)")
                errorMessage = "暂时没能整理积累，请稍后重试"
            }
        } while pendingRefresh
        isLoading = false
        isRefreshing = false
    }

    func setRemindersEnabled(_ enabled: Bool) async {
        do {
            try await saveReminders(enabled)
            remindersEnabled = enabled
            if !enabled { celebration = nil }
        } catch { errorMessage = "提醒设置未能保存，请重试" }
    }

    func dismissCelebration() { celebration = nil }
}
