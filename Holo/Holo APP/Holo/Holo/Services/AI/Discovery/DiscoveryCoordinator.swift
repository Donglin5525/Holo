//
//  DiscoveryCoordinator.swift
//  Holo
//
//  「一个发现」G6 协调器：DiscoveryService 协议实现 + 全链执行器
//  （实施包 02 §8/§9；03 §4 调度与退避、§5 六检查位；01 §5 开启/撤销）。
//
//  职责：串联 调度决策 → 六检查位（读源/candidates/verify/提交/展示/续聊）→
//  结构门禁 → 反例召回 → 独立核验 → 发布门禁 → 本机落库；
//  以及 enable/disable/openFinding/反馈/续聊草稿/refresh 的 UI 服务面。
//
//  线程纪律：本类 @MainActor（UI 状态唯一真源）；重活（来源召回/反例/回源核版本）
//  经 Task.detached(utility) 下后台，网络 await 天然不占主线程；
//  store 写入为微数据量（候选 ≤3、发现 ≤1）inline 执行。
//
//  中断语义（T09）：每次跨 await 边界复核「epoch + 开关 + 总授权 + Task 取消」，
//  失效即丢弃在途结果（迟到结果永不采纳）、best effort cancel 服务端 run。
//  kill 恢复（T41）：init 把 preparing/scheduled 旧 run 保守标 cancelled，不重调已 dispatch 阶段。
//

import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 客户端服务面（测试替身挂接点；真实实现即 DiscoveryClient）

/// DiscoveryClient 的协议化投影（八端点签名逐字对齐）。
/// 生产用 DiscoveryClient；测试按本协议实现替身。
protocol DiscoveryClientServing {
    func capabilities() async throws -> DiscoveryClient.CapabilitiesResponse
    func control() async throws -> DiscoveryClient.ControlResponse
    func enable(
        expectedRevision: Int,
        allowedDomains: [String],
        consentDocVersion: String?,
        confirmTakeover: Bool,
        requestID: String
    ) async throws -> DiscoveryClient.EnableResponse
    func disable(requestID: String, reason: String?) async throws -> DiscoveryClient.DisableResponse
    func updateScope(
        expectedRevision: Int,
        allowedDomains: [String],
        consentDocVersion: String?,
        requestID: String
    ) async throws -> DiscoveryClient.ScopeResponse
    func createRun(
        runID: String,
        sourceManifestDigest: String?,
        requestID: String?
    ) async throws -> DiscoveryClient.CreateRunResponse
    func candidates(
        runID: String,
        runToken: String,
        requestID: String?,
        data: DiscoveryJSONValue
    ) async throws -> (response: DiscoveryClient.StageResponse, envelope: DiscoveryCandidateEnvelope)
    func verify(
        runID: String,
        runToken: String,
        requestID: String?,
        candidates: DiscoveryJSONValue,
        data: DiscoveryJSONValue
    ) async throws -> (response: DiscoveryClient.StageResponse, envelope: DiscoveryVerificationEnvelope)
    func cancel(runID: String, requestID: String) async throws -> DiscoveryClient.CancelResponse
    /// 1.1.5 候选异步作业（交材料即返回；手机前台取件）。默认实现=不支持 → 协调器回落同步端点。
    func startCandidatesAsync(
        runID: String,
        runToken: String,
        requestID: String?,
        data: DiscoveryJSONValue
    ) async throws -> DiscoveryClient.CandidateJobPoll
    func candidatesResult(runID: String, runToken: String) async throws -> DiscoveryClient.CandidateJobPoll
}

extension DiscoveryClientServing {
    func startCandidatesAsync(
        runID: String,
        runToken: String,
        requestID: String?,
        data: DiscoveryJSONValue
    ) async throws -> DiscoveryClient.CandidateJobPoll {
        throw DiscoveryClient.DiscoveryClientError.asyncCandidatesUnsupported
    }

    func candidatesResult(runID: String, runToken: String) async throws -> DiscoveryClient.CandidateJobPoll {
        throw DiscoveryClient.DiscoveryClientError.asyncCandidatesUnsupported
    }
}

extension DiscoveryClient: DiscoveryClientServing {}

// MARK: - 待取件的候选作业（1.1.5：服务端缓存候选 → 手机取件 → 本机找反例 → 核验）

/// 交出材料后、取到候选前的本机缓存。App 被系统回收后，下次前台据此接着取件、
/// 在本机用原样材料做门禁与反例召回——不重新扫描、不重开 run、不另占名额。
/// 只存本次已上行过的证据块（不扩大上传面）；落 Application Support、
/// 首次解锁后可读、不进备份；run 终态即删。
struct DiscoveryPendingCandidateJob: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = DiscoveryPendingCandidateJob.currentSchemaVersion
    let runID: String
    let runToken: String
    /// 异步启动的请求 ID：重交同 body 时复用（服务端幂等）
    let startRequestID: String
    let freeze: DiscoveryRunFreeze
    let material: DiscoveryMaterialPackage
    /// 初次召回请求的变化对象（反例召回复用同一请求口径）
    let changedSourceRefs: [String]
    /// 冻结时的授权域（rawValue，排序）
    let allowedDomains: [String]
    let startedAt: Date
    /// 服务端 run 租约到期；过期即放弃取件
    var leaseExpiresAt: Date?
}

/// 待取件作业的本机存储（单槽位）。fileURL=nil 为内存模式（测试/非生产装配）。
@MainActor
final class DiscoveryPendingCandidateJobStore {

    private let fileURL: URL?
    private var memory: DiscoveryPendingCandidateJob?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    /// 生产装配：Application Support/Discovery/pending-candidate-job.json
    static func live() -> DiscoveryPendingCandidateJobStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = base?
            .appendingPathComponent("Discovery", isDirectory: true)
            .appendingPathComponent("pending-candidate-job.json")
        return DiscoveryPendingCandidateJobStore(fileURL: url)
    }

    func load() -> DiscoveryPendingCandidateJob? {
        guard let fileURL else { return memory }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let job = try? JSONDecoder().decode(DiscoveryPendingCandidateJob.self, from: data),
              job.schemaVersion == DiscoveryPendingCandidateJob.currentSchemaVersion else {
            // 结构不认识（版本升级/损坏）：丢弃，不阻塞后续批次
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return job
    }

    func save(_ job: DiscoveryPendingCandidateJob) throws {
        guard let fileURL else {
            memory = job
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(job)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: [.atomic])
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(values)
    }

    func clear() {
        memory = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

/// 批次期间保后台执行时长（锁屏/切走后系统给的宽限期内把取件与核验跑完）。
/// 返回结束闭包；非 UIKit 平台/测试为空操作。
@MainActor
enum DiscoveryBackgroundExecution {
    static func live(_ name: String) -> () -> Void {
        #if canImport(UIKit) && !os(watchOS)
        let token = DiscoveryBackgroundTaskToken()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            if token.id != .invalid {
                UIApplication.shared.endBackgroundTask(token.id)
                token.id = .invalid
            }
        }
        return {
            if token.id != .invalid {
                UIApplication.shared.endBackgroundTask(token.id)
                token.id = .invalid
            }
        }
        #else
        return {}
        #endif
    }
}

#if canImport(UIKit) && !os(watchOS)
@MainActor
private final class DiscoveryBackgroundTaskToken {
    var id: UIBackgroundTaskIdentifier = .invalid
}
#endif

// MARK: - 版本包（冻结用）

/// 冻结十三字段中的四个版本号。capabilities 只暴露 policyVersion；
/// V1 以 prompt registry 首版（1）与路由首版（1）代入，后端扩展独立版本后从此处替换。
struct DiscoveryVersionBundle: Equatable, Sendable {
    var candidatePromptVersion = 1
    var verifyPromptVersion = 1
    var modelRouteVersion = 1
    var policyVersion = 1

    init(
        candidatePromptVersion: Int = 1,
        verifyPromptVersion: Int = 1,
        modelRouteVersion: Int = 1,
        policyVersion: Int = 1
    ) {
        self.candidatePromptVersion = candidatePromptVersion
        self.verifyPromptVersion = verifyPromptVersion
        self.modelRouteVersion = modelRouteVersion
        self.policyVersion = policyVersion
    }
}

// MARK: - 批次触发原因

enum DiscoveryRunReason: Sendable, Equatable {
    /// 首次开启后的受限历史准备（03 §4.3：无需等新增记录）
    case enableFirstRun
    case foregroundActivation
    case dirtyMark
    case refresh
    case retry
}

// MARK: - 协调器侧储（UserDefaults，holo.discovery.coordinator.* 前缀）

/// pendingDisableIntent（离线待提交撤权）／suppressedCategories（notInterested 类别抑制）／
/// processedRecord（noFinding 等成功终态，同材料不重跑 T20）。
/// 规格位置本应在 DiscoverySettings；因 G6 任务不改该文件，等价落在独立侧储（键同前缀）。
nonisolated final class DiscoveryCoordinatorSideStore {

    private let defaults: UserDefaults

    private enum Keys {
        static let prefix = "holo.discovery.coordinator."
        static let pendingDisableIntent = Keys.prefix + "pendingDisableIntent"
        static let suppressedCategories = Keys.prefix + "suppressedCategories"
        static let processedDigest = Keys.prefix + "processed.digest"
        static let processedAt = Keys.prefix + "processed.at"
        static let processedPolicyVersion = Keys.prefix + "processed.policyVersion"
        static let processedPromptVersion = Keys.prefix + "processed.promptVersion"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // 离线撤权意图（01 §5：确认前禁止重新发送材料；联网后优先补交）
    var hasPendingDisableIntent: Bool {
        defaults.bool(forKey: Keys.pendingDisableIntent)
    }

    func setPendingDisableIntent() {
        defaults.set(true, forKey: Keys.pendingDisableIntent)
    }

    func clearPendingDisableIntent() {
        defaults.set(false, forKey: Keys.pendingDisableIntent)
    }

    // notInterested 的类别抑制（可恢复；resetFeedbackSuppression 清除）
    var suppressedCategories: Set<String> {
        Set(defaults.stringArray(forKey: Keys.suppressedCategories) ?? [])
    }

    func addSuppressedCategory(_ category: String) {
        var categories = suppressedCategories
        guard categories.insert(category).inserted else { return }
        defaults.set(Array(categories).sorted(), forKey: Keys.suppressedCategories)
    }

    func clearSuppressedCategories() {
        defaults.removeObject(forKey: Keys.suppressedCategories)
    }

    // 成功终态记录（03 §4.4：材料不变时下一天也不再跑；版本升级可受控重评估）
    var processedRecord: DiscoveryProcessedRecord? {
        guard let digest = defaults.string(forKey: Keys.processedDigest) else { return nil }
        let at = Date(timeIntervalSince1970: defaults.double(forKey: Keys.processedAt))
        return DiscoveryProcessedRecord(
            sourceManifestDigest: digest,
            processedAt: at,
            policyVersion: defaults.integer(forKey: Keys.processedPolicyVersion),
            promptVersion: defaults.integer(forKey: Keys.processedPromptVersion)
        )
    }

    func recordProcessed(digest: String, policyVersion: Int, promptVersion: Int, at: Date) {
        defaults.set(digest, forKey: Keys.processedDigest)
        defaults.set(at.timeIntervalSince1970, forKey: Keys.processedAt)
        defaults.set(policyVersion, forKey: Keys.processedPolicyVersion)
        defaults.set(promptVersion, forKey: Keys.processedPromptVersion)
    }
}

// MARK: - 协调器

@MainActor
final class DiscoveryCoordinator: NSObject, DiscoveryService {

    // MARK: 依赖（全部注入可替换）

    private let settings: DiscoverySettings
    private let store: DiscoveryStore
    private let accessPolicy: DiscoveryAccessPolicy
    private let client: DiscoveryClientServing
    private let adapters: [any DiscoverySourceAdapting]
    private let retriever: DiscoveryRetriever
    private let evidenceBuilder: DiscoveryEvidenceBuilder
    private let schedulerCore: DiscoverySchedulerCore
    private let publicationPolicy: DiscoveryPublicationPolicy
    private let invalidationService: DiscoveryInvalidationService
    private let environmentProvider: DiscoveryEnvironmentProvider
    private let continuationBuilder: DiscoveryContinuationBuilder
    private let clock: () -> Date
    private let calendar: Calendar
    private let deviceIdProvider: () -> String
    private let consentProvider: () -> Bool
    private let idProvider: () -> String
    private let resourceSnapshotProvider: () -> DiscoveryResourceSnapshot
    private let sideStore: DiscoveryCoordinatorSideStore
    /// 知识仓库提供者（融合联动）。nil = 测试装配：知识特性惰性降级，不影响发现主链。
    private let knowledgeRepositoryProvider: (@Sendable () async throws -> CoreDataHoloMemoryRepository)?
    /// 1.1.5 待取件作业（单槽位）
    private let pendingJobStore: DiscoveryPendingCandidateJobStore
    /// 批次期间申请后台宽限（返回结束闭包）
    private let backgroundExecution: @MainActor (String) -> () -> Void
    /// 取件轮询间隔等待（测试注入为空操作）
    private let pollSleeper: @Sendable (TimeInterval) async -> Void

    // MARK: 运行状态（UI 单一事实源）

    private(set) var presentationState: DiscoveryPresentationState = .disabled
    private(set) var settingsDetailState: DiscoverySettingsDetailState = .disabled
    private(set) var currentFinding: DiscoveryFindingPresentation?
    private(set) var isDetailPresented = false

    /// 在途批次任务（测试可 await 其完成）
    private(set) var batchTask: Task<Void, Never>?
    /// 已排定的重试任务（测试观察预算窗口重试是否已排）
    private(set) var retryTask: Task<Void, Never>?

    private var dirtyMarks: [DiscoveryDirtyMark] = []
    /// 首次开启后的受限历史准备尚未完成（不消费到批次终态）
    private var firstRunPending = false

    /// 关键路径可观测日志（notice 级进系统日志流；2026-10-30 事故诊断加，
    /// 此前该链路零埋点，真机「批次从不发起」只能盲猜）。
    /// 2026-11-01 增文件通道：真机 oslog/syslog 抓取时灵时不灵（三轮实锤），
    /// 同时 append 到沙盒 Documents/disp-diag.log（8KB 滚动），devicectl 直拉 100% 可靠。
    private static let diagLog: DiscoveryDiagLog = {
        let logger = Logger(subsystem: "com.holo.app", category: "Discovery")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("disp-diag.log")
        return DiscoveryDiagLog(logger: logger, fileURL: url)
    }()
    /// 最近一次运行所处相位（waitingForMaterial 是无 runID 的纯展示态）
    private var lastPhase: DiscoveryRunPhase = .waitingForMaterial
    private var lastFailure: DiscoveryFailureKind?
    /// 连续网络失败的退避阶梯计数（5/15/45 分钟；预检通过即复位）
    private var networkRetryAttempt = 0
    /// 诊断（2026-10-30）：任何赋值都留痕——排查新进程预算态来源异常
    private var budgetResetAt: Date? {
        didSet {
            if oldValue != budgetResetAt {
                let captured = budgetResetAt
                Self.diagLog.notice("disp budgetResetAt SET \(String(describing: oldValue)) → \(String(describing: captured))")
            }
        }
    }
    private var dailyBatchAvailable = true
    private var serverCapabilitiesEnabled = true
    /// 本进程已探明服务端不支持候选异步作业（老服务端/密钥未配）→ 直接走同步，下次启动重新探测
    private var asyncCandidatesUnsupported = false
    /// 同日服务端可重试失败的已重试次数（本机兜底上限；跨自然日复位）
    private var serverRetryCount = 0
    private var serverRetryDay: Date?
    private var versions = DiscoveryVersionBundle()
    /// 有效发现曾存在但已过期/失效（设置页 stale 文案依据）
    private var findingRecentlyLost = false

    // MARK: - 装配

    init(
        settings: DiscoverySettings = .shared,
        store: DiscoveryStore,
        accessPolicy: DiscoveryAccessPolicy = DiscoveryAccessPolicy(),
        client: DiscoveryClientServing = DiscoveryClient(),
        adapters: [any DiscoverySourceAdapting]? = nil,
        retriever: DiscoveryRetriever? = nil,
        evidenceBuilder: DiscoveryEvidenceBuilder = DiscoveryEvidenceBuilder(),
        schedulerCore: DiscoverySchedulerCore = DiscoverySchedulerCore(),
        publicationPolicy: DiscoveryPublicationPolicy = DiscoveryPublicationPolicy(),
        invalidationService: DiscoveryInvalidationService? = nil,
        environmentProvider: DiscoveryEnvironmentProvider? = nil,
        continuationBuilder: DiscoveryContinuationBuilder? = nil,
        clock: @escaping () -> Date = { Date() },
        calendar: Calendar = .current,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId },
        consentProvider: @escaping () -> Bool = { HoloAIDataProcessingConsent.shared.isGranted },
        idProvider: @escaping () -> String = { UUID().uuidString },
        resourceSnapshotProvider: (() -> DiscoveryResourceSnapshot)? = nil,
        sideStore: DiscoveryCoordinatorSideStore = DiscoveryCoordinatorSideStore(),
        knowledgeRepositoryProvider: (@Sendable () async throws -> CoreDataHoloMemoryRepository)? = nil,
        pendingJobStore: DiscoveryPendingCandidateJobStore? = nil,
        backgroundExecution: (@MainActor (String) -> () -> Void)? = nil,
        pollSleeper: (@Sendable (TimeInterval) async -> Void)? = nil
    ) {
        let resolvedAdapters = adapters ?? [
            DiscoveryThoughtAdapter(),
            DiscoveryTaskAdapter(),
            DiscoveryHabitAdapter(),
        ]
        self.settings = settings
        self.store = store
        self.accessPolicy = accessPolicy
        self.client = client
        self.adapters = resolvedAdapters
        self.retriever = retriever ?? DiscoveryRetriever(adapters: resolvedAdapters)
        self.evidenceBuilder = evidenceBuilder
        self.schedulerCore = schedulerCore
        self.publicationPolicy = publicationPolicy
        self.invalidationService = invalidationService ?? DiscoveryInvalidationService(store: store)
        let resolvedEnvironmentProvider = environmentProvider ?? DiscoveryEnvironmentProvider()
        self.environmentProvider = resolvedEnvironmentProvider
        self.continuationBuilder = continuationBuilder ?? DiscoveryContinuationBuilder(
            store: store,
            settings: settings,
            accessPolicy: accessPolicy,
            adapters: resolvedAdapters,
            clock: clock,
            consentProvider: consentProvider
        )
        self.clock = clock
        self.calendar = calendar
        self.deviceIdProvider = deviceIdProvider
        self.consentProvider = consentProvider
        self.idProvider = idProvider
        self.resourceSnapshotProvider = resourceSnapshotProvider ?? { resolvedEnvironmentProvider.snapshot() }
        self.sideStore = sideStore
        self.knowledgeRepositoryProvider = knowledgeRepositoryProvider
        // 非生产装配默认内存槽位（测试互不串扰）；生产由 makeLive 注入文件槽位
        self.pendingJobStore = pendingJobStore ?? DiscoveryPendingCandidateJobStore()
        self.backgroundExecution = backgroundExecution ?? { _ in {} }
        self.pollSleeper = pollSleeper ?? { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
        super.init()

        // App kill 恢复（T41）：在途旧 run 保守标 cancelled（本地），不重调已 dispatch 阶段；
        // 下一次资格（新材料/首开/次日批次）再跑。
        // 1.1.5 例外：待取件的那一单保留（服务端仍在算/已算完待取），下次批次入口接着取件。
        let pendingRunID = self.pendingJobStore.load()?.runID
        if let active = (try? store.activeRuns()), !active.isEmpty {
            let now = clock()
            for record in active where record.runID != pendingRunID {
                try? store.updateRunPhase(
                    runID: record.runID,
                    phase: .cancelled,
                    diagnostics: [.controlChanged],
                    now: now
                )
            }
        }
        if let pendingRunID {
            let stillActive = ((try? store.activeRuns()) ?? []).contains { $0.runID == pendingRunID }
            if !stillActive {
                // 本机 run 记录已不在途（被清理/已终态）：缓存失去归属，丢弃
                self.pendingJobStore.clear()
                Self.diagLog.notice("disp init: pending job dropped (run not active) run=\(pendingRunID)")
            } else {
                Self.diagLog.notice("disp init: pending job kept for pickup run=\(pendingRunID)")
            }
        }

        // 首跑待办恢复（2026-10-30）：firstRunPending 是「已开启但从未成功终态」的派生态，
        // 从持久化事实推导，不依赖内存（此前仅存内存，重启即丢且无恢复——10-28 东林真机
        // 首跑撞预算 429 后，重启被快路径永远挡住，功能卡死在「还在等足够的记录」）。
        // processedRecord 只在成功终态写入（含发布），nil ⟺ 从未跑完过一个批次。
        let restoreEnabled = settings.snapshot().isEnabled
        let restoreProcessed = sideStore.processedRecord != nil
        if restoreEnabled, !restoreProcessed {
            firstRunPending = true
        }
        Self.diagLog.notice("disp init restore: enabled=\(restoreEnabled) processedRecord=\(restoreProcessed) → firstRunPending=\(self.firstRunPending)")

        self.invalidationService.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange(_:)),
            name: .holoDiscoverySettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKnowledgeControl(_:)),
            name: .holoKnowledgeControlDidApply,
            object: nil
        )
        recomputePresentation()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 生产装配（G5/G7 接入点）。store 装配失败属不可恢复环境故障，尽早暴露。
    static func makeLive(
        activityProvider: @escaping @Sendable () -> DiscoveryUserActivityState = { DiscoveryUserActivityState() }
    ) -> DiscoveryCoordinator {
        let store = try! DiscoveryStore()
        return DiscoveryCoordinator(
            store: store,
            knowledgeRepositoryProvider: { try await HoloMemoryRuntime.shared.repository() },
            pendingJobStore: .live(),
            backgroundExecution: { DiscoveryBackgroundExecution.live($0) }
        )
    }

    /// 进程级单例：ChatViewModel/设置页/ChatView 的统一服务面（ChatViewModel 以 @StateObject
    /// 无参创建、无注入通道，故走单例；HoloApp 前台激活调 shared.refresh()）。
    @MainActor static let shared: DiscoveryCoordinator = DiscoveryCoordinator.makeLive()

    @objc private func handleSettingsChange(_ note: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.settings.snapshot().isEnabled {
                self.batchTask?.cancel()
            }
            self.recomputePresentation()
        }
    }

    /// 离线撤权意图是否待补交（测试/集成观察面；确认前 runBatch 永不发起）。
    var isDisableIntentPending: Bool {
        sideStore.hasPendingDisableIntent
    }

    // MARK: - Dirty 登记（三域变更事件接入点）

    /// 距上次成功终态是否已跨自然日（「每天一个发现」的日历首查资格）。
    /// 无成功终态记录时恒 false（该场景由 firstRunPending 资格覆盖，不重复计算）。
    private func isPastDaySinceLastTerminal(now: Date) -> Bool {
        guard let processed = sideStore.processedRecord else { return false }
        return !calendar.isDate(processed.processedAt, inSameDayAs: now)
    }

    /// 有效来源变更登记（03 §4.3：仅查看/同步相同版本/改展示设置不产生 mark）。
    /// 同域同 digest 增量去重（改回原样不累积新材料）。
    func markDirty(domain: DiscoverySourceDomain, changedAt: Date? = nil, digestContribution: String) {
        let mark = DiscoveryDirtyMark(
            domain: domain,
            changedAt: changedAt ?? clock(),
            digestContribution: digestContribution
        )
        guard !dirtyMarks.contains(where: { $0.domain == mark.domain && $0.digestContribution == mark.digestContribution })
        else { return }
        dirtyMarks.append(mark)
    }

    // MARK: - 批次入口

    /// 在途批次标志。Task.isCancelled 对已完成任务恒为 false，不能当在途判断
    /// （首版实现据此误判「已完成」为「在途」，导致后续 runBatch 永远被挡）。
    private var isBatchRunning = false
    /// 批次代数：disable 中断在途批次后，旧任务收尾不得清掉新批次的在途标志。
    private var batchGeneration = 0

    /// 排一次批次（utility 优先级）。单飞：在途批次不叠加；批次结束后释放。
    func runBatch(reason: DiscoveryRunReason) {
        if isBatchRunning {
            Self.diagLog.notice("disp runBatch skip: batch in flight, reason=\(String(describing: reason))")
            return
        }
        Self.diagLog.notice("disp runBatch start: reason=\(String(describing: reason))")
        isBatchRunning = true
        batchGeneration += 1
        let generation = batchGeneration
        let epoch = settings.snapshot().localGrantEpoch
        batchTask = Task(priority: .utility) { [weak self] in
            // 1.1.5：锁屏/切走后系统给的宽限期内把取件与核验跑完（候选 3–17s、核验 ~1s）
            let endBackground = self?.backgroundExecution("HoloDiscoveryBatch")
            await self?.executeBatch(reason: reason, epoch: epoch)
            endBackground?()
            guard let self else { return }
            if self.batchGeneration == generation {
                self.isBatchRunning = false
            }
        }
    }

    // MARK: - 全链执行

    private func executeBatch(reason: DiscoveryRunReason, epoch: Int) async {
        // 离线撤权意图未补交确认前，永不发起（01 §5）
        guard !sideStore.hasPendingDisableIntent else {
            Self.diagLog.notice("disp exit: pendingDisableIntent")
            return
        }

        let settingsSnapshot = settings.snapshot()
        let consentGranted = consentProvider()
        guard settingsSnapshot.isEnabled, consentGranted else {
            Self.diagLog.notice("disp exit: enabled=\(settingsSnapshot.isEnabled) consent=\(consentGranted)")
            await stopAndHide(.controlDisabled, runID: nil)
            return
        }

        // 1.1.5 取件续跑优先：上次交出的材料还在服务端（算着或已算完待取）→ 接着取件，
        // 不重新扫描、不重开 run、不另占名额。必须在快路径之前（续跑与有无新变更无关）。
        if let pending = pendingJobStore.load() {
            if await resumePendingCandidateJob(pending, epoch: epoch) { return }
        }

        // 快路径：无未消费变更、非首开、且未跨自然日 → 无新材料（本地零读源，前台激活便宜）。
        // 跨日放行进完整决策：由扫描自比 manifestDigest 判定材料是否真的变了（T20 拦住未变日）。
        let fastPathNow = clock()
        let marksCount = dirtyMarks.count
        let firstRunStillPending = firstRunPending
        if marksCount == 0 && !firstRunStillPending && !isPastDaySinceLastTerminal(now: fastPathNow) {
            Self.diagLog.notice("disp exit: fastPath marks=\(marksCount) firstRunPending=\(firstRunStillPending)")
            lastPhase = .waitingForMaterial
            recomputePresentation()
            return
        }

        // 网络预检提前到重活之前：decide 的 networkUnavailable 分支原本在 90 天窗口
        // 全量扫描+召回之后才生效，断网时会每 5 分钟空转一轮全量 CoreData 重活。
        // 此处先挡（未 dispatch、不消耗任何东西），重试仍按退避排程
        if !resourceSnapshotProvider().isNetworkAvailable {
            Self.diagLog.notice("disp exit: preCheck network unavailable")
            applyDeferred(.networkUnavailable, now: fastPathNow)
            return
        }
        networkRetryAttempt = 0   // 网络已通：退避阶梯复位

        // ---- 检查位 1：读源前（localGrant/总授权/范围/来源排除的统一门控）----
        let controlRevision = storedControlRevision
        var environment = makeEnvironment(serverControlRevision: controlRevision)
        let grantedDomains = DiscoverySourceDomain.allCases.filter {
            accessPolicy.canReadSources(domain: $0, environment: environment).isAllowed
        }
        guard !grantedDomains.isEmpty else {
            Self.diagLog.notice("disp exit: no granted domains (scope)")
            await stopAndHide(.scopeInvalid, runID: nil)
            return
        }

        // 初次召回（受限历史准备：授权域 90 天有界窗口扫描 → 变化对象 refs；
        // 03 §4.3 首开不需等待新增记录；扫描与召回重活下后台）
        let baseRequest = DiscoveryRetriever.Request(calendar: calendar)
        let now = clock()
        let scanAdapters = adapters
        let scanDomains = grantedDomains
        let scanWindow = DiscoveryRetriever.windows(for: baseRequest, now: now).history
        let scannedRefs: [String]
        do {
            scannedRefs = try await Task.detached(priority: .utility) {
                try Self.boundedWindowScan(
                    adapters: scanAdapters,
                    domains: scanDomains,
                    window: scanWindow,
                    limit: DiscoveryRetriever.Limits.channelFetchLimit
                )
            }.value
        } catch {
            Self.diagLog.notice("disp exit: scan threw \(String(describing: error))")
            lastPhase = .waitingForMaterial
            recomputePresentation()
            return
        }
        Self.diagLog.notice("disp scan ok: refs=\(scannedRefs.count) domains=\(grantedDomains.map(\.rawValue))")
        let recallRequest = DiscoveryRetriever.Request(
            changedSourceRefs: scannedRefs,
            topicRefs: [],
            needsComparisonHistory: true,
            comparisonAnchorRefs: [],
            calendar: calendar
        )
        let retriever = self.retriever
        let material: DiscoveryMaterialPackage
        do {
            material = try await Task.detached(priority: .utility) {
                try retriever.initialRecall(request: recallRequest, environment: environment, now: now)
            }.value
        } catch {
            // 读源失败（store/谓词异常）：按无材料处理，不消耗批次
            Self.diagLog.notice("disp exit: recall threw \(String(describing: error))")
            lastPhase = .waitingForMaterial
            recomputePresentation()
            return
        }
        guard !Task.isCancelled, isControlStillValid(epoch: epoch) else { return }

        // 资格计数（证据构建器口径：独立 lineage 组数，非段数）
        let qualification = Self.independentGroupCount(of: material.supportAtoms)
        // 本批材料摘要（与 store.sourceManifestDigest 同口径：sourceRef=version 序列化）
        let manifestEntries = Self.manifestEntries(from: material.supportAtoms, fetchedAt: now)
        let currentDigest = Self.manifestDigest(of: manifestEntries)
        Self.diagLog.notice("disp material: atoms=\(material.supportAtoms.count) qualification=\(qualification) digest=\(currentDigest)")

        // ---- 调度决策（03 §4.3/§4.4）----
        refreshBudgetWindow(now: now)
        let decision = schedulerCore.decide(
            marks: dirtyMarks,
            qualification: qualification,
            isFirstEnableAfterGrant: firstRunPending,
            isNewDaySinceLastTerminal: isPastDaySinceLastTerminal(now: now),
            controlEnabled: settings.snapshot().isEnabled,
            consentGranted: consentProvider(),
            scopeValid: !settings.snapshot().allowedDomains.isEmpty,
            dailyBatchAvailable: dailyBatchAvailable,
            budgetResetAt: budgetResetAt,
            processedToday: {
                // 2026-11-01 报告问题4：processedToday 按自然日过滤——跨天的同材料终态
                // 不再拦截（产品语义=每天可再分析一次；成本由日配额与预算池兜底）
                guard let record = sideStore.processedRecord,
                      calendar.isDate(record.processedAt, inSameDayAs: now) else { return nil }
                return record
            }(),
            currentSourceManifestDigest: currentDigest,
            policyVersion: versions.policyVersion,
            promptVersion: versions.candidatePromptVersion,
            resource: resourceSnapshotProvider(),
            now: now
        )

        switch decision {
        case .stopAndHide(let stopReason):
            Self.diagLog.notice("disp decision: stopAndHide \(String(describing: stopReason))")
            await stopAndHide(stopReason, runID: nil)
            return
        case .waitingForMaterial:
            Self.diagLog.notice("disp decision: waitingForMaterial")
            lastPhase = .waitingForMaterial
            recomputePresentation()
            return
        case .deferred(let deferredReason):
            Self.diagLog.notice("disp decision: deferred \(String(describing: deferredReason))")
            if case .resourceYield = deferredReason {
                let snap = resourceSnapshotProvider()
                Self.diagLog.notice("disp yield detail: input=\(snap.isTextInputActive) recording=\(snap.isRecording) manualAI=\(snap.isManualAIRunning) thermal=\(snap.isThermallyConstrained) lowPower=\(snap.isLowPowerMode) lowData=\(snap.isLowDataMode)")
            }
            applyDeferred(deferredReason, now: now)
            return
        case .prepare:
            Self.diagLog.notice("disp decision: prepare → creating run")
            lastFailure = nil   // 新批次已在途：清掉上次的失败展示态（运行期如实显示「正在准备」）
        }

        // ---- 准备运行：runID/清单/检索索引落库 → 冻结 → preparing ----
        let runID = idProvider()
        do {
            try store.recordSourceManifest(runID: runID, entries: manifestEntries)
            try store.recordRetrievalIndex(runID: runID, entries: Self.retrievalEntries(from: material.supportAtoms))
        } catch {
            assertionFailure("Discovery 清单落库失败：\(error)")
            return
        }
        let freeze = DiscoveryRunFreeze(
            runID: runID,
            accountSubject: deviceIdProvider(),
            deviceID: deviceIdProvider(),
            localGrantEpoch: epoch,
            serverControlRevision: controlRevision ?? 0,
            scopeRevision: DiscoveryScopeRevision.digest(domains: settingsSnapshot.allowedDomains),
            // 与 store.sourceManifestDigest 同口径的本地计算（避免落库后回读的时序耦合）
            sourceManifestDigest: currentDigest,
            candidatePromptVersion: versions.candidatePromptVersion,
            verifyPromptVersion: versions.verifyPromptVersion,
            modelRouteVersion: versions.modelRouteVersion,
            policyVersion: versions.policyVersion,
            anchorNow: now,
            timezone: calendar.timeZone.identifier
        )
        do {
            try store.upsertRunState(freeze: freeze, phase: .preparing, now: now)
        } catch {
            assertionFailure("Discovery 运行状态落库失败：\(error)")
            return
        }
        lastPhase = .preparing
        recomputePresentation()

        do {
            // ---- 检查位 2：candidates 发出前（本机代数 + 服务端控制/预算）----
            environment = makeEnvironment(serverControlRevision: controlRevision)
            guard accessPolicy.canRequestCandidates(frozenGrantEpoch: epoch, environment: environment).isAllowed else {
                try await abortInFlight(runID: runID, diagnostics: [.controlChanged])
                return
            }
            let created = try await client.createRun(
                runID: runID,
                sourceManifestDigest: freeze.sourceManifestDigest,
                requestID: idProvider()
            )
            guard !Task.isCancelled, isControlStillValid(epoch: epoch) else {
                try await abortInFlight(runID: runID, diagnostics: [.controlChanged])
                return
            }
            guard created.controlRevision == freeze.serverControlRevision else {
                // 服务端控制已前进：本批冻结失效，刷新控制后结束
                try await abortInFlight(runID: runID, diagnostics: [.controlChanged])
                await refreshControlSnapshot()
                return
            }

            // ---- 候选阶段（1.1.5）：优先异步作业（交材料即返回、前台取件），服务端不支持则回落同步 ----
            let context = CandidateStageContext(
                runID: runID,
                runToken: created.runToken,
                freeze: freeze,
                material: material,
                recallRequest: recallRequest,
                allowedDomains: settingsSnapshot.allowedDomains,
                epoch: epoch
            )
            let requestData = Self.candidateRequestData(
                freeze: freeze,
                material: material,
                allowedDomains: settingsSnapshot.allowedDomains,
                iso: Self.isoFormatter.string(from:)
            )
            var pickedUp: (response: DiscoveryClient.StageResponse, envelope: DiscoveryCandidateEnvelope)?
            if !asyncCandidatesUnsupported {
                switch try await runCandidatesAsync(context, requestData: requestData, resume: false) {
                case .completed(let response, let envelope):
                    pickedUp = (response, envelope)
                case .stillRunning, .aborted:
                    return
                case .unsupported:
                    pickedUp = nil
                }
            }
            let stage: (response: DiscoveryClient.StageResponse, envelope: DiscoveryCandidateEnvelope)
            if let pickedUp {
                stage = pickedUp
            } else {
                stage = try await client.candidates(
                    runID: runID,
                    runToken: created.runToken,
                    requestID: idProvider(),
                    data: requestData
                )
            }
            try await continueAfterCandidates(
                context,
                stageResponse: stage.response,
                envelope: stage.envelope,
                environment: environment
            )
            pendingJobStore.clear()
        } catch {
            // 网络类失败（作业可能仍在服务端算）保留取件缓存，下次前台接着取；其余作废
            if !Self.keepsPendingJob(after: error) { pendingJobStore.clear() }
            handleStageFailure(error, runID: runID, digest: freeze.sourceManifestDigest)
        }
    }

    // MARK: - 候选后半段（1.1.5 抽出：同步与异步取件共用）

    /// 一次候选阶段的上下文（同步路径在内存里直接有；续跑由取件缓存还原）
    private struct CandidateStageContext: Sendable {
        let runID: String
        let runToken: String
        let freeze: DiscoveryRunFreeze
        let material: DiscoveryMaterialPackage
        let recallRequest: DiscoveryRetriever.Request
        let allowedDomains: Set<DiscoverySourceDomain>
        let epoch: Int
    }

    /// 拿到候选之后：结构门禁 → 反例召回（只在本机）→ 回源核版本 → 核验 → 提交。
    /// 逐行搬自 executeBatch 原后半段（行为不变）；now 取冻结锚点（与原批次 now 同值）。
    private func continueAfterCandidates(
        _ context: CandidateStageContext,
        stageResponse: DiscoveryClient.StageResponse,
        envelope: DiscoveryCandidateEnvelope,
        environment: DiscoveryAccessSnapshot
    ) async throws {
        let runID = context.runID
        let freeze = context.freeze
        let material = context.material
        let recallRequest = context.recallRequest
        let epoch = context.epoch
        let now = freeze.anchorNow
        guard !Task.isCancelled, isControlStillValid(epoch: epoch) else {
            try await abortInFlight(runID: runID, diagnostics: [.controlChanged])
            return
        }
        // 门禁 2（归属）：服务端阶段响应与信封 runID 必须一致
        guard stageResponse.runID == runID, envelope.runID == runID else {
            try await abortInFlight(runID: runID, diagnostics: [.schemaInvalid])
            return
        }

        // 版本回填（2026-11-01 报告问题4）：后端实际使用的 prompt 版本写回本地版本包，
        // 使 processedRecord 的「同版本不重跑」随服务端升级自动获得重评估资格
        if let serverPromptVersion = stageResponse.promptVersion, serverPromptVersion != versions.candidatePromptVersion {
            versions.candidatePromptVersion = serverPromptVersion
            Self.diagLog.notice("disp prompt version synced: candidate v\(serverPromptVersion)")
        }

        // ---- 结构门禁（02 §5 八条；1/3 的 schema 部分已在客户端解码时完成）----
        let historyWindow = DiscoveryRetriever.windows(for: recallRequest, now: now).history
        let gate = runStructuralGate(
            candidates: envelope.candidates,
            material: material,
            historyWindow: historyWindow
        )
        Self.diagLog.notice("disp gate: received=\(envelope.candidates.count) survivors=\(gate.survivors.count) diagnostics=\(gate.diagnostics.map(\.rawValue))")

        if envelope.candidates.isEmpty {
            // 服务端对空候选自动 completeRun（03 §4.2），客户端不调 verify、不 cancel
            try finishBatchNoFinding(runID: runID, digest: freeze.sourceManifestDigest, diagnostics: gate.diagnostics)
            return
        }
        if gate.survivors.isEmpty {
            // 本地全拒：cancel 释放后续语义（不承诺第三方未处理），并记成功终态
            Self.diagLog.notice("disp cancel: structural gate rejected all")
            _ = try? await client.cancel(runID: runID, requestID: idProvider())
            try finishBatchNoFinding(runID: runID, digest: freeze.sourceManifestDigest, diagnostics: gate.diagnostics)
            return
        }

        // ---- 反例召回（02 §6）+ 回源核版本（变了不用旧块）----
        let counterPackages = try await counterRecall(
            for: gate.survivors,
            supportAtoms: material.supportAtoms,
            request: recallRequest,
            environment: environment
        )
        guard !Task.isCancelled, isControlStillValid(epoch: epoch) else {
            try await abortInFlight(runID: runID, diagnostics: [.controlChanged])
            return
        }
        let mergedCounter = DiscoveryRetriever.mergedCounterPackage(
            Array(counterPackages.values),
            totalBudget: material.counterBudgetBlocks
        )
        let stale = try await Task.detached(priority: .utility) { [retriever] in
            try retriever.revalidate(
                atoms: material.supportAtoms + mergedCounter.blocks,
                environment: environment,
                now: now
            )
        }.value
        guard !Task.isCancelled, isControlStillValid(epoch: epoch) else {
            try await abortInFlight(runID: runID, diagnostics: [.controlChanged])
            return
        }
        let staleEvidenceIDs = Set(stale.map(\.evidenceID))
        let verifiedCandidates = gate.survivors.filter { candidate in
            let cited = Self.citedEvidenceIDs(of: candidate)
            return cited.isDisjoint(with: staleEvidenceIDs)   // 有 stale 即拒（02 §5 门禁 8）
        }
        if verifiedCandidates.isEmpty {
            _ = try? await client.cancel(runID: runID, requestID: idProvider())
            try finishBatchNoFinding(
                runID: runID,
                digest: freeze.sourceManifestDigest,
                diagnostics: gate.diagnostics + [.sourceInvalidated]
            )
            return
        }

        // ---- 检查位 3：verify 发出前（源版本已复核；运行阶段 preparing；控制/范围版本）----
        guard accessPolicy.canRequestVerification(runPhase: .preparing, frozenGrantEpoch: epoch, environment: environment).isAllowed else {
            try await abortInFlight(runID: runID, diagnostics: [.controlChanged])
            return
        }
        guard let candidatesEcho = Self.candidatesArray(from: stageResponse.envelope) else {
            try await abortInFlight(runID: runID, diagnostics: [.schemaInvalid])
            return
        }
        let (verifyResponse, verifyEnvelope) = try await client.verify(
            runID: runID,
            runToken: context.runToken,
            requestID: idProvider(),
            candidates: candidatesEcho,
            data: Self.verifyRequestData(
                freeze: freeze,
                material: material,
                counter: mergedCounter,
                perCandidateCoverage: counterPackages.mapValues(\.coverageState),
                allowedDomains: context.allowedDomains,
                iso: Self.isoFormatter.string(from:)
            )
        )
        // T09：跨 await 复核——撤权/关闭/重开后迟到结果丢弃，永不采纳
        guard !Task.isCancelled, isControlStillValid(epoch: epoch) else {
            try await abortInFlight(runID: runID, diagnostics: [.controlChanged])
            return
        }
        guard verifyResponse.runID == runID, verifyEnvelope.runID == runID else {
            try await abortInFlight(runID: runID, diagnostics: [.schemaInvalid])
            return
        }

        // ---- 提交：核验结果归属 → 检查位 4 → 发布门禁 → 落库 ----
        try await commitIfEligible(
            runID: runID,
            freeze: freeze,
            material: material,
            verifiedCandidates: verifiedCandidates,
            counterPackages: counterPackages,
            mergedCounterBlocks: mergedCounter.blocks,
            verification: verifyEnvelope,
            epoch: epoch
        )
    }

    // MARK: - 候选异步作业（1.1.5：服务端缓存候选 → 手机取件）

    private enum CandidatePickupOutcome {
        case completed(DiscoveryClient.StageResponse, DiscoveryCandidateEnvelope)
        /// 本次前台没等到：缓存保留，稍后/下次前台接着取
        case stillRunning
        /// 控制失效：已 abortInFlight 并作废缓存
        case aborted
        /// 服务端未开放异步作业：回落同步端点
        case unsupported
    }

    /// 单次会话内最多轮询次数（× pollAfterSeconds≈3s ≈ 4 分钟）；超出留待下次取件
    private static let maxPollsPerSession = 80
    /// 仍在算时的补查间隔
    private static let stillRunningRecheckDelay: TimeInterval = 60

    /// 交材料（或续取）并轮询到终态。先落缓存再交材料：交的瞬间被回收，下次凭缓存同 body 重交（服务端幂等）。
    private func runCandidatesAsync(
        _ context: CandidateStageContext,
        requestData: DiscoveryJSONValue,
        resume: Bool
    ) async throws -> CandidatePickupOutcome {
        var job: DiscoveryPendingCandidateJob
        var poll: DiscoveryClient.CandidateJobPoll
        if resume, let existing = pendingJobStore.load(), existing.runID == context.runID {
            job = existing
            do {
                poll = try await client.candidatesResult(runID: context.runID, runToken: context.runToken)
                Self.diagLog.notice("disp async resume: run=\(context.runID) status=\(poll.status.jobStatus.rawValue)")
            } catch let error where Self.isJobNotFound(error) {
                // 启动请求没到服务端（交材料瞬间被回收）：同 requestID 同 body 重交
                Self.diagLog.notice("disp async resume: job not found, resubmit run=\(context.runID)")
                poll = try await client.startCandidatesAsync(
                    runID: context.runID,
                    runToken: context.runToken,
                    requestID: existing.startRequestID,
                    data: requestData
                )
            }
        } else {
            job = DiscoveryPendingCandidateJob(
                runID: context.runID,
                runToken: context.runToken,
                startRequestID: idProvider(),
                freeze: context.freeze,
                material: context.material,
                changedSourceRefs: context.recallRequest.changedSourceRefs,
                allowedDomains: context.allowedDomains.map(\.rawValue).sorted(),
                startedAt: clock(),
                leaseExpiresAt: nil
            )
            try pendingJobStore.save(job)
            do {
                poll = try await client.startCandidatesAsync(
                    runID: context.runID,
                    runToken: context.runToken,
                    requestID: job.startRequestID,
                    data: requestData
                )
                Self.diagLog.notice("disp async start: run=\(context.runID) status=\(poll.status.jobStatus.rawValue)")
            } catch let error where Self.isAsyncUnsupported(error) {
                pendingJobStore.clear()
                asyncCandidatesUnsupported = true
                Self.diagLog.notice("disp async unsupported → sync fallback: \(String(describing: error))")
                return .unsupported
            }
        }

        var polls = 0
        while true {
            if let lease = poll.status.leaseExpiresAt {
                let leaseDate = Date(timeIntervalSince1970: TimeInterval(lease) / 1000)
                if job.leaseExpiresAt != leaseDate {
                    job.leaseExpiresAt = leaseDate
                    try? pendingJobStore.save(job)
                }
            }
            switch poll.status.jobStatus {
            case .completed:
                guard let completed = poll.completed else {
                    throw DiscoveryClient.DiscoveryClientError.unexpectedStageEnvelope(runID: context.runID)
                }
                Self.diagLog.notice("disp async completed: run=\(context.runID) polls=\(polls)")
                return .completed(completed.response, completed.envelope)
            case .failed:
                let code = poll.status.error?.code ?? "nil"
                let retryAvailable = poll.status.retryAvailable
                Self.diagLog.notice("disp async failed: run=\(context.runID) code=\(code) retryAvailable=\(retryAvailable)")
                throw DiscoveryClient.DiscoveryClientError.candidateJobFailed(
                    code: poll.status.error?.code,
                    retryAvailable: retryAvailable
                )
            case .running:
                polls += 1
                if polls > Self.maxPollsPerSession {
                    Self.diagLog.notice("disp async still running: keep pending run=\(context.runID)")
                    lastPhase = .preparing
                    recomputePresentation()
                    scheduleRetry(after: Self.stillRunningRecheckDelay)
                    return .stillRunning
                }
                let wait = TimeInterval(min(max(poll.status.pollAfterSeconds ?? 3, 1), 15))
                await pollSleeper(wait)
                guard !Task.isCancelled, isControlStillValid(epoch: context.epoch) else {
                    pendingJobStore.clear()
                    try await abortInFlight(runID: context.runID, diagnostics: [.controlChanged])
                    return .aborted
                }
                poll = try await client.candidatesResult(runID: context.runID, runToken: context.runToken)
            }
        }
    }

    /// 取件续跑。返回 true = 本次批次已由取件流程处理（含仍在等）；false = 缓存已作废，走常规批次。
    private func resumePendingCandidateJob(_ job: DiscoveryPendingCandidateJob, epoch: Int) async -> Bool {
        let now = clock()
        guard job.freeze.localGrantEpoch == epoch else {
            // 关闭重开/撤权后代数前进：旧单作废（best effort 通知服务端）
            Self.diagLog.notice("disp async resume: epoch changed, drop run=\(job.runID)")
            pendingJobStore.clear()
            _ = try? await client.cancel(runID: job.runID, requestID: idProvider())
            try? store.updateRunPhase(runID: job.runID, phase: .cancelled, diagnostics: [.controlChanged], now: now)
            return false
        }
        if let lease = job.leaseExpiresAt, now >= lease {
            Self.diagLog.notice("disp async resume: lease expired, drop run=\(job.runID)")
            pendingJobStore.clear()
            try? store.updateRunPhase(runID: job.runID, phase: .cancelled, diagnostics: [.controlChanged], now: now)
            return false
        }
        guard resourceSnapshotProvider().isNetworkAvailable else {
            Self.diagLog.notice("disp async resume: network unavailable, keep pending run=\(job.runID)")
            applyDeferred(.networkUnavailable, now: now)
            return true
        }
        let allowedDomains = Set(job.allowedDomains.compactMap { DiscoverySourceDomain(rawValue: $0) })
        let context = CandidateStageContext(
            runID: job.runID,
            runToken: job.runToken,
            freeze: job.freeze,
            material: job.material,
            recallRequest: DiscoveryRetriever.Request(
                changedSourceRefs: job.changedSourceRefs,
                topicRefs: [],
                needsComparisonHistory: true,
                comparisonAnchorRefs: [],
                calendar: calendar
            ),
            allowedDomains: allowedDomains,
            epoch: epoch
        )
        lastFailure = nil
        lastPhase = .preparing
        recomputePresentation()
        do {
            let requestData = Self.candidateRequestData(
                freeze: job.freeze,
                material: job.material,
                allowedDomains: allowedDomains,
                iso: Self.isoFormatter.string(from:)
            )
            switch try await runCandidatesAsync(context, requestData: requestData, resume: true) {
            case .completed(let response, let envelope):
                let environment = makeEnvironment(serverControlRevision: storedControlRevision)
                try await continueAfterCandidates(
                    context,
                    stageResponse: response,
                    envelope: envelope,
                    environment: environment
                )
                pendingJobStore.clear()
            case .stillRunning, .aborted:
                break
            case .unsupported:
                pendingJobStore.clear()
                try? store.updateRunPhase(runID: job.runID, phase: .cancelled, diagnostics: [.controlChanged], now: clock())
            }
        } catch {
            if !Self.keepsPendingJob(after: error) { pendingJobStore.clear() }
            handleStageFailure(error, runID: job.runID, digest: job.freeze.sourceManifestDigest)
        }
        return true
    }

    /// 网络类失败（请求可能已到服务端、作业仍在算）保留缓存；其余失败作废。
    private static func keepsPendingJob(after error: Error) -> Bool {
        if error is URLError { return true }
        if let apiError = error as? APIError {
            switch apiError {
            case .networkUnavailable, .timeout:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func isJobNotFound(_ error: Error) -> Bool {
        if case APIError.backendError(404, let code, _, _) = error {
            return code == "DISCOVERY_JOB_NOT_FOUND"
        }
        return false
    }

    /// 服务端没有异步作业：替身默认实现、老服务端无此路由（404）、密钥未配（503 DISCOVERY_ASYNC_UNAVAILABLE）
    private static func isAsyncUnsupported(_ error: Error) -> Bool {
        if case DiscoveryClient.DiscoveryClientError.asyncCandidatesUnsupported = error { return true }
        if let apiError = error as? APIError {
            switch apiError {
            case .backendError(let status, let code, _, _):
                if status == 503 { return code == "DISCOVERY_ASYNC_UNAVAILABLE" }
                if status == 404 {
                    return code != "DISCOVERY_JOB_NOT_FOUND" && code != "DISCOVERY_RUN_NOT_FOUND"
                }
                return false
            case .httpError(let status, _):
                return status == 404
            default:
                return false
            }
        }
        return false
    }

    // MARK: - 结构门禁（02 §5）

    /// 结构门禁结果
    private struct StructuralGateOutcome {
        var survivors: [DiscoveryCandidate] = []
        var diagnostics: [DiscoveryDiagnosticReasonCode] = []
    }

    /// 02 §5 八条中的本地部分（schema/白名单/唯一性/claim 全覆盖已由
    /// DiscoveryAIPacket.decodeValidated* 在解码时执行）。
    /// 此处执行：evidenceID 本批可用、quote 回原文对齐、区间不超取数范围、
    /// 定量句只认 computedFact（百分比/相关系数首发禁）、敏感、否定指纹。
    /// type 计数门槛与独立事件计数在发布门禁（证据计数为准）复核。
    private func runStructuralGate(
        candidates: [DiscoveryCandidate],
        material: DiscoveryMaterialPackage,
        historyWindow: DiscoveryTimeWindow
    ) -> StructuralGateOutcome {
        // 指纹批量预取（检查位 8 的一半在结构层复查，提交前还会再复核）
        var negativeFingerprints = Set(sideStore.suppressedCategories)
        for candidate in candidates {
            let fingerprint = DiscoveryPublicationPolicy.subjectFingerprint(of: candidate)
            if (try? store.hasNegativeFeedback(fingerprintMaterial: fingerprint)) == true {
                negativeFingerprints.insert(fingerprint)
            }
        }

        var outcome = StructuralGateOutcome()
        let availableEvidence = Dictionary(
            material.supportAtoms.map { ($0.evidenceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let validMetricIDs = Set(material.supportAtoms.flatMap { $0.computedFacts.map(\.metricID) })

        for candidate in candidates {
            var accepted = true

            // 门禁 3：evidenceID 本批可用 + quote 回原文（对齐失败拒，不取第一个）
            for claim in candidate.claims {
                for citation in claim.citations {
                    guard let atom = availableEvidence[citation.evidenceID] else {
                        accepted = false
                        outcome.diagnostics.append(.irrelevantCitation)
                        continue
                    }
                    guard atom.sourceKind != .computedFact else {
                        // computedFact 是程序产物，不是可引用原文的 quote 证据
                        accepted = false
                        outcome.diagnostics.append(.irrelevantCitation)
                        continue
                    }
                    guard DiscoveryQuoteAlignment.align(quote: citation.quote, source: atom.sourceBlock) != nil else {
                        accepted = false
                        outcome.diagnostics.append(.quoteMismatch)
                        continue
                    }
                }
            }

            // 门禁 5：区间不能超取数范围（缺发生时间的材料不支持精确时序由发布门禁兜）
            let rangeDates = ([candidate.timeRange] + candidate.comparisonPeriods).flatMap { range in
                [range.start, range.end].compactMap { $0 }.compactMap(DiscoveryISO8601.parse)
            }
            if !rangeDates.allSatisfy({ historyWindow.contains($0) }) {
                accepted = false
                outcome.diagnostics.append(.unsupportedGeneralization)
            }

            // 门禁 6：定量句只认 computedFact；百分比/相关系数首发一律拒
            for claim in candidate.claims {
                if !claim.metricIDs.allSatisfy(validMetricIDs.contains) {
                    accepted = false
                    outcome.diagnostics.append(.numericMismatch)
                    continue
                }
                switch Self.gradeQuantitative(claim.text) {
                case .none:
                    break
                case .countWord:
                    // 「这两次」类：由引用集可复算（≥2 引用）或引用 computedFact
                    if claim.citations.count < 2 && claim.metricIDs.isEmpty {
                        accepted = false
                        outcome.diagnostics.append(.numericMismatch)
                    }
                case .explicitNumber:
                    if claim.metricIDs.isEmpty {
                        accepted = false
                        outcome.diagnostics.append(.numericMismatch)
                    }
                case .forbidden:
                    accepted = false
                    outcome.diagnostics.append(.numericMismatch)
                }
            }

            // 门禁 7：敏感不明确即拒（uncertain 不发布）
            if candidate.sensitivity != .nonSensitive {
                accepted = false
                outcome.diagnostics.append(.sensitiveInference)
            }

            // 门禁 8（前半）：用户否定指纹复查
            if negativeFingerprints.contains(DiscoveryPublicationPolicy.subjectFingerprint(of: candidate)) {
                accepted = false
                outcome.diagnostics.append(.userRejected)
            }

            if accepted {
                outcome.survivors.append(candidate)
            }
        }
        return outcome
    }

    // MARK: - 提交（检查位 4 + 发布门禁 + 落库）

    private func commitIfEligible(
        runID: String,
        freeze: DiscoveryRunFreeze,
        material: DiscoveryMaterialPackage,
        verifiedCandidates: [DiscoveryCandidate],
        counterPackages: [String: DiscoveryCounterPackage],
        mergedCounterBlocks: [DiscoveryFactAtom],
        verification: DiscoveryVerificationEnvelope,
        epoch: Int
    ) async throws {
        // 核验归属：缺结果/非 accept 的候选直接出局（02 §7）
        var acceptedCandidates: [AcceptedCandidate] = verifiedCandidates.compactMap { candidate in
            guard let result = verification.candidateResults.first(where: { $0.candidateID == candidate.candidateID })
            else { return nil }
            if result.verdict == .accept {
                return AcceptedCandidate(
                    candidate: candidate,
                    verification: result,
                    counterEvidenceCount: mergedCounterBlocks.count
                )
            }
            // 2026-11-01 部分支持修剪：核验常给「2 supported + 1 unsupported」整候选 reject
            //（真机/模拟器连续三轮实锤，用户永远等不到发现）。标题句与至少一条事实句
            // supported 时，丢弃不支持的事实句保守发布——每条展示句仍全 supported，
            // 只减信息量不降真实性；标题句不支持或事实句全灭仍整体出局。
            let verdicts = Dictionary(
                result.claimResults.map { ($0.claimID, $0.verdict) },
                uniquingKeysWith: { first, _ in first }
            )
            guard verdicts[candidate.titleClaimID] == .supported else { return nil }
            let supportedBodyIDs = candidate.bodyClaimIDs.filter { verdicts[$0] == .supported }
            guard !supportedBodyIDs.isEmpty else { return nil }
            let keptIDs = Set([candidate.titleClaimID] + supportedBodyIDs)
            let keptClaims = candidate.claims.filter { keptIDs.contains($0.claimID) }
            let keptEvidence = Set(keptClaims.flatMap { $0.citations.map(\.evidenceID) })
            let trimmed = DiscoveryCandidate(
                candidateID: candidate.candidateID,
                type: candidate.type,
                subjectKey: candidate.subjectKey,
                scopeKind: candidate.scopeKind,
                timeRange: candidate.timeRange,
                claims: keptClaims,
                titleClaimID: candidate.titleClaimID,
                bodyClaimIDs: supportedBodyIDs,
                supportEvidenceIDs: candidate.supportEvidenceIDs.filter { keptEvidence.contains($0) },
                counterSearch: candidate.counterSearch,
                sensitivity: candidate.sensitivity,
                comparisonPeriods: candidate.comparisonPeriods
            )
            Self.diagLog.notice("disp verify trim: candidate=\(candidate.candidateID) kept=\(keptClaims.count)/\(candidate.claims.count)")
            var trimmedAccepted = AcceptedCandidate(
                candidate: trimmed,
                verification: result,
                counterEvidenceCount: mergedCounterBlocks.count
            )
            trimmedAccepted.publishEligibleAfterTrim = true
            return trimmedAccepted
        }
        let digest = freeze.sourceManifestDigest
        guard !acceptedCandidates.isEmpty else {
            // 全部被核验拒绝：verify 已完成服务端 run，记成功终态（同材料不隔天重跑）
            try finishBatchNoFinding(runID: runID, digest: digest, diagnostics: [.noNontrivialObservation])
            return
        }
        // 跨入口去重（融合契约 §6 / D03）：已确认且无新信息的命题不包装成新发现；
        // 用户在任一入口暂缓的语义版本共用冷却。只读知识操作元数据，不触发模型。
        acceptedCandidates = await excludingKnowledgeDuplicates(acceptedCandidates)
        if acceptedCandidates.isEmpty {
            Self.diagLog.notice("disp publish rejected: knowledge duplicates")
        }
        guard !acceptedCandidates.isEmpty else {
            try finishBatchNoFinding(runID: runID, digest: digest, diagnostics: [.noNontrivialObservation])
            return
        }

        // 展示句全 supported（accept ⇒ 全 supported 由信封校验保证，此处复核核验结果归属完整性）
        let allSupported = acceptedCandidates.allSatisfy { accepted in
            let verdicts = Dictionary(
                accepted.verification.claimResults.map { ($0.claimID, $0.verdict) },
                uniquingKeysWith: { first, _ in first }
            )
            return accepted.candidate.claims.allSatisfy { verdicts[$0.claimID] == .supported }
        }

        // ---- 检查位 4：提交前（所有依赖源未变 + 控制一致 + 核验完整）----
        let environment = makeEnvironment(serverControlRevision: storedControlRevision)
        guard accessPolicy.canCommit(
            freeze: freeze,
            allDisplayedClaimsSupported: allSupported,
            environment: environment
        ).isAllowed else {
            try await abortInFlight(runID: runID, diagnostics: [.controlChanged])
            return
        }

        let availableEvidence = Dictionary(
            material.supportAtoms.map { ($0.evidenceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var evidenceSummaries: [String: DiscoveryEvidenceSummary] = [:]
        var negativeFingerprints = Set(sideStore.suppressedCategories)
        var recentFingerprints = Set<String>()
        if let active = (try? store.activeFinding(now: clock())) {
            recentFingerprints.insert(active.payload.fingerprintMaterial)
        }
        for accepted in acceptedCandidates {
            let candidate = accepted.candidate
            evidenceSummaries[candidate.candidateID] = Self.evidenceSummary(
                of: candidate,
                available: availableEvidence,
                calendar: calendar
            )
            let fingerprint = DiscoveryPublicationPolicy.subjectFingerprint(of: candidate)
            if (try? store.hasNegativeFeedback(fingerprintMaterial: fingerprint)) == true {
                negativeFingerprints.insert(fingerprint)
            }
        }

        let outcome = publicationPolicy.decide(DiscoveryPublicationInput(
            runID: runID,
            freezeDigest: Self.freezeDigest(of: freeze),
            acceptedCandidates: acceptedCandidates,
            counterCoverage: counterPackages.mapValues(\.coverageState),
            evidence: evidenceSummaries,
            negativeFingerprints: negativeFingerprints,
            recentSubjectFingerprints: recentFingerprints,
            now: clock()
        ))

        switch outcome {
        case .rejectAll(let rejections):
            Self.diagLog.notice("disp publish rejected: \(rejections.map { String(describing: $0.reason) })")
            let diagnostics = rejections.map { Self.diagnosticCode(for: $0.reason) }
            try finishBatchNoFinding(runID: runID, digest: digest, diagnostics: diagnostics)
        case .publish(let payload):
            // citations.sourceRef 回填真实 ref（retrievalIndex：evidenceID → 来源）
            let index = Dictionary(
                (try store.retrievalIndex(runID: runID)).map { ($0.evidenceID, $0.sourceRef) },
                uniquingKeysWith: { first, _ in first }
            )
            let backfilled = DiscoveryPublishedPayload(
                candidateID: payload.candidateID,
                type: payload.type,
                title: payload.title,
                body: payload.body,
                citations: payload.citations.map {
                    DiscoveryPublishedPayload.Citation(
                        evidenceID: $0.evidenceID,
                        quote: $0.quote,
                        sourceRef: index[$0.evidenceID]
                    )
                },
                coverageNote: payload.coverageNote,
                sensitivity: payload.sensitivity,
                timeRange: payload.timeRange,
                fingerprintMaterial: payload.fingerprintMaterial
            )
            // 依赖索引：支持来源 + 参与解释的反例（02 §9.3；sourceKind 按证据真实类型）
            let supportAtoms = acceptedCandidates.flatMap { accepted in
                Self.citedEvidenceIDs(of: accepted.candidate).compactMap { availableEvidence[$0] }
            }
            var dependencies: [DiscoveryFindingDependency] = []
            var seenRefs = Set<String>()
            for atom in supportAtoms {
                guard let ref = atom.localSourceRef, seenRefs.insert(ref.canonical).inserted else { continue }
                dependencies.append(DiscoveryFindingDependency(
                    sourceRef: ref.canonical,
                    kind: atom.sourceKind,
                    sourceRevision: atom.sourceRevision,
                    role: .support
                ))
            }
            for atom in mergedCounterBlocks {
                guard let ref = atom.localSourceRef, seenRefs.insert(ref.canonical).inserted else { continue }
                dependencies.append(DiscoveryFindingDependency(
                    sourceRef: ref.canonical,
                    kind: atom.sourceKind,
                    sourceRevision: atom.sourceRevision,
                    role: .counterExample
                ))
            }
            let resolvedDependencies = dependencies

            let publishedAt = clock()
            let findingID = try store.publishFinding(
                runID: runID,
                payload: backfilled,
                dependencies: resolvedDependencies,
                publishedAt: publishedAt,
                expiresAt: publishedAt.addingTimeInterval(14 * 24 * 3600),
                freezeDigest: Self.freezeDigest(of: freeze)
            )
            // claim → 命题/语义/证据身份的版本化关联（程序生成，不入模型 schema；可重建投影）。
            if let published = acceptedCandidates.first(where: { $0.candidate.candidateID == payload.candidateID }) {
                let package = counterPackages[published.candidate.candidateID]
                var coverageComplete = false
                if let package {
                    let searched = package.coverageState == .complete || package.coverageState == .completedNoHit
                    coverageComplete = searched && package.rejectedQueryCount == 0
                }
                let linkages = DiscoveryKnowledgeBridge.linkages(
                    findingID: findingID,
                    runID: runID,
                    candidate: published.candidate,
                    atoms: availableEvidence,
                    counterAtoms: package?.blocks ?? [],
                    counterCoverageComplete: coverageComplete,
                    now: publishedAt
                )
                try store.saveClaimLinkages(linkages)
            }
            try store.updateRunPhase(runID: runID, phase: .ready, diagnostics: [], now: publishedAt)
            sideStore.recordProcessed(
                digest: digest,
                policyVersion: versions.policyVersion,
                promptVersion: versions.candidatePromptVersion,
                at: publishedAt
            )
            consumeDirtyMarks()
            firstRunPending = false
            lastFailure = nil
            lastPhase = .ready
            findingRecentlyLost = false
            recomputePresentation()
        }
    }

    /// 成功终态收口（noFinding / 本地全拒 / 核验全拒 / 发布全拒共用）。
    private func finishBatchNoFinding(
        runID: String,
        digest: String,
        diagnostics: [DiscoveryDiagnosticReasonCode]
    ) throws {
        try store.updateRunPhase(runID: runID, phase: .noFinding, diagnostics: diagnostics, now: clock())
        sideStore.recordProcessed(
            digest: digest,
            policyVersion: versions.policyVersion,
            promptVersion: versions.candidatePromptVersion,
            at: clock()
        )
        consumeDirtyMarks()
        firstRunPending = false
        lastFailure = nil
        lastPhase = .noFinding
        findingRecentlyLost = false
        recomputePresentation()
    }

    // MARK: - 失败与退避（03 §4.4）

    private func handleStageFailure(_ error: Error, runID: String, digest: String) {
        let now = clock()
        let failure = Self.classify(error)

        switch failure {
        case .networkUnavailablePreDispatch:
            // 未 dispatch：保持 dirty，有限退避（5/15/45 阶梯），不报「生成中」
            lastFailure = failure
            if let next = schedulerCore.nextAttemptAfterFailure(failure: failure, now: now, attempt: networkRetryAttempt) {
                networkRetryAttempt += 1
                scheduleRetry(after: next.timeIntervalSince(now))
            }
            recomputePresentation()
            return
        case .budgetExceeded:
            lastFailure = failure
            dailyBatchAvailable = false
            budgetResetAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            // 窗口恢复后自动重试（2026-10-30）：此前只关当日不排重试，恢复完全依赖前台触发；
            // 若重启后 firstRunPending/marks 均空，快路径会吞掉所有触发 → 永久卡「还在等足够的记录」。
            // resetAt 为本地近似（次日零点）；月限等更长窗口醒来后仍 429 会排下一轮，自愈。
            scheduleRetry(after: budgetResetAt!.timeIntervalSince(now))
        case .schemaRejectedByModel, .semanticRejected:
            // 模型确定性拒绝 = 成功终态（03 §4.4/T20、DiscoveryProcessedRecord 文档）：
            // 记 processedRecord 后同材料同版本不再重跑（版本升级仍可受控重评估），
            // 且消费 dirty/首开标记——否则每次回前台/重启都会完整重跑一次批次，
            // 逐次烧光服务端 runsPerDay，用户永远等不到发现
            lastFailure = failure
            sideStore.recordProcessed(
                digest: digest,
                policyVersion: versions.policyVersion,
                promptVersion: versions.candidatePromptVersion,
                at: now
            )
            consumeDirtyMarks()
            firstRunPending = false
        case .stageResultLost, .upstreamErrorPostDispatch, .leaseExpired:
            // dispatch 后失败：本阶段不重复调用，终止本批（03 §4.4）。
            // 「下一资格=次日新批次」此前只写在注释里：服务端 run 已被本批消耗，
            // 若不本地关当日闸，每次回前台都会重跑完整批次，逐次烧光服务端日批次
            // 直到 429。这里与 budgetExceeded 同款关闸+排次日重试
            lastFailure = failure
            if serverOwnsRetry(after: error), registerServerRetry(now: now) {
                // 1.1.5：服务端原因失败不烧名额（S6）→ 不关当日闸，稍后新开一批。
                // 名额以服务端为准：真用完时 createRun 回 429 走 budgetExceeded 关闸；
                // 本机同日最多再试 maxServerRetriesPerDay 次兜底，不会无限重跑
                Self.diagLog.notice("disp failure: server-retryable, retry in \(Int(Self.serverRetryDelay))s (count=\(serverRetryCount))")
                scheduleRetry(after: Self.serverRetryDelay)
            } else {
                dailyBatchAvailable = false
                budgetResetAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                scheduleRetry(after: budgetResetAt!.timeIntervalSince(now))
            }
        }

        if settings.snapshot().isEnabled {
            try? store.updateRunPhase(
                runID: runID,
                phase: .backoff,
                diagnostics: [Self.diagnosticCode(forFailure: failure)],
                now: now
            )
        }
        // 除模型拒绝（已按成功终态收口）外，失败一律保持 dirty；重试节奏受日批次与有限退避约束
        lastPhase = .backoff
        recomputePresentation()
    }

    private static func classify(_ error: Error) -> DiscoveryFailureKind {
        if case DiscoveryClient.DiscoveryClientError.stageResultLost = error { return .stageResultLost }
        // 1.1.5 候选作业失败：dispatch 后失败（是否关当日闸由 serverOwnsRetry 判定）
        if case DiscoveryClient.DiscoveryClientError.candidateJobFailed = error { return .upstreamErrorPostDispatch }
        if let apiError = error as? APIError {
            switch apiError {
            case .networkUnavailable, .timeout:
                return .networkUnavailablePreDispatch
            case .rateLimited, .httpError(429, _), .backendError(429, _, _, _):
                return .budgetExceeded
            default:
                return .upstreamErrorPostDispatch
            }
        }
        if error is URLError { return .networkUnavailablePreDispatch }
        return .upstreamErrorPostDispatch
    }

    /// 同日服务端可重试次数上限（与服务端 attemptsPerDay=3 对齐：首跑 + 2 次重试）
    private static let maxServerRetriesPerDay = 2
    private static let serverRetryDelay: TimeInterval = 120

    /// dispatch 后失败由谁定「还能不能再试」：
    /// - 候选作业失败：服务端明确给出 retryAvailable；
    /// - 其余（核验/上游错误）：对端是 1.1.5 服务端（异步可用）时名额以服务端为准；
    ///   对端是老服务端（已回落同步）时保持原口径关当日闸。
    private func serverOwnsRetry(after error: Error) -> Bool {
        if case DiscoveryClient.DiscoveryClientError.candidateJobFailed(_, let retryAvailable) = error {
            return retryAvailable
        }
        return !asyncCandidatesUnsupported
    }

    private func registerServerRetry(now: Date) -> Bool {
        if let day = serverRetryDay, !calendar.isDate(day, inSameDayAs: now) {
            serverRetryCount = 0
        }
        serverRetryDay = now
        guard serverRetryCount < Self.maxServerRetriesPerDay else { return false }
        serverRetryCount += 1
        return true
    }

    private static func diagnosticCode(forFailure failure: DiscoveryFailureKind) -> DiscoveryDiagnosticReasonCode {
        switch failure {
        case .networkUnavailablePreDispatch, .budgetExceeded: return .budgetDeferred
        case .schemaRejectedByModel: return .schemaInvalid
        case .semanticRejected: return .noNontrivialObservation
        case .stageResultLost, .upstreamErrorPostDispatch: return .schemaInvalid
        case .leaseExpired: return .controlChanged
        }
    }

    private func applyDeferred(_ reason: DiscoveryDeferredReason, now: Date) {
        switch reason {
        case .silenceWindow(let remaining):
            scheduleRetry(after: remaining)
        case .networkUnavailable:
            lastFailure = .networkUnavailablePreDispatch
            if let next = schedulerCore.nextAttemptAfterFailure(failure: .networkUnavailablePreDispatch, now: now, attempt: networkRetryAttempt) {
                networkRetryAttempt += 1
                scheduleRetry(after: next.timeIntervalSince(now))
            }
        case .resourceYield, .leaseActive:
            break   // 前台激活/变更事件的轻量检查会再触发
        case .dailyBudgetExhausted(let resetAt):
            lastFailure = .budgetExceeded
            dailyBatchAvailable = false
            // 无服务端 resetAt 时保守到次日自然日（上海日界由服务端口径，本机按本地日近似）
            budgetResetAt = resetAt ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            // 窗口恢复后自动重试（与 handleStageFailure 的 budgetExceeded 同一根因，双入口都要排）
            scheduleRetry(after: max(0, budgetResetAt!.timeIntervalSince(now)))
        case .alreadyProcessedToday:
            break   // 同材料已成功终态：安静等待新材料
        }
        if lastPhase != .ready { lastPhase = .waitingForMaterial }
        recomputePresentation()
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        let epoch = settings.snapshot().localGrantEpoch
        retryTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.settings.snapshot()
            if snapshot.isEnabled, snapshot.localGrantEpoch == epoch {
                self.runBatch(reason: .retry)
            }
        }
    }

    private func refreshBudgetWindow(now: Date) {
        if !dailyBatchAvailable, let resetAt = budgetResetAt, now >= resetAt {
            dailyBatchAvailable = true
            budgetResetAt = nil
        }
    }

    private func consumeDirtyMarks() {
        dirtyMarks.removeAll()
    }

    // MARK: - 中断/撤权

    /// 控制链复核：每次跨 await 边界回来检查（T09 迟到结果永不采纳）。
    private func isControlStillValid(epoch: Int) -> Bool {
        let snapshot = settings.snapshot()
        return snapshot.isEnabled
            && snapshot.localGrantEpoch == epoch
            && consentProvider()
            && !sideStore.hasPendingDisableIntent
    }

    /// 丢弃在途结果：best effort cancel 服务端 run；本机 run 标 cancelled
    /// （disable() 路径已 clearAllForAccount，不复活行）。
    private func abortInFlight(runID: String, diagnostics: [DiscoveryDiagnosticReasonCode]) async throws {
        _ = try? await client.cancel(runID: runID, requestID: idProvider())
        if settings.snapshot().isEnabled {
            try store.updateRunPhase(runID: runID, phase: .cancelled, diagnostics: diagnostics, now: clock())
        }
        lastPhase = .waitingForMaterial
        recomputePresentation()
    }

    /// 调度 stopAndHide：立即停止并隐藏（03 §4.4「账号或控制不合法」行）。
    private func stopAndHide(_ reason: DiscoveryStopReason, runID: String?) async {
        batchTask?.cancel()
        switch reason {
        case .disabledLocally, .controlDisabled:
            if let runID, settings.snapshot().isEnabled {
                try? store.updateRunPhase(runID: runID, phase: .cancelled, diagnostics: [.controlChanged], now: clock())
            }
        case .consentWithdrawn, .scopeInvalid:
            break
        }
        recomputePresentation()
    }

    // MARK: - 反例召回（下后台）

    private func counterRecall(
        for candidates: [DiscoveryCandidate],
        supportAtoms: [DiscoveryFactAtom],
        request: DiscoveryRetriever.Request,
        environment: DiscoveryAccessSnapshot
    ) async throws -> [String: DiscoveryCounterPackage] {
        let retriever = self.retriever
        let now = clock()
        return try await Task.detached(priority: .utility) {
            var packages: [String: DiscoveryCounterPackage] = [:]
            for candidate in candidates {
                packages[candidate.candidateID] = try retriever.counterRecall(
                    candidate: candidate,
                    supportAtoms: supportAtoms,
                    request: request,
                    environment: environment,
                    now: now
                )
            }
            return packages
        }.value
    }

    // MARK: - DiscoveryService：开启/关闭

    func enable(
        selectedDomains: Set<DiscoverySourceDomain>,
        confirmTakeoverIfOwnedByOtherDevice: Bool
    ) async -> DiscoveryEnableOutcome {
        // 范围至少一类（01 §5）
        guard !selectedDomains.isEmpty else { return .noDomainSelected }

        // capability：后端不支持则开关不可完成开启
        let capabilities: DiscoveryClient.CapabilitiesResponse
        do {
            capabilities = try await client.capabilities()
            try Task.checkCancellation()
        } catch {
            return enableFailure(error, stage: "capabilities")
        }
        guard capabilities.protocolVersion == 1 else { return .failed(.incompatibleResponse) }
        guard capabilities.enabled else {
            serverCapabilitiesEnabled = false
            recomputePresentation()
            return .serverUnsupported
        }
        serverCapabilitiesEnabled = true
        versions.policyVersion = capabilities.policyVersion

        // 全局授权缺失 → 引导授权（不自动打开）
        guard consentProvider() else { return .needsGlobalConsent }

        // 离线关闭的意图必须先得到确认，不能开启成功后仍被旧关闭意图挡住。
        if sideStore.hasPendingDisableIntent {
            do {
                _ = try await client.disable(requestID: idProvider(), reason: "pending_disable_before_enable")
                sideStore.clearPendingDisableIntent()
            } catch {
                return enableFailure(error, stage: "pending-disable")
            }
        }

        // 控制快照：他设备占用需用户确认接管（V1 单设备租约）
        let control: DiscoveryClient.ControlResponse
        do {
            control = try await client.control()
            try Task.checkCancellation()
        } catch {
            return enableFailure(error, stage: "control")
        }
        let myDevice = deviceIdProvider()
        let ownedByOther = control.enabled && control.ownerDeviceId != nil && control.ownerDeviceId != myDevice
        if ownedByOther && !confirmTakeoverIfOwnedByOtherDevice, let owner = control.ownerDeviceId {
            return .needsTakeoverConfirmation(ownerDeviceID: owner)
        }

        var serverEnabled = false
        do {
            let response = try await client.enable(
                expectedRevision: control.revision,
                allowedDomains: selectedDomains.map(\.rawValue).sorted(),
                consentDocVersion: control.consentDocVersion ?? "discovery-consent-v1",
                confirmTakeover: ownedByOther,
                requestID: idProvider()
            )
            guard response.enabled else { return .failed(.serverUnavailable) }
            serverEnabled = true
            try Task.checkCancellation()
            // 先完成可能失败的本机持久化，再发布开启状态，避免 UI 报失败却实际开启。
            try store.upsertControlSnapshot(DiscoveryControlSnapshotRecord(
                revision: response.revision,
                payloadJSON: "{\"revision\":\(response.revision),\"enabled\":true}",
                digest: DiscoveryContentDigest.sourceRevision(from: ["discovery.control.v1", String(response.revision), "true"]),
                fetchedAt: clock()
            ))
            guard consentProvider() else {
                await rollbackEnable()
                return .needsGlobalConsent
            }
            try settings.enable(domains: selectedDomains)
            firstRunPending = true   // 受限历史准备（不等待新增记录）
            recomputePresentation()
            runBatch(reason: .enableFirstRun)
            return .enabled
        } catch {
            if serverEnabled {
                await rollbackEnable()
                if error is CancellationError { return .cancelled }
                _ = enableFailure(error, stage: "local-save")
                return .failed(.localSave)
            }
            return enableFailure(error, stage: "enable")
        }
    }

    private func enableFailure(_ error: Error, stage: String) -> DiscoveryEnableOutcome {
        if error is CancellationError { return .cancelled }
        let apiError = error as? APIError
        Logger(subsystem: "com.holo.app", category: "Discovery").error(
            "发现开启失败 stage=\(stage) category=\(apiError?.diagnosticCategory ?? String(describing: type(of: error))) requestID=\(apiError?.requestId ?? "none")")
        return .failed(DiscoveryEnableFailure.from(error))
    }

    private func rollbackEnable() async {
        settings.disable()
        do {
            _ = try await client.disable(requestID: idProvider(), reason: "enable_not_committed")
            sideStore.clearPendingDisableIntent()
        } catch {
            sideStore.setPendingDisableIntent()
        }
        recomputePresentation()
    }

    func disable() async {
        guard settings.snapshot().isEnabled || sideStore.hasPendingDisableIntent else { return }

        // 本机先关：开关 → 隐藏 → 取消任务 → 删派生数据（保留否定指纹，02 §9.3）
        settings.disable()
        batchTask?.cancel()
        batchGeneration += 1   // 旧任务收尾不再清在途标志
        isBatchRunning = false   // 重开后可立即排首跑
        retryTask?.cancel()
        currentFinding = nil
        isDetailPresented = false
        pendingJobStore.clear()   // 1.1.5：取件缓存属派生数据，关闭即删
        do {
            try store.clearAllForAccount(now: clock())
        } catch {
            assertionFailure("Discovery 派生数据清理失败：\(error)")
        }
        recomputePresentation()

        // 服务端禁用；离线保留待提交意图，确认前不再发材料
        do {
            _ = try await client.disable(requestID: idProvider(), reason: "user_disable")
            sideStore.clearPendingDisableIntent()
        } catch {
            sideStore.setPendingDisableIntent()
        }
    }

    // MARK: - DiscoveryService：展示与反馈

    func openFinding() -> DiscoveryFindingPresentation? {
        guard let record = readableFinding(now: clock()) else {
            currentFinding = nil
            recomputePresentation()
            return nil
        }
        if record.status == .published {
            try? store.markFinding(id: record.id, status: .viewed, now: clock())
        }
        isDetailPresented = true
        let presentation = Self.makePresentation(from: record, viewed: true, calendar: calendar)
        currentFinding = presentation
        recomputePresentation()
        return presentation
    }

    func submitFeedback(_ action: DiscoveryFeedbackAction) async {
        switch action {
        case .accurate:
            // 轻反馈：只作为该有限观察的就地回执，写共同提示记录（acknowledged）；
            // 不新增确认、独立证据、置信度或自动保存资格（融合契约 §5）。
            await recordKnowledgePrompt(outcome: "acknowledged")
            return
        case .manageDismiss:
            isDetailPresented = false
            recomputePresentation()
            return
        case .inaccurate(let reason):
            // 先撤下，再记最小否定（点击后无需等联网）；首次点击立即生效
            guard let record = readableFinding(now: clock()) else { return }
            let material = record.payload.fingerprintMaterial
            // 幂等：先查再写（连续点击不重复写入）
            if (try? store.hasNegativeFeedback(fingerprintMaterial: material)) != true {
                try? store.recordNegativeFeedback(fingerprintMaterial: material, now: clock())
            }
            try? store.markFinding(id: record.id, status: .rejected, now: clock())
            switch reason {
            case .notInterested:
                // 展示偏好：停止该范围的主动呈现；不是事实否定、不判假整个主题（D06）。
                sideStore.addSuppressedCategory(material)
            case .wrongEvidence, .wrongUnderstanding, .notApplicableNow:
                // 事实控制：作用于两侧准确关联内容（发现撤下 + 知识操作），不整主题封禁。
                await applyKnowledgeFeedback(reason: reason, findingRecord: record)
            }
            currentFinding = nil
            isDetailPresented = false
            recomputePresentation()
        }
    }

    /// 「不太准确」三种子作用域 → 统一知识操作（融合契约 §5 表）。
    private func applyKnowledgeFeedback(
        reason: DiscoveryInaccurateReason,
        findingRecord: DiscoveryPublishedFindingRecord
    ) async {
        guard let repository = await knowledgeRepository(),
              let linkages = try? store.claimLinkages(findingID: findingRecord.id),
              !linkages.isEmpty else { return }
        let now = clock()
        let scope: HoloKnowledgeInaccurateScope
        switch reason {
        case .wrongEvidence: scope = .evidence
        case .wrongUnderstanding: scope = .understanding
        case .notApplicableNow: scope = .applicability
        case .notInterested: return
        }
        let control = HoloKnowledgeControlService(repository: repository)
        for linkage in linkages {
            // notApplicableNow → 收窄当前有效范围，保留历史（不假定以前从未发生）。
            let action: HoloKnowledgeControlAction = (reason == .notApplicableNow)
                ? .narrowScope(validTo: now)
                : .markInaccurate(reason: nil, scope: scope)
            let request = HoloKnowledgeControlRequest(
                operationID: "disc-fb-\(linkage.propositionID)-\(linkage.semanticDigest)-\(reason.rawValue)",
                propositionID: linkage.propositionID,
                expectedSemanticDigest: linkage.semanticDigest,
                knownOperationIDs: [],
                action: action,
                entry: DiscoveryKnowledgeBridge.originEntry,
                issuedAt: now
            )
            _ = try? await control.apply(request)
        }
    }

    /// 共同提示记录（轻反馈/暂缓）：避免同版本跨入口重复询问。
    private func recordKnowledgePrompt(outcome: String) async {
        guard let repository = await knowledgeRepository(),
              let record = readableFinding(now: clock()),
              let linkages = try? store.claimLinkages(findingID: record.id) else { return }
        let now = clock()
        let operations = linkages.map { linkage in
            HoloKnowledgeOperation(
                operationID: "disc-prompt-\(linkage.propositionID)-\(linkage.semanticDigest)-\(outcome)-\(Int(now.timeIntervalSince1970 / 86_400))",
                kind: .promptRecord,
                propositionID: linkage.propositionID,
                targetSemanticDigest: linkage.semanticDigest,
                controlGeneration: 0,
                payload: .promptRecord(
                    entry: DiscoveryKnowledgeBridge.originEntry,
                    semanticDigest: linkage.semanticDigest,
                    outcome: outcome
                ),
                partition: .normal,
                issuedAt: now
            )
        }
        try? await repository.saveKnowledgeRevisionAndOperation(revision: nil, operations: operations)
    }

    // MARK: - DiscoveryService：确认并记住（融合契约 §4）

    func knowledgeSaveState(for findingID: String) async -> DiscoveryKnowledgeSaveState {
        guard let record = readableFinding(now: clock()),
              record.id.uuidString == findingID else {
            return .unavailable(reason: "findingGone")
        }
        guard let repository = await knowledgeRepository(),
              let linkages = try? store.claimLinkages(findingID: record.id) else {
            return .notEligible
        }
        for linkage in linkages
        where await Self.hasStandaloneBlock(repository: repository, propositionID: linkage.propositionID, digest: linkage.semanticDigest, now: clock()) {
            return .unavailable(reason: "restricted")
        }
        guard let eligibleLinkage = await eligibleKnowledgeLinkage(linkages: linkages, repository: repository) else {
            return .notEligible
        }
        // 已确认且无新信息：两处显示同一已记住状态（D02/D03）。
        // 2026-10-31 审计 E4：inactive 不并入「已记住」——已确认后被停用/否定/遗忘的命题
        // 必须落到下方 restricted 分支，否则发现详情对被用户限制的理解仍显示「已记住」。
        if let resolved = try? await repository.resolvedKnowledge(propositionID: eligibleLinkage.propositionID, now: clock()),
           resolved.confirmedSemanticDigest == eligibleLinkage.semanticDigest,
           resolved.decision.isUsableForAnswering {
            let answeringEnabled = ((try? await repository.loadControlState())?.memoryAssistedAnsweringEnabled) ?? false
            return .remembered(
                propositionID: eligibleLinkage.propositionID,
                answeringEnabled: answeringEnabled
            )
        }
        if let resolved = try? await repository.resolvedKnowledge(propositionID: eligibleLinkage.propositionID, now: clock()),
           resolved.decision == .inactive,
           !resolved.restrictingOperationIDs.isEmpty {
            return .unavailable(reason: "restricted")
        }
        return .eligible(
            claimID: eligibleLinkage.claimID,
            preview: eligibleLinkage.semantic.displayText,
            usesDescription: "用于相关帮助；实际使用遵守记忆辅助回答开关"
        )
    }

    /// claim 级成熟度：跨发现批次聚合同一命题的证据后按统一准入判定（D15 共用事实）。
    private func eligibleKnowledgeLinkage(
        linkages: [DiscoveryClaimLinkage],
        repository: CoreDataHoloMemoryRepository
    ) async -> DiscoveryClaimLinkage? {
        let now = clock()
        for linkage in linkages where linkage.semantic.evidenceForm != .explicitSemanticFact {
            // 跨批次证据聚合：同命题全部关联的独立事件并集（同一血缘只计一次）。
            var allLinkages = [linkage]
            if let historical = try? store.claimLinkages(propositionID: linkage.propositionID) {
                allLinkages.append(contentsOf: historical)
            }
            var support = linkage.evidenceSnapshot.supportRefs
            var lineages = Set(support.map(\.lineageKey))
            var dates = support.map(\.observedAt)
            for other in allLinkages {
                for ref in other.evidenceSnapshot.supportRefs where !lineages.contains(ref.lineageKey) {
                    lineages.insert(ref.lineageKey)
                    support.append(ref)
                    dates.append(ref.observedAt)
                }
            }
            // 反例检索状态聚合（2026-10-31 审计 E1）：三态如实合并——
            // 任一批 searchedFound → found；否则全部批次都查过无反例才可写 searchedNoneFound；
            // 有批次未查且未发现 → notSearched（「未查明」不冒充「查过没有」，09-R12 同则），
            // 否则 notSearched 的批次攒够支持证据就能绕过 requiresCounterexampleSearch 门槛。
            let counterStatuses = allLinkages.map(\.evidenceSnapshot.counterexampleSearch)
            let aggregatedCounterStatus: HoloKnowledgeCounterexampleSearchStatus
            if counterStatuses.contains(.searchedFound) {
                aggregatedCounterStatus = .searchedFound
            } else if counterStatuses.allSatisfy({ $0 == .searchedNoneFound }) {
                aggregatedCounterStatus = .searchedNoneFound
            } else {
                aggregatedCounterStatus = .notSearched
            }
            // 历史批次的反例引用并入聚合快照（此前只保留当前批次，历史反例会丢）
            var counters = linkage.evidenceSnapshot.counterRefs
            var counterKeys = Set(counters.map(\.lineageKey))
            for other in allLinkages {
                for ref in other.evidenceSnapshot.counterRefs where !counterKeys.contains(ref.lineageKey) {
                    counterKeys.insert(ref.lineageKey)
                    counters.append(ref)
                }
            }
            let templateID = linkage.evidenceSnapshot.templateID
            let evidence = HoloKnowledgeEvidenceSnapshot(
                supportRefs: support,
                counterRefs: counters,
                observationWindowFrom: dates.min(),
                observationWindowTo: dates.max(),
                independentEventCount: lineages.count,
                coveragePercent: DiscoveryKnowledgeBridge.weeklyCoverage(of: dates),
                counterexampleSearch: aggregatedCounterStatus,
                templateID: templateID,
                statsSummary: linkage.evidenceSnapshot.statsSummary,
                sourceRevisions: linkage.evidenceSnapshot.sourceRevisions,
                holdoutValidatedPeriods: linkage.evidenceSnapshot.holdoutValidatedPeriods,
                capturedAt: now
            )
            let verdict = HoloKnowledgeAdmission.assess(
                semantic: linkage.semantic,
                evidence: evidence,
                authorizedSourceDomains: DiscoveryKnowledgeBridge.discoveryAuthorizedDomains
            )
            switch verdict {
            case .worthConfirming, .remembered:
                return linkage
            case .reject, .internalOnly:
                continue
            }
        }
        return nil
    }

    func confirmAndRemember(findingID: String, claimID: String) async -> DiscoveryKnowledgeSaveOutcome {
        guard let record = readableFinding(now: clock()),
              record.id.uuidString == findingID,
              let linkage = (try? store.claimLinkages(findingID: record.id))?
                  .first(where: { $0.claimID == claimID }) else {
            return .failed(description: "findingGone")
        }
        guard let repository = await knowledgeRepository() else {
            return .failed(description: "knowledgeUnavailable")
        }
        let now = clock()
        // 保存前重核：来源仍有效（依赖索引回源核验同通道）。
        if await continuationBuilder.validateForSend(findingID: findingID) == false {
            return .conflict(reason: "sourceChanged")
        }
        do {
            let revision = DiscoveryKnowledgeBridge.revision(from: linkage, now: now)
            try await repository.saveKnowledgeRevisionAndOperation(revision: revision, operations: [])
            let control = HoloKnowledgeControlService(repository: repository)
            let outcome = try await control.apply(HoloKnowledgeControlRequest(
                operationID: "disc-save-\(linkage.propositionID)-\(linkage.semanticDigest)",
                propositionID: linkage.propositionID,
                expectedSemanticDigest: linkage.semanticDigest,
                knownOperationIDs: [],
                action: .confirm,
                entry: DiscoveryKnowledgeBridge.originEntry,
                issuedAt: now
            ))
            switch outcome {
            case .applied(let propositionID, _):
                return .saved(propositionID: propositionID)
            case .alreadyApplied:
                return .alreadySaved(propositionID: linkage.propositionID)
            case .conflict(_, let reason):
                return .conflict(reason: reason)
            case .notFound:
                return .failed(description: "notFound")
            case .notAllowed(let reason):
                return .conflict(reason: reason)
            case .persistenceFailed(let description):
                return .failed(description: description)
            }
        } catch {
            return .failed(description: String(describing: error))
        }
    }

    /// 「暂时不说」：最低限度的不打扰记录（不构成认可/否定；冷却共用）。
    func recordMinimalDeference(findingID: String) async {
        guard let record = readableFinding(now: clock()),
              record.id.uuidString == findingID,
              let repository = await knowledgeRepository(),
              let linkages = try? store.claimLinkages(findingID: record.id),
              !linkages.isEmpty else { return }
        let now = clock()
        let control = HoloKnowledgeControlService(repository: repository)
        for linkage in linkages {
            _ = try? await control.apply(HoloKnowledgeControlRequest(
                operationID: "disc-defer-\(linkage.propositionID)-\(linkage.semanticDigest)",
                propositionID: linkage.propositionID,
                expectedSemanticDigest: linkage.semanticDigest,
                knownOperationIDs: [],
                action: .deferCooldown,
                entry: DiscoveryKnowledgeBridge.originEntry,
                issuedAt: now
            ))
        }
        isDetailPresented = false
        recomputePresentation()
    }

    // MARK: 记忆控制 → 发现侧撤下（融合契约 §5/§7；D04/D18）

    @objc private func handleKnowledgeControl(_ note: Notification) {
        guard let propositionID = note.userInfo?["propositionID"] as? String,
              let kindRaw = note.userInfo?["kind"] as? String,
              let kind = HoloKnowledgeOperationKind(rawValue: kindRaw),
              kind.isUsageRestricting else { return }
        Task { @MainActor in
            self.withdrawFindingsLinked(toPropositionIDs: [propositionID])
        }
    }

    private func withdrawFindingsLinked(toPropositionIDs propositionIDs: Set<String>) {
        let now = clock()
        guard let hitIDs = try? store.activeFindingIDs(linkedToPropositionIDs: propositionIDs, now: now),
              !hitIDs.isEmpty else { return }
        for id in hitIDs {
            try? store.invalidateFinding(id: id, now: now)
        }
        if let active = currentFinding,
           let activeID = UUID(uuidString: active.findingID),
           hitIDs.contains(activeID) {
            currentFinding = nil
        }
        recomputePresentation()
    }

    private func knowledgeRepository() async -> CoreDataHoloMemoryRepository? {
        guard let provider = knowledgeRepositoryProvider else { return nil }
        return try? await provider()
    }

    /// 无修订命题上的独立限制（不准确/收窄）或生效中的暂缓冷却。
    static func hasStandaloneBlock(
        repository: CoreDataHoloMemoryRepository,
        propositionID: String,
        digest: String,
        now: Date
    ) async -> Bool {
        guard let snapshot = try? await repository.knowledgeStoreSnapshot(propositionID: propositionID),
              snapshot.revisions.isEmpty else { return false }
        for operation in snapshot.operations {
            switch operation.kind {
            case .markInaccurate, .narrowScope:
                if operation.targetSemanticDigest == nil || operation.targetSemanticDigest == digest { return true }
            case .deferCooldown:
                if case .cooldown(let until) = operation.payload, until > now,
                   operation.targetSemanticDigest == nil || operation.targetSemanticDigest == digest {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    /// 已确认同语义（无新信息）或处于暂缓冷却的候选不再作为「新发现」呈现。
    private func excludingKnowledgeDuplicates(_ candidates: [AcceptedCandidate]) async -> [AcceptedCandidate] {
        guard let repository = await knowledgeRepository() else { return candidates }
        let now = clock()
        var survivors: [AcceptedCandidate] = []
        for accepted in candidates {
            var duplicate = false
            for claim in accepted.candidate.claims {
                let semantic = DiscoveryKnowledgeBridge.semantic(for: claim, candidate: accepted.candidate)
                let propositionID = HoloKnowledgeIdentity.propositionID(for: semantic)
                // 未保存 claim 的独立限制/暂缓（无修订，resolve 为 nil）：按操作元数据判定（D05/D18）
                if await Self.hasStandaloneBlock(repository: repository, propositionID: propositionID, digest: semantic.semanticDigest, now: now) {
                    duplicate = true
                    break
                }
                guard let resolved = try? await repository.resolvedKnowledge(propositionID: propositionID, now: now) else { continue }
                if resolved.confirmedSemanticDigest == semantic.semanticDigest {
                    duplicate = true
                    break
                }
                if let cooldown = resolved.cooldownUntil, cooldown > now,
                   resolved.proposedRevision?.semanticDigest == semantic.semanticDigest
                    || resolved.currentRevision?.semanticDigest == semantic.semanticDigest {
                    duplicate = true
                    break
                }
                // 记忆侧已否定/遗忘该语义：不得换入口再次推荐（D18）。
                if resolved.decision == .inactive, !resolved.restrictingOperationIDs.isEmpty {
                    duplicate = true
                    break
                }
            }
            if !duplicate { survivors.append(accepted) }
        }
        return survivors
    }

    func buildConversationDraft() -> DiscoveryConversationDraft? {
        guard let finding = currentFinding
            ?? Self.presentationIfLoaded(now: clock(), store: store, calendar: calendar)
        else { return nil }
        return continuationBuilder.buildDraft(
            from: finding,
            allowedDomains: settings.snapshot().allowedDomains
        )
    }

    /// 发送前来源重核（检查位 6）：聊天发送路径在发出前调用。
    func validateConversationDraftForSend(findingID: String) async -> Bool {
        await continuationBuilder.validateForSend(findingID: findingID)
    }

    func resetFeedbackSuppression() async {
        do {
            try store.resetNegativeFeedback()
        } catch {
            assertionFailure("Discovery 反馈重置失败：\(error)")
        }
        sideStore.clearSuppressedCategories()
        recomputePresentation()
    }

    // MARK: - DiscoveryService：刷新

    func refresh() async {
        // 离线撤权意图优先补交；确认前不发材料
        if sideStore.hasPendingDisableIntent {
            if (try? await client.disable(requestID: idProvider(), reason: "user_disable")) != nil {
                sideStore.clearPendingDisableIntent()
            }
            recomputePresentation()
            return
        }
        guard settings.snapshot().isEnabled else {
            recomputePresentation()
            return
        }
        await refreshControlSnapshot()
        recomputePresentation()
        // 前台激活只做轻量检查并安排 utility 任务（03 §4.3；完整资格由 decide 判定）
        let check = environmentProvider.foregroundCheck()
        Self.diagLog.notice("disp refresh: check=\(String(describing: check))")
        if check == .scheduleUtilityCheck {
            runBatch(reason: .refresh)
        } else {
            // 冷启动竞态兜底（2026-11-01）：NWPathMonitor 首个 path 更新可迟到至秒级，
            // 启动瞬间的 refresh 会 skip 且不排任何后续 → 批次静默丢失（真机三轮实测两轮撞上）。
            // skip 一律 30 秒后补查（幂等：届时在跑则 runBatch 自守卫；让位类原因届时重判）。
            scheduleRetry(after: 30)
        }
    }

    private func refreshControlSnapshot() async {
        guard let control = try? await client.control() else { return }
        let now = clock()
        let snapshot = DiscoveryControlSnapshotRecord(
            revision: control.revision,
            payloadJSON: "{\"revision\":\(control.revision),\"enabled\":\(control.enabled)}",
            digest: DiscoveryContentDigest.sourceRevision(from: ["discovery.control.v1", String(control.revision), String(control.enabled)]),
            fetchedAt: now
        )
        try? store.upsertControlSnapshot(snapshot)
        if !control.enabled {
            // 服务端已禁用（他机关闭/后台停用）：本机同步关闭并清派生数据
            settings.disable()
            batchTask?.cancel()
            batchGeneration += 1
            isBatchRunning = false
            currentFinding = nil
            isDetailPresented = false
            pendingJobStore.clear()
            try? store.clearAllForAccount(now: now)
            return
        }
        // 范围以服务端为准（用户在他机确认过的调整；本机不自行扩大）
        let serverDomains = Set(control.allowedDomains.compactMap { DiscoverySourceDomain(rawValue: $0) })
        if !serverDomains.isEmpty, serverDomains != settings.snapshot().allowedDomains {
            try? settings.updateAllowedDomains(serverDomains)
        }
    }

    // MARK: - 状态映射（01 §1 九行状态表）

    private func recomputePresentation() {
        let now = clock()

        guard serverCapabilitiesEnabled else {
            presentationState = .serverUnsupported
            settingsDetailState = .serverUnsupported
            return
        }
        if sideStore.hasPendingDisableIntent {
            presentationState = .disabled
            settingsDetailState = .disabled
            return
        }
        let snapshot = settings.snapshot()
        guard snapshot.isEnabled else {
            presentationState = .disabled
            settingsDetailState = .disabled
            currentFinding = nil
            isDetailPresented = false
            findingRecentlyLost = false
            return
        }
        guard consentProvider() else {
            // 撤权：立即撤下并终止详情阅读
            presentationState = .disabled
            settingsDetailState = .revoked
            currentFinding = nil
            isDetailPresented = false
            return
        }

        // 有效发现（published/viewed 且未过期；过期在 activeFinding 处即撤）
        if let record = readableFinding(now: now) {
            let viewed = record.status == .viewed
            presentationState = .available(findingID: record.id.uuidString, viewed: viewed)
            settingsDetailState = .hasFinding(viewed: viewed)
            findingRecentlyLost = false
            // 详情打开期间不被新结果替换；退出后才切换（01 §1）
            if !isDetailPresented || currentFinding == nil {
                currentFinding = Self.makePresentation(from: record, viewed: viewed, calendar: calendar)
            }
            return
        }
        if lastPhase == .ready {
            // published 后又不可读（否定/失效/过期）→ 等待新的线索（设置页 stale 文案）
            findingRecentlyLost = true
        }
        currentFinding = nil

        // 网络失败/预算不足：旧内容可读否则无胶囊；设置页不催用户重试
        if let failure = lastFailure {
            switch failure {
            case .networkUnavailablePreDispatch, .budgetExceeded, .upstreamErrorPostDispatch, .stageResultLost:
                presentationState = .temporarilyUnavailable
                settingsDetailState = .pausedTemporarily
                return
            default:
                break
            }
        }

        switch lastPhase {
        case .preparing, .scheduled:
            presentationState = .preparing
            settingsDetailState = .preparing
        case .ready, .noFinding, .waitingForMaterial, .backoff, .cancelled:
            presentationState = .waitingForMaterial
            settingsDetailState = findingRecentlyLost ? .stale : .waitingForMaterial
        }
    }

    /// 展示前检查（检查位 5）：canDisplay 门控 + 否定命中不展示。
    private func readableFinding(now: Date) -> DiscoveryPublishedFindingRecord? {
        guard let record = (try? store.activeFinding(now: now)) else { return nil }
        let negated = (try? store.hasNegativeFeedback(fingerprintMaterial: record.payload.fingerprintMaterial)) ?? true
        let environment = makeEnvironment(serverControlRevision: storedControlRevision)
        let displayState = DiscoveryFindingDisplayState(
            status: record.status,
            expiresAt: record.expiresAt,
            subjectNegativeFeedbackHit: negated,
            dependenciesValid: true   // 依赖失效由 InvalidationService 即时改状态，此处不再重复查
        )
        guard accessPolicy.canDisplay(finding: displayState, environment: environment).isAllowed else {
            return nil
        }
        return record
    }

    private func makeEnvironment(serverControlRevision: Int?) -> DiscoveryAccessSnapshot {
        DiscoveryAccessSnapshot(
            now: clock(),
            isGlobalConsentGranted: consentProvider(),
            settings: settings.snapshot(),
            serverControlRevision: serverControlRevision,
            dailyAutoBatchBudgetRemaining: dailyBatchAvailable ? 1 : 0
        )
    }

    private var storedControlRevision: Int? {
        if let record = (try? store.latestControlSnapshot()) {
            return record.revision
        }
        return nil
    }

    // MARK: - 展示映射

    private static func presentationIfLoaded(
        now: Date,
        store: DiscoveryStore,
        calendar: Calendar
    ) -> DiscoveryFindingPresentation? {
        guard let record = (try? store.activeFinding(now: now)) else { return nil }
        return makePresentation(from: record, viewed: record.status == .viewed, calendar: calendar)
    }

    private static func makePresentation(
        from record: DiscoveryPublishedFindingRecord,
        viewed: Bool,
        calendar: Calendar
    ) -> DiscoveryFindingPresentation {
        let payload = record.payload
        var quotes: [String: String] = [:]
        for citation in payload.citations where quotes[citation.evidenceID] == nil {
            quotes[citation.evidenceID] = citation.quote
        }
        let joinedBody = payload.body.joined(separator: "")
        return DiscoveryFindingPresentation(
            findingID: record.id.uuidString,
            title: payload.title,
            body: payload.body,
            citations: payload.citations,
            displayQuotes: quotes,
            coverageNote: payload.coverageNote,
            timeRangeText: Self.timeRangeText(payload.timeRange, calendar: calendar),
            publishedAt: record.publishedAt,
            expiresAt: record.expiresAt,
            viewed: viewed,
            // 存在改变解释的反例时正文必须体现边界（01 §2）；
            // V1 以反例信号词近似判定（正文由已核验 claim 原样组装，边界词未被裁剪）
            hasCounterEvidenceNote: DiscoveryRetriever.counterSignalLexicon.contains { joinedBody.contains($0) }
        )
    }

    private static func timeRangeText(_ range: DiscoveryTimeRange, calendar: Calendar) -> String {
        func text(_ raw: String?) -> String {
            guard let raw, let date = DiscoveryISO8601.parse(raw) else { return "记录时间" }
            let components = calendar.dateComponents([.month, .day], from: date)
            return "\(components.month ?? 0)月\(components.day ?? 0)日"
        }
        switch (range.start != nil, range.end != nil) {
        case (true, true):
            return "\(text(range.start)) 至 \(text(range.end))"
        case (true, false):
            return "\(text(range.start)) 起"
        case (false, true):
            return "截至 \(text(range.end))"
        case (false, false):
            return "记录时间范围内"
        }
    }

    // MARK: - 数据组装（05 §2.1；data 会被服务端 JSON.stringify 直接作为 user 内容）

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func candidateRequestData(
        freeze: DiscoveryRunFreeze,
        material: DiscoveryMaterialPackage,
        allowedDomains: Set<DiscoverySourceDomain>,
        iso: (Date) -> String
    ) -> DiscoveryJSONValue {
        let byID = Dictionary(material.supportAtoms.map { ($0.evidenceID, $0) }, uniquingKeysWith: { first, _ in first })
        let evidence = material.generationEvidenceIDs.compactMap { byID[$0] }.map { Self.evidenceObject($0, iso: iso) }
        return .object([
            ("schemaVersion", .number(.int(1))),
            ("runID", .string(freeze.runID)),
            ("anchorNow", .string(iso(freeze.anchorNow))),
            ("timezone", .string(freeze.timezone)),
            ("allowedDomains", .array(allowedDomains.map(\.rawValue).sorted().map { .string($0) })),
            ("evidence", .array(evidence)),
            ("coverage", coverageObject(material.coverage, iso: iso)),
            ("computedFacts", .array(material.supportAtoms.flatMap { $0.computedFacts }.map { Self.computedFactObject($0, iso: iso) })),
            ("allowedTypes", .array(DiscoveryCandidateType.allCases.map { .string($0.rawValue) })),
            ("blockedThemes", .array([])),   // 已展示主题的非敏感指纹约束（V1 无历史发现时为空）
        ])
    }

    private static func verifyRequestData(
        freeze: DiscoveryRunFreeze,
        material: DiscoveryMaterialPackage,
        counter: DiscoveryCounterPackage,
        perCandidateCoverage: [String: DiscoveryCounterCoverageState],
        allowedDomains: Set<DiscoverySourceDomain>,
        iso: (Date) -> String
    ) -> DiscoveryJSONValue {
        // 核验看完整支持块 + 反例与相邻上下文（02 §7）：全部支持块（含超出生成切片的部分）+ 合并反例块
        let evidence = (material.supportAtoms + counter.blocks).map { Self.evidenceObject($0, iso: iso) }
        let counterCoverage = Dictionary(
            perCandidateCoverage.map { key, value in
                (key, DiscoveryJSONValue.object([
                    ("state", .string(value.rawValue)),
                    ("rejectedQueryCount", .number(.int(0))),
                    ("neutralLookbackExecuted", .bool(counter.neutralLookbackExecuted)),
                ]))
            },
            uniquingKeysWith: { first, _ in first }
        )
        return .object([
            ("schemaVersion", .number(.int(1))),
            ("anchorNow", .string(iso(freeze.anchorNow))),
            ("timezone", .string(freeze.timezone)),
            ("allowedDomains", .array(allowedDomains.map(\.rawValue).sorted().map { .string($0) })),
            ("evidence", .array(evidence)),
            ("coverage", coverageObject(material.coverage, iso: iso)),
            ("computedFacts", .array(material.supportAtoms.flatMap { $0.computedFacts }.map { Self.computedFactObject($0, iso: iso) })),
            ("counterCoverage", .object(counterCoverage.sorted { $0.key < $1.key }.map { $0 })),
            ("sourceLimits", .array([
                .string("定量结论只能引用 computedFact"),
                .string("第一版不允许百分比/相关系数类句子"),
            ])),
        ])
    }

    private static func evidenceObject(_ atom: DiscoveryFactAtom, iso: (Date) -> String) -> DiscoveryJSONValue {
        func optionalDate(_ date: Date?) -> DiscoveryJSONValue {
            date.map { .string(iso($0)) } ?? .null
        }
        let lineage: DiscoveryJSONValue
        switch atom.lineageGroup {
        case .group(let label): lineage = .string(label)
        case .ambiguous: lineage = .string("ambiguous")
        }
        return .object([
            ("evidenceID", .string(atom.evidenceID)),
            ("sourceKind", .string(atom.sourceKind.rawValue)),
            ("sourceBlock", .string(atom.sourceBlock)),
            ("occurredRange", .object([
                ("start", optionalDate(atom.occurredRange.start)),
                ("end", optionalDate(atom.occurredRange.end)),
                ("precision", .string(atom.occurredRange.precision.rawValue)),
            ])),
            ("recordedAt", .string(iso(atom.recordedAt))),
            ("lineageGroup", lineage),
            ("entityRefs", .array(atom.entityRefs.map { .string($0) })),
        ])
    }

    private static func coverageObject(_ coverage: DiscoveryFactAtom.Coverage, iso: (Date) -> String) -> DiscoveryJSONValue {
        func optionalDate(_ date: Date?) -> DiscoveryJSONValue {
            date.map { .string(iso($0)) } ?? .null
        }
        var limitations: [DiscoveryJSONValue] = [.string("只覆盖已有记录")]
        if !coverage.denominatorKnown {
            limitations.append(.string("习惯域缺记录不等于没有发生"))
        }
        if coverage.truncatedCount > 0 {
            limitations.append(.string("部分材料因预算截断未纳入"))
        }
        return .object([
            ("domains", .array(coverage.domains.map(\.rawValue).sorted().map { .string($0) })),
            ("windowStart", optionalDate(coverage.windowStart)),
            ("windowEnd", optionalDate(coverage.windowEnd)),
            ("matchedCount", .number(.int(Int64(coverage.matchedCount)))),
            ("usedCount", .number(.int(Int64(coverage.usedCount)))),
            ("truncatedCount", .number(.int(Int64(coverage.truncatedCount)))),
            ("denominatorKnown", .bool(coverage.denominatorKnown)),
            ("truncated", .bool(coverage.truncatedCount > 0)),
            ("limitations", .array(limitations)),
        ])
    }

    private static func computedFactObject(_ fact: DiscoveryFactAtom.ComputedFact, iso: (Date) -> String) -> DiscoveryJSONValue {
        func optionalNumber(_ value: Double?) -> DiscoveryJSONValue {
            value.map { .number(.double($0)) } ?? .null
        }
        func optionalDate(_ date: Date?) -> DiscoveryJSONValue {
            date.map { .string(iso($0)) } ?? .null
        }
        return .object([
            ("metricID", .string(fact.metricID)),
            ("formulaVersion", .string(fact.formulaVersion)),
            ("numerator", optionalNumber(fact.numerator)),
            ("denominator", optionalNumber(fact.denominator)),
            ("unit", fact.unit.map { .string($0) } ?? .null),
            ("windowStart", optionalDate(fact.windowStart)),
            ("windowEnd", optionalDate(fact.windowEnd)),
            ("value", .number(.double(fact.value))),
        ])
    }

    /// 阶段一响应 envelope 的 candidates 原样数组（字节级回显给 verify，hash 对齐 T34）。
    private static func candidatesArray(from envelope: DiscoveryJSONValue) -> DiscoveryJSONValue? {
        guard case .object(let pairs) = envelope,
              let candidates = pairs.first(where: { $0.0 == "candidates" })?.1,
              case .array = candidates
        else { return nil }
        return candidates
    }

    // MARK: - 证据口径工具

    /// 授权域有界窗口扫描（回源核权谓词已含在适配器 basePredicate 内）。
    /// V1 的「受限历史准备」与 dirty 触发共用该扫描作为变化对象来源
    ///（DiscoveryDirtyMark 尚不携带记录 refs；G2 变更事件接入时可改由 mark 提供）。
    nonisolated private static func boundedWindowScan(
        adapters: [any DiscoverySourceAdapting],
        domains: [DiscoverySourceDomain],
        window: DiscoveryTimeWindow,
        limit: Int
    ) throws -> [String] {
        var refs: [String] = []
        var seen = Set<String>()
        for adapter in adapters where domains.contains(adapter.domain) {
            for snapshot in try adapter.fetchSnapshots(window: window, limit: limit)
            where seen.insert(snapshot.sourceRefCanonical).inserted {
                refs.append(snapshot.sourceRefCanonical)
            }
        }
        return refs
    }

    /// 独立事件数：非 ambiguous 的 lineage 组数（ambiguous 不计；computedFact atom 不计）
    private static func independentGroupCount(of atoms: [DiscoveryFactAtom]) -> Int {
        var labels = Set<String>()
        for atom in atoms where atom.sourceKind != .computedFact {
            if case .group(let label) = atom.lineageGroup {
                labels.insert(label)
            }
        }
        return labels.count
    }

    private static func manifestEntries(from atoms: [DiscoveryFactAtom], fetchedAt: Date) -> [DiscoverySourceManifestEntry] {
        atoms.compactMap { atom in
            atom.localSourceRef.map {
                DiscoverySourceManifestEntry(
                    sourceRef: $0.canonical,
                    kind: $0.kind,
                    sourceRevision: atom.sourceRevision,
                    fetchedAt: fetchedAt
                )
            }
        }
    }

    /// 与 DiscoveryStore.sourceManifestDigest 同口径（sourceRef=version 序列、sourceRef 升序）。
    private static func manifestDigest(of entries: [DiscoverySourceManifestEntry]) -> String {
        DiscoveryContentDigest.sourceRevision(
            from: ["discovery.manifest.v1"]
                + entries.map { "\($0.sourceRef)=\($0.sourceRevision)" }.sorted()
        )
    }

    private static func retrievalEntries(from atoms: [DiscoveryFactAtom]) -> [DiscoveryRetrievalIndexEntry] {
        atoms.compactMap { atom in
            guard let ref = atom.localSourceRef else { return nil }   // computedFact 无回源定位
            return DiscoveryRetrievalIndexEntry(
                evidenceID: atom.evidenceID,
                sourceRef: ref.canonical,
                kind: ref.kind,
                sourceRevision: atom.sourceRevision,
                blockHash: DiscoveryContentDigest.sourceRevision(from: [atom.sourceBlock])
            )
        }
    }

    private static func citedEvidenceIDs(of candidate: DiscoveryCandidate) -> Set<String> {
        Set(candidate.claims.flatMap { $0.citations.map(\.evidenceID) })
            .union(candidate.supportEvidenceIDs)
    }

    private static func evidenceSummary(
        of candidate: DiscoveryCandidate,
        available: [String: DiscoveryFactAtom],
        calendar: Calendar
    ) -> DiscoveryEvidenceSummary {
        let cited = citedEvidenceIDs(of: candidate)
        let atoms = cited.compactMap { available[$0] }.filter { $0.sourceKind != .computedFact }
        var labels = Set<String>()
        var dates: [Date] = []
        for atom in atoms {
            if case .group(let label) = atom.lineageGroup { labels.insert(label) }
            if let start = atom.occurredRange.start { dates.append(start) }
        }
        let dayCount = Set(dates.map { calendar.startOfDay(for: $0) }).count
        return DiscoveryEvidenceSummary(
            independentEventCount: labels.count,
            independentEventDates: dates,
            independentDayCount: dayCount
        )
    }

    private static func freezeDigest(of freeze: DiscoveryRunFreeze) -> String {
        DiscoveryContentDigest.sourceRevision(from: [
            "discovery.freeze.v1",
            freeze.runID,
            freeze.accountSubject,
            freeze.deviceID,
            String(freeze.localGrantEpoch),
            String(freeze.serverControlRevision),
            freeze.scopeRevision,
            freeze.sourceManifestDigest,
            String(freeze.candidatePromptVersion),
            String(freeze.verifyPromptVersion),
            String(freeze.modelRouteVersion),
            String(freeze.policyVersion),
            String(Int(freeze.anchorNow.timeIntervalSince1970)),
            freeze.timezone,
        ])
    }

    private static func diagnosticCode(for reason: DiscoveryPublicationRejectionReason) -> DiscoveryDiagnosticReasonCode {
        switch reason {
        case .notAcceptedByVerification: return .noNontrivialObservation
        case .insufficientIndependentEvents: return .insufficientIndependence
        case .boundedPatternSpanTooShort: return .insufficientCoverage
        case .coverageIncomplete: return .insufficientCoverage
        case .sensitivityNotResolved: return .sensitiveInference
        case .userNegated: return .userRejected
        case .duplicateOfRecentFinding: return .noNontrivialObservation
        case .missingEventDates: return .unknownEventTime
        }
    }

    // MARK: - 定量句分级（02 §5 门禁 6 的 V1 近似）

    private enum QuantitativeGrade {
        case none              // 无定量表述
        case countWord         // 中文数词（「这两次」）：可由引用集复算
        case explicitNumber    // 阿拉伯数字：必须引用 computedFact
        case forbidden         // 百分比/相关系数：首发一律拒
    }

    private static func gradeQuantitative(_ text: String) -> QuantitativeGrade {
        if text.contains("%") || text.contains("％") || text.contains("百分比")
            || text.contains("相关系数") || text.contains("相关性") {
            return .forbidden
        }
        if text.contains(where: { $0.isASCII && $0.isNumber }) {
            return .explicitNumber
        }
        let countWords = ["两", "三", "四", "五", "六", "七", "八", "九", "十", "几次", "多次", "每隔"]
        if countWords.contains(where: { text.contains($0) }) {
            return .countWord
        }
        return .none
    }
}

// MARK: - 诊断日志双通道（os_log + 沙盒文件；2026-11-01 真机日志抓取不稳增文件通道）

/// notice 进系统日志 + 同步 append 沙盒文件（8KB 滚动，devicectl 可直拉）。
nonisolated final class DiscoveryDiagLog {
    private let logger: Logger
    private let fileURL: URL?
    private let queue = DispatchQueue(label: "holo.discovery.diaglog")

    init(logger: Logger, fileURL: URL?) {
        self.logger = logger
        self.fileURL = fileURL
    }

    func notice(_ message: String) {
        logger.notice("\(message)")
        guard let url = fileURL else { return }
        queue.async {
            let line = Self.formatter.string(from: Date()) + " " + message + "\n"
            let fm = FileManager.default
            if let existing = (try? String(contentsOf: url, encoding: .utf8)), existing.utf8.count > 8192 {
                try? String(existing.suffix(4096)).write(to: url, atomically: true, encoding: .utf8)
            }
            let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (current + line).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()
}
