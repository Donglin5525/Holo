//
//  HealthSleepTimelineBuilder.swift
//  Holo
//
//  睡眠时间轴构建器：把一晚的 HealthKit 睡眠样本归并为可渲染的分段序列
//  （二期睡眠详情页「整晚睡眠时间轴」的数据源）。纯函数，供 Repository 与测试共用。
//
//  口径：单层时间轴只画「睡着类（深睡/核心/REM/未分期）+ 清醒」，在床但未睡的
//  首尾段画为入睡潜伏样式；与一期 SleepStructureAnalyzer 共用归晚窗口与阶段色语义。
//  阶段原始值与 HKCategoryValueSleepAnalysis.rawValue 对齐（inBed=0/awake=2/
//  asleepUnspecified=3/asleepCore=4/asleepDeep=5/asleepREM=6），保持独立于 HealthKit 可测。
//

import Foundation

/// 时间轴上的一个分段（阶段内已合并重叠、已裁剪到归晚窗口）
struct HealthSleepSegment: Equatable, Sendable {
    enum Stage: String, Equatable, Sendable {
        case asleepDeep
        case asleepCore
        case asleepREM
        /// 未分期睡着（混入 Watch 夜时按核心色渲染）
        case asleepUnspecified
        case awake
        /// 在床但未睡（入睡潜伏/晨间在床）
        case inBedAwake
    }

    let stage: HealthSleepSegment.Stage
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// 一晚的完整时间轴
struct HealthSleepTimeline: Equatable, Sendable {
    let wakeDay: Date
    /// 按 start 升序；段间空隙（无样本覆盖）由渲染层留白
    let segments: [HealthSleepSegment]
    /// 是否包含阶段分期（无 Watch 时为 false，UI 走引导态）
    let hasStageData: Bool

    var nightStart: Date? { segments.map(\.start).min() }
    var nightEnd: Date? { segments.map(\.end).max() }
}

enum HealthSleepTimelineBuilder {

    typealias Interval = HealthSleepSampleAggregator.Interval

    /// HKCategoryValueSleepAnalysis.rawValue 对照（独立于 HealthKit，纯函数可测）
    private enum StageRawValue {
        static let inBed = 0
        static let awake = 2
        static let asleepUnspecified = 3
        static let asleepCore = 4
        static let asleepDeep = 5
        static let asleepREM = 6
    }

    /// 输入：一晚的原始样本（阶段原始值、起止）。返回 nil = 该晚没有任何睡着段。
    static func build(wakeDay: Date, samples: [(value: Int, start: Date, end: Date)]) -> HealthSleepTimeline? {
        guard !samples.isEmpty else { return nil }

        func stage(for value: Int) -> HealthSleepSegment.Stage? {
            switch value {
            case StageRawValue.asleepDeep: return .asleepDeep
            case StageRawValue.asleepCore: return .asleepCore
            case StageRawValue.asleepREM: return .asleepREM
            case StageRawValue.asleepUnspecified: return .asleepUnspecified
            case StageRawValue.awake: return .awake
            case StageRawValue.inBed: return .inBedAwake
            default: return nil
            }
        }

        var byStage: [HealthSleepSegment.Stage: [Interval]] = [:]
        for sample in samples {
            guard let resolved = stage(for: sample.value), sample.end > sample.start else { continue }
            byStage[resolved, default: []].append(Interval(start: sample.start, end: sample.end))
        }

        let asleepStages: [HealthSleepSegment.Stage] = [.asleepCore, .asleepDeep, .asleepREM, .asleepUnspecified]
        let asleepIntervals = asleepStages.flatMap { byStage[$0] ?? [] }
        guard !asleepIntervals.isEmpty else { return nil }

        var segments: [HealthSleepSegment] = []
        for (resolved, intervals) in byStage {
            for interval in HealthSleepSampleAggregator.merged(intervals) {
                segments.append(HealthSleepSegment(stage: resolved, start: interval.start, end: interval.end))
            }
        }
        segments.sort { $0.start < $1.start }

        let hasStageData = !(byStage[.asleepDeep] ?? []).isEmpty
            || !(byStage[.asleepCore] ?? []).isEmpty
            || !(byStage[.asleepREM] ?? []).isEmpty

        return HealthSleepTimeline(wakeDay: wakeDay, segments: segments, hasStageData: hasStageData)
    }
}
