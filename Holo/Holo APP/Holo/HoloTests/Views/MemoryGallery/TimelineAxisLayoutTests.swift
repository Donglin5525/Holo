//
//  TimelineAxisLayoutTests.swift
//  HoloTests
//
//  「轴」档分钟↔像素映射的契约测试：白天段「高度 = 时长」恒成立、
//  折叠态凌晨压带不塌陷、双向映射可逆、吸附与凌晨下限口径正确。
//

import XCTest
@testable import Holo

final class TimelineAxisLayoutTests: XCTestCase {

    private let expanded = TimelineAxisLayout(collapseMorning: false)
    private let collapsed = TimelineAxisLayout(collapseMorning: true)

    private let hourHeight: CGFloat = 56
    private let bandHeight: CGFloat = 38
    private let morningEnd: CGFloat = 7 * 60

    // MARK: - 展开态：全天线性

    func testExpandedKeyPoints() {
        XCTAssertEqual(expanded.contentHeight, 24 * hourHeight, accuracy: 0.001)
        XCTAssertEqual(expanded.y(minute: 0), 0, accuracy: 0.001)
        XCTAssertEqual(expanded.y(minute: 60), hourHeight, accuracy: 0.001)
        XCTAssertEqual(expanded.y(minute: 1440), 24 * hourHeight, accuracy: 0.001)
    }

    // MARK: - 折叠态：凌晨压带、白天正常

    func testCollapsedKeyPoints() {
        // 总高 = 38 + 17 小时 × 56
        XCTAssertEqual(collapsed.contentHeight, bandHeight + 17 * hourHeight, accuracy: 0.001)
        // 7:00 恰在带底
        XCTAssertEqual(collapsed.y(minute: morningEnd), bandHeight, accuracy: 0.001)
        // 8:00 = 带底 + 1 小时
        XCTAssertEqual(collapsed.y(minute: morningEnd + 60), bandHeight + hourHeight, accuracy: 0.001)
        // 24:00 = 带底 + 17 小时
        XCTAssertEqual(collapsed.y(minute: 1440), bandHeight + 17 * hourHeight, accuracy: 0.001)
    }

    /// 白天段（7–24 点）任意等长时长的高度差相等：压缩不改白天比例
    func testCollapsedDaytimeScaleUnchanged() {
        let h1 = collapsed.y(minute: 10 * 60) - collapsed.y(minute: 9 * 60)
        let h2 = collapsed.y(minute: 22 * 60) - collapsed.y(minute: 21 * 60)
        let hExpanded = expanded.y(minute: 10 * 60) - expanded.y(minute: 9 * 60)
        XCTAssertEqual(h1, hourHeight, accuracy: 0.001)
        XCTAssertEqual(h2, hourHeight, accuracy: 0.001)
        XCTAssertEqual(h1, hExpanded, accuracy: 0.001)
    }

    // MARK: - 双向映射可逆

    func testRoundTripExpanded() {
        var minute: CGFloat = 0
        while minute <= 1440 {
            let back = expanded.minute(y: expanded.y(minute: minute))
            XCTAssertEqual(back, minute, accuracy: 0.01, "expanded round-trip failed at \(minute)")
            minute += 15
        }
    }

    func testRoundTripCollapsed() {
        var minute: CGFloat = 0
        while minute <= 1440 {
            let back = collapsed.minute(y: collapsed.y(minute: minute))
            XCTAssertEqual(back, minute, accuracy: 0.01, "collapsed round-trip failed at \(minute)")
            minute += 15
        }
    }

    // MARK: - 吸附与凌晨下限

    func testSnapExpanded() {
        XCTAssertEqual(expanded.snapMinute(317), 315, accuracy: 0.001)
        XCTAssertEqual(expanded.snapMinute(0), 0, accuracy: 0.001)
        XCTAssertEqual(expanded.snapMinute(-30), 0, accuracy: 0.001)
        XCTAssertEqual(expanded.snapMinute(1500), 1440, accuracy: 0.001)
    }

    /// 折叠态凌晨不可排（与周档口径一致）：吸附结果下限收到 7:00
    func testSnapCollapsedFloorAtMorningEnd() {
        XCTAssertEqual(collapsed.snapMinute(300), morningEnd, accuracy: 0.001)
        XCTAssertEqual(collapsed.snapMinute(430), 435, accuracy: 0.001)
        XCTAssertEqual(collapsed.snapMinute(410), 420, accuracy: 0.001)
    }

    // MARK: - 块渲染口径

    /// 完全落在折叠段的块隐藏
    func testMorningHidden() {
        XCTAssertTrue(collapsed.isMorningHidden(endMinute: morningEnd), "end 恰为 7:00 的块无白天部分，应隐藏")
        XCTAssertTrue(collapsed.isMorningHidden(endMinute: 300))
        XCTAssertFalse(collapsed.isMorningHidden(endMinute: morningEnd + 1), "跨界块保留白天部分")
        XCTAssertFalse(expanded.isMorningHidden(endMinute: 0), "展开态不隐藏任何块")
    }

    /// 跨界块（如 6:30–8:30）折叠态从带底起画
    func testLaneYTopClampsToStraddlingBlock() {
        XCTAssertEqual(collapsed.laneYTop(startMinute: 390), bandHeight, accuracy: 0.001)
        XCTAssertEqual(expanded.laneYTop(startMinute: 390), expanded.y(minute: 390), accuracy: 0.001)
        XCTAssertEqual(collapsed.laneYTop(startMinute: 480), collapsed.y(minute: 480), accuracy: 0.001)
    }

    // MARK: - 泳道分配（宽屏多泳道展开）

    private func spans(_ tuples: [(String, CGFloat, CGFloat)]) -> [(id: String, start: CGFloat, end: CGFloat)] {
        tuples.map { (id: $0.0, start: $0.1, end: $0.2) }
    }

    func testAssignLanes_NoOverlap_SingleLane() {
        let plan = TimelineAxisLayout.assignLanes(spans: spans([
            ("a", 480, 540), ("b", 600, 660), ("c", 660, 720)
        ]))
        XCTAssertEqual(plan.laneCount, 1, "互不重叠应共用一条泳道")
        XCTAssertEqual(plan.lanes["a"], 0)
        XCTAssertEqual(plan.lanes["b"], 0)
        XCTAssertEqual(plan.lanes["c"], 0)
    }

    func testAssignLanes_Overlap_GetsOwnLane() {
        let plan = TimelineAxisLayout.assignLanes(spans: spans([
            ("a", 480, 600), ("b", 540, 660)
        ]))
        XCTAssertEqual(plan.laneCount, 2, "时间重叠必须分泳道，不得叠印")
        XCTAssertNotEqual(plan.lanes["a"], plan.lanes["b"])
    }

    func testAssignLanes_FreedLaneIsReused() {
        // c 在 a 结束后开始：复用 a 的泳道，不再新开
        let plan = TimelineAxisLayout.assignLanes(spans: spans([
            ("a", 480, 540), ("b", 480, 660), ("c", 540, 600)
        ]))
        XCTAssertEqual(plan.laneCount, 2)
        XCTAssertEqual(plan.lanes["c"], plan.lanes["a"], "复用已释放泳道")
    }

    func testAssignLanes_ThreeWayOverlap_ThreeLanes() {
        let plan = TimelineAxisLayout.assignLanes(spans: spans([
            ("a", 480, 700), ("b", 490, 690), ("c", 500, 600)
        ]))
        XCTAssertEqual(plan.laneCount, 3)
        XCTAssertEqual(Set(plan.lanes.values), [0, 1, 2])
    }

    func testAssignLanes_TouchingEdges_ShareLane() {
        // 前一条结束 == 后一条开始：不算重叠（日程接龙是合法排法）
        let plan = TimelineAxisLayout.assignLanes(spans: spans([
            ("a", 480, 540), ("b", 540, 600)
        ]))
        XCTAssertEqual(plan.laneCount, 1)
    }

    func testAssignLanes_EmptyInput_DegenerateToOneLane() {
        let plan = TimelineAxisLayout.assignLanes(spans: spans([]))
        XCTAssertEqual(plan.laneCount, 1, "空组记 1 条泳道，宽度分配退化为对半且不除零")
    }

    // MARK: - 拖拽换算比例

    func testMinutesPerPoint() {
        // 白天：1pt ≈ 60/56 分钟
        XCTAssertEqual(expanded.minutesPerPoint(aroundMinute: 600), 60 / hourHeight, accuracy: 0.0001)
        XCTAssertEqual(collapsed.minutesPerPoint(aroundMinute: 600), 60 / hourHeight, accuracy: 0.0001)
        // 折叠带内：压缩比
        XCTAssertEqual(collapsed.minutesPerPoint(aroundMinute: 100), morningEnd / bandHeight, accuracy: 0.0001)
    }
}
