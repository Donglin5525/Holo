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

nonisolated enum CloudKitRuntimeAvailability {
    static let containerIdentifier = "iCloud.com.tangyuxuan.Holo"

    enum BuildConfiguration {
        case debug
        case release
    }

    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        let runningOnSimulator = true
        #else
        let runningOnSimulator = false
        #endif

        #if DEBUG
        return isAvailable(
            embeddedProvisionProfile: embeddedProvisionProfileText(),
            buildConfiguration: .debug,
            targetEnvironmentIsSimulator: runningOnSimulator
        )
        #else
        return isAvailable(
            embeddedProvisionProfile: nil,
            buildConfiguration: .release,
            targetEnvironmentIsSimulator: runningOnSimulator
        )
        #endif
    }

    static func isAvailable(
        embeddedProvisionProfile profile: String?,
        buildConfiguration: BuildConfiguration,
        targetEnvironmentIsSimulator: Bool = false
    ) -> Bool {
        guard !targetEnvironmentIsSimulator else {
            return false
        }

        switch buildConfiguration {
        case .release:
            return true
        case .debug:
            guard let profile, !profile.isEmpty else {
                return true
            }
            return profile.contains("<string>CloudKit</string>") &&
                profile.contains("<string>\(containerIdentifier)</string>")
        }
    }

    private static func embeddedProvisionProfileText() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8)
    }
}

@MainActor
final class ICloudSyncStatusService: ObservableObject {
    static let shared = ICloudSyncStatusService()

    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var isRefreshing: Bool = false
    /// 最近一次真实同步事件的描述；nil = 本机还没发生过任何同步事件。
    /// 不要在打开设置页时回写账号态默认文案——那会把真实进度冲掉，制造「同步没在跑」的假象。
    @Published private(set) var lastEventDescription: String?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var lastStatusCheckTime: Date?
    @Published private(set) var lastManualSyncRequestTime: Date?
    @Published var refreshToast: String?

    private lazy var container: CKContainer? = {
        guard CloudKitRuntimeAvailability.isAvailable else { return nil }
        return CKContainer(identifier: CloudKitRuntimeAvailability.containerIdentifier)
    }()
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
            MainActor.assumeIsolated {
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
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 0.6 {
            try? await Task.sleep(for: .milliseconds(Int((0.6 - elapsed) * 1000)))
        }
        isRefreshing = false
        refreshToast = String(localized: "状态已更新：") + accountStatusText
    }

    /// 静默初始化：App 启动时拉一次账号状态并开始记录同步事件，
    /// 供列表空态判断「首次同步是否尚未完成」。不写任何 toast 与状态文案。
    func warmUpAccountStatus() async {
        await updateAccountStatus()
    }

    /// 账号可用且本机还没完成过任何一次同步事件：新设备首次恢复中。
    /// 列表空态用它提示「数据正在路上」，设置页用它提示检查 iCloud 权限；
    /// 任一同步事件完成后即翻为 false。
    var isInitialSyncPending: Bool {
        CloudKitRuntimeAvailability.isAvailable && accountStatus == .available && lastSyncTime == nil
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
                // 即时反馈只承认「已递交」；真实结果等探针上传事件落地后再报
                refreshToast = String(localized: "已递交同步请求，结果稍后显示在这里")
                beginProbeFeedbackWait()
            } catch {
                lastErrorMessage = error.localizedDescription
                lastEventDescription = String(localized: "同步请求失败")
                refreshToast = String(localized: "同步请求失败")
                logger.error("写入 iCloud 同步探针失败：\(error.localizedDescription)")
            }
        } else {
            refreshToast = String(localized: "状态已更新：") + accountStatusText
        }

        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 0.6 {
            try? await Task.sleep(for: .milliseconds(Int((0.6 - elapsed) * 1000)))
        }
        isRefreshing = false
    }

    // MARK: - 手动同步的真实结果反馈

    /// 探针写入会触发一次真实的上传事件；等它落地再报结果，
    /// 不再「递交请求就报成功」——那会让用户误以为数据已同步完成。
    private static let probeFeedbackTimeout: TimeInterval = 12
    private var pendingProbeFeedback = false
    private var probeFeedbackTimeoutTask: Task<Void, Never>?

    private func beginProbeFeedbackWait() {
        pendingProbeFeedback = true
        probeFeedbackTimeoutTask?.cancel()
        probeFeedbackTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.probeFeedbackTimeout))
            guard !Task.isCancelled else { return }
            await self?.finishProbeFeedback(timedOut: true)
        }
    }

    @MainActor
    private func finishProbeFeedback(timedOut: Bool) {
        guard pendingProbeFeedback else { return }
        pendingProbeFeedback = false
        probeFeedbackTimeoutTask = nil
        if timedOut {
            refreshToast = String(localized: "同步暂未响应，系统稍后会自动重试")
        }
        // 成功路径的 toast 在 handleCloudKitEvent 里给
    }

    /// 状态主文案：优先展示真实同步事件，没发生过事件时回落到账号状态描述
    var statusDisplayText: String {
        lastEventDescription ?? statusDescriptionForCurrentAccount()
    }

    var accountStatusText: String {
        switch accountStatus {
        case .available: return String(localized: "已登录")
        case .noAccount: return String(localized: "未登录 iCloud")
        case .restricted: return String(localized: "账号受限")
        case .temporarilyUnavailable: return String(localized: "iCloud 暂时不可用")
        case .couldNotDetermine: return String(localized: "未检测到")
        @unknown default: return String(localized: "未知")
        }
    }

    var syncStatusDetailText: String {
        if let lastSyncTime {
            if let lastManualSyncRequestTime, lastManualSyncRequestTime > lastSyncTime {
                return String(localized: "最近请求同步：") + formatTime(lastManualSyncRequestTime)
            }
            return String(localized: "最近同步：") + formatTime(lastSyncTime)
        }

        if let lastManualSyncRequestTime {
            return String(localized: "最近请求同步：") + formatTime(lastManualSyncRequestTime)
        }

        if let lastStatusCheckTime {
            return String(localized: "最近检查：") + formatTime(lastStatusCheckTime)
        }

        return String(localized: "等待首次同步完成")
    }

    private func handleCloudKitEvent(_ notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else {
            return
        }

        isSyncing = event.endDate == nil
        switch event.type {
        case .setup:
            lastEventDescription = isSyncing ? String(localized: "正在准备 iCloud 同步") : String(localized: "iCloud 同步已准备")
        case .import:
            lastEventDescription = isSyncing ? String(localized: "正在接收 iCloud 数据") : String(localized: "已接收 iCloud 数据")
        case .export:
            lastEventDescription = isSyncing ? String(localized: "正在上传本机数据") : String(localized: "已上传本机数据")
        @unknown default:
            lastEventDescription = String(localized: "iCloud 同步状态已更新")
        }

        if !isSyncing {
            let syncTime = event.endDate ?? Date()
            lastSyncTime = syncTime
            UserDefaults.standard.set(syncTime, forKey: lastSyncTimeKey)

            // 手动同步的探针上传落地了，报真实结果
            if pendingProbeFeedback, event.type == .export {
                pendingProbeFeedback = false
                probeFeedbackTimeoutTask?.cancel()
                probeFeedbackTimeoutTask = nil
                if event.error == nil {
                    refreshToast = String(localized: "同步完成：本机数据已上传 iCloud")
                }
            }
        }

        if let error = event.error {
            // 「操作被取消」= 同步进行到一半被切后台/锁屏/断网中断，系统会自动重试，
            // 属正常现象，不进「最近错误」吓用户
            if (error as? CKError)?.code == .operationCancelled {
                logger.info("iCloud 同步事件被系统取消（自动重试）：\(error.localizedDescription)")
            } else {
                lastErrorMessage = error.localizedDescription
                logger.error("iCloud 同步事件错误：\(error.localizedDescription)")
            }
        } else if !isSyncing {
            // 事件成功完成即清除旧错误：「最近错误」只反映最近一次结果
            lastErrorMessage = nil
        }
    }

    private func updateAccountStatus() async {
        guard let container else {
            accountStatus = .couldNotDetermine
            lastErrorMessage = String(localized: "当前签名未启用 iCloud CloudKit，同步功能暂不可用")
            lastEventDescription = String(localized: "iCloud 同步未启用")
            let checkedAt = Date()
            lastStatusCheckTime = checkedAt
            UserDefaults.standard.set(checkedAt, forKey: lastStatusCheckTimeKey)
            return
        }

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
            return String(localized: "iCloud 可用，等待系统自动同步")
        case .noAccount:
            return String(localized: "未登录 iCloud，无法同步")
        case .restricted:
            return String(localized: "iCloud 账号受限，无法同步")
        case .temporarilyUnavailable:
            return String(localized: "iCloud 暂时不可用")
        case .couldNotDetermine:
            return String(localized: "暂时无法确认 iCloud 状态")
        @unknown default:
            return String(localized: "iCloud 状态未知")
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
