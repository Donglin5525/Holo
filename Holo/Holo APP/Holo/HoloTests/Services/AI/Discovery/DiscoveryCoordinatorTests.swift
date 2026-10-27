//
//  DiscoveryCoordinatorTests.swift
//  HoloTests
//
//  「一个发现」G6 协调器测试（02 §8/§9、03 §4/§5、01 §5）：
//  快乐路径全链（材料→候选→核验→发布）、空候选 noFinding 只一次模型调用、
//  结构全拒 cancel、T09 在途撤权丢弃迟到结果、网络不可用 pre-dispatch 保持 dirty、
//  kill 恢复保守关闭、反馈幂等、离线 disable 待提交意图、enable 分支、续聊草稿来源重核。
//  待挂载 HoloTests target（本文件为新增，未改动 pbxproj，由主会话统一挂载）。
//

// 待挂载 HoloTests target
import XCTest
import CoreData
import SwiftUI
@testable import Holo

// MARK: - Mock 客户端

@MainActor
private final class MockDiscoveryClient: DiscoveryClientServing {

    /// candidates 响应形态
    enum CandidatesSpec {
        case happy          // 合格 two_episodes 候选
        case empty          // 空候选 + noMaterial
        case badQuote       // quote 对不回原文（结构全拒）
    }

    var capabilitiesFlag = true
    var capabilitiesError: Error?
    var controlError: Error?
    var enableError: Error?
    var onEnable: (() -> Void)?
    var capabilitiesPolicyVersion = 1
    var controlRevisionValue = 1
    var controlEnabled = true
    var controlOwnerDeviceId: String?
    var disableError: Error?
    var candidatesSpec: CandidatesSpec = .happy
    var verifyEnvelopeOverride: DiscoveryVerificationEnvelope?
    var holdVerify = false
    var releaseVerify = false

    private(set) var capabilitiesCallCount = 0
    private(set) var controlCallCount = 0
    private(set) var enableCallCount = 0
    private(set) var disableCallCount = 0
    private(set) var createRunCallCount = 0
    private(set) var candidatesCallCount = 0
    private(set) var verifyCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var createdRunIDs: [String] = []
    private(set) var cancelledRunIDs: [String] = []

    var totalNetworkCalls: Int {
        capabilitiesCallCount + controlCallCount + enableCallCount + disableCallCount
            + createRunCallCount + candidatesCallCount + verifyCallCount + cancelCallCount
    }

    func capabilities() async throws -> DiscoveryClient.CapabilitiesResponse {
        capabilitiesCallCount += 1
        if let capabilitiesError { throw capabilitiesError }
        return DiscoveryClient.CapabilitiesResponse(
            protocolVersion: 1,
            enabled: capabilitiesFlag,
            policyVersion: capabilitiesPolicyVersion,
            allowedDomains: ["thought"],
            budget: .init(runsPerDay: 1, candidateMaxTokens: nil, verifyMaxTokens: nil, inputBudgetTokens: 16000)
        )
    }

    func control() async throws -> DiscoveryClient.ControlResponse {
        controlCallCount += 1
        if let controlError { throw controlError }
        return DiscoveryClient.ControlResponse(
            enabled: controlEnabled,
            revision: controlRevisionValue,
            ownerDeviceId: controlOwnerDeviceId,
            scopeRevision: 1,
            allowedDomains: ["thought"],
            consentDocVersion: "discovery-consent-v1"
        )
    }

    func enable(
        expectedRevision: Int,
        allowedDomains: [String],
        consentDocVersion: String?,
        confirmTakeover: Bool,
        requestID: String
    ) async throws -> DiscoveryClient.EnableResponse {
        enableCallCount += 1
        if let enableError { throw enableError }
        onEnable?()
        controlRevisionValue += 1
        return DiscoveryClient.EnableResponse(
            enabled: true,
            revision: controlRevisionValue,
            scopeRevision: 1,
            allowedDomains: allowedDomains,
            ownerDeviceId: "device-A",
            grant: "grant-1",
            replayed: false
        )
    }

    func disable(requestID: String, reason: String?) async throws -> DiscoveryClient.DisableResponse {
        disableCallCount += 1
        if let disableError { throw disableError }
        return DiscoveryClient.DisableResponse(enabled: false, revision: controlRevisionValue + 1, scopeRevision: 1, replayed: false)
    }

    func updateScope(
        expectedRevision: Int,
        allowedDomains: [String],
        consentDocVersion: String?,
        requestID: String
    ) async throws -> DiscoveryClient.ScopeResponse {
        DiscoveryClient.ScopeResponse(enabled: true, revision: expectedRevision, scopeRevision: 1, allowedDomains: allowedDomains, replayed: false)
    }

    func createRun(
        runID: String,
        sourceManifestDigest: String?,
        requestID: String?
    ) async throws -> DiscoveryClient.CreateRunResponse {
        createRunCallCount += 1
        createdRunIDs.append(runID)
        return DiscoveryClient.CreateRunResponse(
            runID: runID,
            runToken: "run-token-\(runID)",
            status: "reserved",
            controlRevision: controlRevisionValue,
            scopeRevision: 1,
            dayKey: "2026-10-23",
            leaseExpiresAt: 1_790_000_600,
            leaseSeconds: 600,
            stageBudget: .init(candidates: 1, verify: 1),
            replayed: nil
        )
    }

    func candidates(
        runID: String,
        runToken: String,
        requestID: String?,
        data: DiscoveryJSONValue
    ) async throws -> (response: DiscoveryClient.StageResponse, envelope: DiscoveryCandidateEnvelope) {
        candidatesCallCount += 1
        switch candidatesSpec {
        case .empty:
            let envelope = DiscoveryCandidateEnvelope(runID: runID, candidates: [], noFindingReason: .noMaterial)
            let response = try Self.stageResponse(runID: runID, stage: "candidates", envelopeObject: [
                "schemaVersion": 1, "kind": "candidates", "runID": runID,
                "candidates": [], "noFindingReason": "no_material",
            ])
            return (response, envelope)
        case .happy, .badQuote:
            let quoteOverride: String? = candidatesSpec == .badQuote ? "这段话不存在于任何原文记录中" : nil
            let envelope = DiscoveryFixtures.candidateEnvelope(runID: runID, quoteOverride: quoteOverride)
            let response = try Self.stageResponse(runID: runID, stage: "candidates", envelopeObject: [
                "schemaVersion": 1, "kind": "candidates", "runID": runID,
                "candidates": [DiscoveryFixtures.candidateObject(quoteOverride: quoteOverride)],
                "noFindingReason": "none",
            ])
            return (response, envelope)
        }
    }

    func verify(
        runID: String,
        runToken: String,
        requestID: String?,
        candidates: DiscoveryJSONValue,
        data: DiscoveryJSONValue
    ) async throws -> (response: DiscoveryClient.StageResponse, envelope: DiscoveryVerificationEnvelope) {
        verifyCallCount += 1
        // T09 用：按住核验直至测试放行（取消后 sleep 报错被吞，继续等释放再返回迟到结果）
        while holdVerify && !releaseVerify {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let envelope = verifyEnvelopeOverride ?? DiscoveryFixtures.acceptVerification(runID: runID)
        let response = try Self.stageResponse(runID: runID, stage: "verify", envelopeObject: [
            "schemaVersion": 1, "kind": "verification", "runID": runID, "candidateResults": [],
        ])
        return (response, envelope)
    }

    func cancel(runID: String, requestID: String) async throws -> DiscoveryClient.CancelResponse {
        cancelCallCount += 1
        cancelledRunIDs.append(runID)
        return DiscoveryClient.CancelResponse(runID: runID, status: "cancelled", alreadyClosed: false)
    }

    /// StageResponse 只有 init(from:)，经 JSON 解码构造
    static func stageResponse(runID: String, stage: String, envelopeObject: [String: Any]) throws -> DiscoveryClient.StageResponse {
        let payload: [String: Any] = ["runID": runID, "stage": stage, "envelope": envelopeObject]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(DiscoveryClient.StageResponse.self, from: data)
    }
}

// MARK: - 合成适配器（G2 测试同款；非 MainActor——协议同步要求 + 协调器 detached 调用）

private final class SyntheticThoughtAdapter: DiscoverySourceAdapting {
    let domain = DiscoverySourceDomain.thought
    let sourceKind = DiscoverySourceKind.thought
    var snapshots: [DiscoverySourceSnapshot] = []
    var availabilityValue = DiscoverySourceAvailability(earliestRecordAt: Date(timeIntervalSince1970: 0))

    func basePredicate() -> NSPredicate { NSPredicate(value: true) }

    private func inWindow(_ snapshot: DiscoverySourceSnapshot, _ window: DiscoveryTimeWindow) -> Bool {
        window.contains(snapshot.occurredAt ?? snapshot.recordedAt)
    }

    func fetchSnapshots(localIDs: [String], limit: Int) throws -> [DiscoverySourceSnapshot] {
        snapshots.filter { localIDs.contains($0.localID) }
    }

    func fetchSnapshots(topicRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        snapshots.filter { inWindow($0, window) && !$0.entityRefs.filter { topicRefs.contains($0) }.isEmpty }
    }

    func fetchSnapshots(anchorRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        let keys = Set(anchorRefs)
        return snapshots.filter { inWindow($0, window) && !($0.eventAnchors + $0.entityRefs).filter { keys.contains($0) }.isEmpty }
    }

    func fetchSnapshots(keyword: String, window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        snapshots.filter { inWindow($0, window) && $0.text.lowercased().contains(keyword.lowercased()) }
    }

    func fetchSnapshots(window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        snapshots.filter { inWindow($0, window) }
    }

    func availability() throws -> DiscoverySourceAvailability { availabilityValue }
}

// MARK: - 资源快照盒子（可变注入）

private final class ResourceSnapshotBox: @unchecked Sendable {
    var value: DiscoveryResourceSnapshot
    init(_ value: DiscoveryResourceSnapshot) {
        self.value = value
    }
}

// MARK: - 候选/核验 fixtures

private enum DiscoveryFixtures {

    static let titleText = "重新开始时，你把第一步变得更轻了。"
    static let bodyText = "恢复运动时先走了十分钟；重新阅读时放低了每夜的目标。这两段记录相似，但还不能说明一直有效。"
    static let quote1 = "今天先出去走了十分钟"
    static let quote2 = "今晚只翻了两页"

    /// 快照文本（quote 是其精确子串，保证 quote 对齐通过）
    static let sportText = "停了一阵，今天先出去走了十分钟。没有要求自己一定跑起来。"
    static let readingText = "重新读书，今晚只翻了两页，没有要求读完一章。"

    static func candidate(quoteOverride: String? = nil) -> DiscoveryCandidate {
        let q1 = quoteOverride ?? quote1
        let q2 = quoteOverride ?? quote2
        return DiscoveryCandidate(
            candidateID: "C01",
            type: .twoEpisodes,
            subjectKey: "lighter-start",
            scopeKind: .twoEpisodes,
            timeRange: DiscoveryTimeRange(start: nil, end: nil),
            claims: [
                DiscoveryClaim(
                    claimID: "K1", kind: .fact, text: titleText,
                    citations: [DiscoveryCitation(evidenceID: "E01", quote: q1)], metricIDs: []
                ),
                DiscoveryClaim(
                    claimID: "K2", kind: .observation, text: bodyText,
                    citations: [
                        DiscoveryCitation(evidenceID: "E01", quote: q1),
                        DiscoveryCitation(evidenceID: "E02", quote: q2),
                    ], metricIDs: []
                ),
            ],
            titleClaimID: "K1",
            bodyClaimIDs: ["K2"],
            supportEvidenceIDs: ["E01", "E02"],
            counterSearch: [],
            sensitivity: .nonSensitive,
            comparisonPeriods: []
        )
    }

    static func candidateEnvelope(runID: String, quoteOverride: String? = nil) -> DiscoveryCandidateEnvelope {
        DiscoveryCandidateEnvelope(runID: runID, candidates: [candidate(quoteOverride: quoteOverride)], noFindingReason: .none)
    }

    static func candidateObject(quoteOverride: String? = nil) -> [String: Any] {
        let q1 = quoteOverride ?? quote1
        let q2 = quoteOverride ?? quote2
        return [
            "candidateID": "C01",
            "type": "two_episodes",
            "subjectKey": "lighter-start",
            "scopeKind": "two_episodes",
            "timeRange": ["start": NSNull(), "end": NSNull()],
            "claims": [
                ["claimID": "K1", "kind": "fact", "text": titleText,
                 "citations": [["evidenceID": "E01", "quote": q1]], "metricIDs": []],
                ["claimID": "K2", "kind": "observation", "text": bodyText,
                 "citations": [["evidenceID": "E01", "quote": q1], ["evidenceID": "E02", "quote": q2]],
                 "metricIDs": []],
            ],
            "titleClaimID": "K1",
            "bodyClaimIDs": ["K2"],
            "supportEvidenceIDs": ["E01", "E02"],
            "counterSearch": [],
            "sensitivity": "non_sensitive",
            "comparisonPeriods": [],
        ]
    }

    static func acceptVerification(runID: String) -> DiscoveryVerificationEnvelope {
        DiscoveryVerificationEnvelope(runID: runID, candidateResults: [
            DiscoveryCandidateResult(
                candidateID: "C01",
                verdict: .accept,
                claimResults: [
                    DiscoveryClaimResult(claimID: "K1", verdict: .supported, reasonCodes: [], supportEvidenceIDs: ["E01"], counterEvidenceIDs: []),
                    DiscoveryClaimResult(claimID: "K2", verdict: .supported, reasonCodes: [], supportEvidenceIDs: ["E01", "E02"], counterEvidenceIDs: []),
                ],
                reasonCodes: []
            ),
        ])
    }
}

// MARK: - 测试

@MainActor
final class DiscoveryCoordinatorTests: XCTestCase {

    /// iOS 26.3 测试宿主坑（habit-drag-session-deadlock-1011 档案）：
    /// MainActor 隔离类在用例内局部释放踩 TaskLocal 析构 double-free，
    /// 协调器/mock/适配器/store 全部钉进程级池不释放。
    nonisolated(unsafe) private static var pinned: [AnyObject] = []

    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    private var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: DiscoverySettings!
    private var store: DiscoveryStore!
    private var mock: MockDiscoveryClient!
    private var adapter: SyntheticThoughtAdapter!
    private var resourceBox: ResourceSnapshotBox!

    override func setUp() async throws {
        suiteName = "DiscoveryCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = DiscoverySettings(defaults: defaults)
        try settings.enable(domains: [.thought])   // enabled=true, epoch=1
        store = try DiscoveryStore(configuration: .init(
            inMemory: true,
            feedbackKey: Data(repeating: 7, count: 32)
        ))
        mock = MockDiscoveryClient()
        adapter = SyntheticThoughtAdapter()
        adapter.snapshots = [
            thoughtSnapshot(id: "t1", text: DiscoveryFixtures.sportText, daysAgo: 10),
            thoughtSnapshot(id: "t2", text: DiscoveryFixtures.readingText, daysAgo: 3),
        ]
        try store.upsertControlSnapshot(DiscoveryControlSnapshotRecord(
            revision: 1, payloadJSON: "{}", digest: "control-digest", fetchedAt: fixedNow
        ))
        resourceBox = ResourceSnapshotBox(DiscoveryResourceSnapshot())
        let pinnedBatch: [AnyObject] = [settings, store, mock, adapter, resourceBox]
        Self.pinned.append(contentsOf: pinnedBatch)
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    // MARK: - 工具

    private func thoughtSnapshot(id: String, text: String, daysAgo: Double, refs: [String] = ["tag:运动"]) -> DiscoverySourceSnapshot {
        let occurred = fixedNow.addingTimeInterval(-daysAgo * 86400)
        return DiscoverySourceSnapshot(
            domain: .thought, kind: .thought, localID: id,
            occurredAt: occurred, occurredOnlyDateKnown: false,
            recordedAt: occurred,
            text: text, numericValue: nil, numericUnit: nil,
            entityRefs: refs, eventAnchors: [],
            revisionFields: ["discovery.thought.v1", id, text, String(occurred.timeIntervalSince1970)]
        )
    }

    private func makeCoordinator(consentProvider: @escaping () -> Bool = { true }) -> DiscoveryCoordinator {
        let coordinator = DiscoveryCoordinator(
            settings: settings,
            store: store,
            client: mock,
            adapters: [adapter],
            retriever: DiscoveryRetriever(adapters: [adapter]),
            invalidationService: DiscoveryInvalidationService(
                store: store,
                businessCoordinator: NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
            ),
            clock: { self.fixedNow },
            calendar: shanghaiCalendar,
            deviceIdProvider: { "device-A" },
            consentProvider: consentProvider,
            idProvider: { "req-\(UUID().uuidString)" },
            resourceSnapshotProvider: { self.resourceBox.value },
            sideStore: DiscoveryCoordinatorSideStore(defaults: defaults)
        )
        Self.pinned.append(coordinator)
        return coordinator
    }

    /// 触发一次批次：登记一条已过静默窗的变更并等待批次结束
    private func runOneBatch(_ coordinator: DiscoveryCoordinator, digest: String = "digest-1") async {
        coordinator.markDirty(
            domain: .thought,
            changedAt: fixedNow.addingTimeInterval(-1200),
            digestContribution: digest
        )
        coordinator.runBatch(reason: .dirtyMark)
        await coordinator.batchTask?.value
    }

    private func tombstoneCount() throws -> Int {
        try store.performRead { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DiscoveryFeedbackTombstoneMO")
            return try context.fetch(request).count
        }
    }

    // MARK: - 快乐路径

    func test_快乐路径_材料到候选到核验到发布() async throws {
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)

        XCTAssertEqual(mock.createRunCallCount, 1)
        XCTAssertEqual(mock.candidatesCallCount, 1)
        XCTAssertEqual(mock.verifyCallCount, 1)
        XCTAssertEqual(mock.cancelCallCount, 0, "发布成功不 cancel")

        guard case .available(let findingID, let viewed) = coordinator.presentationState else {
            return XCTFail("发布后应为 available，实际 \(coordinator.presentationState)")
        }
        XCTAssertFalse(viewed)
        XCTAssertFalse(findingID.isEmpty)

        let record = try store.activeFinding(now: fixedNow)
        XCTAssertEqual(record?.payload.title, DiscoveryFixtures.titleText)
        XCTAssertEqual(record?.runID, mock.createdRunIDs.first)
        // citations.sourceRef 用 retrievalIndex 回填真实来源
        let sourceRefs = record?.payload.citations.map(\.sourceRef) ?? []
        XCTAssertTrue(sourceRefs.contains("thought:t1"), "E01 引用回填 thought:t1，实际 \(sourceRefs)")
        XCTAssertTrue(sourceRefs.contains("thought:t2"), "E02 引用回填 thought:t2，实际 \(sourceRefs)")

        XCTAssertEqual(try store.runState(runID: mock.createdRunIDs[0])?.phase, .ready)
    }

    // MARK: - 空候选

    func test_空候选_noFinding只一次模型调用_verify不发() async throws {
        mock.candidatesSpec = .empty
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)

        XCTAssertEqual(mock.candidatesCallCount, 1, "只调一次生成")
        XCTAssertEqual(mock.verifyCallCount, 0, "空候选不调核验")
        XCTAssertEqual(mock.cancelCallCount, 0, "服务端对空候选自动 completeRun，客户端不 cancel")
        XCTAssertEqual(try store.runState(runID: mock.createdRunIDs[0])?.phase, .noFinding)
        XCTAssertEqual(coordinator.presentationState, .waitingForMaterial)

        // 同材料（digest 不变）新变更触发也不重跑（T20：成功终态记 source digest）
        await runOneBatch(coordinator, digest: "digest-2")
        XCTAssertEqual(mock.candidatesCallCount, 1, "材料不变不隔天重跑")
    }

    // MARK: - 结构全拒

    func test_结构全拒_quote对不回原文_cancel调用且记processed() async throws {
        mock.candidatesSpec = .badQuote
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)

        XCTAssertEqual(mock.verifyCallCount, 0, "无结构合格候选不调核验（03 §4.2）")
        XCTAssertEqual(mock.cancelCallCount, 1, "本地全拒 cancel 释放后续语义")
        XCTAssertEqual(try store.runState(runID: mock.createdRunIDs[0])?.phase, .noFinding)

        // 同材料不再重跑
        await runOneBatch(coordinator, digest: "digest-2")
        XCTAssertEqual(mock.candidatesCallCount, 1)
    }

    // MARK: - T09：在途撤权丢弃迟到结果

    func test_T09_verify在途时disable_迟到结果被丢弃() async throws {
        let coordinator = makeCoordinator()
        mock.holdVerify = true

        coordinator.markDirty(
            domain: .thought,
            changedAt: fixedNow.addingTimeInterval(-1200),
            digestContribution: "digest-t09"
        )
        coordinator.runBatch(reason: .dirtyMark)

        // 等核验已发出（在途）
        while mock.verifyCallCount == 0 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let batchTask = coordinator.batchTask

        await coordinator.disable()
        XCTAssertEqual(mock.disableCallCount, 1)
        XCTAssertFalse(coordinator.isDisableIntentPending, "在线 disable 无待提交意图")
        XCTAssertEqual(coordinator.presentationState, .disabled)

        // 放行迟到的核验结果（accept）
        mock.releaseVerify = true
        await batchTask?.value

        XCTAssertEqual(mock.cancelCallCount, 1, "控制失效丢弃在途结果并 best effort cancel 服务端 run")
        XCTAssertNil(try store.activeFinding(now: fixedNow), "迟到结果永不采纳")
        XCTAssertNil(coordinator.currentFinding)
    }

    // MARK: - 退避：网络不可用

    func test_网络不可用_preDispatch保持dirty不发网络() async throws {
        var snapshot = DiscoveryResourceSnapshot()
        snapshot.isNetworkAvailable = false
        resourceBox.value = snapshot

        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)

        XCTAssertEqual(mock.totalNetworkCalls, 0, "网络不可用且未 dispatch：不发任何网络请求")
        XCTAssertEqual(coordinator.presentationState, .temporarilyUnavailable)

        // 网络恢复后 dirty 仍在，重跑能到 candidates
        resourceBox.value = DiscoveryResourceSnapshot()
        await runOneBatch(coordinator, digest: "digest-2")
        XCTAssertEqual(mock.createRunCallCount, 1, "dirty 保持：网络恢复后同一批材料继续")
        XCTAssertEqual(mock.candidatesCallCount, 1)
    }

    // MARK: - kill 恢复（T41）

    func test_kill恢复_preparing旧run保守关闭且不发网络() async throws {
        let freeze = DiscoveryRunFreeze(
            runID: "legacy-run",
            accountSubject: "device-A",
            deviceID: "device-A",
            localGrantEpoch: 1,
            serverControlRevision: 1,
            scopeRevision: "legacy-scope",
            sourceManifestDigest: "legacy-digest",
            candidatePromptVersion: 1,
            verifyPromptVersion: 1,
            modelRouteVersion: 1,
            policyVersion: 1,
            anchorNow: fixedNow.addingTimeInterval(-600),
            timezone: "Asia/Shanghai"
        )
        try store.upsertRunState(freeze: freeze, phase: .preparing, now: fixedNow.addingTimeInterval(-600))

        let coordinator = makeCoordinator()

        XCTAssertEqual(try store.runState(runID: "legacy-run")?.phase, .cancelled, "在途旧 run 保守标 cancelled")
        XCTAssertEqual(mock.totalNetworkCalls, 0, "恢复不重调已 dispatch 阶段、不发网络")
        XCTAssertEqual(coordinator.presentationState, .waitingForMaterial)
    }

    // MARK: - 反馈幂等

    func test_反馈幂等_连续两次inaccurate只写一条tombstone() async throws {
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)
        XCTAssertNotNil(try store.activeFinding(now: fixedNow), "前置：已发布一条")

        await coordinator.submitFeedback(.inaccurate(reason: .wrongUnderstanding))
        await coordinator.submitFeedback(.inaccurate(reason: .wrongUnderstanding))

        XCTAssertEqual(try tombstoneCount(), 1, "同主题否定只写一条")
        XCTAssertNil(try store.activeFinding(now: fixedNow), "否定即撤下")
        XCTAssertEqual(coordinator.presentationState, .waitingForMaterial)
    }

    // MARK: - 离线 disable

    func test_离线disable_pendingIntent置位_refresh补交成功后清除() async throws {
        let coordinator = makeCoordinator()
        mock.disableError = URLError(.notConnectedToInternet)

        await coordinator.disable()
        XCTAssertTrue(coordinator.isDisableIntentPending, "离线关闭保留待提交意图")
        XCTAssertEqual(mock.disableCallCount, 1)
        XCTAssertEqual(coordinator.presentationState, .disabled)

        // 待提交意图未确认前不发材料
        await runOneBatch(coordinator)
        XCTAssertEqual(mock.totalNetworkCalls, 1, "runBatch 被挡下（仅此前的 disable 一次调用）")

        mock.disableError = nil
        await coordinator.refresh()
        XCTAssertFalse(coordinator.isDisableIntentPending, "联网后优先补交并清除意图")
        XCTAssertEqual(mock.disableCallCount, 2)
    }

    // MARK: - enable 分支
    // setUp 为批量用例预开了设置；enable 流程用例必须从「关闭」初态出发（01 §5：任一步失败保持关闭）

    func test_开启_后端不支持返回serverUnsupported() async throws {
        settings.disable()
        mock.capabilitiesFlag = false
        let coordinator = makeCoordinator()
        let outcome = await coordinator.enable(
            selectedDomains: [.thought],
            confirmTakeoverIfOwnedByOtherDevice: false
        )
        XCTAssertEqual(outcome, .serverUnsupported)
        XCTAssertFalse(settings.snapshot().isEnabled, "任一步失败保持关闭")
        XCTAssertEqual(coordinator.presentationState, .serverUnsupported)
    }

    func test_开启_他设备占用需确认接管() async throws {
        settings.disable()
        mock.controlOwnerDeviceId = "device-other"
        let coordinator = makeCoordinator()
        let outcome = await coordinator.enable(
            selectedDomains: [.thought],
            confirmTakeoverIfOwnedByOtherDevice: false
        )
        XCTAssertEqual(outcome, .needsTakeoverConfirmation(ownerDeviceID: "device-other"))
        XCTAssertEqual(mock.enableCallCount, 0, "未确认不发起接管")
        XCTAssertFalse(settings.snapshot().isEnabled)
    }

    func test_开启_正常路径enabled且无材料不消耗批次() async throws {
        settings.disable()
        adapter.snapshots = []   // 首开无材料
        let coordinator = makeCoordinator()
        let outcome = await coordinator.enable(
            selectedDomains: [.thought],
            confirmTakeoverIfOwnedByOtherDevice: false
        )
        XCTAssertEqual(outcome, .enabled)
        XCTAssertTrue(settings.snapshot().isEnabled)
        if let task = coordinator.batchTask {
            await task.value
        }
        XCTAssertEqual(mock.createRunCallCount, 0, "首开无材料不消耗批次（03 §4.3）")
        XCTAssertEqual(coordinator.settingsDetailState, .waitingForMaterial)
    }

    // MARK: - 续聊草稿与发送前重核（检查位 6）

    func test_续聊草稿_组装与发送前来源重核() async throws {
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)

        let draft = coordinator.buildConversationDraft()
        XCTAssertNotNil(draft)
        XCTAssertEqual(draft?.findingTitle, DiscoveryFixtures.titleText)
        XCTAssertTrue(draft?.sourceScopeDescription.contains("想法") == true, "来源范围描述含允许域")
        XCTAssertFalse(draft?.suggestedDraftText.isEmpty == true, "建议问句非空")

        let findingID = {
            if case .available(let id, _) = coordinator.presentationState { return id }
            return ""
        }()
        let validate = await coordinator.validateConversationDraftForSend(findingID: findingID)
        XCTAssertTrue(validate, "来源未变可发送")

        // 撤源（来源全部消失）→ 发送前重核 false
        adapter.snapshots = []
        let revalidate = await coordinator.validateConversationDraftForSend(findingID: findingID)
        XCTAssertFalse(revalidate, "撤源后「来源已不可用」")

        // ID 不匹配同样拒绝
        let mismatch = await coordinator.validateConversationDraftForSend(findingID: "not-a-finding")
        XCTAssertFalse(mismatch)
    }
    func test_线上能力响应_v前缀策略版本可以解码() throws {
        let payload = #"{"protocolVersion":1,"enabled":true,"policyVersion":"v1","allowedDomains":["thought","task","habit"],"budget":{"runsPerDay":1,"candidateMaxTokens":3072,"verifyMaxTokens":4096,"inputBudgetTokens":16384}}"#
        let response = try JSONDecoder().decode(DiscoveryClient.CapabilitiesResponse.self, from: Data(payload.utf8))
        XCTAssertEqual(response.policyVersion, 1)
        XCTAssertTrue(response.enabled)
        for version in ["2", #""v2""#, #""2""#] {
            let updated = payload.replacingOccurrences(of: #""v1""#, with: version)
            XCTAssertEqual(try JSONDecoder().decode(DiscoveryClient.CapabilitiesResponse.self, from: Data(updated.utf8)).policyVersion, 2)
        }
        let invalid = payload.replacingOccurrences(of: #""v1""#, with: #""unknown""#)
        XCTAssertThrowsError(try JSONDecoder().decode(DiscoveryClient.CapabilitiesResponse.self, from: Data(invalid.utf8)))
    }

    func test_Plus标识在宽布局中仍保持声明尺寸() {
        for tier in [HoloPlusEmblemTier.free, .plus] {
            let host = UIHostingController(rootView: HoloPlusEmblem(size: 36, tier: tier))
            let size = host.sizeThatFits(in: CGSize(width: 402, height: 160))
            XCTAssertEqual(size.width, 36, accuracy: 0.5)
            XCTAssertEqual(size.height, 36, accuracy: 0.5)
        }
    }

    func test_开启_能力请求断网提示具体原因且不进入控制流程() async {
        settings.disable()
        mock.capabilitiesError = APIError.networkUnavailable
        let outcome = await makeCoordinator().enable(selectedDomains: [.thought], confirmTakeoverIfOwnedByOtherDevice: false)
        XCTAssertEqual(outcome, .failed(.networkUnavailable))
        XCTAssertEqual(mock.controlCallCount, 0)
        XCTAssertFalse(settings.snapshot().isEnabled)
    }

    func test_开启_主动取消不误报为网络失败() async {
        settings.disable()
        mock.capabilitiesError = CancellationError()
        let outcome = await makeCoordinator().enable(selectedDomains: [.thought], confirmTakeoverIfOwnedByOtherDevice: false)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(mock.controlCallCount, 0)
        XCTAssertFalse(settings.snapshot().isEnabled)
    }

    func test_开启_控制读取失败保留具体原因() async {
        settings.disable()
        mock.controlError = APIError.timeout
        let outcome = await makeCoordinator().enable(selectedDomains: [.thought], confirmTakeoverIfOwnedByOtherDevice: false)
        XCTAssertEqual(outcome, .failed(.timeout))
        XCTAssertEqual(mock.enableCallCount, 0)
        XCTAssertFalse(settings.snapshot().isEnabled)
    }

    func test_开启_控制冲突不伪装为取消或成功() async {
        settings.disable()
        mock.enableError = APIError.backendError(statusCode: 409, code: "DISCOVERY_REVISION_CONFLICT", message: "Control revision mismatch", requestId: "test")
        let outcome = await makeCoordinator().enable(selectedDomains: [.thought], confirmTakeoverIfOwnedByOtherDevice: false)
        XCTAssertEqual(outcome, .failed(.conflict))
        XCTAssertFalse(settings.snapshot().isEnabled)
    }

    func test_开启_离线关闭后重开先补交关闭意图() async {
        let coordinator = makeCoordinator()
        mock.disableError = URLError(.notConnectedToInternet)
        await coordinator.disable()
        XCTAssertTrue(coordinator.isDisableIntentPending)
        mock.disableError = nil
        let outcome = await coordinator.enable(selectedDomains: [.thought], confirmTakeoverIfOwnedByOtherDevice: false)
        XCTAssertEqual(outcome, .enabled)
        XCTAssertFalse(coordinator.isDisableIntentPending)
        XCTAssertEqual(mock.disableCallCount, 2)
        XCTAssertTrue(settings.snapshot().isEnabled)
        await coordinator.batchTask?.value
    }

    func test_开启_已关闭的其他设备不要求无效接管() async {
        settings.disable()
        mock.controlEnabled = false
        mock.controlOwnerDeviceId = "device-other"
        let coordinator = makeCoordinator()
        let outcome = await coordinator.enable(selectedDomains: [.thought], confirmTakeoverIfOwnedByOtherDevice: false)
        XCTAssertEqual(outcome, .enabled)
        XCTAssertEqual(mock.enableCallCount, 1)
        await coordinator.batchTask?.value
    }

    func test_开启_服务端确认时已撤回总授权则回滚() async {
        settings.disable()
        var consent = true
        mock.onEnable = { consent = false }
        let coordinator = makeCoordinator(consentProvider: { consent })
        let outcome = await coordinator.enable(selectedDomains: [.thought], confirmTakeoverIfOwnedByOtherDevice: false)
        XCTAssertEqual(outcome, .needsGlobalConsent)
        XCTAssertFalse(settings.snapshot().isEnabled)
        XCTAssertEqual(mock.disableCallCount, 1)
        XCTAssertEqual(mock.createRunCallCount, 0)
    }
}
