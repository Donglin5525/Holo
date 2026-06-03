//
//  HoloLongTermMemoryStoreTests.swift
//  HoloTests
//
//  测试长期记忆 Store 日期编解码、损坏恢复、旧 Schema 兼容
//

import XCTest
@testable import Holo

final class HoloLongTermMemoryStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeMemory(
        id: String = UUID().uuidString,
        title: String = "测试记忆",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) -> HoloLongTermMemory {
        HoloLongTermMemory(
            id: id,
            type: .explicitUserPreference,
            title: title,
            summary: "测试摘要",
            confidence: .medium,
            confirmationState: .candidate,
            sensitivity: .normal,
            evidence: [
                HoloLongTermMemoryEvidence(
                    id: UUID().uuidString,
                    source: .conversation,
                    sourceID: nil,
                    excerpt: "测试证据",
                    observedAt: createdAt
                )
            ],
            createdAt: createdAt,
            updatedAt: updatedAt,
            expiresAt: nil
        )
    }

    private func truncateToSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(Int(date.timeIntervalSince1970)))
    }

    override func tearDown() {
        // 清理测试数据：删除所有记忆后保存空数组
        let memories = HoloLongTermMemoryStore.load()
        if !memories.isEmpty {
            try? HoloLongTermMemoryStore.save([])
        }
        super.tearDown()
    }

    // MARK: - Task 0.1: 日期解码 bug 修复验证

    func testSaveAndLoad_日期字段保持一致() throws {
        let expectedCreatedAt = truncateToSeconds(Date().addingTimeInterval(-86400))
        let expectedUpdatedAt = truncateToSeconds(Date())
        let expectedObservedAt = truncateToSeconds(Date().addingTimeInterval(-3600))

        let memory = HoloLongTermMemory(
            id: "date-test-1",
            type: .recurringPattern,
            title: "日期测试",
            summary: "验证日期编解码一致性",
            confidence: .high,
            confirmationState: .candidate,
            sensitivity: .normal,
            evidence: [
                HoloLongTermMemoryEvidence(
                    id: "evidence-1",
                    source: .habits,
                    sourceID: nil,
                    excerpt: "习惯证据",
                    observedAt: expectedObservedAt
                )
            ],
            createdAt: expectedCreatedAt,
            updatedAt: expectedUpdatedAt,
            expiresAt: nil
        )

        try HoloLongTermMemoryStore.save([memory])
        let loaded = HoloLongTermMemoryStore.load()

        XCTAssertEqual(loaded.count, 1)
        let loadedMemory = try XCTUnwrap(loaded.first)

        XCTAssertEqual(truncateToSeconds(loadedMemory.createdAt), expectedCreatedAt)
        XCTAssertEqual(truncateToSeconds(loadedMemory.updatedAt), expectedUpdatedAt)
        XCTAssertEqual(truncateToSeconds(loadedMemory.evidence.first!.observedAt), expectedObservedAt)
    }

    func testLoad_损坏文件时返回空数组不崩溃() throws {
        // 写入非法 JSON
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeURL = appSupport.appendingPathComponent("Holo/HoloLongTermMemories.json")
        let dir = storeURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ invalid json !!!".utf8).write(to: storeURL)

        let loaded = HoloLongTermMemoryStore.load()
        XCTAssertEqual(loaded.isEmpty, true)
    }

    func testLoad_文件不存在时返回空数组() {
        // 先删除文件
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeURL = appSupport.appendingPathComponent("Holo/HoloLongTermMemories.json")
        if fm.fileExists(atPath: storeURL.path) {
            try? fm.removeItem(at: storeURL)
        }

        let loaded = HoloLongTermMemoryStore.load()
        XCTAssertEqual(loaded.isEmpty, true)
    }

    // MARK: - Task 0.3: 旧 Schema 兼容测试

    func testLoad_OldSchema_缺失字段不崩溃() throws {
        // 模拟旧 Schema：只有 id/title/summary/createdAt/updatedAt
        let minimalJSON = """
        [{
            "id": "old-1",
            "type": "explicitUserPreference",
            "title": "旧记忆",
            "summary": "旧格式摘要",
            "confidence": "medium",
            "confirmationState": "candidate",
            "sensitivity": "normal",
            "evidence": [],
            "createdAt": "2025-06-01T00:00:00Z",
            "updatedAt": "2025-06-01T00:00:00Z"
        }]
        """

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeURL = appSupport.appendingPathComponent("Holo/HoloLongTermMemories.json")
        let dir = storeURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(minimalJSON.utf8).write(to: storeURL)

        let loaded = HoloLongTermMemoryStore.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "旧记忆")
        XCTAssertNil(loaded.first?.expiresAt)
    }

    func testSaveAndLoad_SchemaVersion兼容() throws {
        // 先写入一个旧格式记忆
        let oldJSON = """
        [{
            "id": "compat-1",
            "type": "recurringPattern",
            "title": "兼容性测试",
            "summary": "旧格式",
            "confidence": "high",
            "confirmationState": "confirmed",
            "sensitivity": "normal",
            "evidence": [],
            "createdAt": "2025-01-15T12:00:00Z",
            "updatedAt": "2025-01-15T12:00:00Z"
        }]
        """

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeURL = appSupport.appendingPathComponent("Holo/HoloLongTermMemories.json")
        let dir = storeURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(oldJSON.utf8).write(to: storeURL)

        // 加载旧格式
        var loaded = HoloLongTermMemoryStore.load()
        XCTAssertEqual(loaded.count, 1)

        // 追加新记忆并保存
        let newMemory = makeMemory(id: "compat-2", title: "新记忆")
        loaded.append(newMemory)
        try HoloLongTermMemoryStore.save(loaded)

        // 再次加载验证全部成功
        let reloaded = HoloLongTermMemoryStore.load()
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.first?.title, "兼容性测试")
        XCTAssertEqual(reloaded.last?.title, "新记忆")
    }
}
