//
//  SleepStructureAnalyzer.swift
//  Holo
//
//  睡眠结构特征计算器：从一晚的分段序列推导 REM 段数、REM 潜伏期、
//  深睡前半夜占比、入睡潜伏期。纯函数，供 HealthRepository 与测试共用。
//
//  口径（与 AI 数据字典一致）：阶段特征依赖 Apple Watch（或兼容设备）写入的
//  睡眠分期；单晚分期精度有限，消费方应基于 7 天以上趋势解读，不做单晚定性。
//

import Foundation

struct SleepStructureAnalyzer {

    typealias Interval = HealthSleepSampleAggregator.Interval

    /// 一晚的分段输入：各阶段为裁剪到归晚窗口后的原始段（未合并）。
    struct NightSegments {
        /// core+deep+rem+unspecified 全部睡着段
        var asleep: [Interval]
        var core: [Interval]
        var deep: [Interval]
        var rem: [Interval]
        var inBed: [Interval]
    }

    /// 结构特征。nil = 该维度不可得（无阶段数据 / 无在床记录 / 多源错位），
    /// 消费方不得把 nil 当 0 解读。
    struct Features: Equatable, Sendable {
        var remEpisodes: Int?
        var remLatencyMinutes: Double?
        /// 前半夜深睡占整晚深睡百分比（0-100）
        var deepFrontLoadPercent: Double?
        var sleepOnsetLatencyMinutes: Double?
    }

    /// 低于该时长的 REM 段视为设备噪声，不计入段数。
    private static let remMinimumSegmentSeconds: TimeInterval = 300

    static func features(_ night: NightSegments) -> Features {
        guard let sleepOnset = night.asleep.map(\.start).min() else {
            return Features()
        }

        // 入睡潜伏期：上床 → 首次入睡。差值非正说明在床记录晚于入睡（多源错位），视为不可得。
        var onsetLatency: Double?
        if let bedStart = HealthSleepSampleAggregator.merged(night.inBed).first?.start {
            let latency = bedStart.distance(to: sleepOnset) / 60
            onsetLatency = latency > 0 ? latency : nil
        }

        let mergedREM = HealthSleepSampleAggregator.merged(night.rem)
            .filter { $0.end.timeIntervalSince($0.start) >= remMinimumSegmentSeconds }
        var remEpisodes: Int?
        var remLatency: Double?
        if !night.rem.isEmpty {
            remEpisodes = mergedREM.count
            remLatency = mergedREM.first.map { sleepOnset.distance(to: $0.start) / 60 }
        }

        var deepFrontLoad: Double?
        let mergedDeep = HealthSleepSampleAggregator.merged(night.deep)
        if !mergedDeep.isEmpty {
            let deepTotal = mergedDeep.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            let nightMid = sleepOnset.addingTimeInterval(
                (night.asleep.map(\.end).max() ?? sleepOnset).timeIntervalSince(sleepOnset) / 2
            )
            let frontWindow = Interval(start: sleepOnset, end: nightMid)
            let deepFront = mergedDeep.reduce(0.0) { sum, segment in
                guard let clipped = HealthSleepSampleAggregator.clippedInterval(
                    start: segment.start, end: segment.end, to: frontWindow
                ) else { return sum }
                return sum + clipped.end.timeIntervalSince(clipped.start)
            }
            deepFrontLoad = deepTotal > 0 ? deepFront / deepTotal * 100 : nil
        }

        return Features(
            remEpisodes: remEpisodes,
            remLatencyMinutes: remLatency,
            deepFrontLoadPercent: deepFrontLoad,
            sleepOnsetLatencyMinutes: onsetLatency
        )
    }
}
