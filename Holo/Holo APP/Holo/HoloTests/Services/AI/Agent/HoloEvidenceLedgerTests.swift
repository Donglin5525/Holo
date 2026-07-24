//
//  HoloEvidenceLedgerTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 2.1 Evidence Ledger 测试
//  运行（在 "Holo/Holo APP/Holo" 目录下）：
//  swiftc -parse-as-library \
//    "Holo/Models/AI/Agent/"*.swift \
//    "Holo/Services/AI/Agent/Persistence/"*.swift \
//    "Holo/Services/AI/Agent/Tools/HoloDataTool.swift" \
//    <本测试> -o /tmp/holo_evidence_ledger_test && /tmp/holo_evidence_ledger_test
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloEvidenceLedgerTests.main()
    }
}
#endif
struct HoloEvidenceLedgerTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await testUpsert_相同dedupeKey不重复()
        try await testUpsert_新evidence追加()
        try await testUpsert_referencedByJobIDs合并去重()
        try await testMarkOrphaned_无引用且过期被标记()
        print("HoloEvidenceLedgerTests passed")
    }

    // MARK: - Helpers

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-evidence-ledger-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeEvidence(
        id: String, dedupeKey: String, status: HoloEvidenceStatus = .active,
        generatedAt: Date, jobIDs: [String] = [], memoryIDs: [String] = []
    ) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: dedupeKey, sourceModule: .habit, sourceID: "src", sourceKind: "kind",
            timeRange: nil, occurredAt: generatedAt, metricKey: "metric", metricValue: 1, unit: "次",
            baselineValue: nil, comparison: nil, excerpt: "原文", redactedExcerpt: "脱敏",
            sensitivity: .normal, confidence: 1.0, status: status,
            generatedBy: "test", generatedAt: generatedAt,
            referencedByJobIDs: jobIDs, referencedByMemoryIDs: memoryIDs, deviceID: nil
        )
    }

    // MARK: - 用例

    /// 相同 dedupeKey 的两条记录，upsert 后只保留一条（后者覆盖前者）。
    private static func testUpsert_相同dedupeKey不重复() async throws {
        let dir = makeTempDir()
        let ledger = HoloEvidenceLedger(directory: dir)
        let now = Date(timeIntervalSince1970: 1000)

        try await ledger.upsert([
            makeEvidence(id: "ev-1", dedupeKey: "key-A", generatedAt: now),
            makeEvidence(id: "ev-2", dedupeKey: "key-A", generatedAt: now)
        ])

        let all = try await ledger.load()
        expect(all.count == 1, "相同 dedupeKey 应只保留 1 条，实际 \(all.count)")
        expect(all.first?.id == "ev-2", "应保留后写入的 ev-2")
    }

    /// 不同 dedupeKey 的记录追加保留。
    private static func testUpsert_新evidence追加() async throws {
        let dir = makeTempDir()
        let ledger = HoloEvidenceLedger(directory: dir)
        let now = Date(timeIntervalSince1970: 1000)

        try await ledger.upsert([makeEvidence(id: "ev-1", dedupeKey: "key-A", generatedAt: now)])
        try await ledger.upsert([makeEvidence(id: "ev-2", dedupeKey: "key-B", generatedAt: now)])

        let all = try await ledger.load()
        expect(all.count == 2, "不同 dedupeKey 应都保留，实际 \(all.count)")
    }

    /// 同 dedupeKey 再次 upsert 时，referencedByJobIDs 应与旧记录合并去重。
    private static func testUpsert_referencedByJobIDs合并去重() async throws {
        let dir = makeTempDir()
        let ledger = HoloEvidenceLedger(directory: dir)
        let now = Date(timeIntervalSince1970: 1000)

        try await ledger.upsert([
            makeEvidence(id: "ev-1", dedupeKey: "key-A", generatedAt: now, jobIDs: ["job-1"])
        ])
        try await ledger.upsert([
            makeEvidence(id: "ev-2", dedupeKey: "key-A", generatedAt: now, jobIDs: ["job-1", "job-2"])
        ])

        let record = try await ledger.load().first
        expect(record?.referencedByJobIDs.count == 2, "合并去重后应 2 个引用，实际 \(record?.referencedByJobIDs.count ?? -1)")
        expect(record?.referencedByJobIDs.contains("job-1") ?? false, "应含 job-1")
        expect(record?.referencedByJobIDs.contains("job-2") ?? false, "应含 job-2")
    }

    /// markOrphaned：无引用且早于 cutoff 的证据标记为 orphaned；有引用或未过期的不动。
    private static func testMarkOrphaned_无引用且过期被标记() async throws {
        let dir = makeTempDir()
        let ledger = HoloEvidenceLedger(directory: dir)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: TimeInterval = 86_400

        try await ledger.upsert([
            makeEvidence(id: "ev-old", dedupeKey: "k1", status: .active,
                         generatedAt: now.addingTimeInterval(-8 * day)),
            makeEvidence(id: "ev-ref", dedupeKey: "k2", status: .active,
                         generatedAt: now.addingTimeInterval(-8 * day), jobIDs: ["job-1"]),
            makeEvidence(id: "ev-fresh", dedupeKey: "k3", status: .active,
                         generatedAt: now.addingTimeInterval(-1 * day))
        ])

        // cutoff 设在 ev-old 与 ev-fresh 之间（now-3天）
        try await ledger.markOrphaned(olderThan: now.addingTimeInterval(-3 * day))

        let all = try await ledger.load()
        expect(all.first { $0.id == "ev-old" }?.status == .orphaned, "ev-old 无引用且过期应标记 orphaned")
        expect(all.first { $0.id == "ev-ref" }?.status == .active, "ev-ref 有引用应保持 active")
        expect(all.first { $0.id == "ev-fresh" }?.status == .active, "ev-fresh 未过期应保持 active")
    }
}
