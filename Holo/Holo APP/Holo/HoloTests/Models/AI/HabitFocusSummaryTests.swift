//
//  HabitFocusSummaryTests.swift
//  HoloTests
//
//  负向习惯主题识别与趋势摘要测试
//

import XCTest
@testable import Holo

final class HabitFocusSummaryTests: XCTestCase {

    func testSmokingGoalIsRecognizedAsNegativeFocusTopic() {
        let signal = HabitFocusSignal.classify(
            habitName: "戒烟",
            isBadHabit: false,
            goalTitle: "戒烟 90 天",
            profileContext: "我正在戒烟，希望减少复吸。"
        )

        XCTAssertEqual(signal.polarity, .negative)
        XCTAssertTrue(signal.sources.contains(.habitKeyword))
        XCTAssertTrue(signal.sources.contains(.goalKeyword))
        XCTAssertTrue(signal.sources.contains(.profileKeyword))
        XCTAssertTrue(signal.needsClarification == false)
    }

    func testManualPositiveMarkWinsOverNegativeKeywordButNeedsClarification() {
        let signal = HabitFocusSignal.classify(
            habitName: "戒烟学习资料",
            isBadHabit: false,
            goalTitle: nil,
            profileContext: nil
        )

        XCTAssertEqual(signal.polarity, .positive)
        XCTAssertTrue(signal.needsClarification)
    }

    func testNegativeHabitTrendTreatsMoreSmokingAsWorse() {
        let current = HabitPerformanceSnapshot(
            habitName: "抽烟",
            polarity: .negative,
            successRule: .stayBelowTarget,
            completionRate: 4.0 / 7.0,
            totalValue: 18,
            targetValue: 3,
            unit: "根",
            controlledDays: 4,
            overLimitDays: 3,
            completedDays: 4,
            totalDays: 7
        )
        let previous = HabitPerformanceSnapshot(
            habitName: "抽烟",
            polarity: .negative,
            successRule: .stayBelowTarget,
            completionRate: 6.0 / 7.0,
            totalValue: 8,
            targetValue: 3,
            unit: "根",
            controlledDays: 6,
            overLimitDays: 1,
            completedDays: 6,
            totalDays: 7
        )

        let summary = HabitFocusSummary(
            habitName: "抽烟",
            signal: HabitFocusSignal(polarity: .negative, sources: [.manualBadHabit], needsClarification: false),
            current: current,
            previous: previous,
            currentStreak: 2,
            goalTitle: "戒烟"
        )

        XCTAssertEqual(summary.trend, .worse)
        XCTAssertEqual(summary.totalValueDelta, 10)
        XCTAssertEqual(summary.overLimitDaysDelta, 2)
        XCTAssertTrue(summary.aiContextLine.contains("负向习惯"))
        XCTAssertTrue(summary.aiContextLine.contains("发生总量 18根"))
        XCTAssertTrue(summary.aiContextLine.contains("比上期增加 10根"))
        XCTAssertTrue(summary.aiContextLine.contains("超标 3 天"))
        XCTAssertFalse(summary.aiContextLine.contains("完成更多"))
    }
}
