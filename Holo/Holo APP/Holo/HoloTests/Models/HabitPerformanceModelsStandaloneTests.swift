import Foundation

@main
struct HabitPerformanceModelsStandaloneTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    static func main() {
        testBadNumericHabitCountsDaysAtOrBelowTargetAsControlled()
        testPositiveCheckInHabitCountsCompletedDaysAsProgress()
        print("HabitPerformanceModels standalone tests passed")
    }

    private static func testBadNumericHabitCountsDaysAtOrBelowTargetAsControlled() {
        let snapshot = HabitPerformanceEvaluator.evaluate(
            habitName: "抽烟",
            isBadHabit: true,
            isNumericType: true,
            totalDays: 3,
            completedCheckInDays: 0,
            dailyNumericValues: [5, 2],
            targetValue: 3,
            unit: "根"
        )

        expect(snapshot.polarity == .negative, "抽烟应被识别为负向习惯")
        expect(snapshot.successRule == .stayBelowTarget, "有目标值的负向数值习惯应以不超过目标为成功规则")
        expect(snapshot.totalValue == 7, "总量应累计所有数值记录")
        expect(snapshot.controlledDays == 2, "3 天中 1 天超标，2 天应算控制住")
        expect(snapshot.overLimitDays == 1, "只有 5 根这天超过目标 3 根")
        expect(snapshot.completionRate == 2.0 / 3.0, "控制率应为 controlledDays / totalDays")
    }

    private static func testPositiveCheckInHabitCountsCompletedDaysAsProgress() {
        let snapshot = HabitPerformanceEvaluator.evaluate(
            habitName: "跑步",
            isBadHabit: false,
            isNumericType: false,
            totalDays: 4,
            completedCheckInDays: 3,
            dailyNumericValues: [],
            targetValue: nil,
            unit: nil
        )

        expect(snapshot.polarity == .positive, "跑步应为正向习惯")
        expect(snapshot.successRule == .completeWhenDone, "正向打卡习惯应以完成打卡为成功规则")
        expect(snapshot.completedDays == 3, "完成天数应来自打卡完成数")
        expect(snapshot.completionRate == 0.75, "完成率应为 completedDays / totalDays")
    }
}
