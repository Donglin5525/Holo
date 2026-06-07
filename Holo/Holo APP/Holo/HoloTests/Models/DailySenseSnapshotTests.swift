//
//  DailySenseSnapshotTests.swift
//  HoloTests
//
//  DailySenseSnapshot v3 模型测试
//  测试编码/解码、向后兼容性、legacy 判断
//

import XCTest
@testable import Holo

final class DailySenseSnapshotTests: XCTestCase {

    // MARK: - v3 格式测试

    func testV3RoundTripIncludesTags() throws {
        let date = Date(timeIntervalSince1970: 1704067200) // 2024-01-01 00:00:00 UTC
        let generatedAt = Date(timeIntervalSince1970: 1704153600) // 2024-01-02 00:00:00 UTC
        let signals = [
            DailySenseSignal(dimension: .task, level: .warning, text: "3 个任务逾期"),
            DailySenseSignal(dimension: .habit, level: .normal, text: "习惯打卡正常"),
            DailySenseSignal(dimension: .expense, level: .critical, text: "消费偏离均值 2.0x")
        ]
        let snapshot = DailySenseSnapshot(
            date: date,
            state: .atRisk,
            signals: signals,
            tags: [.highPressure],
            generatedAt: generatedAt
        )

        // 编码
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(snapshot)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        // 解码
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DailySenseSnapshot.self, from: jsonData)

        // 验证
        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.date, date)
        XCTAssertEqual(decoded.state, .atRisk)
        XCTAssertEqual(decoded.signals.count, 3)
        XCTAssertEqual(decoded.signals[0].dimension, .task)
        XCTAssertEqual(decoded.signals[0].level, .warning)
        XCTAssertEqual(decoded.signals[0].text, "3 个任务逾期")
        XCTAssertEqual(decoded.signals[1].dimension, .habit)
        XCTAssertEqual(decoded.signals[1].level, .normal)
        XCTAssertEqual(decoded.signals[1].text, "习惯打卡正常")
        XCTAssertEqual(decoded.signals[2].dimension, .expense)
        XCTAssertEqual(decoded.signals[2].level, .critical)
        XCTAssertEqual(decoded.signals[2].text, "消费偏离均值 2.0x")
        XCTAssertEqual(decoded.tags, [.highPressure])
        XCTAssertEqual(decoded.generatedAt, generatedAt)
        XCTAssertFalse(decoded.isLegacy)

        // 验证 JSON 包含新字段
        XCTAssertTrue(jsonString.contains("\"schemaVersion\":3"))
        XCTAssertTrue(jsonString.contains("\"signals\":["))
        XCTAssertTrue(jsonString.contains("\"tags\":["))
    }

    // MARK: - Legacy 格式测试

    func testLegacyJSONDecoding() throws {
        // 模拟旧格式 JSON（有 confidence 和 reasons，没有 signals 和 schemaVersion）
        let legacyJSON = """
        {
            "date": "2024-01-01T00:00:00Z",
            "state": "atRisk",
            "confidence": 0.85,
            "reasons": ["3 个任务逾期", "2 个习惯断连", "消费偏高"],
            "generatedAt": "2024-01-01T12:00:00Z"
        }
        """

        let jsonData = legacyJSON.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(DailySenseSnapshot.self, from: jsonData)

        // 验证 legacy 识别
        XCTAssertEqual(decoded.schemaVersion, 1) // 默认为 1
        XCTAssertTrue(decoded.isLegacy)
        XCTAssertEqual(decoded.date, Date(timeIntervalSince1970: 1704067200))
        XCTAssertEqual(decoded.state, .atRisk)
        XCTAssertTrue(decoded.signals.isEmpty) // legacy 没有信号
        XCTAssertTrue(decoded.tags.isEmpty) // legacy 没有标签
        XCTAssertEqual(decoded.generatedAt, Date(timeIntervalSince1970: 1704067200 + 43200))
    }

    func testV2JSONDecodesTagsAsEmpty() throws {
        let v2JSON = """
        {
            "schemaVersion": 2,
            "date": "2024-01-01T00:00:00Z",
            "state": "stable",
            "signals": [
                { "dimension": "task", "level": "normal", "text": "没有逾期" }
            ],
            "generatedAt": "2024-01-01T12:00:00Z"
        }
        """

        let jsonData = v2JSON.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(DailySenseSnapshot.self, from: jsonData)

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertFalse(decoded.isLegacy)
        XCTAssertEqual(decoded.signals.count, 1)
        XCTAssertTrue(decoded.tags.isEmpty)
    }

    func testEmptySignalsIsNotLegacy() throws {
        let date = Date(timeIntervalSince1970: 1704067200)
        let generatedAt = Date(timeIntervalSince1970: 1704153600)
        let snapshot = DailySenseSnapshot(
            date: date,
            state: .stable,
            signals: [], // 空信号数组
            generatedAt: generatedAt
        )

        // 编码
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(snapshot)

        // 解码
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DailySenseSnapshot.self, from: jsonData)

        // 验证：空信号数组仍然是 v3，不是 legacy
        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertFalse(decoded.isLegacy)
        XCTAssertTrue(decoded.signals.isEmpty)
        XCTAssertEqual(decoded.state, .stable)
    }

    // MARK: - 枚举测试

    func testSenseDimensionDisplayNames() {
        XCTAssertEqual(SenseDimension.task.displayName, "待办")
        XCTAssertEqual(SenseDimension.habit.displayName, "习惯")
        XCTAssertEqual(SenseDimension.expense.displayName, "消费")
        XCTAssertEqual(SenseDimension.health.displayName, "健康")
    }

    func testSignalLevelCases() {
        // 验证 SignalLevel 可以正常编码/解码
        let levels: [SignalLevel] = [.normal, .warning, .critical]
        XCTAssertEqual(levels.count, 3)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for level in levels {
            let data = try! encoder.encode(level)
            let decoded = try! decoder.decode(SignalLevel.self, from: data)
            XCTAssertEqual(decoded, level)
        }
    }

    func testDailySenseStateDisplayNames() {
        XCTAssertEqual(DailySenseState.stable.rawValue, "stable")
        XCTAssertEqual(DailySenseState.atRisk.rawValue, "atRisk")
        XCTAssertEqual(DailySenseState.recovering.rawValue, "recovering")
    }

    func testSnapshotStateTitle() {
        let snapshot1 = DailySenseSnapshot(
            date: Date(),
            state: .stable,
            signals: [],
            generatedAt: Date()
        )
        XCTAssertEqual(snapshot1.stateTitle, "节奏不错")

        let snapshot2 = DailySenseSnapshot(
            date: Date(),
            state: .atRisk,
            signals: [],
            generatedAt: Date()
        )
        XCTAssertEqual(snapshot2.stateTitle, "节奏有点乱")

        let snapshot3 = DailySenseSnapshot(
            date: Date(),
            state: .recovering,
            signals: [],
            generatedAt: Date()
        )
        XCTAssertEqual(snapshot3.stateTitle, "节奏在找回")
    }

    // MARK: - Codable 兼容性测试

    func testSignalCodable() throws {
        let signal = DailySenseSignal(
            dimension: .health,
            level: .warning,
            text: "睡眠质量下降"
        )

        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(signal)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DailySenseSignal.self, from: jsonData)

        XCTAssertEqual(decoded.dimension, .health)
        XCTAssertEqual(decoded.level, .warning)
        XCTAssertEqual(decoded.text, "睡眠质量下降")
    }

    func testSnapshotArrayCodable() throws {
        let snapshots = [
            DailySenseSnapshot(
                date: Date(timeIntervalSince1970: 1704067200),
                state: .stable,
                signals: [],
                generatedAt: Date()
            ),
            DailySenseSnapshot(
                date: Date(timeIntervalSince1970: 1704153600),
                state: .atRisk,
                signals: [
                    DailySenseSignal(dimension: .task, level: .warning, text: "任务逾期")
                ],
                generatedAt: Date()
            )
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(snapshots)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([DailySenseSnapshot].self, from: jsonData)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].state, .stable)
        XCTAssertEqual(decoded[1].state, .atRisk)
        XCTAssertEqual(decoded[1].signals.count, 1)
    }

    func testHighPressureRequiresThreeIndependentWarningDimensions() {
        let twoSignals = [
            DailySenseSignal(dimension: .task, level: .warning, text: "任务集中"),
            DailySenseSignal(dimension: .expense, level: .critical, text: "消费偏离")
        ]
        XCTAssertFalse(DailySenseStateBuilder.buildTags(signals: twoSignals, hasConfirmedNewStage: false).contains(.highPressure))

        let threeSignals = twoSignals + [
            DailySenseSignal(dimension: .health, level: .warning, text: "睡眠偏少")
        ]
        XCTAssertTrue(DailySenseStateBuilder.buildTags(signals: threeSignals, hasConfirmedNewStage: false).contains(.highPressure))
    }

    func testSingleFinanceSpikeDoesNotCreateHighPressure() {
        let signals = [
            DailySenseSignal(dimension: .expense, level: .critical, text: "今天支出明显偏离")
        ]

        XCTAssertTrue(DailySenseStateBuilder.buildTags(signals: signals, hasConfirmedNewStage: false).isEmpty)
    }

    func testNewStageRequiresExplicitConfirmedSignal() {
        let signals = [
            DailySenseSignal(dimension: .task, level: .normal, text: "没有逾期")
        ]

        XCTAssertFalse(DailySenseStateBuilder.buildTags(signals: signals, hasConfirmedNewStage: false).contains(.newStage))
        XCTAssertTrue(DailySenseStateBuilder.buildTags(signals: signals, hasConfirmedNewStage: true).contains(.newStage))
    }
}
