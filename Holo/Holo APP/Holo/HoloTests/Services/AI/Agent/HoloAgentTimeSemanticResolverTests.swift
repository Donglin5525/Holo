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

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        HoloAgentTimeSemanticResolverTests.main()
    }
}
#endif
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
        test裸年份解析为全年窗口()
        test裸年份不影响年月与今年()
        test中文数字年份解析为全年窗口()
        test中文数字不影响阿拉伯数字路径()
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

    // MARK: - 裸年份（无月份）解析

    private static func test裸年份解析为全年窗口() {
        let result = HoloAgentTimeSemanticResolver.resolve(
            "2026年体重趋势是怎样的", referenceDate: referenceDate, calendar: calendar
        )
        expect(result != nil, "『2026年』应解析出全年窗口（此前返回 nil 导致只查近 14 天）")
        expect(result?.kind == .explicitYear, "应为 explicitYear，实际=\(String(describing: result?.kind))")
        expect(result?.timeRange.label == "2026年", "label 应为「2026年」，实际=\(result?.timeRange.label ?? "nil")")
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        expect(result?.timeRange.start == start, "起点应为 2026-01-01，实际=\(String(describing: result?.timeRange.start))")
        expect(result?.timeRange.end == end, "终点应为 2027-01-01，实际=\(String(describing: result?.timeRange.end))")
    }

    private static func test裸年份不影响年月与今年() {
        // 「2026年7月」仍应解析为显式月份，不被裸年份吃掉。
        let monthResult = HoloAgentTimeSemanticResolver.resolve(
            "2026年7月体重变化", referenceDate: referenceDate, calendar: calendar
        )
        expect(monthResult?.kind == .explicitMonth, "『2026年7月』应为 explicitMonth，实际=\(String(describing: monthResult?.kind))")
        let monthStart = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        expect(monthResult?.timeRange.start == monthStart, "『2026年7月』起点应为 7月1日")

        // 「今年」仍走词法 currentYear。
        let thisYear = HoloAgentTimeSemanticResolver.resolve(
            "今年体重趋势", referenceDate: referenceDate, calendar: calendar
        )
        expect(thisYear?.kind == .currentYear, "『今年』应为 currentYear，实际=\(String(describing: thisYear?.kind))")
    }

    // MARK: - 中文数字年份归一化

    /// 「二零二六年」应与「2026年」解析出同一全年窗口。
    /// 此前 normalize 无中文数字归一化，regex 只认阿拉伯数字 → 返回 nil → 只查近 14 天。
    private static func test中文数字年份解析为全年窗口() {
        let result = HoloAgentTimeSemanticResolver.resolve(
            "二零二六年我的体重变化趋势是怎样的", referenceDate: referenceDate, calendar: calendar
        )
        expect(result != nil, "『二零二六年』应解析出全年窗口（归一化后等价于『2026年』）")
        expect(result?.kind == .explicitYear, "应为 explicitYear，实际=\(String(describing: result?.kind))")
        expect(result?.timeRange.label == "2026年", "label 应为「2026年」，实际=\(result?.timeRange.label ?? "nil")")
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        expect(result?.timeRange.start == start, "起点应为 2026-01-01，实际=\(String(describing: result?.timeRange.start))")
        expect(result?.timeRange.end == end, "终点应为 2027-01-01，实际=\(String(describing: result?.timeRange.end))")
    }

    /// 归一化不得破坏阿拉伯数字路径，也不得误伤「一个月」等非时间表达。
    private static func test中文数字不影响阿拉伯数字路径() {
        // 阿拉伯数字仍正常
        let arabic = HoloAgentTimeSemanticResolver.resolve(
            "2026年体重趋势", referenceDate: referenceDate, calendar: calendar
        )
        expect(arabic?.kind == .explicitYear, "阿拉伯『2026年』仍应为 explicitYear")
        expect(arabic?.timeRange.label == "2026年", "阿拉伯 label 应为「2026年」")

        // 「一个月」「第一天」不应被误解析为时间范围（无『年』『月份』锚点不归一）
        let nonTime = HoloAgentTimeSemanticResolver.resolve(
            "养成一个习惯需要多少天", referenceDate: referenceDate, calendar: calendar
        )
        // 这类无时间语义的问题本就应返回 nil，不应因归一化误命中。
        expect(nonTime?.kind != .explicitYear, "『一个习惯』不应被误判为 explicitYear")
    }
}
