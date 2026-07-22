//
//  HoloAgentTimeSemanticResolverTests.swift
//  HoloTests
//
//  Agent V3.1 — 对比类问题双时间窗解析测试
//  运行：swiftc -parse-as-library \
//    "Holo/Models/AI/Agent/HoloAgentTimeRange.swift" \
//    "Holo/Services/AI/Agent/HoloAgentTimeSemanticResolver.swift" \
//    <本测试> -o /tmp/holo_time_resolver_test && /tmp/holo_time_resolver_test
//

import Foundation

@main
struct HoloAgentTimeSemanticResolverTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test本月比上月解析双窗()
        test这个月比上个月解析双窗()
        test本周比上周解析双窗()
        test今年比去年解析双窗()
        test非对比问题返回Nil()
        test单窗resolve保持不变()
        test对比问题current窗口正确()
        test对比问题baseline窗口正确()
        print("HoloAgentTimeSemanticResolverTests passed")
    }

    /// 固定参考日期：2026-07-22，确保测试可复现。
    private static let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 12))!
    }()

    private static var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "zh_CN")
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    // MARK: - 双窗解析命中

    private static func test本月比上月解析双窗() {
        let result = HoloAgentTimeSemanticResolver.resolveComparison(
            "这个月比上个月消费多在哪", referenceDate: referenceDate, calendar: calendar
        )
        expect(result != nil, "『这个月比上个月』应解析出对比双窗")
        expect(result?.current.kind == .currentMonth, "current 应为本月")
        expect(result?.baseline.kind == .previousMonth, "baseline 应为上月")
    }

    private static func test这个月比上个月解析双窗() {
        // 词序颠倒（上个月在前）也应正确配对。
        let result = HoloAgentTimeSemanticResolver.resolveComparison(
            "上月和本月相比花了多少", referenceDate: referenceDate, calendar: calendar
        )
        expect(result != nil, "词序颠倒也应配对")
        expect(result?.current.kind == .currentMonth, "current 仍为本月")
        expect(result?.baseline.kind == .previousMonth, "baseline 仍为上月")
    }

    private static func test本周比上周解析双窗() {
        let result = HoloAgentTimeSemanticResolver.resolveComparison(
            "这周比上周走了多少步", referenceDate: referenceDate, calendar: calendar
        )
        expect(result != nil, "『这周比上周』应解析出对比双窗")
        expect(result?.current.kind == .currentWeek, "current 应为本周")
        expect(result?.baseline.kind == .previousWeek, "baseline 应为上周")
    }

    private static func test今年比去年解析双窗() {
        let result = HoloAgentTimeSemanticResolver.resolveComparison(
            "今年比去年存了多少钱", referenceDate: referenceDate, calendar: calendar
        )
        expect(result != nil, "『今年比去年』应解析出对比双窗")
        expect(result?.current.kind == .currentYear, "current 应为今年")
        expect(result?.baseline.kind == .previousYear, "baseline 应为去年")
    }

    // MARK: - 非对比问题回退

    private static func test非对比问题返回Nil() {
        expect(HoloAgentTimeSemanticResolver.resolveComparison(
            "这个月花了多少钱", referenceDate: referenceDate, calendar: calendar
        ) == nil, "仅本月、无对比词应返回 nil")
        expect(HoloAgentTimeSemanticResolver.resolveComparison(
            "最近睡眠怎么样", referenceDate: referenceDate, calendar: calendar
        ) == nil, "无时间词应返回 nil")
    }

    private static func test单窗resolve保持不变() {
        // 验证现有 resolve 行为未被破坏。
        let single = HoloAgentTimeSemanticResolver.resolve(
            "这个月花了多少钱", referenceDate: referenceDate, calendar: calendar
        )
        expect(single != nil, "单窗 resolve 应仍有效")
        expect(single?.kind == .currentMonth, "应为 currentMonth")
    }

    // MARK: - 窗口边界正确性

    private static func test对比问题current窗口正确() {
        let result = HoloAgentTimeSemanticResolver.resolveComparison(
            "这个月比上个月消费多在哪", referenceDate: referenceDate, calendar: calendar
        )
        let currentRange = result?.current.timeRange
        expect(currentRange?.start != nil && currentRange?.end != nil, "current 窗口应有起止")

        // current 本月：2026-07-01 起
        let currentStart = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        expect(currentRange?.start == currentStart, "current 起点应为 7月1日，实际=\(String(describing: currentRange?.start))")
    }

    private static func test对比问题baseline窗口正确() {
        let result = HoloAgentTimeSemanticResolver.resolveComparison(
            "这个月比上个月消费多在哪", referenceDate: referenceDate, calendar: calendar
        )
        let baselineRange = result?.baseline.timeRange
        expect(baselineRange?.start != nil && baselineRange?.end != nil, "baseline 窗口应有起止")

        // baseline 上月：2026-06-01 起，2026-07-01 止
        let baselineStart = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let baselineEnd = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        expect(baselineRange?.start == baselineStart, "baseline 起点应为 6月1日，实际=\(String(describing: baselineRange?.start))")
        expect(baselineRange?.end == baselineEnd, "baseline 终点应为 7月1日，实际=\(String(describing: baselineRange?.end))")

        // label 应为"上月"，供 evidence 文案使用。
        expect(baselineRange?.label == "上月", "baseline label 应为「上月」，实际=\(baselineRange?.label ?? "nil")")
    }
}
