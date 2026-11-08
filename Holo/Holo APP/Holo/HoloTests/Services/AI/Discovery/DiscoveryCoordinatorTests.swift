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
    /// 阶段失败注入（预算 429 等）：置位后 candidates 直接抛出，不再按 spec 构造
    var candidatesError: Error?
    /// 真实模型试评响应：按本批匿名 ID 对齐后走生产严格解码，不用人工构造的候选。
    var recordedSample: [String: Any]?
    private var asyncRequestData: [String: DiscoveryJSONValue] = [:]
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
            + asyncStartCallCount + asyncResultCallCount
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
            grant: .init(
                deviceId: "device-A",
                revision: controlRevisionValue,
                scopeRevision: 1,
                dayKey: "2026-10-23",
                leaseExpiresAt: 1_790_000_600
            ),
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
        if let candidatesError { throw candidatesError }
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

    // MARK: 1.1.5 候选异步作业

    var asyncEnabled = false
    /// 取件时先回几次 running 再给终态
    var asyncRunningPolls = 0
    /// 置位后作业以 failed 收尾
    var asyncFailure: (code: String, retryAvailable: Bool)?
    var asyncResultErrors: [Error] = []
    var asyncLeaseExpiresAt: Int64 = 1_790_086_400_000
    private(set) var asyncStartCallCount = 0
    private(set) var asyncResultCallCount = 0
    private var asyncPollsSoFar: [String: Int] = [:]

    func startCandidatesAsync(
        runID: String,
        runToken: String,
        requestID: String?,
        data: DiscoveryJSONValue
    ) async throws -> DiscoveryClient.CandidateJobPoll {
        asyncStartCallCount += 1
        guard asyncEnabled else { throw DiscoveryClient.DiscoveryClientError.asyncCandidatesUnsupported }
        asyncRequestData[runID] = data
        if asyncPollsSoFar[runID] == nil { asyncPollsSoFar[runID] = 0 }
        return try jobPoll(runID: runID, state: .running)
    }

    func candidatesResult(runID: String, runToken: String) async throws -> DiscoveryClient.CandidateJobPoll {
        asyncResultCallCount += 1
        if !asyncResultErrors.isEmpty { throw asyncResultErrors.removeFirst() }
        guard asyncEnabled else { throw DiscoveryClient.DiscoveryClientError.asyncCandidatesUnsupported }
        guard let soFar = asyncPollsSoFar[runID] else {
            throw APIError.backendError(statusCode: 404, code: "DISCOVERY_JOB_NOT_FOUND", message: "not found", requestId: nil)
        }
        if soFar < asyncRunningPolls {
            asyncPollsSoFar[runID] = soFar + 1
            return try jobPoll(runID: runID, state: .running)
        }
        return try jobPoll(runID: runID, state: asyncFailure == nil ? .completed : .failed)
    }

    private func jobPoll(runID: String, state: DiscoveryClient.CandidateJobStatus.JobState) throws -> DiscoveryClient.CandidateJobPoll {
        var completed: (response: DiscoveryClient.StageResponse, envelope: DiscoveryCandidateEnvelope)?
        if state == .completed {
            if let sample = recordedSample, let requestData = asyncRequestData[runID] {
                let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: DiscoveryCanonicalJSON.data(from: requestData)) as? [String: Any])
                let currentEvidence = try XCTUnwrap(request["evidence"] as? [[String: Any]])
                let originalEvidence = try XCTUnwrap(sample["evidence"] as? [[String: Any]])
                var mapping: [String: String] = [:]
                for original in originalEvidence {
                    let source = try XCTUnwrap(original["sourceBlock"] as? String)
                    let current = try XCTUnwrap(currentEvidence.first { ($0["sourceBlock"] as? String) == source })
                    mapping[try XCTUnwrap(original["evidenceID"] as? String)] = try XCTUnwrap(current["evidenceID"] as? String)
                }
                func remap(_ value: Any) -> Any {
                    if let object = value as? [String: Any] {
                        return object.mapValues { remap($0) }
                    }
                    if let array = value as? [Any] { return array.map(remap) }
                    if let string = value as? String { return mapping[string] ?? string }
                    return value
                }
                var candidateObject = try XCTUnwrap(remap(sample["candidates"]!) as? [String: Any])
                candidateObject["runID"] = runID
                var verificationObject = try XCTUnwrap(remap(sample["verification"]!) as? [String: Any])
                verificationObject["runID"] = runID
                let candidate = try DiscoveryAIPacket.decodeValidatedCandidateEnvelope(from: JSONSerialization.data(withJSONObject: candidateObject))
                verifyEnvelopeOverride = try DiscoveryAIPacket.decodeValidatedVerificationEnvelope(from: JSONSerialization.data(withJSONObject: verificationObject))
                let response = try Self.stageResponse(runID: runID, stage: "candidates", envelopeObject: candidateObject)
                completed = (response, candidate)
            } else {
            let envelope = DiscoveryFixtures.candidateEnvelope(runID: runID, quoteOverride: nil)
            let response = try Self.stageResponse(runID: runID, stage: "candidates", envelopeObject: [
                "schemaVersion": 1, "kind": "candidates", "runID": runID,
                "candidates": [DiscoveryFixtures.candidateObject(quoteOverride: nil)],
                "noFindingReason": "none",
            ])
            completed = (response, envelope)
            }
        }
        let status = DiscoveryClient.CandidateJobStatus(
            runID: runID,
            stage: "candidates",
            jobStatus: state,
            pollAfterSeconds: state == .running ? 3 : nil,
            leaseExpiresAt: asyncLeaseExpiresAt,
            result: completed?.response,
            error: state == .failed ? .init(code: asyncFailure?.code, reason: nil) : nil,
            retryAvailable: state == .failed ? (asyncFailure?.retryAvailable ?? false) : false,
            replayed: false
        )
        return DiscoveryClient.CandidateJobPoll(status: status, completed: completed)
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

    private var fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

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

    private func makeCoordinator(knowledgeRepository: CoreDataHoloMemoryRepository? = nil,
                                 consentProvider: @escaping () -> Bool = { true },
                                 pendingJobStore: DiscoveryPendingCandidateJobStore? = nil) -> DiscoveryCoordinator {
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
            sideStore: DiscoveryCoordinatorSideStore(defaults: defaults),
            knowledgeRepositoryProvider: knowledgeRepository.map { repository in { repository } },
            pendingJobStore: pendingJobStore,
            pollSleeper: { _ in }
        )
        Self.pinned.append(coordinator)
        return coordinator
    }

    private func makeKnowledgeRepository() throws -> CoreDataHoloMemoryRepository {
        let controller = try HoloMemoryPersistenceController(inMemory: true)
        Self.pinned.append(controller)
        return CoreDataHoloMemoryRepository(controller: controller)
    }

    private func currentFindingID(_ coordinator: DiscoveryCoordinator) -> String {
        if case .available(let id, _) = coordinator.presentationState { return id }
        return ""
    }

    func testRecordedFinancePreviewAndConfirmationShareOneKnowledgeRevision() async throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_794_012_000)
        let window = try XCTUnwrap(HoloRecordedPatternMiner.window(at: now, calendar: calendar))
        func expense(_ id: String, _ day: Int, expense: Bool = true) -> FinanceMemoryTransactionInput {
            .init(id: id, amount: 20, isExpense: expense, categoryID: "lunch", categoryName: "午餐", merchant: nil,
                  occurredAt: window.start.addingTimeInterval(Double(day) * 86_400), revisionDigest: "r-\(id)")
        }
        let sparse = [expense("one", 2), expense("two", 2), expense("three", 9)]
        XCTAssertTrue(HoloRecordedPatternMiner.finance(sparse, window: window, calendar: calendar).isEmpty)
        let proposal = try XCTUnwrap(HoloRecordedPatternMiner.finance(
            sparse + [expense("four", 10), expense("four", 10), expense("income", 12, expense: false), expense("outside", 28)],
            window: window, calendar: calendar
        ).first)
        let evidence = proposal.initialEvidenceSnapshot
        XCTAssertEqual(evidence.independentEventCount, 3)
        XCTAssertEqual(evidence.supportRefs.count, 4)
        XCTAssertEqual(evidence.completePeriods, 2)
        XCTAssertEqual(proposal.partition, .sensitiveLocal)

        let repository = try makeKnowledgeRepository()
        let snapshot = try await repository.knowledgeStoreSnapshot(propositionID: proposal.propositionID)
        XCTAssertTrue(snapshot.revisions.isEmpty, "预览不能提前写入记忆")
        let projected = try XCTUnwrap(snapshot.includingProposal(proposal, controlGeneration: 0, now: now).resolve(
            propositionID: proposal.propositionID, controlGeneration: 0, learningBaselineAt: nil, now: now
        ))
        XCTAssertTrue(DiscoveryMemoryReviewService.isReviewable(projected, allowed: [.finance], now: now))
        XCTAssertFalse(DiscoveryMemoryReviewService.isReviewable(projected, allowed: [.health], now: now))
        XCTAssertFalse(projected.decision.isUsableForAnswering)
        let request = HoloKnowledgeControlRequest(
            propositionID: proposal.propositionID, expectedSemanticDigest: proposal.semanticDigest,
            knownOperationIDs: [], action: .confirm, entry: "discovery", issuedAt: now
        )
        let control = HoloKnowledgeControlService(repository: repository)
        let rejected = try await control.apply(request, proposal: proposal, expectedEvidenceID: "stale")
        guard case .notAllowed = rejected else { return XCTFail("旧依据不可确认：\(rejected)") }
        let applied = try await control.apply(request, proposal: proposal, expectedEvidenceID: evidence.id)
        guard case .applied = applied else { return XCTFail("确认应当保存：\(applied)") }
        let loaded = try await repository.resolvedKnowledge(propositionID: proposal.propositionID, now: now)
        let remembered = try XCTUnwrap(loaded)
        XCTAssertEqual(remembered.decision, .confirmedValid)
        XCTAssertEqual(remembered.latestEvidenceSnapshot?.id, evidence.id)
        XCTAssertEqual(remembered.allowedUses, [.sourceLinkForPreciseQuery], "历史观察不提升为长期建议")
        XCTAssertFalse(DiscoveryMemoryReviewService.isReviewable(remembered, allowed: [.finance], now: now))
    }

    func testRecordedHealthUsesOnlyComparableWeeksAndShowsExceptionsInCount() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let window = try XCTUnwrap(HoloRecordedPatternMiner.window(
            at: Date(timeIntervalSince1970: 1_794_012_000), calendar: calendar
        ))
        let samples = (0..<27).map { offset in
            let day = window.start.addingTimeInterval(Double(offset) * 86_400)
            let value: Double = calendar.isDateInWeekend(day) ? (offset < 14 ? 3000 : 9500) : 6500
            return HoloRecordedPatternMiner.HealthDay(day: day, value: value)
        }
        let proposal = try XCTUnwrap(HoloRecordedPatternMiner.health(samples, metric: .steps, window: window, calendar: calendar))
        let evidence = proposal.initialEvidenceSnapshot
        XCTAssertEqual(proposal.partition, .sensitiveLocal)
        XCTAssertEqual(evidence.completePeriods, 3)
        XCTAssertEqual(evidence.independentEventCount, 21)
        XCTAssertTrue(evidence.statsSummary?.contains("2 / 3") == true)
        XCTAssertFalse(evidence.supportRefs.contains { $0.observedAt >= window.end.addingTimeInterval(-7 * 86_400) })
        XCTAssertNil(HoloRecordedPatternMiner.health(Array(samples.prefix(14)), metric: .steps, window: window, calendar: calendar))
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

    // MARK: - 重启恢复与预算重试（2026-10-30 首跑卡死修复）

    /// 事故回放：开启成功 → 首跑撞预算 429 → 重启。firstRunPending 仅存内存且无恢复，
    /// 三域变更事件又未接线 → 快路径永远吞掉前台触发，卡死「还在等足够的记录」。
    /// 修复=init 从「已开启 && 从未成功终态」推导恢复首跑待办。
    func test_首跑待办恢复_重启后开启且从未成功终态前台激活即发起首跑() async throws {
        // setUp 已 enable；无 processedRecord = 从未成功终态
        let coordinator = makeCoordinator()   // 模拟新进程

        coordinator.runBatch(reason: .foregroundActivation)   // 无 dirty marks 的前台激活
        await coordinator.batchTask?.value

        XCTAssertEqual(mock.createRunCallCount, 1, "首跑待办从持久化事实恢复：不等（尚未接线的）变更事件")
        XCTAssertNotEqual(coordinator.presentationState, .waitingForMaterial, "不得再卡「还在等足够的记录」")
    }

    /// 已成功终态的账号重启后不得误恢复首跑（首跑待办恢复只针对从未跑完的）。
    func test_首跑待办恢复_已有成功终态不误恢复() async throws {
        let sideStore = DiscoveryCoordinatorSideStore(defaults: defaults)
        sideStore.recordProcessed(digest: "done-digest", policyVersion: 1, promptVersion: 1, at: fixedNow)

        let coordinator = makeCoordinator()
        coordinator.runBatch(reason: .foregroundActivation)
        await coordinator.batchTask?.value

        XCTAssertEqual(mock.createRunCallCount, 0, "已有成功终态且同日：快路径拦截，零网络")
    }

    /// 「每天一个发现」的日历资格：跨自然日后第一次前台激活放行完整决策，
    /// 由扫描自比 manifestDigest 决定重跑；同一天再次激活被快路径拦截。
    func test_跨天资格_昨日成功终态新一天首查放行同日拦截() async throws {
        let sideStore = DiscoveryCoordinatorSideStore(defaults: defaults)
        // 昨天 noFinding 终态，digest 与今日材料不同（今日材料变了才值得重跑）
        sideStore.recordProcessed(digest: "yesterday-digest", policyVersion: 1, promptVersion: 1,
                                  at: fixedNow.addingTimeInterval(-86400))

        let coordinator = makeCoordinator()
        coordinator.runBatch(reason: .foregroundActivation)
        await coordinator.batchTask?.value
        XCTAssertEqual(mock.createRunCallCount, 1, "跨自然日：快路径放行进完整决策")

        // 上一批成功终态把 processedAt 刷成今天 → 同日再激活走快路径，零网络
        coordinator.runBatch(reason: .foregroundActivation)
        await coordinator.batchTask?.value
        XCTAssertEqual(mock.createRunCallCount, 1, "同日无变更：快路径拦截，不重复发起")
    }

    /// 预算 429 后：状态如实显示「暂未更新」（不误报材料不足），且窗口恢复的重试已排定。
    func test_预算超限_429后状态paused且排定窗口重试() async throws {
        mock.candidatesError = APIError.rateLimited("后台整理额度已用完")
        let coordinator = makeCoordinator()
        coordinator.runBatch(reason: .foregroundActivation)
        await coordinator.batchTask?.value

        XCTAssertEqual(mock.candidatesCallCount, 1, "candidates 被调且撞预算 429")
        XCTAssertEqual(coordinator.presentationState, .temporarilyUnavailable, "预算态如实显示，不误报「记录还不够」")
        XCTAssertNotNil(coordinator.retryTask, "预算窗口恢复后的自动重试已排定（此前只关当日不排重试）")
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
    // MARK: - 记忆联动（v2.2 §6.1 / 融合契约；场景 D01–D05/D14/D18）

    func test_联动_发布时写claim关联_两次经历不达记忆门槛不显示保存按钮() async throws {
        let repository = try makeKnowledgeRepository()
        let coordinator = makeCoordinator(knowledgeRepository: repository)
        await runOneBatch(coordinator)
        guard let record = try store.activeFinding(now: fixedNow) else { return XCTFail("前置：已发布") }

        let linkages = try store.claimLinkages(findingID: record.id)
        XCTAssertEqual(linkages.map(\.claimID).sorted(), ["K1", "K2"], "每个 claim 一条版本化关联（D17 精确到结论）")
        XCTAssertTrue(linkages.allSatisfy { $0.propositionID.hasPrefix("holo-prop-") && !$0.semanticDigest.isEmpty })
        XCTAssertNotEqual(linkages[0].propositionID, linkages[1].propositionID, "不同 claim 不同命题")
        XCTAssertTrue(linkages.allSatisfy { $0.evidenceSnapshot.templateID == nil }, "D01 两次经历不是规律模板")
        XCTAssertTrue(linkages.allSatisfy { $0.evidenceSnapshot.supportRefs.allSatisfy { $0.sourceDomain == .thought } }, "来源仅想法域")

        let state = await coordinator.knowledgeSaveState(for: currentFindingID(coordinator))
        XCTAssertEqual(state, .notEligible, "D01 未达记忆门槛：不显示不能兑现的保存按钮")
        let outcome = await coordinator.confirmAndRemember(findingID: currentFindingID(coordinator), claimID: "K1")
        XCTAssertFalse(outcome.isSuccess, "两次经历不能越级保存为规律")
        let snapshot = try await repository.knowledgeStoreSnapshot()
        XCTAssertFalse(snapshot.operations.contains { $0.kind == .confirm }, "没有确认操作")
    }

    func test_联动_有点像只写提示记录_不建知识不增样本() async throws {
        let repository = try makeKnowledgeRepository()
        let coordinator = makeCoordinator(knowledgeRepository: repository)
        await runOneBatch(coordinator)
        _ = coordinator.openFinding()

        await coordinator.submitFeedback(.accurate)

        let snapshot = try await repository.knowledgeStoreSnapshot()
        XCTAssertTrue(snapshot.revisions.isEmpty, "D01 有点像不暗中保存")
        let prompts = snapshot.operations.filter { $0.kind == .promptRecord }
        XCTAssertEqual(prompts.count, 2, "每个 claim 一条轻反馈提示记录")
        XCTAssertTrue(prompts.allSatisfy { op in
            if case .promptRecord(let entry, _, let outcome) = op.payload { return entry == "discovery" && outcome == "acknowledged" }
            return false
        })
        XCTAssertTrue(snapshot.operations.filter { $0.kind.isUsageRestricting || $0.kind == .confirm }.isEmpty, "无确认无限制")
        XCTAssertNotNil(try store.activeFinding(now: fixedNow), "有点像不撤下")
    }

    func test_联动_理解不对立即撤下并写最低否定_同义不再推荐() async throws {
        let repository = try makeKnowledgeRepository()
        let coordinator = makeCoordinator(knowledgeRepository: repository)
        await runOneBatch(coordinator)
        guard let record = try store.activeFinding(now: fixedNow) else { return XCTFail("前置：已发布") }
        let linkages = try store.claimLinkages(findingID: record.id)
        _ = coordinator.openFinding()

        await coordinator.submitFeedback(.inaccurate(reason: .wrongUnderstanding))

        XCTAssertNil(try store.activeFinding(now: fixedNow), "D05 首次点击立即撤下")
        let snapshot = try await repository.knowledgeStoreSnapshot()
        let inaccurate = snapshot.operations.filter { $0.kind == .markInaccurate }
        XCTAssertEqual(inaccurate.count, linkages.count, "每个关联 claim 一条准确范围的最低否定（不封禁整个主题）")
        XCTAssertEqual(Set(inaccurate.compactMap(\.targetSemanticDigest)), Set(linkages.map(\.semanticDigest)), "否定绑定准确语义指纹")
        XCTAssertTrue(snapshot.revisions.isEmpty, "否定不需要先把错误理解写成修订")

        // D18/D04：同一准确语义再被生成时，发布门禁按知识侧限制排除（不换入口复活）
        for linkage in linkages {
            let blocked = await DiscoveryCoordinator.hasStandaloneBlock(
                repository: repository, propositionID: linkage.propositionID,
                digest: linkage.semanticDigest, now: fixedNow
            )
            XCTAssertTrue(blocked, "被否定语义在发布去重中命中")
        }
        let reworded = await DiscoveryCoordinator.hasStandaloneBlock(
            repository: repository, propositionID: linkages[0].propositionID,
            digest: "sd-other-version", now: fixedNow
        )
        XCTAssertFalse(reworded, "否定只阻断该准确语义版本，不封禁整个主题")
        XCTAssertEqual(coordinator.presentationState, .waitingForMaterial)
    }

    func test_联动_现在不适用收窄范围_暂时不说只记冷却() async throws {
        let repository = try makeKnowledgeRepository()
        let coordinator = makeCoordinator(knowledgeRepository: repository)
        await runOneBatch(coordinator)
        _ = coordinator.openFinding()

        await coordinator.recordMinimalDeference(findingID: currentFindingID(coordinator))
        var snapshot = try await repository.knowledgeStoreSnapshot()
        let deferred = snapshot.operations.filter { $0.kind == .deferCooldown }
        XCTAssertEqual(deferred.count, 2, "暂时不说：每个 claim 一条冷却（不构成认可/否定）")
        XCTAssertTrue(snapshot.operations.filter { $0.kind.isUsageRestricting }.isEmpty, "暂时不说不是限制")
        XCTAssertNotNil(try store.activeFinding(now: fixedNow), "暂时不说不撤下发现本身")
        XCTAssertFalse(coordinator.isDetailPresented)

        // 冷却期内同语义不再作为新发现（D03 共用冷却）
        let cooled = await DiscoveryCoordinator.hasStandaloneBlock(
            repository: repository, propositionID: deferred[0].propositionID,
            digest: deferred[0].targetSemanticDigest ?? "", now: fixedNow
        )
        XCTAssertTrue(cooled, "暂缓的语义版本在冷却期内不再主动推荐")
        let afterCooldown = await DiscoveryCoordinator.hasStandaloneBlock(
            repository: repository, propositionID: deferred[0].propositionID,
            digest: deferred[0].targetSemanticDigest ?? "", now: fixedNow.addingTimeInterval(31 * 86_400)
        )
        XCTAssertFalse(afterCooldown, "冷却到期后可再评估")

        _ = coordinator.openFinding()
        await coordinator.submitFeedback(.inaccurate(reason: .notApplicableNow))
        snapshot = try await repository.knowledgeStoreSnapshot()
        XCTAssertEqual(snapshot.operations.filter { $0.kind == .narrowScope }.count, 2, "现在不适用 → 收窄范围，保留历史")
        XCTAssertNil(try store.activeFinding(now: fixedNow), "撤下当前呈现")
    }

    func test_联动_记忆侧限制后发现撤下() async throws {
        let repository = try makeKnowledgeRepository()
        let coordinator = makeCoordinator(knowledgeRepository: repository)
        await runOneBatch(coordinator)
        guard let record = try store.activeFinding(now: fixedNow),
              let linkage = try store.claimLinkages(findingID: record.id).first else { return XCTFail("前置：已发布") }

        // 用户在记忆侧（另一入口）否定同一准确语义
        let service = HoloKnowledgeControlService(repository: repository)
        let outcome = try await service.apply(HoloKnowledgeControlRequest(
            operationID: "mc-inaccurate", propositionID: linkage.propositionID,
            expectedSemanticDigest: linkage.semanticDigest, knownOperationIDs: [],
            action: .markInaccurate(reason: nil, scope: .understanding), entry: "memoryCenter", issuedAt: fixedNow
        ))
        XCTAssertTrue(outcome.isSuccess)

        // 通知经 MainActor Task 投递：让出几次运行循环
        for _ in 0..<20 where (try? store.activeFinding(now: fixedNow)) != nil {
            await Task.yield()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(try store.activeFinding(now: fixedNow), "D04 记忆侧纠正/判错 → 引用旧语义的发现撤下")
    }

    func test_联动_不想看这类只是展示偏好_不写知识否定() async throws {
        let repository = try makeKnowledgeRepository()
        let coordinator = makeCoordinator(knowledgeRepository: repository)
        await runOneBatch(coordinator)
        _ = coordinator.openFinding()

        await coordinator.submitFeedback(.inaccurate(reason: .notInterested))

        let snapshot = try await repository.knowledgeStoreSnapshot()
        XCTAssertTrue(snapshot.operations.filter { $0.kind.isUsageRestricting }.isEmpty, "D06 不想再提示 ≠ 事实否定")
        XCTAssertNil(try store.activeFinding(now: fixedNow), "但当前呈现停止")
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

    // MARK: - 1.1.5 候选异步作业（服务端缓存候选 → 手机取件 → 本机找反例 → 核验）

    private func tempPendingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-pending-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("pending-candidate-job.json")
    }

    private func makePendingStore(_ url: URL) -> DiscoveryPendingCandidateJobStore {
        let pending = DiscoveryPendingCandidateJobStore(fileURL: url)
        Self.pinned.append(pending)
        return pending
    }

    func test_异步_交材料即返回_前台取件后本机门禁反例核验并发布() async throws {
        mock.asyncEnabled = true
        mock.asyncRunningPolls = 2
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)

        XCTAssertEqual(mock.createRunCallCount, 1)
        XCTAssertEqual(mock.asyncStartCallCount, 1)
        XCTAssertEqual(mock.asyncResultCallCount, 3, "running×2 → completed")
        XCTAssertEqual(mock.candidatesCallCount, 0, "异步可用时不走同步候选端点（服务端两路不混用）")
        XCTAssertEqual(mock.verifyCallCount, 1, "取到候选后照常本机门禁+反例召回+核验")
        guard case .available = coordinator.presentationState else {
            return XCTFail("发布后应为 available，实际 \(coordinator.presentationState)")
        }
        XCTAssertEqual(try store.runState(runID: mock.createdRunIDs[0])?.phase, .ready)
    }

    func test_异步_App被回收后重启_凭本机缓存接着取件_不重开run不另占名额() async throws {
        let url = tempPendingURL()
        mock.asyncEnabled = true
        mock.asyncRunningPolls = 10_000   // 本次前台一直没等到
        let first = makeCoordinator(pendingJobStore: makePendingStore(url))
        await runOneBatch(first)
        first.retryTask?.cancel()

        let runID = try XCTUnwrap(mock.createdRunIDs.first)
        XCTAssertEqual(mock.asyncStartCallCount, 1)
        XCTAssertEqual(mock.verifyCallCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "未取到候选：取件缓存落盘")
        XCTAssertEqual(try store.runState(runID: runID)?.phase, .preparing)
        XCTAssertEqual(first.presentationState, .preparing, "如实显示「正在准备」")

        // 进程被回收后重启：新协调器 + 新槽位实例读同一文件；服务端此时已算完
        mock.asyncRunningPolls = 0
        let second = makeCoordinator(pendingJobStore: makePendingStore(url))
        XCTAssertEqual(try store.runState(runID: runID)?.phase, .preparing, "待取件的 run 不被 T41 冷启动误关")
        second.runBatch(reason: .refresh)
        await second.batchTask?.value

        XCTAssertEqual(mock.createRunCallCount, 1, "续取不重开 run（不另占名额）")
        XCTAssertEqual(mock.asyncStartCallCount, 1, "续取不重交材料")
        XCTAssertEqual(mock.verifyCallCount, 1)
        guard case .available = second.presentationState else {
            return XCTFail("续取后应发布，实际 \(second.presentationState)")
        }
        XCTAssertEqual(try store.runState(runID: runID)?.phase, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "run 终态后取件缓存即删")
    }

    func test_异步_服务端判可重试失败_不关当日闸_下一批照常开() async throws {
        mock.asyncEnabled = true
        mock.asyncFailure = ("DISCOVERY_MODEL_OUTPUT_INVALID", true)
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)
        XCTAssertNotNil(coordinator.retryTask, "可重试失败排定稍后重试")
        coordinator.retryTask?.cancel()
        XCTAssertEqual(coordinator.settingsDetailState, .failed(reason: .service, retry: .soon),
                       "1.1.5：服务端原因失败如实显示「没整理成功，之后再试」，不再是「还在等足够的记录」")
        XCTAssertEqual(mock.verifyCallCount, 0)
        XCTAssertEqual(try store.runState(runID: mock.createdRunIDs[0])?.phase, .backoff)

        mock.asyncFailure = nil
        await runOneBatch(coordinator, digest: "digest-2")
        XCTAssertEqual(mock.createRunCallCount, 2, "失败不烧名额：同日下一批照常开 run")
        XCTAssertEqual(mock.verifyCallCount, 1)
        guard case .available = coordinator.presentationState else {
            return XCTFail("重试后应发布，实际 \(coordinator.presentationState)")
        }
    }

    func test_异步_服务端判不可重试_本机关当日闸() async throws {
        mock.asyncEnabled = true
        mock.asyncFailure = ("DISCOVERY_MODEL_OUTPUT_INVALID", false)
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)
        coordinator.retryTask?.cancel()
        XCTAssertEqual(coordinator.settingsDetailState, .failed(reason: .service, retry: .tomorrow))

        mock.asyncFailure = nil
        await runOneBatch(coordinator, digest: "digest-2")
        XCTAssertEqual(mock.createRunCallCount, 1, "服务端说当天次数用完：不再开 run")
        coordinator.retryTask?.cancel()
    }

    func test_服务端不支持异步_回落同步端点全链照常() async throws {
        let coordinator = makeCoordinator()   // 替身 asyncEnabled=false
        await runOneBatch(coordinator)

        XCTAssertEqual(mock.asyncStartCallCount, 1, "先探测异步")
        XCTAssertEqual(mock.candidatesCallCount, 1, "不支持即回落同步")
        XCTAssertEqual(mock.verifyCallCount, 1)
        guard case .available = coordinator.presentationState else {
            return XCTFail("回落同步后应发布，实际 \(coordinator.presentationState)")
        }
    }

    func test_异步_等待取件时关闭发现_取件缓存即删() async throws {
        let url = tempPendingURL()
        mock.asyncEnabled = true
        mock.asyncRunningPolls = 10_000
        let coordinator = makeCoordinator(pendingJobStore: makePendingStore(url))
        await runOneBatch(coordinator)
        coordinator.retryTask?.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await coordinator.disable()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "取件缓存属派生数据，关闭即删")
    }

    @MainActor
    func test_契约_候选作业三态按后端字面量解码_缓存结构不认识即丢弃() throws {
        // 字面量逐字抄 HoloBackend/src/discovery/discoveryController.js jobStatusResponse
        let running = #"{"runID":"r1","stage":"candidates","jobStatus":"running","pollAfterSeconds":3,"leaseExpiresAt":1790086400000,"result":null,"error":null,"retryAvailable":false,"replayed":false}"#
        let failed = #"{"runID":"r1","stage":"candidates","jobStatus":"failed","pollAfterSeconds":null,"leaseExpiresAt":1790086400000,"result":null,"error":{"code":"DISCOVERY_MODEL_OUTPUT_INVALID","reason":"time_range_value"},"retryAvailable":true,"replayed":false}"#
        let completed = #"{"runID":"r1","stage":"candidates","jobStatus":"completed","pollAfterSeconds":null,"leaseExpiresAt":1790086400000,"result":{"runID":"r1","stage":"candidates","envelope":{"schemaVersion":1,"kind":"candidates","runID":"r1","candidates":[],"noFindingReason":"no_material"},"promptType":"discovery_candidate_v1","promptVersion":1,"replayed":false,"candidatesHash":"abc"},"error":null,"retryAvailable":false,"replayed":true}"#
        let decoder = JSONDecoder()
        let r = try decoder.decode(DiscoveryClient.CandidateJobStatus.self, from: Data(running.utf8))
        XCTAssertEqual(r.jobStatus, .running)
        XCTAssertEqual(r.pollAfterSeconds, 3)
        XCTAssertNil(r.result)
        let f = try decoder.decode(DiscoveryClient.CandidateJobStatus.self, from: Data(failed.utf8))
        XCTAssertEqual(f.jobStatus, .failed)
        XCTAssertEqual(f.error?.code, "DISCOVERY_MODEL_OUTPUT_INVALID")
        XCTAssertEqual(f.error?.reason, "time_range_value")
        XCTAssertTrue(f.retryAvailable)
        let c = try decoder.decode(DiscoveryClient.CandidateJobStatus.self, from: Data(completed.utf8))
        XCTAssertEqual(c.jobStatus, .completed)
        XCTAssertEqual(c.result?.runID, "r1")
        XCTAssertEqual(c.result?.candidatesHash, "abc")
        XCTAssertEqual(c.leaseExpiresAt, 1_790_086_400_000)

        // 本机缓存结构不认识（版本升级/损坏）：丢弃，不阻塞后续批次
        let url = tempPendingURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":99}"#.utf8).write(to: url)
        let pending = makePendingStore(url)
        XCTAssertNil(pending.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 1.1.5 设置页状态拆分（整理过了 / 没整理成功 / 材料不够）

    func test_云端发现_轻度温升仍可提交_严重温升才让位() {
        XCTAssertFalse(DiscoveryEnvironmentProvider.shouldYield(for: .nominal))
        XCTAssertFalse(DiscoveryEnvironmentProvider.shouldYield(for: .fair))
        XCTAssertTrue(DiscoveryEnvironmentProvider.shouldYield(for: .serious))
        XCTAssertTrue(DiscoveryEnvironmentProvider.shouldYield(for: .critical))
    }

    func test_资源让位后自动补查_不用用户再切前后台() async throws {
        var snapshot = DiscoveryResourceSnapshot()
        snapshot.isThermallyConstrained = true
        resourceBox.value = snapshot
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)
        XCTAssertEqual(mock.totalNetworkCalls, 0, "让位时不发送材料")
        XCTAssertNotNil(coordinator.retryTask, "资源恢复后必须有自动补查")
        coordinator.retryTask?.cancel()

        snapshot.isThermallyConstrained = false
        resourceBox.value = snapshot
        coordinator.runBatch(reason: .retry)
        await coordinator.batchTask?.value
        XCTAssertNotNil(try store.activeFinding(now: fixedNow), "补查可完成发布")
    }

    func test_异步取件断网_重启后继续原批次并能阅读依据续聊() async throws {
        let url = tempPendingURL()
        mock.asyncEnabled = true
        mock.asyncResultErrors = [APIError.networkUnavailable]
        let first = makeCoordinator(pendingJobStore: makePendingStore(url))
        await runOneBatch(first)
        first.retryTask?.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "断网保留取件凭据与已授权材料")
        XCTAssertEqual(mock.createRunCallCount, 1)

        let relaunched = makeCoordinator(pendingJobStore: makePendingStore(url))
        relaunched.runBatch(reason: .foregroundActivation)
        await relaunched.batchTask?.value
        XCTAssertEqual(mock.createRunCallCount, 1, "恢复不重新占用当天名额")
        XCTAssertEqual(mock.asyncStartCallCount, 1, "恢复不重复提交模型任务")
        let finding = try XCTUnwrap(relaunched.openFinding())
        XCTAssertFalse(finding.citations.isEmpty)
        XCTAssertFalse(finding.displayQuotes.isEmpty)
        let draft = try XCTUnwrap(relaunched.buildConversationDraft())
        XCTAssertEqual(draft.findingID, finding.findingID)
        let canSend = await relaunched.validateConversationDraftForSend(findingID: finding.findingID)
        XCTAssertTrue(canSend)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "发布后清除临时材料")
    }

    func test_真实模型试评JSON_异步取件到本机落库与阅读续聊完整通过() async throws {
        try await assertRecordedSamplePublishes(
            fileName: "sample-input.json",
            expectedBody: ["在十月八日和十六日，你分别选择了散步和翻书作为起步动作。"]
        )
    }

    func test_当前Qwen实时样本_完整协调器发布阅读依据与续聊通过() async throws {
        try await assertRecordedSamplePublishes(
            fileName: "fresh-model-input.json",
            expectedBody: ["第一次是十月八日去散步，第二次是十月十六日去阅读。",
                           "两次行动都明确排除了完成完整任务的要求。"]
        )
    }

    private func assertRecordedSamplePublishes(fileName: String, expectedBody: [String]) async throws {
        // 真源是上一轮已展示的 Qwen r22/F01 原始生成及核验，不是 verifyEval 的人工候选。
        // fresh-model-input 则是 2026-11-05 同生产配置的独立内存库实时调用，不触碰个人记录。
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 { repo.deleteLastPathComponent() }
        let path = repo.appendingPathComponent("docs/_common/plans/2026-11-05-一个发现诊断与效果验证/\(fileName)")
        let sample = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let sourceEvidence = try XCTUnwrap(sample["evidence"] as? [[String: Any]])
        let iso = ISO8601DateFormatter()
        fixedNow = try XCTUnwrap(iso.date(from: "2026-11-05T00:00:00+08:00"))
        adapter.snapshots = try sourceEvidence.map { item in
            let id = try XCTUnwrap(item["evidenceID"] as? String)
            let text = try XCTUnwrap(item["sourceBlock"] as? String)
            let occurred = try XCTUnwrap(iso.date(from: try XCTUnwrap(item["recordedAt"] as? String)))
            return thoughtSnapshot(id: id, text: text, daysAgo: fixedNow.timeIntervalSince(occurred) / 86400, refs: ["tag:重新开始"])
        }
        mock.asyncEnabled = true
        mock.recordedSample = sample
        mock.asyncLeaseExpiresAt = Int64(fixedNow.addingTimeInterval(86400).timeIntervalSince1970 * 1000)
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)
        XCTAssertEqual(mock.createRunCallCount, 1)
        XCTAssertEqual(mock.asyncStartCallCount, 1)
        XCTAssertEqual(mock.candidatesCallCount, 0, "真实样本通过异步接口，不回落长请求")
        XCTAssertEqual(mock.verifyCallCount, 1)
        let record = try XCTUnwrap(store.activeFinding(now: fixedNow))
        XCTAssertEqual(record.payload.title, "这两次重新开始，你都把第一步变轻了。")
        XCTAssertEqual(record.payload.body, expectedBody)
        let finding = try XCTUnwrap(coordinator.openFinding())
        XCTAssertEqual(Set(finding.citations.compactMap(\.sourceRef)).count, 2)
        let draft = try XCTUnwrap(coordinator.buildConversationDraft())
        XCTAssertTrue(draft.findingSummary.contains(record.payload.body[0]))
        let canSend = await coordinator.validateConversationDraftForSend(findingID: finding.findingID)
        XCTAssertTrue(canSend)
    }

    func test_状态拆分_空候选后显示今天整理过了_重启后不丢() async throws {
        mock.candidatesSpec = .empty
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)
        XCTAssertEqual(coordinator.settingsDetailState, .checkedNoFinding(checkedAt: fixedNow),
                       "跑完无合格：不再显示「还在等足够的记录」")
        XCTAssertEqual(coordinator.presentationState, .waitingForMaterial, "胶囊口径不变（无胶囊）")

        // 模拟 App 重启：同一份本机侧储重建协调器（内存态全丢），回前台后仍如实显示
        let relaunched = makeCoordinator()
        relaunched.runBatch(reason: .foregroundActivation)
        await relaunched.batchTask?.value
        XCTAssertEqual(relaunched.settingsDetailState, .checkedNoFinding(checkedAt: fixedNow), "重启后结局不丢")
    }

    func test_状态拆分_预算429显示今天次数已用完() async throws {
        mock.candidatesError = APIError.rateLimited("后台整理额度已用完")
        let coordinator = makeCoordinator()
        coordinator.runBatch(reason: .foregroundActivation)
        await coordinator.batchTask?.value
        coordinator.retryTask?.cancel()
        XCTAssertEqual(coordinator.settingsDetailState, .failed(reason: .dailyLimit, retry: .tomorrow))
    }

    func test_状态拆分_断网显示没整理成功会再试() async throws {
        var snapshot = DiscoveryResourceSnapshot()
        snapshot.isNetworkAvailable = false
        resourceBox.value = snapshot
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)
        coordinator.retryTask?.cancel()
        XCTAssertEqual(coordinator.settingsDetailState, .failed(reason: .network, retry: .soon))
    }

    func test_状态拆分_当天已整理过_次数用完仍显示整理过了() async throws {
        let checkedAt = fixedNow.addingTimeInterval(-3600)   // 同一自然日（上海 21:13）
        DiscoveryCoordinatorSideStore(defaults: defaults).recordLastOutcome(.noFinding(at: checkedAt))
        mock.candidatesError = APIError.rateLimited("后台整理额度已用完")
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)
        coordinator.retryTask?.cancel()
        XCTAssertEqual(coordinator.settingsDetailState, .checkedNoFinding(checkedAt: checkedAt),
                       "「今天整理过了」比「次数已用完」更有信息量，不被覆盖")
    }

    func test_状态拆分_映射优先级与跨天() {
        let yesterday = fixedNow.addingTimeInterval(-86_400)
        XCTAssertEqual(
            DiscoveryCoordinator.settingsDetail(findingRecentlyLost: false,
                                                lastOutcome: .failed(.service, retry: .tomorrow, at: yesterday),
                                                now: fixedNow, calendar: shanghaiCalendar),
            .waitingForMaterial, "前一天的失败不再显示（避免过期的「明天再试」）")
        XCTAssertEqual(
            DiscoveryCoordinator.settingsDetail(findingRecentlyLost: false,
                                                lastOutcome: .noFinding(at: yesterday),
                                                now: fixedNow, calendar: shanghaiCalendar),
            .checkedNoFinding(checkedAt: yesterday), "「整理过了」跨天仍显示，带日期")
        XCTAssertEqual(
            DiscoveryCoordinator.settingsDetail(findingRecentlyLost: true,
                                                lastOutcome: .noFinding(at: fixedNow),
                                                now: fixedNow, calendar: shanghaiCalendar),
            .stale, "刚失去发现时优先说明「等待新的线索」")
        XCTAssertEqual(
            DiscoveryCoordinator.settingsDetail(findingRecentlyLost: false, lastOutcome: nil,
                                                now: fixedNow, calendar: shanghaiCalendar),
            .waitingForMaterial)
    }

    func test_状态拆分_关闭后清除结局() async throws {
        mock.candidatesSpec = .empty
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)
        XCTAssertNotNil(DiscoveryCoordinatorSideStore(defaults: defaults).lastOutcome)
        await coordinator.disable()
        XCTAssertNil(DiscoveryCoordinatorSideStore(defaults: defaults).lastOutcome, "关闭即删派生的结局状态")
    }

    func test_状态拆分_升级前跑完的批次_启动时从运行记录回填整理过了() async throws {
        mock.candidatesSpec = .empty
        let coordinator = makeCoordinator()
        await runOneBatch(coordinator)
        // 模拟升级前：批次已跑完（运行记录 noFinding），但旧版本没有写结局记录
        DiscoveryCoordinatorSideStore(defaults: defaults).clearLastOutcome()

        let upgraded = makeCoordinator()
        upgraded.runBatch(reason: .foregroundActivation)
        await upgraded.batchTask?.value
        XCTAssertEqual(upgraded.settingsDetailState, .checkedNoFinding(checkedAt: fixedNow),
                       "升级后首次启动即如实显示，不必等下一次整理")
    }

    func test_状态拆分_文案可区分() {
        let now = fixedNow
        let copy = DiscoverySettingsCopy.self
        XCTAssertEqual(copy.statusText(for: .checkedNoFinding(checkedAt: now), now: now, calendar: shanghaiCalendar), "今天整理过了")
        XCTAssertEqual(copy.statusText(for: .checkedNoFinding(checkedAt: now.addingTimeInterval(-86_400)), now: now, calendar: shanghaiCalendar), "昨天整理过了")
        XCTAssertEqual(copy.statusText(for: .checkedNoFinding(checkedAt: now.addingTimeInterval(-3 * 86_400)), now: now, calendar: shanghaiCalendar), "9月18日整理过了")
        XCTAssertEqual(copy.statusText(for: .failed(reason: .service, retry: .soon)), "这次没整理成功")
        XCTAssertEqual(copy.statusText(for: .failed(reason: .service, retry: .tomorrow)), "今天没整理成功")
        XCTAssertEqual(copy.statusText(for: .failed(reason: .dailyLimit, retry: .tomorrow)), "今天的整理次数已用完")
        XCTAssertEqual(copy.statusText(for: .waitingForMaterial), "还在等足够的记录")
        XCTAssertEqual(copy.statusText(for: .preparing), "正在整理")
        // 每种失败原因都有各自的说明，且都不要求用户操作
        for reason in [DiscoveryLastOutcome.FailureReason.network, .service, .dailyLimit] {
            let detail = copy.statusDetailText(for: .failed(reason: reason, retry: .soon))
            XCTAssertTrue(detail.contains("自动"), "\(reason) 说明需告知会自动再试：\(detail)")
        }
    }
}
