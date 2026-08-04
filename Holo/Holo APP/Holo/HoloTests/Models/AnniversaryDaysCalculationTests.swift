//
//  AnniversaryDaysCalculationTests.swift
//  HoloTests
//
//  纪念日天数计算核心算法测试：倒数、累计、每年重复下一周年。
//

import XCTest
import CoreData
@testable import Holo

final class AnniversaryDaysCalculationTests: XCTestCase {

    // MARK: - 测试上下文

    /// 内存型上下文，用于创建测试用 Anniversary 托管对象
    private var context: NSManagedObjectContext!

    private let calendar = Calendar.current

    override func setUp() {
        super.setUp()
        let container = NSPersistentContainer(
            name: "AnniversaryTest",
            managedObjectModel: CoreDataStack.shared.persistentContainer.managedObjectModel
        )
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error {
                XCTFail("测试上下文加载失败：\(error)")
            }
        }
        context = container.viewContext
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    // MARK: - 辅助

    /// 创建一个测试纪念日
    private func makeAnniversary(
        title: String = "Test",
        date: Date,
        repeatYearly: Bool = false
    ) -> Anniversary {
        Anniversary.create(in: context, title: title, date: date, repeatYearly: repeatYearly)
    }

    /// 生成指定年月日的日期（00:00:00）
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - 倒数（未来日期，不重复）

    func testFutureDateCountdown() {
        // 今天 + 10 天
        let future = calendar.date(byAdding: .day, value: 10, to: Date())!
        let item = makeAnniversary(date: future)
        XCTAssertEqual(item.daysFromToday(), 10, "未来10天应返回 10")
        XCTAssertEqual(item.displayMode, .countdown(days: 10))
        XCTAssertTrue(item.displayMode.isCountdown)
    }

    func testTodayCountdown() {
        let item = makeAnniversary(date: Date())
        XCTAssertEqual(item.daysFromToday(), 0, "今天应返回 0")
        XCTAssertTrue(item.isToday)
        XCTAssertEqual(item.displayHeadline, "就是今天")
    }

    // MARK: - 累计（过去日期，不重复）

    func testPastDateElapsed() {
        let past = calendar.date(byAdding: .day, value: -30, to: Date())!
        let item = makeAnniversary(date: past)
        XCTAssertEqual(item.daysFromToday(), -30, "过去30天应返回 -30")
        XCTAssertEqual(item.displayDays, 30, "展示天数为绝对值 30")
        XCTAssertEqual(item.displayHeadline, "已经 30 天")
    }

    func testOneYearAgoElapsed() {
        let past = calendar.date(byAdding: .year, value: -1, to: Date())!
        let item = makeAnniversary(date: past)
        XCTAssertEqual(item.displayDays, 365, "一年前约365天")
    }

    // MARK: - 每年重复：下一周年计算

    func testYearlyRepeatNextOccurrenceThisYear() {
        // 假设今年的某天还没到，比如 12月25日
        let next = calendar.date(byAdding: .month, value: 6, to: Date())!  // 约6个月后
        let item = makeAnniversary(date: next, repeatYearly: true)

        // 下一个周年应该就是今年的这个日期
        let nextOccur = item.nextOccurrenceDate()
        XCTAssertEqual(
            calendar.dateComponents([.month, .day], from: nextOccur),
            calendar.dateComponents([.month, .day], from: next),
            "今年未到的周年日，下一个周年应是今年的同月同日"
        )
    }

    func testYearlyRepeatNextOccurrenceNextYear() {
        // 假设今年的周年已经过了，比如 3个月前
        let past = calendar.date(byAdding: .month, value: -3, to: Date())!
        let item = makeAnniversary(date: past, repeatYearly: true)

        // 下一个周年应该是明年的同月同日
        let nextOccur = item.nextOccurrenceDate()
        let nextYear = (calendar.dateComponents([.year], from: Date()).year ?? 0) + 1
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: nextOccur),
            DateComponents(year: nextYear,
                           month: calendar.dateComponents([.month], from: past).month,
                           day: calendar.dateComponents([.day], from: past).day),
            "今年已过的周年日，下一个周年应是明年同月同日"
        )
    }

    func testYearlyRepeatDaysFromToday() {
        // 每年重复的纪念日，距今的天数应是"距下一个周年"的天数
        let past = calendar.date(byAdding: .month, value: -3, to: Date())!
        let item = makeAnniversary(date: past, repeatYearly: true)
        let days = item.daysFromToday()

        // 应是正数（未来）
        XCTAssertGreaterThan(days, 0, "每年重复的纪念日距今应为正数（未来）")

        // 验证：手动算距下一个周年的天数
        let nextOccur = item.nextOccurrenceDate()
        let expectedDays = calendar.dateComponents([.day], from: Date(), to: nextOccur).day ?? 0
        XCTAssertEqual(days, expectedDays, "天数应等于距下一个周年的天数")
    }

    // MARK: - 临近判断

    func testIsApproaching() {
        let inFiveDays = calendar.date(byAdding: .day, value: 5, to: Date())!
        let item = makeAnniversary(date: inFiveDays)
        XCTAssertTrue(item.isApproaching, "5天后应判定为临近")

        let inTenDays = calendar.date(byAdding: .day, value: 10, to: Date())!
        let far = makeAnniversary(date: inTenDays)
        XCTAssertFalse(far.isApproaching, "10天后不应判定为临近")
    }

    // MARK: - 周年数

    func testAnniversaryNumber() {
        let threeYearsAgo = calendar.date(byAdding: .year, value: -3, to: Date())!
        let item = makeAnniversary(date: threeYearsAgo, repeatYearly: true)
        XCTAssertEqual(item.anniversaryNumber, 3, "3年前的纪念日应是第3周年")
    }
}
