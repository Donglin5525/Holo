//
//  MatterPresentationTests.swift
//  HoloTests
//
//  Matter 展示层纯逻辑测试（方案 §18.1 - attention 规则/首页选件/文案）：
//  - HoloMatterAttentionPolicy 全部确定性规则（§5.3）
//  - MatterHomeSurface 首页选件排序（0/1/多 Matter，§13.2）
//

import XCTest
@testable import Holo

final class MatterPresentationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_789_000_000) // 固定"今天"
    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_789_000_000 + Double(offset) * 86_400)
    }

    // MARK: - AttentionPolicy（方案 §5.3 确定性规则）

    func testAllWaitingConfirmedLoopsMeansWaiting() {
        let result = HoloMatterAttentionPolicy.evaluate(
            targetDate: nil,
            loops: [
                .init(title: "京都住宿", state: .waiting, epistemic: .confirmed),
                .init(title: "签证出签", state: .waiting, epistemic: .confirmed),
            ],
            now: now
        )
        XCTAssertEqual(result.attention, .waiting)
    }

    func testMissedConfirmedDeadlineMeansAtRisk() {
        let result = HoloMatterAttentionPolicy.evaluate(
            targetDate: nil,
            loops: [.init(title: "签证递交", state: .open, epistemic: .confirmed, targetDate: day(-1))],
            now: now
        )
        XCTAssertEqual(result.attention, .atRisk)
        XCTAssertNotNil(result.reason)
    }

    func testSuggestedLoopNeverEscalatesRisk() {
        // 只有 suggested 且过期 → 不得制造风险（unknown：无确认问题无日期）
        let result = HoloMatterAttentionPolicy.evaluate(
            targetDate: nil,
            loops: [.init(title: "买转换插头", state: .open, epistemic: .suggested, targetDate: day(-3))],
            now: now
        )
        XCTAssertEqual(result.attention, .unknown)
    }

    func testConfirmedDeadlineWithinWindowMeansNeedsAttention() {
        let result = HoloMatterAttentionPolicy.evaluate(
            targetDate: nil,
            loops: [.init(title: "签证递交", state: .open, epistemic: .confirmed, targetDate: day(10))],
            now: now
        )
        XCTAssertEqual(result.attention, .needsAttention)
    }

    func testUnknownWhenNoDatesAndNoConfirmedLoops() {
        let result = HoloMatterAttentionPolicy.evaluate(targetDate: nil, loops: [], now: now)
        XCTAssertEqual(result.attention, .unknown)
        // suggested 的存在同样不改变 unknown
        let withSuggested = HoloMatterAttentionPolicy.evaluate(
            targetDate: nil,
            loops: [.init(title: "收拾行李", state: .open, epistemic: .suggested)],
            now: now
        )
        XCTAssertEqual(withSuggested.attention, .unknown)
    }

    func testOnTrackForFarDateWithConfirmedLoops() {
        let result = HoloMatterAttentionPolicy.evaluate(
            targetDate: day(60),
            loops: [.init(title: "换护照", state: .resolved, epistemic: .confirmed)],
            now: now
        )
        // resolved 不算 active loop → 无确认 open 问题、日期尚远 → unknown（无风险信息）
        XCTAssertTrue([.onTrack, .unknown].contains(result.attention))
    }

    func testMatterTargetDatePassedMeansAtRisk() {
        let result = HoloMatterAttentionPolicy.evaluate(targetDate: day(-5), loops: [], now: now)
        XCTAssertEqual(result.attention, .atRisk)
    }

    // MARK: - MatterHomeSurface（首页 0/1/多 Matter）

    private func candidate(
        title: String,
        attention: HoloMatterAttention,
        nextActionDate: Date? = nil,
        updatedAgo: TimeInterval = 0
    ) -> MatterHomeSurface.Candidate {
        MatterHomeSurface.Candidate(
            id: UUID(),
            title: title,
            targetDate: day(30),
            updatedAt: now.addingTimeInterval(-updatedAgo),
            nextActionTitle: "做点什么",
            nextActionTargetDate: nextActionDate,
            loops: [
                .init(title: "问题", state: .open, epistemic: .confirmed, targetDate: day(10))
            ],
            projectionAttention: attention
        )
    }

    func testSelectEmptyMatters() {
        XCTAssertTrue(MatterHomeSurface.select([], now: now).isEmpty)
    }

    func testSelectSingleMatter() {
        let items = MatterHomeSurface.select([candidate(title: "日本旅行", attention: .needsAttention)], now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "日本旅行")
    }

    func testSelectSortsByAttentionSeverity() {
        let needsAttention = candidate(title: "低风险事项", attention: .onTrack)
        let atRisk = MatterHomeSurface.Candidate(
            id: UUID(), title: "已过期事项", targetDate: day(-2), updatedAt: now,
            nextActionTitle: nil, nextActionTargetDate: nil,
            loops: [.init(title: "过期问题", state: .open, epistemic: .confirmed, targetDate: day(-1))],
            projectionAttention: .atRisk
        )
        let items = MatterHomeSurface.select([needsAttention, atRisk], now: now)
        XCTAssertEqual(items.first?.title, "已过期事项", "atRisk 必须排在 onTrack 前")
        XCTAssertEqual(items.first?.attention, .atRisk)
    }

    func testSelectTiesBreakByNearestNextAction() {
        let later = candidate(title: "远期", attention: .needsAttention, nextActionDate: day(20))
        let sooner = candidate(title: "近期", attention: .needsAttention, nextActionDate: day(3))
        let items = MatterHomeSurface.select([later, sooner], now: now)
        XCTAssertEqual(items.first?.title, "近期")
    }

    // MARK: - 文案

    func testFocusCardDaysText() {
        XCTAssertEqual(MatterFocusCard.daysText(0), String(localized: "就是今天"))
        XCTAssertEqual(MatterFocusCard.daysText(20), String(localized: "还有 20 天"))
        XCTAssertEqual(MatterFocusCard.daysText(-3), String(localized: "已过期 3 天"))
    }
}
