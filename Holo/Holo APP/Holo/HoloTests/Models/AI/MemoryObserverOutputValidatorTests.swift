//
//  MemoryObserverOutputValidatorTests.swift
//  HoloTests
//
//  测试 Observer 输出校验器
//

import XCTest
@testable import Holo

final class MemoryObserverOutputValidatorTests: XCTestCase {

    // MARK: - Helpers

    private func makePackage(signalIDs: [String] = ["sig-1", "sig-2", "sig-3"],
                             episodicIDs: [String] = ["ep-1", "ep-2"]) -> HoloObservationPackage {
        let now = Date()
        let signals = signalIDs.map { id in
            HoloMemorySignal(
                id: id, title: "信号\(id)", detail: "详情",
                polarity: .negative, confidence: 0.7,
                sourceModule: .habits, evidenceRefs: [], generatedAt: now
            )
        }
        let episodicSummaries = episodicIDs.map { id in
            HoloEpisodicMemorySummary(
                id: id, title: "记忆\(id)", summary: "摘要",
                state: .active, hitCount: 1, lastHitAt: nil
            )
        }
        return HoloObservationPackage(
            runID: "test-run",
            period: ObservationPeriod(start: "", end: "", window: "fourteenDays"),
            habitSignals: signals,
            goalSignals: [],
            existingEpisodicMemories: episodicSummaries,
            existingLongTermMemories: [],
            memoryFeedbackHistory: [],
            suppressionRules: [],
            estimatedTokens: 0,
            truncated: false
        )
    }

    private func makeEntry(title: String = "测试",
                           confidence: Double = 0.7,
                           evidenceRefs: [String] = ["sig-1"],
                           expiresInDays: Int = 30,
                           sensitivity: String = "normal",
                           visibility: String = "suggested") -> NewEpisodicMemoryEntry {
        NewEpisodicMemoryEntry(
            title: title,
            memoryText: "测试记忆内容",
            confidence: confidence,
            sensitivity: sensitivity,
            visibility: visibility,
            evidenceRefs: evidenceRefs,
            reasoningSummary: "测试原因",
            expiresInDays: expiresInDays
        )
    }

    // MARK: - Tests

    func testValidate_正常输出_全部通过() {
        let package = makePackage()
        let output = HoloMemoryObserverOutput(
            newEpisodicMemories: [makeEntry()],
            memoryHits: [MemoryHitEntry(episodicMemoryID: "ep-1", hitReasoning: "相关")],
            weakenedOrExpiredMemories: [WeakenedEntry(episodicMemoryID: "ep-2", reason: "已过期")]
        )

        let result = MemoryObserverOutputValidator.validate(output, against: package, suppressionRules: [])
        XCTAssertEqual(result.validNewMemories.count, 1)
        XCTAssertEqual(result.validHits.count, 1)
        XCTAssertEqual(result.validWeakened.count, 1)
        XCTAssertTrue(result.rejectedEntries.isEmpty)
    }

    func testValidate_非法confidence_被过滤() {
        let package = makePackage()
        let output = HoloMemoryObserverOutput(
            newEpisodicMemories: [makeEntry(confidence: 1.5)],
            memoryHits: [], weakenedOrExpiredMemories: []
        )

        let result = MemoryObserverOutputValidator.validate(output, against: package, suppressionRules: [])
        XCTAssertEqual(result.validNewMemories.count, 0)
        XCTAssertEqual(result.rejectedEntries.count, 1)
    }

    func testValidate_低confidence_被过滤() {
        let package = makePackage()
        let output = HoloMemoryObserverOutput(
            newEpisodicMemories: [makeEntry(confidence: 0.3)],
            memoryHits: [], weakenedOrExpiredMemories: []
        )

        let result = MemoryObserverOutputValidator.validate(output, against: package, suppressionRules: [])
        XCTAssertEqual(result.validNewMemories.count, 0)
        XCTAssertEqual(result.rejectedEntries.count, 1)
    }

    func testValidate_幻觉evidenceRefs_被过滤() {
        let package = makePackage()
        let output = HoloMemoryObserverOutput(
            newEpisodicMemories: [makeEntry(evidenceRefs: ["hallucinated-1", "hallucinated-2"])],
            memoryHits: [], weakenedOrExpiredMemories: []
        )

        let result = MemoryObserverOutputValidator.validate(output, against: package, suppressionRules: [])
        XCTAssertEqual(result.validNewMemories.count, 0)
        XCTAssertEqual(result.rejectedEntries.count, 1)
        XCTAssertTrue(result.rejectedEntries.first?.reason.contains("幻觉") == true)
    }

    func testValidate_敏感记忆hidden_被过滤() {
        let package = makePackage()
        let output = HoloMemoryObserverOutput(
            newEpisodicMemories: [makeEntry(sensitivity: "sensitive", visibility: "hidden")],
            memoryHits: [], weakenedOrExpiredMemories: []
        )

        let result = MemoryObserverOutputValidator.validate(output, against: package, suppressionRules: [])
        XCTAssertEqual(result.validNewMemories.count, 0)
        XCTAssertEqual(result.rejectedEntries.count, 1)
    }

    func testValidate_suppression命中_被拦截() {
        let package = makePackage()
        let rule = HoloMemorySuppressionRule(
            id: "rule-1",
            originalMemorySummary: "抽烟控制",
            keywordGroups: [["抽烟", "烟草"]],
            suppressedUntil: Date().addingTimeInterval(86400 * 30),
            originalRejectedAt: Date()
        )

        let output = HoloMemoryObserverOutput(
            newEpisodicMemories: [makeEntry(title: "抽烟控制不稳定")],
            memoryHits: [], weakenedOrExpiredMemories: []
        )

        let result = MemoryObserverOutputValidator.validate(output, against: package, suppressionRules: [rule])
        XCTAssertEqual(result.validNewMemories.count, 0)
        XCTAssertTrue(result.rejectedEntries.first?.reason.contains("suppression") == true)
    }

    func testValidate_expiresInDays超范围_被过滤() {
        let package = makePackage()

        let tooShort = HoloMemoryObserverOutput(
            newEpisodicMemories: [makeEntry(expiresInDays: 3)],
            memoryHits: [], weakenedOrExpiredMemories: []
        )
        let resultShort = MemoryObserverOutputValidator.validate(tooShort, against: package, suppressionRules: [])
        XCTAssertEqual(resultShort.validNewMemories.count, 0)

        let tooLong = HoloMemoryObserverOutput(
            newEpisodicMemories: [makeEntry(expiresInDays: 120)],
            memoryHits: [], weakenedOrExpiredMemories: []
        )
        let resultLong = MemoryObserverOutputValidator.validate(tooLong, against: package, suppressionRules: [])
        XCTAssertEqual(resultLong.validNewMemories.count, 0)
    }

    func testValidate_部分通过_混合结果() {
        let package = makePackage()
        let output = HoloMemoryObserverOutput(
            newEpisodicMemories: [
                makeEntry(title: "有效", confidence: 0.8, evidenceRefs: ["sig-1"]),
                makeEntry(title: "无效", confidence: 0.1, evidenceRefs: ["sig-2"]),
                makeEntry(title: "幻觉", confidence: 0.9, evidenceRefs: ["fake"]),
            ],
            memoryHits: [MemoryHitEntry(episodicMemoryID: "nonexistent", hitReasoning: "不存在的ID")],
            weakenedOrExpiredMemories: []
        )

        let result = MemoryObserverOutputValidator.validate(output, against: package, suppressionRules: [])
        XCTAssertEqual(result.validNewMemories.count, 1)
        XCTAssertEqual(result.rejectedEntries.count, 3)  // 2 invalid memories + 1 invalid hit
    }

    func testValidate_emptyOutput_返回空结果() {
        let package = makePackage()
        let output = HoloMemoryObserverOutput(
            newEpisodicMemories: [],
            memoryHits: [],
            weakenedOrExpiredMemories: []
        )

        let result = MemoryObserverOutputValidator.validate(output, against: package, suppressionRules: [])
        XCTAssertTrue(result.validNewMemories.isEmpty)
        XCTAssertTrue(result.validHits.isEmpty)
        XCTAssertTrue(result.validWeakened.isEmpty)
        XCTAssertTrue(result.rejectedEntries.isEmpty)
    }
}
