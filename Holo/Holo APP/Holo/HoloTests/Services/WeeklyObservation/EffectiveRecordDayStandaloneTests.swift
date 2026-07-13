//
//  EffectiveRecordDayStandaloneTests.swift
//  Holo
//
//  有效记录日聚合器 standalone test
//  游离 Xcode test target（HoloTests/ 在 PBXFileSystemSynchronizedRootGroup 之外），
//  用 swiftc 联合编译 EffectiveRecordDayModels.swift 后运行断言，实现纯逻辑 TDD。
//
//  运行：
//    swiftc \
//      "Holo/Services/WeeklyObservation/EffectiveRecordDayModels.swift" \
//      "HoloTests/Services/WeeklyObservation/EffectiveRecordDayStandaloneTests.swift" \
//      -o /tmp/erd && /tmp/erd
//

import Foundation

@main
struct EffectiveRecordDayStandaloneTests {

    /// 固定时区日历，避免依赖设备时区
    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return c
    }()

    /// 构造某天 0 点 Date（startOfDay 语义）
    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    static func main() {
        // 参考今日取一个稳定值，断言不依赖运行时刻
        let today = day(2026, 7, 7)

        testSameDayMultipleRecordsCountOnce(today: today)
        testSingleModuleDoesNotQualify(today: today)
        testThreeDaysTwoModulesLightReady(today: today)
        testSevenDaysTwoModulesFullReady(today: today)
        testSevenDaysSingleModuleStillNurturing(today: today)
        testFutureDaysExcluded(today: today)
        testNurturingHintWhenDaysEnoughButModuleShort(today: today)
        testObservationStageMapping()
        testPreviousCompletedWeekFromMonday()
        testPreviousCompletedWeekAcrossMonth()
        testPreviousCompletedWeekAcrossYear()
        testAggregationOnlyCountsTargetWeek()

        print("✅ EffectiveRecordDayStandaloneTests 全部通过")
    }

    // MARK: - Cases

    /// 同一天多个模块有记录，只计 1 个有效记录日
    static func testSameDayMultipleRecordsCountOnce(today: Date) {
        let oneDay = day(2026, 7, 5)
        let r = EffectiveRecordDayAggregator.aggregate(
            financeDays: [oneDay],
            todoDays: [oneDay],
            habitDays: [oneDay],
            thoughtDays: [oneDay],
            today: today
        )
        expect(r.recordDayCount == 1, "同天多模块只计 1 天（实际 \(r.recordDayCount)）")
        expect(r.coveredModules.count == 4, "四模块都被覆盖（实际 \(r.coveredModules.count)）")
        // 1 天不达 light 门槛
        expect(r.eligibility == .nurturing, "1 天应为 nurturing")
    }

    /// 单模块即使天数足够也不达标（G6 窗口级跨模块门槛）
    static func testSingleModuleDoesNotQualify(today: Date) {
        let days: Set<Date> = [day(2026,7,1), day(2026,7,2), day(2026,7,3), day(2026,7,4)]
        let r = EffectiveRecordDayAggregator.aggregate(
            financeDays: days, todoDays: [], habitDays: [], thoughtDays: [], today: today
        )
        expect(r.recordDayCount == 4, "4 天记账（实际 \(r.recordDayCount)）")
        expect(r.coveredModules == [.finance], "仅 finance 模块")
        expect(r.eligibility == .nurturing, "单模块 4 天仍 nurturing（G6）")
    }

    /// 3 天 + 2 模块 → lightReady
    static func testThreeDaysTwoModulesLightReady(today: Date) {
        let r = EffectiveRecordDayAggregator.aggregate(
            financeDays: [day(2026,7,3), day(2026,7,4)],
            todoDays: [day(2026,7,5)],
            habitDays: [], thoughtDays: [], today: today
        )
        expect(r.recordDayCount == 3, "3 天（实际 \(r.recordDayCount)）")
        expect(r.coveredModules.count == 2, "2 模块")
        expect(r.eligibility == .lightReady, "3 天+2 模块 → lightReady")
        expect(r.eligibility.observationStageRawValue == "light3d", "lightReady → light3d")
    }

    /// 7 天 + 2 模块 → fullReady
    static func testSevenDaysTwoModulesFullReady(today: Date) {
        let finance: Set<Date> = [day(2026,7,1),day(2026,7,2),day(2026,7,3),day(2026,7,4)]
        let habit: Set<Date> = [day(2026,7,4),day(2026,7,5),day(2026,7,6),day(2026,7,7)]
        let r = EffectiveRecordDayAggregator.aggregate(
            financeDays: finance, todoDays: [], habitDays: habit, thoughtDays: [], today: today
        )
        // 7/4 重叠，去重后 7 天
        expect(r.recordDayCount == 7, "7 天去重（实际 \(r.recordDayCount)）")
        expect(r.coveredModules.count == 2, "2 模块")
        expect(r.eligibility == .fullReady, "7 天+2 模块 → fullReady")
        expect(r.eligibility.observationStageRawValue == "full7d", "fullReady → full7d")
    }

    /// 7 天但仅 1 模块 → 仍 nurturing（G6）
    static func testSevenDaysSingleModuleStillNurturing(today: Date) {
        let days: Set<Date> = Set((1...7).map { day(2026, 7, $0) })
        let r = EffectiveRecordDayAggregator.aggregate(
            financeDays: days, todoDays: [], habitDays: [], thoughtDays: [], today: today
        )
        expect(r.recordDayCount == 7, "7 天记账")
        expect(r.eligibility == .nurturing, "7 天单模块仍 nurturing（G6）")
    }

    /// 未来日期不计入
    static func testFutureDaysExcluded(today: Date) {
        let r = EffectiveRecordDayAggregator.aggregate(
            financeDays: [day(2026,7,5), day(2026,7,6), day(2026,7,7), day(2026,7,8), day(2026,7,9)],
            todoDays: [day(2026,7,6)],
            habitDays: [], thoughtDays: [], today: today
        )
        // 7/8、7/9 在未来（today=7/7），不计；剩 7/5/6/7 三天 + 2 模块 → lightReady
        expect(r.recordDayCount == 3, "未来日期排除后 3 天（实际 \(r.recordDayCount)）")
        expect(r.eligibility == .lightReady, "3 天+2 模块 → lightReady")
    }

    /// 养成期口径：天数够但模块不足 → 多样化提示
    static func testNurturingHintWhenDaysEnoughButModuleShort(today: Date) {
        let days: Set<Date> = [day(2026,7,4), day(2026,7,5), day(2026,7,6)]
        let r = EffectiveRecordDayAggregator.aggregate(
            financeDays: days, todoDays: [], habitDays: [], thoughtDays: [], today: today
        )
        expect(r.eligibility == .nurturing, "单模块 3 天 nurturing")
        expect(r.nurturingHint == "再记录一种内容，观察会更准", "天数够模块不足提示多样化")
    }

    /// observationStage 映射
    static func testObservationStageMapping() {
        expect(ObservationEligibility.nurturing.observationStageRawValue == nil, "nurturing → nil")
        expect(ObservationEligibility.lightReady.observationStageRawValue == "light3d", "lightReady → light3d")
        expect(ObservationEligibility.fullReady.observationStageRawValue == "full7d", "fullReady → full7d")
    }

    static func testPreviousCompletedWeekFromMonday() {
        let period = WeeklyObservationPeriod.previousCompletedWeek(
            containing: day(2026, 7, 13),
            calendar: cal
        )
        expect(period.start == day(2026, 7, 6), "周一启动仍取上一周周一")
        expect(period.end == day(2026, 7, 12), "周一启动取上一周周日")
    }

    static func testPreviousCompletedWeekAcrossMonth() {
        let period = WeeklyObservationPeriod.previousCompletedWeek(
            containing: day(2026, 8, 2),
            calendar: cal
        )
        expect(period.start == day(2026, 7, 20), "跨月时上一完整周起点正确")
        expect(period.end == day(2026, 7, 26), "跨月时上一完整周终点正确")
    }

    static func testPreviousCompletedWeekAcrossYear() {
        let period = WeeklyObservationPeriod.previousCompletedWeek(
            containing: day(2027, 1, 1),
            calendar: cal
        )
        expect(period.start == day(2026, 12, 21), "跨年时上一完整周起点正确")
        expect(period.end == day(2026, 12, 27), "跨年时上一完整周终点正确")
    }

    static func testAggregationOnlyCountsTargetWeek() {
        let period = WeeklyObservationPeriod(
            start: day(2026, 7, 6),
            end: day(2026, 7, 12)
        )
        let result = EffectiveRecordDayAggregator.aggregate(
            financeDays: [day(2026, 6, 30), day(2026, 7, 6), day(2026, 7, 7)],
            todoDays: [day(2026, 7, 8), day(2026, 7, 13)],
            habitDays: [],
            thoughtDays: [],
            today: day(2026, 7, 13),
            period: period
        )
        expect(result.recordDayCount == 3, "只统计目标上一周内的 3 个有效记录日")
        expect(result.eligibility == .lightReady, "目标周 3 天 2 模块达到生成门槛")
    }

    // MARK: - Assert helper

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("  ✓ \(message)")
        } else {
            print("  ✗ FAILED: \(message)")
            fatalError("断言失败：\(message)")
        }
    }
}
