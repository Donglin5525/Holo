//
//  ContextInputCompletenessStandaloneTests.swift
//  HoloTests
//
//  体检 G1 输入完整性验收：探针 A06/A08/A11 转正确行为断言。
//  - A06：萃取与核验 Prompt 携带完整来源契约（业务状态/归属/领域/种类/血缘）。
//  - A08：单条长来源切段跨多包时逐包全部萃取（批次键含片段范围指纹）。
//  - A11：(updatedAt,id) 游标下推数据库，151 行与 1001 条同秒输入都完整触达；
//    学习基线过滤生效；追平返回 nil 游标且萃取水位不被清空。
//  standalone 运行见 scripts/run-personal-context-standalone.sh。
//

import CoreData
import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await ContextInputCompletenessStandaloneTests.main()
    }
}
#endif
struct ContextInputCompletenessStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        testExtractionPromptCarriesSourceContract()
        testVerificationPromptCarriesSourceContract()
        try await testLongSourceExtractsAllPackages()
        try testCursorPaginationReachesAllRows()
        try testCursorPaginationSameSecondFlood()
        try testCursorPaginationBaseline()
        try await testCaughtUpKeepsWatermark()
        print("ContextInputCompletenessStandaloneTests: \(assertionCount) assertions passed")
    }

    // MARK: - A06 来源契约

    private static func makeContractSource() -> HoloContextSourceSnapshot {
        HoloContextSourceSnapshot(
            sourceID: "task:1",
            sourceDomain: "task",
            sourceKind: "todoTask",
            revisionDigest: "r1",
            sourceCreatedAt: Date(timeIntervalSince1970: 1_791_072_000),
            sourceUpdatedAt: Date(timeIntervalSince1970: 1_791_072_000),
            plainText: "任务「买猫粮」",
            sensitivity: .normal,
            accessGeneration: 1,
            authorship: "quoted",
            lineageRootIDs: ["evt-1"],
            businessState: ["completed": "false"]
        )
    }

    /// A06 修复断言：运行时已有的业务状态、归属、领域、种类、血缘必须进萃取 Prompt。
    private static func testExtractionPromptCarriesSourceContract() {
        let source = makeContractSource()
        let prompt = HoloPersonalContextPromptBuilder.extractionPrompt(
            packageSegments: HoloContextSegmenter.segments(for: source),
            sourcesByID: [source.sourceID: source],
            existingCandidates: []
        )
        for field in ["businessState", "completed", "sourceDomain", "sourceKind",
                      "authorship", "lineageRootIDs"] {
            expect(prompt.contains(field), "萃取 Prompt 必须携带来源契约字段 \(field)")
        }
        expect(prompt.contains("\"false\""), "计划/完成状态值必须原样进入 Prompt")
        expect(prompt.contains("quoted"), "归属标记必须原样进入 Prompt")
    }

    /// A06 修复断言：核验器看到同一份来源契约。
    private static func testVerificationPromptCarriesSourceContract() {
        let source = makeContractSource()
        let candidate = HoloContextExtractionCandidateDTO(
            candidateRef: "c1",
            statement: "用户养猫",
            subjects: [.init(label: "我", scope: .user)],
            facets: [.init(kind: .preference)],
            epistemicStatus: "observed",
            basis: [.init(sourceID: source.sourceID, quote: "买猫粮", revision: "r1")],
            openQuestions: []
        )
        let prompt = HoloPersonalContextPromptBuilder.verificationPrompt(
            candidates: [candidate],
            sourcesByID: [source.sourceID: source]
        )
        for field in ["businessState", "completed", "sourceDomain", "sourceKind",
                      "authorship", "lineageRootIDs"] {
            expect(prompt.contains(field), "核验 Prompt 必须携带来源契约字段 \(field)")
        }
    }

    // MARK: - A08 长来源分包

    private class PackageCountingWriter: HoloPersonalContextRecordWriting, @unchecked Sendable {
        var receipts = Set<String>()
        func existingContextRecords() async throws -> [HoloMemoryRecord] { [] }
        func write(records: [HoloMemoryRecord], batchKey: String) async throws {
            receipts.insert(batchKey)
        }
        func hasSuccessfulBatch(batchKey: String) async throws -> Bool { receipts.contains(batchKey) }
        func activeTombstones() async throws -> [HoloMemoryTombstone] { [] }
        func loadCursor() async throws -> HoloContextExtractionCursorState? { nil }
        func saveCursor(_ cursor: HoloContextExtractionCursorState) async throws {}
        func loadCursor(domain: String) async throws -> HoloContextExtractionCursorState? { nil }
        func saveCursor(_ cursor: HoloContextExtractionCursorState, domain: String) async throws {}
        func currentGeneration() async throws -> HoloContextExtractionGeneration {
            .init(userDecisionVersion: 1, learningBaselineAt: nil)
        }
        func currentSourceRevisions(sourceIDs: [String]) async throws -> [String: String] { [:] }
    }

    private final class EmptyLLM: HoloPersonalContextLLMCalling, @unchecked Sendable {
        var extractionCalls = 0
        func extract(prompt: String) async throws -> String {
            extractionCalls += 1
            return "{\"candidates\":[],\"counterEvidence\":[]}"
        }
        func verify(prompt: String) async throws -> String { "{\"verdicts\":[]}" }
    }

    /// A08 修复断言：18000 字单条想法切出的每个包都必须各萃取一次（旧缺陷只调 1 次）。
    private static func testLongSourceExtractsAllPackages() async throws {
        let now = Date(timeIntervalSince1970: 1_791_072_000)
        let longSource = HoloContextSourceSnapshot(
            sourceID: "long-note",
            sourceDomain: "thought",
            sourceKind: "userNote",
            revisionDigest: "r1",
            sourceCreatedAt: now,
            sourceUpdatedAt: now,
            plainText: String(repeating: "长", count: 18_000),
            sensitivity: .normal,
            accessGeneration: 1
        )
        var remaining = HoloContextSegmenter.segments(for: longSource)
        var expectedPackages = 0
        while !remaining.isEmpty {
            let (pack, rest) = HoloContextSegmenter.packageSegments(remaining)
            guard !pack.isEmpty else { break }
            expectedPackages += 1
            remaining = rest
        }
        expect(expectedPackages > 1, "18000 字应切出多包（实际 \(expectedPackages)），样本失效")

        let llm = EmptyLLM()
        let writer = PackageCountingWriter()
        let extractor = HoloPersonalContextExtractor(
            paging: HoloContextInMemorySourcePaging(sources: [longSource]),
            llm: llm,
            writer: writer
        )
        _ = try await extractor.runOneBatch(now: now)
        expect(llm.extractionCalls == expectedPackages,
               "多包来源应萃取 \(expectedPackages) 次，实际 \(llm.extractionCalls) 次——批次键必须区分同来源的不同包")
        expect(writer.receipts.count == expectedPackages,
               "每个包应有独立批次回执")
    }

    // MARK: - A11 游标下推分页（真实 Core Data 内存库）

    /// 动态实体内存库：与探针同法，不依赖工程模型。
    private static func makeInMemoryContext() throws -> NSManagedObjectContext {
        let entity = NSEntityDescription()
        entity.name = "AuditRow"
        entity.managedObjectClassName = String(describing: NSManagedObject.self)
        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .stringAttributeType
        let timestamp = NSAttributeDescription()
        timestamp.name = "updatedAt"
        timestamp.attributeType = .dateAttributeType
        entity.properties = [id, timestamp]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    private static func insertRow(
        _ context: NSManagedObjectContext,
        id: String,
        updatedAt: Date
    ) {
        let item = NSEntityDescription.insertNewObject(forEntityName: "AuditRow", into: context)
        item.setValue(id, forKey: "id")
        item.setValue(updatedAt, forKey: "updatedAt")
    }

    /// 用共享分页骨架连续翻页，返回触达的全部行 id。
    private static func drainAllRows(
        context: NSManagedObjectContext,
        limit: Int,
        baseline: Date? = nil
    ) throws -> [String] {
        var reached: [String] = []
        var cursor: HoloContextSourceCursor?
        for _ in 0..<200 {
            let (page, next) = try HoloContextCursorPagination.page(
                context: context,
                entityName: "AuditRow",
                alivePredicate: NSPredicate(format: "TRUEPREDICATE"),
                cursor: cursor,
                baseline: baseline,
                limit: limit,
                time: { $0.value(forKey: "updatedAt") as! Date },
                cursorKey: { $0.value(forKey: "id") as! String },
                makeSnapshot: { row in
                    HoloContextSourceSnapshot(
                        sourceID: row.value(forKey: "id") as! String,
                        sourceDomain: "audit",
                        sourceKind: "row",
                        revisionDigest: "r",
                        sourceCreatedAt: row.value(forKey: "updatedAt") as! Date,
                        sourceUpdatedAt: row.value(forKey: "updatedAt") as! Date,
                        plainText: "",
                        sensitivity: .normal,
                        accessGeneration: 1
                    )
                }
            )
            reached.append(contentsOf: page.map { $0.sourceID })
            guard let next else { break }
            cursor = next
        }
        return reached
    }

    /// A11 修复断言：151 行按 50 一页连续翻页必须全部触达（旧缺陷 [50,50,0,50] 只到 100）。
    private static func testCursorPaginationReachesAllRows() throws {
        let context = try makeInMemoryContext()
        let base = Date(timeIntervalSince1970: 1_791_072_000)
        for index in 1...151 {
            insertRow(context, id: String(format: "%03d", index), updatedAt: base.addingTimeInterval(Double(index)))
        }
        try context.save()
        let reached = try drainAllRows(context: context, limit: 50)
        expect(reached.count == 151, "151 行应全部触达，实际 \(reached.count)")
        expect(Set(reached).count == 151, "触达行不得重复")
    }

    /// A11 修复断言：1001 条同秒批量导入（同秒风暴）也必须全部触达。
    private static func testCursorPaginationSameSecondFlood() throws {
        let context = try makeInMemoryContext()
        let sameSecond = Date(timeIntervalSince1970: 1_791_072_000)
        for index in 1...1001 {
            insertRow(context, id: String(format: "%04d", index), updatedAt: sameSecond)
        }
        try context.save()
        let reached = try drainAllRows(context: context, limit: 50)
        expect(reached.count == 1001, "同秒 1001 行应全部触达，实际 \(reached.count)")
        expect(Set(reached).count == 1001, "同秒触达行不得重复")
    }

    /// 学习基线下推断言：基线之前的来源不返回。
    private static func testCursorPaginationBaseline() throws {
        let context = try makeInMemoryContext()
        let base = Date(timeIntervalSince1970: 1_791_072_000)
        for index in 1...30 {
            insertRow(context, id: String(format: "%03d", index), updatedAt: base.addingTimeInterval(Double(index) * 100))
        }
        try context.save()
        let baseline = base.addingTimeInterval(1_500)
        let reached = try drainAllRows(context: context, limit: 7, baseline: baseline)
        expect(reached.count == 16, "基线之后（updatedAt≥基线）应剩 16 行，实际 \(reached.count)")
    }

    // MARK: - 追平保留水位

    /// G1 修复断言：全库追平（空页）后萃取游标必须保留，不得清空重启全历史。
    private static func testCaughtUpKeepsWatermark() async throws {
        final class CursorRecordingWriter: PackageCountingWriter, @unchecked Sendable {
            var savedCursors: [HoloContextExtractionCursorState] = []
            override func saveCursor(_ cursor: HoloContextExtractionCursorState, domain: String) async throws {
                savedCursors.append(cursor)
            }
        }
        let now = Date(timeIntervalSince1970: 1_791_072_000)
        let source = HoloContextSourceSnapshot(
            sourceID: "only-note",
            sourceDomain: "thought",
            sourceKind: "userNote",
            revisionDigest: "r1",
            sourceCreatedAt: now,
            sourceUpdatedAt: now,
            plainText: "短想法",
            sensitivity: .normal,
            accessGeneration: 1
        )
        let writer = CursorRecordingWriter()
        let extractor = HoloPersonalContextExtractor(
            paging: HoloContextInMemorySourcePaging(sources: [source]),
            llm: EmptyLLM(),
            writer: writer
        )
        _ = try await extractor.runOneBatch(now: now)
        // 第二轮：全库已追平，页为空。
        _ = try await extractor.runOneBatch(now: now.addingTimeInterval(60))
        guard let lastCursor = writer.savedCursors.last else {
            expect(false, "追平轮应保存游标（watermark 更新）")
            return
        }
        expect(lastCursor.sourceCursor != nil,
               "追平后水位必须保留，不得清空重启全历史")
    }
}
