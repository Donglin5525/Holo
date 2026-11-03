//
//  DiscoveryPerformanceTests.swift
//  HoloTests
//
//  D13 性能实测（实施包 04 §5）：100/1000/10000 条纯合成记录，
//  两类情况——①冷启动准备（初次召回→反例检索全管线）②已有索引后单条变化（回源核版本 + 主线程登记）。
//  断言口径：主线程常量级登记 p95 < 10ms（04 §5 测试目标；Release 真机实测另行挂账，
//  本测试为 Debug 模拟器口径）。证据 JSON 落 NSTemporaryDirectory()/discovery_perf_results.json。
//

// 待挂载 HoloTests target
import XCTest
import CoreData
@testable import Holo

final class DiscoveryPerformanceTests: XCTestCase {

    /// iOS 26.3 测试宿主坑规避（同 DiscoveryStoreTests）
    override func invokeTest() {
        DispatchQueue.global(qos: .userInitiated).sync {
            super.invokeTest()
        }
    }

    /// MainActor 类钉池（habit-drag 档案）
    nonisolated(unsafe) private static var pinned: [AnyObject] = []

    private var fixedNow: Date { Date(timeIntervalSince1970: 1_790_000_000) }

    private var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private var environment: DiscoveryAccessSnapshot {
        DiscoveryAccessSnapshot(
            now: fixedNow,
            isGlobalConsentGranted: true,
            settings: DiscoverySettingsSnapshot(isEnabled: true, allowedDomains: [.thought], localGrantEpoch: 1),
            serverControlRevision: 1,
            dailyAutoBatchBudgetRemaining: 1
        )
    }

    // MARK: - 合成适配器（性能负载：数组过滤即扫描成本）

    final class SyntheticPerfAdapter: DiscoverySourceAdapting {
        let domain = DiscoverySourceDomain.thought
        let sourceKind = DiscoverySourceKind.thought
        var snapshots: [DiscoverySourceSnapshot] = []
        var availabilityValue = DiscoverySourceAvailability(earliestRecordAt: Date(timeIntervalSince1970: 0))
        private(set) var scannedTotal = 0

        func basePredicate() -> NSPredicate { NSPredicate(value: true) }

        private func inWindow(_ snapshot: DiscoverySourceSnapshot, _ window: DiscoveryTimeWindow) -> Bool {
            window.contains(snapshot.occurredAt ?? snapshot.recordedAt)
        }

        func fetchSnapshots(localIDs: [String], limit: Int) throws -> [DiscoverySourceSnapshot] {
            scannedTotal += snapshots.count
            let keys = Set(localIDs)
            return Array(snapshots.filter { keys.contains($0.localID) }.prefix(limit))
        }

        func fetchSnapshots(topicRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
            scannedTotal += snapshots.count
            return Array(snapshots.filter { inWindow($0, window) && !$0.entityRefs.filter { topicRefs.contains($0) }.isEmpty }.prefix(limit))
        }

        func fetchSnapshots(anchorRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
            scannedTotal += snapshots.count
            let keys = Set(anchorRefs)
            return Array(snapshots.filter { inWindow($0, window) && !($0.eventAnchors + $0.entityRefs).filter { keys.contains($0) }.isEmpty }.prefix(limit))
        }

        func fetchSnapshots(keyword: String, window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
            scannedTotal += snapshots.count
            return Array(snapshots.filter { inWindow($0, window) && $0.text.lowercased().contains(keyword.lowercased()) }.prefix(limit))
        }

        func fetchSnapshots(window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
            scannedTotal += snapshots.count
            return snapshots.filter { inWindow($0, window) }
        }

        func availability() throws -> DiscoverySourceAvailability { availabilityValue }
    }

    private func snapshot(_ index: Int, now: Date) -> DiscoverySourceSnapshot {
        // 文本带编号防全文相同（避免血缘 ambiguous 启发式把上万条并成一组）
        let occurred = now.addingTimeInterval(-Double(index % 25) * 86400 - Double(index % 20) * 3600)
        let text: String
        switch index % 3 {
        case 0: text = "第\(index)条：重新开始运动，先出门走了十分钟，没有要求自己一定跑起来。"
        case 1: text = "第\(index)条：读书只翻了两页，没有要求读完一章，先让自己坐下来。"
        default: text = "第\(index)条：今天先做最小的一步，写完开头一段就停，明天继续。"
        }
        return DiscoverySourceSnapshot(
            domain: .thought, kind: .thought, localID: "perf-t-\(index)",
            occurredAt: occurred, occurredOnlyDateKnown: false,
            recordedAt: occurred,
            text: text, numericValue: nil, numericUnit: nil,
            entityRefs: ["tag:运动", "tag:阅读"], eventAnchors: [],
            revisionFields: ["discovery.thought.v1", "perf-t-\(index)", text, String(occurred.timeIntervalSince1970)]
        )
    }

    private func candidate() -> DiscoveryCandidate {
        DiscoveryCandidate(
            candidateID: "C01", type: .twoEpisodes, subjectKey: "lighter-start",
            scopeKind: .twoEpisodes,
            timeRange: DiscoveryTimeRange(start: nil, end: nil),
            claims: [], titleClaimID: "K1", bodyClaimIDs: ["K2"],
            supportEvidenceIDs: [],
            counterSearch: [
                DiscoveryCounterSearch(domains: [.thought], anchorRefs: [], keywords: ["没有继续"])
            ],
            sensitivity: .nonSensitive, comparisonPeriods: []
        )
    }

    // MARK: - 结果落盘

    private static var results: [[String: Any]] = []

    private func record(_ entry: [String: Any]) {
        Self.results.append(entry)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("discovery_perf_results.json")
        if let data = try? JSONSerialization.data(withJSONObject: Self.results, options: [.prettyPrinted]) {
            try? data.write(to: url)
        }
    }

    // MARK: - ① 冷启动准备（100/1000/10000）

    func test_perf_冷启动准备_三档规模() throws {
        for size in [100, 1000, 10000] {
            let adapter = SyntheticPerfAdapter()
            Self.pinned.append(adapter)
            adapter.snapshots = (0..<size).map { snapshot($0, now: fixedNow) }
            let retriever = DiscoveryRetriever(adapters: [adapter])

            let request = DiscoveryRetriever.Request(
                changedSourceRefs: ["thought:perf-t-0"],
                topicRefs: ["tag:运动"],
                needsComparisonHistory: false,
                comparisonAnchorRefs: [],
                calendar: shanghaiCalendar
            )

            // 冷启动：初次召回（扫描→切块→血缘→材料包）
            let t0 = DispatchTime.now()
            let material = try retriever.initialRecall(request: request, environment: environment, now: fixedNow)
            let recallMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000

            // 反例检索（受限查询 + 中性回看）
            let t1 = DispatchTime.now()
            let counters = try retriever.counterRecall(
                candidate: candidate(),
                supportAtoms: material.supportAtoms,
                request: request, environment: environment, now: fixedNow
            )
            let counterMs = Double(DispatchTime.now().uptimeNanoseconds - t1.uptimeNanoseconds) / 1_000_000

            let entry: [String: Any] = [
                "case": "coldStart",
                "records": size,
                "scannedCount": adapter.scannedTotal,
                "matchedCount": material.coverage.matchedCount,
                "usedBlocks": material.supportAtoms.filter { $0.sourceKind != .computedFact }.count,
                "generationBlocks": material.generationEvidenceIDs.count,
                "truncated": material.coverage.truncatedCount,
                "counterBlocks": counters.blocks.count,
                "counterCoverage": counters.coverageState.rawValue,
                "recallMs": recallMs,
                "counterMs": counterMs,
                "totalMs": recallMs + counterMs,
            ]
            record(entry)

            // 管线预算恒定：与库规模无关的输出上界
            XCTAssertLessThanOrEqual(material.supportAtoms.filter { $0.sourceKind != .computedFact }.count, 24)
            XCTAssertLessThanOrEqual(material.generationEvidenceIDs.count, 12)
            XCTAssertLessThanOrEqual(counters.blocks.count, 6)
        }
    }

    // MARK: - ② 已有索引后单条变化：回源核版本 + 主线程登记

    func test_perf_单条变化_回源核版本与主线程登记_p95() throws {
        let adapter = SyntheticPerfAdapter()
        Self.pinned.append(adapter)
        adapter.snapshots = (0..<1000).map { snapshot($0, now: fixedNow) }
        let retriever = DiscoveryRetriever(adapters: [adapter])

        let request = DiscoveryRetriever.Request(
            changedSourceRefs: [], topicRefs: ["tag:运动"],
            needsComparisonHistory: false, comparisonAnchorRefs: [],
            calendar: shanghaiCalendar
        )
        let material = try retriever.initialRecall(request: request, environment: environment, now: fixedNow)
        let atoms = material.supportAtoms

        // 单条变化：revalidate 整包（其中 1 条版本已变——把第 0 条文本改掉）
        var mutated = adapter.snapshots
        mutated[0] = snapshot(0, now: fixedNow)
        mutated[0] = DiscoverySourceSnapshot(
            domain: .thought, kind: .thought, localID: "perf-t-0",
            occurredAt: mutated[0].occurredAt, occurredOnlyDateKnown: false,
            recordedAt: mutated[0].recordedAt,
            text: "第0条：内容已修改，版本必须失效。",
            numericValue: nil, numericUnit: nil,
            entityRefs: ["tag:运动"], eventAnchors: [],
            revisionFields: ["discovery.thought.v1", "perf-t-0", "changed", "0"]
        )
        adapter.snapshots = mutated

        let t0 = DispatchTime.now()
        let stale = try retriever.revalidate(atoms: atoms, environment: environment, now: fixedNow)
        let revalidateMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        XCTAssertFalse(stale.isEmpty, "变化的那条必须被核出失效")

        // 主线程登记：失效依赖查询 ×500 取 p95（常量级：发现≤1 条 + 依赖索引）
        let store = try DiscoveryStore(configuration: .init(
            inMemory: true,
            feedbackKey: Data(repeating: 0x07, count: 32),
            feedbackSalt: "perf-salt"
        ))
        let findingID = try store.publishFinding(
            runID: "perf-run",
            payload: DiscoveryPublishedPayload(
                candidateID: "C01", type: .twoEpisodes,
                title: "性能测试发现", body: ["正文"],
                citations: [], coverageNote: "性能测试",
                sensitivity: .nonSensitive,
                timeRange: DiscoveryTimeRange(start: nil, end: nil),
                fingerprintMaterial: "subject:perf"
            ),
            dependencies: (0..<10).map {
                DiscoveryFindingDependency(
                    sourceRef: "thought:perf-t-\($0)", kind: .thought,
                    sourceRevision: "r\($0)", role: .support
                )
            },
            publishedAt: fixedNow,
            expiresAt: fixedNow.addingTimeInterval(14 * 24 * 3600),
            freezeDigest: "perf-digest"
        )
        XCTAssertNotNil(findingID)

        let probeRefs = (0..<10).map { "thought:perf-t-\($0)" }
        var samples: [Double] = []
        for _ in 0..<500 {
            let start = DispatchTime.now()
            _ = try store.findingsAffected(bySourceRefs: Set(probeRefs))
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        let p100 = samples.last ?? 0

        record([
            "case": "singleChange",
            "records": 1000,
            "revalidateMs": revalidateMs,
            "staleCount": stale.count,
            "registrationSamples": samples.count,
            "registrationP50Ms": p50,
            "registrationP95Ms": p95,
            "registrationMaxMs": p100,
        ])

        // 04 §5 测试目标：主线程仅做常量级登记，p95 < 10ms（Debug 模拟器口径，真机 Release 挂账）
        XCTAssertLessThan(p95, 10.0, "主线程登记 p95 必须低于 10ms，实测 \(p95)ms")
    }
}
