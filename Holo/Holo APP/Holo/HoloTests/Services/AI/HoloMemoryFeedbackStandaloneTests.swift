import Foundation

actor HoloMemoryFeedbackTestStore: HoloMemoryFeedbackStore {
    private var records: [String: HoloMemoryRecord]
    private var control = HoloMemoryControlState.initial(now: Date(timeIntervalSince1970: 0))
    private(set) var tombstones: [HoloMemoryTombstone] = []
    private(set) var decisions: [HoloMemoryUserDecision] = []
    private(set) var deletedRecordIDs: [String] = []

    init(record: HoloMemoryRecord) {
        records = [record.id: record]
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
        decisions.append(decision)
        record.userDecision = decision
        record.recordVersion += 1
        record.updatedAt = now
        switch decision {
        case .confirmed, .corrected:
            record.state = .active
        case .rejected:
            record.state = .suppressed
        case .forgotten:
            record.state = .tombstoned
            record.displaySummary = ""
            record.aiUseSummary = ""
            record.evidenceRefs = []
        case .none, .markedIrrelevant:
            break
        }
        records[id] = record
        return true
    }

    func loadControlState() async throws -> HoloMemoryControlState { control }
    func saveControlState(_ state: HoloMemoryControlState) async throws { control = state }
    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws {
        tombstones.append(tombstone)
    }
    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws {
        records[record.id] = record
    }
    func deleteRecord(id: String) async throws -> Bool {
        guard records.removeValue(forKey: id) != nil else { return false }
        deletedRecordIDs.append(id)
        return true
    }

    func snapshot(id: String) -> HoloMemoryRecord? { records[id] }
    func tombstoneSnapshot() -> [HoloMemoryTombstone] { tombstones }
    func decisionSnapshot() -> [HoloMemoryUserDecision] { decisions }
    func deletedRecordIDSnapshot() -> [String] { deletedRecordIDs }
}

@main
struct HoloMemoryFeedbackStandaloneTests {
    private static var assertions = 0

    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_752_508_800)
        let original = try makeRecord(now: now)

        let accurateStore = HoloMemoryFeedbackTestStore(record: original)
        let accurateService = HoloMemoryFeedbackService(store: accurateStore)
        let accurateSaved = try await accurateService.apply(.accurate, to: original.id, now: now)
        expect(accurateSaved, "准确反馈应保存")
        let accurate = await accurateStore.snapshot(id: original.id)
        expect(accurate?.userDecision == .confirmed, "准确反馈应成为用户确认版本")
        expect(accurate?.state == .active, "准确反馈应保持可用")

        let inaccurateStore = HoloMemoryFeedbackTestStore(record: original)
        let inaccurateService = HoloMemoryFeedbackService(store: inaccurateStore)
        let inaccurateSaved = try await inaccurateService.apply(.inaccurate, to: original.id, now: now)
        expect(inaccurateSaved, "不准确反馈应保存")
        let inaccurate = await inaccurateStore.snapshot(id: original.id)
        expect(inaccurate?.userDecision == .rejected, "不准确反馈应被拒绝")
        expect(inaccurate?.state == .suppressed, "不准确记忆不得再进入回答")
        let restoredSaved = try await inaccurateService.apply(
            .accurate,
            to: original.id,
            now: now.addingTimeInterval(1)
        )
        expect(restoredSaved, "不准确记忆应允许改回准确")
        let restored = await inaccurateStore.snapshot(id: original.id)
        expect(restored?.userDecision == .confirmed, "重新选择准确应覆盖原有决策")
        expect(restored?.state == .active, "重新选择准确应恢复为可用记忆")

        let forgetStore = HoloMemoryFeedbackTestStore(record: original)
        let forgetService = HoloMemoryFeedbackService(store: forgetStore)
        let forgottenSaved = try await forgetService.apply(.noLongerUse, to: original.id, now: now)
        expect(forgottenSaved, "不再使用应保存")
        let tombstones = await forgetStore.tombstoneSnapshot()
        let decisions = await forgetStore.decisionSnapshot()
        let deletedRecordIDs = await forgetStore.deletedRecordIDSnapshot()
        expect(tombstones.isEmpty, "不再使用不应写入阻止再生成的墓碑")
        expect(decisions.isEmpty, "不再使用不应伪装成永久忘记决策")
        expect(deletedRecordIDs == [original.id], "不再使用应只删除当前记忆")
        let forgotten = await forgetStore.snapshot(id: original.id)
        expect(forgotten == nil, "不再使用后不应保留空正文占位记录")

        let correctionStore = HoloMemoryFeedbackTestStore(record: original)
        let correctionService = HoloMemoryFeedbackService(store: correctionStore)
        let corrected = try await correctionService.correct(
            id: original.id,
            summary: "  我最近更重视   恢复节奏  ",
            now: now.addingTimeInterval(60)
        )
        expect(corrected.displaySummary == "我最近更重视 恢复节奏", "纠正文案应规范化")
        expect(corrected.aiUseSummary == corrected.displaySummary, "展示与模型摘要应同步")
        expect(corrected.userDecision == .corrected, "纠正必须标记为用户确认修订")
        expect(corrected.state == .active, "纠正版本应立即可用")
        expect(corrected.recordVersion == original.recordVersion + 1, "纠正必须创建新版本")
        expect(corrected.predecessorVersionID == original.versionID, "纠正必须保留前序版本链")
        expect(corrected.evidenceRefs == original.evidenceRefs, "纠正不得丢失来源证据")
        expect(corrected.id == original.id, "纠正不得改变稳定身份")

        do {
            _ = try await correctionService.correct(id: original.id, summary: "  ", now: now)
            fatalError("空纠正应失败")
        } catch HoloMemoryFeedbackError.emptyCorrection {
            assertions += 1
        }

        print("HoloMemoryFeedbackStandaloneTests: \(assertions) assertions passed")
    }

    private static func makeRecord(now: Date) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(
            type: .healthMetric,
            value: "recovery-rhythm",
            displayLabel: "恢复节奏"
        )
        let evidence = HoloMemoryEvidenceRef(
            id: "health-aggregate-1",
            kind: .aggregateSnapshot,
            sourceDomain: .health,
            lineageKey: "health-recovery-week",
            revisionDigest: "rev-1",
            observedAt: now,
            validFrom: now.addingTimeInterval(-7 * 86_400),
            validTo: now,
            aggregateDefinition: "weekly recovery summary",
            sampleCount: 7,
            summary: "近期恢复时间较稳定"
        )
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .health,
            sourceDomains: [.health],
            claimKind: .phaseShift,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: .health,
            sourceDomains: [.health],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: .phaseShift,
            persistenceClass: .phase,
            displaySummary: "近期更关注恢复节奏",
            aiUseSummary: "近期更关注恢复节奏",
            prohibitedInferences: ["medicalDiagnosis"],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: evidence.validFrom,
            validTo: evidence.validTo,
            lastSupportedAt: now,
            confidenceScore: 0.8,
            freshnessScore: 0.9,
            scoringVersion: 2,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: .sensitive,
            userDecision: .none,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
}
