//
//  HealthNightVitals.swift
//  Holo
//
//  睡眠体征（健康分析方案 2026-11-17 第二步）：
//  把心率、呼吸频率、HRV 样本按「选定主睡眠的可信睡着区间」匹配——
//  区间外的样本（日间呼吸、睡前 HRV、正午运动心率）不进入该晚统计。
//  达到覆盖门槛才给该晚中位数；少量样本保留为可查看的观测点。
//
//  静息心率保留独立日粒度（fetchVitalsRange 既有口径不动）。
//  覆盖门槛为试用默认值，集中配置，待真实记录校准。
//

import Foundation

// MARK: - 模型

/// 单个体征采样点（时间 + 数值 + 单位由所属指标约定）
struct HealthVitalSample: Equatable, Sendable {
    let date: Date
    let value: Double
}

/// 一项体征在一晚的结果
struct HealthNightMetricVitals: Equatable, Sendable {
    enum Coverage: String, Sendable {
        /// 达到覆盖门槛（样本数 + 前后两半各有样本），中位数可用
        case sufficient
        /// 少量样本，可作观测点查看（不进入结论）
        case observed
        /// 该晚无入睡区间内样本
        case none
    }

    /// 落在可信睡着区间内的采样点（按时间升序）
    let samples: [HealthVitalSample]
    /// 仅 sufficient 时非 nil
    let median: Double?

    var coverage: Coverage {
        if median != nil { return .sufficient }
        return samples.isEmpty ? .none : .observed
    }
}

/// 一晚的睡眠体征
struct HealthNightVitals: Equatable, Sendable {
    /// 睡眠心率（次/分）
    let heartRate: HealthNightMetricVitals
    /// 睡眠呼吸频率（次/分）
    let respiratory: HealthNightMetricVitals
    /// 睡眠 HRV（ms）
    let heartRateVariability: HealthNightMetricVitals
}

// MARK: - 匹配器（纯函数）

nonisolated enum HealthNightVitalsMatcher {

    typealias Interval = HealthSleepSampleAggregator.Interval

    /// 覆盖门槛（试用默认值：心率/呼吸各 ≥3，HRV ≥2，
    /// 且该指标在主睡眠累计睡着时长的前后两半各有样本）
    static func minimumSamples(isHRV: Bool) -> Int { isHRV ? 2 : 3 }

    /// 把区间外样本剔除并按覆盖门槛产出中位数。
    /// - Parameters:
    ///   - raw: 会话时间跨度内拉到的全部采样点
    ///   - trustedIntervals: 主睡眠的可信睡着区间（累计时长的前后两半按时间顺序切分）
    static func match(
        raw: [HealthVitalSample],
        trustedIntervals: [Interval],
        isHRV: Bool = false
    ) -> HealthNightMetricVitals {
        let sortedIntervals = trustedIntervals.sorted { $0.start < $1.start }
        let inside = raw
            .filter { sample in
                sortedIntervals.contains { sample.date >= $0.start && sample.date < $0.end }
            }
            .sorted { $0.date < $1.date }

        guard !inside.isEmpty else {
            return HealthNightMetricVitals(samples: [], median: nil)
        }

        // 前后两半：沿可信睡着区间的累计时长在中点切分
        let total = sortedIntervals.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        var elapsed: TimeInterval = 0
        var halfBoundary: Date?
        for interval in sortedIntervals {
            let length = interval.end.timeIntervalSince(interval.start)
            if elapsed + length >= total / 2 {
                let offset = total / 2 - elapsed
                halfBoundary = interval.start.addingTimeInterval(offset)
                break
            }
            elapsed += length
        }
        let boundary = halfBoundary ?? sortedIntervals.last!.end
        let inFirstHalf = inside.contains { $0.date < boundary }
        let inSecondHalf = inside.contains { $0.date >= boundary }

        if inside.count >= minimumSamples(isHRV: isHRV), inFirstHalf, inSecondHalf {
            let values = inside.map(\.value).sorted()
            let middle = values.count / 2
            let median: Double = values.count % 2 == 1
                ? values[middle]
                : (values[middle - 1] + values[middle]) / 2
            return HealthNightMetricVitals(samples: inside, median: median)
        }
        return HealthNightMetricVitals(samples: inside, median: nil)
    }
}
