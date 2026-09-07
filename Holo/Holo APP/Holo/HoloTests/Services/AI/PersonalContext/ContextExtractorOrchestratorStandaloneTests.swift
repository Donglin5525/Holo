//
//  ContextExtractorOrchestratorStandaloneTests.swift
//  HoloTests
//
//  P4 编排器验证：批次幂等（receipt 复用不重调 LLM）、游标先落库再推进（失败不推进）、
//  清空/控制代际竞态（拒绝过期批次）、源修订竞态（重新排队）、墓碑 suppression
//  （删除后重生拦截）、无候选空批 receipt、合并复用身份。
//  standalone 运行见 scripts/run-personal-context-standalone.sh。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await ContextExtractorOrchestratorStandaloneTests.main()
    }
}
#endif
struct ContextExtractorOrchestratorStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await testHappyPathCreatesRecordsAndAdvancesCursor()
        try await testBatchIdempotencySkipsLLMOnReplay()
        try await testLLMFailureDoesNotAdvanceCursor()
        try await testGenerationChangeRejectsStaleBatch()
        try await testSourceRevisionChangeRejectsStaleBatch()
        try await testTombstoneSuppressesResurrection()
        try await testEmptyCandidatesStillRecordsReceipt()
        try await testMergeReusesStableIdentity()
        print("ContextExtractorOrchestratorStandaloneTests: \(assertionCount) 断言全部通过")
    }

    // MARK: 测试替身

    /// 可编排的 LLM 假件：按队列返回响应，统计调用次数。
    final class FakeLLM: HoloPersonalContextLLMCalling, @unchecked Sendable {
        var extractResponses: [String] = []
        var verifyResponses: [String] = []
        private(set) var extractCallCount = 0
        private(set) var verifyCallCount = 0
        /// 注入失败（竞态模拟）。
        var extractError: Error?

        func extract(prompt: String) async throws -> String {
            if let extractError { throw extractError }
            extractCallCount += 1
            guard !extractResponses.isEmpty else { return "{\"candidates\":[],\"counterEvidence\":[]}" }
            return extractResponses.removeFirst()
        }

        func verify(prompt: String) async throws -> String {
            verifyCallCount += 1
            guard !verifyResponses.isEmpty else { return "{\"verdicts\":[]}" }
            return verifyResponses.removeFirst()
        }
    }

    /// 内存落库假件：记录+receipt+游标+代际+修订目录。
    final class FakeWriter: HoloPersonalContextRecordWriting, @unchecked Sendable {
        var records: [HoloMemoryRecord] = []
        var successfulBatchKeys: Set<String> = []
        var cursor: HoloContextExtractionCursorState?
        var tombstones: [HoloMemoryTombstone] = []
        var generation = HoloContextExtractionGeneration(userDecisionVersion: 1, learningBaselineAt: nil)
        /// sourceID → 当前修订（竞态模拟：LLM 返回后改这里）。
        var sourceRevisions: [String: String] = [:]
        private(set) var writeCallCount = 0

        func existingContextRecords() async throws -> [HoloMemoryRecord] { records }

        func write(records: [HoloMemoryRecord], batchKey: String) async throws {
            writeCallCount += 1
            guard !successfulBatchKeys.contains(batchKey) else { return }
            for record in records {
                if let index = self.records.firstIndex(where: { $0.id == record.id }) {
                    self.records[index] = record
                } else {
                    self.records.append(record)
                }
            }
            successfulBatchKeys.insert(batchKey)
        }

        func hasSuccessfulBatch(batchKey: String) async throws -> Bool {
            successfulBatchKeys.contains(batchKey)
        }

        func activeTombstones() async throws -> [HoloMemoryTombstone] { tombstones }

        func loadCursor() async throws -> HoloContextExtractionCursorState? { cursor }

        func saveCursor(_ cursor: HoloContextExtractionCursorState) async throws {
            self.cursor = cursor
        }

        func currentGeneration() async throws -> HoloContextExtractionGeneration { generation }

        func currentSourceRevisions(sourceIDs: [String]) async throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: sourceIDs.compactMap { id in
                sourceRevisions[id].map { (id, $0) }
            })
        }

        /// 记录当前源修订（正常态：与快照一致）。
        func seedRevisions(from sources: [HoloContextSourceSnapshot]) {
            sourceRevisions = Dictionary(
                uniqueKeysWithValues: sources.map { ($0.sourceID, $0.revisionDigest) }
            )
        }
    }

    static func source(
        id: String = "thought-1",
        text: String = "医生说要低盐饮食，要注意。",
        revision: String = "rev-1",
        updatedAt: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) -> HoloContextSourceSnapshot {
        HoloContextSourceSnapshot(
            sourceID: id,
            sourceDomain: "thought",
            sourceKind: "userNote",
            revisionDigest: revision,
            sourceCreatedAt: updatedAt,
            sourceUpdatedAt: updatedAt,
            plainText: text,
            sensitivity: .normal,
            accessGeneration: 1
        )
    }

    static func extractionRaw(ref: String = "c1", statement: String = "父亲被要求低盐", quote: String = "低盐") -> String {
        """
        {"candidates":[{"candidateRef":"\(ref)","statement":"\(statement)","relationText":"\(statement)","subjects":[{"label":"父亲","scope":"person"}],"facets":[{"kind":"constraint"}],"epistemicStatus":"declared","basis":[{"sourceID":"thought-1","quote":"\(quote)","revision":"rev-1","stance":"support"}],"openQuestions":[]}],"counterEvidence":[]}
        """
    }

    static func makeExtractor(
        sources: [HoloContextSourceSnapshot]
    ) -> (extractor: HoloPersonalContextExtractor, llm: FakeLLM, writer: FakeWriter) {
        let llm = FakeLLM()
        let writer = FakeWriter()
        writer.seedRevisions(from: sources)
        let paging = HoloContextInMemorySourcePaging(sources: sources)
        let extractor = HoloPersonalContextExtractor(paging: paging, llm: llm, writer: writer)
        return (extractor, llm, writer)
    }

    // MARK: 用例

    /// 正常路径：萃取→核验→落库→游标推进；记录 candidate 默认+载荷可读。
    static func testHappyPathCreatesRecordsAndAdvancesCursor() async throws {
        let sources = [source()]
        let (extractor, llm, writer) = makeExtractor(sources: sources)
        llm.extractResponses = [extractionRaw()]
        llm.verifyResponses = ["{\"verdicts\":[{\"candidateRef\":\"c1\",\"verdict\":\"supported\"}]}"]

        let outcome = try await extractor.runOneBatch(now: Date(timeIntervalSince1970: 1_790_000_000))

        expect(outcome.createdRecords == 1, "创建一条记录（实际 \(outcome.createdRecords)）")
        expect(writer.records.count == 1, "落库一条")
        let record = writer.records[0]
        expect(record.state == .candidate, "新记录默认 candidate")
        expect(record.personalContext?.isReadable == true, "载荷可读")
        expect(record.personalContext?.v1?.admission.level == .adviceEligible, "supported → 建议背景")
        expect(writer.cursor?.sourceCursor == nil, "全部处理完游标清空")
        expect(writer.cursor?.progress.createdRecords == 1, "进度计数")
    }

    /// 幂等：同批次重放直接复用 receipt，不再调 LLM。
    static func testBatchIdempotencySkipsLLMOnReplay() async throws {
        let sources = [source()]
        let (extractor, llm, writer) = makeExtractor(sources: sources)
        llm.extractResponses = [extractionRaw()]
        llm.verifyResponses = ["{\"verdicts\":[{\"candidateRef\":\"c1\",\"verdict\":\"supported\"}]}"]

        _ = try await extractor.runOneBatch(now: Date(timeIntervalSince1970: 1_790_000_000))
        let callsAfterFirst = (llm.extractCallCount, llm.verifyCallCount)
        expect(callsAfterFirst == (1, 1), "首轮各一次调用")

        // 重放（模拟重复请求/重试）：paging 相同来源 → 相同 batchKey → receipt 命中。
        let outcome2 = try await extractor.runOneBatch(now: Date(timeIntervalSince1970: 1_790_000_100))
        expect(llm.extractCallCount == 1, "receipt 命中不再萃取（实际 \(llm.extractCallCount)）")
        expect(writer.records.count == 1, "不重复创建记录")
        expect(outcome2.createdRecords == 0, "重放零新建")
    }

    /// LLM 失败：游标不推进，下次重试可成功（先落库再推游标的顺序保证）。
    static func testLLMFailureDoesNotAdvanceCursor() async throws {
        let sources = [source()]
        let (extractor, llm, writer) = makeExtractor(sources: sources)
        llm.extractError = HoloPersonalContextResponseParser.ParseError.notJSON

        do {
            _ = try await extractor.runOneBatch(now: Date(timeIntervalSince1970: 1_790_000_000))
            expect(false, "LLM 失败应抛错")
        } catch {
            expect(true, "LLM 失败抛错")
        }
        expect(writer.cursor == nil, "失败不落游标")
        expect(writer.records.isEmpty, "失败不落记录")

        // 修复后重试成功。
        llm.extractError = nil
        llm.extractResponses = [extractionRaw()]
        llm.verifyResponses = ["{\"verdicts\":[{\"candidateRef\":\"c1\",\"verdict\":\"supported\"}]}"]
        let outcome = try await extractor.runOneBatch(now: Date(timeIntervalSince1970: 1_790_000_200))
        expect(outcome.createdRecords == 1, "重试成功创建")
    }

    /// 清空/控制代际变化：LLM 返回后复查发现版本变化 → 拒绝过期批次（不写不推游标）。
    static func testGenerationChangeRejectsStaleBatch() async throws {
        let sources = [source()]
        let (extractor, llm, writer) = makeExtractor(sources: sources)
        llm.extractResponses = [extractionRaw()]
        llm.verifyResponses = ["{\"verdicts\":[{\"candidateRef\":\"c1\",\"verdict\":\"supported\"}]}"]

        // 模拟：LLM 在途时用户清空（版本推进）。
        llm.extractError = nil
        let llmRef = llm
        _ = llmRef
        // 直接在调用前改 generation 模拟竞态（LLM 返回后复查）。
        writer.generation = HoloContextExtractionGeneration(
            userDecisionVersion: 999,
            learningBaselineAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        // start 代际与复查代际不同的另一种路径：先改回去再在 extract 后改。
        writer.generation = HoloContextExtractionGeneration(userDecisionVersion: 1, learningBaselineAt: nil)

        // 正常开始（start 代际 v1），萃取返回后人为推进版本。
        // FakeLLM 无回调钩子；用两段式：先验证 start≠复查路径——
        // 在 writer.currentGeneration 上加"第二次调用返回新值"行为。
        let staleWriter = StaleGenerationWriter(base: writer)
        let paging = HoloContextInMemorySourcePaging(sources: sources)
        let staleExtractor = HoloPersonalContextExtractor(paging: paging, llm: llm, writer: staleWriter)

        do {
            _ = try await staleExtractor.runOneBatch(now: Date(timeIntervalSince1970: 1_790_000_000))
            expect(false, "代际变化应拒绝过期批次")
        } catch let error as HoloPersonalContextExtractor.ExtractionError {
            expect(error == .generationChanged, "错误类型正确")
        }
        expect(staleWriter.base.writeCallCount == 0, "过期批次不落库")
        expect(staleWriter.base.cursor == nil, "过期批次不推游标")
    }

    /// 源修订在 LLM 返回前变化：拒绝过期批次、重新排队（不写不推）。
    static func testSourceRevisionChangeRejectsStaleBatch() async throws {
        let sources = [source()]
        let (extractor, llm, writer) = makeExtractor(sources: sources)
        llm.extractResponses = [extractionRaw()]
        llm.verifyResponses = ["{\"verdicts\":[{\"candidateRef\":\"c1\",\"verdict\":\"supported\"}]}"]

        // LLM 在途时原文被编辑（修订变化）。
        writer.sourceRevisions["thought-1"] = "rev-2"

        do {
            _ = try await extractor.runOneBatch(now: Date(timeIntervalSince1970: 1_790_000_000))
            expect(false, "源修订变化应拒绝过期批次")
        } catch let error as HoloPersonalContextExtractor.ExtractionError {
            if case .sourceRevisionChanged(let sourceID) = error {
                expect(sourceID == "thought-1", "指出变化来源")
            } else {
                expect(false, "错误类型应为 sourceRevisionChanged")
            }
        }
        expect(writer.writeCallCount == 0, "过期批次不落库")
        expect(writer.records.isEmpty, "无记录")
        expect(writer.cursor == nil, "游标不推进（重新排队）")
    }

    /// 墓碑 suppression：候选命中被忘记记录的 span 键 → 拦截，不创建。
    static func testTombstoneSuppressesResurrection() async throws {
        let sources = [source()]
        let (extractor, llm, writer) = makeExtractor(sources: sources)
        llm.extractResponses = [extractionRaw()]
        llm.verifyResponses = ["{\"verdicts\":[{\"candidateRef\":\"c1\",\"verdict\":\"supported\"}]}"]

        // 构造被忘记记录的墓碑（span 键来自同一来源/修订/命题）。
        let forgottenPayload = HoloPersonalContextPayloadV1(
            contextID: "old-ctx",
            statement: "父亲被要求低盐",
            relationText: "父亲被要求低盐",
            epistemicStatus: .declared,
            basis: [HoloContextBasisRef(sourceID: "thought-1", quote: "低盐", sourceRevision: "rev-1")],
            admission: HoloContextAdmissionV1(
                level: .adviceEligible, policyVersion: 1, decidedAt: Date(timeIntervalSince1970: 0)
            )
        )
        writer.tombstones = [HoloMemoryTombstone(
            identityKey: "old-record",
            scope: HoloMemoryScope.domain,
            claimKind: HoloMemoryClaimKind.observedFact,
            anchorKeys: HoloContextSuppressionKeys.spanKeys(for: forgottenPayload),
            userDecisionVersion: 100,
            createdAt: Date(timeIntervalSince1970: 0)
        )]

        let outcome = try await extractor.runOneBatch(now: Date(timeIntervalSince1970: 1_790_000_000))
        expect(outcome.suppressed == 1, "重生候选被拦截（实际 \(outcome.suppressed)）")
        expect(writer.records.isEmpty, "被压制候选不落库")
        expect(writer.cursor?.progress.suppressedCandidates == 1, "suppression 计入进度/覆盖")
    }

    /// 无候选空批：receipt 也落（避免重复 LLM 调用），游标推进。
    static func testEmptyCandidatesStillRecordsReceipt() async throws {
        let sources = [source(text: "今天天气不错。")]
        let (extractor, llm, writer) = makeExtractor(sources: sources)
        llm.extractResponses = ["{\"candidates\":[],\"counterEvidence\":[]}"]

        let outcome = try await extractor.runOneBatch(now: Date(timeIntervalSince1970: 1_790_000_000))
        expect(outcome.createdRecords == 0, "无候选零创建")
        expect(writer.successfulBatchKeys.count == 1, "空批 receipt 已落")
        expect(llm.verifyCallCount == 0, "无候选不调核验")

        // 重放不再调 LLM。
        _ = try await extractor.runOneBatch(now: Date(timeIntervalSince1970: 1_790_000_100))
        expect(llm.extractCallCount == 1, "空批重放不重调萃取")
    }

    /// 合并动作：复用目标稳定 ID 与 contextID，追加证据、版本+1。
    static func testMergeReusesStableIdentity() async throws {
        let sources = [source()]
        let (extractor, llm, writer) = makeExtractor(sources: sources)

        // 既有记录（同一命题）。
        let existingPayload = HoloPersonalContextPayloadV1(
            contextID: "existing-ctx",
            statement: "父亲被要求低盐",
            subjects: [HoloContextPartyRef(label: "父亲", scope: .person)],
            relationText: "父亲被要求低盐",
            epistemicStatus: .declared,
            basis: [HoloContextBasisRef(sourceID: "thought-0", quote: "低盐", sourceRevision: "rev-0")],
            admission: HoloContextAdmissionV1(
                level: .adviceEligible, policyVersion: 1, decidedAt: Date(timeIntervalSince1970: 0)
            )
        )
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: existingPayload.contextAnchorValue)
        let existingRecord = try HoloMemoryRecord(
            id: HoloMemoryIdentity.makeStableID(
                scope: .domain, primaryDomain: .thought, sourceDomains: [.thought],
                claimKind: .observedFact, anchors: [anchor]
            ),
            scope: .domain,
            primaryDomain: .thought,
            sourceDomains: [.thought],
            subjectKey: "个人情境",
            anchorRefs: [anchor],
            claimKind: .observedFact,
            persistenceClass: .durable,
            displaySummary: existingPayload.statement,
            aiUseSummary: existingPayload.statement,
            prohibitedInferences: [],
            evidenceRefs: [],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            confidenceScore: 0.5,
            freshnessScore: 0.5,
            scoringVersion: 1,
            scoreComputedAt: Date(timeIntervalSince1970: 0),
            extractorVersion: 1,
            promptVersion: 1,
            state: .candidate,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            personalContext: HoloPersonalContextPayloadEnvelope(v1: existingPayload)
        )
        writer.records = [existingRecord]

        // 新证据萃取出同一命题（mergeInto 指向既有 contextID）。
        llm.extractResponses = [extractionRaw(statement: "父亲被要求低盐")]
        llm.verifyResponses = ["{\"verdicts\":[{\"candidateRef\":\"c1\",\"verdict\":\"supported\"}]}"]

        let outcome = try await extractor.runOneBatch(now: Date(timeIntervalSince1970: 1_790_000_000))

        expect(outcome.mergedRecords == 1, "命中合并（实际 \(outcome.mergedRecords)）")
        expect(writer.records.count == 1, "不新建重复记录")
        let merged = writer.records[0]
        expect(merged.id == existingRecord.id, "稳定 ID 不变")
        expect(merged.recordVersion == existingRecord.recordVersion + 1, "版本推进")
        expect(merged.personalContext?.v1?.contextID == "existing-ctx", "contextID 复用")
        expect(merged.personalContext?.v1?.basis.count == 2, "证据追加（旧1+新1）")
    }
}

/// 代际竞态替身：第一次 currentGeneration 返回基线，之后返回新代际。
final class StaleGenerationWriter: HoloPersonalContextRecordWriting, @unchecked Sendable {
    let base: ContextExtractorOrchestratorStandaloneTests.FakeWriter
    private var generationCallCount = 0

    init(base: ContextExtractorOrchestratorStandaloneTests.FakeWriter) {
        self.base = base
    }

    func existingContextRecords() async throws -> [HoloMemoryRecord] {
        try await base.existingContextRecords()
    }

    func write(records: [HoloMemoryRecord], batchKey: String) async throws {
        try await base.write(records: records, batchKey: batchKey)
    }

    func hasSuccessfulBatch(batchKey: String) async throws -> Bool {
        try await base.hasSuccessfulBatch(batchKey: batchKey)
    }

    func activeTombstones() async throws -> [HoloMemoryTombstone] {
        try await base.activeTombstones()
    }

    func loadCursor() async throws -> HoloContextExtractionCursorState? {
        try await base.loadCursor()
    }

    func saveCursor(_ cursor: HoloContextExtractionCursorState) async throws {
        try await base.saveCursor(cursor)
    }

    func currentGeneration() async throws -> HoloContextExtractionGeneration {
        generationCallCount += 1
        if generationCallCount == 1 {
            return base.generation
        }
        return HoloContextExtractionGeneration(
            userDecisionVersion: base.generation.userDecisionVersion + 1_000,
            learningBaselineAt: base.generation.learningBaselineAt
        )
    }

    func currentSourceRevisions(sourceIDs: [String]) async throws -> [String: String] {
        try await base.currentSourceRevisions(sourceIDs: sourceIDs)
    }
}
