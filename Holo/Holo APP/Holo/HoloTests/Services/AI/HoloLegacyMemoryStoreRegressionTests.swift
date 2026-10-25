import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloLegacyMemoryStoreRegressionTests.main()
    }
}
#endif
struct HoloLegacyMemoryStoreRegressionTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    private static func makeTemporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-legacy-memory-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func makeEvidence(_ id: String) -> HoloLongTermMemoryEvidence {
        HoloLongTermMemoryEvidence(
            id: "evidence-\(id)",
            source: .habits,
            sourceID: "source-\(id)",
            excerpt: "测试证据 \(id)",
            observedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
    }

    private static func makeLongTermMemory(_ id: String) -> HoloLongTermMemory {
        HoloLongTermMemory(
            id: id,
            subjectKey: "habit:\(id)",
            title: "测试记忆 \(id)",
            confidence: .medium,
            confirmationState: .candidate,
            sensitivity: .normal,
            evidence: [makeEvidence(id)],
            createdAt: Date(timeIntervalSince1970: 1_720_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_720_000_000),
            expiresAt: nil,
            semanticType: .stablePattern,
            displaySummary: "测试摘要 \(id)",
            aiUseSummary: "测试上下文 \(id)",
            useScopes: [.coreContext],
            prohibitedInferences: ["不要扩大推断"]
        )
    }

    private static func makeEpisodicMemory(_ id: String) -> HoloEpisodicMemory {
        HoloEpisodicMemory(
            id: id,
            title: "情景记忆 \(id)",
            summary: "情景摘要 \(id)",
            state: .active,
            visibility: .hidden,
            confidence: .medium,
            sensitivity: .normal,
            hitCount: 1,
            semanticHitRunIDs: [],
            evidence: [makeEvidence(id)],
            createdAt: Date(timeIntervalSince1970: 1_720_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_720_000_000),
            lastHitAt: nil,
            expiresAt: Date(timeIntervalSince1970: 1_730_000_000),
            sourceModules: [.habits],
            reasoningSummary: nil,
            userEditedSummary: nil,
            promotedLongTermMemoryID: nil,
            createdFromRunID: "run-\(id)"
        )
    }

    private static func testEpisodicFirstWriteAndInterruptedTempFile() throws {
        let directory = try makeTemporaryDirectory("episodic-first-write")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HoloEpisodicMemoryStore(directoryURL: directory)
        let memory = makeEpisodicMemory("first")
        store.save([memory])

        expect(store.load() == [memory], "情景记忆首次写入后必须可读")

        let tempURL = directory.appendingPathComponent("episodicMemories_temp.json")
        try Data("interrupted-write".utf8).write(to: tempURL)
        expect(store.load() == [memory], "中断遗留的临时文件不能替代正式 Store")
    }

    private static func testEpisodicConcurrentMutations() throws {
        let directory = try makeTemporaryDirectory("episodic-concurrency")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HoloEpisodicMemoryStore(directoryURL: directory)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "holo.episodic.test", attributes: .concurrent)

        for id in ["alpha", "beta"] {
            group.enter()
            queue.async {
                store.upsert(makeEpisodicMemory(id))
                group.leave()
            }
        }
        group.wait()

        expect(Set(store.load().map(\.id)) == Set(["alpha", "beta"]),
               "情景记忆并发 mutation 不能互相覆盖")
    }

    private static func testLongTermFirstWriteAndConcurrentMutations() throws {
        let directory = try makeTemporaryDirectory("long-term")
        defer { try? FileManager.default.removeItem(at: directory) }

        let defaultsName = "holo.legacy-memory-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            fatalError("无法创建隔离 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let store = HoloLongTermMemoryFileStore(
            directoryURL: directory,
            defaults: defaults,
            migrationKey: "migration-complete"
        )
        let first = makeLongTermMemory("first")
        try store.save([first])
        expect(store.load() == [first], "长期记忆首次写入后必须可读")

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "holo.long-term.test", attributes: .concurrent)
        for id in ["alpha", "beta"] {
            group.enter()
            queue.async {
                _ = store.upsertCandidate(makeLongTermMemory(id))
                group.leave()
            }
        }
        group.wait()

        let ids = Set(store.load().map(\.id))
        expect(ids.isSuperset(of: ["first", "alpha", "beta"]),
               "长期记忆并发 mutation 不能互相覆盖")

        let tempURL = directory.appendingPathComponent("HoloLongTermMemories_temp.json")
        try Data("interrupted-write".utf8).write(to: tempURL)
        expect(Set(store.load().map(\.id)) == ids,
               "长期记忆中断遗留的临时文件不能替代正式 Store")
    }

    static func main() throws {
        try testEpisodicFirstWriteAndInterruptedTempFile()
        try testEpisodicConcurrentMutations()
        try testLongTermFirstWriteAndConcurrentMutations()
        try testLongTermDeleteMemoriesReferencingThoughts()
        print("HoloLegacyMemoryStoreRegressionTests passed: \(assertionCount) assertions")
    }

    /// 标签级 AI 排除（2026-10-21 方案）：按证据源想法删除长期记忆——
    /// 「含即删」口径（宁可少记一条，不可漏一条）。放 Standalone：FileStore 在
    /// XCTest 宿主内同步测试会触发 malloc 析构崩溃（前人实证，见 welcomenote 1015 坑）。
    private static func testLongTermDeleteMemoriesReferencingThoughts() throws {
        let directory = try makeTemporaryDirectory("long-term-ai-exclusion")
        defer { try? FileManager.default.removeItem(at: directory) }

        let defaultsName = "holo.legacy-memory-tests.ai-exclusion.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            fatalError("无法创建隔离 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let store = HoloLongTermMemoryFileStore(
            directoryURL: directory,
            defaults: defaults,
            migrationKey: "migration-complete"
        )

        let excludedThoughtID = UUID().uuidString.lowercased()
        let normalThoughtID = UUID().uuidString.lowercased()

        // 依据排除想法 / 依据正常想法 / 非想法域（habits）三条记忆
        var excludedBased = makeLongTermMemory("m-excluded")
        excludedBased.evidence = [
            HoloLongTermMemoryEvidence(
                id: "m-excluded-e", source: .thoughts, sourceID: excludedThoughtID,
                excerpt: "依据", observedAt: Date(timeIntervalSince1970: 1_720_000_000))
        ]
        var normalBased = makeLongTermMemory("m-normal")
        normalBased.evidence = [
            HoloLongTermMemoryEvidence(
                id: "m-normal-e", source: .thoughts, sourceID: normalThoughtID,
                excerpt: "依据", observedAt: Date(timeIntervalSince1970: 1_720_000_000))
        ]
        try store.save([excludedBased, normalBased, makeLongTermMemory("m-habit")])

        let removed = store.deleteMemoriesReferencing(thoughtIDs: [excludedThoughtID])

        expect(removed == 1, "只删证据命中排除想法的记忆")
        expect(Set(store.load().map(\.id)) == ["m-normal", "m-habit"],
               "正常想法记忆与非想法域记忆保留")

        // 幂等：重复删除无匹配、不误删
        expect(store.deleteMemoriesReferencing(thoughtIDs: [excludedThoughtID]) == 0,
               "重复删除不再有条目可删")
        expect(store.deleteMemoriesReferencing(thoughtIDs: [normalThoughtID]) == 1,
               "正常想法的 id 同样可按口径删除（口径通用）")
    }
}
