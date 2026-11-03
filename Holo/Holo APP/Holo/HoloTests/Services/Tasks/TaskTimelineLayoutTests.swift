//
//  TaskTimelineLayoutTests.swift
//  HoloTests
//
//  时间轴重叠布局纯规则（多视图方案 §5.2-6/7/8）：冲突组分列、视觉重叠、
//  三列聚合、结束等于下一开始不算冲突。
//

import XCTest
@testable import Holo

final class TaskTimelineLayoutTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func at(_ h: Int, _ m: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: h, minute: m))!
    }

    private func block(_ id: String, _ start: Date, _ end: Date) -> TaskTimelineLayout.Block {
        TaskTimelineLayout.Block(id: UUID(uuidString: id)!, start: start, end: end)
    }

    private var metrics: TaskTimelineLayout.Metrics {
        TaskTimelineLayout.Metrics(availableWidth: 316) // 404 - 左时间列40 - 起点44 ≈ 316（375pt 屏）
    }

    // MARK: - C02：B/H 两列且互标重叠

    func testOverlappingPairSplitsIntoTwoLanes() {
        let b = block("00000000-0000-0000-0000-000000000002", at(10, 30), at(12))
        let h = block("00000000-0000-0000-0000-000000000004", at(10, 45), at(11, 30))
        let output = TaskTimelineLayout.layout([h, b], metrics: metrics)
        XCTAssertEqual(output.groups.count, 1)
        guard case .placements(let placements) = output.groups[0] else {
            return XCTFail("应逐块落位")
        }
        XCTAssertEqual(placements.count, 2)
        XCTAssertTrue(placements.allSatisfy { $0.laneCount == 2 })
        XCTAssertTrue(placements.allSatisfy { $0.overlapsAnother })
        XCTAssertEqual(Set(placements.map(\.lane)), [0, 1])
    }

    // MARK: - 结束等于下一开始：不是冲突（§5.2-7）

    func testBackToBackBlocksDoNotConflict() {
        let first = block("00000000-0000-0000-0000-000000000001", at(9), at(10))
        let second = block("00000000-0000-0000-0000-000000000002", at(10), at(11))
        let output = TaskTimelineLayout.layout([first, second], metrics: metrics)
        XCTAssertEqual(output.groups.count, 2)
        XCTAssertTrue(output.allPlacements.allSatisfy { $0.lane == 0 && $0.laneCount == 1 })
        XCTAssertTrue(output.allPlacements.allSatisfy { !$0.overlapsAnother })
    }

    // MARK: - C12：短块视觉重叠也分列（触点不被遮住）

    func testShortBlocksVisuallyOverlappingSplitLanes() {
        // 15 分钟真实块（15pt 高 < 44pt 最小可点高 → 视觉 ~41 分钟）
        let s1 = block("00000000-0000-0000-0000-000000000001", at(10, 40), at(10, 55))
        let s2 = block("00000000-0000-0000-0000-000000000002", at(10, 50), at(11, 5))
        let output = TaskTimelineLayout.layout([s1, s2], metrics: metrics)
        XCTAssertEqual(output.groups.count, 1)
        XCTAssertTrue(output.allPlacements.allSatisfy { $0.laneCount == 2 })
    }

    // MARK: - 三列且净宽 < 88：聚合组块

    func testTripleOverlapMergesWhenTooNarrow() {
        let s1 = block("00000000-0000-0000-0000-000000000001", at(10, 40), at(11, 15))
        let s2 = block("00000000-0000-0000-0000-000000000002", at(10, 40), at(11, 15))
        let s3 = block("00000000-0000-0000-0000-000000000003", at(10, 40), at(11, 15))
        // 可用宽 250：250/3 ≈ 83 < 88 → 聚合
        let narrow = TaskTimelineLayout.Metrics(availableWidth: 250)
        let merged = TaskTimelineLayout.layout([s1, s2, s3], metrics: narrow)
        guard case .merged(let group) = merged.groups.first else {
            return XCTFail("三列过窄应聚合")
        }
        XCTAssertEqual(group.blocks.count, 3)
        XCTAssertEqual(group.start, at(10, 40))

        // 可用宽 316：316/3 ≈ 105 > 88 → 逐块三列
        let wide = TaskTimelineLayout.layout([s1, s2, s3], metrics: metrics)
        guard case .placements(let placements) = wide.groups.first else {
            return XCTFail("宽度足够应逐块")
        }
        XCTAssertEqual(placements.count, 3)
        XCTAssertTrue(placements.allSatisfy { $0.laneCount == 3 })
    }

    // MARK: - 高度换算

    func testBlockHeightUsesRealDurationWithMinimumFloor() {
        let short = TaskTimelineMath.blockHeight(start: at(10), end: at(10, 15), hourHeight: 64, minBlockHeight: 44, calendar: calendar)
        XCTAssertEqual(short, 44) // 15 分钟 = 16pt，兜底到 44
        let long = TaskTimelineMath.blockHeight(start: at(10), end: at(11, 30), hourHeight: 64, minBlockHeight: 44, calendar: calendar)
        XCTAssertEqual(long, 96) // 90 分钟 = 96pt
    }
}
