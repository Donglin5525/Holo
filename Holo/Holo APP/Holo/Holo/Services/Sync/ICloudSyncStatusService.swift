//
//  ICloudSyncStatusService.swift
//  Holo
//
//  iCloud 同步状态监听服务
//  监听 NSPersistentCloudKitContainer 事件，提供账号状态和同步进度
//

import Foundation
import CloudKit
import CoreData
import Combine
import OSLog

private let logger = Logger(subsystem: "com.tangyuxuan.Holo", category: "ICloudSync")

@MainActor
final class ICloudSyncStatusService: ObservableObject {
    static let shared = ICloudSyncStatusService()

    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastEventDescription: String = "尚未检测"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastSyncTime: Date?
    @Published var refreshToast: String?

    private let container = CKContainer(identifier: "iCloud.com.tangyuxuan.Holo")
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleCloudKitEvent(notification)
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refreshAccountStatus() async {
        isRefreshing = true
        // 最少显示 0.6 秒 loading，让用户能看到反馈
        let start = Date()
        do {
            accountStatus = try await container.accountStatus()
            lastErrorMessage = nil
        } catch {
            accountStatus = .couldNotDetermine
            lastErrorMessage = error.localizedDescription
            logger.error("iCloud 账号状态检查失败：\(error.localizedDescription)")
        }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 0.6 {
            try? await Task.sleep(for: .milliseconds(Int((0.6 - elapsed) * 1000)))
        }
        isRefreshing = false
        refreshToast = "状态已更新：" + accountStatusText
        // 2 秒后清除 toast
        try? await Task.sleep(for: .seconds(2))
        refreshToast = nil
    }

    var accountStatusText: String {
        switch accountStatus {
        case .available: return "已登录"
        case .noAccount: return "未登录 iCloud"
        case .restricted: return "账号受限"
        case .temporarilyUnavailable: return "iCloud 暂时不可用"
        case .couldNotDetermine: return "未检测到"
        @unknown default: return "未知"
        }
    }

    private func handleCloudKitEvent(_ notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else {
            return
        }

        isSyncing = event.endDate == nil
        switch event.type {
        case .setup:
            lastEventDescription = isSyncing ? "正在准备 iCloud 同步" : "iCloud 同步已准备"
        case .import:
            lastEventDescription = isSyncing ? "正在接收 iCloud 数据" : "已接收 iCloud 数据"
        case .export:
            lastEventDescription = isSyncing ? "正在上传本机数据" : "已上传本机数据"
        @unknown default:
            lastEventDescription = "iCloud 同步状态已更新"
        }

        if !isSyncing {
            lastSyncTime = event.endDate ?? Date()
        }

        if let error = event.error {
            lastErrorMessage = error.localizedDescription
            logger.error("iCloud 同步事件错误：\(error.localizedDescription)")
        }
    }
}
