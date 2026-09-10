//
//  ActivityDistributionAnalyzerTests.swift
//  HoloTests
//
//  活动节律特征计算器测试：最长静坐、活动时间窗、晚间步数占比、峰值小时、
//  全零天特征降级为 nil。
//

import Foundation
@testable import Holo

struct ActivityDistributionAnalyzerTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test午后低谷最长静坐与活动窗()
        test晚间步数占比与峰值小时()
        test白天全活跃时最长静坐为零()
        test全零天特征降级为nil()
        print("ActivityDistributionAnalyzerTests passed")
    }

    /// 早高峰/午后低谷/晚间高峰的一天
    private static let typicalDay: [Double] = [
        0, 0, 0, 0, 0, 0,          // 0-5
        50, 850, 1450, 600, 1100, 900,  // 6-11
        400, 80, 0, 0, 80, 200,    // 12-17
        1600, 1900, 1200, 500,     // 18-21
        100, 0                     // 22-23
    ]

    private static func test午后低谷最长静坐与活动窗() {
        let features = ActivityDistributionAnalyzer.features(hourlySteps: typicalDay)
        // 白天窗 8-21 时：13(80)/14(0)/15(0)/16(80) 连续 4 个安静小时
        expect(features.longestSedentaryMinutes == 240, "午后连续 4 个安静小时应为 240 分钟，实际 \(features.longestSedentaryMinutes)")
        expect(features.activeWindowStartHour == 7, "首个活跃小时应为 7（850 步），实际 \(String(describing: features.activeWindowStartHour))")
        expect(features.activeWindowEndHour == 21, "末个活跃小时应为 21（500 步），实际 \(String(describing: features.activeWindowEndHour))")
    }

    private static func test晚间步数占比与峰值小时() {
        let features = ActivityDistributionAnalyzer.features(hourlySteps: typicalDay)
        // 晚间 18-23 = 1600+1900+1200+500+100+0 = 5300；全天 11010
        expect(abs((features.eveningStepShare ?? 0) - 5300.0 / 11010.0) < 0.001,
               "晚间步数占比应约 0.481，实际 \(String(describing: features.eveningStepShare))")
        expect(features.peakHour == 19, "峰值小时应为 19（1900 步），实际 \(String(describing: features.peakHour))")
    }

    private static func test白天全活跃时最长静坐为零() {
        var hourly = Array(repeating: 500.0, count: 24)
        for index in 0...5 { hourly[index] = 0 }
        let features = ActivityDistributionAnalyzer.features(hourlySteps: hourly)
        expect(features.longestSedentaryMinutes == 0, "白天窗全活跃时最长静坐应为 0，实际 \(features.longestSedentaryMinutes)")
    }

    private static func test全零天特征降级为nil() {
        let features = ActivityDistributionAnalyzer.features(hourlySteps: Array(repeating: 0, count: 24))
        expect(features.activeWindowStartHour == nil && features.activeWindowEndHour == nil,
               "全零天活动窗必须为 nil（不可得 ≠ 没有活动）")
        expect(features.eveningStepShare == nil, "全零天晚间占比必须为 nil")
        expect(features.peakHour == nil, "全零天峰值小时必须为 nil")
    }
}

#if !HOLO_XCTEST_BRIDGE
@main
private struct HoloStandaloneLauncher {
    static func main() {
        ActivityDistributionAnalyzerTests.main()
    }
}
#endif
