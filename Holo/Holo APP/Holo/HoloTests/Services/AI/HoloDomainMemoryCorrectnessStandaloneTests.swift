//
//  HoloDomainMemoryCorrectnessStandaloneTests.swift
//  HoloTests
//
//  体检 G2 领域记忆正确性验收：探针 A01/A02/A03 转正确行为断言。
//  - A01：摘要数值必须命中程序持有的事实值，编造数字整条拒绝（fabricatedValue）。
//  - A02：模型漏回禁止推断时，被引证据的来源限制由程序合并保留。
//  - A03：记录观察窗=证据覆盖的真实窗口，不用调度窗替代。
//  standalone 运行见 scripts/run-memory-decision-standalone.sh。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloDomainMemoryCorrectnessStandaloneTests.main()
    }
}
#endif
struct HoloDomainMemoryCorrectnessStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try testFabricatedNumberRejected()
        try testLegitimateNumbersAccepted()
        try testSourceProhibitedInferencesMerged()
        try testObservationWindowComesFromEvidence()
        print("HoloDomainMemoryCorrectnessStandaloneTests: \(assertionCount) assertions passed")
    }

    // MARK: - 造数

    private static let now = Date(timeIntervalSince1970: 1_791_072_000)

    private static func makeSignal(
        numericFacts: [String: Double],
        prohibitedInferences: [String]
    ) throws -> HoloDomainMemorySignal {
        let anchor = try HoloMemoryAnchorRef(type: .financeCategory, value: "餐饮")
        let evidence = HoloMemoryEvidenceRef(
            id: "real-finance-evidence",
            kind: .aggregateSnapshot,
            sourceDomain: .finance,
            lineageKey: "finance-current-total",
            revisionDigest: "r1",
            observedAt: now,
            validFrom: now.addingTimeInterval(-90 * 86_400),
            validTo: now,
            aggregateDefinition: "90天餐饮支出，合计100元",
            sampleCount: 10
        )
        return try HoloDomainSignalBuilder.make(
            id: "real-signal",
            domain: .finance,
            kind: .aggregate,
            evidence: evidence,
            anchors: [anchor],
            numericFacts: numericFacts,
            prohibitedInferences: prohibitedInferences
        )
    }

    private static func validateCandidate(
        signal: HoloDomainMemorySignal,
        summary: String,
        prohibitedInferences: [String]
    ) -> HoloDomainMemoryValidationResult {
        let window = HoloMemoryObservationWindow.make(
            target: .domain(.finance),
            dirtySince: now,
            now: now,
            catchUpLimit: 14 * 86_400
        )
        let package = HoloDomainObservationPackageBuilder.build(
            domain: .finance,
            window: window,
            signals: [signal]
        )
        let candidate = HoloDomainMemoryCandidateOutput(
            domain: .finance,
            claimKind: .observedFact,
            persistenceClass: .currentState,
            displaySummary: summary,
            aiUseSummary: summary,
            anchors: signal.anchors,
            evidenceIDs: [signal.evidence.id],
            prohibitedInferences: prohibitedInferences
        )
        return HoloDomainMemoryOutputValidator.validate(
            envelope: .init(candidates: [candidate]),
            against: package,
            now: now,
            extractorVersion: 1,
            promptVersion: 2
        )
    }

    // MARK: - A01 数值核验

    /// A01 修复断言：错误数字（999999 vs 真实 100）整条拒绝且落因 fabricatedValue。
    private static func testFabricatedNumberRejected() throws {
        let signal = try makeSignal(
            numericFacts: ["totalExpense": 100],
            prohibitedInferences: []
        )
        let result = validateCandidate(
            signal: signal,
            summary: "最近90天餐饮支出999999元",
            prohibitedInferences: []
        )
        expect(result.validRecords.isEmpty, "编造数字的候选不得成为记忆")
        expect(result.rejections == [.fabricatedValue], "拒绝原因应为 fabricatedValue，实际 \(result.rejections)")
    }

    /// 合法数字（事实值 100、口径 90、样本 10）必须通过。
    private static func testLegitimateNumbersAccepted() throws {
        let signal = try makeSignal(
            numericFacts: ["totalExpense": 100],
            prohibitedInferences: []
        )
        let result = validateCandidate(
            signal: signal,
            summary: "最近90天餐饮支出合计100元，来自10条记录",
            prohibitedInferences: []
        )
        expect(result.rejections.isEmpty, "程序事实内的数字不得被拒，实际 \(result.rejections)")
        expect(result.validRecords.count == 1, "合法候选应被接受")
    }

    // MARK: - A02 来源限制程序合并

    /// A02 修复断言：模型漏回禁止推断时，被引证据的限制仍并入记录。
    private static func testSourceProhibitedInferencesMerged() throws {
        let signal = try makeSignal(
            numericFacts: ["totalExpense": 100],
            prohibitedInferences: ["不得据此推断收入"]
        )
        let result = validateCandidate(
            signal: signal,
            summary: "最近90天餐饮支出合计100元",
            prohibitedInferences: []
        )
        let record = result.validRecords.first
        expect(record != nil, "合法候选应被接受")
        expect(record?.prohibitedInferences.contains("不得据此推断收入") == true,
               "模型漏回边界条件时，来源限制必须由程序并入，实际 \(record?.prohibitedInferences ?? [])")
    }

    // MARK: - A03 观察窗来自证据

    /// A03 修复断言：记录时间窗=证据覆盖的真实窗口（90 天），非调度当日。
    private static func testObservationWindowComesFromEvidence() throws {
        let signal = try makeSignal(
            numericFacts: ["totalExpense": 100],
            prohibitedInferences: []
        )
        let result = validateCandidate(
            signal: signal,
            summary: "最近90天餐饮支出合计100元",
            prohibitedInferences: []
        )
        let record = result.validRecords.first
        expect(record?.validFrom == signal.evidence.validFrom,
               "记录窗口起点必须是证据窗口起点（90 天前），实际 \(String(describing: record?.validFrom))")
        expect(record?.validTo == signal.evidence.validTo,
               "记录窗口终点必须是证据窗口终点")
    }
}
