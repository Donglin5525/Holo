//
//  HabitNumericAggregation.swift
//  Holo
//
//  数值型习惯的每日聚合纯逻辑
//

import Foundation

/// 数值型习惯的原始样本。value 为空表示该记录不是有效数值记录。
struct HabitNumericSample {
    let date: Date
    let value: Double?
}

/// 数值型习惯按日聚合后的结果。
struct HabitDailyNumericValue: Equatable {
    let date: Date
    let value: Double
}

enum HabitNumericAggregator {

    /// 将原始记录统一聚合为每日数值。
    /// - 计数类：累加当天全部有效数值。
    /// - 测量类：取当天最后一条有效数值，而不是把最后一条空记录当成 0。
    ///
    /// 真实记录的 0 是有效业务数据，必须保留；nil、NaN 和无穷值不参与统计。
    static func aggregateDaily(
        samples: [HabitNumericSample],
        isCountType: Bool,
        calendar: Calendar = .current
    ) -> [HabitDailyNumericValue] {
        var validSamplesByDay: [Date: [HabitNumericSample]] = [:]

        for sample in samples {
            guard let value = sample.value, value.isFinite else { continue }
            let dayStart = calendar.startOfDay(for: sample.date)
            validSamplesByDay[dayStart, default: []].append(
                HabitNumericSample(date: sample.date, value: value)
            )
        }

        return validSamplesByDay.compactMap { dayStart, daySamples in
            if isCountType {
                let total = daySamples.compactMap(\.value).reduce(0, +)
                return HabitDailyNumericValue(date: dayStart, value: total)
            }

            guard let latestValue = daySamples
                .max(by: { $0.date < $1.date })?
                .value else {
                return nil
            }
            return HabitDailyNumericValue(date: dayStart, value: latestValue)
        }
        .sorted { $0.date < $1.date }
    }
}
