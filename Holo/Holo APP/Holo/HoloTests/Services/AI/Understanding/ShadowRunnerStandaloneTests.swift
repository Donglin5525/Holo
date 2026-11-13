//
//  ShadowRunnerStandaloneTests.swift
//  Holo
//
//  影子 Runner 全链单测（fixture 数据源+fixture 提案客户端；Runner 零 App 依赖可 standalone 编译）。
//  覆盖：首轮全链终态 / 幂等二轮零处理（预算保护） / 提案失败不重试 / 持久化三件套。
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift。

struct ShadowRunnerStandaloneTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func run() async throws {
        try await firstRunFullPipeline()
        try await secondRunIdempotent()
        try await proposalFailureNoRetry()
        try await persistenceArtifacts()

        print("ShadowRunnerStandaloneTests: \(assertions) assertions passed")
    }

    static let calendar = { () -> Calendar in
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    static func day(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }
    static let now = day(2026, 11, 13, 10)

    static func tempStorage() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-runner-test-\(UUID().uuidString)")
    }

    /// fixture 数据源：caseA 猫主题（财务 4 + 想法 2 + 任务 1 的等价简化——财务+想法即可成跨域主题）。
    static func fixtureInputs() -> ([FinanceObservationInput], [ThoughtObservationInput]) {
        let finance = [
            FinanceObservationInput(id: "cat-1", note: "猫粮", occurredAt: day(2026, 8, 14, 19), recordedAt: day(2026, 8, 14, 19), updatedAt: day(2026, 8, 14, 19), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-2", note: "猫粮 5kg", occurredAt: day(2026, 9, 2, 20), recordedAt: day(2026, 9, 2, 20), updatedAt: day(2026, 9, 2, 20), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-3", note: "猫砂豆腐砂", occurredAt: day(2026, 9, 25, 12), recordedAt: day(2026, 9, 25, 12), updatedAt: day(2026, 9, 25, 12), isRefund: false, categoryName: nil),
        ]
        let thought = [
            ThoughtObservationInput(id: "th-1", text: "今晚加班回家，猫在门口等我。", createdAt: day(2026, 9, 26, 23), updatedAt: day(2026, 9, 26, 23), isAIDerived: false),
        ]
        return (finance, thought)
    }

    /// fixture 提案客户端：返回 M1.2 A-semantic 等价好候选（refs 对应 fixture 数据的 sourceRef）。
    struct FixtureProposeClient: UnderstandingProposeClient {
        var candidates: [ProposalCandidate]
        var error: Error?
        func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] {
            if let error { throw error }
            return candidates
        }
    }

    static let goodCandidate = ProposalCandidate(
        claimType: "role",
        statement: "本人是猫的主要照料者（负责日常清洁和饮食）。",
        supportingRefs: ["cat-1", "th-1"], alternativeExplanations: ["代养", "室友的猫"],
        whatWouldChangeTheAnswer: "出行清单纳入喂养安排", evidenceGrade: "支持", action: "adopt")

    // MARK: 1. 首轮全链

    static func firstRunFullPipeline() async throws {
        let storage = tempStorage()
        let report = await UnderstandingShadowRunner.runOnce(
            now: now, maxTopics: 3, storage: storage,
            loadInputs: { fixtureInputs() },
            proposeClient: FixtureProposeClient(candidates: [goodCandidate], error: nil))
        expect(report.financeObservations == 3 && report.thoughtObservations == 1, "观察计数=数据源计数")
        expect(report.themesTotal >= 1, "猫主题聚出（财务+想法跨域）")
        expect(report.topicsProcessed == 1, "首轮处理 1 主题")
        expect(report.proposalsReceived == 1, "收到 1 条提案")
        expect(report.outcomes["adoptable"] == 1, "好候选→adoptable（全链真实组件跑通）")
        expect(report.modelFailures.isEmpty, "无模型失败")
        try? FileManager.default.removeItem(at: storage)
    }

    // MARK: 2. 二轮幂等（预算保护）

    static func secondRunIdempotent() async throws {
        let storage = tempStorage()
        _ = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 3, storage: storage,
            loadInputs: { fixtureInputs() },
            proposeClient: FixtureProposeClient(candidates: [goodCandidate], error: nil))
        let second = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 3, storage: storage,
            loadInputs: { fixtureInputs() },
            proposeClient: FixtureProposeClient(candidates: [goodCandidate], error: nil))
        expect(second.topicsProcessed == 0 && second.proposalsReceived == 0,
               "同数据二轮零主题零调用（指纹 unchanged=预算保护，不重复计费）")
        try? FileManager.default.removeItem(at: storage)
    }

    // MARK: 3. 提案失败不重试

    static func proposalFailureNoRetry() async throws {
        let storage = tempStorage()
        struct Boom: Error {}
        let report = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 3, storage: storage,
            loadInputs: { fixtureInputs() },
            proposeClient: FixtureProposeClient(candidates: [], error: Boom()))
        expect(report.modelFailures.count == 1, "失败主题入 modelFailures 留诊断")
        expect(report.outcomes["rejected"] == 1, "提案失败→rejected（不重试不空转）")
        try? FileManager.default.removeItem(at: storage)
    }

    // MARK: 4. 持久化三件套（索引/主题快照/台账）

    static func persistenceArtifacts() async throws {
        let storage = tempStorage()
        _ = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 3, storage: storage,
            loadInputs: { fixtureInputs() },
            proposeClient: FixtureProposeClient(candidates: [goodCandidate], error: nil))
        expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent("index.json").path),
               "索引落盘")
        expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent("themes.json").path),
               "主题快照落盘")
        expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent("shadow-ledger.json").path),
               "影子台账落盘")
        let ledger = ShadowLedger.load(directory: storage)
        expect(ledger.snapshot(stage: .adoptable).count == 1, "台账终态可回读（评审导出数据源）")
        try? FileManager.default.removeItem(at: storage)
    }
}
