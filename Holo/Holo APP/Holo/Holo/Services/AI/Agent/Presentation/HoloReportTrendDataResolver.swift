//
//  HoloReportTrendDataResolver.swift
//  Holo
//
//  报告趋势图数据回查（2026-09-24 报告可读性改造）：
//  云端报告的证据带稳定的数据集标识（dataset），而逐日原始数据本就在本机。
//  与其让后端把序列塞回报告 JSON（上传→分析→回传的绕路），不如按
//  dataset + 报告时间窗直接回查本机序列——数据同源、协议零改动、
//  对存量旧报告也立即生效。查不到/序列太短/数据集不可映射：返回 nil，
//  UI 静默降级不画图（趋势图是形状直觉，不承担与云端指标逐位对账的职责，
//  卡上明确标注「本机逐日数据」）。
//

import Foundation
import CoreData

struct HoloReportTrendSeries: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        var date: Date
        var value: Double
    }
    var title: String
    var unitLabel: String
    var points: [Point]
}

enum HoloReportTrendDataResolver {

    /// 数据集 → 展示配置。只收录逐日语义清晰的数据集；
    /// 会话/行级数据（health.workout 等）不画逐日折线。
    static let supportedDatasets: [String: (title: String, unit: String)] = [
        "health.sleep": ("每日睡眠时长", "小时"),
        "health.steps": ("每日步数", "步"),
        "health.stand": ("每日站立", "小时"),
        "health.activity": ("每日活动时长", "分钟"),
        "health.energy": ("每日活动能量", "千卡"),
        "health.distance": ("每日距离", "公里"),
        "finance.transactions": ("每日支出", "元"),
    ]

    static func isSupported(dataset: String?) -> Bool {
        guard let dataset else { return false }
        return supportedDatasets[dataset] != nil
    }

    /// 回查数据集在 [start, end] 的逐日序列。序列点 < 3 返回 nil（画不出趋势）。
    static func resolve(dataset: String, start: Date, end: Date) async -> HoloReportTrendSeries? {
        guard let config = supportedDatasets[dataset] else { return nil }
        let calendar = Calendar.current
        let windowStart = calendar.startOfDay(for: start)
        let windowEnd = calendar.startOfDay(for: end)
        guard windowEnd >= windowStart else { return nil }

        var points: [HoloReportTrendSeries.Point]
        switch dataset {
        case "health.sleep":
            points = healthPoints(await HealthRepository.shared.fetchSleepRange(from: windowStart, to: windowEnd))
        case "health.steps":
            points = healthPoints(await HealthRepository.shared.fetchStepsRange(from: windowStart, to: windowEnd))
        case "health.stand":
            points = healthPoints(await HealthRepository.shared.fetchStandTimeRange(from: windowStart, to: windowEnd))
        case "health.activity":
            points = healthPoints(await HealthRepository.shared.fetchActiveMinutesRange(from: windowStart, to: windowEnd))
        case "health.energy":
            if case let .value(data) = await HealthRepository.shared.fetchEnergyRangeStrict(from: windowStart, to: windowEnd) {
                points = healthPoints(data)
            } else {
                return nil
            }
        case "health.distance":
            if case let .value(data) = await HealthRepository.shared.fetchDistanceRangeStrict(from: windowStart, to: windowEnd) {
                points = healthPoints(data)
            } else {
                return nil
            }
        case "finance.transactions":
            points = await dailyExpensePoints(from: windowStart, to: windowEnd)
        default:
            return nil
        }

        let filtered = points
            .filter { $0.date >= windowStart && $0.date <= windowEnd }
            .sorted { $0.date < $1.date }
        guard filtered.count >= 3 else { return nil }
        return HoloReportTrendSeries(
            title: config.title,
            unitLabel: config.unit,
            points: weeklyAggregatedIfDense(filtered)
        )
    }

    /// 健康逐日序列：只保留有样本且 > 0 的天（0 常见于未佩戴/无读数，
    /// 画成 0 会制造「那天没睡」的假象；断线比假 0 诚实）。
    private static func healthPoints(_ data: [DailyHealthData]) -> [HoloReportTrendSeries.Point] {
        data.compactMap { item in
            guard item.value > 0 else { return nil }
            return HoloReportTrendSeries.Point(date: Calendar.current.startOfDay(for: item.date), value: item.value)
        }
    }

    /// 财务逐日支出：窗口内支出交易按日落袋（deletedAt==nil 口径与查询引擎一致）。
    /// 没花钱的天是真实 0，补零画出「哪些天没花钱」。
    private static func dailyExpensePoints(from start: Date, to end: Date) async -> [HoloReportTrendSeries.Point] {
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        let endExclusive = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end.addingTimeInterval(86_400)
        let sumsByDay: [Date: Double] = await context.perform {
            let request = Transaction.fetchRequest()
            request.predicate = NSPredicate(
                format: "type == %@ AND deletedAt == nil AND date >= %@ AND date < %@",
                "expense",
                start as NSDate,
                endExclusive as NSDate
            )
            guard let transactions = try? context.fetch(request) else { return [:] }
            return transactions.reduce(into: [:]) { partial, transaction in
                let day = Calendar.current.startOfDay(for: transaction.date)
                partial[day, default: 0] += transaction.amount.doubleValue
            }
        }
        var points: [HoloReportTrendSeries.Point] = []
        var cursor = start
        let calendar = Calendar.current
        while cursor <= end {
            points.append(HoloReportTrendSeries.Point(
                date: cursor,
                value: (sumsByDay[cursor] ?? 0).rounded(toPlaces: 2)
            ))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end.addingTimeInterval(1)
        }
        return points
    }

    /// 点数过多（> 62，即近 90/180 天报告）时按周聚合取周均值：
    /// 睡眠/步数/金额的周均形状直觉一致（周均支出×7=周合计），卡上标注「按周」；
    /// 否则原样返回逐日。（internal 供单测锁定聚合口径）
    static func weeklyAggregatedIfDense(_ points: [HoloReportTrendSeries.Point]) -> [HoloReportTrendSeries.Point] {
        guard points.count > 62 else { return points }
        let calendar = Calendar.current
        var byWeek: [Date: [Double]] = [:]
        for point in points {
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: point.date)?.start ?? point.date
            byWeek[weekStart, default: []].append(point.value)
        }
        return byWeek
            .sorted { $0.key < $1.key }
            .map { weekStart, values in
                HoloReportTrendSeries.Point(
                    date: weekStart,
                    value: (values.reduce(0, +) / Double(values.count)).rounded(toPlaces: 2)
                )
            }
    }
}

private extension Double {
    func rounded(toPlaces: Int) -> Double {
        let divisor = pow(10.0, Double(toPlaces))
        return (self * divisor).rounded() / divisor
    }
}
