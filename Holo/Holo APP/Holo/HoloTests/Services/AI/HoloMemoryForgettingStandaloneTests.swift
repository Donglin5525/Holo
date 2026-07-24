import Foundation

actor FakeHoloMemoryForgettingStore: HoloMemoryForgettingStore {
    var records: [String: HoloMemoryRecord]
    var tombstones: [HoloMemoryTombstone] = []
    var controlState = HoloMemoryControlState.initial(now: Date(timeIntervalSince1970: 0))

    init(records: [HoloMemoryRecord]) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func fetch(id: String) async throws -> HoloMemoryRecord? { records[id] }
    func query(_ query: HoloMemoryRepositoryQuery) async throws -> [HoloMemoryRecord] {
        Array(records.values)
    }
    func markUserDecision(
        id: String,
        decision: HoloMemoryUserDecision,
        now: Date
    ) async throws -> Bool {
        guard var record = records[id] else { return false }
        record.userDecision = decision
        record.state = decision == .forgotten ? .tombstoned : record.state
        if decision == .forgotten {
            record.displaySummary = ""
            record.aiUseSummary = ""
            record.evidenceRefs = []
            record.counterEvidenceRefs = []
        }
        record.updatedAt = now
        records[id] = record
        return true
    }
    func loadControlState() async throws -> HoloMemoryControlState { controlState }
    func saveControlState(_ state: HoloMemoryControlState) async throws { controlState = state }
    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws { tombstones.append(tombstone) }
    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws {
        records[record.id] = record
    }

    func snapshot() -> ([HoloMemoryRecord], [HoloMemoryTombstone], HoloMemoryControlState) {
        (Array(records.values), tombstones, controlState)
    }
}

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryForgettingStandaloneTests.main()
    }
}
#endif
struct HoloMemoryForgettingStandaloneTests {
    private static var assertions = 0

    static func main() async throws {
        try testSemanticTombstoneMatching()
        try await testForgetScrubsOriginalText()
        try await testClearAllAndExplicitHistoricalRescan()
        try await testSourceRevisionInvalidatesDependentMemory()
        print("HoloMemoryForgettingStandaloneTests: \(assertions) assertions passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    private static func testSemanticTombstoneMatching() throws {
        let anchor = try HoloMemoryAnchorRef(type: .habit, value: "late sleep")
        let tombstone = HoloMemoryTombstone(
            identityKey: "forgotten",
            scope: .domain,
            claimKind: .recurringPattern,
            anchorKeys: [anchor.stableKey],
            userDecisionVersion: 1,
            createdAt: Date()
        )

        expect(HoloSemanticTombstoneMatcher.matches(
            tombstone: tombstone,
            scope: .domain,
            claimKind: .phaseShift,
            anchors: [anchor]
        ), "相同锚点与同一 claim family 的候选必须被永久忘记规则拦截")
        expect(!HoloSemanticTombstoneMatcher.matches(
            tombstone: tombstone,
            scope: .domain,
            claimKind: .association,
            anchors: [anchor]
        ), "不同 claim family 不应被过度屏蔽")
    }

    private static func testForgetScrubsOriginalText() async throws {
        let record = try makeRecord(anchorValue: "late-sleep", sourceID: "habit-1")
        let store = FakeHoloMemoryForgettingStore(records: [record])
        let service = HoloMemoryForgettingService(store: store)
        let didForget = try await service.forget(id: record.id, now: Date(timeIntervalSince1970: 20))
        let snapshot = await store.snapshot()

        expect(didForget, "存在的记忆应可被永久忘记")
        expect(snapshot.1.count == 1, "永久忘记必须建立语义墓碑")
        expect(snapshot.0.first?.displaySummary.isEmpty == true, "忘记后必须清除展示原文")
        expect(snapshot.0.first?.aiUseSummary.isEmpty == true, "忘记后必须清除模型输入原文")
        let encoded = try JSONEncoder().encode(snapshot.1[0])
        expect(!String(decoding: encoded, as: UTF8.self).contains("用户最近睡得较晚"),
               "墓碑不得保留原始摘要")
    }

    private static func testClearAllAndExplicitHistoricalRescan() async throws {
        let first = try makeRecord(anchorValue: "first", sourceID: "habit-1")
        let second = try makeRecord(anchorValue: "second", sourceID: "habit-2")
        let store = FakeHoloMemoryForgettingStore(records: [first, second])
        let service = HoloMemoryForgettingService(store: store)
        let cleared = try await service.clearAll(now: Date(timeIntervalSince1970: 30))
        var snapshot = await store.snapshot()

        expect(cleared == 2, "清空应覆盖全部可用记忆")
        expect(snapshot.2.learningBaselineAt == Date(timeIntervalSince1970: 30),
               "清空必须先写入新的学习起点")
        expect(snapshot.0.allSatisfy { $0.state == .tombstoned && $0.aiUseSummary.isEmpty },
               "清空后所有旧正文都必须不可用")

        let preview = try await service.prepareHistoricalRescan()
        expect(preview.affectedRecordCount == 2, "重新扫描历史前必须显式预览影响范围")
        try await service.confirmHistoricalRescan(preview: preview, now: Date(timeIntervalSince1970: 40))
        snapshot = await store.snapshot()
        expect(snapshot.2.learningBaselineAt == nil, "只有确认预览后才允许重新扫描历史")
    }

    private static func testSourceRevisionInvalidatesDependentMemory() async throws {
        let record = try makeRecord(anchorValue: "source-change", sourceID: "habit-1")
        let store = FakeHoloMemoryForgettingStore(records: [record])
        let service = HoloMemoryForgettingService(store: store)
        let count = try await service.invalidateMemories(
            dependingOnSourceID: "habit-1",
            currentRevisionDigest: "new-revision",
            now: Date(timeIntervalSince1970: 50)
        )
        let snapshot = await store.snapshot()

        expect(count == 1, "原始实体修改应命中依赖记忆")
        expect(snapshot.0.first?.state == .invalidated, "依赖旧版本原始数据的记忆必须失效")
    }

    private static func makeRecord(
        anchorValue: String,
        sourceID: String
    ) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .habit, value: anchorValue)
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            claimKind: .recurringPattern,
            anchors: [anchor]
        )
        let observedAt = Date(timeIntervalSince1970: 10)
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            subjectKey: anchorValue,
            anchorRefs: [anchor],
            claimKind: .recurringPattern,
            persistenceClass: .phase,
            displaySummary: "用户最近睡得较晚",
            aiUseSummary: "近期存在晚睡模式",
            prohibitedInferences: [],
            evidenceRefs: [HoloMemoryEvidenceRef(
                id: "evidence-\(sourceID)",
                kind: .entityRef,
                sourceDomain: .habit,
                lineageKey: "habit:\(sourceID)",
                sourceID: sourceID,
                revisionDigest: "old-revision",
                observedAt: observedAt
            )],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: 1,
            scoreComputedAt: observedAt,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: observedAt,
            updatedAt: observedAt
        )
    }
}
