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

    /// 当前构建连接的 CloudKit 数据库环境。
    /// 生产库/开发库是同一容器下两个完全隔离的数据库：正式渠道（App Store/TestFlight）
    /// 的包签名里带 Production 标记连生产库；开发签名不带该键，苹果默认连开发库。
    /// 两边数据互不可见——诊断页把这行亮出来，避免「两端各自同步正常却互相同步不上」的排查盲区。
    enum CloudKitEnvironment: String {
        case production
        case development

        var displayName: String {
            switch self {
            case .production: return String(localized: "生产库（正式版）")
            case .development: return String(localized: "开发库（开发版）")
            }
        }
    }

    static var currentEnvironment: CloudKitEnvironment? {
        guard isAvailable else { return nil }
        return environment(hasEmbeddedProvisioningProfile: embeddedProvisionProfileText() != nil)
    }

    /// 纯函数便于单测：包内嵌开发描述文件 = Xcode 直接安装的开发构建，连开发库；
    /// 无描述文件 = App Store / TestFlight 正式渠道，连生产库。
    /// （iOS 无公开 API 读签名 entitlements，描述文件存在性是可靠且跨 target 的判据）
    static func environment(hasEmbeddedProvisioningProfile: Bool) -> CloudKitEnvironment {
        hasEmbeddedProvisioningProfile ? .development : .production
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
            // icloud-services 为通配符 *（Xcode 自动管理的开发 profile 常见形态）时同样含 CloudKit，
            // 只认字面 "CloudKit" 会把这类包误判为不支持同步、静默退化为本地容器。
            let cloudKitServiceAllowed = profile.contains("<string>CloudKit</string>") ||
                profile.contains("<string>*</string>")
            return cloudKitServiceAllowed &&
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
    /// 两个方向各自的进行中状态（事件开始→未结束）。isSyncing 汇总两者。
    @Published private(set) var isUploading: Bool = false
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var isRefreshing: Bool = false
    /// 最近一次真实同步事件的描述；nil = 本机还没发生过任何同步事件。
    /// 不要在打开设置页时回写账号态默认文案——那会把真实进度冲掉，制造「同步没在跑」的假象。
    @Published private(set) var lastEventDescription: String?
    /// 当前未解除的同步错误。失败即写入并持久化（重启不丢），
    /// 只有对应方向（错误归属方向）的导出成功结束才清除——下载成功不代表积压数据传了上去。
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastErrorTime: Date?
    @Published private(set) var lastErrorIsQuota = false
    /// 错误归属方向（"export" / "import"），驱动错误行挂到上传/下载对应行下
    @Published private(set) var lastErrorDirection: String?
    @Published private(set) var errorHistory: [SyncErrorRecord] = []
    /// 双向各自最近一次成功时间。旧版只有一个混合的 lastSyncTime——
    /// 「已上传本机数据」会盖住「从未收到过云端数据」，双向拆开才各自可判。
    @Published private(set) var lastExportTime: Date?
    @Published private(set) var lastImportTime: Date?
    @Published private(set) var lastStatusCheckTime: Date?
    @Published private(set) var lastManualSyncRequestTime: Date?
    @Published var refreshToast: String?

    var isSyncing: Bool { isUploading || isDownloading }

    private lazy var container: CKContainer? = {
        guard CloudKitRuntimeAvailability.isAvailable else { return nil }
        return CKContainer(identifier: CloudKitRuntimeAvailability.containerIdentifier)
    }()
    private var observer: NSObjectProtocol?
    private let defaults: UserDefaults
    private let legacyLastSyncTimeKey = "iCloudSyncStatusService.lastSyncTime"
    private let lastExportTimeKey = "iCloudSyncStatusService.lastExportTime"
    private let lastImportTimeKey = "iCloudSyncStatusService.lastImportTime"
    private let lastStatusCheckTimeKey = "iCloudSyncStatusService.lastStatusCheckTime"
    private let lastManualSyncRequestTimeKey = "iCloudSyncStatusService.lastManualSyncRequestTime"
    private let lastEventDescriptionKey = "iCloudSyncStatusService.lastEventDescription"
    private let lastErrorMessageKey = "iCloudSyncStatusService.lastErrorMessage"
    private let lastErrorTimeKey = "iCloudSyncStatusService.lastErrorTime"
    private let lastErrorIsQuotaKey = "iCloudSyncStatusService.lastErrorIsQuota"
    private let lastErrorDirectionKey = "iCloudSyncStatusService.lastErrorDirection"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastExportTime = defaults.object(forKey: lastExportTimeKey) as? Date
        lastImportTime = defaults.object(forKey: lastImportTimeKey) as? Date
        // 旧版本只有一个混合时间戳，无法区分方向。升级迁移宁可保守：
        // 两方向都继承旧值（宁可漏报「首次恢复未完成」，不让老用户误看「数据正在路上」横幅）。
        if lastExportTime == nil && lastImportTime == nil,
           let legacyTime = defaults.object(forKey: legacyLastSyncTimeKey) as? Date {
            lastExportTime = legacyTime
            lastImportTime = legacyTime
            defaults.set(legacyTime, forKey: lastExportTimeKey)
            defaults.set(legacyTime, forKey: lastImportTimeKey)
        }
        lastStatusCheckTime = defaults.object(forKey: lastStatusCheckTimeKey) as? Date
        lastManualSyncRequestTime = defaults.object(forKey: lastManualSyncRequestTimeKey) as? Date
        lastEventDescription = defaults.string(forKey: lastEventDescriptionKey)
        lastErrorMessage = defaults.string(forKey: lastErrorMessageKey)
        lastErrorTime = defaults.object(forKey: lastErrorTimeKey) as? Date
        lastErrorIsQuota = defaults.bool(forKey: lastErrorIsQuotaKey)
        lastErrorDirection = defaults.string(forKey: lastErrorDirectionKey)
        errorHistory = SyncErrorLog.load(from: defaults)

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

    /// 账号可用且本机从未完成过一次「下载」事件：首次恢复可能还没完成。
    /// 锚定 import 而非任意事件——新设备上首装种子的上传成功不应冒充「同步完成」
    /// （旧版正是如此：种子 export 一落地横幅就消失，云端数据其实一条都没到）。
    /// 列表空态用它提示「数据正在路上」，设置页用它分支提示（查权限 / 查另一台设备）。
    var isInitialSyncPending: Bool {
        Self.initialSyncPending(
            isAvailable: CloudKitRuntimeAvailability.isAvailable,
            accountAvailable: accountStatus == .available,
            hasCompletedAnyImport: lastImportTime != nil
        )
    }

    /// 判定纯函数（单测入口）：可用 + 账号正常 + 从未完成过下载 = 首次恢复未完成
    static func initialSyncPending(
        isAvailable: Bool,
        accountAvailable: Bool,
        hasCompletedAnyImport: Bool
    ) -> Bool {
        isAvailable && accountAvailable && !hasCompletedAnyImport
    }

    /// 上传成功过但从未收到过云端数据：多设备场景下大概率是另一台设备没在上传
    /// （或两端连的不是同一个 CloudKit 环境）。设置页据此给出针对性指引。
    var neverReceivedFromCloud: Bool {
        CloudKitRuntimeAvailability.isAvailable
            && accountStatus == .available
            && lastExportTime != nil
            && lastImportTime == nil
    }

    func requestManualSync() async {
        isRefreshing = true
        let start = Date()
        await updateAccountStatus()

        if accountStatus == .available {
            do {
                let requestedAt = try await writeSyncProbe()
                lastManualSyncRequestTime = requestedAt
                defaults.set(requestedAt, forKey: lastManualSyncRequestTimeKey)
                // 即时反馈只承认「已递交」；真实结果等探针上传事件落地后再报
                refreshToast = String(localized: "已递交同步请求，结果稍后显示在这里")
                beginProbeFeedbackWait()
            } catch {
                // 探针写入失败发生在本机（未进任何同步方向），方向记 nil
                setSyncError(message: error.localizedDescription, isQuota: false, direction: nil)
                setDescription(String(localized: "同步请求失败"))
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
    /// 上传落地后再给下载方向一个等待窗：窗口内收到 import 事件就报「收到新数据」；
    /// 超时则报「云端新数据将自动到达」——不武断承诺「云端没有新数据」。
    private static let importFeedbackTimeout: TimeInterval = 10
    private var pendingProbeFeedback = false
    private var probeFeedbackTimeoutTask: Task<Void, Never>?
    private var pendingImportFeedback = false
    private var importFeedbackTimeoutTask: Task<Void, Never>?

    private func beginProbeFeedbackWait() {
        pendingProbeFeedback = true
        probeFeedbackTimeoutTask?.cancel()
        probeFeedbackTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.probeFeedbackTimeout))
            guard !Task.isCancelled else { return }
            self?.finishProbeFeedback(timedOut: true)
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
        // 成功路径的 toast 在 handleEventSuccess / handleEventFailure 里给
    }

    private func beginImportFeedbackWait() {
        pendingImportFeedback = true
        importFeedbackTimeoutTask?.cancel()
        importFeedbackTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.importFeedbackTimeout))
            guard !Task.isCancelled else { return }
            self?.finishImportFeedback(timedOut: true)
        }
    }

    @MainActor
    func finishImportFeedback(timedOut: Bool) {
        guard pendingImportFeedback else { return }
        pendingImportFeedback = false
        importFeedbackTimeoutTask = nil
        if timedOut {
            refreshToast = String(localized: "同步完成：本机数据已上传 iCloud，云端新数据将自动到达")
        }
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

    // MARK: - 双向状态行（设置页上传/下载两行的数据来源）

    /// 一个同步方向的状态行：进行中 / 成功时间 / 失败原因 / 从未发生，四态互斥。
    /// 错误只挂到它归属的方向行上——下载行的文案不掺上传的错。
    struct DirectionStatusLine {
        let title: String
        let detail: String
        let isInProgress: Bool
        let hasError: Bool
    }

    var exportStatusLine: DirectionStatusLine {
        if isUploading {
            return DirectionStatusLine(
                title: String(localized: "上传"),
                detail: String(localized: "正在上传本机数据…"),
                isInProgress: true,
                hasError: false
            )
        }
        if lastErrorDirection == "export", let message = lastErrorMessage {
            return DirectionStatusLine(
                title: String(localized: "上传"),
                detail: String(localized: "上传失败：") + message,
                isInProgress: false,
                hasError: true
            )
        }
        if let time = lastExportTime {
            return DirectionStatusLine(
                title: String(localized: "上传"),
                detail: String(localized: "已上传 · ") + formatTime(time),
                isInProgress: false,
                hasError: false
            )
        }
        return DirectionStatusLine(
            title: String(localized: "上传"),
            detail: String(localized: "尚未上传"),
            isInProgress: false,
            hasError: false
        )
    }

    var importStatusLine: DirectionStatusLine {
        if isDownloading {
            return DirectionStatusLine(
                title: String(localized: "下载"),
                detail: String(localized: "正在接收 iCloud 数据…"),
                isInProgress: true,
                hasError: false
            )
        }
        if lastErrorDirection == "import", let message = lastErrorMessage {
            return DirectionStatusLine(
                title: String(localized: "下载"),
                detail: String(localized: "接收失败：") + message,
                isInProgress: false,
                hasError: true
            )
        }
        if let time = lastImportTime {
            return DirectionStatusLine(
                title: String(localized: "下载"),
                detail: String(localized: "已接收 · ") + formatTime(time),
                isInProgress: false,
                hasError: false
            )
        }
        return DirectionStatusLine(
            title: String(localized: "下载"),
            detail: String(localized: "尚未收到云端数据"),
            isInProgress: false,
            hasError: false
        )
    }

    private func handleCloudKitEvent(_ notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else {
            return
        }
        processCloudKitEvent(type: event.type, endDate: event.endDate, error: event.error)
    }

    /// 事件 → 状态的唯一决策入口（单测直接调这里）。
    /// 铁律：事件以错误结束时，不写「已上传」类成功文案、不刷新该方向最近成功时间——
    /// 否则会出现「iCloud 满、上传全失败、界面却报同步成功」的假象。
    func processCloudKitEvent(
        type: NSPersistentCloudKitContainer.EventType,
        endDate: Date?,
        error: Error?
    ) {
        let isFinished = endDate != nil
        switch type {
        case .setup: break
        case .import: isDownloading = !isFinished
        case .export: isUploading = !isFinished
        @unknown default: break
        }

        // 进行中的事件只更新进度文案，不动任何结论性状态
        if !isFinished {
            switch type {
            case .setup: setDescription(String(localized: "正在准备 iCloud 同步"))
            case .import: setDescription(String(localized: "正在接收 iCloud 数据"))
            case .export: setDescription(String(localized: "正在上传本机数据"))
            @unknown default: setDescription(String(localized: "iCloud 同步状态已更新"))
            }
            return
        }

        if let error {
            handleEventFailure(type: type, error: error)
        } else {
            handleEventSuccess(type: type)
        }
    }

    private func handleEventSuccess(type: NSPersistentCloudKitContainer.EventType) {
        let syncTime = Date()

        switch type {
        case .setup:
            setDescription(String(localized: "iCloud 同步已准备"))
        case .import:
            lastImportTime = syncTime
            defaults.set(syncTime, forKey: lastImportTimeKey)
            setDescription(String(localized: "已接收 iCloud 数据"))
        case .export:
            lastExportTime = syncTime
            defaults.set(syncTime, forKey: lastExportTimeKey)
            setDescription(String(localized: "已上传本机数据"))
        @unknown default:
            setDescription(String(localized: "iCloud 同步状态已更新"))
        }

        // 只有「同方向的成功」才解除该方向的同步错误：
        // 上传错误要等上传真正成功才解除（下载通了不代表积压数据传了上去），反之亦然。
        // 上传成功是更强的恢复信号（本地积压已对齐服务端），任意方向的错误都随之解除；
        // 旧版本迁移过来的错误没有方向标记，任一方向成功即可解除。
        if lastErrorMessage != nil,
           type == .export || lastErrorDirection == nil || directionName(type) == lastErrorDirection {
            clearSyncError()
        }

        // 手动同步的探针上传落地了：报上传结果，并给下载方向开等待窗
        if pendingProbeFeedback, type == .export {
            finishProbeFeedback(timedOut: false)
            refreshToast = String(localized: "同步完成：本机数据已上传 iCloud")
            beginImportFeedbackWait()
            return
        }

        // 下载等待窗内收到新数据：双向都有结论，这是「立即同步」的完整成功
        if pendingImportFeedback, type == .import {
            finishImportFeedback(timedOut: false)
            refreshToast = String(localized: "同步完成：本机数据已上传，并收到云端新数据")
        }
    }

    private func handleEventFailure(type: NSPersistentCloudKitContainer.EventType, error: Error) {
        let kind = CloudKitSyncErrorAnalyzer.classify(error)

        // 「操作被取消」= 同步进行到一半被切后台/锁屏/断网中断，系统会自动重试，
        // 属正常现象：不进错误状态，也不算一次失败结论；探针这趟不算数，继续等下一趟
        if kind == .operationCancelled {
            logger.info("iCloud 同步事件被系统取消（自动重试）：\(error.localizedDescription)")
            setDescription(String(localized: "同步被系统中断，稍后自动重试"))
            return
        }

        let isQuota = kind == .quotaExceeded
        let direction = directionName(type)
        let ckErrorCode = CloudKitSyncErrorAnalyzer.deepestCKErrorCode(error)

        // 如实记录：诊断流水 + 当前错误（含归属方向，持久化，重启不丢）
        let record = SyncErrorRecord(
            date: Date(),
            direction: direction,
            ckErrorCode: ckErrorCode,
            message: error.localizedDescription
        )
        errorHistory = SyncErrorLog.append(record, to: defaults)
        setSyncError(
            message: isQuota
                ? String(localized: "iCloud 空间已满，本机数据未上传")
                : error.localizedDescription,
            isQuota: isQuota,
            direction: direction,
            date: record.date
        )
        logger.error("iCloud 同步事件失败 [\(direction)] ckErrorCode=\(ckErrorCode.map(String.init) ?? "nil")：\(error.localizedDescription)")

        // 失败结论：不写该方向成功时间、不写「已…」成功文案
        switch type {
        case .setup: setDescription(String(localized: "iCloud 同步准备失败"))
        case .import: setDescription(String(localized: "接收 iCloud 数据失败"))
        case .export: setDescription(String(localized: "本机数据上传失败"))
        @unknown default: setDescription(String(localized: "iCloud 同步失败"))
        }

        // 手动同步的探针失败落地：立即报真实原因，不让用户干等超时兜底
        if pendingProbeFeedback, type == .export {
            finishProbeFeedback(timedOut: false)
            refreshToast = isQuota
                ? String(localized: "同步失败：iCloud 空间已满，请清理 iCloud 存储空间后重试")
                : String(localized: "同步失败：") + error.localizedDescription
            return
        }

        // 下载等待窗内接收失败：下载方向如实报错
        if pendingImportFeedback, type == .import {
            finishImportFeedback(timedOut: false)
            refreshToast = String(localized: "已上传 iCloud，但接收云端数据失败：") + error.localizedDescription
        }
    }

    private func setDescription(_ text: String) {
        lastEventDescription = text
        defaults.set(text, forKey: lastEventDescriptionKey)
    }

    private func setSyncError(message: String, isQuota: Bool, direction: String?, date: Date = Date()) {
        lastErrorMessage = message
        lastErrorTime = date
        lastErrorIsQuota = isQuota
        lastErrorDirection = direction
        defaults.set(message, forKey: lastErrorMessageKey)
        defaults.set(date, forKey: lastErrorTimeKey)
        defaults.set(isQuota, forKey: lastErrorIsQuotaKey)
        defaults.set(direction, forKey: lastErrorDirectionKey)
    }

    private func clearSyncError() {
        lastErrorMessage = nil
        lastErrorTime = nil
        lastErrorIsQuota = false
        lastErrorDirection = nil
        defaults.removeObject(forKey: lastErrorMessageKey)
        defaults.removeObject(forKey: lastErrorTimeKey)
        defaults.removeObject(forKey: lastErrorIsQuotaKey)
        defaults.removeObject(forKey: lastErrorDirectionKey)
    }

    private func directionName(_ type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup: return "setup"
        case .import: return "import"
        case .export: return "export"
        @unknown default: return "unknown"
        }
    }

    private func updateAccountStatus() async {
        guard let container else {
            accountStatus = .couldNotDetermine
            // 签名未启用 CloudKit（模拟器/开发签名）是能力缺失而非同步失败：
            // 状态行表达即可，不进「最近错误」吓用户
            setDescription(String(localized: "iCloud 同步未启用"))
            let checkedAt = Date()
            lastStatusCheckTime = checkedAt
            defaults.set(checkedAt, forKey: lastStatusCheckTimeKey)
            return
        }

        do {
            accountStatus = try await container.accountStatus()
            // 账号可查 ≠ 同步已恢复：上次的上传错误保留到 export 真正成功为止
        } catch {
            accountStatus = .couldNotDetermine
            logger.error("iCloud 账号状态检查失败：\(error.localizedDescription)")
        }

        let checkedAt = Date()
        lastStatusCheckTime = checkedAt
        defaults.set(checkedAt, forKey: lastStatusCheckTimeKey)
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

    /// 诊断页与设置页共用的统一时间格式
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
