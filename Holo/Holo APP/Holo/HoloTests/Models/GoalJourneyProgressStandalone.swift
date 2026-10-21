import Foundation

@main
struct GoalJourneyProgressStandalone {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        expect(GoalJourneyProgress(value: nil, target: 120) == nil, "缺记录不能画成0")
        expect(GoalJourneyProgress(value: 0, target: 120)?.fraction == 0, "真实0保留")
        expect(GoalJourneyProgress(value: 6000, target: 18000)?.label == "33%", "资金独立比例")
        expect(GoalJourneyProgress(value: 2, target: 3)?.label == "67%", "次数独立比例")
        expect(GoalJourneyProgress(value: 110, target: 120)?.label == "92%", "时长独立比例")
        expect(GoalJourneyProgress(value: 27000, target: 18000)?.fraction == 1, "超额几何封顶")
        expect(GoalJourneyProgress(value: -100, target: 18000)?.fraction == 0, "负余额不画负宽度")
        expect(GoalJourneyProgress(value: 1, target: 2, kind: .allowance)?.label == "上限已用 50%", "上限不是完成率")
        expect(GoalJourneyProgress(value: 0, target: 2, kind: .allowance)?.label == "上限已用 0%", "真实未发生不冒充未知")
        expect(GoalJourneyProgress(value: 3, target: 2, kind: .allowance)?.exceeded == true, "超出上限")
        expect(GoalJourneyProgress(value: 3, target: 2, kind: .allowance)?.label == "已超上限", "超限有文字")
        expect(GoalJourneyProgress(value: 1, target: 0) == nil, "零目标不除零")
        expect(GoalJourneyProgress(value: 1, target: nil) == nil, "没有目标不补条")
        expect(GoalJourneyProgress(value: .infinity, target: 5) == nil, "无效来源数值不画条")
        expect(GoalJourneyProgress(value: 1, target: .nan) == nil, "无效目标不画条")
        expect(GoalJourneyProgress(value: 70, target: 60, evaluatedFraction: 0.5)?.label == "50%", "下降目标沿用基线求得的比例")
        expect(GoalJourneyProgress(value: 5, target: 0, evaluatedFraction: 0.5)?.label == "50%", "有意义的零终点改善比例")
        expect(GoalJourneyProgress(value: 2, target: 3, evaluatedFraction: .nan) == nil, "拒绝无效已计算比例")
        print("GoalJourneyProgress: \(checks) checks passed")
    }
}
