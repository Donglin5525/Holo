import XCTest
@testable import Holo

/// 验证 `MemoryGalleryViewModel.dailySummaries(items:in:)` 按周期聚合每日摘要的正确性。
///
/// 背景：生活星图的信号卡片（习惯/财务/任务）原本从 `timelineSections` 取数，
/// 而 timelineSections 是时间线分页产物（第一页仅最近 7 天）。当洞察周期回退到
/// 上一周/月时，range 最早的几天（如上周一）不在第一页，导致星图聚合漏算、
/// 误判「等待记账记录」。`dailySummaries` 直接遍历 range 内每一天从 items 聚合，
/// 不依赖分页状态，与 AI 洞察（直接查 Core Data range）取数逻辑一致。
/// 这里通过注入固定 items + range 验证它不会漏掉 range 起点。
final class MemoryGalleryViewModelConstellationTests: XCTestCase {

    // MARK: - 核心：range 起点必须被覆盖（timelineSections 分页会漏这天）

    func testDailySummariesIncludesRangeStartDay() {
        // 模拟本周一回退到上一周：range = 06-15(周一) ~ 06-21(周日)
        let start = makeDate(year: 2026, month: 6, day: 15)
        let end = makeDate(year: 2026, month: 6, day: 21)

        // items 含 06-15（range 起点，分页会漏）和 06-16 的记账
        let items = [
            makeTransaction(on: makeDate(year: 2026, month: 6, day: 16), amount: 50),
            makeTransaction(on: makeDate(year: 2026, month: 6, day: 15), amount: 30)
        ]

        let summaries = MemoryGalleryViewModel.dailySummaries(items: items, in: (start, end))

        // 应返回 2 天的摘要（06-15 + 06-16），不漏 range 起点
        XCTAssertEqual(
            summaries.count, 2,
            "range 起点当天有数据时必须纳入，不应因分页窗口错配被漏掉"
        )
        XCTAssertTrue(summaries.contains { $0.totalExpense != nil }, "记账数据应被聚合到摘要")
    }

    // MARK: - range 外数据不计入

    func testDailySummariesExcludesOutOfRange() {
        let start = makeDate(year: 2026, month: 6, day: 15)
        let end = makeDate(year: 2026, month: 6, day: 21)

        // 06-14 在 range 外
        let items = [makeTransaction(on: makeDate(year: 2026, month: 6, day: 14), amount: 30)]

        let summaries = MemoryGalleryViewModel.dailySummaries(items: items, in: (start, end))

        XCTAssertTrue(summaries.isEmpty, "range 外的数据不应计入周期摘要")
    }

    // MARK: - 空 items

    func testDailySummariesEmptyItemsReturnsEmpty() {
        let start = makeDate(year: 2026, month: 6, day: 15)
        let end = makeDate(year: 2026, month: 6, day: 21)

        let summaries = MemoryGalleryViewModel.dailySummaries(items: [], in: (start, end))

        XCTAssertTrue(summaries.isEmpty)
    }

    // MARK: - 多类型聚合正确性

    func testDailySummariesAggregatesHabitsAndTasks() throws {
        let day = makeDate(year: 2026, month: 6, day: 15)
        let items = [
            makeTransaction(on: day, amount: 30),
            makeHabit(on: day, completed: true),
            makeHabit(on: day, completed: false),
            makeTask(on: day, completed: true)
        ]

        let summaries = MemoryGalleryViewModel.dailySummaries(items: items, in: (day, day))

        XCTAssertEqual(summaries.count, 1)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.totalExpense, 30)
        XCTAssertEqual(summary.habitsTotal, 2)
        XCTAssertEqual(summary.habitsCompleted, 1, "只有 subtitle != 未完成 的习惯算完成")
        XCTAssertEqual(summary.tasksCompleted, 1, "只有 subtitle == 已完成 的任务算完成")
        XCTAssertEqual(summary.thoughtCount, 0)
    }

    // MARK: - 辅助

    /// 构造确定性的本地时区当天 0 点日期，避免依赖「今天」。
    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Calendar.current.date(from: components) else {
            XCTFail("无法构造测试日期 \(year)-\(month)-\(day)")
            return Date()
        }
        return Calendar.current.startOfDay(for: date)
    }

    private func makeTransaction(on date: Date, amount: Decimal) -> MemoryItem {
        MemoryItem(
            id: UUID(),
            type: .transaction,
            date: date,
            title: "测试支出",
            subtitle: nil,
            icon: "creditcard.fill",
            colorHex: "#64748B",
            amount: amount,
            note: nil,
            createdAt: date,
            sourceId: UUID()
        )
    }

    private func makeHabit(on date: Date, completed: Bool) -> MemoryItem {
        MemoryItem(
            id: UUID(),
            type: .habitRecord,
            date: date,
            title: "测试习惯",
            subtitle: completed ? "已完成" : "未完成",
            icon: "checkmark.circle.fill",
            colorHex: "#22C55E",
            amount: nil,
            note: nil,
            createdAt: date,
            sourceId: UUID()
        )
    }

    private func makeTask(on date: Date, completed: Bool) -> MemoryItem {
        MemoryItem(
            id: UUID(),
            type: .task,
            date: date,
            title: "测试任务",
            subtitle: completed ? "已完成" : nil,
            icon: "checklist",
            colorHex: "#6366F1",
            amount: nil,
            note: nil,
            createdAt: date,
            sourceId: UUID()
        )
    }
}
