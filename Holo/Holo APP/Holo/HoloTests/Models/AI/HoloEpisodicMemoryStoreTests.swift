//
//  HoloEpisodicMemoryStoreTests.swift
//  HoloTests
//
//  测试情景记忆 Store 的 CRUD、过期、拒绝、suppression
//

import XCTest
@testable import Holo

final class HoloEpisodicMemoryStoreTests: XCTestCase {

    private var store: HoloEpisodicMemoryStore!

    override func setUp() {
        super.setUp()
        store = HoloEpisodicMemoryStore.shared
        // 清空数据
        store.save([])
        store.saveSuppressionRules([])
    }

    override func tearDown() {
        store.save([])
        store.saveSuppressionRules([])
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeMemory(
        id: String = UUID().uuidString,
        title: String = "测试情景记忆",
        state: HoloEpisodicMemoryState = .active,
        expiresAt: Date = Date().addingTimeInterval(86400 * 30)
    ) -> HoloEpisodicMemory {
        HoloEpisodicMemory(
            id: id,
            title: title,
            summary: "测试摘要",
            state: state,
            visibility: .suggested,
            confidence: .medium,
            sensitivity: .normal,
            hitCount: 0,
            semanticHitRunIDs: [],
            evidence: [],
            createdAt: Date(),
            updatedAt: Date(),
            lastHitAt: nil,
            expiresAt: expiresAt,
            sourceModules: [.habits],
            reasoningSummary: nil,
            userEditedSummary: nil,
            promotedLongTermMemoryID: nil,
            createdFromRunID: "test-run-1"
        )
    }

    // MARK: - Save & Load

    func testSaveAndLoad_日期策略一致() {
        let expectedCreatedAt = Date().addingTimeInterval(-86400)
        let expectedExpiresAt = Date().addingTimeInterval(86400 * 60)

        var memory = makeMemory(id: "date-test")
        memory.createdAt = expectedCreatedAt
        memory.expiresAt = expectedExpiresAt

        store.save([memory])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1)
        let loadedMemory = loaded.first!

        // ISO8601 精度到秒
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.year, from: loadedMemory.createdAt),
                       cal.component(.year, from: expectedCreatedAt))
        XCTAssertEqual(cal.component(.month, from: loadedMemory.createdAt),
                       cal.component(.month, from: expectedCreatedAt))
        XCTAssertEqual(cal.component(.day, from: loadedMemory.createdAt),
                       cal.component(.day, from: expectedCreatedAt))
    }

    func testSaveAndLoad_空Store往返() {
        store.save([])
        let loaded = store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Upsert

    func testUpsert_新增与更新() {
        let memory = makeMemory(id: "upsert-1", title: "新增记忆")
        store.upsert(memory)
        XCTAssertEqual(store.load().count, 1)

        var updated = memory
        updated.title = "更新后标题"
        updated.state = .active
        store.upsert(updated)

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "更新后标题")
    }

    // MARK: - State

    func testUpdateState_状态转换() {
        let memory = makeMemory(id: "state-1", state: .suggested)
        store.save([memory])

        store.updateState(id: "state-1", to: .active)
        let loaded = store.load()
        XCTAssertEqual(loaded.first?.state, .active)
    }

    // MARK: - Expiry

    func testMarkExpired_超期记忆自动过期() {
        // 创建一个已过期的记忆
        let expiredMemory = makeMemory(
            id: "expired-1",
            state: .active,
            expiresAt: Date().addingTimeInterval(-1)  // 已过期
        )
        store.save([expiredMemory])

        let expiredIDs = store.markExpired()
        XCTAssertEqual(expiredIDs, ["expired-1"])

        let loaded = store.load()
        XCTAssertEqual(loaded.first?.state, .expired)
    }

    // MARK: - Reject & Suppression

    func testReject_生成SuppressionRule() {
        let memory = makeMemory(id: "reject-1", title: "抽烟控制", state: .suggested)
        store.save([memory])

        let rule = store.reject(id: "reject-1")
        XCTAssertNotNil(rule)
        XCTAssertFalse(rule!.keywordGroups.isEmpty)

        let loaded = store.load()
        XCTAssertEqual(loaded.first?.state, .rejected)

        let rules = store.loadSuppressionRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertGreaterThan(rules.first!.suppressedUntil, Date())
    }

    func testLoadSuppressionRules_过期规则自动清理() {
        // 保存一个已过期的 rule
        let expiredRule = HoloMemorySuppressionRule(
            id: "rule-expired",
            originalMemorySummary: "测试",
            keywordGroups: [["测试"]],
            suppressedUntil: Date().addingTimeInterval(-86400),  // 昨天过期
            originalRejectedAt: Date().addingTimeInterval(-86400 * 31)
        )
        store.saveSuppressionRules([expiredRule])

        let rules = store.loadSuppressionRules()
        XCTAssertTrue(rules.isEmpty, "已过期的 suppression rule 应被自动清理")
    }

    // MARK: - Corrupted File

    func test损坏文件_备份恢复() {
        // 直接写入非法 JSON
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo/Memory", isDirectory: true)
        let storeURL = dir.appendingPathComponent("episodicMemories.json")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("{ broken !!!".utf8).write(to: storeURL)

        let loaded = store.load()
        XCTAssertTrue(loaded.isEmpty, "损坏文件应返回空数组")

        // 验证备份文件被创建
        let backupURL = dir.appendingPathComponent("episodicMemories.backup.json")
        XCTAssertTrue(fm.fileExists(atPath: backupURL.path), "应创建备份文件")
    }

    // MARK: - Query

    func testQueryActive_只返回Active和Suggested() {
        let memories = [
            makeMemory(id: "q-1", state: .active),
            makeMemory(id: "q-2", state: .suggested),
            makeMemory(id: "q-3", state: .expired),
            makeMemory(id: "q-4", state: .rejected),
        ]
        store.save(memories)

        let active = store.queryActive()
        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(Set(active.map(\.id)), Set(["q-1", "q-2"]))
    }
}
