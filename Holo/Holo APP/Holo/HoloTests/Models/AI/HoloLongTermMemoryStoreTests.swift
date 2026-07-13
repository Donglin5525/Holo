//
//  HoloLongTermMemoryStoreTests.swift
//  HoloTests
//
//  测试长期记忆 Store 日期编解码、损坏恢复和严格 V2 迁移
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
            subjectKey: "test:\(id)",
            title: title,
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
            expiresAt: nil,
            semanticType: .stablePattern,
            displaySummary: "测试摘要",
            aiUseSummary: "仅在相关测试场景使用，不扩展推断。",
            useScopes: [.coreContext],
            prohibitedInferences: ["不要扩展推断"]
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
            subjectKey: "habit:date-test",
            title: "日期测试",
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
            expiresAt: nil,
            semanticType: .stablePattern,
            displaySummary: "验证日期编解码一致性",
            aiUseSummary: "仅用于验证日期，不做其他推断。",
            useScopes: [.coreContext],
            prohibitedInferences: ["不要扩展推断"]
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

    // MARK: - 严格 V2 迁移

    func testMigration_旧格式直接删除() throws {
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

        let result = try HoloLongTermMemoryMigration.decodeAndFilter(Data(minimalJSON.utf8))
        XCTAssertEqual(result.removedLegacyCount, 1)
        XCTAssertTrue(result.memories.isEmpty)
    }

    func testMigration_缺少稳定主题键的新格式直接删除() throws {
        let invalidV2JSON = """
        [{
            "id": "compat-1",
            "type": "recurringPattern",
            "title": "兼容性测试",
            "summary": "旧格式",
            "confidence": "high",
            "confirmationState": "confirmed",
            "sensitivity": "normal",
            "evidence": [{"id":"e1","source":"memoryInsight","sourceID":"h1","excerpt":"证据","observedAt":"2025-01-15T12:00:00Z"}],
            "createdAt": "2025-01-15T12:00:00Z",
            "updatedAt": "2025-01-15T12:00:00Z",
            "semanticType": "stablePattern",
            "displaySummary": "稳定记录",
            "aiUseSummary": "只在相关场景参考",
            "useScopes": ["coreContext"],
            "prohibitedInferences": ["不要扩展推断"]
        }]
        """

        let result = try HoloLongTermMemoryMigration.decodeAndFilter(Data(invalidV2JSON.utf8))
        XCTAssertEqual(result.removedInvalidCount, 1)
        XCTAssertTrue(result.memories.isEmpty)
    }
}
