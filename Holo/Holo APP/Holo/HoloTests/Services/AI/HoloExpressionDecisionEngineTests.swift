//
//  HoloExpressionDecisionEngineTests.swift
//  HoloTests
//

import XCTest
@testable import Holo

final class HoloExpressionDecisionEngineTests: XCTestCase {
    func testSingleWeakSignalOnlyObserves() {
        let decision = HoloExpressionDecisionEngine.decide(
            evidenceCount: 1,
            independentDimensionCount: 1
        )

        XCTAssertEqual(decision.level, .observe)
        XCTAssertTrue(decision.allowedVerbs.contains("看到"))
    }

    func testThreeIndependentSignalsCanSummarize() {
        let decision = HoloExpressionDecisionEngine.decide(
            evidenceCount: 3,
            independentDimensionCount: 3
        )

        XCTAssertEqual(decision.level, .summarize)
        XCTAssertTrue(decision.allowedVerbs.contains("可能"))
    }

    func testSensitiveHealthSignalDoesNotSummarizeStrongly() {
        let decision = HoloExpressionDecisionEngine.decide(
            evidenceCount: 3,
            independentDimensionCount: 3,
            containsSensitiveHealthOrMindSignal: true
        )

        XCTAssertEqual(decision.level, .observe)
    }

    func testConfirmedMilestoneCelebrates() {
        let decision = HoloExpressionDecisionEngine.decide(
            evidenceCount: 2,
            independentDimensionCount: 1,
            hasConfirmedMilestone: true
        )

        XCTAssertEqual(decision.level, .celebrate)
    }
}

