import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        HabitNumericAggregationStandaloneTests.main()
    }
}
#endif
struct HabitNumericAggregationStandaloneTests {
    private static var assertions = 0

    static func main() {
        test测量类忽略最新空记录()
        test统计跨多日的变化与极值()
        test计数类忽略空值并累加()
        test真实零值不会被当成无数据()
        test异常非有限值不会污染统计()
        print("✅ HabitNumericAggregationStandaloneTests: \(assertions) assertions passed")
    }

    private static func test测量类忽略最新空记录() {
        let day = date(dayOffset: -80, hour: 8)
        let result = HabitNumericAggregator.aggregateDaily(
            samples: [
                HabitNumericSample(date: day, value: 72.4),
                HabitNumericSample(date: day.addingTimeInterval(3600), value: nil)
            ],
            isCountType: false
        )

        expect(result.count == 1, "同一天有有效值时不能因空记录丢失整天")
        expect(result.first?.value == 72.4, "最新空记录不能被转换为 0")
    }

    private static func test统计跨多日的变化与极值() {
        let result = HabitNumericAggregator.aggregateDaily(
            samples: [
                HabitNumericSample(date: date(dayOffset: -80, hour: 8), value: 72.4),
                HabitNumericSample(date: date(dayOffset: -40, hour: 8), value: nil),
                HabitNumericSample(date: date(dayOffset: -1, hour: 8), value: 70.1)
            ],
            isCountType: false
        )

        let values = result.map(\.value)
        expect(values == [72.4, 70.1], "90 天和全部范围只应包含有效测量值")
        expect(values.min() == 70.1, "最低值应来自真实记录")
        expect(values.max() == 72.4, "最高值应来自真实记录")
        expect(abs((values.last ?? 0) - (values.first ?? 0) + 2.3) < 0.000_001,
               "变化值应为最新有效值减最早有效值")
    }

    private static func test计数类忽略空值并累加() {
        let day = date(dayOffset: -1, hour: 8)
        let result = HabitNumericAggregator.aggregateDaily(
            samples: [
                HabitNumericSample(date: day, value: 2),
                HabitNumericSample(date: day.addingTimeInterval(60), value: nil),
                HabitNumericSample(date: day.addingTimeInterval(120), value: 3)
            ],
            isCountType: true
        )

        expect(result.first?.value == 5, "计数类应只累加有效数值")
    }

    private static func test真实零值不会被当成无数据() {
        let result = HabitNumericAggregator.aggregateDaily(
            samples: [HabitNumericSample(date: date(dayOffset: 0, hour: 8), value: 0)],
            isCountType: false
        )

        expect(result.count == 1, "真实录入的 0 必须保留")
        expect(result.first?.value == 0, "真实零值不能被过滤")
    }

    private static func test异常非有限值不会污染统计() {
        let result = HabitNumericAggregator.aggregateDaily(
            samples: [
                HabitNumericSample(date: date(dayOffset: -2, hour: 8), value: .nan),
                HabitNumericSample(date: date(dayOffset: -1, hour: 8), value: .infinity),
                HabitNumericSample(date: date(dayOffset: 0, hour: 8), value: 70)
            ],
            isCountType: false
        )

        expect(result.map(\.value) == [70], "NaN 和无穷值不能进入统计或图表")
    }

    private static func date(dayOffset: Int, hour: Int) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
        return calendar.date(byAdding: .hour, value: hour, to: day) ?? day
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            fatalError("❌ \(message)")
        }
    }
}
