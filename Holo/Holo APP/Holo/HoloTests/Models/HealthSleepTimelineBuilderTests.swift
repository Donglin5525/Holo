//
//  HealthSleepTimelineBuilderTests.swift
//  HoloTests
//
//  时间轴构建器测试：分阶段归并、重叠合并、排序、hasStageData 判定、无睡着段返回 nil。
//

import Foundation
import HealthKit
@testable import Holo

struct HealthSleepTimelineBuilderTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test使用AppleSDK真实阶段值()
        test真实REM进入明细与结构分析()
        test未分期睡眠不丢失()
        test没有REM样本时保留未知()
        test整晚在床不遮盖分期()
        test均值与最高值的显示基础一致()
        test分阶段归并并按时间排序()
        test同阶段重叠样本合并为一段()
        test无阶段数据判定为引导态()
        test无睡着段返回nil()
        test未知阶段值被忽略()
        print("HealthSleepTimelineBuilderTests passed")
    }

    private static func test使用AppleSDK真实阶段值() {
        let timeline = HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: [
            sample(HKCategoryValueSleepAnalysis.asleepCore.rawValue, 0, 60),
            sample(HKCategoryValueSleepAnalysis.asleepDeep.rawValue, 60, 90),
            sample(HKCategoryValueSleepAnalysis.asleepREM.rawValue, 90, 120)
        ])
        expect(timeline?.segments.map(\.stage) == [.asleepCore, .asleepDeep, .asleepREM],
               "必须按 Apple SDK 识别核心、深睡和 REM，不能让 mock 自证错误编号")
    }

    private static func test真实REM进入明细与结构分析() {
        let detail = HealthRepository.makeSleepDetail(wakeDay: wakeDay, rawSamples: [
            sample(HKCategoryValueSleepAnalysis.inBed.rawValue, -7, 120),
            sample(HKCategoryValueSleepAnalysis.asleepCore.rawValue, 0, 60),
            sample(HKCategoryValueSleepAnalysis.asleepDeep.rawValue, 60, 90),
            sample(HKCategoryValueSleepAnalysis.asleepREM.rawValue, 90, 120)
        ])
        expect(detail?.coreHours == 1, "真实核心时长应为 60 分钟")
        expect(detail?.deepHours == 0.5, "真实深睡时长应为 30 分钟")
        expect(detail?.remHours == 0.5, "真实 REM 时长应为 30 分钟")
        expect(detail?.remEpisodes == 1 && detail?.remLatencyMinutes == 90, "REM 应进入结构分析")
        expect(detail?.sleepOnsetLatencyMinutes == 7, "入睡耗时应保留 7 分钟")
    }

    private static func test未分期睡眠不丢失() {
        let samples = [sample(HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, 0, 120)]
        let detail = HealthRepository.makeSleepDetail(wakeDay: wakeDay, rawSamples: samples)
        expect(detail?.totalHours == 2 && detail?.hasStageData == false, "未分期睡眠应保留时长并使用引导态")
    }

    private static func test没有REM样本时保留未知() {
        let detail = HealthRepository.makeSleepDetail(wakeDay: wakeDay, rawSamples: [
            sample(HKCategoryValueSleepAnalysis.asleepCore.rawValue, 0, 60),
            sample(HKCategoryValueSleepAnalysis.asleepDeep.rawValue, 60, 90)
        ])
        expect(detail?.remHours == nil && detail?.remEpisodes == nil,
               "未收到 REM 样本应显示未记录，不能伪装为 0 分钟")
    }

    private static func test整晚在床不遮盖分期() {
        let timeline = HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: [
            sample(HKCategoryValueSleepAnalysis.inBed.rawValue, -7, 130),
            sample(HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, 0, 120),
            sample(HKCategoryValueSleepAnalysis.asleepCore.rawValue, 0, 60),
            sample(HKCategoryValueSleepAnalysis.asleepREM.rawValue, 60, 120)
        ])
        expect(timeline?.segments.map(\.stage) == [.inBedAwake, .asleepCore, .asleepREM, .inBedAwake], "整晚在床/未分期底层不得覆盖已知阶段")
        expect(timeline?.segments.filter { $0.stage == .inBedAwake }.reduce(0) { $0 + $1.duration } == 17 * 60, "只显示首尾未睡的在床时间")
    }

    private static func test均值与最高值的显示基础一致() {
        let values = (0..<7).map { DailyHealthData(date: base.addingTimeInterval(Double($0) * 86400), value: 8.45) }
        expect(DailyHealthData.averageValue(in: values) == 8.45, "完全相同记录的均值必须等于最高值，不能显示平均 8.5、最高 8.4")
        expect(DailyHealthData.averageValue(in: []) == nil, "没有记录时均值未知")
    }

    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static let wakeDay = base

    private static func sample(_ value: Int, _ startMin: Double, _ endMin: Double)
        -> (value: Int, start: Date, end: Date) {
        (value, base.addingTimeInterval(startMin * 60), base.addingTimeInterval(endMin * 60))
    }

    private static func test分阶段归并并按时间排序() {
        let timeline = HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: [
            sample(HKCategoryValueSleepAnalysis.inBed.rawValue, 0, 17),    // inBed → 潜伏
            sample(HKCategoryValueSleepAnalysis.asleepDeep.rawValue, 17, 61),   // deep
            sample(HKCategoryValueSleepAnalysis.asleepREM.rawValue, 61, 73),   // rem
            sample(HKCategoryValueSleepAnalysis.asleepCore.rawValue, 73, 117),  // core
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
            sample(HKCategoryValueSleepAnalysis.asleepCore.rawValue, 0, 60),
            sample(HKCategoryValueSleepAnalysis.asleepCore.rawValue, 50, 120),   // 与上段重叠
            sample(HKCategoryValueSleepAnalysis.asleepREM.rawValue, 130, 160)
        ])
        let coreSegments = timeline!.segments.filter { $0.stage == .asleepCore }
        expect(coreSegments.count == 1, "重叠 core 样本应合并为 1 段，实际 \(coreSegments.count)")
        expect(coreSegments.first!.duration == 120 * 60, "合并后时长应为 120 分钟")
    }

    private static func test无阶段数据判定为引导态() {
        // iPhone 用户：只有 unspecified 睡着 + 在床，无 deep/core/rem
        let timeline = HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: [
            sample(HKCategoryValueSleepAnalysis.inBed.rawValue, 0, 17),
            sample(HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, 17, 460)
        ])
        expect(timeline != nil, "unspecified 睡着段也应产出时间轴")
        expect(timeline!.hasStageData == false, "无 deep/core/rem 应判定为引导态")
        expect(timeline!.segments.map(\.stage) == [.inBedAwake, .asleepUnspecified], "阶段序列应为潜伏+未分期")
    }

    private static func test无睡着段返回nil() {
        let timeline = HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: [
            sample(HKCategoryValueSleepAnalysis.inBed.rawValue, 0, 480)  // 只有在床
        ])
        expect(timeline == nil, "只有 inBed 无睡着段应返回 nil")
    }

    private static func test未知阶段值被忽略() {
        let timeline = HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: [
            sample(99, 0, 30),   // 未知值
            sample(HKCategoryValueSleepAnalysis.asleepCore.rawValue, 30, 90)
        ])
        expect(timeline!.segments.count == 1, "未知阶段值样本应被忽略")
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

#if canImport(UIKit)
import SwiftUI
import XCTest
import UIKit

/// 渲染真实 SwiftUI 组件的稀疏态，附件为合成样本，不代表用户健康记录。
final class SleepPageLayoutSnapshotTests: XCTestCase {
    @MainActor
    func test睡眠组件正常与缺失状态() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ stage: HKCategoryValueSleepAnalysis, _ start: Double, _ end: Double) -> (value: Int, start: Date, end: Date) {
            (stage.rawValue, base.addingTimeInterval(start * 60), base.addingTimeInterval(end * 60))
        }
        let raw = [sample(.inBed, -7, 130), sample(.asleepCore, 0, 60),
                   sample(.asleepDeep, 60, 90), sample(.asleepREM, 90, 120)]
        let detail = try XCTUnwrap(HealthRepository.makeSleepDetail(wakeDay: base, rawSamples: raw))
        let timeline = try XCTUnwrap(HealthSleepTimelineBuilder.build(wakeDay: base, samples: raw))
        try capture(SleepTimelineCard(timeline: timeline, detail: detail), name: "timeline-normal-dark", color: .dark, usesUIKit: true)
        try capture(SleepTimelineCard(timeline: timeline, detail: detail), name: "timeline-large-dark", color: .dark, size: .accessibility2, usesUIKit: true)
        try capture(SleepStagesCard(detail: detail), name: "stages-normal-light", color: .light)
        var missing = detail
        missing.remHours = nil
        missing.remEpisodes = nil
        try capture(SleepStagesCard(detail: missing), name: "stages-missing-rem-dark", color: .dark)
        try capture(SleepStagesCard(detail: missing), name: "stages-missing-rem-large", color: .dark, size: .accessibility2)
        try capture(SleepStageGuideCard(), name: "no-stages-light", color: .light)
    }

    @MainActor
    private func capture<Content: View>(_ content: Content, name: String, color: ColorScheme,
                                       size: DynamicTypeSize = .large, usesUIKit: Bool = false) throws {
        let content = content.padding(HoloSpacing.md)
            .frame(width: 353).background(Color.holoToolBackground)
            .environment(\.colorScheme, color).environment(\.dynamicTypeSize, size)
        let rendered: UIImage
        if usesUIKit {
            // 时间轴含 UIKit 手势层，不能用 ImageRenderer；先挂载并落实字号，再测量完整高度。
            let host = UIHostingController(rootView: content.fixedSize(horizontal: false, vertical: true))
            host.safeAreaRegions = []
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 353, height: 10_000))
            window.rootViewController = host
            window.overrideUserInterfaceStyle = color == .dark ? .dark : .light
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            let measured = host.sizeThatFits(in: CGSize(width: 353, height: 10_000))
            host.view.frame = CGRect(origin: .zero, size: measured)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            rendered = UIGraphicsImageRenderer(size: measured, format: format).image { context in
                host.view.layer.render(in: context.cgContext)
            }
        } else {
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            rendered = try XCTUnwrap(renderer.uiImage)
        }
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "sleep-synthetic-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
