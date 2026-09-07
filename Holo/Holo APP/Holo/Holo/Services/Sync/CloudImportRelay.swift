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
//  这里全局唯一监听 store 的远程变更通知，防抖合并后广播 holoCloudDataDidSync，
//  各模块订阅这一条通知重拉各自数据即可，不再各自维护一套监听+防抖代码。
//

import Foundation
import CoreData

extension Notification.Name {
    /// iCloud 云端数据已同步到本地（主线程广播；本地写入触发的导出同样会经过这里，
    /// 模块侧重拉是幂等 fetch，代价可接受）
    static let holoCloudDataDidSync = Notification.Name("holoCloudDataDidSync")
}

final class CloudImportRelay {

    static let shared = CloudImportRelay()

    /// 防抖窗口：CloudKit 导入是逐批落库的，窗口内合并成一次广播，避免列表反复重拉
    private static let debounceInterval: TimeInterval = 2

    private var observer: NSObjectProtocol?
    private var debounceWork: DispatchWorkItem?

    private init() {}

    /// 开启远程变更监听（幂等），由首个订阅者触发即可，无需等 store 加载完成
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: CoreDataStack.shared.persistentContainer.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleBroadcast()
        }
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

    /// 观察者 queue 指定了 .main，状态变化全部落在主队列，无需加锁
    private func scheduleBroadcast() {
        dispatchPrecondition(condition: .onQueue(.main))
        debounceWork?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .holoCloudDataDidSync, object: nil)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }
}
