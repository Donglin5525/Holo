//
//  HoloProductAnalytics.swift
//  Holo
//
//  产品埋点（2026-10-19 自建方案，2026-10-25 字典 v2）：匿名使用事件本地队列 + 批量上报。
//  事件域 = 会话/模块曝光/记账/打卡/建任务/付费墙漏斗（v1）+ AI 交互/想法·习惯·账户创建/
//  识图记账漏斗/数据导出（v2），字典与后端 PRODUCT_EVENT_NAMES 白名单一一对应
//  （docs/_common/plans/2026-10-19-产品埋点自建方案/README.md）。
//  隐私契约：不收任何用户内容（金额/标题/备注/习惯名/消息正文一律不进事件），仅枚举参数。
//  管线复刻 HoloAgentTelemetryUploader：冷启动/前台化/进后台批量上报，服务端按
//  事件 UUID INSERT OR IGNORE 幂等；4xx 丢弃批次（未来新事件名被旧后端白名单拒收
//  时防毒丸无限重试），其余失败保留待重试。队列上限 1000 条（超限丢最旧）。
//

import Foundation
import os.log

/// 埋点事件名（与后端 PRODUCT_EVENT_NAMES 一一对应；新增事件先发后端白名单再发 iOS）
enum HoloProductEventName: String, CaseIterable {
    // v1（2026-10-19）
    case appFirstLaunch = "app_first_launch"
    case appSessionStart = "app_session_start"
    case moduleView = "module_view"
    case billCreated = "bill_created"
    case habitCheckin = "habit_checkin"
    case taskCreated = "task_created"
    case paywallViewed = "paywall_viewed"
    case paywallPurchaseTapped = "paywall_purchase_tapped"
    // v2（2026-10-25）：AI 交互（AI 是默认首页 tab 不走 module_view 闸口，服务端
    // ai_call_logs 只记技术调用不记用户入口/查看行为）+ 记录动作补齐 + 漏斗/数据安全
    /// 一次分析会话内首条发出的 AI 消息（会话=每次前台激活；与 app_session_start 相除=AI 渗透率）
    case aiConversationStarted = "ai_conversation_started"
    /// 每条发出的 AI 消息；kind=text/image/report_followup
    case aiMessageSent = "ai_message_sent"
    /// 发起一次深度洞察（消耗 Plus 额度）；scenario=AnalysisScenario rawValue
    case aiDeepReportRequested = "ai_deep_report_requested"
    /// 打开一份深度洞察报告详情（生成≠查看）
    case aiDeepReportViewed = "ai_deep_report_viewed"
    /// 想法创建；source=editor（编辑器）/ai（对话建笔记、记心情）。种子与导入不计
    case thoughtCreated = "thought_created"
    /// 新建习惯；type=checkIn/numeric（经 HabitRepository 通知总线，同打卡事件）
    case habitCreated = "habit_created"
    /// 新建财务账户；type=AccountType rawValue
    case accountCreated = "account_created"
    /// 发起识图记账；entry=ReceiptBookingSource rawValue（chat/shortcut*/shareSheet/lockedCamera）
    case receiptBookingStarted = "receipt_booking_started"
    /// 完成一次数据导出；format=csv/json
    case exportPerformed = "export_performed"
}

/// 待上报事件（字段与后端 normalizeProductEvent 一一对应）
struct HoloProductPendingEvent: Codable {
    let id: String
    let name: String
    let timestampMs: Int64
    let params: [String: String]?
    let appVersion: String
    let buildChannel: String
    let sessionId: String?
}

/// 当前分析会话 ID：一次前台激活一个 UUID，随所有后端请求头（x-holo-session-id）
/// 与埋点事件上送——服务端 product_events / ai_call_logs / request_logs 统一记录
/// session_id，把前端行为与 AI 调用串成完整用户链路（2026-10-19 东林拍板
/// 「前后端要对得上、用户 ID 一致」）。设备身份沿用 X-Holo-Device-Id 同一体系。
/// 后台任务唤醒的进程没有前台会话 → nil → 不带头 → 服务端空值恰好标记非前台行为。
nonisolated enum HoloAnalyticsSession {
    private static let lock = OSAllocatedUnfairLock(initialState: String?.none)

    /// 当前会话 ID；nil = 尚无前台会话（冷启动早期/纯后台唤醒）
    static var currentId: String? {
        lock.withLock { $0 }
    }

    /// 开启新会话并返回其 ID（每次 session_start 时调用）
    static func beginNew() -> String {
        let id = UUID().uuidString
        lock.withLock { $0 = id }
        return id
    }
}

/// 本地待上报队列：Application Support 下 JSON 文件持久化，追加即落盘。
/// 服务端总开关关停期间事件照常入队（上限 1000 兜底），开关恢复后自然续传。
nonisolated actor HoloProductEventQueue {
    private(set) var events: [HoloProductPendingEvent] = []
    private var loaded = false
    private let fileURL: URL
    private let maxQueuedEvents: Int

    init(fileURL: URL = HoloProductEventQueue.defaultFileURL, maxQueuedEvents: Int = 1000) {
        self.fileURL = fileURL
        self.maxQueuedEvents = maxQueuedEvents
    }

    /// 测试注入用独立存储位；正式路径固定在 Application Support/Analytics。
    static var defaultFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Analytics", isDirectory: true)
        return dir.appendingPathComponent("product-events-pending.json")
    }

    func append(_ event: HoloProductPendingEvent) {
        loadIfNeeded()
        events.append(event)
        if events.count > maxQueuedEvents {
            events.removeFirst(events.count - maxQueuedEvents)
        }
        save()
    }

    func prefix(_ maxLength: Int) -> [HoloProductPendingEvent] {
        loadIfNeeded()
        return Array(events.prefix(maxLength))
    }

    func remove(ids: Set<String>) {
        loadIfNeeded()
        events.removeAll { ids.contains($0.id) }
        save()
    }

    func removeAll() {
        loadIfNeeded()
        events.removeAll()
        save()
    }

    func count() -> Int {
        loadIfNeeded()
        return events.count
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        events = (try? JSONDecoder().decode([HoloProductPendingEvent].self, from: data)) ?? []
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

nonisolated final class HoloProductAnalytics {
    static let shared = HoloProductAnalytics()

    private let logger = Logger(subsystem: "com.holo.app", category: "ProductAnalytics")
    private let baseURL: String
    private let apiClient: APIClient
    private let deviceIdProvider: () -> String
    private let queue: HoloProductEventQueue
    private let maxBatchSize = 100
    /// 单次 flush 最多 10 批：极端积压（换机/长期关开关后恢复）不阻塞前台化链路
    private let maxBatchesPerFlush = 10
    private let firstLaunchDefaultsKey = "holo.analytics.firstLaunchDone"

    init(
        baseURL: String = HoloBackendEnvironment.baseURL,
        apiClient: APIClient = .shared,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId },
        queue: HoloProductEventQueue = HoloProductEventQueue()
    ) {
        self.baseURL = baseURL
        self.apiClient = apiClient
        self.deviceIdProvider = deviceIdProvider
        self.queue = queue
        // 习惯打卡/新建事件总线：HabitRepository 被主 App 与小组件两 target 共享编译，
        // 仓库层只能发通知不能直接引用本类（见 HabitRepository 通知定义处注释）
        NotificationCenter.default.addObserver(
            forName: .holoHabitCheckinDidRecord,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let kind = (notification.userInfo?["kind"] as? String) ?? "check"
            self?.track(.habitCheckin, ["kind": kind])
        }
        NotificationCenter.default.addObserver(
            forName: .holoHabitDidCreate,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let type = (notification.userInfo?["type"] as? String) ?? "checkIn"
            self?.track(.habitCreated, ["type": type])
        }
    }

    /// 收集闸：XCTest 宿主与截图/模拟器验收播种模式下不产生事件（避免假数据污染）
    static var isCollecting: Bool {
        guard !TestHostEnvironment.isHostedByXCTest else { return false }
        #if DEBUG
        // 播种模式的启动开关都是 MainActor 隔离的启动参数读取，仅主线程时检查
        if Thread.isMainThread, MainActor.assumeIsolated({ Self.debugSeedModesActive }) {
            return false
        }
        #endif
        return true
    }

    #if DEBUG
    @MainActor
    private static var debugSeedModesActive: Bool {
        HoloAppStoreScreenshotSeeder.isRequested
            || HoloMemorySimulatorValidationEnvironment.current != nil
    }
    #endif

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var buildChannel: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    /// 记录一条事件；fire-and-forget，任何失败静默——埋点绝不影响调用方主流程。
    func track(_ name: HoloProductEventName, _ params: [String: String] = [:]) {
        guard Self.isCollecting else { return }
        let event = HoloProductPendingEvent(
            id: UUID().uuidString,
            name: name.rawValue,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            params: params.isEmpty ? nil : params,
            appVersion: Self.appVersion,
            buildChannel: Self.buildChannel,
            sessionId: HoloAnalyticsSession.currentId
        )
        Task { await queue.append(event) }
    }

    /// 首次启动事件（进程内每次冷启动检查一次 UserDefaults once 标记）
    func trackFirstLaunchIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: firstLaunchDefaultsKey) else { return }
        UserDefaults.standard.set(true, forKey: firstLaunchDefaultsKey)
        track(.appFirstLaunch)
    }

    /// 会话事件；冷启动首激活记 cold，之后每次从后台回前台记 foreground。
    /// 每次会话同时开启新的分析会话 ID（前后端链路关联键，见 HoloAnalyticsSession）。
    func trackSessionStart(cold: Bool) {
        _ = HoloAnalyticsSession.beginNew()
        track(.appSessionStart, ["trigger": cold ? "cold" : "foreground"])
    }

    /// 增量上报（冷启动/前台化/进后台调用）；无新事件/失败均静默，下次再试。
    func uploadIfNeeded() async {
        guard Self.isCollecting else { return }
        for _ in 0..<maxBatchesPerFlush {
            let batch = await queue.prefix(maxBatchSize)
            guard !batch.isEmpty else { return }

            let request = APIRequest(
                baseURL: baseURL,
                path: "/v1/product/events",
                method: .post,
                headers: ["X-Holo-Device-Id": deviceIdProvider()],
                body: UploadRequest(events: batch.map(Payload.init))
            )
            do {
                let response: UploadResponse = try await apiClient.send(request)
                guard response.ok else {
                    logger.error("埋点上报被拒绝，保留待重试")
                    return
                }
                await queue.remove(ids: Set(batch.map(\.id)))
                logger.info("埋点上报成功 accepted=\(response.accepted ?? 0, privacy: .public)")
            } catch let error as APIError {
                // 4xx（旧后端白名单拒收新事件名等）= 本批永久失败：丢弃防毒丸重试；
                // 401/429/网络/5xx 保留，下次前台化续传
                if Self.isPermanentClientError(error) {
                    await queue.remove(ids: Set(batch.map(\.id)))
                    logger.error("埋点上报被 4xx 拒绝，丢弃本批：\(error.errorDescription ?? "", privacy: .public)")
                } else {
                    logger.error("埋点上报失败（下次前台化重试）：\(String(describing: error), privacy: .public)")
                }
                return
            } catch {
                logger.error("埋点上报失败（下次前台化重试）：\(String(describing: error), privacy: .public)")
                return
            }
            if batch.count < maxBatchSize { return }
        }
    }

    private static func isPermanentClientError(_ error: APIError) -> Bool {
        let statusCode: Int
        switch error {
        case .httpError(let code, _), .backendError(let code, _, _, _):
            statusCode = code
        default:
            return false
        }
        switch statusCode {
        case 400...499 where statusCode != 401 && statusCode != 408 && statusCode != 429:
            return true
        default:
            return false
        }
    }

    // MARK: - 上报契约（字段与后端 normalizeProductEvent 一一对应）

    private struct UploadRequest: Encodable {
        let events: [Payload]
    }

    private struct Payload: Encodable {
        let id: String
        let name: String
        let timestampMs: Int64
        let params: [String: String]?
        let appVersion: String
        let buildChannel: String
        let sessionId: String?

        init(_ event: HoloProductPendingEvent) {
            self.id = event.id
            self.name = event.name
            self.timestampMs = event.timestampMs
            self.params = event.params
            self.appVersion = event.appVersion
            self.buildChannel = event.buildChannel
            self.sessionId = event.sessionId
        }
    }

    private struct UploadResponse: Decodable {
        let ok: Bool
        let accepted: Int?
        let disabled: Bool?
    }
}
