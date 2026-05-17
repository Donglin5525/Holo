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
    @Published private(set) var lastStatusCheckTime: Date?
    @Published private(set) var lastManualSyncRequestTime: Date?
    @Published var refreshToast: String?

    private let container = CKContainer(identifier: "iCloud.com.tangyuxuan.Holo")
    private var observer: NSObjectProtocol?
    private let lastSyncTimeKey = "iCloudSyncStatusService.lastSyncTime"
    private let lastStatusCheckTimeKey = "iCloudSyncStatusService.lastStatusCheckTime"
    private let lastManualSyncRequestTimeKey = "iCloudSyncStatusService.lastManualSyncRequestTime"

    private init() {
        let defaults = UserDefaults.standard
        lastSyncTime = defaults.object(forKey: lastSyncTimeKey) as? Date
        lastStatusCheckTime = defaults.object(forKey: lastStatusCheckTimeKey) as? Date
        lastManualSyncRequestTime = defaults.object(forKey: lastManualSyncRequestTimeKey) as? Date

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
        await updateAccountStatus()
        lastEventDescription = statusDescriptionForCurrentAccount()
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 0.6 {
            try? await Task.sleep(for: .milliseconds(Int((0.6 - elapsed) * 1000)))
        }
        isRefreshing = false
        refreshToast = "状态已更新：" + accountStatusText
    }

    func requestManualSync() async {
        isRefreshing = true
        let start = Date()
        await updateAccountStatus()

        if accountStatus == .available {
            do {
                let requestedAt = try await writeSyncProbe()
                lastManualSyncRequestTime = requestedAt
                UserDefaults.standard.set(requestedAt, forKey: lastManualSyncRequestTimeKey)
                lastEventDescription = "已请求同步，等待系统完成"
                refreshToast = "已请求同步"
            } catch {
                lastErrorMessage = error.localizedDescription
                lastEventDescription = "同步请求失败"
                refreshToast = "同步请求失败"
                logger.error("写入 iCloud 同步探针失败：\(error.localizedDescription)")
            }
        } else {
            lastEventDescription = statusDescriptionForCurrentAccount()
            refreshToast = "状态已更新：" + accountStatusText
        }

        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 0.6 {
            try? await Task.sleep(for: .milliseconds(Int((0.6 - elapsed) * 1000)))
        }
        isRefreshing = false
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

    var syncStatusDetailText: String {
        if let lastSyncTime {
            if let lastManualSyncRequestTime, lastManualSyncRequestTime > lastSyncTime {
                return "最近请求同步：" + formatTime(lastManualSyncRequestTime)
            }
            return "最近同步：" + formatTime(lastSyncTime)
        }

        if let lastManualSyncRequestTime {
            return "最近请求同步：" + formatTime(lastManualSyncRequestTime)
        }

        if let lastStatusCheckTime {
            return "最近检查：" + formatTime(lastStatusCheckTime)
        }

        return "等待首次同步完成"
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
            let syncTime = event.endDate ?? Date()
            lastSyncTime = syncTime
            UserDefaults.standard.set(syncTime, forKey: lastSyncTimeKey)
        }

        if let error = event.error {
            lastErrorMessage = error.localizedDescription
            logger.error("iCloud 同步事件错误：\(error.localizedDescription)")
        }
    }

    private func updateAccountStatus() async {
        do {
            accountStatus = try await container.accountStatus()
            lastErrorMessage = nil
        } catch {
            accountStatus = .couldNotDetermine
            lastErrorMessage = error.localizedDescription
            logger.error("iCloud 账号状态检查失败：\(error.localizedDescription)")
        }

        let checkedAt = Date()
        lastStatusCheckTime = checkedAt
        UserDefaults.standard.set(checkedAt, forKey: lastStatusCheckTimeKey)
    }

    private func writeSyncProbe() async throws -> Date {
        await CoreDataStack.shared.waitUntilReady()
        let requestedAt = Date()

        try await CoreDataStack.shared.performBackgroundTask { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "ICloudSyncProbe")
            request.fetchLimit = 1

            let probe = try context.fetch(request).first
                ?? NSEntityDescription.insertNewObject(forEntityName: "ICloudSyncProbe", into: context)

            if probe.value(forKey: "id") == nil {
                probe.setValue(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, forKey: "id")
            }
            probe.setValue(requestedAt, forKey: "updatedAt")
            probe.setValue("manual", forKey: "reason")
            probe.setValue(UUID().uuidString, forKey: "nonce")

            if context.hasChanges {
                try context.save()
            }
        }

        return requestedAt
    }

    private func statusDescriptionForCurrentAccount() -> String {
        switch accountStatus {
        case .available:
            return "iCloud 可用，等待系统自动同步"
        case .noAccount:
            return "未登录 iCloud，无法同步"
        case .restricted:
            return "iCloud 账号受限，无法同步"
        case .temporarilyUnavailable:
            return "iCloud 暂时不可用"
        case .couldNotDetermine:
            return "暂时无法确认 iCloud 状态"
        @unknown default:
            return "iCloud 状态未知"
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
