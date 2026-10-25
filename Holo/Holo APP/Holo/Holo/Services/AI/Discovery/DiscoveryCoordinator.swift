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
}

extension DiscoveryClient: DiscoveryClientServing {}

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

    // MARK: 运行状态（UI 单一事实源）

    private(set) var presentationState: DiscoveryPresentationState = .disabled
    private(set) var settingsDetailState: DiscoverySettingsDetailState = .disabled
    private(set) var currentFinding: DiscoveryFindingPresentation?
    private(set) var isDetailPresented = false

    /// 在途批次任务（测试可 await 其完成）
    private(set) var batchTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    private var dirtyMarks: [DiscoveryDirtyMark] = []
    /// 首次开启后的受限历史准备尚未完成（不消费到批次终态）
    private var firstRunPending = false
    /// 最近一次运行所处相位（waitingForMaterial 是无 runID 的纯展示态）
    private var lastPhase: DiscoveryRunPhase = .waitingForMaterial
    private var lastFailure: DiscoveryFailureKind?
    private var budgetResetAt: Date?
    private var dailyBatchAvailable = true
    private var serverCapabilitiesEnabled = true
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
        sideStore: DiscoveryCoordinatorSideStore = DiscoveryCoordinatorSideStore()
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
        super.init()

        // App kill 恢复（T41）：在途旧 run 保守标 cancelled（本地），不重调已 dispatch 阶段；
        // 下一次资格（新材料/首开/次日批次）再跑。
        if let active = (try? store.activeRuns()), !active.isEmpty {
            let now = clock()
            for record in active {
                try? store.updateRunPhase(
                    runID: record.runID,
                    phase: .cancelled,
                    diagnostics: [.controlChanged],
                    now: now
                )
            }
        }

        self.invalidationService.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange(_:)),
            name: .holoDiscoverySettingsDidChange,
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
        return DiscoveryCoordinator(store: store)
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
        guard !isBatchRunning else { return }
        isBatchRunning = true
        batchGeneration += 1
        let generation = batchGeneration
        let epoch = settings.snapshot().localGrantEpoch
        batchTask = Task(priority: .utility) { [weak self] in
            await self?.executeBatch(reason: reason, epoch: epoch)
            guard let self else { return }
            if self.batchGeneration == generation {
                self.isBatchRunning = false
            }
        }
    }

    // MARK: - 全链执行

    private func executeBatch(reason: DiscoveryRunReason, epoch: Int) async {
        // 离线撤权意图未补交确认前，永不发起（01 §5）
        guard !sideStore.hasPendingDisableIntent else { return }

        let settingsSnapshot = settings.snapshot()
        guard settingsSnapshot.isEnabled, consentProvider() else {
            await stopAndHide(.controlDisabled, runID: nil)
            return
        }

        // 快路径：无未消费变更且非首开 → 无新材料（本地零读源，前台激活便宜）
        if dirtyMarks.isEmpty && !firstRunPending {
            lastPhase = .waitingForMaterial
            recomputePresentation()
            return
        }

        // ---- 检查位 1：读源前（localGrant/总授权/范围/来源排除的统一门控）----
        let controlRevision = storedControlRevision
        var environment = makeEnvironment(serverControlRevision: controlRevision)
        let grantedDomains = DiscoverySourceDomain.allCases.filter {
            accessPolicy.canReadSources(domain: $0, environment: environment).isAllowed
        }
        guard !grantedDomains.isEmpty else {
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
            lastPhase = .waitingForMaterial
            recomputePresentation()
            return
        }
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

        // ---- 调度决策（03 §4.3/§4.4）----
        refreshBudgetWindow(now: now)
        let decision = schedulerCore.decide(
            marks: dirtyMarks,
            qualification: qualification,
            isFirstEnableAfterGrant: firstRunPending,
            controlEnabled: settings.snapshot().isEnabled,
            consentGranted: consentProvider(),
            scopeValid: !settings.snapshot().allowedDomains.isEmpty,
            dailyBatchAvailable: dailyBatchAvailable,
            budgetResetAt: budgetResetAt,
            processedToday: sideStore.processedRecord,
            currentSourceManifestDigest: currentDigest,
            policyVersion: versions.policyVersion,
            promptVersion: versions.candidatePromptVersion,
            resource: resourceSnapshotProvider(),
            now: now
        )

        switch decision {
        case .stopAndHide(let stopReason):
            await stopAndHide(stopReason, runID: nil)
            return
        case .waitingForMaterial:
            lastPhase = .waitingForMaterial
            recomputePresentation()
            return
        case .deferred(let deferredReason):
            applyDeferred(deferredReason, now: now)
            return
        case .prepare:
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

            let (stageResponse, envelope) = try await client.candidates(
                runID: runID,
                runToken: created.runToken,
                requestID: idProvider(),
                data: Self.candidateRequestData(
                    freeze: freeze,
                    material: material,
                    allowedDomains: settingsSnapshot.allowedDomains,
                    iso: Self.isoFormatter.string(from:)
                )
            )
            guard !Task.isCancelled, isControlStillValid(epoch: epoch) else {
                try await abortInFlight(runID: runID, diagnostics: [.controlChanged])
                return
            }
            // 门禁 2（归属）：服务端阶段响应与信封 runID 必须一致
            guard stageResponse.runID == runID, envelope.runID == runID else {
                try await abortInFlight(runID: runID, diagnostics: [.schemaInvalid])
                return
            }

            // ---- 结构门禁（02 §5 八条；1/3 的 schema 部分已在客户端解码时完成）----
            let historyWindow = DiscoveryRetriever.windows(for: recallRequest, now: now).history
            let gate = runStructuralGate(
                candidates: envelope.candidates,
                material: material,
                historyWindow: historyWindow
            )

            if envelope.candidates.isEmpty {
                // 服务端对空候选自动 completeRun（03 §4.2），客户端不调 verify、不 cancel
                try finishBatchNoFinding(runID: runID, digest: freeze.sourceManifestDigest, diagnostics: gate.diagnostics)
                return
            }
            if gate.survivors.isEmpty {
                // 本地全拒：cancel 释放后续语义（不承诺第三方未处理），并记成功终态
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
                runToken: created.runToken,
                requestID: idProvider(),
                candidates: candidatesEcho,
                data: Self.verifyRequestData(
                    freeze: freeze,
                    material: material,
                    counter: mergedCounter,
                    perCandidateCoverage: counterPackages.mapValues(\.coverageState),
                    allowedDomains: settingsSnapshot.allowedDomains,
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
        } catch {
            handleStageFailure(error, runID: runID)
        }
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
        let acceptedCandidates: [AcceptedCandidate] = verifiedCandidates.compactMap { candidate in
            guard let result = verification.candidateResults.first(where: { $0.candidateID == candidate.candidateID })
            else { return nil }
            guard result.verdict == .accept else { return nil }
            return AcceptedCandidate(
                candidate: candidate,
                verification: result,
                counterEvidenceCount: mergedCounterBlocks.count
            )
        }
        let digest = freeze.sourceManifestDigest
        guard !acceptedCandidates.isEmpty else {
            // 全部被核验拒绝：verify 已完成服务端 run，记成功终态（同材料不隔天重跑）
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
            try store.publishFinding(
                runID: runID,
                payload: backfilled,
                dependencies: resolvedDependencies,
                publishedAt: publishedAt,
                expiresAt: publishedAt.addingTimeInterval(14 * 24 * 3600),
                freezeDigest: Self.freezeDigest(of: freeze)
            )
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

    private func handleStageFailure(_ error: Error, runID: String) {
        let now = clock()
        let failure = Self.classify(error)

        switch failure {
        case .networkUnavailablePreDispatch:
            // 未 dispatch：保持 dirty，有限退避，不报「生成中」
            lastFailure = failure
            if let next = schedulerCore.nextAttemptAfterFailure(failure: failure, now: now) {
                scheduleRetry(after: next.timeIntervalSince(now))
            }
            recomputePresentation()
            return
        case .budgetExceeded:
            lastFailure = failure
            dailyBatchAvailable = false
            budgetResetAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .schemaRejectedByModel, .semanticRejected:
            lastFailure = failure
        case .stageResultLost, .upstreamErrorPostDispatch, .leaseExpired:
            // dispatch 后失败：本阶段不重复调用，终止本批（03 §4.4）
            lastFailure = failure
        }

        if settings.snapshot().isEnabled {
            try? store.updateRunPhase(
                runID: runID,
                phase: .backoff,
                diagnostics: [Self.diagnosticCode(forFailure: failure)],
                now: now
            )
        }
        // 失败一律保持 dirty（未成功终态不消费变更；「材料不变不重跑」由 processedRecord
        // 只在成功终态记录来保证）。重试节奏受日批次与有限退避约束。
        lastPhase = .backoff
        recomputePresentation()
    }

    private static func classify(_ error: Error) -> DiscoveryFailureKind {
        if case DiscoveryClient.DiscoveryClientError.stageResultLost = error { return .stageResultLost }
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
            if let next = schedulerCore.nextAttemptAfterFailure(failure: .networkUnavailablePreDispatch, now: now) {
                scheduleRetry(after: next.timeIntervalSince(now))
            }
        case .resourceYield, .leaseActive:
            break   // 前台激活/变更事件的轻量检查会再触发
        case .dailyBudgetExhausted(let resetAt):
            lastFailure = .budgetExceeded
            dailyBatchAvailable = false
            // 无服务端 resetAt 时保守到次日自然日（上海日界由服务端口径，本机按本地日近似）
            budgetResetAt = resetAt ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
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
        } catch {
            return .cancelled   // 任一步失败保持关闭
        }
        guard capabilities.enabled else {
            serverCapabilitiesEnabled = false
            recomputePresentation()
            return .serverUnsupported
        }
        serverCapabilitiesEnabled = true
        versions.policyVersion = capabilities.policyVersion

        // 全局授权缺失 → 引导授权（不自动打开）
        guard consentProvider() else { return .needsGlobalConsent }

        // 控制快照：他设备占用需用户确认接管（V1 单设备租约）
        let control: DiscoveryClient.ControlResponse
        do {
            control = try await client.control()
        } catch {
            return .cancelled
        }
        let myDevice = deviceIdProvider()
        let ownedByOther = control.ownerDeviceId != nil && control.ownerDeviceId != myDevice
        if ownedByOther && !confirmTakeoverIfOwnedByOtherDevice, let owner = control.ownerDeviceId {
            return .needsTakeoverConfirmation(ownerDeviceID: owner)
        }

        do {
            let response = try await client.enable(
                expectedRevision: control.revision,
                allowedDomains: selectedDomains.map(\.rawValue).sorted(),
                consentDocVersion: control.consentDocVersion ?? "discovery-consent-v1",
                confirmTakeover: ownedByOther,
                requestID: idProvider()
            )
            // 服务端确认后本机才保存（任一步失败保持关闭）
            try settings.enable(domains: selectedDomains)
            try store.upsertControlSnapshot(DiscoveryControlSnapshotRecord(
                revision: response.revision,
                payloadJSON: "{\"revision\":\(response.revision),\"enabled\":true}",
                digest: DiscoveryContentDigest.sourceRevision(from: ["discovery.control.v1", String(response.revision), "true"]),
                fetchedAt: clock()
            ))
            firstRunPending = true   // 受限历史准备（不等待新增记录）
            recomputePresentation()
            runBatch(reason: .enableFirstRun)
            return .enabled
        } catch {
            return .cancelled
        }
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
            return   // 回执：不弹任务、不写长期记忆（01 §3）
        case .manageDismiss:
            isDetailPresented = false
            recomputePresentation()
            return
        case .inaccurate(let reason):
            // 先撤下，再记最小否定（点击后无需等联网）
            guard let record = readableFinding(now: clock()) else { return }
            let material = record.payload.fingerprintMaterial
            // 幂等：先查再写（连续点击不重复写入）
            if (try? store.hasNegativeFeedback(fingerprintMaterial: material)) != true {
                try? store.recordNegativeFeedback(fingerprintMaterial: material, now: clock())
            }
            try? store.markFinding(id: record.id, status: .rejected, now: clock())
            if reason == .notInterested {
                // 类别持续抑制（可在子页恢复；resetFeedbackSuppression 清除）
                sideStore.addSuppressedCategory(material)
            }
            currentFinding = nil
            isDetailPresented = false
            recomputePresentation()
        }
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
        if environmentProvider.foregroundCheck() == .scheduleUtilityCheck {
            runBatch(reason: .refresh)
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
