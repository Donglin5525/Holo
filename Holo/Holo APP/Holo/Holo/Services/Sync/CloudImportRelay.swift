//
//  CloudImportRelay.swift
//  Holo
//
//  iCloud 云端数据到达中继
//  NSPersistentCloudKitContainer 把远端数据导入本地 store 后不带任何业务回调，
//  各模块又只在本地写入时广播自己的 *DataDidChange，于是第二台设备上
//  「首启一次性加载跑在后台导入之前」的时序会让列表永远停在空态
//  （iPad 新装机数据不同步的根因）。
//
//  这里监听 CloudKit 同步引擎的 import 事件成功结束，合并后广播
//  holoCloudDataDidSync，各模块订阅这一条通知重拉各自数据。
//  刻意不用 NSPersistentStoreRemoteChange：那条通知在本地保存时同样会发，
//  会让所有模块在每次写入后多跑一轮无意义重拉。
//
//  2026-10-09 C1（掉帧治理第一批）：旧实现 setup/import 事件一到达（无论
//  开始、失败、结束）就当「批次落地」调度广播，且去尾防抖会被连续批次无限
//  重置。现改为：只认主生活容器、已结束、succeeded 且无 error 的 import
//  （setup 成功仅进程内首次作为新设备首载兜底——引擎就绪不等于数据已导入）；
//  同一事件的成功结束只消费一次；尾部合并 500ms、窗口上限 2s，持续导入
//  期间最多每 2s 发布一轮；广播携带合并批次数供打点对时。
//

import Foundation
import CoreData
import os.log

extension Notification.Name {
    /// iCloud 云端数据已同步到本地（主线程广播）
    static let holoCloudDataDidSync = Notification.Name("holoCloudDataDidSync")
}

/// 云同步事件判定输入（值类型，测试不构造 NSPersistentCloudKitContainer.Event）
struct CloudSyncEventInput: Equatable {
    enum Kind: Equatable { case setup, `import`, export, unknown }
    var identifier: UUID
    var kind: Kind
    var endDate: Date?
    var succeeded: Bool
    var hasError: Bool
}

/// 事件判定结论（纯语义，与广播调度解耦，可单测）
enum CloudSyncEventOutcome: Equatable {
    /// 与数据到达无关（export / 未知类型）：不广播不打点
    case ignored
    /// 尚未结束（endDate == nil）：仅诊断日志
    case started
    /// 结束但失败：仅诊断日志，不广播
    case failed
    /// import 成功结束：进入广播合并
    case importSucceeded
    /// setup 成功结束：进程内首次进入广播（新设备首载兜底），此后仅日志
    case setupSucceeded
}

final class CloudImportRelay {

    static let shared = CloudImportRelay()

    /// 掉帧诊断打点用（2026-10-08 起）：同步事件三态与广播时刻，供与 HangMonitor 卡顿报告对时
    private static let syncLogger = Logger(subsystem: "com.holo.app", category: "CloudImportRelay")

    /// holoCloudDataDidSync 的 userInfo 键：本轮合并的成功事件数（Int），打点对时用
    static let mergedBatchesUserInfoKey = "holoCloudSyncMergedBatches"

    /// 尾部合并窗口：CloudKit 导入逐批落库，窗内新事件只延长尾部计时
    private static let tailMergeInterval: TimeInterval = 0.5
    /// 合并窗口上限：从本窗首个成功事件起算，到点必发，持续导入不会无限推迟广播
    private static let maxMergeWindow: TimeInterval = 2
    /// 已消费「成功结束」的事件 ID 上界（防集合长期增长）
    private static let consumedEventIDLimit = 128

    private var observer: NSObjectProtocol?
    private var debounceWork: DispatchWorkItem?
    /// 本窗绝对截止时刻（nil = 无待发布窗口）
    private var windowDeadline: Date?
    /// 本窗已合并的成功事件数（打点用）
    private var mergedBatchCount = 0
    private var consumedEventIDs: [UUID] = []
    /// setup 成功兜底只在进程内消费一次（引擎重建时不再全模块重拉）
    private var setupBroadcastConsumed = false

    private init() {}

    /// 事件 → 结论 的纯判定（主容器过滤之外的语义全部在这里，可单测）
    static func classify(_ input: CloudSyncEventInput) -> CloudSyncEventOutcome {
        guard input.endDate != nil else { return .started }
        guard input.succeeded, !input.hasError else { return .failed }
        switch input.kind {
        case .import: return .importSucceeded
        case .setup: return .setupSucceeded
        case .export, .unknown: return .ignored
        }
    }

    /// 开启同步事件监听（幂等），由首个订阅者触发即可，无需等 store 加载完成
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // 只认主生活容器的事件：HoloMemory 的独立容器也在本进程发同类通知，
            // 不得让它触发全模块重拉。容器动态取（存储恢复流程会换容器实例）。
            guard let container = notification.object as? NSPersistentCloudKitContainer,
                  container === (CoreDataStack.shared.persistentContainer as? NSPersistentCloudKitContainer),
                  let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                      as? NSPersistentCloudKitContainer.Event else {
                return
            }
            let kind: CloudSyncEventInput.Kind
            switch event.type {
            case .setup: kind = .setup
            case .import: kind = .import
            case .export: kind = .export
            @unknown default: kind = .unknown
            }
            self?.handle(CloudSyncEventInput(
                identifier: event.identifier,
                kind: kind,
                endDate: event.endDate,
                succeeded: event.succeeded,
                hasError: event.error != nil
            ))
        }
    }

    /// 主线程处理已过滤的主容器事件
    private func handle(_ input: CloudSyncEventInput) {
        dispatchPrecondition(condition: .onQueue(.main))
        let kindLabel = input.kind == .setup ? "setup" : "import"
        switch Self.classify(input) {
        case .ignored:
            return
        case .started:
            Self.syncLogger.debug("CloudKit \(kindLabel, privacy: .public) 开始 \(input.identifier)")
        case .failed:
            Self.syncLogger.notice("CloudKit \(kindLabel, privacy: .public) 失败结束 \(input.identifier)（不触发刷新）")
        case .importSucceeded:
            guard consumeSuccessEventID(input.identifier) else { return }
            Self.syncLogger.notice("CloudKit import 成功落地 \(input.identifier)")
            scheduleBroadcast()
        case .setupSucceeded:
            // setup 成功只代表引擎就绪，不代表数据已导入。保留进程内一次首载兜底
            // （覆盖「库早已同步完、不会再有 import 事件」的场景），此后引擎重建
            // 只记日志，不再全模块重拉；新数据由 import 成功事件接续刷新。
            guard !setupBroadcastConsumed else {
                Self.syncLogger.notice("CloudKit setup 成功（引擎就绪，数据未导入）\(input.identifier)")
                return
            }
            setupBroadcastConsumed = true
            guard consumeSuccessEventID(input.identifier) else { return }
            Self.syncLogger.notice("CloudKit setup 成功（进程内首载兜底）\(input.identifier)")
            scheduleBroadcast()
        }
    }

    /// 同一事件的成功结束只消费一次；集合有界防增长
    private func consumeSuccessEventID(_ id: UUID) -> Bool {
        guard !consumedEventIDs.contains(id) else { return false }
        consumedEventIDs.append(id)
        if consumedEventIDs.count > Self.consumedEventIDLimit {
            consumedEventIDs.removeFirst(consumedEventIDs.count - Self.consumedEventIDLimit)
        }
        return true
    }

    /// 订阅云端数据到达广播，主线程回调。
    /// 返回观察者句柄，页面级订阅者（ViewModel）释放时用它移除。
    @discardableResult
    func addObserver(_ block: @escaping () -> Void) -> NSObjectProtocol {
        start()
        return NotificationCenter.default.addObserver(
            forName: .holoCloudDataDidSync,
            object: nil,
            queue: .main
        ) { _ in block() }
    }

    /// 观察者 queue 指定了 .main，状态变化全部落在主队列，无需加锁。
    /// 尾部合并 + 窗口上限：窗内新事件只延长尾部计时且不越过截止时刻；
    /// 到截止时刻必发，长导入最多每 maxMergeWindow 一轮。
    private func scheduleBroadcast() {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = Date()
        mergedBatchCount += 1
        let deadline: Date
        if let existing = windowDeadline, now < existing {
            deadline = existing
        } else {
            deadline = now + Self.maxMergeWindow
            windowDeadline = deadline
        }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fireBroadcast()
        }
        debounceWork = work
        let delay = min(Self.tailMergeInterval, max(0, deadline.timeIntervalSinceNow))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fireBroadcast() {
        dispatchPrecondition(condition: .onQueue(.main))
        let merged = mergedBatchCount
        mergedBatchCount = 0
        windowDeadline = nil
        Self.syncLogger.notice("云同步广播发布：合并批次 \(merged)")
        NotificationCenter.default.post(
            name: .holoCloudDataDidSync,
            object: nil,
            userInfo: [Self.mergedBatchesUserInfoKey: merged]
        )
    }
}
