//
//  ActivityDistributionAnalyzer.swift
//  Holo
//
//  活动节律特征计算器：由 24 小时步数桶推导最长连续静坐、活动时间窗、
//  晚间步数占比。纯函数，供 HealthRepository 与测试共用。
//
//  口径（与 AI 数据字典一致）：小时粒度聚合，非分钟级行为记录；
//  静坐判定 = 白天窗内整小时步数低于安静阈值。iPhone 即可产生，无需 Watch。
//

import Foundation

struct ActivityDistributionAnalyzer {

    struct Features: Equatable, Sendable {
        /// 白天窗内最长连续安静小时折算分钟；白天全活跃时为 0
        var longestSedentaryMinutes: Double
        /// 首个/末个活跃小时（步数≥活跃阈值）。nil = 全天无活跃小时
        var activeWindowStartHour: Int?
        var activeWindowEndHour: Int?
        /// 18-23 时步数占全天比例（0-1）。nil = 全天无步数
        var eveningStepShare: Double?
        /// 步数最多的小时。nil = 全天无步数
        var peakHour: Int?
    }

    static func features(
        hourlySteps: [Double],
        quietThreshold: Double = 100,
        activeThreshold: Double = 200,
        daytimeHours: Range<Int> = 8..<22
    ) -> Features {
        let hours = Array(hourlySteps.prefix(24))
        let total = hours.reduce(0, +)

        let longest = longestQuietRange(
            hourlySteps: hours,
            quietThreshold: quietThreshold,
            daytimeHours: daytimeHours
        )

        let activeHours = hours.indices.filter { hours[$0] >= activeThreshold }
        let eveningShare: Double?
        if total > 0 {
            let eveningTotal = hours.indices.filter { $0 >= 18 }.reduce(0.0) { $0 + hours[$1] }
            eveningShare = eveningTotal / total
        } else {
            eveningShare = nil
        }

        return Features(
            longestSedentaryMinutes: Double(longest?.count ?? 0) * 60,
            activeWindowStartHour: activeHours.first,
            activeWindowEndHour: activeHours.last,
            eveningStepShare: eveningShare,
            peakHour: total > 0 ? hours.indices.max(by: { hours[$0] < hours[$1] }) : nil
        )
    }

    /// 白天窗内最长连续安静小时区间（index 即小时）。nil = 无安静小时。
    /// 渲染层（分布卡高亮带）与分钟数口径共用此扫描，防两份逻辑漂移。
    static func longestQuietRange(
        hourlySteps: [Double],
        quietThreshold: Double = 100,
        daytimeHours: Range<Int> = 8..<22
    ) -> Range<Int>? {
        let hours = Array(hourlySteps.prefix(24))
        var best: Range<Int>?
        var runStart: Int?
        for hour in daytimeHours where hours.indices.contains(hour) {
            if hours[hour] < quietThreshold {
                if runStart == nil { runStart = hour }
                let count = hour - runStart! + 1
                if best == nil || count > best!.count {
                    best = runStart!..<(hour + 1)
                }
            } else {
                runStart = nil
            }
        }
        return best
    }
}
