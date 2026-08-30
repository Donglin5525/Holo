//
//  ScheduleSyncEngine.swift
//  Holo
//
//  任务→日历写入引擎（二期「写回去」执行层）
//  对账式同步：ScheduleSyncPlanner 出决策，本引擎采集三方快照、落地操作。
//  多设备一致性：映射经 CloudKit 共享；事件认领以 url 埋的任务 ID 为最终依据；
//  认领不到不重建（宽限后断开）——避免多设备双写。
//

import Foundation
import EventKit
import CoreData
import SwiftUI

@MainActor
final class ScheduleSyncEngine {

    static let shared = ScheduleSyncEngine()

    /// 任务写入日历开关（挂在日历集成总开关之下，默认开——东林拍板「带时间段自动同步」）
    @AppStorage("com.holo.schedule.taskSyncEnabled") var isTaskSyncEnabled: Bool = true

    /// Holo 专属日历名
    static let holoCalendarTitle = "Holo"

    /// 对账防抖
    private static let reconcileDebounce: TimeInterval = 1.0

    private var reconcileTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let calendar = Calendar.current

    private init() {
        // 任务数据变化 → 对账（覆盖所有写任务入口：详情页/Agent/想法转任务…）
        observers.append(NotificationCenter.default.addObserver(
            forName: .todoDataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReconcile() }
        })
        // 系统日历变化（含用户在日历 App 改 Holo 日历事件）→ 对账
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReconcile() }
        })
    }

    // MARK: - 触发

    func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.reconcileDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    /// 立即对账（写入开关开启/回前台时调用，同样经防抖合并）
    func reconcileNow() {
        scheduleReconcile()
    }

    var isReady: Bool {
        ScheduleStore.shared.isEnabled
            && ScheduleStore.shared.authorizationStatus == .fullAccess
            && isTaskSyncEnabled
    }

    // MARK: - 对账主流程

    func reconcile() async {
        guard isReady else { return }
        let store = ScheduleStore.shared
        guard let eventStore = await store.ensureEventStoreForSync() else { return }
        guard let holoCalendar = ensureHoloCalendar(in: eventStore) else { return }

        let tasks = collectTaskSnapshots()
        let events = collectEventSnapshots(in: holoCalendar, store: eventStore)
        let mirrors = collectMirrors()

        let operations = ScheduleSyncPlanner.plan(tasks: tasks, events: events, mirrors: mirrors)

        apply(operations, eventStore: eventStore, holoCalendar: holoCalendar)

        // 本轮认领到的映射刷新确认时间（宽限窗口滚动）
        refreshConfirmations(now: Date())
    }

    // MARK: - Holo 日历管理

    /// 找或建专属「Holo」日历；iCloud 源优先（事件跨设备），无则本地
    private func ensureHoloCalendar(in store: EKEventStore) -> EKCalendar? {
        let existing = store.calendars(for: .event).first {
            $0.title == Self.holoCalendarTitle && $0.allowsContentModifications
        }
        if let existing { return existing }

        // 被用户改名/删除后重建：允许写入的源里选 iCloud，退而求其次 local
        let source = store.sources.first { $0.sourceType == .calDAV && $0.title.contains("iCloud") }
            ?? store.sources.first { $0.sourceType == .calDAV }
            ?? store.sources.first { $0.sourceType == .local }
        guard let source else { return nil }

        let newCalendar = EKCalendar(for: .event, eventStore: store)
        newCalendar.title = Self.holoCalendarTitle
        newCalendar.source = source
        do {
            try store.saveCalendar(newCalendar, commit: true)
            return newCalendar
        } catch {
            return nil
        }
    }

    // MARK: - 快照采集

    private func collectTaskSnapshots() -> [SyncTaskSnapshot] {
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        request.predicate = NSPredicate(format: "plannedStart != nil")
        guard let tasks = try? context.fetch(request) else { return [] }
        return tasks.map { task in
            SyncTaskSnapshot(
                taskId: task.id,
                title: task.title,
                plannedStart: task.plannedStart,
                plannedEnd: task.plannedEnd,
                completed: task.completed,
                deleted: task.deletedFlag || task.deletedAt != nil,
                archived: task.archived,
                updatedAt: task.updatedAt
            )
        }
    }

    private func collectEventSnapshots(in holoCalendar: EKCalendar, store: EKEventStore) -> [SyncEventSnapshot] {
        let start = calendar.date(byAdding: .year, value: -3, to: Date()) ?? Date()
        let end = calendar.date(byAdding: .year, value: 3, to: Date()) ?? Date()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [holoCalendar])
        return store.events(matching: predicate).map { event in
            SyncEventSnapshot(
                eventIdentifier: event.eventIdentifier,
                claimedTaskId: Self.taskId(fromEventURL: event.url),
                title: event.title ?? "",
                startDate: event.startDate,
                endDate: event.endDate,
                lastModifiedDate: event.lastModifiedDate
            )
        }
    }

    private func collectMirrors() -> [SyncMirrorSnapshot] {
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<TaskScheduleMirror>(entityName: "TaskScheduleMirror")
        guard let mirrors = try? context.fetch(request) else { return [] }
        return mirrors.map { mirror in
            SyncMirrorSnapshot(
                taskId: mirror.taskId,
                eventIdentifier: mirror.eventIdentifier,
                state: mirror.state,
                lastSyncedStart: mirror.lastSyncedStart,
                lastSyncedEnd: mirror.lastSyncedEnd,
                lastSyncedTitle: mirror.lastSyncedTitle,
                lastSyncedAt: mirror.lastSyncedAt,
                lastConfirmedAt: mirror.lastConfirmedAt
            )
        }
    }

    /// 事件 url 埋的任务标识：holo-task://<uuid>
    static func taskId(fromEventURL url: URL?) -> UUID? {
        guard let url, url.scheme == "holo-task" else { return nil }
        return UUID(uuidString: url.host ?? url.absoluteString.replacingOccurrences(of: "holo-task://", with: ""))
    }

    static func eventURL(for taskId: UUID) -> URL {
        URL(string: "holo-task://\(taskId.uuidString)")!
    }

    // MARK: - 操作落地

    private func apply(_ operations: [ScheduleSyncOperation], eventStore: EKEventStore, holoCalendar: EKCalendar) {
        guard !operations.isEmpty else { return }
        let context = CoreDataStack.shared.viewContext

        for operation in operations {
            switch operation {
            case .createEvent(let task):
                let event = EKEvent(eventStore: eventStore)
                event.calendar = holoCalendar
                event.title = task.title
                event.startDate = task.plannedStart ?? Date()
                event.endDate = task.plannedEnd ?? Date()
                event.url = Self.eventURL(for: task.taskId)
                do {
                    try eventStore.save(event, span: .thisEvent)
                    let mirror = TaskScheduleMirror(context: context)
                    mirror.id = UUID()
                    mirror.taskId = task.taskId
                    mirror.eventIdentifier = event.eventIdentifier
                    mirror.calendarIdentifier = holoCalendar.calendarIdentifier
                    mirror.lastSyncedStart = task.plannedStart
                    mirror.lastSyncedEnd = task.plannedEnd
                    mirror.lastSyncedTitle = task.title
                    mirror.lastSyncedAt = Date()
                    mirror.lastConfirmedAt = Date()
                    mirror.state = "active"
                    mirror.createdAt = Date()
                    try? context.save()
                } catch {
                    continue
                }

            case .updateEvent(let task, let eventIdentifier):
                guard let event = eventStore.event(withIdentifier: eventIdentifier) else { continue }
                event.title = task.title
                event.startDate = task.plannedStart ?? event.startDate
                event.endDate = task.plannedEnd ?? event.endDate
                do {
                    try eventStore.save(event, span: .thisEvent)
                    updateMirror(taskId: task.taskId, context: context) { mirror in
                        mirror.lastSyncedStart = task.plannedStart
                        mirror.lastSyncedEnd = task.plannedEnd
                        mirror.lastSyncedTitle = task.title
                        mirror.lastSyncedAt = Date()
                    }
                } catch {
                    continue
                }

            case .updateTask(let taskId, let title, let plannedStart, let plannedEnd):
                // 回流任务：不触发通知循环（repository.updateTask 会发 todoDataDidChange → 防抖后再对账为 no-op）
                guard let task = fetchTask(id: taskId) else { continue }
                try? TodoRepository.shared.updateTask(
                    task,
                    title: title,
                    plannedTime: .set(start: plannedStart, end: plannedEnd)
                )
                updateMirror(taskId: taskId, context: context) { mirror in
                    mirror.lastSyncedStart = plannedStart
                    mirror.lastSyncedEnd = plannedEnd
                    mirror.lastSyncedTitle = title
                    mirror.lastSyncedAt = Date()
                }

            case .deleteEventAndMirror(let eventIdentifier, let taskId):
                if let event = eventStore.event(withIdentifier: eventIdentifier) {
                    try? eventStore.remove(event, span: .thisEvent)
                }
                if let mirror = fetchMirror(taskId: taskId) {
                    context.delete(mirror)
                    try? context.save()
                }

            case .disconnectMirror(let taskId):
                updateMirror(taskId: taskId, context: context) { mirror in
                    mirror.state = "disconnected"
                    mirror.lastSyncedAt = Date()
                }
            }
        }
    }

    // MARK: - 持久化辅助

    private func updateMirror(taskId: UUID, context: NSManagedObjectContext, _ mutate: (TaskScheduleMirror) -> Void) {
        guard let mirror = fetchMirror(taskId: taskId) else { return }
        mutate(mirror)
        try? context.save()
    }

    private func fetchMirror(taskId: UUID) -> TaskScheduleMirror? {
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<TaskScheduleMirror>(entityName: "TaskScheduleMirror")
        request.predicate = NSPredicate(format: "taskId == %@", taskId as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func fetchTask(id: UUID) -> TodoTask? {
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// 本轮认领到的 active 映射统一刷新确认时间
    private func refreshConfirmations(now: Date) {
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<TaskScheduleMirror>(entityName: "TaskScheduleMirror")
        request.predicate = NSPredicate(format: "state == %@ AND lastConfirmedAt < %@", "active", now as NSDate)
        guard let mirrors = try? context.fetch(request), !mirrors.isEmpty else { return }
        mirrors.forEach { $0.lastConfirmedAt = now }
        try? context.save()
    }
}
