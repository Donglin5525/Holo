//
//  DiscoveryRetrieverTests.swift
//  HoloTests
//
//  「一个发现」G2 检索测试（02 §3 / §6；04 验收矩阵 T29/T30）：
//  24/12 块预算、变化对象优先、反例三态覆盖（完成无命中/历史不足/预算截断）、
//  越界 counterSearch 整条拒绝、程序侧中性回看必须执行、回源核版本。
//  用最小合成 adapter（协议实现）测检索语义规则，不建三域业务库。
//  待挂载 HoloTests target（本文件为新增，未改动 pbxproj，由主会话统一挂载）。
//

// 待挂载 HoloTests target
import XCTest
import CoreData
@testable import Holo

@MainActor
final class DiscoveryRetrieverTests: XCTestCase {

    /// iOS 26.3 测试宿主坑（habit-drag-session-deadlock-1011 档案）：MainActor 隔离类在
    /// 用例内局部释放踩 TaskLocal 析构 double-free。合成 adapter/retriever 均为 MainActor
    /// 类（协议要求），钉进程级池不释放。
    nonisolated(unsafe) private static var pinnedInstances: [AnyObject] = []

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

    // MARK: - 合成适配器

    final class SyntheticThoughtAdapter: DiscoverySourceAdapting {
        let domain = DiscoverySourceDomain.thought
        let sourceKind = DiscoverySourceKind.thought
        var snapshots: [DiscoverySourceSnapshot] = []
        var availabilityValue = DiscoverySourceAvailability(earliestRecordAt: Date(timeIntervalSince1970: 0))
        private(set) var executedKeywords: [String] = []
        private(set) var topicFetchCount = 0
        private(set) var anchorFetchCount = 0
        private(set) var localIDFetchCount = 0

        func basePredicate() -> NSPredicate { NSPredicate(value: true) }

        private func inWindow(_ snapshot: DiscoverySourceSnapshot, _ window: DiscoveryTimeWindow) -> Bool {
            window.contains(snapshot.occurredAt ?? snapshot.recordedAt)
        }

        func fetchSnapshots(localIDs: [String], limit: Int) throws -> [DiscoverySourceSnapshot] {
            localIDFetchCount += 1
            return snapshots.filter { localIDs.contains($0.localID) }
        }

        func fetchSnapshots(topicRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
            topicFetchCount += 1
            return snapshots.filter { inWindow($0, window) && !$0.entityRefs.filter({ topicRefs.contains($0) }).isEmpty }
        }

        func fetchSnapshots(anchorRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
            anchorFetchCount += 1
            let keys = Set(anchorRefs)
            return snapshots.filter { inWindow($0, window) && !($0.eventAnchors + $0.entityRefs).filter({ keys.contains($0) }).isEmpty }
        }

        func fetchSnapshots(keyword: String, window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
            executedKeywords.append(keyword)
            return snapshots.filter { inWindow($0, window) && $0.text.lowercased().contains(keyword.lowercased()) }
        }

        func fetchSnapshots(window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
            snapshots.filter { inWindow($0, window) }
        }

        func availability() throws -> DiscoverySourceAvailability { availabilityValue }
    }

    private func thoughtSnapshot(
        id: String,
        text: String,
        daysAgo: Double,
        refs: [String] = ["tag:运动"]
    ) -> DiscoverySourceSnapshot {
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

    private func makeRetriever(_ adapter: SyntheticThoughtAdapter) -> DiscoveryRetriever {
        Self.pinnedInstances.append(adapter)
        return DiscoveryRetriever(adapters: [adapter])
    }

    private func makeRequest(changed: [String] = [], topics: [String] = ["tag:运动"], comparison: Bool = false) -> DiscoveryRetriever.Request {
        DiscoveryRetriever.Request(
            changedSourceRefs: changed,
            topicRefs: topics,
            needsComparisonHistory: comparison,
            comparisonAnchorRefs: [],
            calendar: shanghaiCalendar
        )
    }

    /// 用 builder 把支持快照转成 atom（counterRecall 的入参形态）
    private func supportAtoms(from snapshots: [DiscoverySourceSnapshot]) -> [DiscoveryFactAtom] {
        DiscoveryEvidenceBuilder().buildAtoms(
            from: snapshots,
            coverageInput: DiscoveryCoverageInput(domains: [.thought], matchedBlockCount: snapshots.count),
            accessRevision: "a",
            calendar: shanghaiCalendar,
            now: fixedNow
        ).atoms.filter { $0.sourceKind != .computedFact }
    }

    private func makeCandidate(counterSearch: [DiscoveryCounterSearch]) -> DiscoveryCandidate {
        DiscoveryCandidate(
            candidateID: "C01",
            type: .twoEpisodes,
            subjectKey: "lighter-start",
            scopeKind: .twoEpisodes,
            timeRange: DiscoveryTimeRange(start: nil, end: nil),
            claims: [],
            titleClaimID: "K1",
            bodyClaimIDs: ["K2"],
            supportEvidenceIDs: [],
            counterSearch: counterSearch,
            sensitivity: .nonSensitive,
            comparisonPeriods: []
        )
    }

    // MARK: - 初次召回：预算与通道

    func test_初次召回_候选材料24块_生成阶段12块() throws {
        let adapter = SyntheticThoughtAdapter()
        adapter.snapshots = (0..<30).map { thoughtSnapshot(id: "t\($0)", text: "第\($0)条运动记录，先走了十分钟。", daysAgo: 1 + Double($0) * 0.5) }
        let package = try makeRetriever(adapter).initialRecall(request: makeRequest(), environment: environment, now: fixedNow)

        let blockAtoms = package.supportAtoms.filter { $0.sourceKind != .computedFact }
        XCTAssertEqual(blockAtoms.count, 24, "候选材料最多 24 块")
        XCTAssertEqual(package.generationEvidenceIDs.count, 12, "生成阶段最多 12 块")
        XCTAssertGreaterThanOrEqual(package.coverage.truncatedCount, 6, "超出预算的块记截断")
        XCTAssertEqual(package.counterBudgetBlocks, 0)
        XCTAssertEqual(package.coverage.matchedCount, 30)
        XCTAssertEqual(package.coverage.usedCount, 24)
        XCTAssertNil(package.coverage.indexVersion, "V1 无向量索引")
    }

    func test_初次召回_变化对象走通道1且优先() throws {
        let adapter = SyntheticThoughtAdapter()
        adapter.snapshots = [
            thoughtSnapshot(id: "changed", text: "变化对象：今晚只翻了两页。", daysAgo: 3, refs: []),
            thoughtSnapshot(id: "topic", text: "同主题：今晚先读两页再睡。", daysAgo: 4),
        ]
        let package = try makeRetriever(adapter).initialRecall(
            request: makeRequest(changed: ["thought:changed"]),
            environment: environment,
            now: fixedNow
        )
        XCTAssertEqual(adapter.localIDFetchCount, 1, "变化对象走 localID 通道")
        XCTAssertEqual(package.supportAtoms.first?.sourceBlock, "变化对象：今晚只翻了两页。", "变化对象排最前（通道优先级）")
    }

    func test_初次召回_未授权域不参与() throws {
        let adapter = SyntheticThoughtAdapter()
        adapter.snapshots = [thoughtSnapshot(id: "t1", text: "内容。", daysAgo: 1)]
        var narrowed = environment
        narrowed.settings.allowedDomains = [.task]   // 想法域未授权
        let package = try makeRetriever(adapter).initialRecall(request: makeRequest(), environment: narrowed, now: fixedNow)
        XCTAssertTrue(package.supportAtoms.isEmpty, "canReadSources 拒绝的域不出材料")
    }

    // MARK: - T29/T30：反例

    private var fixtureCoverage: DiscoveryFactAtom.Coverage {
        DiscoveryFactAtom.Coverage(
            domains: [.thought], windowStart: nil, windowEnd: nil,
            matchedCount: 0, usedCount: 0, truncatedCount: 0,
            denominatorKnown: true, indexVersion: nil
        )
    }

    func test_T29_转折反例块进入反例包_不被支持相似块挤掉() throws {
        let adapter = SyntheticThoughtAdapter()
        let support = thoughtSnapshot(id: "support", text: "今天先走了十分钟，想看看能不能慢慢恢复。", daysAgo: 10)
        adapter.snapshots = [support]
            + (0..<3).map { thoughtSnapshot(id: "n\($0)", text: "又走了十分钟，感觉还行。第\($0)次。", daysAgo: 2 + Double($0)) }
            + [
                thoughtSnapshot(id: "counter1", text: "前几天走了十分钟，但是后来还是没有继续。", daysAgo: 8),
                thoughtSnapshot(id: "counter2", text: "后来是约了同伴才又出了门，不是减小目标就能解决。", daysAgo: 5),
            ]
        let supportAtoms = supportAtoms(from: [support])
        let package = try makeRetriever(adapter).counterRecall(
            candidate: makeCandidate(counterSearch: []),
            supportAtoms: supportAtoms,
            request: makeRequest(),
            environment: environment,
            now: fixedNow
        )

        XCTAssertEqual(package.blocks.count, 5, "支持块被剔重后：3 相似块 + 2 反例块")
        XCTAssertTrue(package.blocks[0].sourceBlock.contains("但是") || package.blocks[0].sourceBlock.contains("不是"),
                      "会推翻核心解释的块排最前（F06）")
        XCTAssertTrue(package.blocks.contains { $0.sourceBlock.contains("后来还是没有继续") }, "转折反例不被支持相似块挤掉")
        XCTAssertTrue(package.blocks.contains { $0.sourceBlock.contains("约了同伴") })
        XCTAssertFalse(package.blocks.contains { $0.sourceBlock == "今天先走了十分钟，想看看能不能慢慢恢复。" }, "支持块本身不重复进反例包")
        XCTAssertEqual(package.coverageState, .complete)
    }

    func test_T30_反例超过6块_覆盖标预算截断() throws {
        let adapter = SyntheticThoughtAdapter()
        adapter.snapshots = (0..<8).map {
            thoughtSnapshot(id: "c\($0)", text: "但是第\($0)次尝试后来还是没有继续下去。", daysAgo: 1 + Double($0))
        }
        let package = try makeRetriever(adapter).counterRecall(
            candidate: makeCandidate(counterSearch: []),
            supportAtoms: supportAtoms(from: [thoughtSnapshot(id: "s", text: "支持块：先走十分钟。", daysAgo: 9)]),
            request: makeRequest(),
            environment: environment,
            now: fixedNow
        )
        XCTAssertEqual(package.blocks.count, 6)
        XCTAssertEqual(package.coverageState, .budgetTruncated, "预算截断与无命中必须区分（覆盖三态）")
    }

    func test_覆盖三态_搜索完成且无命中() throws {
        let adapter = SyntheticThoughtAdapter()
        adapter.snapshots = []   // 全窗口扫描无结果
        adapter.availabilityValue = DiscoverySourceAvailability(earliestRecordAt: Date(timeIntervalSince1970: 0))
        let package = try makeRetriever(adapter).counterRecall(
            candidate: makeCandidate(counterSearch: []),
            supportAtoms: supportAtoms(from: [thoughtSnapshot(id: "s", text: "支持：先走十分钟。", daysAgo: 9, refs: ["tag:运动"])]),
            request: makeRequest(),
            environment: environment,
            now: fixedNow
        )
        XCTAssertTrue(package.blocks.isEmpty)
        XCTAssertEqual(package.coverageState, .completedNoHit, "无命中 ≠ 找不到反例：仅指当前记录范围")
    }

    func test_覆盖三态_历史不足() throws {
        let adapter = SyntheticThoughtAdapter()
        adapter.snapshots = []
        // 最早记录晚于 90 天窗口起点 → 窗口内历史不可用
        adapter.availabilityValue = DiscoverySourceAvailability(earliestRecordAt: fixedNow.addingTimeInterval(-10 * 86400))
        let package = try makeRetriever(adapter).counterRecall(
            candidate: makeCandidate(counterSearch: []),
            supportAtoms: supportAtoms(from: [thoughtSnapshot(id: "s", text: "支持。", daysAgo: 9)]),
            request: makeRequest(),
            environment: environment,
            now: fixedNow
        )
        XCTAssertEqual(package.coverageState, .insufficientHistoryOrIndex, "历史不足不能发布广泛模式")
    }

    func test_覆盖三态_域内无任何记录也算历史不足() throws {
        let adapter = SyntheticThoughtAdapter()
        adapter.availabilityValue = DiscoverySourceAvailability(earliestRecordAt: nil)
        let package = try makeRetriever(adapter).counterRecall(
            candidate: makeCandidate(counterSearch: []),
            supportAtoms: supportAtoms(from: [thoughtSnapshot(id: "s", text: "支持。", daysAgo: 9)]),
            request: makeRequest(),
            environment: environment,
            now: fixedNow
        )
        XCTAssertEqual(package.coverageState, .insufficientHistoryOrIndex)
    }

    // MARK: - 越界 counterSearch

    func test_越界关键词_整条拒绝不执行_标检索不完整() throws {
        let adapter = SyntheticThoughtAdapter()
        adapter.snapshots = [thoughtSnapshot(id: "s0", text: "今天走了十分钟。", daysAgo: 2)]
        let candidate = makeCandidate(counterSearch: [
            DiscoveryCounterSearch(domains: [.thought], anchorRefs: [], keywords: ["/Users/me/health.json"]),
            DiscoveryCounterSearch(domains: [.thought], anchorRefs: [], keywords: ["http://x.io"]),
            DiscoveryCounterSearch(domains: [.thought], anchorRefs: [], keywords: ["十分钟"]),   // 合法
        ])
        let package = try makeRetriever(adapter).counterRecall(
            candidate: candidate,
            supportAtoms: supportAtoms(from: [thoughtSnapshot(id: "s", text: "支持。", daysAgo: 9)]),
            request: makeRequest(),
            environment: environment,
            now: fixedNow
        )
        XCTAssertEqual(package.rejectedQueryCount, 2, "路径/URL 关键词整条拒绝")
        XCTAssertEqual(adapter.executedKeywords, ["十分钟"], "越界查询不执行（只执行了合法关键词）")
        XCTAssertTrue(package.neutralLookbackExecuted)
    }

    func test_越界域_未授权域整条拒绝() throws {
        let adapter = SyntheticThoughtAdapter()
        let candidate = makeCandidate(counterSearch: [
            DiscoveryCounterSearch(domains: [.task], anchorRefs: [], keywords: ["报销"]),   // task 未授权
        ])
        let package = try makeRetriever(adapter).counterRecall(
            candidate: candidate,
            supportAtoms: supportAtoms(from: [thoughtSnapshot(id: "s", text: "支持。", daysAgo: 9)]),
            request: makeRequest(),
            environment: environment,
            now: fixedNow
        )
        XCTAssertEqual(package.rejectedQueryCount, 1)
    }

    func test_anchorRefs指向本批evidence_可解析为回源锚() throws {
        let adapter = SyntheticThoughtAdapter()
        let support = thoughtSnapshot(id: "s", text: "支持：今天先走了十分钟，慢慢恢复。", daysAgo: 10)
        adapter.snapshots = [support, thoughtSnapshot(id: "counter", text: "但是后来还是没有继续。", daysAgo: 7)]
        let atoms = supportAtoms(from: [support])
        let evidenceID = atoms[0].evidenceID
        let candidate = makeCandidate(counterSearch: [
            DiscoveryCounterSearch(domains: [.thought], anchorRefs: [evidenceID], keywords: []),
        ])
        let package = try makeRetriever(adapter).counterRecall(
            candidate: candidate,
            supportAtoms: atoms,
            request: makeRequest(),
            environment: environment,
            now: fixedNow
        )
        XCTAssertTrue(package.blocks.contains { $0.sourceBlock.contains("后来还是没有继续") })
    }

    // MARK: - 中性回看（必须执行）

    func test_中性回看_模型无查询也执行并命中反例() throws {
        let adapter = SyntheticThoughtAdapter()
        let support = thoughtSnapshot(id: "s", text: "先走了十分钟，想看看能不能恢复。", daysAgo: 10)
        adapter.snapshots = [support, thoughtSnapshot(id: "neutral", text: "走了十分钟，但是没有继续，停了一周。", daysAgo: 6)]
        let package = try makeRetriever(adapter).counterRecall(
            candidate: makeCandidate(counterSearch: []),   // 模型没有提议任何查询
            supportAtoms: supportAtoms(from: [support]),
            request: makeRequest(),
            environment: environment,
            now: fixedNow
        )
        XCTAssertTrue(package.neutralLookbackExecuted, "程序侧中性回看必须执行（防「证实自己」查询漏反例）")
        XCTAssertGreaterThanOrEqual(adapter.topicFetchCount + adapter.anchorFetchCount, 1)
        XCTAssertTrue(package.blocks.contains { $0.sourceBlock.contains("没有继续") })
    }

    // MARK: - 合并去重

    private func counterBlock(_ id: String, _ text: String? = nil) -> DiscoveryFactAtom {
        DiscoveryFactAtom(
            localSourceRef: .init(kind: .thought, localID: id),
            sourceRevision: "r", evidenceID: id, sourceKind: .thought,
            occurredRange: .init(start: nil, end: nil, precision: .unknown),
            recordedAt: fixedNow,
            sourceBlock: text ?? "文本\(id)",
            quoteLocator: nil,
            lineageGroup: .ambiguous, entityRefs: [],
            coverage: fixtureCoverage,
            accessRevision: "a", computedFacts: []
        )
    }

    func test_合并去重_总量受预算约束() {
        let packageA = DiscoveryCounterPackage(blocks: [counterBlock("A1", "x"), counterBlock("A2", "y")], coverageState: .complete, rejectedQueryCount: 0, neutralLookbackExecuted: true)
        let packageB = DiscoveryCounterPackage(blocks: [counterBlock("A1", "x"), counterBlock("B1", "z"), counterBlock("B2", "w")], coverageState: .complete, rejectedQueryCount: 1, neutralLookbackExecuted: true)

        // 4 个唯一块：预算 4 → 全保留、complete
        let mergedFull = DiscoveryRetriever.mergedCounterPackage([packageA, packageB], totalBudget: 4)
        XCTAssertEqual(mergedFull.blocks.map(\.evidenceID), ["A1", "A2", "B1", "B2"], "同 sourceRef+同文本去重")
        XCTAssertEqual(mergedFull.coverageState, .complete)
        XCTAssertEqual(mergedFull.rejectedQueryCount, 1)

        // 预算 2 → 截断标记
        let mergedCapped = DiscoveryRetriever.mergedCounterPackage([packageA, packageB], totalBudget: 2)
        XCTAssertEqual(mergedCapped.blocks.map(\.evidenceID), ["A1", "A2"])
        XCTAssertEqual(mergedCapped.coverageState, .budgetTruncated, "预算不足 → coverageIncomplete")
    }

    func test_合并_任一截断则标记截断() {
        let truncated = DiscoveryCounterPackage(blocks: [], coverageState: .budgetTruncated, rejectedQueryCount: 0, neutralLookbackExecuted: true)
        let complete = DiscoveryCounterPackage(blocks: [counterBlock("A1")], coverageState: .complete, rejectedQueryCount: 0, neutralLookbackExecuted: true)
        XCTAssertEqual(DiscoveryRetriever.mergedCounterPackage([complete, truncated], totalBudget: 6).coverageState, .budgetTruncated)
    }

    // MARK: - 回源核版本

    func test_revalidate_版本变化与来源消失() throws {
        let adapter = SyntheticThoughtAdapter()
        let original = thoughtSnapshot(id: "t1", text: "原文内容：先走了十分钟。", daysAgo: 5)
        adapter.snapshots = [original]
        let atoms = supportAtoms(from: [original])
        let retriever = makeRetriever(adapter)

        XCTAssertTrue(try retriever.revalidate(atoms: atoms, environment: environment, now: fixedNow).isEmpty, "未变化不失效")

        // 原文被编辑 → revisionChanged
        adapter.snapshots = [thoughtSnapshot(id: "t1", text: "改后的内容：跑了五公里。", daysAgo: 5)]
        let stale = try retriever.revalidate(atoms: atoms, environment: environment, now: fixedNow)
        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(stale.first?.reason, .revisionChanged, "变了不用旧块")
        XCTAssertEqual(stale.first?.sourceRef, "thought:t1")

        // 来源消失（删除/不再可见）→ sourceMissing
        adapter.snapshots = []
        let missing = try retriever.revalidate(atoms: atoms, environment: environment, now: fixedNow)
        XCTAssertEqual(missing.first?.reason, .sourceMissing)
    }

    // MARK: - accessRevision

    func test_accessRevision_随范围与代数变化() {
        var envA = environment
        envA.settings.allowedDomains = [.thought]
        var envB = environment
        envB.settings.allowedDomains = [.thought, .task]
        XCTAssertNotEqual(
            DiscoveryRetriever.accessRevision(environment: envA),
            DiscoveryRetriever.accessRevision(environment: envB),
            "范围变化必须改变 accessRevision"
        )
        var envC = environment
        envC.settings.localGrantEpoch = 2
        XCTAssertNotEqual(
            DiscoveryRetriever.accessRevision(environment: environment),
            DiscoveryRetriever.accessRevision(environment: envC),
            "授权代数变化必须改变 accessRevision"
        )
    }
}
