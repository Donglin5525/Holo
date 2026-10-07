import Foundation

// R04（2026-10-04 体检）回归：重复/冲突锚点进入跨域候选构建器必须确定性折叠，
// 不得触发 Dictionary(uniqueKeysWithValues:) 崩溃，且折叠结果不随输入顺序漂移。
// 运行：bash scripts/run-cross-domain-fusion-standalone.sh

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() throws {
        try HoloCrossDomainCandidateBuilderSafetyStandaloneTests.main()
    }
}
#endif
struct HoloCrossDomainCandidateBuilderSafetyStandaloneTests {
    static func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
        precondition(condition, "check failed: \(message()) (line \(line))")
    }

    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        try fullyDuplicateAnchors()
        try conflictingDuplicateAnchors()
        print("PASS: 重复锚点确定性折叠+冲突锚点不崩溃且与顺序无关（R04）")
    }

    // MARK: - 1. 完全重复：同 stableKey 同内容 → 折叠为一条，候选身份与干净输入一致

    static func fullyDuplicateAnchors() throws {
        let now = Date(timeIntervalSince1970: 1_752_422_400)
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: "恢复状态")
        var finance = try makeRecord(domain: .finance, anchor: anchor, lineage: "finance-event-1",
                                     start: now.addingTimeInterval(-604_800), end: now)
        var health = try makeRecord(domain: .health, anchor: anchor, lineage: "health-sleep-1",
                                    start: now.addingTimeInterval(-432_000), end: now.addingTimeInterval(172_800))
        // 模拟历史脏数据：解码绕过 init 规范化后直接带重复锚点（体检复现的同款构造）
        finance.anchorRefs.append(anchor)
        health.anchorRefs.append(anchor)
        try finance.validate()
        try health.validate()

        let candidates = HoloCrossDomainCandidateBuilder.build(from: [finance, health])
        check(candidates.count == 1, "重复锚点折叠后仍应生成同一候选，实测 \(candidates.count)")

        let cleanFinance = try makeRecord(domain: .finance, anchor: anchor, lineage: "finance-event-1",
                                          start: now.addingTimeInterval(-604_800), end: now)
        let cleanHealth = try makeRecord(domain: .health, anchor: anchor, lineage: "health-sleep-1",
                                         start: now.addingTimeInterval(-432_000), end: now.addingTimeInterval(172_800))
        let cleanCandidates = HoloCrossDomainCandidateBuilder.build(from: [cleanFinance, cleanHealth])
        check(candidates.map(\.identityKey) == cleanCandidates.map(\.identityKey),
              "折叠结果应与干净输入的候选身份完全一致")
    }

    // MARK: - 2. 冲突重复：同 stableKey 不同 displayLabel → 确定性保留，不随输入顺序漂移

    static func conflictingDuplicateAnchors() throws {
        let now = Date(timeIntervalSince1970: 1_752_422_400)
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: "恢复状态", displayLabel: "恢复·新")
        let conflict = try HoloMemoryAnchorRef(type: .userTheme, value: "恢复状态", displayLabel: "恢复·旧")
        var finance = try makeRecord(domain: .finance, anchor: anchor, lineage: "finance-event-1",
                                     start: now.addingTimeInterval(-604_800), end: now)
        let health = try makeRecord(domain: .health, anchor: anchor, lineage: "health-sleep-1",
                                    start: now.addingTimeInterval(-432_000), end: now.addingTimeInterval(172_800))
        finance.anchorRefs.append(conflict)

        let first = HoloCrossDomainCandidateBuilder.build(from: [finance, health])
        let flipped = HoloCrossDomainCandidateBuilder.build(from: [health, finance])
        check(first.count == 1 && flipped.count == 1, "冲突重复不得崩溃且仍生成候选")
        check(first.map(\.sharedAnchor.displayLabel) == flipped.map(\.sharedAnchor.displayLabel),
              "冲突折叠结果必须与输入顺序无关（确定性规则）")
        check(first.first?.sharedAnchor.stableKey == anchor.stableKey, "折叠保留同一 stableKey 身份")
    }

    // MARK: - 合成记录（与体检探针同款最小构造，不触碰 App 数据与功能开关）

    private static func makeRecord(
        domain: HoloMemoryDomain,
        anchor: HoloMemoryAnchorRef,
        lineage: String,
        start: Date,
        end: Date
    ) throws -> HoloMemoryRecord {
        let evidence = HoloMemoryEvidenceRef(
            id: "evidence-\(domain.rawValue)-\(lineage)",
            kind: .aggregateSnapshot,
            sourceDomain: domain,
            lineageKey: lineage,
            sourceID: nil,
            revisionDigest: "rev-1",
            observedAt: end,
            validFrom: start,
            validTo: end,
            aggregateDefinition: "test",
            sampleCount: 7,
            summary: "测试证据"
        )
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            claimKind: .recurringPattern,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: .recurringPattern,
            persistenceClass: .currentState,
            displaySummary: "\(domain.rawValue) 近期状态",
            aiUseSummary: "\(domain.rawValue) 近期状态",
            prohibitedInferences: [],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: start,
            validTo: end,
            lastSupportedAt: end,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: 1,
            scoreComputedAt: end,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: start,
            updatedAt: end
        )
    }
}
