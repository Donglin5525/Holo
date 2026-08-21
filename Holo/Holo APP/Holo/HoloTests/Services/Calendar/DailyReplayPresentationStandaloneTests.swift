import Foundation
#if HOLO_XCTEST_BRIDGE
import CoreData
#endif

#if !HOLO_XCTEST_BRIDGE
enum CalendarModule: String, Hashable {
    case finance
    case habit
    case todo
    case thought
    case health
}

enum CalendarEventValueDirection: Hashable {
    case positive
    case negative
}

struct CalendarEvent {
    let id: UUID
    let module: CalendarModule
    let date: Date
    let title: String
    let detail: String?
    let context: String?
    let numericValue: Decimal?
    let valueDirection: CalendarEventValueDirection?
    let relatedTopics: [String]?

    var hasReliableTime: Bool {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return !(components.hour == 0 && components.minute == 0 && components.second == 0)
    }
}
#endif

private func expectDailyReplay(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct DailyReplayStandaloneLauncher {
    static func main() {
        DailyReplayPresentationStandaloneTests.main()
    }
}
#endif

struct DailyReplayPresentationStandaloneTests {
    #if HOLO_XCTEST_BRIDGE
    private static let originContext: NSManagedObjectContext = {
        let container = NSPersistentContainer(
            name: "DailyReplayPresentationTests",
            managedObjectModel: CoreDataTestSupport.sharedModel
        )
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            precondition(error == nil, "测试 Core Data 容器加载失败：\(String(describing: error))")
        }
        CoreDataTestSupport.retain(container)
        return container.viewContext
    }()
    #endif

    static func main() {
        testSameMinuteAndModuleBecomeOneMoment()
        testFinanceMomentUsesSemanticTitleAndSignedTotal()
        testPeriodDoesNotInventMidnightTime()
        testLongEmptyRunCollapsesButKeepsBoundaries()
        testEmptyDaysRemainNavigableWhenCollapseDisabled()
        testNarrativeOnlyAppearsForClearPattern()
        testHistoricalEmptyDaySwipesForward()
        testTodayEmptyDaySwipesBackInsteadOfFuture()
        testEmptyDayDownwardSwipeGoesBack()
        print("DailyReplayPresentationStandaloneTests passed (9 cases)")
    }

    private static func testSameMinuteAndModuleBecomeOneMoment() {
        let events = [
            event(.habit, hour: 19, minute: 27, title: "维生素", idSuffix: 1),
            event(.habit, hour: 19, minute: 27, title: "英语对话", idSuffix: 2),
            event(.finance, hour: 19, minute: 27, title: "晚餐", idSuffix: 3),
            event(.habit, hour: 19, minute: 28, title: "喝水", idSuffix: 4)
        ]

        let moments = DailyReplayPresentation.moments(from: events)
        expectDailyReplay(moments.count == 3, "只有同一分钟且同模块的记录才应合成一个时刻")
        expectDailyReplay(moments.first(where: { $0.module == .habit && $0.events.count == 2 })?.title == "完成了 2 个习惯",
                          "同一分钟的习惯应形成可理解的组合标题：\(moments.map { ($0.module.rawValue, $0.events.count, $0.title) })")
    }

    private static func testFinanceMomentUsesSemanticTitleAndSignedTotal() {
        let events = [
            event(.finance, hour: 15, minute: 15, title: "停车", value: 20, direction: .negative, idSuffix: 5),
            event(.finance, hour: 15, minute: 15, title: "充电", value: 45, direction: .negative, idSuffix: 6)
        ]

        let moment = DailyReplayPresentation.moments(from: events)[0]
        expectDailyReplay(moment.title == "2 笔支出", "多笔同方向记账应明确是收入还是支出")
        expectDailyReplay(moment.signedTotal == Decimal(-65), "组合卡应保留准确的记账合计")
    }

    private static func testPeriodDoesNotInventMidnightTime() {
        let untimed = event(.todo, hour: 0, minute: 0, title: "某项全天任务", idSuffix: 7)
        let late = event(.thought, hour: 22, minute: 40, title: "夜间想法", idSuffix: 8)

        expectDailyReplay(DailyReplayPeriod.classify(untimed) == .untimed, "零点占位数据必须进入当天记录")
        expectDailyReplay(DailyReplayPeriod.classify(late) == .lateNight, "22 点后的真实时刻应归入深夜")
    }

    private static func testLongEmptyRunCollapsesButKeepsBoundaries() {
        let start = date(hour: 0, minute: 0, day: 1)
        let end = date(hour: 0, minute: 0, day: 7)
        let eventDay = date(hour: 0, minute: 0, day: 6)
        let chapters = DailyReplayChapterBuilder.make(
            from: start,
            through: end,
            eventCountsByDay: [eventDay: 2]
        )

        expectDailyReplay(chapters.count == 4, "首日、连续空白段、有记录日和末日应形成四个章节")
        if case .gap(let days) = chapters[1] {
            expectDailyReplay(days.count == 4, "2—5 日的连续空白应折成一个四天区间")
        } else {
            fatalError("长空白段未被折叠")
        }
    }

    private static func testEmptyDaysRemainNavigableWhenCollapseDisabled() {
        let start = date(hour: 0, minute: 0, day: 1)
        let end = date(hour: 0, minute: 0, day: 5)
        let chapters = DailyReplayChapterBuilder.make(
            from: start,
            through: end,
            eventCountsByDay: [:],
            collapseEmptyRuns: false
        )

        expectDailyReplay(chapters.count == 5, "日回放关闭折叠后，每个空白日都必须保留为可滑动章节")
        expectDailyReplay(chapters.allSatisfy {
            if case .day = $0 { return true }
            return false
        }, "逐日回放不能再用空白段卡片替代真实日期")
    }

    private static func testNarrativeOnlyAppearsForClearPattern() {
        let sparse = [
            event(.habit, hour: 9, minute: 0, title: "喝水", idSuffix: 9),
            event(.finance, hour: 12, minute: 0, title: "午餐", idSuffix: 10)
        ]
        let night = (0..<5).map { index in
            event(.habit, hour: 19 + index / 2, minute: index, title: "习惯 \(index)", idSuffix: 20 + index)
        }

        expectDailyReplay(DailyReplayPresentation.narrative(for: sparse) == nil, "稀疏数据不应硬凑一天总结")
        expectDailyReplay(DailyReplayPresentation.narrative(for: night) == "这一天的记忆，大多留在夜里。",
                          "夜间高度集中的记录应生成有证据的轻叙事")
    }

    private static func testHistoricalEmptyDaySwipesForward() {
        let today = date(hour: 0, minute: 0, day: 7)
        let historical = date(hour: 0, minute: 0, day: 5)
        let target = DailyReplayEmptyDayNavigation.target(
            from: historical,
            direction: .upward,
            today: today
        )
        expectDailyReplay(Calendar.current.component(.day, from: target) == 6,
                          "历史空白日上滑应进入下一天")
    }

    private static func testTodayEmptyDaySwipesBackInsteadOfFuture() {
        let today = date(hour: 0, minute: 0, day: 7)
        let target = DailyReplayEmptyDayNavigation.target(
            from: today,
            direction: .upward,
            today: today
        )
        expectDailyReplay(Calendar.current.component(.day, from: target) == 6,
                          "今天上滑不能进入未来，应回看昨天")
    }

    private static func testEmptyDayDownwardSwipeGoesBack() {
        let today = date(hour: 0, minute: 0, day: 7)
        let historical = date(hour: 0, minute: 0, day: 5)
        let target = DailyReplayEmptyDayNavigation.target(
            from: historical,
            direction: .downward,
            today: today
        )
        expectDailyReplay(Calendar.current.component(.day, from: target) == 4,
                          "空白日下滑应回看前一天")
    }

    private static func event(_ module: CalendarModule,
                              hour: Int,
                              minute: Int,
                              title: String,
                              value: Decimal? = nil,
                              direction: CalendarEventValueDirection? = nil,
                              idSuffix: Int) -> CalendarEvent {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!
        #if HOLO_XCTEST_BRIDGE
        let origin = originContext.insertTestObject(Thought.self)
        CoreDataTestSupport.retain(origin)
        return CalendarEvent(
            id: id,
            module: module,
            date: date(hour: hour, minute: minute, day: 7),
            title: title,
            numericValue: value,
            valueDirection: direction,
            originID: origin.objectID
        )
        #else
        return CalendarEvent(
            id: id,
            module: module,
            date: date(hour: hour, minute: minute, day: 7),
            title: title,
            detail: nil,
            context: nil,
            numericValue: value,
            valueDirection: direction,
            relatedTopics: nil
        )
        #endif
    }

    private static func date(hour: Int, minute: Int, day: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = Calendar.current.timeZone
        components.year = 2026
        components.month = 7
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date!
    }
}
