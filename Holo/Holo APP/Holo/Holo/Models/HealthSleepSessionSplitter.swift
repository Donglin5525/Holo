//
//  HealthSleepSessionSplitter.swift
//  Holo
//
//  睡眠会话切分器：把归晚窗口（前一日中午→当日中午）内的睡眠样本切成多个
//  「睡眠会话」，选出睡着总时长最长的「主睡眠（夜间）」，其余记为小睡。
//
//  背景：此前窗口内所有样本一律视为一晚，白天小睡被并入夜间（如 12:00 午睡
//  导致「入睡 12:00」、时间轴横跨 20.5 小时、深睡集中算出 0%）。切分器在
//  Builder / Analyzer 上游把主睡眠请出来，两个既有模块语义零改动。
//
//  口径：
//  - 会话聚类：睡着类区间（合并后）之间空隙 < 3 小时归同一会话；
//  - 尾巴吸收：与主睡眠重叠、或与主睡眠边缘间隔 < 60 分钟的在床/清醒样本并入
//    主睡眠（可级联：赖床链条延伸到真实离床为止；间隔 ≥ 60 分钟视为起床后的
//    行为，不并入，避免上午间歇躺床拉长轴）；
//  - 夜醒判定锚点 mainAsleepEnd = 主睡眠最后一个睡着区间的终点，
//    其后的清醒/在床尾巴是「末次醒来（起床）」而非夜醒，统计口径由消费方据此排除。
//  纯函数，供 Repository 与测试共用。
//

import Foundation

enum HealthSleepSessionSplitter {

    /// 睡着类样本的 HKCategoryValueSleepAnalysis.rawValue（unspecified/core/deep/REM）
    private static let asleepRawValues: Set<Int> = [3, 4, 5, 6]

    /// 睡着段之间空隙低于该阈值归同一会话（起夜 30–60 分钟不会劈开两觉）
    static let sessionGapThreshold: TimeInterval = 3 * 3600
    /// 在床/清醒尾巴与主睡眠边缘间隔低于该阈值即并入（级联延伸到真实离床/上床为止）
    static let tailChainGapThreshold: TimeInterval = 60 * 60

    struct Result: Sendable {
        /// 主睡眠的全部样本：睡着类 + 被吸收的尾巴，按 start 升序
        let mainSamples: [(value: Int, start: Date, end: Date)]
        /// 主睡眠最后一个睡着区间的终点（末次醒来判定锚点）
        let mainAsleepEnd: Date
        /// 当日小睡次数（不含主睡眠）
        let napCount: Int
        /// 当日小睡着总时长（秒）
        let napTotalSeconds: TimeInterval
    }

    /// 返回 nil = 窗口内没有任何睡着段（调用方按 noData 处理）。
    static func split(samples: [(value: Int, start: Date, end: Date)]) -> Result? {
        let valid = samples.filter { $0.end > $0.start }
        let asleepSamples = valid.filter { asleepRawValues.contains($0.value) }
        let restSamples = valid.filter { !asleepRawValues.contains($0.value) }
        let mergedAsleep = HealthSleepSampleAggregator.merged(
            asleepSamples.map { HealthSleepSampleAggregator.Interval(start: $0.start, end: $0.end) }
        )
        guard !mergedAsleep.isEmpty else { return nil }

        // merge 后区间按空隙聚类
        var clusters: [[HealthSleepSampleAggregator.Interval]] = [[mergedAsleep[0]]]
        for interval in mergedAsleep.dropFirst() {
            if interval.start.timeIntervalSince(clusters[clusters.count - 1].last!.end) < sessionGapThreshold {
                clusters[clusters.count - 1].append(interval)
            } else {
                clusters.append([interval])
            }
        }

        func asleepSeconds(_ list: [HealthSleepSampleAggregator.Interval]) -> TimeInterval {
            list.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        }
        let mainIndex = clusters.indices.max { asleepSeconds(clusters[$0]) < asleepSeconds(clusters[$1]) } ?? 0
        let mainCluster = clusters[mainIndex]
        let mainStart = mainCluster.first!.start
        let mainAsleepEnd = mainCluster.last!.end

        let napCount = clusters.count - 1
        let napTotalSeconds = clusters.enumerated()
            .filter { $0.offset != mainIndex }
            .reduce(0.0) { partial, cluster in partial + asleepSeconds(cluster.element) }

        // 主会话睡着样本：与主会话合并区间有交叠者（不裁剪，保持分期原貌）
        var mainSamples: [(value: Int, start: Date, end: Date)] = asleepSamples.filter { sample in
            mainCluster.contains { interval in
                sample.start < interval.end && sample.end > interval.start
            }
        }
        // 尾巴吸收：与主睡眠重叠或间隔 < 60 分钟的在床/清醒样本并入主睡眠，
        // 并入后边缘外扩、级联吸收（赖床链条），直到无新样本可并。
        var sessionStart = mainStart
        var sessionEnd = mainAsleepEnd
        var absorbed: [(value: Int, start: Date, end: Date)] = []
        var changed = true
        while changed {
            changed = false
            for sample in restSamples {
                let alreadyAbsorbed = absorbed.contains { $0.start == sample.start && $0.end == sample.end && $0.value == sample.value }
                guard !alreadyAbsorbed else { continue }
                let chains = sample.start < sessionEnd + tailChainGapThreshold
                    && sample.end > sessionStart - tailChainGapThreshold
                if chains {
                    absorbed.append(sample)
                    sessionStart = min(sessionStart, sample.start)
                    sessionEnd = max(sessionEnd, sample.end)
                    changed = true
                }
            }
        }
        mainSamples.append(contentsOf: absorbed)
        mainSamples.sort { $0.start < $1.start }

        return Result(
            mainSamples: mainSamples,
            mainAsleepEnd: mainAsleepEnd,
            napCount: napCount,
            napTotalSeconds: napTotalSeconds
        )
    }
}
