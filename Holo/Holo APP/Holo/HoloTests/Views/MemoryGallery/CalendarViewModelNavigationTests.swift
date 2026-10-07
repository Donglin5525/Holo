//
//  CalendarViewModelNavigationTests.swift
//  HoloTests
//
//  「轴」档放开未来导航的契约测试：轴档可越过今天排布未来、一年上限封顶、
//  离开轴档时未来聚焦日带回今天；日/周/月三档「只回看」行为不变（回归）。
//

import XCTest
@testable import Holo

@MainActor
final class CalendarViewModelNavigationTests: XCTestCase {

    private var viewModel: CalendarViewModel!

    override func setUp() async throws {
        viewModel = CalendarViewModel()
    }

    // MARK: - 工厂

    private func day(_ offset: Int, from base: Date = Date()) -> Date {
        Calendar.current.date(
            byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: base)
        )!
    }

    // MARK: - 轴档：放开未来

    /// 轴档在今天也能继续往未来翻（排布未来是轴的本职）
    func testTimelineStepForwardPastToday() {
        viewModel.scale = .timeline
        viewModel.focusedDate = day(0)

        viewModel.step(by: 1)

        XCTAssertEqual(Calendar.current.startOfDay(for: viewModel.focusedDate), day(1))
    }

    /// 轴档翻到一年上限后不再前进
    func testTimelineStepForwardClampedAtFutureLimit() {
        viewModel.scale = .timeline
        viewModel.focusedDate = viewModel.timelineFutureLimit

        viewModel.step(by: 1)

        XCTAssertEqual(viewModel.focusedDate, viewModel.timelineFutureLimit)
    }

    /// 轴档的上限 = 一年后的今天
    func testTimelineFutureLimitIsOneYearOut() {
        XCTAssertEqual(viewModel.timelineFutureLimit, day(365))
    }

    /// canStepForward：轴档今天可前进、上限日不可；日档今天不可（既有回归）
    func testCanStepForward() {
        viewModel.scale = .timeline
        viewModel.focusedDate = day(0)
        XCTAssertTrue(viewModel.canStepForward)

        viewModel.focusedDate = viewModel.timelineFutureLimit
        XCTAssertFalse(viewModel.canStepForward)

        viewModel.scale = .day
        viewModel.focusedDate = day(0)
        XCTAssertFalse(viewModel.canStepForward)
    }

    /// 轴档日期选择器直达未来日（focusDay 是选日期弹层的 commit 通道）
    func testFocusDayFutureOnTimeline() {
        viewModel.scale = .timeline
        let target = day(30)

        viewModel.focusDay(target)

        XCTAssertEqual(viewModel.focusedDate, target)
    }

    // MARK: - 切档：未来日只在轴档停留

    /// 离开轴档时，未来的聚焦日期带回今天（三档只回看，不「回放未来」）
    func testSwitchScaleFromTimelineFutureReturnsToToday() {
        viewModel.scale = .timeline
        viewModel.focusedDate = day(10)

        viewModel.switchScale(.day)

        XCTAssertEqual(Calendar.current.startOfDay(for: viewModel.focusedDate), day(0))
    }

    /// 轴档聚焦过去日时切档，日期保持（既有「切换尺度日期上下文不丢」回归）
    func testSwitchScaleFromTimelinePastKeepsDate() {
        viewModel.scale = .timeline
        viewModel.focusedDate = day(-7)

        viewModel.switchScale(.day)

        XCTAssertEqual(viewModel.focusedDate, day(-7))
    }

    // MARK: - 日/周/月：只回看不变（回归）

    /// 日档今天再往前翻仍是今天
    func testDayScaleStillCannotPassToday() {
        viewModel.scale = .day
        viewModel.focusedDate = day(0)

        viewModel.step(by: 1)

        XCTAssertEqual(Calendar.current.startOfDay(for: viewModel.focusedDate), day(0))
    }

    /// 周档/月档翻页同样不越过当前期
    func testWeekAndMonthStillCannotPassCurrentPeriod() {
        viewModel.scale = .week
        viewModel.focusedDate = Calendar.current.startOfDay(for: Date())
        viewModel.step(by: 1)
        XCTAssertTrue(
            CalendarRangeBuilder.weekRange(around: viewModel.focusedDate).contains(Date()),
            "周档步进后仍应落在本周"
        )

        viewModel.scale = .month
        viewModel.step(by: 1)
        XCTAssertTrue(
            Calendar.current.isDate(viewModel.focusedDate, equalTo: Date(), toGranularity: .month),
            "月档步进后仍应落在本月"
        )
    }
}
