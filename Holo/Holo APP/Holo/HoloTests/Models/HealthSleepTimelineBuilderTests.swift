//
//  HealthSleepTimelineBuilderTests.swift
//  HoloTests
//
//  时间轴构建器测试：分阶段归并、重叠合并、排序、hasStageData 判定、无睡着段返回 nil。
//

import Foundation
@testable import Holo

struct HealthSleepTimelineBuilderTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test分阶段归并并按时间排序()
        test同阶段重叠样本合并为一段()
        test无阶段数据判定为引导态()
        test无睡着段返回nil()
        test未知阶段值被忽略()
        test夜醒标注分散时全在上线()
        test夜醒标注过密时上下行交错()
        test夜醒标注两行都放不下时不显示()
        test夜醒标注间距恰好达标时仍算放得下()
        print("HealthSleepTimelineBuilderTests passed")
    }

    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static let wakeDay = base

    private static func sample(_ value: Int, _ startMin: Double, _ endMin: Double)
        -> (value: Int, start: Date, end: Date) {
        (value, base.addingTimeInterval(startMin * 60), base.addingTimeInterval(endMin * 60))
    }

    private static func test分阶段归并并按时间排序() {
        let timeline = HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: [
            sample(0, 0, 17),    // inBed → 潜伏
            sample(5, 17, 61),   // deep
            sample(6, 61, 73),   // rem
            sample(4, 73, 117),  // core
            sample(2, 117, 129)  // awake
        ])
        expect(timeline != nil, "有睡着段应产出时间轴")
        let segments = timeline!.segments
        expect(segments.count == 5, "五个阶段各一段，实际 \(segments.count)")
        expect(segments.map(\.stage) == [.inBedAwake, .asleepDeep, .asleepREM, .asleepCore, .awake],
               "分段应按开始时间升序，实际 \(segments.map(\.stage))")
        expect(timeline!.hasStageData, "含 deep/rem/core 应判定有阶段数据")
        expect(timeline!.nightStart == base.addingTimeInterval(0), "nightStart 应为首段起点")
        expect(timeline!.nightEnd == base.addingTimeInterval(129 * 60), "nightEnd 应为末段终点")
    }

    private static func test同阶段重叠样本合并为一段() {
        let timeline = HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: [
            sample(4, 0, 60),
            sample(4, 50, 120),   // 与上段重叠
            sample(6, 130, 160)
        ])
        let coreSegments = timeline!.segments.filter { $0.stage == .asleepCore }
        expect(coreSegments.count == 1, "重叠 core 样本应合并为 1 段，实际 \(coreSegments.count)")
        expect(coreSegments.first!.duration == 120 * 60, "合并后时长应为 120 分钟")
    }

    private static func test无阶段数据判定为引导态() {
        // iPhone 用户：只有 unspecified 睡着 + 在床，无 deep/core/rem
        let timeline = HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: [
            sample(0, 0, 17),
            sample(3, 17, 460)
        ])
        expect(timeline != nil, "unspecified 睡着段也应产出时间轴")
        expect(timeline!.hasStageData == false, "无 deep/core/rem 应判定为引导态")
        expect(timeline!.segments.map(\.stage) == [.inBedAwake, .asleepUnspecified], "阶段序列应为潜伏+未分期")
    }

    private static func test无睡着段返回nil() {
        let timeline = HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: [
            sample(0, 0, 480)  // 只有在床
        ])
        expect(timeline == nil, "只有 inBed 无睡着段应返回 nil")
    }

    private static func test未知阶段值被忽略() {
        let timeline = HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: [
            sample(99, 0, 30),   // 未知值
            sample(4, 30, 90)
        ])
        expect(timeline!.segments.count == 1, "未知阶段值样本应被忽略")
    }

    // MARK: - 夜醒标注两行避让（SleepTimelineCard.wakeMarkRows）

    private static func test夜醒标注分散时全在上线() {
        let rows = SleepTimelineCard.wakeMarkRows(offsets: [30, 150, 270], minGap: 32)
        expect(rows == [0, 0, 0], "间距充足的标注应全留在上行，实际 \(rows)")
    }

    private static func test夜醒标注过密时上下行交错() {
        // 复刻线上案例：40~45 分钟间隔的三个夜醒（300pt 宽、8 小时跨度下 x≈27/54/81）
        let rows = SleepTimelineCard.wakeMarkRows(offsets: [30, 50, 90], minGap: 32)
        expect(rows == [0, 1, 0], "过密标注应上下行交错，实际 \(rows)")
    }

    private static func test夜醒标注两行都放不下时不显示() {
        let rows = SleepTimelineCard.wakeMarkRows(offsets: [30, 40, 50], minGap: 32)
        expect(rows == [0, 1, nil], "第三标注两行均放不下应弃显而非叠字，实际 \(rows)")
    }

    private static func test夜醒标注间距恰好达标时仍算放得下() {
        let rows = SleepTimelineCard.wakeMarkRows(offsets: [30, 62], minGap: 32)
        expect(rows == [0, 0], "间距恰等于 minGap 应视为放得下，实际 \(rows)")
    }
}

#if !HOLO_XCTEST_BRIDGE
@main
private struct HoloStandaloneLauncher {
    static func main() {
        HealthSleepTimelineBuilderTests.main()
    }
}
#endif
