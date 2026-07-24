import CoreGraphics
import Foundation
#if HOLO_XCTEST_BRIDGE
import CoreData
#endif

// standalone 编译时提供布局模型所需的最小事件契约，避免启动 App/Core Data 宿主。
#if !HOLO_XCTEST_BRIDGE
enum CalendarModule: String {
    case finance
    case habit
    case thought
    case todo
}

struct CalendarEvent {
    let id: UUID
    let module: CalendarModule
    let date: Date
    let title: String
}
#endif

private func expectWeeklyGridAxis(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        WeeklyGridAxisProfileStandaloneTests.main()
    }
}
#endif
struct WeeklyGridAxisProfileStandaloneTests {
    #if HOLO_XCTEST_BRIDGE
    private static let originContext: NSManagedObjectContext = {
        let container = NSPersistentContainer(
            name: "WeeklyGridAxisProfileTests",
            managedObjectModel: CoreDataTestSupport.sharedModel
        )
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        precondition(loadError == nil, "测试 Core Data 容器加载失败：\(String(describing: loadError))")
        CoreDataTestSupport.retain(container)
        return container.viewContext
    }()
    #endif

    static func main() {
        testHeightTiers()
        testWeekUsesMaximumDailyDensity()
        testCumulativeOffsetsAndMinutePosition()
        testEventsRemainIndividuallyVisibleWithinLimit()
        testOverflowContainsCompleteHourList()
        print("WeeklyGridAxisProfileStandaloneTests passed (5 cases)")
    }

    private static func testHeightTiers() {
        let counts = [0, 1, 2, 3, 4, 5, 10]
        let days = counts.enumerated().map { index, count in [index: count] }
        let profile = WeeklyGridAxisProfile.make(
            eventCountsByDay: days,
            startHour: 0,
            endHour: 6
        )

        expectWeeklyGridAxis(profile.segments.map(\.height) == [42, 42, 57, 84, 111, 131, 131],
               "0、1、2、3、4、5、10 条事件应命中约定高度并在 131pt 封顶")
    }

    private static func testWeekUsesMaximumDailyDensity() {
        let profile = WeeklyGridAxisProfile.make(
            eventCountsByDay: [[10: 1, 11: 2], [10: 4], [10: 2, 11: 1]],
            startHour: 10,
            endHour: 12
        )

        expectWeeklyGridAxis(profile.height(for: 10) == 111, "同一小时应取七天中的单日最大事件数")
        expectWeeklyGridAxis(profile.height(for: 11) == 57, "其他小时应独立计算密度")
        expectWeeklyGridAxis(profile.height(for: 12) == 42, "空小时应保持基础高度")
    }

    private static func testCumulativeOffsetsAndMinutePosition() {
        let profile = WeeklyGridAxisProfile.make(
            eventCountsByDay: [[7: 2, 8: 3]],
            startHour: 7,
            endHour: 9
        )

        expectWeeklyGridAxis(profile.top(for: 7) == 0, "首小时应从 0 开始")
        expectWeeklyGridAxis(profile.top(for: 8) == 57, "下一小时应从前一动态高度之后开始")
        expectWeeklyGridAxis(profile.top(for: 9) == 141, "累计坐标应包含前面所有动态小时高度")
        expectWeeklyGridAxis(profile.yPosition(hour: 8, minute: 30) == 99, "半点应位于当前动态小时的中点")
        expectWeeklyGridAxis(profile.totalHeight == 183, "总高度应为所有动态小时高度之和")
    }

    private static func testEventsRemainIndividuallyVisibleWithinLimit() {
        let events = [
            event(.habit, hour: 10, minute: 2, title: "晨间复盘", idSuffix: 1),
            event(.habit, hour: 10, minute: 9, title: "喝水", idSuffix: 2),
            event(.finance, hour: 10, minute: 16, title: "早餐", idSuffix: 3),
            event(.thought, hour: 10, minute: 41, title: "产品想法", idSuffix: 4)
        ]
        let profile = WeeklyGridAxisProfile.make(
            eventCountsByDay: [[10: events.count]],
            startHour: 10,
            endHour: 10
        )

        let layout = WeeklyGridEventLayout.layout(events: events, axisProfile: profile)

        expectWeeklyGridAxis(layout.displayItems.count == 4, "四条以内应全部逐条展示")
        expectWeeklyGridAxis(layout.displayItems.map(\.displayTitle) == events.map(\.title),
               "同一小时应按发生顺序展示真实标题")
        expectWeeklyGridAxis(layout.displayItems.allSatisfy { !$0.isOverflow && $0.events.count == 1 },
               "四条以内不应生成 +N 摘要")
    }

    private static func testOverflowContainsCompleteHourList() {
        let events = (0..<6).map { index in
            event(.todo, hour: 18, minute: index, title: "任务 \(index + 1)", idSuffix: index + 1)
        }
        let profile = WeeklyGridAxisProfile.make(
            eventCountsByDay: [[18: events.count]],
            startHour: 18,
            endHour: 18
        )

        let layout = WeeklyGridEventLayout.layout(events: events, axisProfile: profile)
        let overflow = layout.displayItems.last

        expectWeeklyGridAxis(layout.displayItems.count == 5, "六条事件应展示四条明细和一个溢出入口")
        expectWeeklyGridAxis(overflow?.displayTitle == "还有 2 条", "溢出入口应显示准确隐藏数量")
        expectWeeklyGridAxis(overflow?.events.count == 6, "溢出入口应携带该小时完整事件清单")
        expectWeeklyGridAxis(overflow?.top == 111 && overflow?.height == 17,
               "溢出入口应落在 131pt 封顶小时内")
    }

    private static func event(_ module: CalendarModule,
                              hour: Int,
                              minute: Int,
                              title: String,
                              idSuffix: Int) -> CalendarEvent {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = Calendar.current.timeZone
        components.year = 2026
        components.month = 7
        components.day = 12
        components.hour = hour
        components.minute = minute
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!
        #if HOLO_XCTEST_BRIDGE
        let origin = originContext.insertTestObject(Thought.self)
        CoreDataTestSupport.retain(origin)
        return CalendarEvent(
            id: id,
            module: module,
            date: components.date!,
            title: title,
            originID: origin.objectID
        )
        #else
        return CalendarEvent(id: id, module: module, date: components.date!, title: title)
        #endif
    }
}
